class_name QVoxelStream
extends VoxelStream

## 磁盘文件流（QVX 单文件块流）—— .qvx 格式，一个文件承载整个世界。

## QVoxelSpec / QVoxelFile / QVoxelBlockCodec 均为全局注册类（class_name），直接按名引用，

const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME

const FILE_EXT := "." + QVoxelSpec.FILE_EXT

## 按目录组织存档的调用方使用的固定文件名（一个目录承载整个世界）。
const WORLD_FILE_NAME := "world" + FILE_EXT

## LOD 派生缓存在 CACH 里的命名空间与算法版本（§6：kind 由写入方定义，格式不解释）。
const CACH_KIND_LOD := "LODS"
const CACH_LOD_ALGO := 1

## LOD0（全精度权威数据）所在的 model_id。
const LOD0_MODEL_ID := 0

## 单文件路径（支持 user:// / res:// 或绝对路径）。
@export var file_path: String = "user://voxel_data/" + WORLD_FILE_NAME

## 头部元数据（写入 HEAD 的附加键，读取时原样带回，便于携带世界级参数）。
@export var metadata: Dictionary = {}

## 材质条目（按材质 ID 索引的 Array[Dictionary]，QVX MATE 结构）。
var _materials: Array = []

## 当累计脏块达到该值自动 flush（0 = 关闭自动，仅显式 flush）。
@export var auto_flush_dirty: int = 256

## 在途落盘任务：I/O 在 worker、收尾在主线程。
var _write_in_flight := false
var _write_task_id: int = -1
var _write_serial := 0
var _write_done_serial: int = -1
var _write_result: Array = []

## 在途写盘的**输入快照**（_write_file 换出、_on_write_done 丢弃；失败则并回）。
var _inflight: Dictionary = {}

# 内存状态：只留"未落盘的改动"，不留全世界的解码镜像

## 写入覆盖层：chunk_key(Vector3i) → PackedInt32Array。
var _dirty_buffers: Dictionary = {}

## 删除墓碑：chunk_key(Vector3i) → true。
var _deleted: Dictionary = {}

## 粗层写入覆盖层：lod(>=1) → { block_key(Vector3i): PackedInt32Array }。
var _dirty_lod: Dictionary = {}

## 粗层删除墓碑：lod(>=1) → { block_key(Vector3i): true }。
var _deleted_lod: Dictionary = {}

## CACH 条目轻量索引（本流只认 kind="LODS"、algo_version=CACH_LOD_ALGO）：
var _cach_index: Dictionary = {}

var _dirty := false
var _dirty_count := 0
var _loaded := false

## 【增量写】本流的 VXEL 块（LOD0）是否需要重建。
var _vxel_dirty := false

## 【增量写】非 model 全局块（HEAD/MATE/NODE）是否需要重编码。
var _dirty_global := false

## 【增量写】上次解析出的块字节索引（doc.block_index 的副本）。
var _block_index: Array = []

## 【增量写 + 单块读·二级索引】每个 VXEL 的子块索引：{ model_id(int): index_vxel_blocks()…
var _vxel_index: Dictionary = {}

## 【增量写】上次落盘（或加载）时的 HEAD / MATE / NODE 快照，用于判断全局块是否变化。
var _loaded_head: Dictionary = {}
var _loaded_materials: Array = []
var _loaded_node: Dictionary = {}

# 异步取数由 VoxelAsyncLoader 编排：它先问 has_chunk，命中就调 load_chunk 直接取回

# 真未知块（格式层不认识的类型 -> [payload]）。
var _unknown_blocks: Dictionary = {}

# 路径 / 目录

func _ensure_dir() -> void:
	var dir := file_path.get_base_dir()
	var abs := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)

# 加载 / 保存（整文件）

