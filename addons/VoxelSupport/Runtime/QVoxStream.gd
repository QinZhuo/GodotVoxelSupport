class_name QVoxStream
extends VoxelStream

## 磁盘文件流（QVox 单文件块流）—— .qvox 格式，一个文件承载整个世界。
##
## 取代旧的 .voxr region 存储。设计见 docs/QVOX_FORMAT.md。三点核心差异：
##   1. 单文件：整个世界（所有 chunk、所有 LOD 层、材质、元数据）落在一个 .qvox，
##      而不是"每 region 一个文件"。文件数恒为 1。
##   2. 块流 + 内存索引：启动时扫描一次块头，建立 chunk_key → model/block 索引；
##      之后 save/load/has 全部 O(1) 命中内存。重写时按块重组，未知块原样保留。
##   3. 缓存可删：LOD 降采样、杂项派生数据可选写入 CACH（读取时忽略），
##      删掉 CACH 块不损失语义（P5）。
##
## 与上层契约（VoxelStream 抽象）完全一致，VoxelData / VoxelRenderer 无感知：
##   buffer = PackedInt32Array(CHUNK_VOLUME)，值 = 材质ID（0 = 空）。
##   lod=0 走 VOX0 model 0（唯一的权威体素数据）；lod>=1 走 CACH（派生缓存）。
##
## 【为什么 LOD 不写进 VOX0】粗层块由 LOD0 降采样得到，不含任何 LOD0 没有的信息，
## 因此它是**派生数据**——存成 model 会污染 VOX0 的语义（模型数、NODE 引用、
## 导入器的 split_by_model 都会把它当成一个真实模型），而 CACH 的定义恰好是
## "删掉语义为零"（§6）。于是取值路径只有一条：**权威数据永远从 VOX0 读，
## 派生的粗层数据永远从 CACH 读**，两条路互不干扰。
##
## 块坐标 == chunk 坐标：QVox 的 block_size 与 VoxelChunk.CHUNK_SIZE 同为 32，
## 因此 chunk_key 可直接作为 QVox 的块索引 (bx,by,bz)，无需换算。
##
## 【持久化策略】内存常驻权威数据（_model_blocks）+ 脏标记 + flush() 原子落盘。
##   - save_chunk 只改内存并置脏，不立即写盘（避免每块一次整文件重写）
##   - flush() / 达到 _auto_flush_dirty 阈值时才整文件序列化（临时文件 + rename）
##   - 原子写保证读者只会看到旧的完整文件或新的完整文件，绝不半写

## QVoxSpec / QVoxFile / QVoxBlockCodec 均为全局注册类（class_name），直接按名引用，
## 不要用 `const X := preload(...)`（会遮蔽同名全局类并触发 "hides a global class"）。

const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME

const FILE_EXT := "." + QVoxSpec.FILE_EXT

## 按目录组织存档的调用方使用的固定文件名（一个目录承载整个世界）。
const WORLD_FILE_NAME := "world" + FILE_EXT

## LOD 派生缓存在 CACH 里的命名空间与算法版本（§6：kind 由写入方定义，格式不解释）。
## algo_version 变化 = 降采样规则变化 → 旧缓存按 §6 规则 2 自动失效、重算。
const CACH_KIND_LOD := "LODS"
const CACH_LOD_ALGO := 1

## 单文件路径（支持 user:// / res:// 或绝对路径）。默认 user:// 下的世界文件。
@export var file_path: String = "user://voxel_data/" + WORLD_FILE_NAME

## 头部元数据（写入 HEAD 的附加键，读取时原样带回，便于携带世界级参数）。
@export var metadata: Dictionary = {}

## 材质条目（按材质 ID 索引的 Array[Dictionary]，QVox MATE 结构）。
## 由 VoxelData 在 flush 前通过 set_materials() 注入；索引 0 = 空气。
var _materials: Array = []

