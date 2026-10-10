extends TestCase

## 存储 / 流式不变式测试（编辑器进程即可，无需游戏进程）。
## 这一层此前完全空白：既有用例覆盖了格式编解码与网格 / LOD 内核，却没有一项盯着
## "编辑 → 落盘 → 重载"这条数据通路。而重构（VoxelStream 退化为纯 IO、
## LOD 从独立 model 迁往 CACH）恰恰整条都动在这条路上，所以先把不变式钉死再动刀。
## 前四条从 QVoxelSource 的**公开行为**出发，不依赖 VoxelStream 的内部形态，
## 因此重构换掉 VoxelStream 接口后这些用例依然有效：
##   ① 编辑 → 卸载 → 重载：数据逐体素一致（磁盘为权威）
##   ② 空 chunk 不落盘；chunk 变空立即清盘（不留幽灵数据）
##   ③ 切换 stream：旧流上的未落盘数据先落盘，且内存数据不因切换而丢
##   ④ CACH / 未知块经"加载 → 改块 → 增量写盘"逐字节保真；且删掉 CACH 世界语义不变
##   ⑤ LOD 是 CACH 而非 VXEL 模型：往返命中、来源变更即失效、删 CACH 语义不变

const TEST_DIR := "user://voxel_stream_invariants"


## runner 在每个用例后无条件调用：清掉临时目录，避免残留污染下次运行。
func cleanup() -> void:
	_remove_dir(TEST_DIR)


# ① 编辑 → 卸载 → 重载

func test_edit_unload_reload_roundtrip() -> void:
	var path := TEST_DIR + "/roundtrip.qvx"
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
	d.flush()   # QVoxelStream 的 save 只改内存 + 置脏，真正写盘在 flush

	# 计数接口必须与 key 列表逐一对齐：HUD 每帧走 计数（不分配），调度走 key 列表。
	# 两者若分叉，HUD 会显示错误的"磁盘 chunk 数"而调度却按另一套数字行动。
	assert_eq(d.stream.get_chunk_count(0), d.stream.get_all_chunk_keys(0).size(),
			"get_chunk_count 应与 get_all_chunk_keys 一致")
	assert_eq(d.get_unloaded_chunk_count(), d.get_unloaded_chunk_keys().size(),
			"未加载计数应与未加载 key 列表一致")
	assert_eq(d.get_unloaded_chunk_count(), 1, "此时恰有 1 个 chunk 只在流中")

	# 同实例：缺数据的 chunk 应从磁盘自动载回，读语义不变
	assert_eq(d.get_voxel(positions[0]), 1, "同实例重载后材质应一致")
	assert_eq(d.get_voxels_dict_snapshot(), edited, "同实例重载后体素集合应一致")

	# 新实例：完全从磁盘读（磁盘为权威）
	var r := _make_data(path)
	assert_eq(r.get_voxels_dict_snapshot(), edited, "新实例从磁盘读到的世界应一致")
	assert_true(r.has_chunk(ck), "新实例应认为该 chunk 有数据")


# ② 空 chunk 不落盘 / 变空立即清盘

func test_empty_chunk_is_not_persisted_and_is_erased() -> void:
	var path := TEST_DIR + "/empty.qvx"
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


# ③ 切换 stream 不丢数据

func test_switch_stream_does_not_lose_data() -> void:
	var path_a := TEST_DIR + "/switch_a.qvx"
	var path_b := TEST_DIR + "/switch_b.qvx"
	var d := _make_data(path_a)
	var ck := Vector3i.ZERO
	var p := Vector3i(2, 3, 4)
	d.set_voxel(p, 1, false)   # 只在内存，未 flush

	var b := QVoxelStream.new()
	b.file_path = path_b
	d.stream = b               # 切换：旧流先落盘，再挂新流

	# ③-a 旧流必须已落盘（切换时 flush），否则切流即丢存档
	var a := QVoxelStream.new()
	a.file_path = path_a
	assert_true(a.has_chunk(ck, 0), "切换时应把旧流上的未落盘数据先落盘")
	assert_eq(a.load_chunk(ck, 0)[VoxelChunk.buf_index(2, 3, 4)], 1, "旧流内容应完好")

	# ③-b 内存数据不因切换而丢；且新流必须最终拿到它
	#（否则卸载时会被当成"磁盘已有"直接丢弃 → 静默丢数据）
	assert_eq(d.get_voxel(p), 1, "切换后内存数据不应丢失")
	d.flush()
	var b2 := QVoxelStream.new()
	b2.file_path = path_b
	assert_true(b2.has_chunk(ck, 0), "新流应收到仍在内存中的世界数据")


# ④ CACH / 未知块：增量写盘保真 + CACH 可删