## 确保内存权威数据已从磁盘载入（幂等）。
func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(file_path):
		return
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		push_error("[QVoxelStream] 无法读取 %s: %s" % [file_path, error_string(FileAccess.get_open_error())])
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse_with_index(bytes)
	if doc == null:
		# 磁盘上的文件损坏 = 外部数据不合法，已按约定降级为空世界 → warning（上面「打不开文件」才是环境问题，保持 error）。
		push_warning("[QVoxelStream] %s 解析失败，按空世界处理" % file_path)
		return
	# 【不变量校验】本流的全部坐标换算都建立在"块坐标 == chunk 坐标"之上，
	if doc.get_block_size() != CHUNK_SIZE:
		# 合法但与本流约定不符的旧文件 → 同样是「输入不合法，已拒绝」，warning。
		push_warning("[QVoxelStream] %s 的 block_size=%d 与本流不兼容（本流要求 %d）"
				% [file_path, doc.get_block_size(), CHUNK_SIZE])
		return
	# 【不加载模型内容】只有块索引进内存：体素数据留在磁盘上，按块读（见 _read_clean_chunk）。
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
	# 【二级索引】建 VXEL 子块索引（含各子块 CRC），此后每次增量写直接复用，
	_build_vxel_index(doc.get_block_size(), bytes)
	# 【派生缓存索引】CACH 里的粗层条目：只记"在哪、来源是什么"，**不解码**缓冲区。
	_build_cach_index(bytes)

## 把未落盘的改动写盘（原子：写临时文件 → rename）。
func _write_file() -> void:
	if not _dirty or _write_in_flight:
		return
	# 上次落盘失败会把 _loaded 置回 false（索引已按"未落盘的字节"更新过，不可信）：
	_ensure_loaded()
	_ensure_dir()
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = _build_head()
	doc.materials = _materials_to_qvx()
	doc.models = _overlay_doc_models()
	var node := {}
	if not metadata.is_empty():
		node["metadata"] = metadata
	doc.node = node
	doc.unknown_blocks = _unknown_blocks

	# 增量路径只需要 block_index 与旧 head/materials/node（用于变化对比）
	var old_doc := QVoxelFile.QVoxelDocument.new()
	old_doc.block_index = _block_index
	old_doc.head = _loaded_head
	old_doc.materials = _loaded_materials
	old_doc.node = _loaded_node
	# 本次要替换/删除的旧 CACH 顶层块偏移：必须取自**写之前的** _cach_index（写后偏移全变）。
	var cach_replace := _cach_replace_offsets()
	# 磁盘上已有本文件（且已建 VXEL 子块索引）→ 走增量；否则首写，整文件序列化。
	var incremental := _can_write_incremental()
	var bytes: PackedByteArray
	if incremental:
		# 内部账本是扁平的"世界层"，格式层要的是 model_id 键 → 只在这两处调用点还原
		var dirty_models := {LOD0_MODEL_ID: true} if _vxel_dirty else {}
		# 增量基准 = 磁盘上当前的完整文件字节（按需读一次，不常驻）
		bytes = QVoxelFile.serialize_incremental(_read_base_bytes(), old_doc, doc,
				dirty_models, _dirty_global, true, {LOD0_MODEL_ID: _deleted}, _vxel_index, cach_replace)
	else:
		bytes = QVoxelFile.serialize(doc)

	# 【顺序要紧·一】据"待写字节"刷新块索引与 _vxel_index：派生缓存的 source_crc 是
	_refresh_index_from(bytes)

	# 【顺序要紧·二】追加**变化了的**粗层缓存（CACH）：未变的旧块已在 serialize_incremental
	var derived := _encode_dirty_cach_entries()
	if not derived.is_empty():
		bytes.append_array(derived)
		_block_index = QVoxelFile.scan_block_index(bytes)
	# CACH 块偏移随前面块的大小变化而整体平移 → 按最终字节重建条目索引（轻量：只读头部，不解码）。
	_build_cach_index(bytes)

	# 【快照换出】索引已按新字节更新完毕，此刻把"待写状态"整体取走交给 worker，换来一套空的。
	_inflight = {
		"overlay": _dirty_buffers, "deleted": _deleted,
		"lod": _dirty_lod, "lod_deleted": _deleted_lod,
		"vxel_dirty": _vxel_dirty, "global": _dirty_global,
	}
	_dirty_buffers = {}
	_deleted = {}
	_dirty_lod = {}
	_deleted_lod = {}
	_vxel_dirty = false
	_dirty_global = false
	_dirty = false
	_dirty_count = 0

	# ---- 落盘：写临时文件 + 原子替换。
	_write_serial += 1
	_write_in_flight = true
	_write_result = [OK]
	var tmp_path := file_path + ".tmp"
	_write_task_id = WorkerThreadPool.add_task(_write_bytes_worker.bind(
		self, _write_serial, bytes, tmp_path,
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(file_path),
		_write_result))

