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
##   lod=0 走 model 0（全精度）；lod>=1 各自一个独立 model（各层一 model）。
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

const FILE_EXT := ".qvox"

## 目录型调用方（如程序化流的 persist_directory）使用的固定文件名。
const WORLD_FILE_NAME := "world" + FILE_EXT

## 单文件路径（支持 user:// / res:// 或绝对路径）。默认 user:// 下的世界文件。
@export var file_path: String = "user://voxel_data/" + WORLD_FILE_NAME

## 头部元数据（写入 HEAD 的附加键，读取时原样带回，便于携带世界级参数）。
@export var metadata: Dictionary = {}

## 材质条目（按材质 ID 索引的 Array[Dictionary]，QVox MATE 结构）。
## 由 VoxelData 在 flush 前通过 set_materials() 注入；索引 0 = 空气。
var _materials: Array = []

## 当累计脏块达到该值自动 flush（0 = 关闭自动，仅显式 flush）。防长时间不落盘。
@export var auto_flush_dirty: int = 256

# ----------------------------------------------------------------------------
# 内存权威数据
# ----------------------------------------------------------------------------
# lod=0 → model 0；lod=n（n>=1）→ model n。每个 model 是 {block_index: PackedInt32Array}。
# block_index（Vector3i）即 chunk 坐标（block_size == CHUNK_SIZE）。
var _models: Dictionary = {}

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

# 异步请求簿记见基类 VoxelStream（_async_pending / _async_enqueue / ...）：数据就在内存，
# poll 时就地回填。

# 未内建解析的块（类型 -> [payload]），含真未知类型与 CACH。重写时原样保留，保证不丢外部数据。
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
	# models → _models（键即 model_id）
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

	var bytes: PackedByteArray
	var incr_ok := _can_write_incremental()
	if incr_ok:
		var old_doc := QVoxFile.QVoxDocument.new()
		# 增量路径只需要 block_index 与旧 head/materials/node（用于变化对比）
		old_doc.block_index = _block_index
		old_doc.head = _loaded_head
		old_doc.materials = _loaded_materials
		old_doc.node = _loaded_node
		bytes = QVoxFile.serialize_incremental(_raw_bytes, old_doc, doc, _dirty_models, _dirty_global, true, _dirty_chunks, _vox0_index)
	else:
		bytes = QVoxFile.serialize(doc)

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
		return
	_dirty = false
	_dirty_count = 0
	_dirty_global = false
	# 写后重建索引：把刚写出的字节重新扫描一次，得到新文件的块区间供下次增量。
	# 这样增量可以连续进行（每次都基于最新的磁盘布局），且避免了手工跟踪块偏移。
	# 【顺序要紧】_refresh_vox0_index 需要"本次哪些 model 是脏的"来决定重建范围，
	# 所以必须在 _dirty_models.clear() **之前**调用；调用完再清空脏集合。
	_refresh_index_from(bytes)
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
## 【必须幂等】`_materials` 有两种来源：
##   1) 上层经 set_materials() 注入的 VoxelMaterial 对象（属性 color/trans/metal/...）；
##   2) 从磁盘加载时直接赋值的 MATE Dictionary（键 rgba/metal/...，见 _ensure_loaded）。
## 早先这里只认 (1)：于是"加载 → 改块 → flush"时，(2) 被当成 (1) 重新解释——
## 没有 `color` 键 → 取 Color.WHITE，**所有材质被静默写成白色**（且 alpha 变 255）。
## 现在先识别"已经是 MATE 形状"的输入并原样归一化，两种来源都正确、多次写盘稳定。
##
## 条目 0 恒为空气（全零，§4）：体素值 0 就是空气，故无论调用方给的是什么，
## 这一条都必须归零——它是格式不变量，不该指望每个调用方都记得。
func _materials_to_qvox() -> Array:
	var out: Array = []
	for i in _materials.size():
		var m: Variant = _materials[i]
		if i == 0 or m == null:
			out.append(_air_entry())
			continue
		if m is Dictionary and (m as Dictionary).has("rgba"):
			out.append(_mate_from_dict(m as Dictionary))
			continue
		out.append(_mate_from_material(m))
	return out


## 空气条目（条目 0 的规范形态，§4）。每次返回新字典，避免调用方彼此共享引用。
func _air_entry() -> Dictionary:
	return {
		"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0,
		"e_r": 0, "e_g": 0, "e_b": 0,
	}


## 已是 MATE 形状的 Dictionary → 规范化（掩码到合法范围），供幂等写盘使用。
func _mate_from_dict(d: Dictionary) -> Dictionary:
	return {
		"rgba": int(d.get("rgba", 0)) & 0xFFFFFFFF,
		"metal": clampi(int(d.get("metal", 0)), 0, 255),
		"rough": clampi(int(d.get("rough", 0)), 0, 255),
		"hardness": clampi(int(d.get("hardness", 0)), 0, 255),
		"mass": clampi(int(d.get("mass", 0)), 0, 255),
		"e_r": clampi(int(d.get("e_r", 0)), 0, 255),
		"e_g": clampi(int(d.get("e_g", 0)), 0, 255),
		"e_b": clampi(int(d.get("e_b", 0)), 0, 255),
	}


