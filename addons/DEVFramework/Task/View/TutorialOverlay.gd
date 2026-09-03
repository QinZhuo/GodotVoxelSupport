@tool
## 教程引导覆盖层 — 遮罩/挖孔/边框/箭头/提示气泡一体化控件, 也是教程流程的唯一控制器
## (直接订阅 GroupTask 的逐步信号, 步骤进入→渲染、纯提示点击→判定完成), 类 Godot 内置控件, 支持主题定制。
##
## 用法(项目创建后挂到自己的 CanvasLayer):
##   var guide := TutorialOverlay.new()
##   guide.set_anchors_preset(Control.PRESET_FULL_RECT)
##   guide.start(flow, host)                       # 一行启动(推荐)
##   guide.stop()                                  # 提前结束/跳过
## 低层手动路径: focus(target, target_def, block, click_to_complete, tip_text) / blur()
##
## 主题命名空间 "TutorialOverlay"(与 OptionSelector 一致, 走 Godot 标准主题查找链:
## 本地 → 祖先 → 项目主题, 未定义时用 _DEFAULT_* 回退):
##   Color    dim_color         遮罩暗色
##   StyleBox frame_stylebox    挖孔边框样式
##   Color    arrow_color       指示箭头颜色
##   int      arrow_size        箭头长度(像素)
##   StyleBox tip_stylebox      提示气泡面板
##   Color    tip_font_color    气泡文字颜色
##   int      tip_font_size     气泡字号
class_name TutorialOverlay extends Control

## 空洞/孔内点击(仅 click_to_complete 步骤启用, 用于"点屏幕区域完成"兜底)
signal hole_clicked()
## 步骤进入(step 为当前活跃 Task, 供外部绑定步骤 UI/进度条/播音频)
signal step_started(step: Task)
## 步骤完成(供漏斗埋点; skip_if 直接跳过的步骤不会发此信号)
signal step_completed(step: Task)
## 教程被提前结束/跳过(stop(), 供漏斗埋点"中途放弃")
signal stopped()
## 纯提示步骤的"继续"输入动作(键盘/手柄), 空 = 仅指针点击。
## 有 target 的步骤不走此动作 —— 完成靠目标自身交互(Enter 会激活已聚焦的目标控件)。
@export var advance_action: StringName = &"ui_accept"

const _DEFAULT_DIM := Color(0, 0, 0, 0.55)
const _DEFAULT_ARROW := Color(1, 0.82, 0.25, 1)
const _DEFAULT_TIP_TEXT := Color(0.95, 0.95, 0.95, 1)

# --- 状态 ---
var _target: Node
var _target_def: TutorialTargetDef
var _block := true
var _click_to_complete := false
var _active := false  # 聚焦中标志: blur(完成/未开始) 时不绘制也不拦截; 聚焦中且无孔(纯提示)才画全屏暗区
var _arrow := true  # 当前步骤是否显示指示箭头(读 TutorialTargetDef.arrow)
var _tip_bottom_margin := 28.0  # 纯提示气泡距屏幕底部的边距(像素)
var _tip_min_height := 160.0  # 纯提示气泡最小高度(像素, 保证文本框有足够的垂直高度)
var _tip_top_limit := -1.0  # 纯提示气泡顶部上限 Y(屏幕坐标, 用于"不遮住商店最下方物品购买按钮"), -1 = 不限制
var _hole := Rect2()
var _target_rect := Rect2()  # 每帧精确目标矩形, _hole 平滑逼近它, 避免镜头转动/目标移动时挖孔跳变
var _last_hole := Rect2()  # 上一帧挖孔(未变化且无动画时跳过重绘)
var _rects_key: Array = []  # _apply_rects 布局缓存键: 未变化则跳过重设拦截板矩形与过滤(避免每帧触发子控件重排)
var _tip_layout_key: Array = []  # _place_tip 布局缓存键: 文本/几何未变则跳过 RichTextLabel 重新排版
var _time := 0.0
var _arrow_dir := Vector2.DOWN
var _arrow_anchor := Vector2.ZERO
var _task: GroupTask  # start() 创建的任务(供 stop() 停用)
var _paused_tree: SceneTree  # start({pause_tree}) 暂停的世界(完成后自动恢复)
var _host: Node  # 步骤 target 解析宿主(bind_task/start 记录, show_step 用)
var _active_step: Task  # 当前活跃任务步骤(纯提示点击完成请求的载体)
var _on_step_changed: Callable  # bind_task 步骤推进回调(宿主存进度/发日志等)
var _hover_hits_draggable := false  # 最近物理帧鼠标位置是否命中可拖拽 3D 目标(拖拽按下放行用)
## 放行孔外按下(拖拽类步骤: 目标可能超出挖孔, 需放行按下才能开始拖拽)。
## 由 TutorialTargetDef.allow_outside_drag 在 show_step 时自动带入, 也可在运行时手动改。
var allow_hand_drag := false
## 拖拽放行判定(可选注入): funcref/无参 lambda, 返回 true 时 Guide 放行全部指针事件,
## 避免打断"拖出聚焦框"的拖拽。框架不认识"该项目的拖拽视图类", 由项目注入"是否正在拖拽"。
var drag_checker: Callable = Callable()