## 当累计脏块达到该值自动 flush（0 = 关闭自动，仅显式 flush）。防长时间不落盘。
##
## 【它同时是"单次落盘卡顿峰值"的上限】flush 在主线程重编码脏块，而重编码
## （pick_codec + pack）是 GDScript 逐元素扫描。实测每块代价：
##   · 纯 SOLID / 全空块：约 10~20µs（已走原生 count 快判）
##   · 混合值块（2~4 种材质这种最常见形态）：**约 15ms/块**（pick ~7.7ms + pack ~7.9ms）
## 故"该值 × 15ms"≈ 最坏单帧卡顿：256 → 可达数秒；调到 32 → 约 0.5s。
## 要削掉这个峰值有两条路（都需另行改动，不在本篇注释范围）：
##   1) 原生侧实现 pick_codec / pack（需重建 GDExtension 库）；
##   2) 后台线程落盘（需一并设计脏集在写盘期间的新增如何补标，否则会丢存档）。
## 现阶段最省事的缓解就是把它调小：落盘更频繁，但每次更短。
@export var auto_flush_dirty: int = 256

# ----------------------------------------------------------------------------
# 内存权威数据
# ----------------------------------------------------------------------------
# 只有 lod=0（全精度权威数据）进这里：model 0 = { chunk_key: PackedInt32Array }。
# 粗层（lod>=1）是派生数据，走下面的 _lod_cache（→ CACH）。
# block_index（Vector3i）即 chunk 坐标（block_size == CHUNK_SIZE）。
var _models: Dictionary = {}

## LOD 派生缓存（内存侧）：lod(>=1) → { block_key(Vector3i): PackedInt32Array }。
## 落盘时编码为 CACH（见 CACH_KIND_LOD）。加载时按 source_crc 校验来源是否仍成立。
var _lod_cache: Dictionary = {}

## CACH 是否变化（需在写盘时整体重写）。LOD 缓存任何增删改都置 true。
var _dirty_cach := false

var _dirty := false
var _dirty_count := 0
var _loaded := false

## 【增量写】脏 model 集合（model_id → true）。仅这些 VOX0 块在 flush 时重编码，
## 其余块直接搬运磁盘上的原始字节。替代"改一个块就重编码全世界"的全量路径。
var _dirty_models: Dictionary = {}

## 【增量写】非 model 全局块（HEAD/MATE/NODE）是否需要重编码。
## materials/metadata/node 变动时置 true。
var _dirty_global := false

## 【增量写·第二层局部性】脏的 chunk：{ model_id: { chunk_key: true } }。
## 比 _dirty_models 更细——一个 model（如 lod=0 的世界层）常含成百上千个 chunk，
## 改一个 chunk 时只该重编码那一个子块，而非整层。见 QVoxFile.encode_vox0_incremental。
var _dirty_chunks: Dictionary = {}

## 【增量写】上次解析出的块字节索引（doc.block_index 的副本），以及当时的原始文件字节。
## 用于搬运未变块的原始字节。首次全量写后失效（置空）。
var _block_index: Array = []
var _raw_bytes: PackedByteArray = PackedByteArray()

## 【增量写·二级索引】每个 VOX0 的子块索引：{ model_id(int): index_vox0_blocks() 的结果 }。
##
## 【为什么必须缓存】index_vox0_blocks 要为整个 VOX0 负载（1.4MB）算一遍逐子块 CRC，
## 约 90ms。若每次写盘都重建，子块级增量省下的时间会被它原样吃回去 —— 实测正是如此
## （改 1 个 chunk 仍要 447ms）。这里把它当**持久索引**：加载时建一次，之后每次写盘
## 只对**脏 model** 重建、未变 model 沿用旧索引（它们的字节是原样搬运的，索引自然有效）。
var _vox0_index: Dictionary = {}

## 【增量写】上次落盘（或加载）时的 HEAD / MATE / NODE 快照，用于判断全局块是否变化。
var _loaded_head: Dictionary = {}
var _loaded_materials: Array = []
var _loaded_node: Dictionary = {}

# 异步取数由 VoxelAsyncLoader 编排：它先问 has_chunk，命中就调 load_chunk 直读内存
# （本类的索引常驻内存，无需后台任务），故本类不实现任何异步接口。