## 上层 VoxelMaterial 对象 → MATE 条目。
func _mate_from_material(m: Variant) -> Dictionary:
	var c: Color = m.color if ("color" in m) else Color.WHITE
	var a := int(round((1.0 - float(m.trans)) * 255.0)) if ("trans" in m) else 255
	a = clampi(a, 0, 255)
	var rgba := (int(c.r * 255.0) << 24) | (int(c.g * 255.0) << 16) | (int(c.b * 255.0) << 8) | a
	var em: float = float(m.emission) if ("emission" in m) else 0.0
	return {
		"rgba": rgba & 0xFFFFFFFF,
		"metal": clampi(int(round(float(m.metal) * 255.0)), 0, 255) if ("metal" in m) else 0,
		"rough": clampi(int(round(float(m.rough) * 255.0)), 0, 255) if ("rough" in m) else 255,
		"hardness": clampi(int(round(float(m.hardness))), 0, 255) if ("hardness" in m) else 1,
		"mass": clampi(int(round(float(m.mass))), 0, 255) if ("mass" in m) else 1,
		"e_r": clampi(int(round(c.r * em * 255.0)), 0, 255),
		"e_g": clampi(int(round(c.g * em * 255.0)), 0, 255),
		"e_b": clampi(int(round(c.b * em * 255.0)), 0, 255),
	}


## 内存 _models（int model_id → {Vector3i: PackedInt32Array}）→ QVox doc.models（字符串键）。
func _models_to_qvox_models() -> Dictionary:
	var out: Dictionary = {}
	for mid in _models:
		out[str(mid)] = _prune_empty(_models[mid])
	return out


## 去掉全零块（空块不落盘，P2 / §5.1）。
func _prune_empty(blocks: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in blocks:
		var buf: PackedInt32Array = blocks[k]
		for i in buf.size():
			if buf[i] != 0:
				out[k] = buf
				break
	return out


# ----------------------------------------------------------------------------
# VoxelStream 接口实现
# ----------------------------------------------------------------------------

func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	_ensure_loaded()
	if buffer.is_empty():
		erase_chunk(chunk_key, lod)
		return
	var model_id := lod  # lod=0 → model 0；lod=n → model n
	if not _models.has(model_id):
		_models[model_id] = {}
	_models[model_id][chunk_key] = buffer.duplicate()
	_dirty = true
	_dirty_count += 1
	_dirty_models[model_id] = true   # 【增量写】只重编码这个 model
	_mark_chunk_dirty(model_id, chunk_key)
	if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
		_write_file()


func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	_ensure_loaded()
	var model_id := lod
	if not _models.has(model_id):
		return PackedInt32Array()
	var blocks: Dictionary = _models[model_id]
	var buf: Variant = blocks.get(chunk_key)
	if buf == null:
		return PackedInt32Array()
	return (buf as PackedInt32Array).duplicate()


func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	_ensure_loaded()
	var model_id := lod
	if not _models.has(model_id):
		return false
	return (_models[model_id] as Dictionary).has(chunk_key)


func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void:
	_ensure_loaded()
	var model_id := lod
	if not _models.has(model_id):
		return
	var blocks: Dictionary = _models[model_id]
	if blocks.has(chunk_key):
		blocks.erase(chunk_key)
		_dirty = true
		_dirty_count += 1
		_dirty_models[model_id] = true   # 【增量写】
		_mark_chunk_dirty(model_id, chunk_key)


## 登记一个脏 chunk（子块级增量用）。删除 chunk 也登记——那样该 model 的
## 子块集合会变化，encode_vox0_incremental 会检测到并让调用方退回整编码。
func _mark_chunk_dirty(model_id: int, chunk_key: Vector3i) -> void:
	if not _dirty_chunks.has(model_id):
		_dirty_chunks[model_id] = {}
	(_dirty_chunks[model_id] as Dictionary)[chunk_key] = true


func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	_ensure_loaded()
	var out: Array[Vector3i] = []
	var model_id := lod
	if not _models.has(model_id):
		return out
	for k in (_models[model_id] as Dictionary):
		out.append(k)
	return out


func flush() -> void:
	_ensure_loaded()
	_write_file()


func get_stream_path() -> String:
	return file_path


# ----------------------------------------------------------------------------
# 统一异步接口（与 VoxelProceduralStream 共用同一套流式加载）
# 簿记（登记 / 去重 / 取出）复用基类 VoxelStream 的 _async_* 工具
# ----------------------------------------------------------------------------

## 异步请求：数据常驻内存，直接登记即可（poll 时就地读回），无需后台任务。
func request_chunk_async(chunk_key: Vector3i, lod: int = 0) -> void:
	if lod != 0:
		return
	_ensure_loaded()
	_async_enqueue(chunk_key, 0)


func poll_all_ready(max_count: int) -> Array:
	var out: Array = []
	for e in _async_pending_keys():
		if out.size() >= max_count:
			break
		var lod: int = e[0]
		var ck: Vector3i = e[1]
		_async_drop_pending(ck, lod)
		var buf := load_chunk(ck, lod)
		if buf.is_empty():
			continue
		out.append([lod, ck, buf])
	return out


func is_chunk_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	if lod != 0:
		return false
	return _async_is_pending(chunk_key, 0)


# clear_async_state() 复用基类实现（清空在途 / 就绪登记）。


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
	_dirty = false
	_dirty_count = 0
	_dirty_models.clear()
	_dirty_chunks.clear()
	_dirty_global = false
	_block_index = []
	_raw_bytes = PackedByteArray()
	_vox0_index.clear()
	_loaded = false
