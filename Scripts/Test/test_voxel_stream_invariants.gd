extends TestCase

## 存储 / 流式不变式测试（编辑器进程即可，无需游戏进程）。
##
## 这一层此前完全空白：既有用例覆盖了格式编解码与网格 / LOD 内核，却没有一项盯着
## "编辑 → 落盘 → 重载"这条数据通路。而重构（VoxelStream 退化为纯 IO、
## LOD 从独立 model 迁往 CACH）恰恰整条都动在这条路上，所以先把不变式钉死再动刀。
##
## 前四条从 VoxelData 的**公开行为**出发，不依赖 VoxelStream 的内部形态，
## 因此重构换掉 VoxelStream 接口后这些用例依然有效：
##   ① 编辑 → 卸载 → 重载：数据逐体素一致（磁盘为权威）
##   ② 空 chunk 不落盘；chunk 变空立即清盘（不留幽灵数据）
##   ③ 切换 stream：旧流上的未落盘数据先落盘，且内存数据不因切换而丢
##   ④ CACH / 未知块经"加载 → 改块 → 增量写盘"逐字节保真；且删掉 CACH 世界语义不变
##   ⑤ LOD 是 CACH 而非 VOX0 模型：往返命中、来源变更即失效、删 CACH 语义不变

const TEST_DIR := "user://voxel_stream_invariants"


## runner 在每个用例后无条件调用：清掉临时目录，避免残留污染下次运行。
func cleanup() -> void:
	_remove_dir(TEST_DIR)


# ----------------------------------------------------------------------------
# ① 编辑 → 卸载 → 重载
# ----------------------------------------------------------------------------

func test_edit_unload_reload_roundtrip() -> void:
	var path := TEST_DIR + "/roundtrip.qvox"
	var d := _make_data(path)
	var ck := Vector3i.ZERO
	var positions := [Vector3i(0, 0, 0), Vector3i(31, 0, 0), Vector3i(0, 31, 0), Vector3i(31, 31, 31)]
	for p in positions:
		d.set_voxel(p, 1, false)
	var edited := d.get_voxels_dict_snapshot()
	assert_eq(edited.size(), positions.size(), "编辑后内存应有 4 个体素")

	assert_true(d.unload_chunk(ck), "卸载应成功")
	assert_false(d.is_chunk_loaded(ck), "卸载后该 chunk 不应在内存")
	assert_true(d.stream.has_chunk(ck, 0), "卸载应把数据交给流")
	d.flush()   # QVoxStream 的 save 只改内存 + 置脏，真正写盘在 flush

	# 同实例：缺数据的 chunk 应从磁盘自动载回，读语义不变
	assert_eq(d.get_voxel(positions[0]), 1, "同实例重载后材质应一致")
	assert_eq(d.get_voxels_dict_snapshot(), edited, "同实例重载后体素集合应一致")

	# 新实例：完全从磁盘读（磁盘为权威）
	var r := _make_data(path)
	assert_eq(r.get_voxels_dict_snapshot(), edited, "新实例从磁盘读到的世界应一致")
	assert_true(r.has_chunk(ck), "新实例应认为该 chunk 有数据")


# ----------------------------------------------------------------------------
# ② 空 chunk 不落盘 / 变空立即清盘
# ----------------------------------------------------------------------------

func test_empty_chunk_is_not_persisted_and_is_erased() -> void:
	var path := TEST_DIR + "/empty.qvox"
	var d := _make_data(path)
	var ck := Vector3i.ZERO
	var p := Vector3i(5, 6, 7)

	d.set_voxel(p, 1, false)
	assert_true(d.is_chunk_loaded(ck), "编辑后 chunk 应在内存")
	d.flush()
	assert_true(d.stream.has_chunk(ck, 0), "有体素的 chunk 应落盘")

	# chunk 内唯一体素被移除 → chunk 变空 → 立即从内存与流中清除
	d.remove_voxel(p, false)
	assert_false(d.is_chunk_loaded(ck), "变空的 chunk 应从内存回收")
	assert_false(d.stream.has_chunk(ck, 0), "变空的 chunk 应立即清盘（不得留幽灵数据）")
	d.flush()

	var r := _make_data(path)
	assert_true(r.get_voxels_dict_snapshot().is_empty(), "磁盘上不应残留已清空的 chunk")
	assert_false(r.has_chunk(ck), "新实例不应认为该 chunk 有数据")


# ----------------------------------------------------------------------------
# ③ 切换 stream 不丢数据
# ----------------------------------------------------------------------------