# --- 主题缓存 ---
var _dim_color := _DEFAULT_DIM
var _frame_style: StyleBox
var _arrow_color := _DEFAULT_ARROW
var _arrow_size := 28.0
var _default_frame: StyleBoxFlat

# --- 子节点(仅承担输入拦截, 全部视觉统一在 _draw 绘制: 暗区→边框→箭头 层级正确) ---
var _dim_top := Control.new()
var _dim_bottom := Control.new()
var _dim_left := Control.new()
var _dim_right := Control.new()
var _sensor := Control.new()
var _tip_panel: Panel
var _tip_text_label: RichTextLabel


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_default_frame = StyleBoxFlat.new()
	_default_frame.draw_center = false
	_default_frame.border_width_left = 2
	_default_frame.border_width_top = 2
	_default_frame.border_width_right = 2
	_default_frame.border_width_bottom = 2
	_default_frame.border_color = _DEFAULT_ARROW
	_default_frame.set_corner_radius_all(4)


func _ready() -> void:
	set_process_input(true)  # 启用节点级 _input: 用于在物理拾取前阻断目标外点击
	_build_widgets()
	_apply_theme()
	# 纯提示(无目标)步骤的"点任意处继续"由本控件自行推进, 宿主无需再转发 hole_clicked
	hole_clicked.connect(_on_hole_clicked_internal)
	blur()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()


# ------------------------------------------------------------
# 公开接口
# ------------------------------------------------------------

## 聚焦目标(全屏遮罩 + 挖孔; target 为空 = 纯提示不挖孔)
func focus(target: Node, target_def: TutorialTargetDef, block: bool, click_to_complete: bool, tip_text: String = "") -> void:
	_active = true
	_target = target
	_target_def = target_def
	_block = block
	_click_to_complete = click_to_complete
	_arrow = target_def.arrow if target_def else true
	_last_hole = Rect2()
	set_tip(tip_text)
	_update_geometry()
	_hole = _target_rect  # 首次聚焦瞬移到位(不做平滑插值)
	_apply_rects()
	var v := get_viewport_rect().size
	_update_arrow(v)
	_place_tip(v)
	_focus_target_control()
	queue_redraw()


## 从任务步骤渲染表现(播放桥接: 外部连 task.entity_changed 调用本方法; 无表现字段的普通步骤退化为纯提示)
## 锁定语义自动推导:
##   - 存在 target → 遮挡目标外输入(遮罩挖孔、只点目标, 完成靠目标自身交互/信号)
##   - 无 target 无信号 → 纯提示: 画全屏暗区(除文本气泡外调暗), 强制"点任意处继续"
##   - 无 target 有信号 → 纯提示不遮挡, 等待信号推进(如结算衔接步骤, 不拦截面板按钮)
func show_step(step: Task, host: Node) -> void:
	var step_def := step.def as TutorialStepDef if step else null
	blur()
	_active_step = step
	_host = host
	var target_def: TutorialTargetDef = step_def.target if step_def else null
	# 完成语义由 TutorialStepDef 归口(resolve_target/has_signals), 表现层只组合决策, 不反射任务内部
	var target: Node = step_def.resolve_target(host) if step_def else null
	# 每步重置拖拽放行态: 避免上一步开启的放行残留到本步骤导致误放行孔外点击;
	# 初值取 TutorialTargetDef.allow_outside_drag(拖拽类步骤在配置里声明), 运行期仍可手动改。
	allow_hand_drag = target_def.allow_outside_drag if target_def else false
	var has_target := target != null
	# 完成方式自动推导(归口 TutorialStepDef.click_to_complete_for, target 已解析, 不重复 resolve):
	# - 有 target        → 挖孔阻挡孔外输入, 完成靠目标交互/信号
	# - 无 target 有信号 → 纯提示不阻挡、也不点击完成, 等待信号(如"结算衔接"步骤)
	# - 无 target 无信号 → 纯提示, 点击任意处完成(由此 click_to_complete 承载, 与完成请求共用)
	var click_to_complete: bool = step_def.click_to_complete_for(has_target) if step_def else false
	# 遮罩策略: 有 target(挖孔) 或"点击任意处继续"的纯提示(click_to_complete)都画暗区并强制点击,
	# 使全屏文本提示与指定操作步骤一样: 除文本气泡高亮外其余位置调暗, 玩家只能点击继续。
	# 仅"等待信号"的纯提示步骤(click_to_complete=false)保持不遮罩, 以便玩家操作界面触发信号。
	focus(target, target_def,
			has_target or click_to_complete,
			click_to_complete,
			step.get_current_desc() if step else "")