# 真未知块（格式层不认识的类型 -> [payload]）。重写时原样保留，保证不丢外部数据。
# CACH 不在这里——它是一等块（doc.cach / _lod_cache），有自己的重写路径。
var _unknown_blocks: Dictionary = {}


# ----------------------------------------------------------------------------
# 路径 / 目录
# ----------------------------------------------------------------------------

func _ensure_dir() -> void:
	var dir := file_path.get_base_dir()
	var abs := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


# ----------------------------------------------------------------------------
# 加载 / 保存（整文件）
# ----------------------------------------------------------------------------

## 确保内存权威数据已从磁盘载入（幂等）。文件不存在则视为空世界。
func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		push_error("[QVoxStream] 无法读取 %s: %s" % [file_path, error_string(FileAccess.get_open_error())])
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var doc: QVoxFile.QVoxDocument = QVoxFile.parse_with_index(bytes)
	if doc == null:
		push_error("[QVoxStream] %s 解析失败，按空世界处理" % file_path)
		return
	# models → _models（键即 model_id；doc.models 与本表的键统一为 int）
	for mid in doc.models:
		_models[int(mid)] = doc.models[mid]
	# 材质：QVox MATE Dictionary → 供上层 set_materials 还原
	_materials = doc.materials
	# NODE 中的附加元数据原样带回
	if doc.node.has("metadata") and doc.node["metadata"] is Dictionary:
		metadata = doc.node["metadata"]
	# 未知块保留
	_unknown_blocks = doc.unknown_blocks.duplicate(true)
	# 【增量写】留存块字节索引 + 原始字节，供未变块直接搬运
	_block_index = doc.block_index
	_raw_bytes = bytes
	_loaded_head = doc.head
	_loaded_materials = doc.materials
	_loaded_node = doc.node
	# 【二级索引】建 VOX0 子块索引（含各子块 CRC），此后每次增量写直接复用，
	# 避免写盘时反复对 1.4MB 负载重算 → 这是子块级增量真正生效的前提。
	# 此时 _dirty_models 为空 → 全部 model 都建（加载后的首次写盘即命中缓存）。
	_build_vox0_index(doc.get_block_size())
	# 【派生缓存】CACH 里的 LOD 缓存：逐条按 source_crc 校验来源是否仍成立，
	# 成立的才进 _lod_cache，失效的当场丢弃（调用方会重新降采样并覆盖）。
	# 必须建在 _build_vox0_index 之后——来源校验用的正是它算出的 LOD0 子块 CRC。
	_load_lod_cache(doc.cach, doc.get_block_size())


