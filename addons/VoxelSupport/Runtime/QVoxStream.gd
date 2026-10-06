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
## 【持久化策略】内存只保留"未落盘的改动"（覆盖层 + 删除墓碑）+ 脏标记 + flush() 原子落盘。
##   - save_chunk 只改覆盖层并置脏，不立即写盘（避免每块一次整文件重写）
##   - flush() / 达到 auto_flush_dirty 阈值时才序列化（临时文件 + rename）；
##     未变的块直接搬运磁盘原始字节（增量写，见 QVoxFile.serialize_incremental）
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

## LOD0（全精度权威数据）所在的 model_id。
## 本流把"世界层"固定在 model 0：磁盘上的 VOX0 model 0 即全部 LOD0 chunk。
## 具名而不是散写 0，是为了让"世界层是哪个 model"这个约定只有一个出处；
## 渲染器/降采样侧读取来源 CRC 也走同一个常量（见 _lod_expected_crcs）。
const LOD0_MODEL_ID := 0

## 单文件路径（支持 user:// / res:// 或绝对路径）。默认 user:// 下的世界文件。
@export var file_path: String = "user://voxel_data/" + WORLD_FILE_NAME

## 头部元数据（写入 HEAD 的附加键，读取时原样带回，便于携带世界级参数）。
@export var metadata: Dictionary = {}

## 材质条目（按材质 ID 索引的 Array[Dictionary]，QVox MATE 结构）。
## 由 VoxelData 在 flush 前通过 set_materials() 注入；索引 0 = 空气。
var _materials: Array = []

## 当累计脏块达到该值自动 flush（0 = 关闭自动，仅显式 flush）。防长时间不落盘。
## 它同时是"单次落盘卡顿峰值"的上限：脏块重编码走原生 choose_and_pack（约 0.2ms/块），
## 而"把几十 MB 字节写盘"这段纯 I/O 已交给后台线程（见 _write_bytes_worker），
## 故主线程只承担序列化那部分。
@export var auto_flush_dirty: int = 256

## 在途落盘任务：I/O 在 worker、收尾在主线程。flush() 会等待在途任务，保持"返回即已落盘"。
var _write_in_flight := false
var _write_task_id: int = -1
var _write_serial := 0
var _write_done_serial: int = -1
var _write_result: Array = []

## 在途写盘的**输入快照**（_write_file 换出、_on_write_done 丢弃；失败则并回）。
## 见 _write_file 的"快照换出"注释：写盘期间的新改动落进"新的"覆盖层/墓碑，
## 因此成功收尾只需丢弃快照——不必回头分辨"哪些条目是本次写的、哪些是飞行中新加的"。
var _inflight: Dictionary = {}

# ----------------------------------------------------------------------------
# 内存状态：只留"未落盘的改动"，不留全世界的解码镜像
# ----------------------------------------------------------------------------
# 【为什么不再常驻全世界】旧实现用 _models 把文件里每个 chunk 都解码后长期留在内存，
# 内存随探索范围**无界增长**。但"已落盘的干净数据"本就由磁盘 + 数据层 VoxelData 的流式
# 缓存（受流式半径界定）共同持有，存储层再存一份纯属重复。于是这里只留尚未落盘的部分：
#   _dirty_buffers  写入覆盖层（save_chunk 的产物）
#   _deleted        删除墓碑（否则已删的块会被块索引"复活"）
# 越过它们之后取值路径只有一条：**按块索引 seek 并从文件读那一块**（见 _read_clean_chunk）。
# block_index（Vector3i）即 chunk 坐标（block_size == CHUNK_SIZE）。

## 写入覆盖层：model_id → { chunk_key(Vector3i): PackedInt32Array }。
## 只装"改了但还没写进文件"的块；落盘成功即整体换出丢弃，条数受 auto_flush_dirty 上界约束。
var _dirty_buffers: Dictionary = {}

## 删除墓碑：model_id → { chunk_key(Vector3i): true }。
## 删掉的块若已在文件里，必须留墓碑——否则 has_chunk/load_chunk 会顺着块索引把它读回来。
var _deleted: Dictionary = {}

## 粗层写入覆盖层：lod(>=1) → { block_key(Vector3i): PackedInt32Array }。
## 与 _dirty_buffers 同形（只装"改了但还没写进文件"的粗层块），落盘时编码为 CACH。
var _dirty_lod: Dictionary = {}

## 粗层删除墓碑：lod(>=1) → { block_key(Vector3i): true }。
## 口径与 _deleted 一致：只有文件里确实有这条缓存才需要墓碑（否则墓碑无指代对象）。
var _deleted_lod: Dictionary = {}

## CACH 条目轻量索引（本流只认 kind="LODS"、algo_version=CACH_LOD_ALGO）：
##   lod(>=1) → { block_key(Vector3i) → {
##       "block_off": int,    顶层 CACH 块在文件中的起始偏移（增量写据此跳过/替换旧块）
##       "payload_off": int,  内层 vox 负载在文件中的**绝对**偏移（按需读盘定位）
##       "payload_len": int,
##       "codec": int,
##       "source_crc": Array, 落盘时它依赖的 LOD0 子块 CRC 集合（读时与当前比较判失效）
##   } }
##
## 【为什么是索引而不是解码缓存】粗层块同样随探索范围无界增长；只记"条目在哪、来源是什么"，
## 缓冲区按需 seek 读盘 + 解码（与 _read_clean_chunk 同构）。来源校验因此也移到**读时**：
## 任何一次 LOD0 编辑都会即时让相关缓存失效，而不必在加载时把整批缓存解码一遍。
var _cach_index: Dictionary = {}