## 取消聚焦(全部隐藏: 不绘制暗区/边框/箭头, 拦截板失效)
func blur() -> void:
	_active = false
	_target = null
	_target_def = null
	_active_step = null
	_tip_top_limit = -1.0
	_arrow = true
	_hole = Rect2()
	_target_rect = Rect2()
	_last_hole = Rect2()
	_rects_key = []
	_apply_rects()
	if _tip_panel:
		_tip_panel.visible = false
		_tip_layout_key = []
	queue_redraw()


# ------------------------------------------------------------
# 一行启动(便捷; 等价外部手动桥接: 创建任务→连信号→activate→首次渲染)
# ------------------------------------------------------------

## 在已挂载的 Guide 上直接启动教程: 内部完成"Task 推进→渲染"桥接, 完成后自动 blur。
## 与手动路径完全等价(外部仍可通过返回的 task 连接 completed / 调 save_data 存档)。
## [param flow] 教程流程(GroupTaskDef, 步骤为 TutorialStepDef; SEQUENTIAL)
## [param host] 教程宿主(目标路径/信号解析相对它)
## [param opts] {pause_tree: bool} 可选暂停世界(完成后自动恢复)
## [return] GroupTask 实体(由外部持有)
func start(flow: GroupTaskDef, host: Node, opts: Dictionary = {}) -> GroupTask:
	var task := flow.create_entity() as GroupTask
	if opts.get("pause_tree", false):
		_paused_tree = host.get_tree()
		_paused_tree.paused = true
		process_mode = Node.PROCESS_MODE_ALWAYS
	task.activate({"root": host})
	bind_task(task, host)
	return task


## 绑定外部创建的任务(与 start() 等价, 但由外部持有任务实体, 便于存档/连接 completed)。
## 直接订阅 GroupTask 的逐步信号(step_entered/child_completed/completed), Guide 即教程控制器:
## 步骤进入→渲染表现、纯提示点击→判定完成。无中间转发器。
## [param task] 已激活的 GroupTask(步骤为 TutorialStepDef)
## [param host] 教程宿主(步骤 target 相对它解析)
## [param on_step_changed] 步骤推进回调(宿主存进度/发日志等, 可选)
func bind_task(task: GroupTask, host: Node, on_step_changed: Callable = Callable()) -> void:
	_task = task
	_host = host
	_on_step_changed = on_step_changed
	# 直接订阅 GroupTask 的逐步信号(GroupTask 自内建 step_entered), 无需外部转发器
	if not task.step_entered.is_connected(_on_task_step_entered):
		task.step_entered.connect(_on_task_step_entered)
	if not task.child_completed.is_connected(_on_task_child_completed):
		task.child_completed.connect(_on_task_child_completed)
	if not task.completed.is_connected(_on_task_completed):
		task.completed.connect(_on_task_completed)
	# activate 已发过一次 step_entered(此时未连), 手动补首次渲染
	_on_task_step_entered(task.active_child_entity)


## 某步骤进入 → 渲染表现 + 广播 step_started + 触发进度回调
func _on_task_step_entered(step: Task) -> void:
	if step and not step.is_completed:
		show_step(step, _host)
		step_started.emit(step)
	if _on_step_changed.is_valid():
		_on_step_changed.call()


## 某子步骤完成 → 转发为步骤级埋点信号
func _on_task_child_completed(_index: int, child: Task) -> void:
	step_completed.emit(child)


## 整组完成 → 结束聚焦并恢复暂停世界
func _on_task_completed() -> void:
	blur()
	if _paused_tree:
		_paused_tree.paused = false
		_paused_tree = null
	_task = null


## 重新渲染当前活跃步骤(从商店返回等场景, 目标重新可见时刷新表现)
func refresh() -> void:
	if _active_step and not _active_step.is_completed and _host:
		show_step(_active_step, _host)


## 纯提示(无目标)步骤的"点任意处 / 按继续键"完成: 由本控制器判定 click_to_complete 后推进。
## 完成语义(是否该点击完成)由 TutorialStepDef.click_to_complete 归口, 此处与 show_step 共用同一来源。
func _on_hole_clicked_internal() -> void:
	var step := _active_step
	if step and not step.is_completed and _click_to_complete:
		step.complete()


## 提前结束/跳过教程(取消聚焦 + 停用任务 + 恢复暂停; 不触发 completed, 供"跳过教程"按钮调用)
func stop() -> void:
	if _task:
		_task.deactivate()
		_task = null
	if _paused_tree:
		_paused_tree.paused = false
		_paused_tree = null
	blur()
	stopped.emit()


## 当前挖孔矩形(供外部参考)
func get_hole_rect() -> Rect2:
	return _hole


## 是否处于"聚焦并阻挡目标外输入"状态(供外部判断快捷键/操作是否应禁用)。
## 纯提示(无目标, _block=false)或已 blur(_active=false) 时返回 false, 不阻挡任何输入。
func is_blocking() -> bool:
	return _active and _block