## 把内存权威数据写盘（原子：写临时文件 → rename）。
##
## 【增量写】若本次修改只动了若干 model 的内容（无块集合变化）且已有上次的块字节索引，
## 则走 QVoxFile.serialize_incremental：未变的块直接搬运磁盘原始字节，只重编码脏 model。
## 这消除了"改一个 chunk 就重编码全世界所有 VOX0 块"的浪费（规范 §4 明示"块是编辑的
## 局部性单位"）。块集合变化（新增/删除 model、materials 从无到有等极端情况）自动退回全量。
func _write_file() -> void:
	if not _dirty:
		return
	_ensure_dir()
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = _build_head()
	doc.materials = _materials_to_qvox()
	doc.models = _models_to_qvox_models()
	var node := {}
	if not metadata.is_empty():
		node["metadata"] = metadata
	doc.node = node
	doc.unknown_blocks = _unknown_blocks

	# 增量路径只需要 block_index 与旧 head/materials/node（用于变化对比）
	var old_doc := QVoxFile.QVoxDocument.new()
	old_doc.block_index = _block_index
	old_doc.head = _loaded_head
	old_doc.materials = _loaded_materials
	old_doc.node = _loaded_node
	# 先自己判定走哪条路：serialize_incremental 在全量回退时会把 old 里的 CACH 一并丢掉，
	# 我们必须知道"旧 CACH 有没有被搬运"，才能决定要不要补写（见下）。
	var incremental := _can_write_incremental() and QVoxFile.incremental_applicable(old_doc, doc)
	var bytes: PackedByteArray
	if incremental:
		bytes = QVoxFile.serialize_incremental(_raw_bytes, old_doc, doc, _dirty_models, _dirty_global, true, _dirty_chunks, _vox0_index, _dirty_cach)
	else:
		bytes = QVoxFile.serialize(doc)

	# 【顺序要紧·一】据"待写字节"刷新块索引与 _vox0_index：派生缓存的 source_crc 是
	# "它所依赖的 LOD0 子块 CRC"，必须取自**本次真正写出的字节**。若用内存里的旧索引，
	# 本次改动的 LOD0 块其 CRC 已变 → 缓存来源与实际数据错配 → 下次加载被判失效（白写）。
	_refresh_index_from(bytes)

	# 【顺序要紧·二】追加派生缓存（CACH）：
	#   - 走增量且 CACH 未变 → 旧块已被原样搬运，不重复追加；
	#   - 其余（全量写 / CACH 有变化）→ 旧块不在新字节里，由当前 _lod_cache 整体重写。
	var derived := PackedByteArray()
	if (not incremental) or _dirty_cach:
		derived = _encode_derived_blocks()
	if not derived.is_empty():
		bytes.append_array(derived)
		_raw_bytes = bytes
		_block_index = QVoxFile.scan_block_index(bytes)

	var tmp_path := file_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error("[QVoxStream] 无法写入 %s: %s" % [tmp_path, error_string(FileAccess.get_open_error())])
		return
	f.store_buffer(bytes)
	f.close()
	# 原子替换：读者只会看到旧文件（完整）或新文件（完整）
	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_path := ProjectSettings.globalize_path(file_path)
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(abs_path)
	var err := DirAccess.rename_absolute(abs_tmp, abs_path)
	if err != OK:
		push_error("[QVoxStream] 原子替换失败: %s" % error_string(err))
		# 索引此前已按"未落盘的字节"更新过，作废以免下次增量写拿错基准（退化为全量，安全）。
		_block_index = []
		_raw_bytes = PackedByteArray()
		_vox0_index.clear()
		return
	_dirty = false
	_dirty_count = 0
	_dirty_global = false
	_dirty_cach = false
	# 【顺序要紧】_refresh_index_from 在写盘前已调用（派生缓存的来源 CRC 要基于新字节），
	# 但它内部按"哪些 model 是脏的"决定重建范围，故必须在 _dirty_models.clear() **之前**。
	_dirty_models.clear()
	_dirty_chunks.clear()


## 是否可走增量路径：必须有上次的块索引与原始字节（即此前已 load 或写过一次）。
func _can_write_incremental() -> bool:
	return not _block_index.is_empty() and not _raw_bytes.is_empty()


## 用刚写出的字节刷新块索引。**只扫描块头，不解码负载、不校验 CRC/语义**——
## 这些字节是我们自己刚写下的，正确性由写入端保证；这里只需要"块都落在哪些区间"。
## 走完整 parse_with_index 会把每个 VOX0 的 32768 个体素全部解码并跑语义校验，
## 是扫描的数百倍代价（实测 1834ms vs <1ms），且增量写的正确性并不依赖它。
func _refresh_index_from(bytes: PackedByteArray) -> void:
	_raw_bytes = bytes
	_block_index = QVoxFile.scan_block_index(bytes)
	if _block_index.is_empty():
		# 扫描异常（不该发生）：清空索引 → 下次退回全量，安全兜底
		_raw_bytes = PackedByteArray()
		_vox0_index.clear()
		return
	# head/materials/node 快照仍从新写出的 doc 语义侧取（写入端已知其内容，
	# 无需再从字节反解——那正是我们要避免的全量解析）。
	_loaded_head = _build_head()
	_loaded_materials = _materials_to_qvox()
	_loaded_node = {}
	if not metadata.is_empty():
		_loaded_node["metadata"] = metadata
	# 【二级索引维护】只重建**脏 model** 的子块索引；未变的 model 其子块字节是原样
	# 搬运的，旧索引（含各子块的 CRC）依旧准确，直接沿用即可。
	# 于是每次写盘的重索引开销 = O(脏 model 的子块数)，而非 O(全部 model)。
	_refresh_vox0_index(bytes)


