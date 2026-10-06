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
##
## 【账本唯一】除"流 / 生成器"两个数据源外，粗层降采样（LOD0 → 粗层大格）也是取数的一条
## 路径。它的在途去重与重试计数一并收在这里（_derived_*）——此前这份账在 VoxelData 里另存
## 一份（_lod_downsample_pending/_retries），于是"在途"这一概念散落两处、规则各写一遍。
## VoxelData 只负责构造快照 + 派发 worker + 把结果交回本类登记。
##
## 【数据源切换的原子性】configure() 在锁内替换数据源并递增 _source_epoch；后台任务在派发时
## 捕获"生成器实例 + 当时的 epoch"，回填时 epoch 不符即丢弃。于是"运行中换源 / 换世界"不会让
## 旧源的结果落进新源，也不会让 worker 读到半切换的成员（此前 worker 在锁外直读 _generator）。

## 粗层（lod>=1）在途上限：程序化生成较慢，无上限会让 WorkerThreadPool 被粗层任务占满，
## LOD0 长时间空洞。超限直接丢弃该 request（渲染器后续帧会重试）。
const MAX_COARSE_PENDING := 96

## 派生取数（粗层降采样）的重试上限：LOD0 数据常晚于粗层请求就绪 → 空结果延迟重试；
## 超过上限即放弃（区域外 / 空气层），否则会对着真空反复派发。
const MAX_DERIVED_RETRIES := 5

var _stream: VoxelStream = null
var _generator: VoxelGenerator = null

## 数据源代次：configure() / clear() 递增。在途任务的回填必须与它一致才被接受。
var _source_epoch: int = 0

## _pending[lod] = {key: true}（已提交未就绪）；_results[lod] = {key: buffer}（就绪待取）。
var _pending: Array[Dictionary] = []
var _results: Array[Dictionary] = []

## 派生取数（粗层降采样）账本：index = lod-1。
var _derived_pending: Array[Dictionary] = []
var _derived_retries: Array[Dictionary] = []

var _mutex := Mutex.new()


## 配置数据源（任一可为 null）。切换数据源时应先 clear()。
func configure(stream: VoxelStream, generator: VoxelGenerator) -> void:
	_mutex.lock()
	_stream = stream
	_generator = generator
	_source_epoch += 1
	_mutex.unlock()


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
	# 数据源与代次在锁内取一份快照：worker 不再直读成员，切换数据源时也不会读到半状态。
	var stream := _stream
	var generator := _generator
	var epoch := _source_epoch
	_mutex.unlock()

	if stream != null and stream.has_chunk(chunk_key, lod):
		_resolve(chunk_key, lod, stream.load_chunk(chunk_key, lod), epoch)
		return

	# 可生成判定按 lod 分流由生成器内部处理（lod>=1 的 key 是 block 坐标，不是 chunk 坐标）
	if generator != null and generator.is_in_generation_bounds(chunk_key, lod):
		# 粗层限流：超限时撤销登记（不留幽灵在途），调用方下帧再试
		if lod >= 1 and pending_total() >= MAX_COARSE_PENDING:
			_drop_pending(chunk_key, lod)
			return
		WorkerThreadPool.add_task(_generate_task.bind(generator, epoch, chunk_key, lod))
		return

	_drop_pending(chunk_key, lod)


## 后台线程：调用生成器产出数据后回填。生成器必须是纯函数（不碰主线程状态）。
## generator / epoch 由派发方捕获传入（不在 worker 里读成员，避免与 configure 竞争）。
func _generate_task(generator: VoxelGenerator, epoch: int, chunk_key: Vector3i, lod: int) -> void:
	var buf := generator.generate(chunk_key, lod)
	_resolve(chunk_key, lod, buf, epoch)


## 该 key 是否已有在途任务或结果就绪。
func is_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	_mutex.lock()
	var r := lod < _pending.size() \
			and (_pending[lod].has(chunk_key) or _results[lod].has(chunk_key))
	_mutex.unlock()
	return r


## 某层全部**在途（未就绪）**的 key，供流式卸载批量取消（is_pending 含已就绪，不适合列举）。
func get_unready_keys(lod: int = 0) -> Array:
	_mutex.lock()
	var out: Array = []
	if lod < _pending.size():
		for k in _pending[lod]:
			out.append(k)
	_mutex.unlock()
	return out


