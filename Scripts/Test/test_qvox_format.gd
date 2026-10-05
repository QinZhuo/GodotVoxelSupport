extends TestCase

## QVox 格式一致性测试（编辑器进程即可，无需游戏进程）。
##
## 覆盖的是"实现是否兑现规范"这件事本身，而不是体素业务：
##   · 常量单一事实源（通道宽度）与编解码往返；
##   · 整文件 serialize ↔ parse 往返；
##   · HEAD 能力门：require 含未支持块 → 拒绝；channels ≠ 1 → 拒绝（§3.1 / §10）；
##   · CACH 作为一等块的结构往返与损坏处置（§6 / §9），未知块的不透明保真搬运；
##   · 仓库样例 .qvox 能被当前读取器以 CRC 校验开启的方式读入。
##
## 之所以把样例纳入测试：样例是"格式的活体示例"，一旦写入端与读取端口径漂移
## （历史上 CRC 覆盖范围就漂移过一次），它们会最先变成读不进来的废文件。
## 用独立于写入端的读取路径去读它们，等于一次低成本的跨实现交叉校验。

const SAMPLES_DIR := "res://demo/samples"


# ----------------------------------------------------------------------------
# 常量 / 编解码
# ----------------------------------------------------------------------------

func test_spec_channel_constants() -> void:
	assert_eq(QVoxSpec.CHANNEL_BPP, 16, "支配通道 bpp")
	assert_eq(QVoxSpec.CHANNEL_BYTES, 2, "支配通道每体素字节数")
	assert_eq(QVoxSpec.SUPPORTED_CHANNEL_COUNT, 1, "当前版本通道数")


## 四个编解码各自 pack → unpack 必须无损。用高/低熵两种块各扫一遍，
## 保证 pick_codec 真的会选到 RUN / DENSE / INDEXED / SOLID 而不是只测了某一个。
func test_codec_roundtrip() -> void:
	var b := 32
	var n := b * b * b

	var solid := PackedInt32Array()
	solid.resize(n)
	for i in n:
		solid[i] = 7

	var dense := PackedInt32Array()
	dense.resize(n)
	for i in n:
		dense[i] = (i * 2654435761) % 500   # 高熵且取值跨度 >255，逼迫 DENSE（INDEXED 被跨度预筛淘汰）

	var runs := PackedInt32Array()
	runs.resize(n)
	for i in n:
		runs[i] = 1 if (i / (b * 4)) % 2 == 0 else 2   # 层状，逼迫 RUN

	var few := PackedInt32Array()
	few.resize(n)
	for i in n:
		few[i] = [1, 1, 1, 2, 3][i % 5]   # 少量取值，INDEXED 有机会胜出

	for pair in [["solid", solid], ["dense", dense], ["runs", runs], ["few", few]]:
		var name: String = pair[0]
		var buf: PackedInt32Array = pair[1]
		var pick := QVoxBlockCodec.pick_codec(buf, n)
		var codec: int = int(pick[0])
		assert_ne(codec, QVoxSpec.CODEC_EMPTY, "%s 不应被判为空块" % name)
		var payload := QVoxBlockCodec.pack(codec, buf, n)
		var back := QVoxBlockCodec.unpack(codec, payload, n)
		assert_eq(back.size(), n, "%s 解包长度" % name)
		assert_eq(back, buf, "%s 往返不一致（codec=%d）" % [name, codec])


## 损坏负载必须被判定为解包失败（返回空），而不是静默产出垃圾。
func test_codec_rejects_corrupt() -> void:
	assert_true(QVoxBlockCodec.unpack(QVoxSpec.CODEC_EMPTY, PackedByteArray(), 8).is_empty(),
			"codec=0 应解包失败")
	assert_true(QVoxBlockCodec.unpack(QVoxSpec.CODEC_DENSE, PackedByteArray([1, 2]), 8).is_empty(),
			"DENSE 负载不足应解包失败")
	assert_true(QVoxBlockCodec.unpack(QVoxSpec.CODEC_RUN, PackedByteArray([255, 255, 255, 255]), 8).is_empty(),
			"RUN count 荒谬应解包失败")