## 设置提示文字(空 = 隐藏气泡)
func set_tip(text: String) -> void:
	if _tip_panel == null:
		return
	_tip_text_label.text = text
	_tip_panel.reset_size()
	_tip_layout_key = []  # 文本变了, 气泡排版缓存失效
	_tip_panel.visible = not text.is_empty()


## 设置纯提示气泡的顶部上限 Y(屏幕坐标)。
## 纯提示(无目标)气泡默认贴屏幕底部铺满显示; 传入有效上限后, 气泡顶部不会高于该 Y,
## 用于"提示框不遮住商店最下方物品的购买按钮"。传 -1 取消限制。
func set_tip_top_limit(max_y: float) -> void:
	_tip_top_limit = max_y


# ------------------------------------------------------------
# 构建
# ------------------------------------------------------------

func _build_widgets() -> void:
	if _tip_panel:
		return
	for r: Control in [_dim_top, _dim_bottom, _dim_left, _dim_right]:
		r.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(r)
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP
	_sensor.visible = false
	_sensor.gui_input.connect(_on_sensor_input)
	add_child(_sensor)
	_tip_panel = Panel.new()
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.visible = false
	_tip_text_label = RichTextLabel.new()
	_tip_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_text_label.bbcode_enabled = true
	_tip_text_label.fit_content = false  # Panel 手动布局: 由 _place_tip 控制尺寸
	_tip_text_label.scroll_active = false
	_tip_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_text_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER  # 文字在气泡内垂直居中
	_tip_panel.add_child(_tip_text_label)
	add_child(_tip_panel)


# ------------------------------------------------------------
# 主题
# ------------------------------------------------------------

func _apply_theme() -> void:
	_dim_color = _read_color("dim_color", _DEFAULT_DIM)
	_arrow_color = _read_color("arrow_color", _DEFAULT_ARROW)
	_arrow_size = float(_read_const("arrow_size", 28))
	_frame_style = get_theme_stylebox("frame_stylebox", "TutorialOverlay") \
			if has_theme_stylebox("frame_stylebox", "TutorialOverlay") else null
	if _tip_panel:
		var tip_box := get_theme_stylebox("tip_stylebox", "TutorialOverlay") \
				if has_theme_stylebox("tip_stylebox", "TutorialOverlay") else null
		if tip_box:
			_tip_panel.add_theme_stylebox_override("panel", tip_box)
		var tc := get_theme_color("tip_font_color", "TutorialOverlay") \
				if has_theme_color("tip_font_color", "TutorialOverlay") else _DEFAULT_TIP_TEXT
		_tip_text_label.add_theme_color_override("default_color", tc)
		var fsz := get_theme_font_size("tip_font_size", "TutorialOverlay") \
				if has_theme_font_size("tip_font_size", "TutorialOverlay") else 48
		_tip_text_label.add_theme_font_size_override("normal_font_size", fsz)


func _read_color(name: String, fallback: Color) -> Color:
	return get_theme_color(name, "TutorialOverlay") if has_theme_color(name, "TutorialOverlay") else fallback


func _read_const(name: String, fallback: int) -> int:
	return get_theme_constant(name, "TutorialOverlay") if has_theme_constant(name, "TutorialOverlay") else fallback


# ------------------------------------------------------------
# 几何更新(每帧, 目标移动/镜头转动持续校正)
# ------------------------------------------------------------

## 节点级输入拦截：在事件进入 GUI(_gui_input) 与物理拾取(Area3D 的 input_event / mouse_entered) 之前运行。
## 分两类:
##   - 纯提示(无目标): 不锁、无遮罩, 点任意处即继续(hole_clicked)。
##   - 强制锁定(有目标): 把落在挖孔之外的指针事件(点击+移动)标记为已处理,
##     既阻止目标外的 2D/3D 点击, 也阻止鼠标移过框外 3D 物体触发 mouse_entered 高亮。
func _input(event: InputEvent) -> void:
	if not _active:
		return
	# 拖拽手势放行: 3D 拖拽(如出售卡牌)由 _unhandled_input 驱动, 需要把物品拖出聚焦框外,
	# 此时若按孔外拦截会把事件标记为已处理, 打断拖拽。进入拖拽状态后放行全部指针事件。
	if _is_dragging_3d():
		return
	if _allow_fullscreen_click():
		# 纯提示: 点击任意处 / 按下继续键即完成(无遮罩、不锁, 由本层直接触发, 不依赖 GUI sensor)
		if _is_primary_press(event) or _is_advance_pressed(event):
			hole_clicked.emit()
			get_viewport().set_input_as_handled()
		return
	if not _block:
		return
	var pos := _pointer_position(event)
	if pos == Vector2.INF:
		return  # 非指针事件(键盘/手柄)不处理
	if _hole.size == Vector2.ZERO:
		# 空孔: 目标不存在/失效时拦全部指针交互(纯"无目标全屏阻断");
		# 目标为有效节点但暂不可见(如战斗结算面板弹出、商店未开)时放行输入,
		# 让玩家能点结算"继续"返回商店(否则点继续被拦截导致卡死)。
		if _block_when_hole_empty():
			get_viewport().set_input_as_handled()
		return
	if not _hole.has_point(pos):
		# 孔外: 拦点击与 hover。但"按下"命中可拖拽 3D 目标(如手牌卡牌拖拽出售)时
		# 需放行, 否则 3D 拾取收不到按下、拖拽无法开始(_is_dragging_3d 此时仍为 false)。
		# 命中结果在 _physics_process 中更新(仅那时 direct_space_state 可安全访问), 供此处读取缓存;
		# 配置了 allow_outside_drag 的拖拽类步骤也放行孔外按下(目标可能超出挖孔, 需放行按下才能起拖)。
		if _is_primary_press(event):
			if _hover_hits_draggable or allow_hand_drag:
				return
		get_viewport().set_input_as_handled()