## 撤销某个 key 的在途 / 就绪登记（流式卸载：超出范围的请求不再需要结果）。
## 后台任务无法真正中止，但其回填会因"登记已撤销"而被丢弃（见 _resolve）——这正是
## 旧实现"结果回来由卸载逻辑丢弃"想要的效果，只是现在由编排器一次做对。
func cancel(chunk_key: Vector3i, lod: int = 0) -> void:
	_mutex.lock()
	if lod < _pending.size():
		_pending[lod].erase(chunk_key)
		_results[lod].erase(chunk_key)
	_mutex.unlock()


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


# ----------------------------------------------------------------------------
# 派生取数（粗层降采样）账本
# ----------------------------------------------------------------------------

## 登记一次派生取数在途。返回 false = 同 key 已在途（调用方跳过，勿重复派发）。
func begin_derived(chunk_key: Vector3i, lod: int) -> bool:
	if lod < 1:
		return false
	_mutex.lock()
	_ensure_derived(lod)
	var ok := not _derived_pending[lod - 1].has(chunk_key)
	if ok:
		_derived_pending[lod - 1][chunk_key] = true
	_mutex.unlock()
	return ok


## 结束一次派生取数在途登记。keep_retry=true 时保留重试计数（空结果待重试），否则一并清空
## （成功 / 放弃）。
func end_derived(chunk_key: Vector3i, lod: int, keep_retry: bool = false) -> void:
	if lod < 1:
		return
	_mutex.lock()
	if lod - 1 < _derived_pending.size():
		_derived_pending[lod - 1].erase(chunk_key)
		if not keep_retry:
			_derived_retries[lod - 1].erase(chunk_key)
	_mutex.unlock()


## 该 key 是否已有派生取数在途。
func is_derived(chunk_key: Vector3i, lod: int) -> bool:
	if lod < 1:
		return false
	_mutex.lock()
	var r := lod - 1 < _derived_pending.size() and _derived_pending[lod - 1].has(chunk_key)
	_mutex.unlock()
	return r


## 记一次派生取数重试。返回 false = 已达上限（调用方放弃，计数已清空）。
func note_derived_retry(chunk_key: Vector3i, lod: int) -> bool:
	if lod < 1:
		return false
	_mutex.lock()
	_ensure_derived(lod)
	var n: int = _derived_retries[lod - 1].get(chunk_key, 0)
	if n >= MAX_DERIVED_RETRIES:
		_derived_retries[lod - 1].erase(chunk_key)
		_mutex.unlock()
		return false
	_derived_retries[lod - 1][chunk_key] = n + 1
	_mutex.unlock()
	return true


# ----------------------------------------------------------------------------
# 世界平移 / 清空
# ----------------------------------------------------------------------------

## origin shift：在途 / 就绪 / 派生登记的 key 随数据基准一起平移，否则回填会写到旧坐标。
func shift_keys(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	_mutex.lock()
	for i in _pending.size():
		_pending[i] = VoxelChunk.shift_key_dict(_pending[i], offset)
		_results[i] = VoxelChunk.shift_key_dict(_results[i], offset)
	for i in _derived_pending.size():
		_derived_pending[i] = VoxelChunk.shift_key_dict(_derived_pending[i], offset)
		_derived_retries[i] = VoxelChunk.shift_key_dict(_derived_retries[i], offset)
	_mutex.unlock()


## 清空全部在途 / 就绪 / 派生状态（数据源重建、切换或世界清空时调用）。
## 同时递增代次：已派发的旧任务即使回来也判为过期。
func clear() -> void:
	_mutex.lock()
	for d in _pending:
		d.clear()
	for d in _results:
		d.clear()
	for d in _derived_pending:
		d.clear()
	for d in _derived_retries:
		d.clear()
	_source_epoch += 1
	_mutex.unlock()


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 回填结果：把 key 从"在途"移入"就绪"（仅当该 key 仍在途**且代次未变**时生效）。
func _resolve(chunk_key: Vector3i, lod: int, buffer: PackedInt32Array, epoch: int) -> void:
	_mutex.lock()
	if epoch == _source_epoch and lod < _pending.size() and _pending[lod].has(chunk_key):
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


## 调用方必须已持锁（Mutex 不可重入）。派生账本 index = lod-1，故长度需 >= lod。
func _ensure_derived(lod: int) -> void:
	while _derived_pending.size() < lod:
		_derived_pending.append({})
	while _derived_retries.size() < lod:
		_derived_retries.append({})