## 后台线程：字节写入临时文件 + 原子替换（读者只会看到旧的完整文件或新的完整文件）。
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

## 主线程：落盘收尾。
func _on_write_done(serial: int, result: Array) -> void:
	if serial == _write_done_serial or serial != _write_serial:
		return
	_write_done_serial = serial
	_write_in_flight = false
	_write_task_id = -1
	if int(result[0]) != OK:
		push_error("[QVoxelStream] 原子替换失败: %s" % error_string(int(result[0])))
		_restore_inflight()
		return
	_inflight = {}   # 本次已落盘，快照可以丢了

## 落盘失败：把在途快照并回当前待写状态，并作废"按未落盘字节"算出的索引。
func _restore_inflight() -> void:
	# 飞行中的新写入优先（overwrite=false）：快照里的是"更早、没写成功"的那批。
	_dirty_buffers.merge(_inflight.get("overlay", {}), false)
	_deleted.merge(_inflight.get("deleted", {}), false)
	# 粗层的 lod 是真维度（1..N 同时存在），故仍按层合并。
	var lod_overlay: Dictionary = _inflight.get("lod", {})
	for lod in lod_overlay:
		_ensure_sub(_dirty_lod, int(lod)).merge(lod_overlay[lod], false)
	var lod_deleted: Dictionary = _inflight.get("lod_deleted", {})
	for lod in lod_deleted:
		_ensure_sub(_deleted_lod, int(lod)).merge(lod_deleted[lod], false)
	if bool(_inflight.get("vxel_dirty", false)):
		_vxel_dirty = true
	if bool(_inflight.get("global", false)):
		_dirty_global = true
	_inflight = {}
	_dirty = true
	# 【必须重数】并回的这些改动又要重新排队等落盘，计数必须反映真实待写量：
	_dirty_count = _count_pending()
	_loaded = false
	_block_index = []
	_vxel_index.clear()
	_cach_index.clear()

## 等待在途落盘任务结束并就地收尾（flush 的同步语义用）。
func _wait_pending_write() -> void:
	if _write_task_id == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_write_task_id)
	_on_write_done(_write_serial, _write_result)

## 是否可走增量路径：必须有上次的块索引（即已 load 或写过一次）且磁盘上有基准文件。
func _can_write_incremental() -> bool:
	return not _block_index.is_empty() and FileAccess.file_exists(file_path)

## 读取磁盘上的基准字节（增量写搬运未变块用）。
func _read_base_bytes() -> PackedByteArray:
	if not FileAccess.file_exists(file_path):
		return PackedByteArray()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		push_error("[QVoxelStream] 无法读取增量基准 %s: %s"
				% [file_path, error_string(FileAccess.get_open_error())])
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b

## 用刚写出的字节刷新块索引。
func _refresh_index_from(bytes: PackedByteArray) -> void:
	_block_index = QVoxelFile.scan_block_index(bytes)
	if _block_index.is_empty():
		# 扫描异常（不该发生）：清空索引 → 下次退回全量，安全兜底
		_vxel_index.clear()
		return
	# head/materials/node 快照仍从新写出的 doc 语义侧取（写入端已知其内容，
	_loaded_head = _build_head()
	_loaded_materials = _materials_to_qvx()
	_loaded_node = {}
	if not metadata.is_empty():
		_loaded_node["metadata"] = metadata
	# 【二级索引维护】只重建**脏 model** 的子块索引；未变的 model 其子块字节是原样
	_refresh_vxel_index(bytes)

## 写后重建 VXEL 子块索引。
func _refresh_vxel_index(bytes: PackedByteArray) -> void:
	_build_vxel_index(CHUNK_SIZE, bytes)

