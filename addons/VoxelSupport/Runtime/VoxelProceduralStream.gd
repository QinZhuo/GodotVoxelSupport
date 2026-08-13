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

# 修改过的 chunk（破坏覆盖程序化）：chunk_key -> PackedInt32Array（lod=0）
var _modified: Dictionary = {}
# 修改过的粗层 block（编辑降采样结果）：_modified_lod[level-1] = {block_key: buffer}
var _modified_lod: Array[Dictionary] = []
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


## @abstract 虚函数：按 block key 生成粗 LOD block 数据（LOD_GRID³ 大格，值 = 材质ID，0=空，
## 每格 = 2^lod 体素）。Voxel Tools 式独立数据层：远处粗层 block 直接以粗粒度生成，
## 无需先加载全部 LOD0 chunk 再降采样。子类必须覆写（未覆写会编译报错）。
## lod=1：32³ 大格覆盖 64³ 体素；lod=i：每格 2^i 体素。
@abstract
func _generate_chunk_lod(block_key: Vector3i, lod: int) -> PackedInt32Array


# 后台生成（WorkerThreadPool）：确定性纯函数生成移出主线程，避免切场景/移动时生成卡顿。
# 统一按 lod 分层：_async_pending[lod] = {key: true}；_async_results[lod] = {key: buf}。
var _async_pending: Array[Dictionary] = []
var _async_results: Array[Dictionary] = []
var _async_mutex := Mutex.new()

## 粗层（lod>=1）在途任务上限：程序化生成较慢，无上限会让 WorkerThreadPool 被大量粗层任务占满，
## LOD0/粗层 mesh 长时间空洞（移动时 LOD 边界出现横竖/块状缺口）。超限丢弃粗层 request（渲染器后续重试），
## 保证近处 LOD0 数据加载优先。
const MAX_COARSE_PENDING := 96


## 所有层的在途任务总数
func _async_pending_total() -> int:
	var total := 0
	for d in _async_pending:
		total += d.size()
	return total


## 请求后台生成 chunk/block 数据（lod=0 走 _generate_chunk，lod>=1 走 _generate_chunk_lod）。
## 同 key 已提交/已就绪则不重复。
func request_chunk_async(chunk_key: Vector3i, lod: int = 0) -> void:
	_async_mutex.lock()
	while _async_pending.size() <= lod:
		_async_pending.append({})
	while _async_results.size() <= lod:
		_async_results.append({})
	# 粗层在途限流（lod0 不限制——近处地形加载优先）
	if lod >= 1 and _async_pending_total() >= MAX_COARSE_PENDING:
		_async_mutex.unlock()
		return
	var submitted := _async_pending[lod].has(chunk_key) or _async_results[lod].has(chunk_key)
	if not submitted:
		_async_pending[lod][chunk_key] = true
	_async_mutex.unlock()
	if not submitted:
		WorkerThreadPool.add_task(_async_generate.bind(chunk_key, lod))


## 后台线程 worker：调用子类生成器生成数据（lod 决定粒度），结果入队待主线程 poll。
func _async_generate(chunk_key: Vector3i, lod: int) -> void:
	var buf := _generate_chunk(chunk_key) if lod == 0 else _generate_chunk_lod(chunk_key, lod)
	_async_mutex.lock()
	if _async_pending[lod].has(chunk_key):
		_async_results[lod][chunk_key] = buf
		_async_pending[lod].erase(chunk_key)
	_async_mutex.unlock()