## 当前是否有拖拽正在进行(拖拽需要把物品拖出聚焦框, 放行全部指针事件以免打断)。
## 判定来自 drag_checker —— 框架不认识"该项目的拖拽视图类", 由调用方注入。
func _is_dragging_3d() -> bool:
	return drag_checker.is_valid() and drag_checker.call()


## 在物理阶段更新"鼠标位置是否命中可拖拽目标"缓存(仅拖拽放行开启时才检测, 避免每帧射线开销)。
## 注意: 物理射线查询只能在 _physics_process(物理通知)内安全访问 direct_space_state,
## _input 阶段访问会报 "Space state is inaccessible"。故把检测放到物理帧更新,
## _input 按下时读取缓存来判断是否放行拖拽, 避免吞掉拖拽按下导致"拖不动"。
func _physics_process(_delta: float) -> void:
	if not _active or not _block:
		return
	if not allow_hand_drag:
		_hover_hits_draggable = false
		return
	_hover_hits_draggable = _query_hover_draggable()


## 射线检测当前鼠标位置是否命中可拖拽目标。须在物理帧调用。
func _query_hover_draggable() -> bool:
	var viewport := get_viewport()
	var cam := viewport.get_camera_3d()
	var world := viewport.get_world_3d()
	if cam == null or world == null:
		return false
	var mouse := viewport.get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	query.collide_with_areas = true  # 可拖拽目标多为 Area3D, 需显式开启
	var space_state := world.direct_space_state
	if space_state == null:
		return false
	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return false
	return _is_draggable_node(result.get("collider"))


## 命中节点是否"可拖拽"(鸭子类型: 框架不认识具体拖拽视图类)。
## 命中节点或其祖先带 is_dragging 属性 —— 拖拽视图的通行约定, 与是否正在拖拽无关。
static func _is_draggable_node(collider) -> bool:
	while collider:
		if "is_dragging" in collider:
			return true
		collider = collider.get_parent()
	return false


## 是否为主键按下事件(左键/触摸按下)。
func _is_primary_press(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		return b.pressed and b.button_index == MOUSE_BUTTON_LEFT
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	return false


## 是否按下"继续"动作(键盘/手柄; 仅纯提示步骤使用)
func _is_advance_pressed(event: InputEvent) -> bool:
	return advance_action != &"" and event.is_action_pressed(advance_action)


## 目标为可聚焦 Control 时接管焦点 —— 键盘/手柄导航与激活交给 Godot 焦点系统, 不自建
func _focus_target_control() -> void:
	if _target is Control:
		var c := _target as Control
		if c.get_focus_mode() != Control.FOCUS_NONE and not c.has_focus():
			c.grab_focus()


## 提取指针类事件的屏幕坐标；非指针事件返回 INF 表示不参与拦截。
func _pointer_position(event: InputEvent) -> Vector2:
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).position
	if event is InputEventMouseMotion:
		return (event as InputEventMouseMotion).position
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).position
	if event is InputEventScreenDrag:
		return (event as InputEventScreenDrag).position
	return Vector2.INF


## 判断该步骤是否放行全屏点击(仅用于"无目标"的纯提示步骤点击完成兜底)。
## 存在目标(_target 有效)时一律视为"有目标区域"，绝不放行全屏 —— 目标外必须拦截。
func _allow_fullscreen_click() -> bool:
	return _click_to_complete and (_target == null or not is_instance_valid(_target))


## 挖孔为空(_hole.size==ZERO)时是否仍需拦截全部指针交互 / 绘制全屏暗区。
## 仅当目标不存在或已失效(纯"无目标全屏阻断"步骤)时返回 true;
## 目标为有效节点但当前不可见(如战斗结算面板弹出、商店未开, 挖孔为空)时返回 false,
## 使引导让出输入, 玩家能点结算面板"继续"按钮返回商店, 而非拦截所有点击导致卡死。
func _block_when_hole_empty() -> bool:
	return _target == null or not is_instance_valid(_target)


