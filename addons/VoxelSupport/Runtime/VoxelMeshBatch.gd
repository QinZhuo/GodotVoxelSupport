class_name VoxelMeshBatch
extends RefCounted

## 一次"渲染扇出"的**所有权对象**：同时持有本批次的**任务计数**与**只读快照句柄**。

## 单个 worker 产出的结果（主线程发射）。
signal result_ready(result: Dictionary)

## 批次结算（全部完成或被取消），**至多一次**。
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

## 登记只读快照句柄（本批次负责在结算时释放）。
func attach_snapshot(snapshot: QVoxelSource.ReadonlySnapshot) -> void:
	if _settled or _snapshot != null:
		return
	_snapshot = snapshot

## 是否真的派发过任务。
func has_dispatched() -> bool:
	return _dispatched

## 派发一个 worker。
func spawn(worker: Callable) -> void:
	if _settled:
		return
	_dispatched = true
	_pending += 1
	_task_ids.append(WorkerThreadPool.add_task(_wrap.bind(worker)))

## 取消本批次：停止发射结果并立即释放快照（幂等）。
func cancel() -> void:
	if _settled:
		return
	_cancelled = true
	_finish()

## 若一个任务都没派发出去则立即结算（否则批次永远为"在途"，会挡住调用方的下一次更新）。
func settle_if_idle() -> void:
	if _pending <= 0:
		_finish()

## 阻塞等待全部 worker 结束。
func wait_tasks() -> void:
	for tid in _task_ids:
		WorkerThreadPool.wait_for_task_completion(tid)
	_task_ids.clear()

# 内部

## 子线程包装：唯一职责是"保证 _on_done 必然被调用一次"。
func _wrap(worker: Callable) -> void:
	var out := {}
	worker.call(out)
	call_deferred("_on_done", out)

## **全批次唯一结算点**（主线程）。
func _on_done(result: Dictionary) -> void:
	if _settled:
		return
	_pending -= 1
	if not _cancelled and not result.is_empty():
		result_ready.emit(result)
	if _pending <= 0:
		_finish()

## 结算：释放快照 + 发 finished。
func _finish() -> void:
	if _settled:
		return
	_settled = true
	_pending = 0
	# 快照在此释放：此刻全部 worker 已回填完毕，缓冲不再被后台读取。
	if _snapshot != null:
		_snapshot.release()
		_snapshot = null
	finished.emit()
