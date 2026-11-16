class_name GameTimer extends RefCounted

## 可被外部推进的轻量计时器（由宿主的物理 tick 驱动 ⇒ 计时基准是物理 tick，与帧率无关）。
##
## ===== 框架里有两个计时器, 按需求**显式选择**, 不做自动切换 =====
##   · 本文件(GameTimer): **OOP 版**。可暂停/继续、可手动 tick、按 `order_key` 确定性发射
##     (依赖 TickTool.defer)。适合: 回合制、需要严格时序、或**不用 ECS 的项目**。
##     成本: 每对象一次 advance(约 200~400ns), 与数量线性。
##   · `ECS/Timer/{TimerComponent,TimerSystem}`: **ECS 版**。计时器是实体, 整列推进 + 原生条件过滤。
##     适合: 上千个同类冷却/DoT(空闲推进 2000 个约 0.06ms)。
## 两者语义一致(到期发一次通知), 差别是"发射顺序"(本版按 order, ECS 版按聚合行序)与存储形态。

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