# ----------------------------------------------------------------------------
# 整文件往返
# ----------------------------------------------------------------------------

func test_file_roundtrip() -> void:
	var orig := _make_doc()
	var bytes := QVoxFile.serialize(orig)
	var rep := QVoxFile.QVoxReport.new()
	var doc: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(doc != null, "往返解析应成功（%s）" % rep.summary())
	if doc == null:
		return
	assert_true(rep.ok(), "往返不应有 FATAL（%s）" % rep.summary())
	assert_eq(doc.materials.size(), orig.materials.size(), "材质条目数")
	assert_true(doc.models.has(0), "应含 model 0")
	var blocks: Dictionary = doc.models[0]
	assert_true(blocks.has(Vector3i(0, 0, 0)), "应含块 (0,0,0)")
	assert_eq(blocks[Vector3i(0, 0, 0)], orig.models[0][Vector3i(0, 0, 0)], "块内容往返")


# ----------------------------------------------------------------------------
# HEAD 能力门（§3.1 / §10）
# ----------------------------------------------------------------------------

## require 声明了本读者处理不了的块类型 → 拒绝整个文件（不许静默跳过）。
func test_require_unknown_type_rejected() -> void:
	var doc := _make_doc()
	doc.head["require"] = ["SKEL"]
	var bytes := QVoxFile.serialize(doc)
	var rep := QVoxFile.QVoxReport.new()
	var parsed: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(parsed == null, "require 含未知块类型应拒绝整个文件")
	assert_true(_errors_contain(rep, "require"), "应在 errors 里说明是 require（%s）" % rep.summary())


## require 只声明已知类型 → 正常读入。
func test_require_known_type_accepted() -> void:
	var doc := _make_doc()
	doc.head["require"] = ["MATE", "VOX0", "NODE", "CACH"]
	var bytes := QVoxFile.serialize(doc)
	var rep := QVoxFile.QVoxReport.new()
	var parsed: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(parsed != null, "require 全为已知类型应可读入（%s）" % rep.summary())


## channels 数 ≠ 1 → 拒绝（而不是按单通道猜测解码，"接受却读错"）。
func test_multichannel_rejected() -> void:
	var doc := _make_doc()
	doc.head["channels"] = [
		{"name": "material", "bpp": 16},
		{"name": "sdf", "bpp": 8},
	]
	var bytes := QVoxFile.serialize(doc)
	var rep := QVoxFile.QVoxReport.new()
	var parsed: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(parsed == null, "多通道应拒绝整个文件")
	assert_true(_errors_contain(rep, "channels"), "应在 errors 里说明是 channels（%s）" % rep.summary())


## up_axis 非法 → 不拒绝文件，只告警（§3.1）。
func test_bad_up_axis_warns_only() -> void:
	var doc := _make_doc()
	doc.head["up_axis"] = "w"
	var bytes := QVoxFile.serialize(doc)
	var rep := QVoxFile.QVoxReport.new()
	var parsed: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(parsed != null, "非法 up_axis 不应拒绝文件")
	assert_true(_warnings_contain(rep, "up_axis"), "应就 up_axis 告警（%s）" % rep.summary())


# ----------------------------------------------------------------------------
# CACH / 未知块：不透明保真搬运
# ----------------------------------------------------------------------------

