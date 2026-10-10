extends TestCase

## QVX 格式一致性测试（编辑器进程即可，无需游戏进程）。
## 覆盖的是"实现是否兑现规范"这件事本身，而不是体素业务：
##   · 常量单一事实源（通道宽度）与编解码往返；
##   · 整文件 serialize ↔ parse 往返；
##   · HEAD 能力门：require 含未支持块 → 拒绝；channels ≠ 1 → 拒绝（§3.1 / §10）；
##   · CACH 作为一等块的结构往返与损坏处置（§6 / §9），未知块的不透明保真搬运；
##   · 仓库样例 .qvx 能被当前读取器以 CRC 校验开启的方式读入。
## 之所以把样例纳入测试：样例是"格式的活体示例"，一旦写入端与读取端口径漂移
## （历史上 CRC 覆盖范围就漂移过一次），它们会最先变成读不进来的废文件。
## 用独立于写入端的读取路径去读它们，等于一次低成本的跨实现交叉校验。

const SAMPLES_DIR := "res://demo/samples"


# 常量 / 编解码

func test_spec_channel_constants() -> void:
	assert_eq(QVoxelSpec.CHANNEL_BPP, 16, "支配通道 bpp")
	assert_eq(QVoxelSpec.CHANNEL_BYTES, 2, "支配通道每体素字节数")
	assert_eq(QVoxelSpec.SUPPORTED_CHANNEL_COUNT, 1, "当前版本通道数")


## 【跨语言常量镜像】CODEC_* 与 CHANNEL_BYTES 在原生侧另有一份
## （gdextension/src/voxel_native.cpp 的 QvoxCodec 枚举 / QVOX_CHANNEL_BPP，见那里的【常量单源】）。
## 跨语言共享不了编译期常量，只能**用行为反证**：把 QVoxelSpec 的取值送进原生接口，
## 看它是否恰好按规范里那个编解码动作。任一边改号或改位宽而另一边没跟 → 这里必红，
## 不必依赖人工比对两处数字。
func test_native_codec_id_mirror() -> void:
	var b := 32
	var n := b * b * b

	var uniform := PackedInt32Array()
	uniform.resize(n)
	for i in n:
		uniform[i] = 7

	var layered := PackedInt32Array()
	layered.resize(n)
	for i in n:
		layered[i] = 1 if (i / (b * 4)) % 2 == 0 else 2

	var few := PackedInt32Array()
	few.resize(n)
	for i in n:
		few[i] = [1, 1, 1, 2, 3][i % 5]

	var entropy := PackedInt32Array()
	entropy.resize(n)
	for i in n:
		entropy[i] = (i * 2654435761) % 500

	var cbytes := QVoxelSpec.CHANNEL_BYTES

	# 0 是保留值：原生必须不认（否则"空块"会被写成一份合法负载）
	assert_true(QVoxelBlockCodec.pack(QVoxelSpec.CODEC_EMPTY, uniform, n).is_empty(),
			"原生 codec 0 应是保留值（pack 返回空）")

	# SOLID / DENSE 的负载长度由规范唯一确定 → 一次钉住编号与位宽
	assert_eq(QVoxelBlockCodec.pack(QVoxelSpec.CODEC_SOLID, uniform, n).size(), cbytes,
			"原生 SOLID 应恰为 CHANNEL_BYTES 字节（编号或位宽漂移？）")
	assert_eq(QVoxelBlockCodec.pack(QVoxelSpec.CODEC_DENSE, entropy, n).size(), n * cbytes,
			"原生 DENSE 应恰为 N×CHANNEL_BYTES 字节（编号或位宽漂移？）")

	# RUN / INDEXED 的长度随数据而定，但一定远小于 DENSE → 用"必须压缩 + 往返无损"钉住编号
	for pair in [["RUN", QVoxelSpec.CODEC_RUN, layered], ["INDEXED", QVoxelSpec.CODEC_INDEXED, few]]:
		var name: String = pair[0]
		var codec: int = pair[1]
		var buf: PackedInt32Array = pair[2]
		var payload := QVoxelBlockCodec.pack(codec, buf, n)
		assert_true(payload.size() > 0 and payload.size() < n * cbytes,
				"原生 %s 应压缩编码（编号漂移？得到 %d 字节）" % [name, payload.size()])
		assert_eq(QVoxelBlockCodec.unpack(codec, payload, n), buf, "原生 %s 往返不一致" % name)


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
		var pick := QVoxelBlockCodec.pick_codec(buf, n)
		var codec: int = int(pick[0])
		assert_ne(codec, QVoxelSpec.CODEC_EMPTY, "%s 不应被判为空块" % name)
		var payload := QVoxelBlockCodec.pack(codec, buf, n)
		var back := QVoxelBlockCodec.unpack(codec, payload, n)
		assert_eq(back.size(), n, "%s 解包长度" % name)
		assert_eq(back, buf, "%s 往返不一致（codec=%d）" % [name, codec])


