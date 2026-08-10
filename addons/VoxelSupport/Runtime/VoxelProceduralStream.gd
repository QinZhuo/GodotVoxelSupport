@tool
@abstract
class_name VoxelProceduralStream
extends VoxelStream

## 程序化无限世界数据流【虚基类】：子类通过覆写 _generate_chunk(chunk_key)
## 实现自己的确定性生成算法（Minecraft 式无限世界）。
##
## 设计：
##   - 未修改 chunk：由子类 _generate_chunk 按 chunk key 程序化生成（确定性，可重复，零存储）
##   - 用户破坏的 chunk：save_chunk 记录修改，覆盖程序化数据
##   - 可选 persist_directory：修改的 chunk 复用 VoxelFileStream 写盘，重启保留破坏
##   - get_all_chunk_keys：只枚举修改的（无限世界不枚举程序化全部）
##   - 有限范围（矩形地图/建筑模板）：继承基类 VoxelStream 的范围限制能力，
##     set_grid_size(AABB) / set_chunk_bounds(精确集合)，has_chunk 复用 is_in_generation_bounds
##
## 确定性要求：_generate_chunk 必须对同一 chunk_key 返回相同地形（如噪声 hash(chunk_key)），
## origin shift 平移 chunk key 后地形保持世界连续。
## 注意：基类为虚基类约定，直接实例化会报错——子类必须覆写 _generate_chunk。

## 修改持久化目录（可选）：用户破坏的 chunk 写盘，重启后保留。留空则修改仅存内存。
## 用 setter 保证 new() 之后再赋值也能立即创建文件流。
@export var persist_directory: String = "":
	set(value):
		persist_directory = value
		if _file_stream == null and persist_directory != "":
			_file_stream = VoxelFileStream.new()
			_file_stream.directory = persist_directory
			_rebuild_persisted_index()

# 修改过的 chunk（破坏覆盖程序化）：chunk_key -> PackedInt32Array
var _modified: Dictionary = {}
# 可选文件持久化（复用 VoxelFileStream 的 region 存储）
var _file_stream: VoxelFileStream = null
# 文件流中已持久化的 chunk key 索引：load_chunk 先查此内存索引，避免每 chunk
# 同步读 region 文件（来回移动大量生成时同步读盘 → 主线程卡死）。
var _persisted_keys: Dictionary = {}


## 从文件流枚举已持久化 chunk 重建索引（重启恢复破坏数据时调用一次）。
func _rebuild_persisted_index() -> void:
	_persisted_keys.clear()
	if _file_stream:
		for ck in _file_stream.get_all_chunk_keys():
			_persisted_keys[ck] = true


## @abstract 虚函数：按 chunk key 生成 16³ chunk 缓冲（值 = 材质ID，0=空）。
## 子类必须覆写实现生成算法（未覆写会编译报错）。
@abstract
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array


# 后台生成（WorkerThreadPool）：确定性纯函数生成移出主线程，避免切场景/移动时生成卡顿
#   _async_pending: 已提交后台任务；_async_results: 后台完成待主线程 poll
var _async_pending: Dictionary = {}
var _async_results: Dictionary = {}
var _async_mutex := Mutex.new()


## 请求后台生成 chunk（确定性生成，适合后台线程）。同 key 已提交/已就绪则不重复。
func request_chunk_async(chunk_key: Vector3i) -> void:
	_async_mutex.lock()
	var submitted := _async_pending.has(chunk_key) or _async_results.has(chunk_key)
	if not submitted:
		_async_pending[chunk_key] = true
	_async_mutex.unlock()
	if not submitted:
		WorkerThreadPool.add_task(_async_generate.bind(chunk_key))


## 后台线程 worker：调用子类 _generate_chunk 生成 16³ 缓冲，结果入队待主线程 poll。
func _async_generate(chunk_key: Vector3i) -> void:
	var buf := _generate_chunk(chunk_key)
	_async_mutex.lock()
	if _async_pending.has(chunk_key):
		_async_results[chunk_key] = buf
		_async_pending.erase(chunk_key)
	_async_mutex.unlock()