## CACH 是一等块（§6：结构可解析），未知块是不透明搬运；两者往返都必须保真。
func test_cach_and_unknown_passthrough() -> void:
	var doc := _make_doc()
	# CACH：8 字节定长前置（kind/algo_version/source_count）+ source_crc[] + 写入方自定义负载
	var data := "hello-cache".to_utf8_buffer()
	doc.cach = [{
		"kind": "mesh",
		"algo_version": 2,
		"source_crc": [0x00FA12C4, 0xDEADBEEF],
		"payload": data,
	}]
	doc.unknown_blocks["ZZZZ"] = ["opaque".to_utf8_buffer()]

	var bytes := QVoxFile.serialize(doc)
	var rep := QVoxFile.QVoxReport.new()
	var doc1: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	assert_true(doc1 != null, "含 CACH/未知块的文件应可读入（%s）" % rep.summary())
	if doc1 == null:
		return
	assert_eq(doc1.cach.size(), 1, "CACH 应被解析为一等块（而非未知块）")
	assert_true(doc1.unknown_blocks.has("ZZZZ"), "未知块应被原样留存")
	if doc1.cach.size() == 1:
		var c: Dictionary = doc1.cach[0]
		assert_eq(String(c["kind"]), "mesh", "kind 往返")
		assert_eq(int(c["algo_version"]), 2, "algo_version 往返")
		assert_eq(c["source_crc"], [0x00FA12C4, 0xDEADBEEF], "source_crc 往返")
		# 顶层块 payload 按规范含尾部零填充（length 含填充），故比较"内容"而非原始长度。
		assert_eq(_strip_trailing_zeros(c["payload"]), data, "CACH 内容逐字节保留")

	# 再写一遍：两者都必须还在
	var bytes2 := QVoxFile.serialize(doc1)
	var rep2 := QVoxFile.QVoxReport.new()
	var doc2: QVoxFile.QVoxDocument = QVoxFile.parse(bytes2, true, rep2, true)
	assert_true(doc2 != null, "二次往返应可读入（%s）" % rep2.summary())
	if doc2 == null:
		return
	assert_eq(doc2.cach.size(), 1, "二次往返 CACH 仍在")
	assert_true(doc2.unknown_blocks.has("ZZZZ"), "二次往返未知块仍在")
	if doc2.cach.size() == 1:
		assert_eq(_strip_trailing_zeros(doc2.cach[0]["payload"]), data, "CACH 内容逐字节保留")


## 结构损坏的 CACH（source_count 超出块长）→ 只丢该块（DROP_BLOCK），不拒绝整个文件（§9）。
func test_malformed_cach_is_dropped_not_fatal() -> void:
	var doc := _make_doc()
	doc.cach = [{"kind": "mesh", "algo_version": 1, "source_crc": [], "payload": "x".to_utf8_buffer()}]
	var bytes := QVoxFile.serialize(doc)

	# 定位 CACH 块并把 source_count 改成远超 length 的值（结构损坏）
	var patched := false
	for bi in QVoxFile.scan_block_index(bytes):
		if bi["type"] == QVoxSpec.BLOCK_CACH:
			bytes.encode_u16(int(bi["offset"]) + QVoxSpec.BLOCK_HEADER_SIZE + 6, 0xFFFF)
			patched = true
			break
	assert_true(patched, "样例里应有 CACH 块")
	if not patched:
		return

	# CRC 已因改动而失效，故关闭校验，单独考察结构层处置
	var rep := QVoxFile.QVoxReport.new()
	var parsed: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, false, rep, true)
	assert_true(parsed != null, "损坏的 CACH 不应拒绝整个文件")
	if parsed == null:
		return
	assert_true(parsed.cach.is_empty(), "结构非法的 CACH 应被丢弃")
	assert_eq(rep.dropped_blocks, 1, "应计入一次 DROP_BLOCK（%s）" % rep.summary())
	assert_true(not parsed.models.is_empty(), "其余块不受影响")


# ----------------------------------------------------------------------------
# 仓库样例（跨实现交叉校验）
# ----------------------------------------------------------------------------

