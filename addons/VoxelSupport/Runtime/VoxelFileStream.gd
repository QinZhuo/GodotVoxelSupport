class_name VoxelFileStream
extends VoxelStream

## 磁盘文件流（Region 块级存储）——修复"每 chunk 单文件"的 IO 瓶颈
##
## 把 chunk 数据按 Region 分组存储：每 REGION_SIZE³ 个 chunk 一个 region 文件（.voxr）。
## 走近/补建时，几十个 chunk 往往属于少数几个 region → 每个 region 只读一次文件，
## 后续 chunk 直接从内存缓存取，磁盘 IO 从"几百次小文件读"降到"几次大文件读"。
## 大世界文件数从"每 chunk 一个（上万）"降到"每 64 chunk 一个（百级）。
##
## 特性：
##   - 批量 IO：region 文件一次读入缓存，覆盖 64 个 chunk
##   - LRU 读缓存：最近访问的 region 驻留内存（REGION_CACHE_MAX 个），写操作就地更新后延迟写回
##   - 可选压缩（FileAccess.open_compressed FASTLZ）：稀疏体素数据压缩比高
##   - 接口与 VoxelStream 完全一致，上层 VoxelData / VoxelRenderer 无感知
##
## 文件格式（.voxr，小端）：
##   int32 version（FORMAT_VERSION）
##   int32 chunk_count
##   每个 chunk：
##     int32 cx, cy, cz        （chunk key）
##     int32 voxel_count
##     voxel_count × (int32 local_index, int32 mat_id)   （稀疏体素对，local_index ∈ [0,16³)）
##   空 chunk（无体素）不落盘。

const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const FILE_EXT := ".voxr"
const FORMAT_VERSION := 2

## 每边 chunk 数 = 2^REGION_SHIFT（默认 4×4×4 = 64 chunk/region）
const REGION_SHIFT := 2
const REGION_SIZE := 1 << REGION_SHIFT
const REGION_VOLUME := REGION_SIZE * REGION_SIZE * REGION_SIZE

## 读缓存中最多驻留的 region 数（LRU）。64 chunk × 64 = 4096 chunk 常驻，
## 覆盖可见区域及来回走动的常用 region；超限时把最久未用的 region 写回磁盘后释放。
## 值越大，来回走动时 LRU 驱逐越少（磁盘 IO 越少），但内存占用越高。
const REGION_CACHE_MAX := 64

## 存储目录（支持 user://、res:// 或绝对路径）
@export var directory: String = "user://voxel_data"

## 是否压缩 region 文件（FASTLZ）。稀疏体素数据压缩比高，默认开启。
@export var compression: bool = true

# region 缓存：{region_key: {"chunks": {chunk_key: {local_index: mat_id}}, "dirty": bool}}
var _region_cache: Dictionary = {}
# LRU 顺序（array of region_key，开头 = 最久未用）
var _region_order: Array = []

# 异步 region 加载（读盘在后台线程，根治流式移动时主线程同步 IO 卡顿）：
#   - _io_pending: 已提交后台加载的 region（主线程访问）
#   - _io_results:  后台读盘完成待主线程回填（后台写 / 主线程取，用 Mutex 保护）
var _io_mutex := Mutex.new()
var _io_pending: Dictionary = {}
var _io_results: Dictionary = {}


func _region_key(chunk_key: Vector3i) -> Vector3i:
	return Vector3i(
		chunk_key.x >> REGION_SHIFT,
		chunk_key.y >> REGION_SHIFT,
		chunk_key.z >> REGION_SHIFT)


func _region_path(region_key: Vector3i) -> String:
	return "%s/voxr_%d_%d_%d%s" % [directory, region_key.x, region_key.y, region_key.z, FILE_EXT]


func _ensure_dir() -> void:
	var abs := ProjectSettings.globalize_path(directory)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


## 从文件读取 region 数据（纯函数，后台线程可安全调用，不碰缓存字典）。
## 返回 {chunk_key: {local_index: mat_id}}（文件不存在/格式不符 → 空字典）
func _read_region_file(region_key: Vector3i) -> Dictionary:
	var chunks := {}
	var path := _region_path(region_key)
	if FileAccess.file_exists(path):
		var f := _open_read(path)
		if f:
			var version := f.get_32()
			if version == FORMAT_VERSION:
				var count := f.get_32()
				for i in count:
					var cx := f.get_32()
					var cy := f.get_32()
					var cz := f.get_32()
					var vcount := f.get_32()
					var chunk_data := {}
					for j in vcount:
						var idx := f.get_32()
						var mat := f.get_32()
						chunk_data[idx] = mat
					chunks[Vector3i(cx, cy, cz)] = chunk_data
			f.close()
	return chunks