## 写后重建 VOX0 子块索引。脏 model 重建、未变 model 沿用（见 _vox0_index 注释）。
func _refresh_vox0_index(bytes: PackedByteArray) -> void:
	var block_size := int(_loaded_head.get("block_size", 0))
	if block_size <= 0:
		block_size = 32
	_build_vox0_index(block_size, bytes)


## 建/更新 VOX0 子块索引 { model_id: index_vox0_blocks }。工作基于 _block_index + _raw_bytes。
##
## 维护策略（"跟着写入走"）：_dirty_models 里的 model 重建索引（字节变了），
## 其余沿用旧索引（字节原样搬运，索引里的偏移与 CRC 依旧准确）。
## 于是单次写盘的重索引代价 = O(脏 model 的子块数)，与全世界大小无关。
func _build_vox0_index(block_size: int, bytes: PackedByteArray = PackedByteArray()) -> void:
	var src := bytes if not bytes.is_empty() else _raw_bytes
	var next_idx: Dictionary = {}
	for bi in _block_index:
		if bi["type"] != QVoxSpec.BLOCK_VOX0:
			continue
		var mid := int(bi.get("model_id", -1))
		if mid < 0:
			continue
		# 未变 model 且已有索引：沿用（省下一次 1.4MB 负载的 CRC 扫描）
		if not _dirty_models.has(mid) and _vox0_index.has(mid):
			next_idx[mid] = _vox0_index[mid]
			continue
		var off: int = bi["offset"]
		var total: int = bi["total"]
		var payload_off := off + QVoxSpec.BLOCK_HEADER_SIZE
		var payload_len := total - QVoxSpec.BLOCK_HEADER_SIZE
		if payload_len < 6 or payload_off + payload_len > src.size():
			continue
		next_idx[mid] = QVoxFile.index_vox0_blocks(src.slice(payload_off, payload_off + payload_len), block_size)
	_vox0_index = next_idx


## 构造 HEAD JSON 字典（qvox / channels / block_size / up_axis + 附加元数据）。
func _build_head() -> Dictionary:
	var head := {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": CHUNK_SIZE,
		"up_axis": QVoxSpec.DEFAULT_UP_AXIS,
	}
	# 附加键（metadata 里的自定义键并入 HEAD，便于携带世界级参数）
	for k in metadata:
		if k == "qvox" or k == "channels" or k == "block_size" or k == "up_axis":
			continue
		head[k] = metadata[k]
	return head


## 上层材质数组 → QVox MATE Dictionary 列表。
##
## 转换本身在 VoxelMaterial.to_mate()（写盘与导入共用的唯一实现，见那里的量纲与缺口说明）：
## 这里只负责两件存储层的事——(1) 条目 0 恒为空气（§4 格式不变量，体素值 0 就是空气）；
## (2) 逐条归一化，使"加载 → 改块 → flush"多次写盘稳定（幂等）。
func _materials_to_qvox() -> Array:
	var out: Array = []
	for i in _materials.size():
		out.append(VoxelMaterial.air_mate() if i == 0 else VoxelMaterial.to_mate(_materials[i]))
	return out


## 内存 _models（int model_id → {Vector3i: PackedInt32Array}）→ QVox doc.models。
## 统一输出 int 键；QVoxDocument 的 model_ids()/model_blocks() 会兼容两种键，
## 故读取方无需关心键类型（历史上 int/str 混用曾让增量写无声退化成全量）。
func _models_to_qvox_models() -> Dictionary:
	var out: Dictionary = {}
	for mid in _models:
		out[int(mid)] = _prune_empty(_models[mid])
	return out