func test_samples_load_with_crc() -> void:
	var files := _list_qvox(SAMPLES_DIR)
	assert_true(not files.is_empty(), "%s 下应至少有一个 .qvox 样例" % SAMPLES_DIR)
	for path in files:
		var f := FileAccess.open(str(path), FileAccess.READ)
		assert_true(f != null, "无法打开样例 %s" % path)
		if f == null:
			continue
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var rep := QVoxFile.QVoxReport.new()
		var doc: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
		assert_true(doc != null, "%s 应能被读入（CRC 开启）：%s" % [path.get_file(), rep.summary()])
		if doc == null:
			continue
		assert_true(rep.ok(), "%s 不应报 FATAL：%s" % [path.get_file(), rep.summary()])
		assert_true(not doc.models.is_empty(), "%s 应含至少一个模型" % path.get_file())
		# HEAD 的 qvox 必须是**第一个键**（§3.1）：样例常因手改/旧工具而违反。
		assert_true(_head_qvox_first(bytes), "%s 的 HEAD JSON 首键必须是 qvox" % path.get_file())


# ----------------------------------------------------------------------------
# QVoxStream 端到端（写盘 → 新实例回读 → 擦除 → 增量写盘 → 再回读）
# ----------------------------------------------------------------------------

const TEST_DIR := "user://qvox_test"


## 每个用例后无条件收尾（runner 保证调用）：清掉测试目录，避免残留污染下次运行。
func cleanup() -> void:
	_remove_dir(TEST_DIR)


func test_stream_end_to_end() -> void:
	_remove_dir(TEST_DIR)
	var path := TEST_DIR + "/world.qvox"
	var n := 32 * 32 * 32
	var ck_a := Vector3i(0, 0, 0)
	var ck_b := Vector3i(1, 0, 0)

	var buf_a := PackedInt32Array()
	buf_a.resize(n)
	for i in n:
		buf_a[i] = 1 + (i % 2)
	var buf_b := PackedInt32Array()
	buf_b.resize(n)
	for i in n:
		buf_b[i] = 3
	var buf_l1 := PackedInt32Array()
	buf_l1.resize(n)
	for i in n:
		buf_l1[i] = 2

	var s := QVoxStream.new()
	s.file_path = path
	s.set_materials([null, null, null, null])   # 4 个条目：体素值 1..3 均落在范围内
	s.save_chunk(ck_a, buf_a, 0)
	s.save_chunk(ck_b, buf_b, 0)
	s.save_chunk(Vector3i.ZERO, buf_l1, 1)      # lod=1 → model 1
	s.flush()
	assert_true(FileAccess.file_exists(path), "应写出 .qvox 文件")

	# 新实例回读：磁盘是权威，内存为空。
	var r := QVoxStream.new()
	r.file_path = path
	assert_eq(r.load_chunk(ck_a, 0), buf_a, "lod0 chunk A 回读")
	assert_eq(r.load_chunk(ck_b, 0), buf_b, "lod0 chunk B 回读")
	assert_eq(r.load_chunk(Vector3i.ZERO, 1), buf_l1, "lod1 block 回读")
	assert_true(r.has_chunk(ck_a, 0), "has_chunk(A) 应为真")

	# 擦除一块 → 增量写盘（第二次 flush 走 serialize_incremental）→ 再回读。
	r.erase_chunk(ck_b, 0)
	r.flush()

	var r2 := QVoxStream.new()
	r2.file_path = path
	assert_eq(r2.load_chunk(ck_a, 0), buf_a, "擦除后 A 仍应存在")
	assert_true(r2.load_chunk(ck_b, 0).is_empty(), "擦除后 B 应消失")
	assert_eq(r2.load_chunk(Vector3i.ZERO, 1), buf_l1, "擦除后 lod1 数据不受影响")

	# 异步取数路径：T2 把「登记 / 去重 / 取出」的簿记上提到了 VoxelStream 基类，
	# 而渲染器的流式加载正是走这条路，必须有覆盖（此前完全没有）。
	r2.request_chunk_async(ck_a, 0)
	assert_true(r2.is_chunk_pending(ck_a, 0), "异步请求应登记为在途")
	var ready := r2.poll_all_ready(8)
	assert_eq(ready.size(), 1, "应取回 1 项")
	if ready.size() == 1:
		assert_eq(ready[0][0], 0, "取回项的 lod")
		assert_eq(ready[0][1], ck_a, "取回项的 chunk_key")
		assert_eq(ready[0][2], buf_a, "取回的缓冲应与写入一致")
	assert_true(not r2.is_chunk_pending(ck_a, 0), "取回后不应仍在途")

	# 请求一个不存在的 chunk：不产出结果，但登记同样要被消费掉（否则渲染器会一直等它）。
	r2.request_chunk_async(Vector3i(9, 9, 9), 0)
	assert_eq(r2.poll_all_ready(8).size(), 0, "不存在的 chunk 不应产出结果")
	assert_true(not r2.is_chunk_pending(Vector3i(9, 9, 9), 0), "空块请求也应被消费")

	# 文件本身仍应是合法 .qvox（用独立读取路径复核一次）
	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "应能打开写出的文件")
	if f != null:
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var rep := QVoxFile.QVoxReport.new()
		var doc: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
		assert_true(doc != null and rep.ok(), "写出的文件应能通过解析与校验：%s" % rep.summary())
		if doc != null:
			# 回归：加载后直接 flush（本例走擦除→增量写）不得改写材质。
			# 曾经的 bug 是把已加载的 MATE Dictionary 当成 VoxelMaterial 重新解释 → 全部变白。
			for e in doc.materials:
				assert_eq(int((e as Dictionary).get("rgba", 0)), 0,
						"load→flush 不应改写材质（白色覆写回归）")


