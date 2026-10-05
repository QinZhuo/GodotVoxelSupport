@tool
## 异步作用域 —— 一段异步流程「这一轮」所拥有的、可撤销的异步任务的集合。
##
## 解决什么问题：Godot 的 `SceneTreeTimer` **不可取消**。`await get_tree().create_timer(x).timeout`
## 一旦挂起，就必然醒来并执行其后的副作用。若这期间宿主已被销毁或复用（对象池），
## 那份副作用就会作用在「别人正在用的对象」上——误停别人的特效、误回收在用的实例。
##
## 过去靠「世代计数器 + 醒来后比对」判定失效。那只是**事后检测**：等待者照样被挂住，
## 且每个复用点都要手工自增计数器，漏写一处就静默出错（这是令牌模式的固有成本）。
##
## 本类改为**资源所有权**：把这一轮挂起的任务登记在本作用域内，于生命周期边界
## [method cancel_all] 一次性撤销——等待中的 [method delay] **立即**恢复为 false，
## [method call_after] 的回调**根本不会执行**，判据本身随之消失。
## 因为是「主动撤销」而非「被动检测」，不存在「刚好在撤销与到期之间醒来」的竞态窗口。
##
## 两种用法，择其一：
## [codeblock]
## var _scope := AsyncScope.new(self)   # 传入宿主，本作用域便与它同生共死
##
## # 1) 需要「等待期间做别的事」或后继有分支 —— 用 delay
## func burst() -> void:
##     _scope.cancel_all()
##     ...
##     if not await _scope.delay(2.0):   # false = 别再碰宿主，后续一律不执行
##         return
##     stop()
##
## # 2) 只是「到点做一件事」——用 call_after，没有分支可以漏
## func burst() -> void:
##     _scope.cancel_all()
##     ...
##     _scope.call_after(2.0, stop)
##
## func on_pool_push() -> void:          # 对象归还池 = 这一轮结束
##     _scope.cancel_all()
## [/codeblock]
##
## 传入宿主后，[method delay] / [method call_after] 会在宿主被销毁时自动失效，
## 调用方**不必再自行判断实例是否有效**——这是本类「通用」的关键：
## 否则每个挂起点都要手写一遍防御，而防御是可以漏写的。
##
## 与 [GameTimer] 的分工：GameTimer 由宿主的物理 tick 驱动、经 TickTool 定序，
## 用于**必须可复现的战斗逻辑**（回放的顺序依赖它）。AsyncScope 不参与定序，
## 用于**表现层**（特效节奏、UI 收尾、池化视图的异步清理）——回放不关心这些，定了序反而是负担。
##
## [b]不覆盖[/b]：可撤销的**信号连接**与 [method Object.call_deferred] 队列。
## 特别提醒 [code]await tween.finished[/code] 是个陷阱：[method Tween.kill]
## [b]不会[/b]触发 [signal Tween.finished]，等待者会**永久挂起**造成协程泄漏。
## 要等补间结束请用 [code]tween.finished.connect(...)[/code] 配合本作用域，
## 或直接用 [method Tween.tween_callback]。
class_name AsyncScope extends RefCounted


## 一项可撤销的异步任务：到点执行一次回调，也可被等待。
## 撤销与到期**先到者赢**，只结算一次（幂等）。
class _Task extends RefCounted:
	## 任务结束时发射。completed 为 true = 真正到期，false = 被撤销
	signal done(completed: bool)

	## 所属作用域。用于结算时把自己摘除，以及执行回调前确认宿主仍在
	var scope: AsyncScope
	var _callback: Callable
	var _settled := false

	func _init(p_scope: AsyncScope, sec: float, callback: Callable) -> void:
		scope = p_scope
		_callback = callback
		_run(sec)

	## 按物理 tick 计时（process_in_physics=true）：与项目主流延时一致，
	## 免得这一段的时长随渲染帧抖动。仍受 time_scale 影响（慢动作下特效随之变慢）。
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
		## 先把自己摘除，再通知与执行：回调可能重入（cancel_all / 再登记任务），
		## 此时本任务已不在集合中，不会被重复看见或二次撤销
		scope._forget(self)
		done.emit(completed)
		## 宿主已被销毁时不回调：调用方的闭包几乎都要直接访问宿主状态
		if completed and scope._host_alive() and _callback.is_valid():
			_callback.call()


## 本作用域尚未结算的任务
var _tasks: Array[_Task] = []
## 宿主弱引用。**必须用弱引用**：强引用会让 Node 永远得不到释放
var _host: WeakRef


## [param host] 宿主，通常是本作用域所属的那个 Node。
## 传入后本作用域便与它**同生共死**：宿主离开场景树时立刻撤销全部任务，
## 调用方既不必写任何撤销分支，也不必再判断实例是否有效。
func _init(host: Object = null) -> void:
	if host == null:
		return
	## 弱引用。**不能用强引用**，否则 Node 永远等不到释放
	_host = weakref(host)
	## 宿主离开场景树（queue_free / 场景切换 / remove_child）时立即撤销全部任务，
	## 而不是等各延时到期——否则宿主都没了，等待者还要白挂几秒才返回。
	## 这一条连接就是「零宿主接线」的来源：宿主只需声明 _scope，
	## 不必在每个生命周期边界手工写一遍 cancel_all。
	## 不设 ONE_SHOT：节点可能被 remove 后重新入树，监听必须活过多次进出
	if host is Node:
		(host as Node).tree_exiting.connect(cancel_all)


## 登记一个延时并等待它。
## [param sec] 延时秒数
## [return] true = 真正到期且宿主仍在，可以继续执行后继副作用；
##         false = 已被 [method cancel_all] 撤销，或宿主已销毁，
##         **后续代码不应再触碰宿主状态**（宿主此刻可能已被回收复用给他人）。
func delay(sec: float) -> bool:
	var t := _Task.new(self, sec, Callable())
	## 必须先登记再等待：cancel_all() 只遍历集合，不登记的话本任务永远撤不掉
	_tasks.append(t)
	var completed: bool = await t.done
	return completed and _host_alive()


## 登记一个「到点执行一次」的任务。撤销或宿主销毁时回调**不会执行**。
## 适合「到点做一件事」——没有任何分支需要书写，也就不存在漏写分支的失误。
## 需要「等待期间做别的事」或后继需要判断时，改用 [method delay]。
func call_after(sec: float, callback: Callable) -> void:
	_tasks.append(_Task.new(self, sec, callback))


## 撤销本作用域内所有尚未结算的任务：等待中的 [method delay] 立即恢复为 false，
## [method call_after] 的回调不再执行。幂等，可重复调用。
func cancel_all() -> void:
	## 先复制并清空集合，再逐个撤销：cancel() 会**同步**唤醒等待中的 delay()，
	## 而那个协程恢复后会回头结算。直接边遍历边缩容会漏掉后面的项，撤销静默失效
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