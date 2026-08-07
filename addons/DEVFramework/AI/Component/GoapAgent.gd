class_name GoapAgent extends Component

## GOAP 智能体 — 挂在任意 NPC / 单位节点上的通用 AI 组件。
##
## 工作流程：
##   1. 每帧 tick，处于空闲时周期性（replan_interval）或世界状态变化时请求规划
##   2. 按优先级选择第一个能规划出行动序列的目标
##   3. 依序执行行动；行动会修改世界状态
##   4. 行动完成后（默认）立即重新规划，形成"目标导向"的持续决策
##
## 接入方式：
##   - 在场景中配置 goals / actions 数组（Def 资源）
##   - 行动执行：配置 GoapActionDef.perform_method，在 Agent 子类（或挂载脚本）
##     中实现同名方法。方法返回 true / false / null 分别表示同步完成 / 失败 / 异步
##   - 异步执行：方法内部完成后调用 notify_action_finished(success)
##   - 世界状态：set_state(key, value) / get_state(key)
##
## 扩展点（覆写）：
##   - is_goal_active(goal)   : 额外目标激活判断
##   - sort_goals(goals)      : 自定义目标优先级排序
##   - on_action_execute(action) : perform_method 为空时的兜底执行钩子

@export var goals: Array[GoapGoalDef] = []
@export var actions: Array[GoapActionDef] = []
@export_range(0.0, 10.0, 0.1) var replan_interval: float = 0.5
@export_range(2, 20) var max_plan_depth: int = 12
@export var auto_plan: bool = true
@export var replan_after_action: bool = true
## 行动失败后重新规划的最小冷却时间（秒）。防止"失败->立即重规划->再失败"的同帧
## 死循环刷爆 CPU。连续失败会退避（见 failure_backoff_factor）。
@export_range(0.0, 5.0, 0.05) var failure_replan_delay: float = 0.5
## 连续失败退避倍数：第 n 次失败冷却 = failure_replan_delay * factor^(n-1)（封顶见 failure_backoff_max）
@export_range(1.0, 4.0, 0.1) var failure_backoff_factor: float = 1.5
## 退避冷却封顶（秒）
@export_range(0.1, 10.0, 0.1) var failure_backoff_max: float = 3.0
@export var debug_enabled: bool = false

signal plan_found(goal: GoapGoal, plan: Array)
signal plan_failed(goal: GoapGoal)
signal action_started(action: GoapAction)
signal action_finished(action: GoapAction, success: bool)
signal plan_completed(success: bool)
signal state_changed(key, value)

enum AgentState { IDLE, EXECUTING }

var world_state: GoapWorldState
var current_goal: GoapGoal
var current_plan: Array[GoapAction] = []
var paused: bool = false

var _planner: GoapPlanner
var _current_action: GoapAction
var _state: AgentState = AgentState.IDLE
var _replan_timer := 0.0
var _world_dirty := true
var _fail_streak := 0
var _last_fail_time := 0.0


func _ready() -> void:
	world_state = GoapWorldState.new()
	world_state.changed.connect(_on_world_state_changed)
	_planner = GoapPlanner.new()
	_planner.max_depth = max_plan_depth
	set_process(auto_plan)
	_ready_goap()


## 子类可覆写的初始化钩子
func _ready_goap() -> void:
	pass


func _process(delta: float) -> void:
	tick(delta)


## 主驱动，可被外部手动调用（如回合制逻辑）
func tick(delta: float) -> void:
	if paused:
		return
	_replan_timer += delta
	if _state == AgentState.IDLE and (_world_dirty or _replan_timer >= replan_interval):
		# 失败冷却中：即使 dirty 也不立即重规划，避免死循环刷爆 CPU
		if _in_failure_cooldown():
			return
		_replan_timer = 0.0
		replan()


## —— 世界状态 ——

func set_state(key, value) -> void:
	world_state.set_value(key, value)


func get_state(key, default = null):
	return world_state.get_value(key, default)


## 外部通知世界状态变化（触发重新规划）
func mark_dirty() -> void:
	_world_dirty = true


## —— 规划 ——

## 立即重新规划并（若有方案）开始执行
func replan() -> void:
	if paused:
		return
	# 失败冷却期内拒绝重规划，防止 call_deferred/replan 死循环绕过 tick 冷却
	if _in_failure_cooldown():
		_world_dirty = true
		return
	_world_dirty = false
	var result := _try_plan()
	if result.is_empty():
		var failed_goal := current_goal
		plan_failed.emit(failed_goal)
		if _state == AgentState.EXECUTING:
			_finish_plan(false)
		return

	current_goal = result[0]
	current_plan = result[1]
	_state = AgentState.EXECUTING
	if debug_enabled:
		LogTool.log("GOAP", "%s 规划成功 -> %s: %s" % [name, current_goal.def.name, _plan_desc()])
	plan_found.emit(current_goal, current_plan)
	_execute_next_action()