## 主线程取异步生成结果；未就绪返回空数组。
func poll_chunk_async(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	_async_mutex.lock()
	if lod >= _async_results.size():
		_async_mutex.unlock()
		return PackedInt32Array()
	var r: Variant = _async_results[lod].get(chunk_key)
	if r == null:
		_async_mutex.unlock()
		return PackedInt32Array()
	_async_results[lod].erase(chunk_key)
	_async_mutex.unlock()
	return r


## 该 chunk/block 是否已有后台任务进行中或结果就绪（避免重复提交）。
func is_chunk_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	_async_mutex.lock()
	var r := lod < _async_pending.size() and (_async_pending[lod].has(chunk_key) or _async_results[lod].has(chunk_key))
	_async_mutex.unlock()
	return r


## 主线程批量取后台生成结果（不限提交方——ensure 与 halo 经 preload_chunk 提交的都会回填，
## 避免 async_results 堆积导致数据供给停滞）。返回 [[lod, chunk_key, buf], ...]。
func poll_all_ready(max_count: int) -> Array:
	var out: Array = []
	_async_mutex.lock()
	for lod in _async_results.size():
		var res: Dictionary = _async_results[lod]
		for key in res.keys():
			if out.size() >= max_count:
				break
			out.append([lod, key, res[key]])
			res.erase(key)
	_async_mutex.unlock()
	return out


## 取消/清空全部后台任务状态（数据源重建时调用）。
func clear_async_state() -> void:
	_async_mutex.lock()
	for d in _async_pending:
		d.clear()
	for d in _async_results:
		d.clear()
	_async_mutex.unlock()


## 从流加载 chunk/block。优先级：修改的 > 文件持久化 > 程序化生成（同步兜底，
## 供强制读取/破坏等场景；正常渲染数据由渲染器异步生成后回填，不走到这里）。
func load_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	if lod == 0:
		if _modified.has(chunk_key):
			return _modified[chunk_key]
		if _file_stream and _persisted_keys.has(chunk_key):
			var buf := _file_stream.load_chunk(chunk_key, 0)
			if buf.size() == VoxelChunk.CHUNK_VOLUME:
				return buf
		return _generate_chunk(chunk_key)
	# 粗层：修改块（_modified_lod）> 文件持久化 > 生成器直接生成
	if lod - 1 < _modified_lod.size() and _modified_lod[lod - 1].has(chunk_key):
		return _modified_lod[lod - 1][chunk_key]
	if _file_stream:
		var buf2 := _file_stream.load_chunk(chunk_key, lod)
		if buf2.size() == VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE:
			return buf2
	return _generate_chunk_lod(chunk_key, lod)


## 保存 chunk/block（破坏/编辑写入）：记录修改，可选写盘。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array, lod: int = 0) -> void:
	if lod == 0:
		_modified[chunk_key] = buffer
		if _file_stream:
			_file_stream.save_chunk(chunk_key, buffer, 0)
			_persisted_keys[chunk_key] = true
		return
	while _modified_lod.size() <= lod - 1:
		_modified_lod.append({})
	_modified_lod[lod - 1][chunk_key] = buffer
	if _file_stream:
		_file_stream.save_chunk(chunk_key, buffer, lod)


## 移除 chunk/block（世界该处清空）：回退到程序化（清除修改记录）。
func erase_chunk(chunk_key: Vector3i, lod: int = 0) -> void:
	if lod == 0:
		_modified.erase(chunk_key)
		_persisted_keys.erase(chunk_key)
		if _file_stream:
			_file_stream.erase_chunk(chunk_key, 0)
		return
	if lod - 1 < _modified_lod.size():
		_modified_lod[lod - 1].erase(chunk_key)
	if _file_stream:
		_file_stream.erase_chunk(chunk_key, lod)


## 只枚举修改的 chunk/block（无限世界不枚举程序化全部）。
func get_all_chunk_keys(lod: int = 0) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if lod == 0:
		for ck in _modified:
			keys.append(ck)
		for ck in _persisted_keys:
			if not keys.has(ck):
				keys.append(ck)
		return keys
	if lod - 1 < _modified_lod.size():
		for bk in _modified_lod[lod - 1]:
			keys.append(bk)
	return keys


## 该 chunk/block 是否被用户修改过（破坏/编辑覆盖了程序化数据）。
func is_modified(chunk_key: Vector3i, lod: int = 0) -> bool:
	if lod == 0:
		return _modified.has(chunk_key)
	return lod - 1 < _modified_lod.size() and _modified_lod[lod - 1].has(chunk_key)


## 平移 chunk key（origin shift 用）：所有修改/缓存 key 加偏移，保持世界坐标连续性。
func shift_origin(offset: Vector3i) -> void:
	var new_modified: Dictionary = {}
	for ck in _modified:
		new_modified[ck + offset] = _modified[ck]
	_modified = new_modified
	var new_persisted: Dictionary = {}
	for ck in _persisted_keys:
		new_persisted[ck + offset] = true
	_persisted_keys = new_persisted
	for i in _modified_lod.size():
		_modified_lod[i] = _shift_block_keys(_modified_lod[i], offset)
	_async_mutex.lock()
	for i in _async_pending.size():
		_async_pending[i] = _shift_block_keys(_async_pending[i], offset)
		_async_results[i] = _shift_block_keys(_async_results[i], offset)
	_async_mutex.unlock()
	shift_bounds(offset)


static func _shift_block_keys(d: Dictionary, offset: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + offset] = d[k]
	return nd


## 该 chunk/block 是否属于本流可生成范围（复用具类 VoxelStream.is_in_generation_bounds）：
##   无限世界流恒 true；矩形地图（AABB）O(1)；建筑（精确集合）查集合。
func has_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	return is_in_generation_bounds(chunk_key)


func flush() -> void:
	if _file_stream:
		_file_stream.flush()


func get_stream_path() -> String:
	return persist_directory