## 损坏负载必须被判定为解包失败（返回空），而不是静默产出垃圾。
func test_codec_rejects_corrupt() -> void:
	assert_true(QVoxelBlockCodec.unpack(QVoxelSpec.CODEC_EMPTY, PackedByteArray(), 8).is_empty(),
			"codec=0 应解包失败")
	assert_true(QVoxelBlockCodec.unpack(QVoxelSpec.CODEC_DENSE, PackedByteArray([1, 2]), 8).is_empty(),
			"DENSE 负载不足应解包失败")
	assert_true(QVoxelBlockCodec.unpack(QVoxelSpec.CODEC_RUN, PackedByteArray([255, 255, 255, 255]), 8).is_empty(),
			"RUN count 荒谬应解包失败")


# 整文件往返

func test_file_roundtrip() -> void:
	var orig := _make_doc()
	var bytes := QVoxelFile.serialize(orig)
	var rep := QVoxelFile.QVoxelReport.new()
	var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(doc != null, "往返解析应成功（%s）" % rep.summary())
	if doc == null:
		return
	assert_true(rep.ok(), "往返不应有 FATAL（%s）" % rep.summary())
	assert_eq(doc.materials.size(), orig.materials.size(), "材质条目数")
	assert_true(doc.models.has(0), "应含 model 0")
	var blocks: Dictionary = doc.models[0]
	assert_true(blocks.has(Vector3i(0, 0, 0)), "应含块 (0,0,0)")
	assert_eq(blocks[Vector3i(0, 0, 0)], orig.models[0][Vector3i(0, 0, 0)], "块内容往返")


# HEAD 能力门（§3.1 / §10）

## require 声明了本读者处理不了的块类型 → 拒绝整个文件（不许静默跳过）。
func test_require_unknown_type_rejected() -> void:
	var doc := _make_doc()
	doc.head["require"] = ["SKEL"]
	var bytes := QVoxelFile.serialize(doc)
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(parsed == null, "require 含未知块类型应拒绝整个文件")
	assert_true(_errors_contain(rep, "require"), "应在 errors 里说明是 require（%s）" % rep.summary())


## require 只声明已知类型 → 正常读入。
func test_require_known_type_accepted() -> void:
	var doc := _make_doc()
	doc.head["require"] = ["MATE", "VXEL", "NODE", "CACH"]
	var bytes := QVoxelFile.serialize(doc)
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(parsed != null, "require 全为已知类型应可读入（%s）" % rep.summary())


## channels 数 ≠ 1 → 拒绝（而不是按单通道猜测解码，"接受却读错"）。
func test_multichannel_rejected() -> void:
	var doc := _make_doc()
	doc.head["channels"] = [
		{"name": "material", "bpp": 16},
		{"name": "sdf", "bpp": 8},
	]
	var bytes := QVoxelFile.serialize(doc)
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(parsed == null, "多通道应拒绝整个文件")
	assert_true(_errors_contain(rep, "channels"), "应在 errors 里说明是 channels（%s）" % rep.summary())


## up_axis 非法 → 不拒绝文件，只告警（§3.1）。
func test_bad_up_axis_warns_only() -> void:
	var doc := _make_doc()
	doc.head["up_axis"] = "w"
	var bytes := QVoxelFile.serialize(doc)
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(parsed != null, "非法 up_axis 不应拒绝文件")
	assert_true(_warnings_contain(rep, "up_axis"), "应就 up_axis 告警（%s）" % rep.summary())


# CACH / 未知块：不透明保真搬运

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

	var bytes := QVoxelFile.serialize(doc)
	var rep := QVoxelFile.QVoxelReport.new()
	var doc1: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
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
	var bytes2 := QVoxelFile.serialize(doc1)
	var rep2 := QVoxelFile.QVoxelReport.new()
	var doc2: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes2, true, rep2, true)
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
	var bytes := QVoxelFile.serialize(doc)

	# 定位 CACH 块并把 source_count 改成远超 length 的值（结构损坏）
	var patched := false
	for bi in QVoxelFile.scan_block_index(bytes):
		if bi["type"] == QVoxelSpec.BLOCK_CACH:
			bytes.encode_u16(int(bi["offset"]) + QVoxelSpec.BLOCK_HEADER_SIZE + 6, 0xFFFF)
			patched = true
			break
	assert_true(patched, "样例里应有 CACH 块")
	if not patched:
		return

	# CRC 已因改动而失效，故关闭校验，单独考察结构层处置
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, false, rep, true)
	assert_true(parsed != null, "损坏的 CACH 不应拒绝整个文件")
	if parsed == null:
		return
	assert_true(parsed.cach.is_empty(), "结构非法的 CACH 应被丢弃")
	assert_eq(rep.dropped_blocks, 1, "应计入一次 DROP_BLOCK（%s）" % rep.summary())
	assert_true(not parsed.models.is_empty(), "其余块不受影响")


# 仓库样例（跨实现交叉校验）

func test_samples_load_with_crc() -> void:
	var files := _list_qvx(SAMPLES_DIR)
	assert_true(not files.is_empty(), "%s 下应至少有一个 .qvx 样例" % SAMPLES_DIR)
	for path in files:
		var f := FileAccess.open(str(path), FileAccess.READ)
		assert_true(f != null, "无法打开样例 %s" % path)
		if f == null:
			continue
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var rep := QVoxelFile.QVoxelReport.new()
		var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
		assert_true(doc != null, "%s 应能被读入（CRC 开启）：%s" % [path.get_file(), rep.summary()])
		if doc == null:
			continue
		assert_true(rep.ok(), "%s 不应报 FATAL：%s" % [path.get_file(), rep.summary()])
		assert_true(not doc.models.is_empty(), "%s 应含至少一个模型" % path.get_file())
		# HEAD 的 qvx 必须是**第一个键**（§3.1）：样例常因手改/旧工具而违反。
		assert_true(_head_qvox_first(bytes), "%s 的 HEAD JSON 首键必须是 qvox" % path.get_file())