func test_cach_and_unknown_blocks_survive_incremental_flush() -> void:
	var path := TEST_DIR + "/cach.qvx"
	_write_world_with_cach(path)

	# 加载 → 改一块 → flush：此时必然走增量写（未变块搬运磁盘原始字节）
	var d := _make_data(path)
	d.set_voxel(Vector3i(2, 2, 2), 1, false)
	d.flush()

	var doc := _read_doc(path)
	assert_true(doc != null, "改块后文件应仍可解析")
	if doc == null:
		return
	assert_true(doc.models.has(0), "VXEL 应仍在")
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
	var pruned := TEST_DIR + "/cach_pruned.qvx"
	doc.cach.clear()
	_write_bytes(pruned, QVoxelFile.serialize(doc))
	var with_cach := _make_data(path).get_voxels_dict_snapshot()
	var no_cach := _make_data(pruned).get_voxels_dict_snapshot()
	assert_eq(no_cach, with_cach, "删掉 CACH 不应改变世界语义")


# ⑤ LOD 是 CACH（派生数据），不是 VXEL 模型

## 粗层块往返：落盘为 CACH，重载后来源未变 → 直接命中（不重算）。
## 同时钉死"世界文件里只有 model 0"——LOD 一旦被写成模型，就会污染
## MeshLibrary 的 split_by_model 与 NODE 的 model_id 引用空间。
func test_lod_is_cach_not_model_and_roundtrips() -> void:
	var path := TEST_DIR + "/lod.qvx"
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
	var path := TEST_DIR + "/lod_stale.qvx"
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
	var path := TEST_DIR + "/lod_cach.qvx"
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(5, 5, 5), 1), 0)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(3, 3, 3), 1), 1)
	s.flush()

	var doc := _read_doc(path)
	assert_true(doc != null and doc.cach.size() == 1, "应写出一个 LOD CACH")
	if doc == null:
		return

	var pruned := TEST_DIR + "/lod_cach_pruned.qvx"
	doc.cach.clear()
	_write_bytes(pruned, QVoxelFile.serialize(doc))

	assert_eq(_make_data(pruned).get_voxels_dict_snapshot(),
			_make_data(path).get_voxels_dict_snapshot(),
			"删掉全部 CACH 不应改变世界语义（§6）")
	# 缓存既然被删，粗层就应"未命中"（调用方会重新降采样），而不是读出错数据
	var s2 := _make_stream(pruned)
	assert_false(s2.has_chunk(Vector3i.ZERO, 1), "删掉 CACH 后粗层应未命中（可重算）")


# ⑤-b 粗层缓存**按条目**增量维护（内存只留变了的条目，其余条目留在磁盘上）
# 此前 CACH 由调用方整体持有：任一条目变化都会把整批缓存重写一遍。现在流只留"变了的那几条"
# （_dirty_lod + 墓碑），未变的条目靠 serialize_incremental 原样搬运。以下三条钉死这个契约。

## 多条粗层缓存：只改一条 → 未改的那些必须仍在，且条目数不变。
## （若实现退化成"整批重写"，未变的条目会因为没有内存副本而被丢掉。）
func test_lod_multiple_entries_survive_incremental_flush() -> void:
	var path := TEST_DIR + "/lod_multi.qvx"
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(1, 1, 1), 1), 0)   # LOD0 来源
	var keys := [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(0, 0, 1)]
	for i in keys.size():
		s.save_chunk(keys[i], _block_with(Vector3i(i + 1, 2, 3), 1), 1)
	s.flush()

	# 只改其中一条 → 增量写（未变的 CACH 块应原地搬运）
	var r := _make_stream(path)
	var edited := _block_with(Vector3i(7, 7, 7), 1)
	r.save_chunk(keys[0], edited, 1)
	r.flush()

	var r2 := _make_stream(path)
	assert_eq(r2.get_chunk_count(1), keys.size(), "粗层条目数不应变化")
	assert_eq(r2.load_chunk(keys[0], 1), edited, "改动的粗层条目应已更新")
	for i in range(1, keys.size()):
		assert_eq(r2.load_chunk(keys[i], 1), _block_with(Vector3i(i + 1, 2, 3), 1),
				"未改动的粗层条目 %s 应仍在（按条目增量，不得整批重写）" % keys[i])


## 删一条粗层缓存 → 只该条消失，其余仍在（墓碑 + 按条目跳过旧块）。
func test_lod_entry_erase_keeps_others() -> void:
	var path := TEST_DIR + "/lod_erase.qvx"
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(1, 1, 1), 1), 0)
	var keys := [Vector3i.ZERO, Vector3i(1, 0, 0)]
	for i in keys.size():
		s.save_chunk(keys[i], _block_with(Vector3i(i + 1, 2, 3), 1), 1)
	s.flush()

	var r := _make_stream(path)
	r.erase_chunk(keys[0], 1)
	r.flush()

	var r2 := _make_stream(path)
	assert_false(r2.has_chunk(keys[0], 1), "被删的粗层条目应消失")
	assert_true(r2.has_chunk(keys[1], 1), "未删的粗层条目应仍在")
	assert_eq(r2.get_chunk_count(1), 1, "只应删掉一条")


