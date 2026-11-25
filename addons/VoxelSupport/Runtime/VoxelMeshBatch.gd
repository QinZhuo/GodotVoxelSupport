class_name VoxelMeshBatch
extends RefCounted

## 一次"渲染扇出"的**所有权对象**：同时持有本批次的**任务计数**与**只读快照句柄**。
## 【要解决什么】旧实现把这三样东西散在渲染器里各写一遍：
##     `_pending_task_count`（任务计数）、`_batch_snapshot_active`（快照是否已登记）、
##     `_generation_id`（过期判定）。
## 于是"递减"这个动作出现在多个地方：结果处理函数里既有正常路径的递减，
## 又有两条早退路径各自的递减 —— 一个被丢弃的结果会被减 2 次，计数提前归零，
## 批次被判"完成"→ 快照在 worker 仍在读共享缓冲时被释放 → COW 写保护被击穿。
## 【本类的做法：结算点唯一】计数只在 [method _on_done] 一处递减，而 [method _wrap]
## 保证"无论 worker 怎么提前 return，_on_done 必然被调用一次"。
## 于是消费方（渲染器）无论怎么早退，都不可能让计数失衡 —— 失效模式被结构消除，
## 而不是靠"每处都记得减一次"的纪律维持。
## 【为什么用对象身份而不是 gen_id】批次一经取消即不再发射结果，迟到的回填自然被丢弃；
## 渲染器只需 `batch != _batch` 即可判过期。对象身份不需要维护、也不会忘记自增。
## 【为什么与 VoxelAsyncLoader 分开】后者是**取数账本**：按 (chunk_key, lod) 键、
## 跨多个渲染批次存活、由 configure()/clear() 失效。本类是**渲染扇出账本**：
## 同时至多一个、随 origin shift / 退出 / 世界重建失效，且必须携带 QVoxelSource 的快照句柄。
## 合并两者会让取数层被迫理解快照生命周期，并混淆两套 epoch。

## 单个 worker 产出的结果（主线程发射）。已取消的批次不再发射。
signal result_ready(result: Dictionary)

## 批次结算（全部完成或被取消），**至多一次**。此时快照已释放。
signal finished

## 诊断用序号（全局单调递增，仅用于日志区分批次）。
static var _serial_counter: int = 0

var _serial: int = 0
var _snapshot: QVoxelSource.ReadonlySnapshot = null
var _pending: int = 0
var _task_ids: Array[int] = []
var _dispatched: bool = false
var _settled: bool = false
var _cancelled: bool = false


## snapshot 可后置附加（见 attach_snapshot）：调用方通常先建批次、算完可见集后才登记快照。
func _init(snapshot: QVoxelSource.ReadonlySnapshot = null) -> void:
	_serial_counter += 1
	_serial = _serial_counter
	_snapshot = snapshot


## 诊断用批次序号。
func serial() -> int:
	return _serial


## 批次是否仍在途（未结算）。
func is_active() -> bool:
	return not _settled


## 未完成的任务数（限流判断用）。
func pending_count() -> int:
	return _pending


## 登记只读快照句柄（本批次负责在结算时释放）。仅可在派发前调用一次。
func attach_snapshot(snapshot: QVoxelSource.ReadonlySnapshot) -> void:
	if _settled or _snapshot != null:
		return
	_snapshot = snapshot


## 是否真的派发过任务。调用方据此区分"有过工作"与"空批次"，
## 前者才需要做收尾（emit 更新信号等），后者等同于旧实现的裸计数 0。
func has_dispatched() -> bool:
	return _dispatched


## 派发一个 worker。**worker 必须恰好只有一个自由形参**，签名视为
## `func(out: Dictionary) -> void`：需要产出结果时向 out 写入（`out.merge(...)` /
## `out["k"] = v`）；不写 = 本任务无结果。
## 【为什么强调"恰好一个自由形参"】_wrap 用 `worker.call(out)` 调用它，而 Godot 4 的
## `Callable.bind()` 会把绑定实参放在 call 实参**之后** —— 所以
## `f.bind(a, b).call(out)` 实际是 `f(out, a, b)`，out 落在第一个形参上、其余整体错位。
## 需要传额外参数时，请在调用方用 lambda 把 out 显式写在末位（见 VoxelRenderer 的派发处），
## 不要依赖 bind 的位置。
## 记账、线程包装、结算全部由本类负责，调用方不需要（也不应该）再维护计数。
func spawn(worker: Callable) -> void:
	if _settled:
		return
	_dispatched = true
	_pending += 1
	_task_ids.append(WorkerThreadPool.add_task(_wrap.bind(worker)))


## 取消本批次：停止发射结果并立即释放快照（幂等）。
## worker 无法真正中止，其回填会因 `_settled` 被丢弃 —— 正是"结果回来由卸载逻辑丢弃"
## 想要的效果，只是现在由批次一次做对。
func cancel() -> void:
	if _settled:
		return
	_cancelled = true
	_finish()


## 若一个任务都没派发出去则立即结算（否则批次永远为"在途"，会挡住调用方的下一次更新）。
func settle_if_idle() -> void:
	if _pending <= 0:
		_finish()


## 阻塞等待全部 worker 结束。**仅退出 / 世界重建路径调用**（节点释放前必须 join，
## 否则 worker 完成时的 call_deferred 会打到已释放实例）。
func wait_tasks() -> void:
	for tid in _task_ids:
		WorkerThreadPool.wait_for_task_completion(tid)
	_task_ids.clear()


# 内部

## 子线程包装：唯一职责是"保证 _on_done 必然被调用一次"。
## worker 抛错/提前 return 也走不到"不结算"的分支，因为 call_deferred 在其之后无条件执行。
func _wrap(worker: Callable) -> void:
	var out := {}
	worker.call(out)
	call_deferred("_on_done", out)


## **全批次唯一结算点**（主线程）。任何消费方的提前 return 都与计数无关。
func _on_done(result: Dictionary) -> void:
	if _settled:
		return
	_pending -= 1
	if not _cancelled and not result.is_empty():
		result_ready.emit(result)
	if _pending <= 0:
		_finish()


## 结算：释放快照 + 发 finished。幂等（正常完成与 cancel 竞争时只生效一次）。
func _finish() -> void:
	if _settled:
		return
	_settled = true
	_pending = 0
	# 快照在此释放：此刻全部 worker 已回填完毕，缓冲不再被后台读取。
	# 比"下一帧再释放"更早，且仍然安全。
	if _snapshot != null:
		_snapshot.release()
		_snapshot = null
	finished.emit()