# QVoxelStream 端到端（写盘 → 新实例回读 → 擦除 → 增量写盘 → 再回读）

const TEST_DIR := "user://qvx_test"


## 每个用例后无条件收尾（runner 保证调用）：清掉测试目录，避免残留污染下次运行。
func cleanup() -> void:
	_remove_dir(TEST_DIR)


func test_stream_end_to_end() -> void:
	_remove_dir(TEST_DIR)
	var path := TEST_DIR + "/world.qvx"
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

	var s := QVoxelStream.new()
	s.file_path = path
	s.set_materials([null, null, null, null])   # 4 个条目：体素值 1..3 均落在范围内
	s.save_chunk(ck_a, buf_a, 0)
	s.save_chunk(ck_b, buf_b, 0)
	s.save_chunk(Vector3i.ZERO, buf_l1, 1)      # lod=1 → CACH 派生缓存（不是 model 1）
	s.flush()
	assert_true(FileAccess.file_exists(path), "应写出 .qvx 文件")

	# 新实例回读：磁盘是权威，内存为空。
	var r := QVoxelStream.new()
	r.file_path = path
	assert_eq(r.load_chunk(ck_a, 0), buf_a, "lod0 chunk A 回读")
	assert_eq(r.load_chunk(ck_b, 0), buf_b, "lod0 chunk B 回读")
	assert_eq(r.load_chunk(Vector3i.ZERO, 1), buf_l1, "lod1 block 回读")
	assert_true(r.has_chunk(ck_a, 0), "has_chunk(A) 应为真")

	# 擦除一块 → 增量写盘（第二次 flush 走 serialize_incremental）→ 再回读。
	r.erase_chunk(ck_b, 0)
	r.flush()

	var r2 := QVoxelStream.new()
	r2.file_path = path
	assert_eq(r2.load_chunk(ck_a, 0), buf_a, "擦除后 A 仍应存在")
	assert_true(r2.load_chunk(ck_b, 0).is_empty(), "擦除后 B 应消失")
	# lod1 是 CACH（派生数据）：B 正是它的来源之一，来源集合变了 §6 规则 1 就判失效。
	# 真实流程里 QVoxelSource 会立刻重算并覆盖它；这里直接操作存储层，故表现为"未命中"。
	# （曾经这里是 assert_eq(..., buf_l1)：那时 lod1 存成独立 model，没有来源校验。）
	assert_true(r2.load_chunk(Vector3i.ZERO, 1).is_empty(), "来源变更后 lod1 缓存应失效（§6）")

	# 异步取数路径：登记 / 去重 / 后台派发 / 回填全部集中在 QVoxelSource 的 VoxelAsyncLoader
	# （存储本身已不含任何异步接口），渲染器的流式加载正是走这条路，必须有覆盖。
	var dq := QVoxelSource.new()
	dq.stream = r2
	dq.request_chunk_async(ck_a, 0)
	assert_true(dq.is_chunk_pending(ck_a, 0), "异步请求应登记为在途")
	var ready := dq.poll_all_ready(8)
	assert_eq(ready.size(), 1, "应取回 1 项")
	if ready.size() == 1:
		assert_eq(ready[0][0], 0, "取回项的 lod")
		assert_eq(ready[0][1], ck_a, "取回项的 chunk_key")
		assert_eq(ready[0][2], buf_a, "取回的缓冲应与写入一致")
	assert_true(not dq.is_chunk_pending(ck_a, 0), "取回后不应仍在途")

	# 请求一个不存在的 chunk：不产出结果，但登记同样要被消费掉（否则渲染器会一直等它）。
	dq.request_chunk_async(Vector3i(9, 9, 9), 0)
	assert_eq(dq.poll_all_ready(8).size(), 0, "不存在的 chunk 不应产出结果")
	assert_true(not dq.is_chunk_pending(Vector3i(9, 9, 9), 0), "空块请求也应被消费")

	# 文件本身仍应是合法 .qvx（用独立读取路径复核一次）
	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "应能打开写出的文件")
	if f != null:
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var rep := QVoxelFile.QVoxelReport.new()
		var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
		assert_true(doc != null and rep.ok(), "写出的文件应能通过解析与校验：%s" % rep.summary())
		if doc != null:
			# 回归：加载后直接 flush（本例走擦除→增量写）不得改写材质。
			# 曾经的 bug 是把已加载的 MATE Dictionary 当成 VoxelMaterial 重新解释 → 全部变白。
			for e in doc.materials:
				assert_eq(int((e as Dictionary).get("rgba", 0)), 0,
						"load→flush 不应改写材质（白色覆写回归）")


# .qvx 作为一等资产：解析 → QVoxelAsset → QVoxelSource / Mesh
# （导入链路本身的用例在 test_qvox_import.gd；这里只钉"源格式 ↔ 适配器"的分派契约）