## 请求异步加载 region（后台线程读盘）。region 已在缓存返回 true；否则提交后台任务返回 false。
## 数据就绪后由 _on_region_loaded 回填缓存，调用方可随后同步 preload（缓存命中则无 IO）。
func request_region_load(region_key: Vector3i) -> bool:
	if _region_cache.has(region_key):
		return true
	_io_mutex.lock()
	var submitted := _io_pending.has(region_key) or _io_results.has(region_key)
	if not submitted:
		_io_pending[region_key] = true
	_io_mutex.unlock()
	if not submitted:
		WorkerThreadPool.add_task(_io_read_worker.bind(region_key))
	return false


## 后台线程：读 region 文件 → 结果队列（Mutex 保护），call_deferred 回主线程
func _io_read_worker(region_key: Vector3i) -> void:
	var chunks := _read_region_file(region_key)
	_io_mutex.lock()
	_io_results[region_key] = chunks
	_io_mutex.unlock()
	call_deferred("_on_region_loaded", region_key)


## 主线程：取后台结果，回填 region 缓存（并执行 LRU 驱逐）
func _on_region_loaded(region_key: Vector3i) -> void:
	_io_mutex.lock()
	var chunks: Variant = _io_results.get(region_key)
	_io_results.erase(region_key)
	_io_pending.erase(region_key)
	_io_mutex.unlock()
	if _region_cache.has(region_key):
		return  # 主线程已同步加载过
	# 防御：文件存在但读到空（异步写窗口期）→ 不缓存空，下次 request 重读
	if (chunks is Dictionary and (chunks as Dictionary).is_empty()) and FileAccess.file_exists(_region_path(region_key)):
		return
	_region_cache[region_key] = {
		"chunks": chunks if chunks is Dictionary else {},
		"dirty": false,
	}
	_region_order.append(region_key)
	if _region_order.size() > REGION_CACHE_MAX:
		var old_key: Vector3i = _region_order.pop_front()
		_flush_region(old_key)


## 取 region 数据（读缓存命中则直接返回；否则读文件入缓存）。
## 返回 {"chunks": {...}, "dirty": bool}，调用方可直接修改 chunks。
func _get_region(region_key: Vector3i) -> Dictionary:
	var entry: Variant = _region_cache.get(region_key)
	if entry != null:
		_touch_region(region_key)
		return entry
	var chunks := _read_region_file(region_key)
	# 防御：文件存在但读到空（异步写窗口期）→ 不缓存空，下帧重读
	if chunks.is_empty() and FileAccess.file_exists(_region_path(region_key)):
		return {"chunks": {}, "dirty": false}
	entry = {"chunks": chunks, "dirty": false}
	_region_cache[region_key] = entry
	_region_order.append(region_key)
	# LRU 超限：写回并释放最久未用的 region
	if _region_order.size() > REGION_CACHE_MAX:
		var old_key: Vector3i = _region_order.pop_front()
		_flush_region(old_key)
	return entry


## 更新 LRU：把 region 移到末尾（最近使用）
func _touch_region(region_key: Vector3i) -> void:
	var idx := _region_order.find(region_key)
	if idx >= 0 and idx != _region_order.size() - 1:
		_region_order.remove_at(idx)
		_region_order.append(region_key)


## 打开 region 文件读取（按 compression 选择压缩/普通）
func _open_read(path: String) -> FileAccess:
	if compression:
		return FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_FASTLZ)
	return FileAccess.open(path, FileAccess.READ)


## 打开 region 文件写入
func _open_write(path: String) -> FileAccess:
	_ensure_dir()
	if compression:
		return FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_FASTLZ)
	return FileAccess.open(path, FileAccess.WRITE)


## 把 region 数据写回磁盘（若 dirty），并从缓存移除。写盘异步化（后台线程）。
func _flush_region(region_key: Vector3i) -> void:
	var entry: Variant = _region_cache.get(region_key)
	if entry == null:
		return
	_region_cache.erase(region_key)
	if not entry.get("dirty", false):
		return
	var chunks: Dictionary = entry["chunks"]
	WorkerThreadPool.add_task(_io_write_worker.bind(region_key, chunks))


