@tool
## 异步作用域 —— 一段异步流程「这一轮」所拥有的、可撤销的异步任务的集合。
class_name AsyncScope extends RefCounted

## 一项可撤销的异步任务：到点执行一次回调，也可被等待。
class _Task extends RefCounted:
	## 任务结束时发射。
	signal done(completed: bool)

	## 所属作用域。
	var scope: AsyncScope
	var _callback: Callable
	var _settled := false

	func _init(p_scope: AsyncScope, sec: float, callback: Callable) -> void:
		scope = p_scope
		_callback = callback
		_run(sec)

	## 按物理 tick 计时（process_in_physics=true）：与项目主流延时同一套时钟。
	func _run(sec: float) -> void:
		await Engine.get_main_loop().create_timer(sec, true, true).timeout
		_finish(true)

	## 提前撤销：不执行回调，结束等待
	func cancel() -> void:
		_finish(false)

	func _finish(completed: bool) -> void:
		if _settled:
			return
		_settled = true
		## 先把自己摘除，再通知与执行：回调可能重入（cancel_all / 再登记任务）。
		scope._forget(self)
		done.emit(completed)
		## 宿主已被销毁时不回调：调用方的闭包几乎都要直接访问宿主状态
		if completed and scope._host_alive() and _callback.is_valid():
			_callback.call()

## 本作用域尚未结算的任务
var _tasks: Array[_Task] = []
## 宿主弱引用。
var _host: WeakRef
## 本作用域的世代。
var generation := Generation.new()

## [param host] 宿主，通常是本作用域所属的那个 Node。
func _init(host: Object = null) -> void:
	## 先接自己的世代：即使没有宿主，外部换代也必须能撤销本作用域的等待
	generation.advanced.connect(_on_generation_advanced)
	if host == null:
		return
	## 弱引用。
	_host = weakref(host)
	## 宿主离开场景树（queue_free / 场景切换 / remove_child）时立即撤销全部任务，
	if host is Node:
		(host as Node).tree_exiting.connect(cancel_all)

## 登记一个延时并等待它。
func delay(sec: float) -> bool:
	var t := _Task.new(self, sec, Callable())
	## 必须先登记再等待：cancel_all() 只遍历集合，不登记的话本任务永远撤不掉
	_tasks.append(t)
	var completed: bool = await t.done
	return completed and _host_alive()

## 登记一个「到点执行一次」的任务。
func call_after(sec: float, callback: Callable) -> void:
	_tasks.append(_Task.new(self, sec, callback))

## 换代并撤销本作用域内所有尚未结算的任务：等待中的 [method delay] 立即恢复为 false。
func cancel_all() -> void:
	## 只换代，撤销经信号回流到 _on_generation_advanced —— 这样外部直接
	generation.next()

## 世代换代：撤销登记表里的全部任务
func _on_generation_advanced(_gen: int) -> void:
	## 先复制并清空集合，再逐个撤销：cancel() 会**同步**唤醒等待中的 delay()。
	var pending := _tasks.duplicate()
	_tasks.clear()
	for t in pending:
		t.cancel()

## 是否还有未结算的任务（调试 / 自检用）
func has_active_delays() -> bool:
	return not _tasks.is_empty()

func _host_alive() -> bool:
	return _host == null or _host.get_ref() != null

func _forget(task: _Task) -> void:
	_tasks.erase(task)
