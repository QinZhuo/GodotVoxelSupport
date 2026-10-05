class_name GameTimer extends RefCounted

## 可被外部推进的轻量计时器（由宿主的物理 tick 驱动 ⇒ 计时基准是物理 tick，与帧率无关）。
##
## 到期时**不立即发射**，而是交给 `TickTool` 按 `order_key` 排进本 tick 的派发队列 ——
## 于是"同一 tick 内多个等待恢复的先后"由队列决定、可复现；`order_key` 的含义由创建者
## （项目侧）决定，框架不解释它。
## 未接线 `TickTool`（无人调用 `tick()`）时行为与普通计时器一致：到期即发射。

signal timeout(not_stop: bool)

var time: float
var cur_time := 0.0
## 是否已发射（幂等：防止重复派发）
var emitted := false
## 最近一次推进时给入的次序 —— 供 `stop()` 复用（保证"取消"与"到期"落在同一个顺序里）
var _order := 0


func _init(init_time := 0.0):
	time = init_time


## 推进；到期时把"发射"按 `order_key` 排进本 tick 的队列。
## `order_key` **每次推进时传入**（而不是创建时记住）：它表达的是"此刻谁先"，应当由
## 宿主在用到的那一刻求值（创建计时器时宿主的双方可能还没就位）。
func advance(delta: float, order_key := 0) -> void:
	_order = order_key
	if emitted or cur_time >= time:
		return
	cur_time += delta
	if cur_time >= time:
		emitted = true
		TickTool.defer(order_key, _emit_true)


## 提前停止（未到期才生效）：同样进队列，"取消"也落在同一个顺序里
func stop() -> void:
	if emitted or cur_time >= time:
		return
	emitted = true
	TickTool.defer(_order, _emit_false)


func _emit_true() -> void:
	timeout.emit(true)


func _emit_false() -> void:
	timeout.emit(false)