## 四种导入器都必须把 .qvx 当作可识别扩展名，且**不能丢掉 .vox**（否则破坏既有导入）。
## 【为什么用 load 而不是类名】全局注册类的可见性依赖编辑器完成一次文件系统扫描；
## 用路径加载则与注册时机无关，测试在任何时刻都稳定可跑（也顺带验证脚本可加载）。
## 【为什么逐项检查要挂在 is_editor_hint 上】四个导入器都是 `EditorImportPlugin` 子类，只能在
## 编辑器进程实例化：headless/CI 里 `script.new()` 返回 null，紧接着对 null 调
## `_get_recognized_extensions()` 会**中断整个用例**，后面的断言一条都不跑 —— 表现为"静默通过"。
## 所以这里显式判断：实例化不了就只钉共享列表（四个导入器共用 `VoxAsset.SUPPORTED_EXTENSIONS`），
## 编辑器进程里再逐项验证每个导入器真的把它报了出来。
func test_importers_recognize_qvx() -> void:
	var paths := [
		"res://addons/VoxelSupport/Importers/VoxelNoopImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelMeshImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelMeshLibraryImporter.gd",
		"res://addons/VoxelSupport/Importers/VoxelDataImporter.gd",
	]
	for p in paths:
		var script: Script = load(p)
		assert_true(script != null, "%s 应能加载" % p)
		if script == null or not Engine.is_editor_hint():
			continue
		var exts: Array = script.new()._get_recognized_extensions()
		assert_true("qvx" in exts, "%s 应识别 qvx" % p.get_file())
		assert_true("vox" in exts, "%s 应仍识别 vox" % p.get_file())
	assert_true("qvx" in VoxAsset.SUPPORTED_EXTENSIONS, "共享扩展名列表应含 qvx")
	assert_true("vox" in VoxAsset.SUPPORTED_EXTENSIONS, "共享扩展名列表应含 vox（不破坏既有导入）")


## 扩展名分派契约：`.qvx` 归 QVoxelAsset，`.vox` 归 VoxAsset，绝不互相冒充。
## 这条是"源格式与适配器必须形状匹配"的守门用例：VoxAsset 是 MagicaVoxel 场景图形状的
## 适配器，用它承载 .qvx 会丢掉 NODE 场景图与除第一个之外的所有模型（详见 QVoxelAsset 注释），
## 因此 from_asset() 遇到 .qvx 必须明确拒绝而不是返回一个丢信息的对象。
func test_source_format_dispatch() -> void:
	assert_true(QVoxelAsset.handles("res://a/b.qvx"), "QVoxelAsset 应认领 .qvx")
	assert_true(QVoxelAsset.handles("res://a/b.QVX"), "扩展名判定应大小写无关")
	assert_false(QVoxelAsset.handles("res://a/b.vox"), "QVoxelAsset 不应认领 .vox")
	assert_true("qvx" in VoxAsset.SUPPORTED_EXTENSIONS and "vox" in VoxAsset.SUPPORTED_EXTENSIONS,
			"扩展名列表应同时含 qvx 与 vox（四个导入器共用）")

	var sample := SAMPLES_DIR + "/deer.qvx"
	if FileAccess.file_exists(sample):
		assert_true(VoxAsset.from_asset(sample) == null, "VoxAsset.from_asset 必须拒绝 .qvx")
		assert_true(QVoxelAsset.from_file(sample) != null, "QVoxelAsset 应能解析同一文件")


# 相机与节点树（NODE 下的工程数据，§5.1 / qvx 3）
# 这一组钉死三件事：
#   ① 相机的字段**逐字段存活**，缺省只在缺失时补（文件里明写的 false 不能被改回来）；
#   ② 坏数据只丢它自己 —— 非对象项、不在白名单的投影、未知 kind 都不该拖垮整块；
#   ③ 编辑模型（QVoxelWorld）与文件之间的往返一致，且节点树是**嵌套**的（不再有下标与图层）。

func test_cameras_and_nested_nodes_roundtrip() -> void:
	var bytes := QVoxelFile.serialize(_make_doc_with_engineering_data())
	var rep := QVoxelFile.QVoxelReport.new()
	var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(doc != null, "应解析成功（%s）" % rep.summary())
	if doc == null:
		return
	var sg := doc.scene

	assert_eq(sg.cameras.size(), 2, "两台相机都要在")
	assert_eq(sg.cameras[0]["name"], "front")
	assert_eq(sg.cameras[0]["projection"], "ortho")
	assert_eq(sg.cameras[0]["size"], 128, "正交视高是可选字段，写了就留")
	assert_eq(sg.cameras[1]["projection"], "persp", "缺失的 projection 补缺省")
	assert_false(sg.cameras[1].has("size"), "没写的可选字段不凭空补出来（未设 ≠ 设成 0）")

	# 嵌套树：组是容器、模型是叶子，子节点在 children 里。**没有下标**正是 qvx 3 的要点 ——
	# 下标会随增删整体平移，一漏改就把节点挂到别的父下面（那类错既不报错、位置也看不出异常）。
	var root := _find_node(sg.nodes, "root")
	assert_eq(root.get("kind"), "group", "顶层是组")
	assert_false(root.has("visible"), "缺省 visible=true 不写出来（P2：缺省才是常态）")
	var body := _find_node(root.get("children", []), "body")
	assert_eq(body.get("kind"), "model", "子节点在父的 children 里")
	assert_eq(body.get("model_id"), 0, "模型下标存活")
	var steps: Array = body.get("steps", [])
	assert_eq(steps.size(), 1, "组内坐标是链上的一条")
	assert_eq(steps[0].get("type"), "PcgTransform", "条目认得出是哪种算子")
	assert_eq((steps[0].get("params") as Dictionary).get("offset"), [1.0, 2.0, 3.0],
			"组内坐标存活（JSON 数字读回是 float）")
	assert_false(body.has("children"), "模型是叶子 —— children 是冗余键，不该出现在模型上")