## 写粗层缓存时，**别的写入方**的 CACH（非 LODS kind）必须逐字节保留。
## 这正是"按条目替换"相对旧"整批重写"的关键收益：整批重写会把不认识的缓存一并丢掉。
func test_lod_write_preserves_foreign_cach() -> void:
	var path := TEST_DIR + "/lod_foreign_cach.qvx"
	_write_world_with_cach(path)   # 文件里已有一个 kind="mesh" 的 CACH
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(3, 3, 3), 1), 1)
	s.flush()

	var doc := _read_doc(path)
	assert_true(doc != null, "文件应可解析")
	if doc == null:
		return
	assert_eq(doc.cach.size(), 2, "应保留旧的 mesh CACH 并新增一个 LODS CACH")
	var mesh_kept := false
	for e in doc.cach:
		if String(e.get("kind", "")) == "mesh":
			mesh_kept = _strip_trailing_zeros(e["payload"]) == "lods".to_utf8_buffer()
	assert_true(mesh_kept, "非 LODS 的 CACH 必须逐字节保留")


## flush 后粗层缓存同样"只剩索引"：覆盖层/墓碑清空，缓冲区不常驻（内存里只有 _cach_index
## 记着的"条目在哪、来源是什么"）。这是 LOD 侧与 _dirty_buffers 同一条不变式。
func test_lod_buffers_are_not_resident_after_flush() -> void:
	var path := TEST_DIR + "/lod_resident.qvx"
	var s := _make_stream(path)
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(1, 1, 1), 1), 0)   # LOD0 来源
	s.save_chunk(Vector3i.ZERO, _block_with(Vector3i(3, 3, 3), 1), 1)
	s.flush()

	assert_true(s._dirty_lod.is_empty(), "flush 后粗层写入覆盖层应为空（不得常驻缓冲区）")
	assert_true(s._deleted_lod.is_empty(), "flush 后粗层删除墓碑应为空")
	assert_true(s._cach_index.has(1), "flush 后应只剩 CACH 条目的位置索引")

	# 覆盖层为空 → 数据只能按索引从磁盘 seek 读回，仍须逐体素一致
	var r := _make_stream(path)
	assert_eq(r.load_chunk(Vector3i.ZERO, 1), _block_with(Vector3i(3, 3, 3), 1),
			"索引命中后应按块读盘还原粗层数据")


# ⑥ 存储层退化为"纯按块 IO"后必须成立的三条（此前靠全世界的解码镜像才成立）

## 多块往返：落盘后**流里不再留任何世界镜像**，每个块都只能按索引 seek 读盘还原。
## 这是"内存不随世界无界增长"的直接体现：干净数据只有磁盘 + 索引一份。
func test_many_chunks_read_back_from_disk() -> void:
	var path := TEST_DIR + "/many.qvx"
	var chunks := _many_chunks()
	var s := _make_stream(path)
	for ck in chunks:
		s.save_chunk(ck, chunks[ck], 0)
	s.flush()

	assert_true(s._dirty_buffers.is_empty(), "flush 后写入覆盖层应为空（不得常驻世界镜像）")
	assert_true(s._deleted.is_empty(), "flush 后删除墓碑应为空")

	# 新实例：没有覆盖层可依靠，每个块都得按块索引从文件读出来
	var r := _make_stream(path)
	assert_eq(r.get_chunk_count(0), chunks.size(), "磁盘上的块数应等于写入数")
	assert_eq(r.get_all_chunk_keys(0).size(), chunks.size(), "key 列表应与计数一致")
	for ck in chunks:
		assert_true(r.has_chunk(ck, 0), "块 %s 应存在" % ck)
		assert_eq(r.load_chunk(ck, 0), chunks[ck], "块 %s 应按块读盘还原" % ck)


## 删除的块留墓碑：删了就是删了，后续落盘也不得把它从索引里"复活"。
func test_deleted_chunk_does_not_resurrect() -> void:
	var path := TEST_DIR + "/delete.qvx"
	var ck_a := Vector3i.ZERO
	var ck_b := Vector3i(3, 0, 0)
	var s := _make_stream(path)
	s.save_chunk(ck_a, _block_with(Vector3i(1, 1, 1), 1), 0)
	s.save_chunk(ck_b, _block_with(Vector3i(2, 2, 2), 1), 0)
	s.flush()

	s.erase_chunk(ck_b, 0)
	assert_false(s.has_chunk(ck_b, 0), "擦除后应立刻不可见（墓碑生效）")
	s.flush()

	var r := _make_stream(path)
	assert_true(r.has_chunk(ck_a, 0), "未删的块应保留")
	assert_false(r.has_chunk(ck_b, 0), "删掉的块不得复活")
	assert_true(r.load_chunk(ck_b, 0).is_empty(), "删掉的块应读回空")

	# 再无改动地写一次：不得把已删的块带回来
	r.flush()
	var r2 := _make_stream(path)
	assert_false(r2.has_chunk(ck_b, 0), "再次落盘不得让已删块复活")
	assert_true(r2.has_chunk(ck_a, 0), "未删的块应仍在")