# ----------------------------------------------------------------------------
# .qvox 作为一等资产：解析 → VoxAsset → VoxelData / Mesh（复用导入管线）
# ----------------------------------------------------------------------------

## 四种导入器都必须把 .qvox 当作可识别扩展名，且**不能丢掉 .vox**（否则破坏既有导入）。
##
## 【为什么用 load 而不是类名】全局注册类的可见性依赖编辑器完成一次文件系统扫描；
## 用路径加载则与注册时机无关，测试在任何时刻都稳定可跑（也顺带验证脚本可加载）。
func test_importers_recognize_qvox() -> void:
	var paths := [
		"res://addons/VoxelSupport/Importers/VoxelNoopImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelMeshImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelMeshLibraryImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelDataImporter.gd",
	]
	for p in paths:
		var script: Script = load(p)
		assert_true(script != null, "%s 应能加载" % p)
		if script == null:
			continue
		var imp = script.new()
		var exts: Array = imp._get_recognized_extensions()
		assert_true("qvox" in exts, "%s 应识别 qvox" % p.get_file())
		assert_true("vox" in exts, "%s 应仍识别 vox" % p.get_file())


## 样例经 VoxAsset.from_asset 必须解析成非空 VoxAsset（models + materials）。
func test_qvox_access_samples() -> void:
	var files := _list_qvox(SAMPLES_DIR)
	assert_true(not files.is_empty(), "应有样例")
	for path in files:
		var vox := VoxAsset.from_asset(str(path))
		assert_true(vox != null, "%s 应能解析" % path.get_file())
		if vox == null:
			continue
		assert_true(vox.models.size() > 0, "%s 应至少解析出一个 model" % path.get_file())
		var total := 0
		for m in vox.models:
			total += (m as VoxAsset.VoxelModel).voxels.size()
		assert_true(total > 0, "%s 应有非空体素" % path.get_file())
		assert_true(vox.materials.size() >= 2, "%s 应带回材质表" % path.get_file())


## .qvox → VoxAsset → VoxelData：与 .vox 同一条导入路径。
func test_qvox_to_voxeldata() -> void:
	var path := SAMPLES_DIR + "/deer.qvox"
	assert_true(FileAccess.file_exists(path), "样例 deer.qvox 应存在")
	if not FileAccess.file_exists(path):
		return
	assert_true("qvox" in VoxAsset.SUPPORTED_EXTENSIONS and "vox" in VoxAsset.SUPPORTED_EXTENSIONS,
			"扩展名列表应同时含 qvox 与 vox")
	var vox := VoxAsset.from_asset(path)
	assert_true(vox != null, "应能从 .qvox 解析出 VoxAsset")
	if vox == null:
		return
	var data := VoxelData.from_voxel_data(vox, 0, true)
	assert_true(data != null, "应能从 .qvox 构造 VoxelData")
	if data == null:
		return
	assert_true(data.grid_size.x > 0 and data.grid_size.y > 0 and data.grid_size.z > 0,
			"grid_size 应为正（%s）" % str(data.grid_size))