## 去掉全零块（空块不落盘，P2 / §5.1）。
## 判空用原生 `count(0)`：此前是"逐体素扫到第一个非空"的 GDScript 循环，而 flush 会对
## **所有块的所有体素**跑一遍——1400 块 / 140 万体素的世界实测是秒级主线程冻结，
## 换成原生后是十几毫秒（同一数量级内从"秒"降到"十毫秒"）。
func _prune_empty(blocks: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in blocks:
		var buf: PackedInt32Array = blocks[k]
		if buf.count(0) != buf.size():
			out[k] = buf
	return out


# ----------------------------------------------------------------------------
# LOD 派生缓存（CACH，§6）
# ----------------------------------------------------------------------------
# 粗层块由 LOD0 降采样得到，是**派生数据**：缓存内容与"它依赖哪些 LOD0 块"一起落盘，
# 读取时对后者做一次精确的**集合比较**——不一致就丢弃重算（§6 失效规则 1）。
# 于是"LOD0 被编辑过、但缓存尚未重算"这种状态在磁盘上无法伪装成有效缓存。
#
# 负载布局（kind="LODS"，格式层不解释，完全由本类定义）：
#   uint16 lod ‖ [ int32 bx,by,bz ‖ uint8 codec ‖ uint32 plen ‖ plen 字节 ]
# 定长前置 2 + 17 = 19 字节。带 plen 是为了让"缓存内容在哪结束"成为块内事实（P4）：
# CACH 负载按 §6 含 0–3 字节尾部填充，没有 plen 就只能退化为"剩余 < 4 即合法"的灰区判定。

const LOD_ENTRY_HEADER := 2 + QVoxSpec.VOX_BLOCK_HEADER_SIZE


## 从 doc.cach 装载 LOD 缓存：只为 (kind, algo_version) 认识且**来源仍成立**的条目建缓存。
func _load_lod_cache(entries: Array, block_size: int) -> void:
	_lod_cache.clear()
	var n := block_size * block_size * block_size
	for e in entries:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		if String(d.get("kind", "")) != CACH_KIND_LOD:
			continue
		# §6 规则 2：算法版本不认识 → 丢弃（缓存由别的规则生成，语义未必相同）。
		if int(d.get("algo_version", -1)) != CACH_LOD_ALGO:
			continue
		var parsed := _decode_lod_entry(d.get("payload", PackedByteArray()), n)
		if parsed.is_empty():
			continue
		var lod: int = parsed["lod"]
		var key: Vector3i = parsed["key"]
		# §6 规则 1：来源集合不一致 → 丢弃（LOD0 已被编辑，缓存已过期）。
		if not _lod_source_matches(key, lod, d.get("source_crc", [])):
			continue
		if not _lod_cache.has(lod):
			_lod_cache[lod] = {}
		(_lod_cache[lod] as Dictionary)[key] = parsed["buffer"]


## 把 _lod_cache 编码为 CACH 块字节（含 12 字节块头）。无缓存时返回空。
func _encode_derived_blocks() -> PackedByteArray:
	var entries: Array = []
	var lods := _lod_cache.keys()
	lods.sort()
	for lod_v in lods:
		var lod := int(lod_v)
		if lod < 1:
			continue
		var by_key: Dictionary = _lod_cache[lod]
		var keys := by_key.keys()
		keys.sort_custom(_compare_block_keys)
		for k in keys:
			var payload := _pack_lod_block(lod, k, by_key[k])
			if payload.is_empty():
				continue
			entries.append({
				"kind": CACH_KIND_LOD,
				"algo_version": CACH_LOD_ALGO,
				"source_crc": _lod_expected_crcs(k, lod),
				"payload": payload,
			})
	var out := PackedByteArray()
	QVoxFile.append_cach_blocks(out, entries)
	return out


## 一个粗层块 → CACH 负载（19 字节头 + 打包数据）。全空块不缓存（返回空）。
func _pack_lod_block(lod: int, key: Vector3i, buf: PackedInt32Array) -> PackedByteArray:
	if buf.size() != CHUNK_VOLUME:
		return PackedByteArray()
	var pick := QVoxBlockCodec.pick_codec(buf, CHUNK_VOLUME)
	var codec: int = pick[0]
	if codec == QVoxSpec.CODEC_EMPTY:
		return PackedByteArray()
	var data := QVoxBlockCodec.pack(codec, buf, CHUNK_VOLUME)
	var out := PackedByteArray()
	out.resize(LOD_ENTRY_HEADER)
	out.encode_u16(0, lod & 0xFFFF)
	out.encode_u32(2, QVoxSpec.to_u32(key.x))
	out.encode_u32(6, QVoxSpec.to_u32(key.y))
	out.encode_u32(10, QVoxSpec.to_u32(key.z))
	out[14] = codec & 0xFF
	out.encode_u32(15, data.size())
	out.append_array(data)
	return out


## CACH 负载 → { "lod": int, "key": Vector3i, "buffer": PackedInt32Array }。非法返回空。
func _decode_lod_entry(payload: PackedByteArray, n: int) -> Dictionary:
	if payload.size() < LOD_ENTRY_HEADER:
		return {}
	var lod := payload.decode_u16(0)
	if lod < 1:
		return {}
	var key := Vector3i(
			QVoxSpec.from_u32(payload.decode_u32(2)),
			QVoxSpec.from_u32(payload.decode_u32(6)),
			QVoxSpec.from_u32(payload.decode_u32(10)))
	var codec := payload[14]
	var plen := payload.decode_u32(15)
	# plen 精确界定内容；其后至多是块尾填充，故"多出来的字节"不构成损坏。
	if codec == QVoxSpec.CODEC_EMPTY or LOD_ENTRY_HEADER + plen > payload.size():
		return {}
	var buf := QVoxBlockCodec.unpack(codec, payload.slice(LOD_ENTRY_HEADER, LOD_ENTRY_HEADER + plen), n)
	if buf.is_empty():
		return {}
	return {"lod": lod, "key": key, "buffer": buf}


## 一个粗层块**当前应有**的来源 CRC 集合（升序去重，§6 的表示要求）。
##
## 来源 = 它覆盖的 2^lod³ 个 LOD0 chunk（VoxelChunk.lod_covered_chunks，与降采样同一套
## 坐标），CRC 直接取 _vox0_index[0] 里已算好的**子块 CRC**：降采样只读这些 chunk，
## 故这一组值足以判定"缓存是否过期"，且不产生任何额外扫描（索引本就为增量写而建）。
func _lod_expected_crcs(block_key: Vector3i, lod: int) -> Array:
	var crcs: Array = []
	var l0: Variant = _vox0_index.get(0)
	if l0 is Dictionary:
		var meta: Variant = (l0 as Dictionary).get("_meta")
		if meta is Dictionary:
			var subs: Variant = (meta as Dictionary).get("sub")
			if subs is Dictionary:
				for ck in VoxelChunk.lod_covered_chunks(block_key, lod):
					var info: Variant = (subs as Dictionary).get(ck)
					if info is Dictionary:
						crcs.append(int((info as Dictionary).get("crc", 0)))
	crcs.sort()
	var out: Array = []
	for c in crcs:
		if out.is_empty() or int(out[-1]) != int(c):
			out.append(c)   # 升序去重：同一组来源无论写入顺序都得到相同表示（§6）
	return out


## 存档中的来源集合是否与当前一致（§6 规则 1：集合比较，非顺序比较）。
func _lod_source_matches(block_key: Vector3i, lod: int, stored: Variant) -> bool:
	if not (stored is Array):
		return false
	return (stored as Array) == _lod_expected_crcs(block_key, lod)


## 块坐标的确定性排序（让写出的 CACH 顺序可复现，与文件内容无关）。
func _compare_block_keys(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


# ----------------------------------------------------------------------------
# VoxelStream 接口实现
# ----------------------------------------------------------------------------

## lod=0 → VOX0 model 0（权威数据）；lod>=1 → CACH 派生缓存（见类注释）。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	_ensure_loaded()
	if buffer.is_empty():
		erase_chunk(chunk_key, lod)
		return
	if lod != 0:
		if not _lod_cache.has(lod):
			_lod_cache[lod] = {}
		(_lod_cache[lod] as Dictionary)[chunk_key] = buffer.duplicate()
		_dirty = true
		_dirty_count += 1
		_dirty_cach = true
		if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
			_write_file()
		return
	if not _models.has(0):
		_models[0] = {}
	(_models[0] as Dictionary)[chunk_key] = buffer.duplicate()
	_dirty = true
	_dirty_count += 1
	_dirty_models[0] = true   # 【增量写】只重编码这个 model
	_mark_chunk_dirty(0, chunk_key)
	if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
		_write_file()


func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	_ensure_loaded()
	if lod != 0:
		var c: Variant = _lod_cache.get(lod)
		if not (c is Dictionary):
			return PackedInt32Array()
		var lb: Variant = (c as Dictionary).get(chunk_key)
		return (lb as PackedInt32Array).duplicate() if lb != null else PackedInt32Array()
	if not _models.has(0):
		return PackedInt32Array()
	var buf: Variant = (_models[0] as Dictionary).get(chunk_key)
	return (buf as PackedInt32Array).duplicate() if buf != null else PackedInt32Array()


func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	_ensure_loaded()
	if lod != 0:
		var c: Variant = _lod_cache.get(lod)
		return c is Dictionary and (c as Dictionary).has(chunk_key)
	if not _models.has(0):
		return false
	return (_models[0] as Dictionary).has(chunk_key)


func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void:
	_ensure_loaded()
	if lod != 0:
		var c: Variant = _lod_cache.get(lod)
		if c is Dictionary and (c as Dictionary).has(chunk_key):
			(c as Dictionary).erase(chunk_key)
			_dirty = true
			_dirty_count += 1
			_dirty_cach = true
		return
	if not _models.has(0):
		return
	var blocks: Dictionary = _models[0]
	if blocks.has(chunk_key):
		blocks.erase(chunk_key)
		_dirty = true
		_dirty_count += 1
		_dirty_models[0] = true   # 【增量写】
		_mark_chunk_dirty(0, chunk_key)


## 登记一个脏 chunk（子块级增量用）。删除 chunk 也登记——那样该 model 的
## 子块集合会变化，encode_vox0_incremental 会检测到并让调用方退回整编码。
func _mark_chunk_dirty(model_id: int, chunk_key: Vector3i) -> void:
	if not _dirty_chunks.has(model_id):
		_dirty_chunks[model_id] = {}
	(_dirty_chunks[model_id] as Dictionary)[chunk_key] = true


func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	_ensure_loaded()
	var out: Array[Vector3i] = []
	if lod != 0:
		var c: Variant = _lod_cache.get(lod)
		if c is Dictionary:
			for k in (c as Dictionary):
				out.append(k)
		return out
	if not _models.has(0):
		return out
	for k in (_models[0] as Dictionary):
		out.append(k)
	return out


## O(1) 计数（不构造 key 数组）。
func get_chunk_count(lod: int = 0) -> int:
	_ensure_loaded()
	if lod != 0:
		var c: Variant = _lod_cache.get(lod)
		return (c as Dictionary).size() if c is Dictionary else 0
	return (_models[0] as Dictionary).size() if _models.has(0) else 0


func flush() -> void:
	_ensure_loaded()
	_write_file()


func get_stream_path() -> String:
	return file_path


# 异步取数（request / poll / 在途查询）不在本类：存储只回答"存没存、取出来"，
# 编排（去重、限流、后台派发、结果回填）由 VoxelAsyncLoader 一处负责。


# ----------------------------------------------------------------------------
# 上层注入 / 查询
# ----------------------------------------------------------------------------

## 注入材质数组（VoxelData.materials）。flush 时写入 MATE 块。
func set_materials(mats: Array) -> void:
	_materials = mats
	_dirty = true
	_dirty_global = true   # 【增量写】MATE 属全局块，需重编码


## 读取文件中的材质（QVox MATE Dictionary 列表），无则空数组。
func get_materials() -> Array:
	_ensure_loaded()
	return _materials


## 是否有未落盘的修改。
func is_dirty() -> bool:
	return _dirty


## 丢弃内存权威数据（下次访问重新从磁盘载入）。不写回。
func clear_cache() -> void:
	_models.clear()
	_lod_cache.clear()
	_dirty = false
	_dirty_count = 0
	_dirty_models.clear()
	_dirty_chunks.clear()
	_dirty_global = false
	_dirty_cach = false
	_block_index = []
	_raw_bytes = PackedByteArray()
	_vox0_index.clear()
	_loaded = false