func test_switch_stream_does_not_lose_data() -> void:
	var path_a := TEST_DIR + "/switch_a.qvox"
	var path_b := TEST_DIR + "/switch_b.qvox"
	var d := _make_data(path_a)
	var ck := Vector3i.ZERO
	var p := Vector3i(2, 3, 4)
	d.set_voxel(p, 1, false)   # 只在内存，未 flush

	var b := QVoxStream.new()
	b.file_path = path_b
	d.stream = b               # 切换：旧流先落盘，再挂新流

	# ③-a 旧流必须已落盘（切换时 flush），否则切流即丢存档
	var a := QVoxStream.new()
	a.file_path = path_a
	assert_true(a.has_chunk(ck, 0), "切换时应把旧流上的未落盘数据先落盘")
	assert_eq(a.load_chunk(ck, 0)[VoxelChunk.buf_index(2, 3, 4)], 1, "旧流内容应完好")

	# ③-b 内存数据不因切换而丢；且新流必须最终拿到它
	#（否则卸载时会被当成"磁盘已有"直接丢弃 → 静默丢数据）
	assert_eq(d.get_voxel(p), 1, "切换后内存数据不应丢失")
	d.flush()
	var b2 := QVoxStream.new()
	b2.file_path = path_b
	assert_true(b2.has_chunk(ck, 0), "新流应收到仍在内存中的世界数据")


# ----------------------------------------------------------------------------
# ④ CACH / 未知块：增量写盘保真 + CACH 可删
# ----------------------------------------------------------------------------

func test_cach_and_unknown_blocks_survive_incremental_flush() -> void:
	var path := TEST_DIR + "/cach.qvox"
	_write_world_with_cach(path)

	# 加载 → 改一块 → flush：此时必然走增量写（未变块搬运磁盘原始字节）
	var d := _make_data(path)
	d.set_voxel(Vector3i(2, 2, 2), 1, false)
	d.flush()

	var doc := _read_doc(path)
	assert_true(doc != null, "改块后文件应仍可解析")
	if doc == null:
		return
	assert_true(doc.models.has(0), "VOX0 应仍在")
	if doc.models.has(0):
		var blocks: Dictionary = doc.models[0]
		assert_eq(blocks[Vector3i.ZERO][VoxelChunk.buf_index(2, 2, 2)], 1, "改动应已落盘")
	assert_eq(doc.cach.size(), 1, "增量写不得丢掉 CACH")
	assert_true(doc.unknown_blocks.has("ZZZZ"), "增量写不得丢未知块")
	if doc.unknown_blocks.has("ZZZZ"):
		assert_eq(_strip_trailing_zeros(doc.unknown_blocks["ZZZZ"][0]),
				"opaque".to_utf8_buffer(), "未知块内容应逐字节保留")
	if doc.cach.size() == 1:
		assert_eq(String(doc.cach[0]["kind"]), "mesh", "增量写后 CACH 的 kind 应不变")
		assert_eq(_strip_trailing_zeros(doc.cach[0]["payload"]),
				"lods".to_utf8_buffer(), "增量写后 CACH 内容应逐字节保留")

	# CACH 是可删的派生数据（P5）：删掉后重开世界，LOD0 语义必须完全一致
	var pruned := TEST_DIR + "/cach_pruned.qvox"
	doc.cach.clear()
	_write_bytes(pruned, QVoxFile.serialize(doc))
	var with_cach := _make_data(path).get_voxels_dict_snapshot()
	var no_cach := _make_data(pruned).get_voxels_dict_snapshot()
	assert_eq(no_cach, with_cach, "删掉 CACH 不应改变世界语义")


# ----------------------------------------------------------------------------
# ⑤ LOD 是 CACH（派生数据），不是 VOX0 模型
# ----------------------------------------------------------------------------

## 粗层块往返：落盘为 CACH，重载后来源未变 → 直接命中（不重算）。
## 同时钉死"世界文件里只有 model 0"——LOD 一旦被写成模型，就会污染
## MeshLibrary 的 split_by_model 与 NODE 的 model_id 引用空间。
func test_lod_is_cach_not_model_and_roundtrips() -> void:
	var path := TEST_DIR + "/lod.qvox"
	var s := _make_stream(path)
	var ck := Vector3i.ZERO
	s.save_chunk(ck, _block_with(Vector3i(1, 1, 1), 1), 0)
	var coarse := _block_with(Vector3i(3, 3, 3), 1)
	s.save_chunk(Vector3i.ZERO, coarse, 1)
	s.flush()

	var doc := _read_doc(path)
	assert_true(doc != null, "文件应可解析")
	if doc == null:
		return
	assert_eq(doc.models.size(), 1, "世界文件只应有 model 0（LOD 不得成为模型）")
	assert_true(doc.models.has(0), "model 0 应在")
	assert_true(doc.models.has(1) == false, "不得有 lod=1 的 model")
	assert_eq(doc.cach.size(), 1, "粗层缓存应恰好是一个 CACH 块")

	var s2 := _make_stream(path)
	assert_true(s2.has_chunk(Vector3i.ZERO, 1), "来源未变 → 粗层缓存应命中")
	assert_eq(s2.load_chunk(Vector3i.ZERO, 1), coarse, "粗层数据应逐体素一致")
	assert_true(s2.has_chunk(ck, 0), "LOD0 权威数据应同时可读")