var _dirty := false
var _dirty_count := 0
var _loaded := false

## 【增量写】脏 model 集合（model_id → true）。仅这些 VOX0 块在 flush 时重建，
## 其余块直接搬运磁盘上的原始字节。替代"改一个块就重编码全世界"的全量路径；
## 而"重建"本身又只重编码变了的子块（内容看 _dirty_buffers、删除看 _deleted），
## 未变子块仍按块索引搬运旧字节（见 QVoxFile.encode_vox0_blocks）。
var _dirty_models: Dictionary = {}

## 【增量写】非 model 全局块（HEAD/MATE/NODE）是否需要重编码。materials/metadata 变动时置 true。
var _dirty_global := false

## 【增量写】上次解析出的块字节索引（doc.block_index 的副本）。
## 用于搬运未变块的原始字节；落盘失败或索引异常时置空 → 下次退化为全量写（安全）。
##
## 【为什么不再常驻"原始文件字节"】此前与它配对还留了一份 `_raw_bytes` = 整份文件的
## 字节副本，等于在解码后的世界之外又常驻一份编码后的世界（内存翻倍）。
## 现在增量写的基准字节**按需从磁盘读一次**（见 _read_base_bytes）：读盘是 memcpy 级 I/O，
## 相比"重编码全世界"（CPU 密集）代价极小，而写盘的主要 I/O 本就在后台线程承担。
var _block_index: Array = []

## 【增量写 + 单块读·二级索引】每个 VOX0 的子块索引：{ model_id(int): index_vox0_blocks() 的结果 }。
## 除 index_vox0_blocks 给出的子块区间/CRC 外，本类还在其 `_meta` 里补一个 `base` 键
## = 该 VOX0 负载在**文件中的绝对起始偏移**（子块区间是相对的，读单块时必须叠上它）。
##
## 【为什么必须缓存】index_vox0_blocks 要为整个 VOX0 负载（1.4MB）算一遍逐子块 CRC，
## 约 90ms。若每次写盘都重建，子块级增量省下的时间会被它原样吃回去 —— 实测正是如此
## （改 1 个 chunk 仍要 447ms）。这里把它当**持久索引**：加载时建一次，之后每次写盘
## 只对**脏 model** 重建、未变 model 沿用（字节是原样搬运的，索引自然有效，只是 base 要刷新）。
## 它同时是**唯一**的"磁盘上有哪些 chunk"账本 —— load_chunk / has_chunk / 计数都靠它，
## 因为文件内容不再被解码常驻内存。
var _vox0_index: Dictionary = {}

## 【增量写】上次落盘（或加载）时的 HEAD / MATE / NODE 快照，用于判断全局块是否变化。
var _loaded_head: Dictionary = {}
var _loaded_materials: Array = []
var _loaded_node: Dictionary = {}

# 异步取数由 VoxelAsyncLoader 编排：它先问 has_chunk，命中就调 load_chunk 直接取回
# （本类的块索引常驻内存，故不需要后台任务；未落盘的块来自覆盖层，已落盘的按块读盘）。
# 因此本类不实现任何异步接口。

# 真未知块（格式层不认识的类型 -> [payload]）。重写时原样保留，保证不丢外部数据。
# CACH 不在这里——它是一等块，LOD 条目走 _cach_index/_dirty_lod 自己的路径。
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
	# 【不变量校验】本流的全部坐标换算都建立在"块坐标 == chunk 坐标"之上，
	# 即要求 HEAD.block_size == CHUNK_SIZE。block_size=16 的合法 .qvox 若照单全收，
	# 每个 chunk 都会被按 16³ 解码 → 静默读出错误体素（接受却误读）。故 fail-fast 拒绝。
	if doc.get_block_size() != CHUNK_SIZE:
		push_error("[QVoxStream] %s 的 block_size=%d 与本流不兼容（本流要求 %d）"
				% [file_path, doc.get_block_size(), CHUNK_SIZE])
		return
	# 【不加载模型内容】只有块索引进内存：体素数据留在磁盘上，按块读（见 _read_clean_chunk）。
	# doc.models 只是本次解析的中间产物，随 doc 一起在这里被丢弃。
	# 材质：QVox MATE Dictionary → 供上层 set_materials 还原
	_materials = doc.materials
	# NODE 中的附加元数据原样带回
	if doc.node.has("metadata") and doc.node["metadata"] is Dictionary:
		metadata = doc.node["metadata"]
	# 未知块保留
	_unknown_blocks = doc.unknown_blocks.duplicate(true)
	# 【增量写】留存块字节索引，供未变块直接搬运（基准字节写盘时按需读盘，见 _read_base_bytes）
	_block_index = doc.block_index
	_loaded_head = doc.head
	_loaded_materials = doc.materials
	_loaded_node = doc.node
	# 【二级索引】建 VOX0 子块索引（含各子块 CRC），此后每次增量写直接复用，
	# 避免写盘时反复对 1.4MB 负载重算 → 这是子块级增量真正生效的前提。
	# 此时 _dirty_models 为空 → 全部 model 都建（加载后的首次写盘即命中缓存）。
	_build_vox0_index(doc.get_block_size(), bytes)
	# 【派生缓存索引】CACH 里的粗层条目：只记"在哪、来源是什么"，**不解码**缓冲区。
	# 来源是否仍成立改到读时判定（见 _cach_entry_valid）；这里仍必须先有 _vox0_index
	# （校验依据就是它算出的 LOD0 子块 CRC），但不必在加载时把整批缓存解出来。
	_build_cach_index(bytes)