## 建/更新 VXEL 子块索引 { model_id: index_vxel_blocks + _meta.base }。
func _build_vxel_index(block_size: int, bytes: PackedByteArray) -> void:
	var src := bytes
	var next_idx: Dictionary = {}
	for bi in _block_index:
		if bi["type"] != QVoxelSpec.BLOCK_VXEL:
			continue
		var mid := int(bi.get("model_id", -1))
		if mid < 0:
			continue
		var off: int = bi["offset"]
		var total: int = bi["total"]
		var payload_off := off + QVoxelSpec.BLOCK_HEADER_SIZE
		var payload_len := total - QVoxelSpec.BLOCK_HEADER_SIZE
		# 未变 model 且已有索引：沿用（省下一次 1.4MB 负载的 CRC 扫描），仅刷新文件基址。
		if not (mid == LOD0_MODEL_ID and _vxel_dirty) and _vxel_index.has(mid):
			var kept: Dictionary = _vxel_index[mid]
			(kept["_meta"] as Dictionary)["base"] = payload_off
			next_idx[mid] = kept
			continue
		# 下界用模型头的实际长度（10 字节），而不是旧的魔法数 6——6~9 字节的负载
		if payload_len < QVoxelSpec.VXEL_MODEL_HEADER_SIZE or payload_off + payload_len > src.size():
			continue
		var sub := QVoxelFile.index_vxel_blocks(src.slice(payload_off, payload_off + payload_len))
		(sub["_meta"] as Dictionary)["base"] = payload_off
		next_idx[mid] = sub
	_vxel_index = next_idx

## 构造 HEAD JSON 字典（qvx / channels / block_size / up_axis + 附加元数据）。
func _build_head() -> Dictionary:
	var head := {
		"qvox": QVoxelSpec.VERSION,
		QVoxelSpec.HEAD_CHANNEL_KEY: QVoxelSpec.DOMINANT_CHANNEL,
		QVoxelSpec.HEAD_BPP_KEY: QVoxelSpec.CHANNEL_BPP,
		"block_size": CHUNK_SIZE,
		QVoxelSpec.HEAD_UP_AXIS_KEY: QVoxelSpec.DEFAULT_UP_AXIS,
	}
	# 附加键（metadata 里的自定义键并入 HEAD，便于携带世界级参数）
	for k in metadata:
		if k == "qvox" or k == QVoxelSpec.HEAD_CHANNEL_KEY or k == QVoxelSpec.HEAD_BPP_KEY \
				or k == QVoxelSpec.HEAD_BLOCK_SIZE_KEY or k == QVoxelSpec.HEAD_UP_AXIS_KEY:
			continue
		head[k] = metadata[k]
	return head

## 上层材质数组 → QVX MATE Dictionary 列表。
func _materials_to_qvx() -> Array:
	var out: Array = []
	for i in _materials.size():
		out.append(QVoxelMate.air_entry() if i == 0 else VoxelMaterial.to_mate(_materials[i]))
	return out

## 未落盘的写入（_dirty_buffers）→ QVX doc.models（**只含脏块**，不是全世界）。
func _overlay_doc_models() -> Dictionary:
	if _dirty_buffers.is_empty():
		return {}
	return {LOD0_MODEL_ID: _dirty_buffers}

# LOD 派生缓存（CACH，§6）

const LOD_ENTRY_HEADER := 2 + QVoxelSpec.VOX_BLOCK_HEADER_SIZE

## 从文件字节建 CACH 条目索引（只读头部，**不解码**内容）。
func _build_cach_index(bytes: PackedByteArray) -> void:
	var idx: Dictionary = {}
	for bi in _block_index:
		if bi["type"] != QVoxelSpec.BLOCK_CACH:
			continue
		var block_off: int = bi["offset"]
		var payload_off := block_off + QVoxelSpec.BLOCK_HEADER_SIZE
		var payload_len: int = int(bi["total"]) - QVoxelSpec.BLOCK_HEADER_SIZE
		if payload_len < LOD_ENTRY_HEADER or payload_off + payload_len > bytes.size():
			continue
		var payload := bytes.slice(payload_off, payload_off + payload_len)
		var hdr := QVoxelBlockStream.parse_cach_header(payload)
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
		# 内层子块头同样复用 QVoxelBlockStream.read_sub_block（唯一布局实现）。
		var blk := QVoxelBlockStream.read_sub_block(payload, content_off + 2, payload.size())
		if blk.is_empty() or int(blk["codec"]) == QVoxelSpec.CODEC_EMPTY:
			continue
		if not idx.has(lod):
			idx[lod] = {}
		(idx[lod] as Dictionary)[blk["key"]] = {
			"block_off": block_off,
			# read_sub_block 的 at = content_off + 2，故它返回的 payload_off
			"payload_off": payload_off + int(blk["payload_off"]),
			"payload_len": int(blk["payload_len"]),
			"codec": int(blk["codec"]),
			"source_crc": hdr["source_crc"],
		}
	_cach_index = idx