func _process(delta: float) -> void:
	if not _active:
		return
	_try_refresh_target()            # 目标失效时按 node_path 重新解析
	_time += delta
	_update_geometry()               # 计算精确 _target_rect
	var changed := _advance_hole(delta)  # _hole 平滑逼近(消除跳变)
	_apply_rects()
	var v := get_viewport_rect().size
	_update_arrow(v)
	_place_tip(v)
	# 有箭头动画、挖孔平滑更新或有内容变化才重绘
	if (_arrow and _hole.size != Vector2.ZERO) or changed or _last_hole != _hole:
		_last_hole = _hole
		queue_redraw()


## 目标节点失效(被移除/替换)时按 node_path 自动重新解析, 避免"购买后货架卡更替"等场景挖孔永久退化为纯提示。
## 仅当当前目标无效且存在 target_def 时才尝试; 仍解析不到则保持纯提示/放行(交给 _block_when_hole_empty 兜底)。
func _try_refresh_target() -> void:
	if _target != null and is_instance_valid(_target):
		return
	if _target_def == null:
		return
	var resolved := _target_def.resolve(_host)
	if resolved != null and is_instance_valid(resolved):
		_target = resolved
		_update_geometry()
		_focus_target_control()
		queue_redraw()


## 计算每帧精确目标矩形(相对 viewport 裁剪)。拦截用 _hole, 这里只更新计算值。
func _update_geometry() -> void:
	var v := get_viewport_rect().size
	var rect := Rect2()
	if _target_def and _target != null and is_instance_valid(_target) and _target.is_inside_tree():
		rect = TutorialTargetDef.get_screen_rect(_target, _target_def)
	rect = rect.intersection(Rect2(Vector2.ZERO, v))
	_target_rect = rect


## 挖孔"死区跟随": 仅当实际显示的 mesh(目标精确矩形, 已含 padding)超出当前聚焦框
## (外扩 padding 的死区)时才把挖孔吸附到目标; 目标仍被死区包容时挖孔固定不动,
## 避免镜头轻微转动 / 目标微移导致挖孔持续跳变。
## 死区大小 = TutorialTargetDef.padding: padding 越大, 目标允许移动/变化的范围越大,
## 聚焦框更新越不频繁; padding 越小则越灵敏。
func _advance_hole(_delta: float) -> bool:
	if _target_rect.size == Vector2.ZERO or _hole.size == Vector2.ZERO:
		var changed := _hole != _target_rect
		_hole = _target_rect
		return changed
	# 死区: 由挖洞外扩 padding 决定(至少 1px, 避免零死区导致每帧抖动)
	var deadzone := maxf(_target_def.padding if _target_def else 0.0, 1.0)
	var hold := _hole.grow(deadzone)
	if hold.encloses(_target_rect):
		return false
	# 目标移出死区 → 重新吸附到目标位置
	_hole = _target_rect
	return true


func _apply_rects() -> void:
	var v := get_viewport_rect().size
	# 布局未变化则跳过: 每帧重设子控件 size/position 会反复触发 Control 重排
	var key := [_active, _block, _click_to_complete, _hole, v, _target]
	if key == _rects_key:
		return
	_rects_key = key
	if not _active:
		# 未聚焦(完成/未开始): 拦截板全部失效(不拦截任何输入)
		for r: Control in [_dim_top, _dim_bottom, _dim_left, _dim_right]:
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.size = Vector2.ZERO
		_sensor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_sensor.visible = false
		return
	# 拦截策略: 阻断时暗区 STOP(拦截暗区点击, 孔内穿透); 不阻断时暗区 IGNORE(仅视觉不拦输入)
	var dim_filter := Control.MOUSE_FILTER_STOP if _block else Control.MOUSE_FILTER_IGNORE
	_sensor.mouse_filter = Control.MOUSE_FILTER_STOP if _block and _click_to_complete else Control.MOUSE_FILTER_IGNORE
	_sensor.visible = _block and _click_to_complete
	if _hole.size == Vector2.ZERO:
		# 不挖孔: 单块全屏板(阻断时拦截全屏, 不阻断时仅视觉由 _draw 画暗区)
		# 目标为有效节点但暂不可见(如战斗结算面板弹出、商店未开)时拦截板不拦截输入(IGNORE),
		# 让玩家能点结算"继续"返回商店; 仅"无目标全屏阻断"步骤才拦全屏(与 _block_when_hole_empty 一致)。
		_dim_top.position = Vector2.ZERO
		_dim_top.size = v
		_dim_top.mouse_filter = Control.MOUSE_FILTER_STOP \
				if (_block and _block_when_hole_empty()) else Control.MOUSE_FILTER_IGNORE
		for r: Control in [_dim_bottom, _dim_left, _dim_right]:
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.size = Vector2.ZERO
		# 仅"无目标"的纯提示步骤可全屏点击兜底(与 _allow_fullscreen_click 一致);
		# 有目标时孔空(目标尚不可见), 感应区不覆盖, 防止绕过目标外拦截完成
		_sensor.position = Vector2.ZERO
		_sensor.size = v if _block and _allow_fullscreen_click() else Vector2.ZERO
		return
	# 4 矩形拼洞: 拦截板与孔贴合(暗区拦截, 孔内穿透到目标按钮/3D 拾取)
	_dim_top.position = Vector2.ZERO
	_dim_top.size = Vector2(v.x, _hole.position.y)
	_dim_top.mouse_filter = dim_filter
	_dim_bottom.position = Vector2(0.0, _hole.end.y)
	_dim_bottom.size = Vector2(v.x, v.y - _hole.end.y)
	_dim_bottom.mouse_filter = dim_filter
	_dim_left.position = Vector2(0.0, _hole.position.y)
	_dim_left.size = Vector2(_hole.position.x, _hole.size.y)
	_dim_left.mouse_filter = dim_filter
	_dim_right.position = Vector2(_hole.end.x, _hole.position.y)
	_dim_right.size = Vector2(v.x - _hole.end.x, _hole.size.y)
	_dim_right.mouse_filter = dim_filter
	# 点击兜底感应区: 仅 click_to_complete 时启用(拦截孔内点击; 否则禁用让事件穿透)
	_sensor.position = _hole.position
	_sensor.size = _hole.size