## 把未落盘的改动写盘（原子：写临时文件 → rename）。
##
## 【增量写】磁盘上已有本文件时走 QVoxFile.serialize_incremental：只有变了的子块被重编码，
## 其余块（含 HEAD/MATE/NODE/未知块/CACH）直接搬运磁盘原始字节。这消除了"改一个 chunk
## 就重编码全世界所有 VOX0 块"的浪费（规范 §4 明示"块是编辑的局部性单位"）。
## 磁盘上还没有本文件（首写）时才整文件序列化 —— 此时覆盖层即完整世界，故也正确。
func _write_file() -> void:
	if not _dirty or _write_in_flight:
		return
	# 上次落盘失败会把 _loaded 置回 false（索引已按"未落盘的字节"更新过，不可信）：
	# 这里重新加载，用磁盘上的真实索引做增量基准，避免退化成"只写覆盖层"而丢掉磁盘数据。
	_ensure_loaded()
	_ensure_dir()
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = _build_head()
	doc.materials = _materials_to_qvox()
	doc.models = _overlay_doc_models()
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
	# 本次要替换/删除的旧 CACH 顶层块偏移：必须取自**写之前的** _cach_index（写后偏移全变）。
	var cach_replace := _cach_replace_offsets()
	# 磁盘上已有本文件（且已建 VOX0 子块索引）→ 走增量；否则首写，整文件序列化。
	var incremental := _can_write_incremental()
	var bytes: PackedByteArray
	if incremental:
		# 增量基准 = 磁盘上当前的完整文件字节（按需读一次，不常驻）
		bytes = QVoxFile.serialize_incremental(_read_base_bytes(), old_doc, doc,
				_dirty_models, _dirty_global, true, _deleted, _vox0_index, cach_replace)
	else:
		bytes = QVoxFile.serialize(doc)

	# 【顺序要紧·一】据"待写字节"刷新块索引与 _vox0_index：派生缓存的 source_crc 是
	# "它所依赖的 LOD0 子块 CRC"，必须取自**本次真正写出的字节**。若用内存里的旧索引，
	# 本次改动的 LOD0 块其 CRC 已变 → 缓存来源与实际数据错配 → 下次加载被判失效（白写）。
	_refresh_index_from(bytes)

	# 【顺序要紧·二】追加**变化了的**粗层缓存（CACH）：未变的旧块已在 serialize_incremental
	# 里被原样搬运，故这里只有 _dirty_lod 这几条要写（不是"整批缓存"——整批缓存已随内存镜像
	# 一起删除，只留磁盘上的条目 + 一张轻量索引）。
	var derived := _encode_dirty_cach_entries()
	if not derived.is_empty():
		bytes.append_array(derived)
		_block_index = QVoxFile.scan_block_index(bytes)
	# CACH 块偏移随前面块的大小变化而整体平移 → 按最终字节重建条目索引（轻量：只读头部，不解码）。
	_build_cach_index(bytes)

	# 【快照换出】索引已按新字节更新完毕，此刻把"待写状态"整体取走交给 worker，换来一套空的。
	# 于是写盘期间的新改动落进新的一套；成功收尾只需丢弃快照（不必回头分辨"哪些条目是
	# 本次写的、哪些是飞行中新加的"），失败则并回，一个字都不丢（见 _restore_inflight）。
	_inflight = {
		"overlay": _dirty_buffers, "deleted": _deleted,
		"lod": _dirty_lod, "lod_deleted": _deleted_lod,
		"models": _dirty_models, "global": _dirty_global,
	}
	_dirty_buffers = {}
	_deleted = {}
	_dirty_lod = {}
	_deleted_lod = {}
	_dirty_models = {}
	_dirty_global = false
	_dirty = false
	_dirty_count = 0

	# ---- 落盘：写临时文件 + 原子替换。纯 I/O 交 worker，收尾在主线程（见 _on_write_done）----
	_write_serial += 1
	_write_in_flight = true
	_write_result = [OK]
	var tmp_path := file_path + ".tmp"
	_write_task_id = WorkerThreadPool.add_task(_write_bytes_worker.bind(
		self, _write_serial, bytes, tmp_path,
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(file_path),
		_write_result))


## 后台线程：字节写入临时文件 + 原子替换（读者只会看到旧的完整文件或新的完整文件）。
## 只做文件 I/O，不碰任何资源状态；完成后把结果交回主线程的 _on_write_done 收尾。
static func _write_bytes_worker(owner: Object, serial: int, bytes: PackedByteArray, tmp_path: String,
		abs_tmp: String, abs_path: String, result: Array) -> void:
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		result[0] = FileAccess.get_open_error()
	else:
		f.store_buffer(bytes)
		f.close()
		if FileAccess.file_exists(abs_path):
			DirAccess.remove_absolute(abs_path)
		result[0] = DirAccess.rename_absolute(abs_tmp, abs_path)
	if owner != null:
		owner.call_deferred(&"_on_write_done", serial, result)