## 来源变更（LOD0 被编辑）→ 粗层缓存按 §6 规则 1 自动失效，不得把过期数据当有效缓存。
func test_lod_cache_invalidated_when_source_changes() -> void:
	var path := TEST_DIR + "/lod_stale.qvox"
	var s := _make_stream(path)
	var ck := Vector3i.ZERO
	s.save_chunk(ck, _block_with(Vector3i(1, 1, 1), 1), 0)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(3, 3, 3), 1), 1)
	s.flush()

	# 改 LOD0 的一个体素 → 粗层缓存的来源 CRC 变化
	var s2 := _make_stream(path)
	var edited := s2.load_chunk(ck, 0)
	edited[VoxelChunk.buf_index(2, 2, 2)] = 1
	s2.save_chunk(ck, edited, 0)
	s2.flush()

	var s3 := _make_stream(path)
	assert_false(s3.has_chunk(Vector3i.ZERO, 1), "来源变更后粗层缓存应判失效（等重新降采样）")
	assert_true(s3.has_chunk(ck, 0), "LOD0 权威数据不受影响")


## 删光全部 CACH（§6 的定义：删掉语义为零）→ 世界数据完全相同，只是没有预热缓存。
func test_deleting_all_cach_keeps_world_semantics() -> void:
	var path := TEST_DIR + "/lod_cach.qvox"
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(5, 5, 5), 1), 0)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(3, 3, 3), 1), 1)
	s.flush()

	var doc := _read_doc(path)
	assert_true(doc != null and doc.cach.size() == 1, "应写出一个 LOD CACH")
	if doc == null:
		return

	var pruned := TEST_DIR + "/lod_cach_pruned.qvox"
	doc.cach.clear()
	_write_bytes(pruned, QVoxFile.serialize(doc))

	assert_eq(_make_data(pruned).get_voxels_dict_snapshot(),
			_make_data(path).get_voxels_dict_snapshot(),
			"删掉全部 CACH 不应改变世界语义（§6）")
	# 缓存既然被删，粗层就应"未命中"（调用方会重新降采样），而不是读出错数据
	var s2 := _make_stream(pruned)
	assert_false(s2.has_chunk(Vector3i.ZERO, 1), "删掉 CACH 后粗层应未命中（可重算）")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 造一个挂了文件流的 VoxelData。材质表给 2 条（索引 0 = 空占位 + 索引 1 可用），
## 使体素值 1 通过 QVox 的 MATE 索引校验（VOX0 内材质值必须 < entry_count）。
func _make_data(path: String) -> VoxelData:
	var s := QVoxStream.new()
	s.file_path = path
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var d := VoxelData.new()
	d.materials = mats
	d.stream = s
	return d


## 空气材质条目（MATE 条目 0 的规范形态）
func _air() -> Dictionary:
	return {"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0}


## 一个挂了材质表的文件流（直接用流而不经 VoxelData，聚焦存储层本身的契约）。
## 必须给足材质条目，否则 VOX0 内的材质值 1 会被语义校验判为"引用了不存在的材质"。
func _make_stream(path: String) -> QVoxStream:
	var s := QVoxStream.new()
	s.file_path = path
	s.set_materials([_air(), _air()])
	return s


## 一个 32³ 块，仅 pos 处有材质 mat（其余为空气）。CHUNK_VOLUME 同时是 LOD 大格的体积。
func _block_with(pos: Vector3i, mat: int) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	buf[VoxelChunk.buf_index(pos.x, pos.y, pos.z)] = mat
	return buf


## 写一个带 CACH / 未知块的世界文件（一个 chunk，含单个体素）。
## CACH 用非 LODS 的 kind，使其走"格式层解析、QVoxStream 不认识"的路径——
## 这正是"别人的缓存也要能原样搬运"的场景。
func _write_world_with_cach(path: String) -> void:
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": VoxelChunk.CHUNK_SIZE,
		"up_axis": QVoxSpec.DEFAULT_UP_AXIS,
	}
	doc.materials = [_air(), _air()]
	doc.models = {"0": {Vector3i.ZERO: _block_with(Vector3i(1, 1, 1), 1)}}
	doc.cach = [{
		"kind": "mesh",
		"algo_version": 1,
		"source_crc": [],
		"payload": "lods".to_utf8_buffer(),
	}]
	doc.unknown_blocks = {"ZZZZ": ["opaque".to_utf8_buffer()]}
	_write_bytes(path, QVoxFile.serialize(doc))


func _read_doc(path: String) -> QVoxFile.QVoxDocument:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return QVoxFile.parse_with_index(bytes)


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


## 去掉封装带来的尾部零填充，得到"内容"字节（仅适用于内容不以零结尾的负载）
func _strip_trailing_zeros(payload: PackedByteArray) -> PackedByteArray:
	var out := payload.duplicate()
	while out.size() > 0 and out[out.size() - 1] == 0:
		out.remove_at(out.size() - 1)
	return out


## 递归删除一个 user:// 目录（仅用于测试临时目录收尾）
func _remove_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path.path_join(name)))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