## 只改一块 → 增量写：其余块在磁盘上必须**逐字节不变**（未变子块是整段搬运的）。
func test_incremental_flush_leaves_other_chunks_intact() -> void:
	var path := TEST_DIR + "/incr.qvx"
	var chunks := _many_chunks()
	var ck_edited := Vector3i(1, 0, 0)
	var s := _make_stream(path)
	for ck in chunks:
		s.save_chunk(ck, chunks[ck], 0)
	s.flush()

	var edited: PackedInt32Array = (chunks[ck_edited] as PackedInt32Array).duplicate()
	edited[VoxelChunk.buf_index(9, 9, 9)] = 1
	var r := _make_stream(path)
	r.save_chunk(ck_edited, edited, 0)
	r.flush()

	var r2 := _make_stream(path)
	for ck in chunks:
		if ck == ck_edited:
			continue
		assert_eq(r2.load_chunk(ck, 0), chunks[ck], "未改动的块 %s 必须逐字节不变" % ck)
	assert_eq(r2.load_chunk(ck_edited, 0), edited, "改动的块应已落盘")
	assert_eq(r2.get_chunk_count(0), chunks.size(), "块数不应变化")


# 辅助

## 一组**内容互不相同且都非空**的块（键也各不相同），用于验证"只改一块"时其余块不动。
## 各块靠"体素个数 + 位置"区分，材质值统一取 1 —— 必须 < 材质表条目数（§9），否则
## 解析期会被判为"引用了不存在的材质"而整块丢弃（既不干净，也会掩盖真实问题）。
func _many_chunks() -> Dictionary:
	var out := {}
	var keys := [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1),
			Vector3i(-1, 0, 0), Vector3i(0, -1, 0), Vector3i(2, 3, 4), Vector3i(-2, 1, 5)]
	for i in keys.size():
		var buf := PackedInt32Array()
		buf.resize(VoxelChunk.CHUNK_VOLUME)
		for j in range(i + 1):
			buf[VoxelChunk.buf_index(j, i, j + 1)] = 1
		out[keys[i]] = buf
	return out

## 造一个挂了文件流的 QVoxelSource。材质表给 2 条（索引 0 = 空占位 + 索引 1 可用），
## 使体素值 1 通过 QVX 的 MATE 索引校验（VXEL 内材质值必须 < entry_count）。
func _make_data(path: String) -> QVoxelSource:
	var s := QVoxelStream.new()
	s.file_path = path
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var d := QVoxelSource.new()
	d.materials = mats
	d.stream = s
	return d


## 空气材质条目（MATE 条目 0 的规范形态）
func _air() -> Dictionary:
	return {"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0}


## 一个挂了材质表的文件流（直接用流而不经 QVoxelSource，聚焦存储层本身的契约）。
## 必须给足材质条目，否则 VXEL 内的材质值 1 会被语义校验判为"引用了不存在的材质"。
func _make_stream(path: String) -> QVoxelStream:
	var s := QVoxelStream.new()
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
## CACH 用非 LODS 的 kind，使其走"格式层解析、QVoxelStream 不认识"的路径——
## 这正是"别人的缓存也要能原样搬运"的场景。
func _write_world_with_cach(path: String) -> void:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = {
		"qvox": QVoxelSpec.VERSION,
		"channels": [{"name": QVoxelSpec.DOMINANT_CHANNEL, "bpp": QVoxelSpec.CHANNEL_BPP}],
		"block_size": VoxelChunk.CHUNK_SIZE,
		"up_axis": QVoxelSpec.DEFAULT_UP_AXIS,
	}
	doc.materials = [_air(), _air()]
	doc.models = {0: {Vector3i.ZERO: _block_with(Vector3i(1, 1, 1), 1)}}
	doc.cach = [{
		"kind": "mesh",
		"algo_version": 1,
		"source_crc": [],
		"payload": "lods".to_utf8_buffer(),
	}]
	doc.unknown_blocks = {"ZZZZ": ["opaque".to_utf8_buffer()]}
	_write_bytes(path, QVoxelFile.serialize(doc))


func _read_doc(path: String) -> QVoxelFile.QVoxelDocument:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return QVoxelFile.parse_with_index(bytes)


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