## 主线程：落盘收尾。成功即丢弃在途快照（待写状态在换出时已清空，写盘期间的新改动
## 落进新的那套，因此这里什么都不用清）；失败则把快照并回并作废索引基准。
## 过期回调（已被 _wait_pending_write 收尾）直接忽略。
func _on_write_done(serial: int, result: Array) -> void:
	if serial == _write_done_serial or serial != _write_serial:
		return
	_write_done_serial = serial
	_write_in_flight = false
	_write_task_id = -1
	if int(result[0]) != OK:
		push_error("[QVoxStream] 原子替换失败: %s" % error_string(int(result[0])))
		_restore_inflight()
		return
	_inflight = {}   # 本次已落盘，快照可以丢了


## 落盘失败：把在途快照并回当前待写状态，并作废"按未落盘字节"算出的索引。
## 【为什么并回】磁盘上还是旧文件，快照里的改动一个字都没写进去；丢弃即丢数据。
## 【为什么作废索引】_refresh_index_from 已按"将要写出的字节"更新过索引，而文件没换 →
## 索引与文件错位。置 _loaded=false 让下次写盘重新加载磁盘（恢复真实索引），
## 从"未落盘"退化为全量写 —— 而全量写会只写覆盖层，所以这里必须先重建索引，否则丢磁盘数据。
func _restore_inflight() -> void:
	var overlay: Dictionary = _inflight.get("overlay", {})
	for mid in overlay:
		_ensure_sub(_dirty_buffers, int(mid)).merge(overlay[mid], false)   # 飞行中的新写入优先
	var deleted: Dictionary = _inflight.get("deleted", {})
	for mid in deleted:
		_ensure_sub(_deleted, int(mid)).merge(deleted[mid], false)
	var lod_overlay: Dictionary = _inflight.get("lod", {})
	for lod in lod_overlay:
		_ensure_sub(_dirty_lod, int(lod)).merge(lod_overlay[lod], false)
	var lod_deleted: Dictionary = _inflight.get("lod_deleted", {})
	for lod in lod_deleted:
		_ensure_sub(_deleted_lod, int(lod)).merge(lod_deleted[lod], false)
	var models: Dictionary = _inflight.get("models", {})
	for mid in models:
		_dirty_models[int(mid)] = true
	if bool(_inflight.get("global", false)):
		_dirty_global = true
	_inflight = {}
	_dirty = true
	_loaded = false
	_block_index = []
	_vox0_index.clear()
	_cach_index.clear()


## 等待在途落盘任务结束并就地收尾（flush 的同步语义用）。
## 注意：不要挂到 NOTIFICATION_PREDELETE —— RefCounted 的析构通知里脚本实例已失效，调用 self 的方法会报 null instance。
## 退出时若仍有在途写入，损失的只是"这一笔未完成"；文件是原子替换的，不会半写。
func _wait_pending_write() -> void:
	if _write_task_id == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_write_task_id)
	_on_write_done(_write_serial, _write_result)


## 是否可走增量路径：必须有上次的块索引（即此前已 load 或写过一次）且磁盘上有基准文件。
func _can_write_incremental() -> bool:
	return not _block_index.is_empty() and FileAccess.file_exists(file_path)


## 读取磁盘上的基准字节（增量写搬运未变块用）。
##
## 【为什么不常驻】它等于"整份文件的字节副本"。改为每次写盘按需读一次：
## 代价是一次文件读（memcpy 级），而收益是彻底去掉一份随世界增长的内存。
func _read_base_bytes() -> PackedByteArray:
	if not FileAccess.file_exists(file_path):
		return PackedByteArray()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		push_error("[QVoxStream] 无法读取增量基准 %s: %s"
				% [file_path, error_string(FileAccess.get_open_error())])
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


## 用刚写出的字节刷新块索引。**只扫描块头，不解码负载、不校验 CRC/语义**——
## 这些字节是我们自己刚写下的，正确性由写入端保证；这里只需要"块都落在哪些区间"。
## 走完整 parse_with_index 会把每个 VOX0 的 32768 个体素全部解码并跑语义校验，
## 是扫描的数百倍代价（实测 1834ms vs <1ms），且增量写的正确性并不依赖它。
func _refresh_index_from(bytes: PackedByteArray) -> void:
	_block_index = QVoxFile.scan_block_index(bytes)
	if _block_index.is_empty():
		# 扫描异常（不该发生）：清空索引 → 下次退回全量，安全兜底
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
## block_size 固定取 CHUNK_SIZE：本流只接受 block_size == CHUNK_SIZE 的文件
## （加载时已校验，见 _load_file），故这里不存在"回退 32"的猜测。
func _refresh_vox0_index(bytes: PackedByteArray) -> void:
	_build_vox0_index(CHUNK_SIZE, bytes)