func test_cameras_lenient_and_validated() -> void:
	var doc := _make_doc()
	doc.node = {
		QVoxelSpec.NODE_CAMERAS_KEY: [{"projection": "weird"}, {"projection": "ortho"}],
		"nodes": [{"name": "a", "kind": "model", "model_id": 0}],
	}
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	var sg := parsed.scene

	assert_eq(sg.cameras[0]["projection"], "persp", "不在白名单的投影按缺省处理")
	assert_true(_warnings_contain(rep, "白名单"), "越白名单要告警")
	assert_eq(sg.nodes.size(), 1, "坏相机不该牵连节点树")


## 未知 kind 要连**子树**一起丢：子节点的坐标是相对它表达的，留下子节点等于把内容搬进一个
## 不存在的父坐标系里（§9：宁可少给，不可给错）。
func test_unknown_kind_drops_the_whole_subtree() -> void:
	var doc := _make_doc()
	doc.node = {
		"nodes": [
			{"name": "ok", "kind": "model", "model_id": 0},
			{"name": "weird", "kind": "warp",
					"children": [{"name": "inner", "kind": "model", "model_id": 0}]},
		],
	}
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	var sg := parsed.scene
	assert_eq(sg.nodes.size(), 1, "未知 kind 的节点被丢弃")
	assert_eq(sg.dropped_nodes, 2, "它和它的子树一起算丢弃（否则 inner 会飘到顶层）")
	assert_true(_warnings_contain(rep, "丢弃"), "丢弃要告警")


## 模型带 children 是冗余键（模型是叶子）：只清 children，不丢整个模型。
func test_model_with_children_keeps_the_model() -> void:
	var doc := _make_doc()
	doc.node = {"nodes": [{"name": "m", "kind": "model", "model_id": 0,
			"children": [{"name": "x", "kind": "model", "model_id": 0}]}]}
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	var n := _find_node(parsed.scene.nodes, "m")
	assert_false(n.is_empty(), "模型本身仍然可用")
	assert_false(n.has("children"), "冗余的 children 被清掉")


## "只有相机、还没有对象"是新建工程的常态，不该在 nodes 的提前返回里被丢掉。
func test_cameras_survive_without_nodes() -> void:
	var doc := _make_doc()
	doc.node = {QVoxelSpec.NODE_CAMERAS_KEY: [{"name": "front"}]}
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	assert_eq(parsed.scene.cameras.size(), 1, "没有 nodes 键不该连相机一起丢")
	assert_eq(parsed.scene.cameras[0]["name"], "front")
	assert_true(parsed.scene.nodes.is_empty(), "节点树为空")
	assert_false(_warnings_contain(rep, "nodes"), "缺 nodes 键 = 空世界，不是错误")


## 相机字段改一下要能撤销。
func test_world_camera_edit_is_undoable() -> void:
	var w := QVoxelWorld.create_empty()
	assert_eq(w.cameras().size(), 0, "新建世界没有相机")
	assert_eq(w.add_camera("front"), 0, "第一台相机")
	assert_eq(w.camera_field(0, "name"), "front")

	# 面板把它包成 QVoxelPropertyCommand(world, &"node")。这一条同时钉死了"写入必须整体替换"——
	# 就地改的话 before 会跟着变，撤销就撤了个寂寞。
	var cmd := QVoxelPropertyCommand.begin(w, &"node")
	assert_true(w.set_camera_field(0, "projection", "ortho"), "值变了 → 应产生撤销单位")
	assert_false(w.set_camera_field(0, "projection", "ortho"), "值没变 → 不该占一次撤销")
	assert_true(cmd.commit(), "整体替换 node 下的数组，浅快照才抓得住改前值")
	assert_eq(w.camera_field(0, "projection"), "ortho")
	cmd.undo()
	assert_eq(w.camera_field(0, "projection"), "persp", "撤销回到改前值")
	cmd.redo()
	assert_eq(w.camera_field(0, "projection"), "ortho")

	assert_true(w.remove_camera(0), "删相机")
	assert_eq(w.cameras().size(), 0)


