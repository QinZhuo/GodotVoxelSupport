@tool
## 教程流程控制器 — 订阅任务步骤, 把每一步翻译成"聚焦哪几个目标 + 提示什么", 表现交给 FocusMaskTool。
## 自身不绘制任何东西: 遮罩/输入收口是通用能力, 教程只决定"什么时候聚焦谁"。
class_name TutorialGuide extends Node

## 步骤进入(供外部绑定步骤 UI/进度条/埋点)
signal step_started(step: Task)
## 步骤完成(skip_if 直接跳过的步骤不发)
signal step_completed(step: Task)
## 教程被提前结束/跳过
signal stopped()

## 无目标步骤的"继续"动作(键盘/手柄); 空 = 只能点击
@export var advance_action: StringName = &"ui_accept"
## 暗区颜色(全流程统一)。alpha 只做"轻微压暗", 焦点目标靠 focus_boost 提亮来拉差异
@export var dim_color := Color(0.039, 0.039, 0.051, 0.5)
## 目标提亮倍数(>1 = 比平时更亮, 与压暗的周围拉开对比)
@export var focus_boost := 1.6
## 拖拽放行(可选): 返回 true 时放行移动/松手/右键(拖出可交互区域不被截断), 左键按下照旧按目标拦
var drag_checker: Callable

var _task: GroupTask
var _host: Node
var _paused_tree: SceneTree
var _active_step: Task
var _on_step_changed: Callable
var _mask: FocusMask


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	_resume()
	_clear_mask()
	_unbind()


# ------------------------------------------------------------
# 驱动
# ------------------------------------------------------------

## 一行启动: 建任务 → 激活 → 首次渲染; opts: pause_tree(bool) / on_step_changed(Callable)
func start(flow: GroupTaskDef, host: Node, opts: Dictionary = {}) -> GroupTask:
	if opts.get("pause_tree", false) and host and host.is_inside_tree():
		_paused_tree = host.get_tree()
		_paused_tree.paused = true
	var task := flow.create_entity() as GroupTask
	task.activate({"root": host})
	bind_task(task, host, opts.get("on_step_changed", Callable()))
	return task


## 绑定外部创建的任务(自己持有实体, 便于存档/连接 completed)
func bind_task(task: GroupTask, host: Node, on_step_changed: Callable = Callable()) -> void:
	if task == null:
		return
	if is_instance_valid(_task) and _task != task:
		_task.deactivate()  # 旧任务不再由本 Guide 驱动, 避免其信号继续推进
	_unbind()
	_task = task
	_host = host
	_on_step_changed = on_step_changed
	task.step_entered.connect(_on_step_entered)
	task.child_completed.connect(_on_child_completed)
	task.completed.connect(_on_completed)
	# activate 已发过一次 step_entered(此时未连), 补首次渲染
	_on_step_entered(task.active_child_entity)


## 提前结束/跳过(不触发 completed, 发 stopped, 供"跳过教程"按钮调用)
func stop() -> void:
	if is_instance_valid(_task):
		_task.deactivate()
	_unbind()
	_resume()
	_clear_mask()
	_active_step = null
	stopped.emit()


## 注: 本类不接管任何"退出/跳过"按键 —— 需要的话由项目在自己的 _input 里调 stop()。
## (遮罩会把 ui_cancel 当锁定输入处理, 所以项目的处理同样要放在 _input 阶段)


## 重新渲染当前步骤(离开子界面返回、目标重新可见时刷新)
func refresh() -> void:
	if _active_step and not _active_step.is_completed:
		show_step(_active_step)


## 临时收起表现(任务与进度保留, 稍后再 show_step/refresh 恢复)
func blur() -> void:
	_clear_mask()


## 覆盖气泡文案(步骤内需要换说法时用)。直接走对话子系统, 不再经过遮罩。
func set_tip(text: String) -> void:
	if text.is_empty():
		DialogueTool.hide()
		return
	var anchor := _mask.get_focus_rect() if _mask else Rect2()
	DialogueTool.show(text, anchor)


## 纯提示气泡的顶部下限(屏幕 Y, -1 = 不限)
func set_tip_limit(max_y: float) -> void:
	var view := DialogueTool.view()
	if view:
		view.limit_top = max_y
		view.refresh()


## 渲染某一步: 解析目标 → 交给焦点遮罩, 提示文字取步骤 desc
##   - 有目标            → 只保留目标可交互, 其余变暗
##   - 无目标 + 有信号   → 只显示提示, 不遮挡(等待外部流程)
##   - 无目标 + 无信号   → 全屏变暗, 点任意处/按继续键推进
func show_step(step: Task) -> void:
	_active_step = step
	var def := step.def as TutorialStepDef if step else null
	if def and def.silent:
		_clear_mask()
		return
	var targets: Array[Node] = def.find_targets(_host) if def else []
	var has_targets := not targets.is_empty()
	var click := def.click_to_complete_for(has_targets) if def else true
	var visible := has_targets or click
	## 拦截与"是否建暗场"解耦: 无目标但等信号的步骤(看了就得点某处推进)以前一律不拦,
	## 玩家能直接点到摇杆等流程入口。要放行就用 targets 圈出可点的区域, 或显式 block_input=false
	var block := def.block_input if def else true
	var dim := dim_color if visible and (def == null or def.dim) else Color(dim_color, 0.0)
	_mask = FocusMaskTool.focus(targets, {
		"block": block,
		"click_to_complete": click,
		"advance_action": advance_action,
		"drag_checker": drag_checker,
		"dim": dim,
		"focus_boost": focus_boost,
	}, _host)
	## 文案直接交给对话子系统 —— 遮罩只负责"锚在哪", 不再当 Task→Dialogue 的传话人
	if _mask:
		DialogueTool.show(step.get_current_desc() if step else "", _mask.get_focus_rect())
	if _mask and not _mask.blank_pressed.is_connected(_on_blank_pressed):
		_mask.blank_pressed.connect(_on_blank_pressed)


func is_blocking() -> bool:
	return FocusMaskTool.is_blocking()


func get_mask() -> FocusMask:
	return _mask if is_instance_valid(_mask) else null


# ------------------------------------------------------------
# 内部
# ------------------------------------------------------------

func _on_step_entered(step: Task) -> void:
	if step and not step.is_completed:
		show_step(step)
		step_started.emit(step)
	if _on_step_changed.is_valid():
		_on_step_changed.call()


func _on_child_completed(_index: int, child: Task) -> void:
	step_completed.emit(child)


func _on_completed() -> void:
	# 不解绑: GroupTask 先发 completed 再发 child_completed, 提前解绑会丢掉最后一步的 step_completed
	_active_step = null
	_resume()
	_clear_mask()


func _on_blank_pressed() -> void:
	if _active_step and not _active_step.is_completed:
		_active_step.complete()


func _unbind() -> void:
	if not is_instance_valid(_task):
		_task = null
		return
	for binding in [[&"step_entered", _on_step_entered], [&"child_completed", _on_child_completed],
			[&"completed", _on_completed]]:
		if _task.is_connected(binding[0], binding[1]):
			_task.disconnect(binding[0], binding[1])
	_task = null


func _clear_mask() -> void:
	if _mask == FocusMaskTool.get_mask():
		FocusMaskTool.clear()
	_mask = null


func _resume() -> void:
	if _paused_tree:
		_paused_tree.paused = false
		_paused_tree = null