## .qvox → 网格：用 VoxelMeshImporter 的真实默认选项跑一遍生成。
func test_qvox_mesh_import() -> void:
	var path := SAMPLES_DIR + "/deer.qvox"
	if not FileAccess.file_exists(path):
		assert_true(false, "样例 deer.qvox 应存在")
		return
	var vox := VoxAsset.from_asset(path)
	if vox == null:
		assert_true(false, "应能从 .qvox 解析出 VoxAsset")
		return
	var opts := {}
	for o in VoxelMeshImporter.new()._get_import_options("", false):
		opts[o["name"]] = o["default_value"]
	var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh(vox, opts, path)
	assert_true(mesh != null, "应为 .qvox 生成网格")
	if mesh != null:
		assert_true(mesh.get_surface_count() > 0, "生成的网格应有 surface")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

func _make_doc() -> QVoxFile.QVoxDocument:
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": 32,
		"up_axis": "y",
	}
	# 3 个材质条目（含全零条目 0），使体素值 1/2 合法。
	doc.materials = [
		{"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0},
		{"rgba": 0xFF0000FF, "metal": 0, "rough": 200, "hardness": 80, "mass": 64, "e_r": 0, "e_g": 0, "e_b": 0},
		{"rgba": 0x00FF00FF, "metal": 10, "rough": 100, "hardness": 40, "mass": 30, "e_r": 5, "e_g": 6, "e_b": 7},
	]
	var n := 32 * 32 * 32
	var buf := PackedInt32Array()
	buf.resize(n)
	for i in n:
		buf[i] = (i % 3)   # 0 / 1 / 2
	doc.models = {0: {Vector3i(0, 0, 0): buf}}
	return doc


func _errors_contain(rep: QVoxFile.QVoxReport, needle: String) -> bool:
	for e in rep.errors:
		if str(e).contains(needle):
			return true
	return false


func _warnings_contain(rep: QVoxFile.QVoxReport, needle: String) -> bool:
	for w in rep.warnings:
		if str(w).contains(needle):
			return true
	return false


func _list_qvox(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".qvox"):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 递归删除一个 user:// 目录（仅用于测试临时目录收尾）。
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


## 去掉封装带来的尾部零填充，得到"内容"字节（仅适用于内容不以零结尾的负载）。
func _strip_trailing_zeros(payload: PackedByteArray) -> PackedByteArray:
	var out := payload.duplicate()
	while out.size() > 0 and out[out.size() - 1] == 0:
		out.remove_at(out.size() - 1)
	return out


## 只读文件头，判断 HEAD 块的 JSON 是否以 "qvox" 为第一个键（§3.1）。
## 独立于 QVoxFile 实现，避免"用被测对象验证被测对象"。
func _head_qvox_first(bytes: PackedByteArray) -> bool:
	if bytes.size() < QVoxSpec.SIGNATURE_SIZE + QVoxSpec.BLOCK_HEADER_SIZE:
		return false
	var at := QVoxSpec.SIGNATURE_SIZE
	var length := bytes.decode_u32(at)
	var type := PackedByteArray()
	for i in 4:
		type.append(bytes[at + 4 + i])
	if type.get_string_from_ascii() != QVoxSpec.BLOCK_HEAD:
		return false
	var payload := bytes.slice(at + QVoxSpec.BLOCK_HEADER_SIZE, at + QVoxSpec.BLOCK_HEADER_SIZE + length)
	while payload.size() > 0 and payload[payload.size() - 1] == 0:
		payload.remove_at(payload.size() - 1)
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not (parsed is Dictionary):
		return false
	var first_key := ""
	for k in (parsed as Dictionary):
		first_key = str(k)
		break
	return first_key == "qvox"