func test_world_engineering_data_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var g := w.create_group("root")
	var o := w.create_model("body", Vector3i(8, 8, 8), g)
	o.fill_box(Vector3i.ZERO, Vector3i(3, 3, 3), mat)
	var solid := o.count_solid()   # 闭区间盒 → 4³，不写死数字，测的是"存活"而非某个计数
	# 组内坐标是一条链上条目（不再是节点字段）—— 它必须和别的条目一样往返
	o.add_modifier(QVoxelTransformModifier.of(PcgTransform.translate(Vector3i(1, 2, 3))))
	w.add_camera("front")
	assert_true(w.set_camera_field(0, "projection", "ortho"), "相机改成正交")
	assert_true(w.set_camera_field(0, "size", 128), "正交视高")

	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(
			QVoxelFile.serialize(w.to_document()), true, rep, true)
	assert_true(rep.warnings.is_empty(), "回环不该有任何告警（%s）" % str(rep.warnings))
	var w2 := QVoxelWorld.from_document(parsed)

	assert_eq(w2.cameras().size(), 1, "相机条数")
	assert_eq(w2.camera_field(0, "name"), "front")
	assert_eq(w2.camera_field(0, "projection"), "ortho")
	assert_eq(int(w2.camera_field(0, "size")), 128, "正交视高存活（JSON 数字读回是 float）")

	assert_eq(w2.nodes.size(), 1, "顶层只有那个组（模型是它的子节点，不是平级）")
	var g2 := w2.nodes[0] as QVoxelGroup
	assert_eq(g2.node_name, "root", "组名存活")
	assert_eq(g2.child_nodes.size(), 1, "组里的模型存活")
	var o2 := g2.child_nodes[0] as QVoxelModel
	assert_eq(o2.node_name, "body")
	assert_eq(o2.modifiers.size(), 1, "组内坐标是一条链上条目")
	var place := (o2.modifiers[0] as QVoxelTransformModifier).transform
	assert_eq(place.mode, PcgTransform.Mode.TRANSLATE, "它是平移条目")
	assert_eq(place.offset, Vector3i(1, 2, 3), "组内坐标存活")
	assert_eq(o2.count_solid(), solid, "体素存活")


## 链上的条目要跟着节点树一起往返 —— 这是 qvx 3 新增的 steps 字段。
## 【为什么连"输出盒尺寸"也一起断言】链的意义全在"它会改变求值结果"；只比条数等于没测，
## 参数读丢 / 旁通位读丢都能让条数一样而对不上。
func test_node_modifiers_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	w.add_material(Color.RED)
	var o := w.create_model("body", Vector3i(8, 8, 8))
	# 三条覆盖三种"该存活的东西"：合成方式（差集）/ 核的参数（平铺份数）/ 旁通位。
	# 差集挂在 SDF 条目上：体素域的变换型条目合成方式只能是「替换」（见 QVoxelDomain.chain_errors）。
	var hole := SdfSphere.new()
	hole.center = Vector3(4.0, 4.0, 4.0)
	hole.radius = 2.0
	o.add_modifier(QVoxelSdfModifier.of(hole, QVoxelDomain.Combine.SUBTRACT))
	o.add_modifier(QVoxelTransformModifier.of(PcgTransform.repeat(0, 3)))
	o.add_modifier(QVoxelTransformModifier.of(PcgTransform.mirror(1)))
	o.modifiers[2].enabled = false

	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(
			QVoxelFile.serialize(w.to_document()), true, rep, true)
	assert_true(rep.warnings.is_empty(), "回环不该有任何告警（%s）" % str(rep.warnings))
	var o2 := QVoxelWorld.from_document(parsed).all_models()[0]

	assert_eq(o2.modifiers.size(), 3, "链上三条都要回来")
	assert_eq(o2.modifiers[0].kind(), QVoxelModifier.KIND_SDF, "种类存活")
	assert_eq(o2.modifiers[0].combine, QVoxelDomain.Combine.SUBTRACT, "合成方式存活")
	assert_eq(o2.modifiers[1].kind(), QVoxelModifier.KIND_TRANSFORM, "种类存活")
	var t := (o2.modifiers[1] as QVoxelTransformModifier).transform
	assert_eq(t.mode, PcgTransform.Mode.REPEAT, "核的种类存活")
	assert_eq(t.times, 3, "核的参数存活")
	assert_false(o2.modifiers[2].enabled, "旁通位存活（它不改变条数，只有尺寸/结果能证明它回来了）")
	assert_eq(QVoxelEvalEngine.output_grid_size(o2.modifiers, o2.grid_size), Vector3i(24, 8, 8),
			"链的尺寸语义存活（平铺 ×3，镜像不改盒尺寸）")


# 帧动画 FRAM（§12）