## 主线程取异步生成结果；未就绪返回空数组。
func poll_chunk_async(chunk_key: Vector3i) -> PackedInt32Array:
	_async_mutex.lock()
	var r: Variant = _async_results.get(chunk_key)
	if r == null:
		_async_mutex.unlock()
		return PackedInt32Array()
	_async_results.erase(chunk_key)
	_async_mutex.unlock()
	return r


## 该 chunk 是否已有后台任务进行中或结果就绪（避免重复提交）。
func is_chunk_pending(chunk_key: Vector3i) -> bool:
	_async_mutex.lock()
	var r := _async_pending.has(chunk_key) or _async_results.has(chunk_key)
	_async_mutex.unlock()
	return r


## 主线程批量取后台生成结果（不限提交方——ensure 与 halo/LOD1 经 preload_chunk 提交的
## 都会回填，避免 async_results 堆积导致数据供给停滞）。返回 [[chunk_key, buf], ...]。
func poll_all_ready(max_count: int) -> Array:
	_async_mutex.lock()
	var keys: Array = []
	for ck in _async_results.keys():
		keys.append(ck)
		if keys.size() >= max_count:
			break
	var out: Array = []
	for ck in keys:
		out.append([ck, _async_results[ck]])
		_async_results.erase(ck)
	_async_mutex.unlock()
	return out


## 取消/清空全部后台任务状态（数据源重建时调用）。
func clear_async_state() -> void:
	_async_mutex.lock()
	_async_pending.clear()
	_async_results.clear()
	_async_mutex.unlock()


## 从流加载 chunk。优先级：修改的 > 文件持久化 > 程序化生成（同步兜底，
## 供强制读取/破坏等场景；正常渲染数据由渲染器异步生成后回填，不走到这里）。
func load_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	if _modified.has(chunk_key):
		return _modified[chunk_key]
	if _file_stream and _persisted_keys.has(chunk_key):
		var buf := _file_stream.load_chunk(chunk_key)
		if buf.size() == VoxelChunk.CHUNK_VOLUME:
			return buf
	return _generate_chunk(chunk_key)


## 保存 chunk（破坏写入）：记录修改，可选写盘。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array) -> void:
	_modified[chunk_key] = buffer
	if _file_stream:
		_file_stream.save_chunk(chunk_key, buffer)
		_persisted_keys[chunk_key] = true


## 移除 chunk（世界该处清空）：回退到程序化（清除修改记录）。
func erase_chunk(chunk_key: Vector3i) -> void:
	_modified.erase(chunk_key)
	_persisted_keys.erase(chunk_key)
	if _file_stream:
		_file_stream.erase_chunk(chunk_key)


## 只枚举修改的 chunk（无限世界不枚举程序化全部）。
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck in _modified:
		keys.append(ck)
	for ck in _persisted_keys:
		if not keys.has(ck):
			keys.append(ck)
	return keys


## 平移 chunk key（origin shift 用）：所有修改/缓存 key 加偏移，保持世界坐标连续性。
## 范围限制同步平移（基类 shift_bounds），使有限范围随数据基准移动。
func shift_origin(offset: Vector3i) -> void:
	var new_modified: Dictionary = {}
	for ck in _modified:
		new_modified[ck + offset] = _modified[ck]
	_modified = new_modified
	var new_persisted: Dictionary = {}
	for ck in _persisted_keys:
		new_persisted[ck + offset] = true
	_persisted_keys = new_persisted
	shift_bounds(offset)


## 该 chunk 是否属于本流可生成范围（复用具类 VoxelStream.is_in_generation_bounds）：
##   无限世界流恒 true；矩形地图（AABB）O(1)；建筑（精确集合）查集合。
func has_chunk(chunk_key: Vector3i) -> bool:
	return is_in_generation_bounds(chunk_key)


func flush() -> void:
	if _file_stream:
		_file_stream.flush()


func get_stream_path() -> String:
	return persist_directory