## 把**变化了的**粗层块编码为 CACH 块字节（含 12 字节块头）。
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
	QVoxelBlockStream.append_cach_blocks(out, entries)
	return out

## 本次写盘需要替换（内容变了）或删除（墓碑）的旧 CACH 顶层块偏移集合。
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

## 一个粗层块 → CACH 负载（2 字节 lod + 17 字节子块头 + 打包数据）。
func _pack_lod_block(lod: int, key: Vector3i, buf: PackedInt32Array) -> PackedByteArray:
	if buf.size() != CHUNK_VOLUME:
		return PackedByteArray()
	# 一次完成"选 codec + 出字节"（原生）。
	var picked := QVoxelBlockCodec.choose_and_pack(buf, CHUNK_VOLUME)
	var codec: int = picked.get("codec", QVoxelSpec.CODEC_EMPTY)
	if codec == QVoxelSpec.CODEC_EMPTY:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, lod & 0xFFFF)
	QVoxelBlockStream.write_sub_block(out, key, codec, picked.get("payload", PackedByteArray()))
	return out

## 该 (lod, key) 在磁盘 CACH 索引里的条目信息；没有返回 null。
func _cach_entry(chunk_key: Vector3i, lod: int) -> Variant:
	var by_key: Variant = _cach_index.get(lod)
	if not (by_key is Dictionary):
		return null
	return (by_key as Dictionary).get(chunk_key)

## 磁盘上这条粗层缓存是否**来源仍成立**（§6 规则 1）。
func _cach_entry_valid(chunk_key: Vector3i, lod: int) -> bool:
	var e: Variant = _cach_entry(chunk_key, lod)
	if not (e is Dictionary):
		return false
	return _lod_source_matches(chunk_key, lod, (e as Dictionary).get("source_crc", []))

## 按索引 seek 读出**一条**粗层块并解码（不解析整个 CACH）。
func _read_cach_block(e: Dictionary) -> PackedInt32Array:
	if _write_in_flight:
		_wait_pending_write()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return PackedInt32Array()
	f.seek(int(e["payload_off"]))
	var payload := f.get_buffer(int(e["payload_len"]))
	f.close()
	return QVoxelBlockCodec.unpack(int(e["codec"]), payload, CHUNK_VOLUME)

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
func _lod_expected_crcs(block_key: Vector3i, lod: int) -> Array:
	var crcs: Array = []
	var l0: Variant = _vxel_index.get(LOD0_MODEL_ID)
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
	return QVoxelBlockCodec.key_less(a, b)

# 脏标记（唯一入口）

## 记一个待落盘改动，并在达到 auto_flush_dirty 时自动落盘。
func _mark_dirty() -> void:
	_dirty = true
	_dirty_count += 1
	if auto_flush_dirty > 0 and _dirty_count >= auto_flush_dirty:
		_write_file()

## 按当前待写集合**重数**脏计数（只在并回这类边界上用：正常路径靠 _mark_dirty 增量维护）。
func _count_pending() -> int:
	var n := _dirty_buffers.size() + _deleted.size()
	for lod in _dirty_lod:
		n += (_dirty_lod[lod] as Dictionary).size()
	for lod in _deleted_lod:
		n += (_deleted_lod[lod] as Dictionary).size()
	return n

# VoxelStream 接口实现

## lod=0 → 写入覆盖层（落盘时才进 VXEL model 0）；lod>=1 → CACH 派生缓存（见类注释）。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	_ensure_loaded()
	# 空块 = 不存在（P2）：全零与空数组一律当"删除"处理（等写盘时才剪全零块，会让内存里
	if buffer.is_empty() or buffer.count(0) == buffer.size():
		erase_chunk(chunk_key, lod)
		return
	if lod != 0:
		_ensure_sub(_dirty_lod, lod)[chunk_key] = buffer.duplicate()
		_get_sub(_deleted_lod, lod).erase(chunk_key)
		_mark_dirty()
		return
	_dirty_buffers[chunk_key] = buffer.duplicate()
	_deleted.erase(chunk_key)
	_vxel_dirty = true   # 【增量写】LOD0 这个 model 需要重建
	_mark_dirty()