## FRAM 往返：帧时长与**完整块表**必须一字不差地回来。
## 【为什么断言"完整块表"而不只是"帧数"】存储层是块级增量（帧 k 只写相对帧 k-1 的变化），
## 解析层必须把它**展开**成完整块表——否则调用方拿到的第 k 帧会缺掉所有没变的块。
## 只比帧数的话，"增量没展开、继承的块全丢了"也照样通过。
func test_fram_roundtrip_expands_deltas() -> void:
	var k0 := Vector3i(0, 0, 0)
	var k1 := Vector3i(1, 0, 0)
	var a := _frame_buf(1)
	var b := _frame_buf(2)
	var doc := _make_fram_doc([
		{"duration_ms": 100, "blocks": {k0: a}},
		{"duration_ms": 120, "blocks": {k0: a, k1: b}},   # 相对帧 0 只新增了 k1
	])
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	assert_true(parsed != null, "FRAM 往返解析应成功（%s）" % rep.summary())
	if parsed == null:
		return
	assert_true(rep.ok(), "往返不应有 FATAL（%s）" % rep.summary())

	var fr: Variant = parsed.model_frames(0)
	assert_true(fr is Array and (fr as Array).size() == 2, "应有 2 帧")
	var f0: Dictionary = (fr as Array)[0]
	var f1: Dictionary = (fr as Array)[1]
	assert_eq(int(f0["duration_ms"]), 100, "帧 0 时长")
	assert_eq(int(f1["duration_ms"]), 120, "帧 1 时长")
	assert_eq((f0["blocks"] as Dictionary).size(), 1, "帧 0 只有一个块")
	# 帧 1 的 k0 在增量里没出现（继承），展开后必须仍在
	assert_eq((f1["blocks"] as Dictionary).size(), 2, "帧 1 应展开为两块（k0 继承 + k1 新增）")
	assert_eq((f1["blocks"] as Dictionary)[k0], a, "继承块的内容应与帧 0 相同")
	assert_eq((f1["blocks"] as Dictionary)[k1], b, "新增块的内容")


## 帧增量的收益：一帧的成本 = 它相对上一帧改了多少块，与模型总大小无关。
## 【为什么盯 FRAM 块自己的 length 而不是文件总大小】总大小里混着 HEAD/MATE/填充，
## 想钉住"相同的块不重写"这件事，只能只看 FRAM 块负载。
func test_fram_delta_skips_unchanged_blocks() -> void:
	var k0 := Vector3i(0, 0, 0)
	var buf := _frame_buf(1)
	var one := QVoxelFile.serialize(_make_fram_doc([{"duration_ms": 100, "blocks": {k0: buf}}]))
	var one_off := _fram_block_offset(one)
	var full := one.decode_u32(one_off) - QVoxelSpec.FRAM_MODEL_HEADER_SIZE - QVoxelSpec.FRAM_FRAME_HEADER_SIZE
	assert_true(full > 0, "单帧的增量负载应非空")

	var same3 := QVoxelFile.serialize(_make_fram_doc([
		{"duration_ms": 100, "blocks": {k0: buf}},
		{"duration_ms": 100, "blocks": {k0: buf}},
		{"duration_ms": 100, "blocks": {k0: buf}},
	]))
	assert_eq(same3.decode_u32(_fram_block_offset(same3)),
			QVoxelSpec.FRAM_MODEL_HEADER_SIZE + 3 * QVoxelSpec.FRAM_FRAME_HEADER_SIZE + full,
			"内容相同的帧不该重复写块负载（增量收益消失？）")


## FRAM 里 codec=0 = "把该块清空"，与 VXEL 里 codec=0 = 损坏的语义**不同**（§12 / QVoxelSpec）。
## 【为什么单独测】"块消失"在增量里必须与"块没变"区分开：前者写 codec=0，后者不写。
## 若把 codec=0 当损坏丢弃，这一帧就会静默继承上一帧的块——画面里凭空多出一块。
func test_fram_frame_can_clear_a_block() -> void:
	var k0 := Vector3i(0, 0, 0)
	var k1 := Vector3i(1, 0, 0)
	var doc := _make_fram_doc([
		{"duration_ms": 100, "blocks": {k0: _frame_buf(1), k1: _frame_buf(2)}},
		{"duration_ms": 100, "blocks": {k0: _frame_buf(1)}},   # k1 被清空
	])
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	assert_true(parsed != null and rep.ok(), "清空帧应能往返（%s）" % rep.summary())
	if parsed == null:
		return
	var fr: Array = parsed.model_frames(0)
	assert_eq(fr.size(), 2, "帧数不变")
	var f1: Dictionary = fr[1]
	assert_eq((f1["blocks"] as Dictionary).size(), 1, "被清空的块不该继承回来")
	assert_true((f1["blocks"] as Dictionary).has(k0), "未变的块应保留")


## §12 不变式：一个 model_id 只能有一个体素源。VXEL 与 FRAM 撞车 → 拒绝整个文件（FATAL）。
func test_fram_vxel_conflict_is_fatal() -> void:
	var doc := _make_doc()   # 已含 models[0]
	doc.frames = {0: [{"duration_ms": 100, "blocks": {Vector3i(0, 0, 0): _frame_buf(1)}}]}
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	assert_true(parsed == null, "同一 model_id 同时有 VXEL 与 FRAM 应拒绝整个文件")
	assert_true(_errors_contain(rep, "冲突"), "report.errors 应说明冲突原因（%s）" % rep.summary())


## require 声明 FRAM → 本读者必须认得它，否则含动画的文件会被整个拒掉。
## （这也是 FRAM 作为"新块类型"对旧读取器的唯一告知手段。）
func test_fram_require_gate_accepted() -> void:
	var doc := _make_fram_doc([{"duration_ms": 100, "blocks": {Vector3i(0, 0, 0): _frame_buf(1)}}])
	doc.head["require"] = ["MATE", "FRAM", "NODE"]
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(QVoxelFile.serialize(doc), true, rep, true)
	assert_true(parsed != null, "require 含 FRAM 应可读入（%s）" % rep.summary())