## 建/更新 VOX0 子块索引 { model_id: index_vox0_blocks + _meta.base }。基于 _block_index + bytes。
##
## 维护策略（"跟着写入走"）：_dirty_models 里的 model 重算子块索引（其字节变了），
## 其余沿用旧索引（字节原样搬运，子块偏移与 CRC 依旧准确）。
## 于是单次写盘的重索引代价 = O(脏 model 的子块数)，与全世界大小无关。
## bytes 必传：基准字节不再常驻（见 _block_index 注释），由调用方提供当前字节。
##
## `_meta.base`（本 VOX0 负载在文件中的绝对偏移）**每个 model 都要刷**：前面的块大小一变，
## 后面所有块的绝对偏移就跟着变 —— 字节没变、索引内容仍有效，但读单块时要用它定位。
func _build_vox0_index(block_size: int, bytes: PackedByteArray) -> void:
	var src := bytes
	var next_idx: Dictionary = {}
	for bi in _block_index:
		if bi["type"] != QVoxSpec.BLOCK_VOX0:
			continue
		var mid := int(bi.get("model_id", -1))
		if mid < 0:
			continue
		var off: int = bi["offset"]
		var total: int = bi["total"]
		var payload_off := off + QVoxSpec.BLOCK_HEADER_SIZE
		var payload_len := total - QVoxSpec.BLOCK_HEADER_SIZE
		# 未变 model 且已有索引：沿用（省下一次 1.4MB 负载的 CRC 扫描），仅刷新文件基址
		if not _dirty_models.has(mid) and _vox0_index.has(mid):
			var kept: Dictionary = _vox0_index[mid]
			(kept["_meta"] as Dictionary)["base"] = payload_off
			next_idx[mid] = kept
			continue
		# 下界用模型头的实际长度（10 字节），而不是旧的魔法数 6——6~9 字节的负载
		# 能通过旧判据却让 index_vox0_blocks 立刻返回空索引（静默丢块）。
		if payload_len < QVoxSpec.VOX_MODEL_HEADER_SIZE or payload_off + payload_len > src.size():
			continue
		var sub := QVoxFile.index_vox0_blocks(src.slice(payload_off, payload_off + payload_len), block_size)
		(sub["_meta"] as Dictionary)["base"] = payload_off
		next_idx[mid] = sub
	_vox0_index = next_idx


## 构造 HEAD JSON 字典（qvox / channels / block_size / up_axis + 附加元数据）。
## block_size 恒为 CHUNK_SIZE —— 这不是"硬编码"，而是本流的不变量：
## 块坐标 == chunk 坐标（见类注释），block_size 不为 CHUNK_SIZE 的文件在加载时即被拒绝。
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


## 未落盘的写入（_dirty_buffers）→ QVox doc.models（**只含脏块**，不是全世界）。
## 统一输出 int 键；QVoxDocument 的 model_ids()/model_blocks() 会兼容两种键，
## 故读取方无需关心键类型（历史上 int/str 混用曾让增量写无声退化成全量）。
## 这里不做"空块剪除"——save_chunk 早已把全空块转成 erase_chunk（见那里的注释）。
func _overlay_doc_models() -> Dictionary:
	var out: Dictionary = {}
	for mid in _dirty_buffers:
		var blocks: Dictionary = _dirty_buffers[mid]
		if not blocks.is_empty():
			out[int(mid)] = blocks
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


## 从文件字节建 CACH 条目索引（只读头部，**不解码**内容）。
##
## 非本流 kind / 算法版本、结构非法、或无法定界的条目一律不入选 —— 它们既不参与"按需读"，
## 也不会被写盘替换（serialize_incremental 只跳过 _cach_replace_offsets 给出的偏移），
## 于是保持不透明、原样保留。这正是 §6"忽略缓存的读者与用满缓存的读者结果相同"的前提。
##
## payload_off 记的是**内层 vox 负载在文件中的绝对偏移**，据此按需 seek 读盘
## （与 VOX0 的 _read_clean_chunk 同构）；block_off 记顶层 CACH 块偏移，供增量写定位旧块。
func _build_cach_index(bytes: PackedByteArray) -> void:
	var idx: Dictionary = {}
	for bi in _block_index:
		if bi["type"] != QVoxSpec.BLOCK_CACH:
			continue
		var block_off: int = bi["offset"]
		var payload_off := block_off + QVoxSpec.BLOCK_HEADER_SIZE
		var payload_len: int = int(bi["total"]) - QVoxSpec.BLOCK_HEADER_SIZE
		if payload_len < LOD_ENTRY_HEADER or payload_off + payload_len > bytes.size():
			continue
		var payload := bytes.slice(payload_off, payload_off + payload_len)
		var hdr := QVoxFile.parse_cach_header(payload)
		if hdr.is_empty():
			continue
		# §6 规则 2/3：kind 或算法版本不认识 → 不索引（当作别的写入方的数据，原样保留）。
		if String(hdr["kind"]) != CACH_KIND_LOD or int(hdr["algo_version"]) != CACH_LOD_ALGO:
			continue
		var content_off: int = hdr["content_off"]
		if content_off + LOD_ENTRY_HEADER > payload.size():
			continue
		var lod := payload.decode_u16(content_off)
		if lod < 1:
			continue
		# 内层子块头同样复用 QVoxFile.read_vox_block（唯一布局实现）。
		# limit 传整个负载长度：plen 界定内容，其后至多是 CACH 块尾填充，不构成损坏。
		var blk := QVoxFile.read_vox_block(payload, content_off + 2, payload.size())
		if blk.is_empty() or int(blk["codec"]) == QVoxSpec.CODEC_EMPTY:
			continue
		if not idx.has(lod):
			idx[lod] = {}
		(idx[lod] as Dictionary)[blk["key"]] = {
			"block_off": block_off,
			# read_vox_block 的 at = content_off + 2，故它返回的 payload_off
			# **已相对本 slice 且已含 content_off**；叠上 slice 起点即可定位，
			# 不能再加一次 content_off（双重计数会让 seek 越过真实负载 → 读回空块）。
			"payload_off": payload_off + int(blk["payload_off"]),
			"payload_len": int(blk["payload_len"]),
			"codec": int(blk["codec"]),
			"source_crc": hdr["source_crc"],
		}
	_cach_index = idx