## 感应区输入: 点击/触摸孔内区域时发射 hole_clicked(click_to_complete 步骤的完成兜底)
func _on_sensor_input(event: InputEvent) -> void:
	var mouse_pressed: bool = event is InputEventMouseButton \
			and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	var touch_pressed: bool = event is InputEventScreenTouch and event.pressed
	if mouse_pressed or touch_pressed:
		_sensor.accept_event()
		hole_clicked.emit()


## 箭头: 默认置于挖孔上方(尖端朝下指向目标); 顶部空间放不下才翻到下方兜底。
## 气泡随箭头同侧(默认上方), 不随目标左右偏移/浮动
func _update_arrow(v: Vector2) -> void:
	if _hole.size == Vector2.ZERO or not _arrow:
		_arrow_dir = Vector2.RIGHT
		_arrow_anchor = Vector2.ZERO
		return
	var gap := _arrow_size * 0.25 + 8.0  # 尖端到孔边的间隙
	var center := _hole.get_center()
	if _hole.position.y >= gap + 8.0:
		_arrow_dir = Vector2.DOWN  # 默认上方
		_arrow_anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.position.y - gap)
	else:
		_arrow_dir = Vector2.UP  # 顶部放不下才翻到下方
		_arrow_anchor = Vector2(clampf(center.x, 48.0, v.x - 48.0), _hole.end.y + gap)


