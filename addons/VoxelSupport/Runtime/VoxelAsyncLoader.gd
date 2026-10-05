class_name VoxelAsyncLoader
extends RefCounted

## 体素取数的异步编排 —— 全项目**唯一**持有"在途 / 就绪"状态的地方。
##
## 【为什么集中在这里】存储（VoxelStream）与生成（VoxelGenerator）本身都是同步的纯操作，
## 各自不该背"谁在跑、跑完没有"这本账；而两个数据源又必须共用同一套去重 / 限流 / 回填
## 规则。于是把账本与规则放在编排方，数据源只回答两个同步问题：
##     "你存了吗？"（has_chunk / load_chunk）  "你能造吗？"（is_in_generation_bounds / generate）
## 新增数据源（如网络流）只需实现同步读或同步生成，异步部分零改动。
##
## 【取数优先级】流里已存 > 生成器可生成 > 无从获取。
## 流优先是因为"存"必须权威：用户破坏过的 chunk 不能被生成结果覆盖掉。
##
## 分层（与 poll_ready 的 lod 语义一致）：lod=0 为 LOD0 chunk，lod>=1 为粗层 block。

## 粗层（lod>=1）在途上限：程序化生成较慢，无上限会让 WorkerThreadPool 被粗层任务占满，
## LOD0 长时间空洞。超限直接丢弃该 request（渲染器后续帧会重试）。
const MAX_COARSE_PENDING := 96

var _stream: VoxelStream = null
var _generator: VoxelGenerator = null

## _pending[lod] = {key: true}（已提交未就绪）；_results[lod] = {key: buffer}（就绪待取）。
var _pending: Array[Dictionary] = []
var _results: Array[Dictionary] = []
var _mutex := Mutex.new()


## 配置数据源（任一可为 null）。切换数据源时应先 clear()。
func configure(stream: VoxelStream, generator: VoxelGenerator) -> void:
	_stream = stream
	_generator = generator


## 提交一次取数请求（同 key 在途或已就绪则忽略）。
##   ① 流里已存 → 主线程直读并立即置为就绪（QVoxStream 的索引常驻内存，不产生 IO 等待）
##   ② 否则生成器可生成 → 丢给 WorkerThreadPool 后台生成
##   ③ 两者都不行 → 立即撤销登记（否则调用方会一直等一个永远不来的结果）
func request(chunk_key: Vector3i, lod: int = 0) -> void:
	_mutex.lock()
	_ensure_layers(lod)
	if _pending[lod].has(chunk_key) or _results[lod].has(chunk_key):
		_mutex.unlock()
		return
	_pending[lod][chunk_key] = true
	_mutex.unlock()

	if _stream != null and _stream.has_chunk(chunk_key, lod):
		_resolve(chunk_key, lod, _stream.load_chunk(chunk_key, lod))
		return

	if _generator != null and _generator.is_in_generation_bounds(chunk_key):
		# 粗层限流：超限时撤销登记（不留幽灵在途），调用方下帧再试
		if lod >= 1 and pending_total() >= MAX_COARSE_PENDING:
			_drop_pending(chunk_key, lod)
			return
		WorkerThreadPool.add_task(_generate_task.bind(chunk_key, lod))
		return

	_drop_pending(chunk_key, lod)


## 后台线程：调用生成器产出数据后回填。生成器必须是纯函数（不碰主线程状态）。
func _generate_task(chunk_key: Vector3i, lod: int) -> void:
	var buf := _generator.generate(chunk_key, lod)
	_resolve(chunk_key, lod, buf)


## 该 key 是否已有在途任务或结果就绪。
func is_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	_mutex.lock()
	var r := lod < _pending.size() \
			and (_pending[lod].has(chunk_key) or _results[lod].has(chunk_key))
	_mutex.unlock()
	return r


## 在途（未就绪）任务总数，供粗层限流。
func pending_total() -> int:
	_mutex.lock()
	var total := 0
	for d in _pending:
		total += d.size()
	_mutex.unlock()
	return total


## 主线程批量取出就绪结果：[[lod, key, buf], ...]；未就绪的留待下次轮询。
func poll_ready(max_count: int) -> Array:
	var out: Array = []
	_mutex.lock()
	for lod in _results.size():
		var res: Dictionary = _results[lod]
		for key in res.keys():
			if out.size() >= max_count:
				break
			out.append([lod, key, res[key]])
			res.erase(key)
	_mutex.unlock()
	return out


## origin shift：在途 / 就绪登记的 key 随数据基准一起平移，否则回填会写到旧坐标。
func shift_keys(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	_mutex.lock()
	for i in _pending.size():
		_pending[i] = _shift_keys(_pending[i], offset)
		_results[i] = _shift_keys(_results[i], offset)
	_mutex.unlock()


## 清空全部在途 / 就绪状态（数据源重建、切换或世界清空时调用）。
func clear() -> void:
	_mutex.lock()
	for d in _pending:
		d.clear()
	for d in _results:
		d.clear()
	_mutex.unlock()


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 回填结果：把 key 从"在途"移入"就绪"（仅当该 key 仍在途时生效）。
func _resolve(chunk_key: Vector3i, lod: int, buffer: PackedInt32Array) -> void:
	_mutex.lock()
	if lod < _pending.size() and _pending[lod].has(chunk_key):
		_results[lod][chunk_key] = buffer
		_pending[lod].erase(chunk_key)
	_mutex.unlock()


func _drop_pending(chunk_key: Vector3i, lod: int) -> void:
	_mutex.lock()
	if lod < _pending.size():
		_pending[lod].erase(chunk_key)
	_mutex.unlock()


## 调用方必须已持锁（Mutex 不可重入）。
func _ensure_layers(lod: int) -> void:
	while _pending.size() <= lod:
		_pending.append({})
	while _results.size() <= lod:
		_results.append({})


static func _shift_keys(d: Dictionary, offset: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + offset] = d[k]
	return nd