## 按优先级选择目标并规划，返回 [goal, plan]；无可行方案返回空数组
func _try_plan() -> Array:
	var candidates: Array[GoapGoal] = []
	for goal_def in goals:
		var goal := GoapGoal.create(goal_def)
		if goal.is_active(self) and is_goal_active(goal):
			candidates.append(goal)
	sort_goals(candidates)
	for goal in candidates:
		var plan := _planner.plan(world_state, goal.def.goal_state, actions)
		if not plan.is_empty():
			return [goal, plan]
	return []


## —— 执行 ——

func _execute_next_action() -> void:
	if current_plan.is_empty():
		_finish_plan(true)
		return
	var action: GoapAction = current_plan.pop_front()
	# 执行前校验：行动前提 / 附加条件在规划后可能已失效（如目标被抢占、状态变化）。
	# 不满足则丢弃整个剩余计划重新规划，避免用陈旧世界状态硬执行导致反复失败。
	if not action.can_run(world_state, self):
		current_plan.clear()
		action.end(self)
		_enter_failure_cooldown()
		call_deferred("replan")
		return
	_current_action = action
	action.begin(self)
	action_started.emit(action)
	action.execute(self)


## 异步行动完成后由外部（或行动方法内部）调用
func notify_action_finished(success: bool) -> void:
	var action := _current_action
	_current_action = null
	if action == null:
		return
	action.end(self)
	action_finished.emit(action, success)
	if debug_enabled:
		LogTool.log("GOAP", "%s 行动 %s %s" % [name, action.def.name, "完成" if success else "失败"])
	if success:
		action.apply_effects(world_state)
		_fail_streak = 0
	if not success:
		_enter_failure_cooldown()
	if not success:
		# 失败：冷却后重规划。冷却期内即使 dirty 也不会立即重规划。
		call_deferred("replan")
	elif replan_after_action:
		# 延迟到帧末重规划，避免行动同步完成时 replan→execute→notify 同帧递归（栈溢出）
		call_deferred("replan")
	else:
		_execute_next_action()


## 记录一次失败并进入重规划冷却（连续失败指数退避）
func _enter_failure_cooldown() -> void:
	_fail_streak += 1
	var delay := minf(failure_replan_delay * pow(failure_backoff_factor, _fail_streak - 1.0), failure_backoff_max)
	_last_fail_time = Time.get_ticks_msec() / 1000.0 + delay


## 当前是否处于失败冷却期
func _in_failure_cooldown() -> bool:
	if _fail_streak <= 0:
		return false
	return (Time.get_ticks_msec() / 1000.0) < _last_fail_time


func _finish_plan(success: bool) -> void:
	_state = AgentState.IDLE
	_current_action = null
	current_plan.clear()
	plan_completed.emit(success)


## 中断当前执行并回到空闲状态（供外部事件如被杀/重生时调用）。
## 清空进行中的动作与剩余计划，置脏以便下一帧重新规划。
func reset_plan() -> void:
	_state = AgentState.IDLE
	_current_action = null
	current_plan.clear()
	_world_dirty = true
	_fail_streak = 0
	_last_fail_time = 0.0


func get_current_action() -> GoapAction:
	return _current_action


func has_plan() -> bool:
	return not current_plan.is_empty() or _current_action != null


## —— 子类扩展点 ——

## 覆写：额外目标激活判断
func is_goal_active(_goal: GoapGoal) -> bool:
	return true


## 覆写：自定义目标排序（默认按 priority 降序）
func sort_goals(goals: Array[GoapGoal]) -> void:
	goals.sort_custom(func(a: GoapGoal, b: GoapGoal) -> bool:
		return a.get_priority() > b.get_priority()
	)


## 覆写：perform_method 为空时的兜底执行钩子
func on_action_execute(action: GoapAction) -> void:
	notify_action_finished(true)


## —— 调试与序列化 ——

func _plan_desc() -> String:
	var parts: Array[String] = []
	for action in current_plan:
		parts.append(action.def.name)
	return " -> ".join(parts)


func _on_world_state_changed(key, _old, _new) -> void:
	_world_dirty = true
	state_changed.emit(key, world_state.get_value(key))


func save_data() -> Dictionary:
	return {
		"world_state": world_state.to_dict(),
		"current_goal": current_goal.def.name if current_goal else "",
	}


func load_data(dict: Dictionary) -> void:
	if dict.has("world_state"):
		world_state.reset(dict["world_state"])