## 提示气泡置于箭头尾端外侧(与箭头同侧, 默认上方), 固定不动不跟随浮动, 避免晃动影响阅读;
## 无箭头时: 有挖孔则置于孔下方; 纯提示(无孔)则横向布满屏幕、贴屏幕底部显示,
## 且顶部不高于 _tip_top_limit(供"不遮住商店最下方物品购买按钮")。
func _place_tip(v: Vector2) -> void:
	if _tip_panel == null:
		return
	# 挖孔步骤(target 有效): 挖孔为空(_hole.size==ZERO)且目标当前不可见(如战斗期间商店未打开)时隐藏气泡,
	# 待目标可见后(_hole 非空)再显示, 避免"战斗结束"等提示在战斗期间提前弹出。
	# 仅当 _hole 为空且目标确实不可见才隐藏, 避免挖孔步骤初始帧(_hole 尚未逼近)误隐藏气泡。
	if _target != null and is_instance_valid(_target):
		if _hole.size == Vector2.ZERO and not _target.is_visible_in_tree():
			if _tip_panel.visible:
				_tip_panel.visible = false
			return
		elif not _tip_panel.visible and not _tip_text_label.text.is_empty():
			_tip_panel.visible = true
	if not _tip_panel.visible:
		return
	# 排版未变化则跳过: get_content_height() 会强制 RichTextLabel 重新排版, 每帧调用开销明显
	var layout_key := [_tip_panel.visible, _tip_text_label.text, v, _hole, _arrow_anchor,
			_tip_top_limit, _arrow]
	if layout_key == _tip_layout_key:
		return
	_tip_layout_key = layout_key
	var margin := 12.0
	# 纯提示(无孔无箭头): 气泡横向布满屏幕; 有孔/箭头: 保持内容宽度(跟随箭头/孔)
	var pure_tip := _arrow_anchor == Vector2.ZERO and _hole.size == Vector2.ZERO
	var tip_width := v.x - 2.0 * margin if pure_tip else 620.0
	# 面板内边距(来自 panel stylebox)
	var box := _tip_panel.get_theme_stylebox("panel")
	var pl := box.get_margin(SIDE_LEFT) if box else 0.0
	var pr := box.get_margin(SIDE_RIGHT) if box else 0.0
	var pt := box.get_margin(SIDE_TOP) if box else 0.0
	var pb := box.get_margin(SIDE_BOTTOM) if box else 0.0
	# 先给 label 设定可用宽度 → 让文本按该宽度换行并计算内容高度
	var label_w := maxf(tip_width - pl - pr, 1.0)
	_tip_text_label.size = Vector2(label_w, 0)
	var content_h := _tip_text_label.get_content_height()
	# 面板尺寸: 宽度铺满但不超屏, 高度 = 内容 + 上下内边距(纯提示不低于 _tip_min_height)
	var panel_w := minf(tip_width, v.x - 2.0 * margin)
	var panel_h := content_h + pt + pb
	if pure_tip:
		panel_h = maxf(panel_h, _tip_min_height)
	var panel_size := Vector2(panel_w, panel_h)
	# 手动布局 label 填满面板内部, 文字垂直居中(避免 Container 自动撑宽超出屏幕)
	_tip_text_label.position = Vector2(pl, pt)
	_tip_text_label.size = Vector2(maxf(panel_w - pl - pr, 1.0), maxf(panel_h - pt - pb, 1.0))
	# 计算位置
	var pos := Vector2.ZERO
	if _arrow_anchor == Vector2.ZERO:
		if _hole.size != Vector2.ZERO:
			pos = Vector2(_hole.get_center().x - panel_size.x * 0.5, _hole.end.y + margin)
		else:
			# 纯提示(无孔): 横向布满屏幕, 贴屏幕底部显示; 顶部不高于 _tip_top_limit(若设置)
			pos = Vector2(margin, v.y - _tip_bottom_margin - panel_size.y)
			if _tip_top_limit >= 0.0:
				pos.y = maxf(pos.y, _tip_top_limit)
	else:
		var tail := _arrow_anchor - _arrow_dir * (_arrow_size + 10.0)
		pos = Vector2(tail.x - panel_size.x * 0.5, tail.y)
		if _arrow_dir == Vector2.DOWN:
			pos.y -= panel_size.y  # 默认上方: 气泡在箭头尾端之上
	pos.x = clampf(pos.x, margin, maxf(margin, v.x - panel_size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, v.y - panel_size.y - margin))
	# 应用实际尺寸与位置
	_tip_panel.custom_minimum_size = panel_size
	_tip_panel.size = panel_size
	_tip_panel.position = pos


# ------------------------------------------------------------
# 绘制: 层级 = 暗区 → 边框 → 箭头(同一 CanvasItem 内先画后叠, 箭头恒在顶层)
# ------------------------------------------------------------

func _draw() -> void:
	if not _active:
		return  # 未聚焦(完成/未开始)不绘制任何内容
	_draw_dim()
	if _hole.size == Vector2.ZERO:
		return
	if _frame_style:
		draw_style_box(_frame_style, _hole)
	else:
		draw_rect(_hole, _DEFAULT_ARROW, false, 2.0)
	_draw_arrow()


## 暗区: 与拦截板矩形一致(4 矩形拼洞), 直接绘制在本控件(不再被子节点遮盖)
## 仅强制锁定(_block)时画暗区; 纯提示(无目标、不锁)不画黑遮罩, 只留气泡。
## 挖孔目标当前不可见(_hole 为空, 如战斗期间商店未开)时不画暗区, 让屏幕恢复正常,
## 待回到商店目标可见后再画暗区(挖孔)。仅"无目标的全屏阻断"步骤画全屏暗区。
func _draw_dim() -> void:
	if not _block:
		return
	var v := get_viewport_rect().size
	if _hole.size == Vector2.ZERO:
		if _target == null or not is_instance_valid(_target):
			draw_rect(Rect2(Vector2.ZERO, v), _dim_color)
		return
	draw_rect(Rect2(0.0, 0.0, v.x, _hole.position.y), _dim_color)
	draw_rect(Rect2(0.0, _hole.end.y, v.x, v.y - _hole.end.y), _dim_color)
	draw_rect(Rect2(0.0, _hole.position.y, _hole.position.x, _hole.size.y), _dim_color)
	draw_rect(Rect2(_hole.end.x, _hole.position.y, v.x - _hole.end.x, _hole.size.y), _dim_color)


## 箭头: 像素尺寸恒定, 整体沿指向方向往复平移(bob 整体偏移, 长度恒为 arrow_size 不拉伸)
func _draw_arrow() -> void:
	if _arrow_anchor == Vector2.ZERO:
		return
	var bob := sin(_time * 6.0) * 4.0
	var tip := _arrow_anchor + _arrow_dir * bob
	var tail := tip - _arrow_dir * _arrow_size
	var normal := Vector2(-_arrow_dir.y, _arrow_dir.x)
	var half_w := _arrow_size * 0.25
	draw_colored_polygon([
		tip,
		tail + normal * half_w,
		tail - normal * half_w,
	], _arrow_color)