## 把**变化了的**粗层块编码为 CACH 块字节（含 12 字节块头）。没有变化时返回空。
##
## 只编码 _dirty_lod：删除的条目无需新字节（serialize_incremental 跳过其旧块即完成删除），
## 未变的条目留在磁盘上原样搬运。source_crc 必须取**本次写出的** LOD0 子块 CRC，
## 故调用点必须在 _refresh_index_from 之后（见 _write_file 的"顺序要紧"注释）。
func _encode_dirty_cach_entries() -> PackedByteArray:
	var entries: Array = []
	var lods := _dirty_lod.keys()
	lods.sort()
	for lod_v in lods:
		var lod := int(lod_v)
		if lod < 1:
			continue
		var by_key: Dictionary = _dirty_lod[lod]
		var keys := by_key.keys()
		keys.sort_custom(_compare_block_keys)
		for k in keys:
			var payload := _pack_lod_block(lod, k, by_key[k])
			if payload.is_empty():
				continue   # 全空块不缓存（save_chunk 已把全空块转 erase，这里是兜底）
			entries.append({
				"kind": CACH_KIND_LOD,
				"algo_version": CACH_LOD_ALGO,
				"source_crc": _lod_expected_crcs(k, lod),
				"payload": payload,
			})
	var out := PackedByteArray()
	QVoxFile.append_cach_blocks(out, entries)
	return out


## 本次写盘需要替换（内容变了）或删除（墓碑）的旧 CACH 顶层块偏移集合。
## 磁盘上还没有的新键没有旧块可跳，自然不在集合里。
## 取自 _cach_index —— 故必须在 _build_cach_index 更新（写后）**之前**调用。
func _cach_replace_offsets() -> Dictionary:
	var out: Dictionary = {}
	for lod in _dirty_lod:
		_collect_cach_offsets(int(lod), _dirty_lod[lod].keys(), out)
	for lod in _deleted_lod:
		_collect_cach_offsets(int(lod), _deleted_lod[lod].keys(), out)
	return out


## 把 (lod, keys) 对应的旧 CACH 顶层块偏移并入 out（磁盘上没有的键自动跳过）。
func _collect_cach_offsets(lod: int, keys: Array, out: Dictionary) -> void:
	var by_key: Variant = _cach_index.get(lod)
	if not (by_key is Dictionary):
		return
	for k in keys:
		var e: Variant = (by_key as Dictionary).get(k)
		if e is Dictionary:
			out[int((e as Dictionary)["block_off"])] = true


## 一个粗层块 → CACH 负载（2 字节 lod + 17 字节子块头 + 打包数据）。全空块不缓存（返回空）。
## 子块部分复用 QVoxFile.write_vox_block：这段 17 字节布局**只在那边维护一处**，
## 免得 LOD 缓存与 VOX0 各自手抄偏移、日后漂移成"两套只有一半读者能读"的格式。
func _pack_lod_block(lod: int, key: Vector3i, buf: PackedInt32Array) -> PackedByteArray:
	if buf.size() != CHUNK_VOLUME:
		return PackedByteArray()
	# 一次完成"选 codec + 出字节"（原生）。此前 pick + pack 是两趟 GDScript 逐元素扫描，
	# 实测约 15ms/块（CACH 重写一次可能带几百个粗层块）。
	var picked := QVoxBlockCodec.choose_and_pack(buf, CHUNK_VOLUME)
	var codec: int = picked.get("codec", QVoxSpec.CODEC_EMPTY)
	if codec == QVoxSpec.CODEC_EMPTY:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, lod & 0xFFFF)
	QVoxFile.write_vox_block(out, key, codec, picked.get("payload", PackedByteArray()))
	return out


## 该 (lod, key) 在磁盘 CACH 索引里的条目信息；没有返回 null。
func _cach_entry(chunk_key: Vector3i, lod: int) -> Variant:
	var by_key: Variant = _cach_index.get(lod)
	if not (by_key is Dictionary):
		return null
	return (by_key as Dictionary).get(chunk_key)


## 磁盘上这条粗层缓存是否**来源仍成立**（§6 规则 1）。索引里没有 → false。
## 校验放在读时：任何一次 LOD0 编辑都会即时让相关缓存失效，无需在加载时整批解码。
func _cach_entry_valid(chunk_key: Vector3i, lod: int) -> bool:
	var e: Variant = _cach_entry(chunk_key, lod)
	if not (e is Dictionary):
		return false
	return _lod_source_matches(chunk_key, lod, (e as Dictionary).get("source_crc", []))


## 按索引 seek 读出**一条**粗层块并解码（不解析整个 CACH）。读取失败 → 空。
## 与 _read_clean_chunk 同构：干净数据不在内存，内存只留"条目在哪"。
func _read_cach_block(e: Dictionary) -> PackedInt32Array:
	if _write_in_flight:
		_wait_pending_write()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return PackedInt32Array()
	f.seek(int(e["payload_off"]))
	var payload := f.get_buffer(int(e["payload_len"]))
	f.close()
	return QVoxBlockCodec.unpack(int(e["codec"]), payload, CHUNK_VOLUME)


## 取一个粗层块：未落盘的覆盖层优先 → 墓碑视为不存在 → 磁盘索引（来源须成立）。
func _load_lod(chunk_key: Vector3i, lod: int) -> PackedInt32Array:
	var pending: Variant = _get_sub(_dirty_lod, lod).get(chunk_key)
	if pending != null:
		return (pending as PackedInt32Array).duplicate()
	if _get_sub(_deleted_lod, lod).has(chunk_key):
		return PackedInt32Array()
	var e: Variant = _cach_entry(chunk_key, lod)
	if not (e is Dictionary):
		return PackedInt32Array()
	if not _lod_source_matches(chunk_key, lod, (e as Dictionary).get("source_crc", [])):
		return PackedInt32Array()   # 来源已变 → 缓存失效（调用方会重新降采样）
	return _read_cach_block(e as Dictionary)