## 一段动画内部结构损坏 → 只丢这段动画（DROP_MODEL），文件其余部分照常可用（§9.0 判据：
## 顶层块流由块头自己的 length 定界，坏掉的负载声明不影响"下一个块头在哪儿"）。
func test_fram_bad_payload_length_drops_animation() -> void:
	var doc := _make_fram_doc([{"duration_ms": 100, "blocks": {Vector3i(0, 0, 0): _frame_buf(1)}}])
	var bytes := QVoxelFile.serialize(doc)
	var off := _fram_block_offset(bytes)
	assert_true(off >= 0, "应能定位 FRAM 块")
	# FRAM 头里的 payload_length 改成荒谬大值；顺带 crc=0（= 作者未写校验值，读取端跳过）
	bytes.encode_u32(off + QVoxelSpec.BLOCK_HEADER_SIZE + 4, 0xFFFFFF)
	bytes.encode_u32(off + 8, 0)
	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	assert_true(parsed != null, "单个动画损坏不该让整个文件不可用（%s）" % rep.summary())
	assert_true(rep.ok(), "应是 DROP_MODEL 而非 FATAL（%s）" % rep.summary())
	assert_eq(rep.dropped_models, 1, "应记一次 DROP_MODEL")
	var fr: Variant = parsed.model_frames(0)
	assert_true(fr == null or (fr as Array).is_empty(), "被丢弃的动画不该留下帧")


# --- 本节的局部辅助 ---------------------------------------------------------

func _make_doc_with_engineering_data() -> QVoxelFile.QVoxelDocument:
	var doc := _make_doc()
	doc.node = {
		QVoxelSpec.NODE_CAMERAS_KEY: [
			{"name": "front", "projection": "ortho", "size": 128},
			{"name": "persp_cam"},
		],
		"nodes": [
			{"name": "root", "kind": "group", "children": [
				# 组内坐标是 steps 里的一条平移条目（combine=0 即「替换」，体素域变换型只允许它）
				{"name": "body", "kind": "model", "model_id": 0, "steps": [
					{"kind": "transform", "combine": 0,
						"type": "PcgTransform", "params": {"mode": 3, "offset": [1, 2, 3]}},
				]},
			]},
		],
	}
	return doc


func _find_node(nodes: Array, node_name: String) -> Dictionary:
	for n in nodes:
		if n is Dictionary and str((n as Dictionary).get("name", "")) == node_name:
			return n
	return {}


# 辅助

func _make_doc() -> QVoxelFile.QVoxelDocument:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = {
		"qvox": QVoxelSpec.VERSION,
		"channels": [{"name": QVoxelSpec.DOMINANT_CHANNEL, "bpp": QVoxelSpec.CHANNEL_BPP}],
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


func _frame_buf(value: int) -> PackedInt32Array:
	var b := QVoxelSpec.DEFAULT_BLOCK_SIZE
	var buf := PackedInt32Array()
	buf.resize(b * b * b)
	buf.fill(value)
	return buf


## 造一个"只有帧动画、没有静态模型"的 doc。
## （同一 model_id 不能既是 VXEL 又是 FRAM，见 §12，故必须清掉 _make_doc 的 models。）
func _make_fram_doc(frames: Array) -> QVoxelFile.QVoxelDocument:
	var doc := _make_doc()
	doc.models = {}
	doc.frames = {0: frames}
	return doc


## 定位序列化结果里 FRAM 块的块头偏移（没有则 -1）。块头自足，故顺序扫即可。
func _fram_block_offset(bytes: PackedByteArray) -> int:
	var pos := QVoxelSpec.SIGNATURE_SIZE
	while pos + QVoxelSpec.BLOCK_HEADER_SIZE <= bytes.size():
		var length := bytes.decode_u32(pos)
		if bytes.slice(pos + 4, pos + 8).get_string_from_ascii() == QVoxelSpec.BLOCK_FRAM:
			return pos
		pos += QVoxelSpec.BLOCK_HEADER_SIZE + length
	return -1


func _errors_contain(rep: QVoxelFile.QVoxelReport, needle: String) -> bool:
	for e in rep.errors:
		if str(e).contains(needle):
			return true
	return false


func _warnings_contain(rep: QVoxelFile.QVoxelReport, needle: String) -> bool:
	for w in rep.warnings:
		if str(w).contains(needle):
			return true
	return false


func _list_qvx(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".qvx"):
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
## 独立于 QVoxelFile 实现，避免"用被测对象验证被测对象"。
func _head_qvox_first(bytes: PackedByteArray) -> bool:
	if bytes.size() < QVoxelSpec.SIGNATURE_SIZE + QVoxelSpec.BLOCK_HEADER_SIZE:
		return false
	var at := QVoxelSpec.SIGNATURE_SIZE
	var length := bytes.decode_u32(at)
	var type := PackedByteArray()
	for i in 4:
		type.append(bytes[at + 4 + i])
	if type.get_string_from_ascii() != QVoxelSpec.BLOCK_HEAD:
		return false
	var payload := bytes.slice(at + QVoxelSpec.BLOCK_HEADER_SIZE, at + QVoxelSpec.BLOCK_HEADER_SIZE + length)
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