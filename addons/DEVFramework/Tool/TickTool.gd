class_name TickTool extends RefCounted

## 物理 tick 步进队列 —— 让"同一 tick 内多个等待恢复的先后"变成**确定**的。
##
## 为什么需要：多条并发协程（例如双方各自的触发链）共享可变状态时，每一步的"等待"
## 若取决于"谁的计时器先到期"，同一 tick 上的先后就没有约定 ⇒ 同输入可能走出不同的事件序列，
## 回放因此无法复现。本工具把"恢复的先后"从执行时机里拿出来，变成**队列顺序**。
##
## 契约（顺序 = 队列内容的纯函数）：
##   · 宿主每物理 tick **末尾**调用 `tick()` 一次（在角色 `_physics_process` 之后）；
##   · 等待者用 `defer(lane, 动作)` 登记"本 tick 结尾执行"的动作；
##   · 派发按 `lane` 升序、同 `lane` 按登记先后（FIFO），且**在本 tick 内完成**；
##   · `lane` 必须是**记录意图的纯函数**（例："玩家 0、敌方 1"）。
##     ⚠️ 不许拿"当前遍历到的第几个"当 lane —— 那等于把执行顺序又偷回来，不确定性立刻回到场上；
##   · 派发过程中新登记的条目属于**下一 tick**（不掺进本轮）；
##   · `lane` 的含义由**项目**决定，框架不解释。
##
## 自检与兜底：未接线（无人调用 `tick()`）时 `defer` 立即执行并**告警一次** ——
## 不挂住等待，但也不让"确定性静默失效"；队列积压到 `BACKLOG_WARN` 也告警（驱动者停了的征兆）。

## 队列积压告警阈值：条目只进不出 ⇒ 驱动者（`tick()`）已经不再被调用
const BACKLOG_WARN := 512

static var _driven := false
static var _warned := false
static var _backlog_warned := false
## 派发中标记：防止被派发的动作间接再调 `tick()` 导致同一批派发两次
static var _flushing := false
static var _seq := 0
static var _queue: Array = []


## 宿主每物理 tick 末尾调用一次（唯一接线点）
static func tick() -> void:
	_driven = true
	if _flushing or _queue.is_empty():
		_seq = 0
		return
	_flushing = true
	_backlog_warned = false
	var due := _queue
	_queue = []
	## 序号**每 tick 归零**：排序只在同一 tick 内有意义。不归零它会跨场累加，
	## 一旦越过 lane 的取值区间就会把不同 lane 的条目排错 —— 长会话才复现，极难查。
	_seq = 0
	due.sort_custom(func(a, b):
		return int(a[0]) < int(b[0]) if int(a[0]) != int(b[0]) else int(a[1]) < int(b[1]))
	for e in due:
		var action: Callable = e[2]
		## 持有对象已释放 ⇒ 跳过（这一步不该再执行，不是错误）
		if action.is_valid():
			action.call()
	_flushing = false


## 登记一个"本 tick 末尾按序执行"的动作
static func defer(lane: int, action: Callable) -> void:
	if not _driven:
		if not _warned:
			_warned = true
			LogTool.warn("步进", "TickTool 未被驱动（无人调用 tick()）⇒ defer 退回立即执行，顺序不再受控")
		action.call()
		return
	if not _backlog_warned and _queue.size() >= BACKLOG_WARN:
		_backlog_warned = true
		LogTool.warn("步进", "队列积压 %d 条：驱动者（TickTool.tick()）是否已停？" % _queue.size())
	_seq += 1
	_queue.append([lane, _seq, action])


## 清空队列（每回合/每场开始前）：避免上一轮的遗留步进漏到下一轮
static func clear() -> void:
	_queue = []
	_seq = 0