## 当前**有效**的粗层键集合：磁盘索引里来源仍成立 ∪ 覆盖层新增 − 墓碑。
## 用键集合统一 keys / count 两条查询，避免两处各写一遍同一套过滤规则。
func _valid_lod_keys(lod: int) -> Dictionary:
	var out: Dictionary = {}
	var by_key: Variant = _cach_index.get(lod)
	if by_key is Dictionary:
		for k in (by_key as Dictionary):
			if _lod_source_matches(k, lod, (by_key as Dictionary)[k].get("source_crc", [])):
				out[k] = true
	for k in _get_sub(_deleted_lod, lod):
		out.erase(k)
	for k in _get_sub(_dirty_lod, lod):
		out[k] = true
	return out


## 一个粗层块**当前应有**的来源 CRC 集合（升序去重，§6 的表示要求）。
##
## 来源 = 它覆盖的 2^lod³ 个 LOD0 chunk（VoxelChunk.lod_covered_chunks，与降采样同一套
## 坐标），CRC 直接取 _vox0_index[0] 里已算好的**子块 CRC**：降采样只读这些 chunk，
## 故这一组值足以判定"缓存是否过期"，且不产生任何额外扫描（索引本就为增量写而建）。
func _lod_expected_crcs(block_key: Vector3i, lod: int) -> Array:
	var crcs: Array = []
	var l0: Variant = _vox0_index.get(LOD0_MODEL_ID)
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

## lod=0 → 写入覆盖层（落盘时才进 VOX0 model 0）；lod>=1 → CACH 派生缓存（见类注释）。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	_ensure_loaded()
	# 空块 = 不存在（P2）：全零与空数组一律当"删除"处理（save_chunk 的旧实现在写盘时才剪
	# 全零块，于是内存里会留一个永远不落盘的幽灵块，has_chunk 与磁盘分叉）。判空用原生 count(0)。
	if buffer.is_empty() or buffer.count(0) == buffer.size():
		erase_chunk(chunk_key, lod)
		return
	if lod != 0:
		_ensure_sub(_dirty_lod, lod)[chunk_key] = buffer.duplicate()
		_get_sub(_deleted_lod, lod).erase(chunk_key)
		_dirty = true
		_dirty_count += 1
		if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
			_write_file()
		return
	var pending := _ensure_sub(_dirty_buffers, LOD0_MODEL_ID)
	pending[chunk_key] = buffer.duplicate()
	_get_sub(_deleted, LOD0_MODEL_ID).erase(chunk_key)
	_dirty = true
	_dirty_count += 1
	_dirty_models[LOD0_MODEL_ID] = true   # 【增量写】只重建这个 model
	if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
		_write_file()


func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	_ensure_loaded()
	if lod != 0:
		return _load_lod(chunk_key, lod)
	# 未落盘的写入才是最新 → 优先；墓碑 → 视为不存在；否则按块索引从磁盘读。
	var pending: Variant = _get_sub(_dirty_buffers, LOD0_MODEL_ID).get(chunk_key)
	if pending != null:
		return (pending as PackedInt32Array).duplicate()
	if _get_sub(_deleted, LOD0_MODEL_ID).has(chunk_key):
		return PackedInt32Array()
	return _read_clean_chunk(chunk_key)


func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	_ensure_loaded()
	if lod != 0:
		# 与 load_chunk 的三段一致：覆盖层 →（墓碑排除）→ 磁盘索引 + 来源校验。
		# 二者必须给出相同的"命中/未命中"，否则 VoxelAsyncLoader 的 has→load 两步会分叉。
		if _get_sub(_deleted_lod, lod).has(chunk_key):
			return false
		if _get_sub(_dirty_lod, lod).has(chunk_key):
			return true
		return _cach_entry_valid(chunk_key, lod)
	if _get_sub(_dirty_buffers, LOD0_MODEL_ID).has(chunk_key):
		return true
	if _get_sub(_deleted, LOD0_MODEL_ID).has(chunk_key):
		return false
	return _index_has(chunk_key)


func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void:
	_ensure_loaded()
	if lod != 0:
		var touched := false
		var pending := _get_sub(_dirty_lod, lod)
		if pending.has(chunk_key):
			pending.erase(chunk_key)
			touched = true
		# 只有磁盘上确实有这条缓存才需要墓碑；否则墓碑没有指代对象（与 lod=0 同一口径）。
		if _cach_entry(chunk_key, lod) != null:
			_ensure_sub(_deleted_lod, lod)[chunk_key] = true
			touched = true
		if touched:
			_dirty = true
			_dirty_count += 1
		return
	var touched := false
	var pending := _get_sub(_dirty_buffers, LOD0_MODEL_ID)
	if pending.has(chunk_key):
		pending.erase(chunk_key)
		touched = true
	# 只有文件里确实有这一块才需要墓碑；否则墓碑没有指代对象，只会一直躺在内存里。
	# （墓碑是"删除"的证据，写入是"新增/覆盖"的证据，二者互斥 —— save_chunk 会清墓碑。）
	if _index_has(chunk_key):
		var tombstones := _ensure_sub(_deleted, LOD0_MODEL_ID)
		tombstones[chunk_key] = true
		touched = true
	if touched:
		_dirty = true
		_dirty_count += 1
		_dirty_models[LOD0_MODEL_ID] = true   # 【增量写】该 model 的子块集合变了