## 后台线程写盘入口（不碰缓存字典，数据快照传入）
func _io_write_worker(region_key: Vector3i, chunks: Dictionary) -> void:
	_write_region_file(region_key, chunks)


## 写 region 文件（原子写：先写临时文件再替换，避免读方读到"半写"文件损坏）。
## chunks 为空 → 删除文件。后台线程可安全调用。
func _write_region_file(region_key: Vector3i, chunks: Dictionary) -> void:
	if chunks.is_empty():
		var path := _region_path(region_key)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var tmp_path := _region_path(region_key) + ".tmp"
	var f := _open_write(tmp_path)
	if f == null:
		push_error("[VoxelFileStream] 无法写入 region %s: %s" % [region_key, error_string(FileAccess.get_open_error())])
		return
	f.store_32(FORMAT_VERSION)
	f.store_32(chunks.size())
	for ck in chunks:
		var ck3: Vector3i = ck
		f.store_32(ck3.x)
		f.store_32(ck3.y)
		f.store_32(ck3.z)
		var chunk_data: Dictionary = chunks[ck]
		f.store_32(chunk_data.size())
		for idx in chunk_data:
			f.store_32(idx)
			f.store_32(chunk_data[idx])
	f.close()
	# 原子替换：读方只会看到旧文件（完整）或新文件（完整），不会读到半写文件
	var path := _region_path(region_key)
	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)
	DirAccess.rename_absolute(abs_tmp, abs_path)


## 同步写回 region（存档 / flush 调用，保证立即落盘）
func _save_region(region_key: Vector3i, entry: Dictionary) -> void:
	if not entry.get("dirty", false):
		return
	_write_region_file(region_key, entry["chunks"])
	entry["dirty"] = false


func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array) -> void:
	if buffer.is_empty():
		erase_chunk(chunk_key)
		return
	# 稀疏化：只存非空体素 (local_index, mat_id)
	var chunk_data := {}
	for i in CHUNK_VOLUME:
		var v: int = buffer[i]
		if v > 0:
			chunk_data[i] = v
	if chunk_data.is_empty():
		erase_chunk(chunk_key)
		return
	var entry := _get_region(_region_key(chunk_key))
	entry["chunks"][chunk_key] = chunk_data
	entry["dirty"] = true


func load_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var entry := _get_region(_region_key(chunk_key))
	var chunk_data: Variant = entry["chunks"].get(chunk_key)
	if chunk_data == null:
		return PackedInt32Array()
	var buf := PackedInt32Array()
	buf.resize(CHUNK_VOLUME)
	for idx in chunk_data:
		# 防御：异步写/读竞态下文件损坏可能读到越界 index，跳过避免崩溃
		if idx >= 0 and idx < CHUNK_VOLUME:
			buf[idx] = chunk_data[idx]
	return buf


func has_chunk(chunk_key: Vector3i) -> bool:
	var entry := _get_region(_region_key(chunk_key))
	return entry["chunks"].has(chunk_key)


func erase_chunk(chunk_key: Vector3i) -> void:
	var entry := _get_region(_region_key(chunk_key))
	if entry["chunks"].has(chunk_key):
		entry["chunks"].erase(chunk_key)
		entry["dirty"] = true


func get_all_chunk_keys() -> Array[Vector3i]:
	var keys := {}
	# 缓存中的 region
	for region_key in _region_cache:
		var entry: Dictionary = _region_cache[region_key]
		for ck in entry["chunks"]:
			keys[ck] = true
	# 目录中未缓存的 region 文件
	var dir := DirAccess.open(directory)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.ends_with(FILE_EXT):
				var stem := name.substr(0, name.length() - FILE_EXT.length())
				var parts := stem.split("_")
				if parts.size() == 4 and parts[0] == "voxr":
					var rk := Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))
					if not _region_cache.has(rk):
						var entry := _get_region(rk)
						for ck in entry["chunks"]:
							keys[ck] = true
			name = dir.get_next()
		dir.list_dir_end()
	var out: Array[Vector3i] = []
	for ck in keys:
		out.append(ck)
	return out


## 把缓存中所有 dirty region 写回磁盘（存档 / 退出前调用）
func flush() -> void:
	for region_key in _region_cache:
		var entry: Dictionary = _region_cache[region_key]
		_save_region(region_key, entry)


## 清空缓存（不写回，调用方需先 flush）
func clear_cache() -> void:
	_region_cache.clear()
	_region_order.clear()


func get_stream_path() -> String:
	return directory