func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	_ensure_loaded()
	if lod != 0:
		return _load_lod(chunk_key, lod)
	# 未落盘的写入才是最新 → 优先；墓碑 → 视为不存在；否则按块索引从磁盘读。
	var pending: Variant = _dirty_buffers.get(chunk_key)
	if pending != null:
		return (pending as PackedInt32Array).duplicate()
	if _deleted.has(chunk_key):
		return PackedInt32Array()
	return _read_clean_chunk(chunk_key)

func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	_ensure_loaded()
	if lod != 0:
		# 与 load_chunk 的三段一致：覆盖层 →（墓碑排除）→ 磁盘索引 + 来源校验。
		if _get_sub(_deleted_lod, lod).has(chunk_key):
			return false
		if _get_sub(_dirty_lod, lod).has(chunk_key):
			return true
		return _cach_entry_valid(chunk_key, lod)
	if _dirty_buffers.has(chunk_key):
		return true
	if _deleted.has(chunk_key):
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
			_mark_dirty()
		return
	var touched := _dirty_buffers.erase(chunk_key)
	# 只有文件里确实有这一块才需要墓碑；否则墓碑没有指代对象，只会一直躺在内存里。
	if _index_has(chunk_key):
		_deleted[chunk_key] = true
		touched = true
	if touched:
		_vxel_dirty = true   # 【增量写】LOD0 的子块集合变了
		_mark_dirty()

func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	_ensure_loaded()
	var out: Array[Vector3i] = []
	if lod != 0:
		for k in _valid_lod_keys(lod):
			out.append(k)
		return out
	var index := _l0_index()
	var subs := _subs(index)
	# 按磁盘上的物理序给出全部已落盘的块（"_meta" 里的 order 就是物理序）
	var order: Array = (index.get("_meta", {}) as Dictionary).get("order", [])
	for k in order:
		if not _deleted.has(k):
			out.append(k)
	# 覆盖层里"磁盘上还没有"的新块
	for k in _dirty_buffers:
		if not subs.has(k):
			out.append(k)
	return out

## 计数（不构造 key 数组）。
func get_chunk_count(lod: int = 0) -> int:
	_ensure_loaded()
	if lod != 0:
		return _valid_lod_keys(lod).size()
	var subs := _subs(_l0_index())
	var n := subs.size()
	for k in _deleted:
		if subs.has(k):
			n -= 1
	for k in _dirty_buffers:
		if not subs.has(k):
			n += 1
	return n

## 从文件按块索引 seek 出那一块并解码（不解析整个 model）。
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
	return QVoxelBlockCodec.unpack(int(info["codec"]), payload, CHUNK_VOLUME)

## lod=0 在磁盘上的子块索引（含 "_meta"）；没有 VXEL 块时返回空字典。
func _l0_index() -> Dictionary:
	var idx: Variant = _vxel_index.get(LOD0_MODEL_ID)
	return idx if idx is Dictionary else {}

## 取子块"存在性 / CRC"表（index 的 "_meta.sub"）：{ chunk_key(Vector3i): {"crc":…
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

## .qvx 单文件世界：粗层 LOD block 独立持久化在 CACH（kind="LODS"）中，
func supports_lod_layer() -> bool:
	return true

# 异步取数（request / poll / 在途查询）不在本类：存储只回答"存没存、取出来"，

# 上层注入 / 查询

## 注入材质数组（QVoxelSource.materials）。
func set_materials(mats: Array) -> void:
	_materials = mats
	_dirty = true
	_dirty_global = true   # 【增量写】MATE 属全局块，需重编码

## 是否有未落盘的修改。
func is_dirty() -> bool:
	return _dirty

## 丢弃全部内存状态（下次访问重新从磁盘载入索引/材质）。
func clear_cache() -> void:
	_dirty_buffers.clear()
	_deleted.clear()
	_dirty_lod.clear()
	_deleted_lod.clear()
	_inflight.clear()
	_dirty = false
	_dirty_count = 0
	_vxel_dirty = false
	_dirty_global = false
	_block_index = []
	_vxel_index.clear()
	_cach_index.clear()
	_loaded = false