func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	_ensure_loaded()
	var out: Array[Vector3i] = []
	if lod != 0:
		for k in _valid_lod_keys(lod):
			out.append(k)
		return out
	var index := _l0_index()
	var subs := _subs(index)
	var tombstones := _get_sub(_deleted, LOD0_MODEL_ID)
	# 按磁盘上的物理序给出全部已落盘的块（"_meta" 里的 order 就是物理序）
	var order: Array = (index.get("_meta", {}) as Dictionary).get("order", [])
	for k in order:
		if not tombstones.has(k):
			out.append(k)
	# 覆盖层里"磁盘上还没有"的新块（本轮的净新增）
	for k in _get_sub(_dirty_buffers, LOD0_MODEL_ID):
		if not subs.has(k):
			out.append(k)
	return out


## 计数（不构造 key 数组）。磁盘块数取子块索引的 size（O(1)），只需再遍历
## "待删 / 待写"这两个小集合（受 auto_flush_dirty 上界约束），故与全世界规模无关。
func get_chunk_count(lod: int = 0) -> int:
	_ensure_loaded()
	if lod != 0:
		return _valid_lod_keys(lod).size()
	var subs := _subs(_l0_index())
	var tombstones := _get_sub(_deleted, LOD0_MODEL_ID)
	var n := subs.size()
	for k in tombstones:
		if subs.has(k):
			n -= 1
	for k in _get_sub(_dirty_buffers, LOD0_MODEL_ID):
		if not subs.has(k):
			n += 1
	return n


## 从文件按块索引 seek 出那一块并解码（不解析整个 model）。磁盘上没有 → 空。
##
## 【为什么按需读盘】干净块不再常驻内存（见 _dirty_buffers 的注释），取值路径只有两条：
## 内存覆盖层（未落盘）/ 磁盘随机读（已落盘）。块索引已给出该子块精确的 payload 区间，
## 因此读的是一小块（十几 KB）而非整个 VOX0，代价与块大小同阶。
func _read_clean_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# 在途落盘期间磁盘还是旧文件，而索引已按"将要写出的字节"更新 → 先等它落地再读，避免错位。
	if _write_in_flight:
		_wait_pending_write()
	var index := _l0_index()
	var info: Variant = index.get(chunk_key)   # 顶层条目即区间信息（"_meta" 是 String 键，不会撞车）
	if not (info is Dictionary):
		return PackedInt32Array()
	var base: int = int((index.get("_meta", {}) as Dictionary).get("base", -1))
	if base < 0:
		return PackedInt32Array()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return PackedInt32Array()
	f.seek(base + int(info["payload_off"]))
	var payload := f.get_buffer(int(info["payload_len"]))
	f.close()
	return QVoxBlockCodec.unpack(int(info["codec"]), payload, CHUNK_VOLUME)


## lod=0 在磁盘上的子块索引（含 "_meta"）；没有 VOX0 块时返回空字典。
func _l0_index() -> Dictionary:
	var idx: Variant = _vox0_index.get(LOD0_MODEL_ID)
	return idx if idx is Dictionary else {}


## 取子块"存在性 / CRC"表（index 的 "_meta.sub"）：{ chunk_key(Vector3i): {"crc": int} }。
## 它与 index 的顶层条目（{chunk_key: 区间信息}）**键集相同**，但只带 CRC —— 因此
## "磁盘上有没有这块""有多少块"用它最省，读字节区间则要用顶层条目。缺失时返回空字典。
static func _subs(index: Dictionary) -> Dictionary:
	var meta: Variant = index.get("_meta")
	if not (meta is Dictionary):
		return {}
	var sub: Variant = (meta as Dictionary).get("sub")
	return sub if sub is Dictionary else {}


## 磁盘上是否有该块（纯索引事实，不含墓碑与覆盖层）。
func _index_has(chunk_key: Vector3i) -> bool:
	return _subs(_l0_index()).has(chunk_key)


static func _get_sub(d: Dictionary, key: int) -> Dictionary:
	var v: Variant = d.get(key)
	return v if v is Dictionary else {}


static func _ensure_sub(d: Dictionary, key: int) -> Dictionary:
	if not d.has(key):
		d[key] = {}
	return d[key]


## 同步落盘：先等掉在途任务，再写本次，再等本次完成——保证"返回时脏数据已落盘"。
func flush() -> void:
	_ensure_loaded()
	_wait_pending_write()
	_write_file()
	_wait_pending_write()


func get_stream_path() -> String:
	return file_path


## .qvox 单文件世界：粗层 LOD block 独立持久化在 CACH（kind="LODS"）中，
## 故本流承载粗层（供渲染器判断"可否直接同步降采样"与"是否回写持久化"）。
func supports_lod_layer() -> bool:
	return true


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


## 丢弃全部内存状态（下次访问重新从磁盘载入索引/材质）。不写回 —— 未落盘的改动会丢。
func clear_cache() -> void:
	_dirty_buffers.clear()
	_deleted.clear()
	_dirty_lod.clear()
	_deleted_lod.clear()
	_inflight.clear()
	_dirty = false
	_dirty_count = 0
	_dirty_models.clear()
	_dirty_global = false
	_block_index = []
	_vox0_index.clear()
	_cach_index.clear()
	_loaded = false
