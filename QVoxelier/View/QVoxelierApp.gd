@tool
class_name QVoxelierApp
extends Node3D
## 建模视口的应用壳：**装配 + 输入翻译 + 快捷键**，不含任何算法（DESIGN §4.1 的 View 层）。
##
## 【它只做三件事】
##   ① 装配：新建世界/对象 → 建会话 → 把显示层交给渲染器、把网格交给地板、把会话交给状态栏；
##   ② 翻译：鼠标事件 → 相机射线 → 网格拾取 → `QVoxelEditSession` 的手势（begin/drag/release）；
##   ③ 快捷键：工具表里的热键切笔、[ ] 改笔刷、Ctrl+Z / Ctrl+Shift+Z 撤销重做、Esc 取消、Home 取景；
##      工程文件 Ctrl+S / Ctrl+Shift+S / Ctrl+O（`.qvx` 也能直接拖进窗口）。
##
## 【快捷键是加速器，不是入口】本应用要同时跑在平板（无键盘 / 无中键 / 无滚轮 / 无右键）与桌面，
## 于是每个动作都先在界面上有一个按钮，键盘只让熟练用户少点两下 —— 按钮与快捷键改的是**同一份状态**
## （工具 / 笔刷 / 材质 / 导航模式），不存在"只有键盘才够得着"的功能。
## 触摸屏上必须由界面补位的三处：中键转视角 →「导航 / 平移」开关，滚轮缩放 →「− / +」，右键擦除 →「擦除」开关。
## 本类因此也是这些状态的**唯一持有者**（`_install` / `_set_*` 都往界面上回写），界面自己不留副本。
##
## 【为什么"翻译"值得单独一层】会话刻意不认识鼠标：它要的是"这一次落笔打在哪"（Pick）。
## 视口是唯一知道屏幕坐标、相机与渲染节点的地方 —— 于是换算只在这里发生一次，
## 会话与工具因此都能无头测试（换成 Dock 内嵌视口时，本类只换相机与渲染节点两行）。
##
## 【坐标换算】渲染器的局部空间是"体素单位 × voxel_scale"（网格顶点按 voxel_scale 放大），
## 故世界射线先 to_local、再除一次 voxel_scale，才落进 VoxelData 的体素坐标里。
## 这条换算只此一处 —— 拾取、地板、网格尺寸三处用的都是同一套单位。

## 新建模型的网格尺寸（MagicaVoxel 的默认有界网格就是 32³）。
@export var grid_size := Vector3i(32, 32, 32)

## 新建模型时预置的调色板（ID 从 1 开始；0 是空气）。
## 不给颜色就没法验证"画上去的是什么颜色"，所以新建即带一套可用色板。
@export var default_palette: Array[Color] = [
	Color(0.87, 0.27, 0.25), Color(0.95, 0.64, 0.19), Color(0.94, 0.89, 0.35),
	Color(0.36, 0.78, 0.40), Color(0.26, 0.64, 0.94), Color(0.61, 0.42, 0.90),
	Color(0.90, 0.90, 0.90), Color(0.34, 0.35, 0.38),
]

## 笔刷上限（体素笔/盒笔/线笔的加粗半径）。
@export var max_brush_size := 16

@onready var model: VoxelRenderer = $Model
@onready var camera: QVoxelViewCamera = $Camera
@onready var grid_floor: QVoxelGridFloor = $Model/Floor
@onready var hud: QVoxelierHud = $Hud

## 应用栏 / 工具坞 / 调色板：**在代码里建**而不是摆进 .tscn —— 它们的内容完全由运行时数据决定
## （工具表、世界的材质表），在场景里预摆只会得到一份立刻被推翻的空壳；
## 状态栏（Hud）留在场景里，因为它是静态骨架、且视口脚本要按路径引用它。
var _toolbar: QVoxelierToolbar
var _tools: QVoxelierTools
var _palette: QVoxelierPalette
var _view_bar: QVoxelierViewBar
var _gizmo: QVoxelierGizmo
var _dock: QVoxelierDock
var _color_section: QVoxelierColorSection
var _tree_section: QVoxelierTreeSection
var _inspector_section: QVoxelierInspectorSection
var _confirm: ConfirmationDialog

## 参数面板当前绑定的修改器（选中树上某条修改器时置入，用于撤销 / 重做后重绑）。
var _modifier: QVoxelModifier
## 该修改器的宿主节点（改参数的命令要挂在它的 content_changed 上标脏）。
var _modifier_owner: QVoxelNode

## 非活动对象的渲染节点容器：多对象世界里只有"当前对象"用 model，其余挂在这里。
## （见 _rebuild_view —— 切换活动对象只换 model.data，其余渲染器复用。）
var _extra_root: Node3D
## 每个对象一条展示会话：model_id → QVoxelEditSession。**活动那条就是 session**。
## 非活动会话不接鼠标，只负责把它那份 VoxelData 喂给对应渲染器。
var _sessions: Dictionary = {}
## 非活动对象的渲染器：model_id → VoxelRenderer。
var _display: Dictionary = {}

## 当前世界与编辑会话（装配产物；换模型时整体重建）。
var world: QVoxelWorld
var session: QVoxelEditSession

## 当前工程文件路径（空 = 还没存过盘的新工程，"保存"会转成"另存为"）。
var project_path := ""

var _material_id := 1
var _stroke := false
var _erase := false
## 对称轴掩码。是**App 级设置**而非笔刷级：每个对象各有自己的笔刷实例，
## 若把它存在笔刷里，切一次对象就会被新笔刷的默认值抹掉（见 _apply_symmetry）。
var _symmetry := Vector3i.ZERO
var _orbit := false
var _pan := false
## 导航 / 平移模式：拖动改的是视角而不是体素。桌面上的中键与 Shift+中键，在触摸屏上
## 没有对应物，故提升为常驻开关 —— 它与 `_orbit` / `_pan` 这类"某一帧正在发生的拖动"不同，
## 是**跨手势的粘性模式**，所以排在状态区而不是手势区。
var _nav := false
var _pan_mode := false
## 有未落盘的改动（状态栏与窗口标题上的 *）。
var _dirty := false

## 取色器：开启后下一次左键点击改为"吸取该处体素的材质"，而不落笔。
var _eyedropper := false
## 正在进行的改色手势对应的属性命令（松手时封口入栈；见 QVoxelierColorSection 的"手势即命令"）。
var _color_cmd: QVoxelPropertyCommand
## 正在进行的"改修改器参数"手势对应的属性命令（同上，只是目标换成链上的某条条目）。
var _prop_cmd: QVoxelPropertyCommand

var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _palette_import_dialog: FileDialog
var _palette_export_dialog: FileDialog

const ACTION_UNDO := &"qvoxelier_undo"
const ACTION_REDO := &"qvoxelier_redo"
const ACTION_BRUSH_UP := &"qvoxelier_brush_up"
const ACTION_BRUSH_DOWN := &"qvoxelier_brush_down"
const ACTION_SAVE := &"qvoxelier_save"
const ACTION_SAVE_AS := &"qvoxelier_save_as"
const ACTION_OPEN := &"qvoxelier_open"


# ----------------------------------------------------------------------------
# 装配
# ----------------------------------------------------------------------------

func _ready() -> void:
	_bind_actions()
	_build_dialogs()
	_build_ui()
	new_model()
	# 编辑器里只装配外观（网格地板与取景），输入留给编辑器自己 —— @tool 脚本不该抢编辑器的键。
	if Engine.is_editor_hint():
		return
	get_window().files_dropped.connect(_on_files_dropped)


## 装配三个界面面板并接线。面板只发"用户想干什么"的信号，**不收会话**：
## 于是界面层永远不碰编辑逻辑，换视口（独立窗口 → Dock 内嵌）时面板一行都不用改。
## （状态栏是例外：它要读会话才能显示工具与撤销栈，所以在 _install 里注入 session。）
func _build_ui() -> void:
	_toolbar = QVoxelierToolbar.new()
	_toolbar.name = "Toolbar"
	add_child(_toolbar)
	_toolbar.new_requested.connect(request_new)
	_toolbar.open_requested.connect(request_open)
	_toolbar.save_requested.connect(save_project)
	_toolbar.save_as_requested.connect(save_project_as)
	_toolbar.undo_requested.connect(_undo)
	_toolbar.redo_requested.connect(_redo)
	_toolbar.frame_requested.connect(func(): frame_view(); hud.flash("已取景"))
	_toolbar.zoom_requested.connect(func(steps: float): camera.zoom_by_steps(steps))
	_toolbar.view_mode_changed.connect(_set_view_mode)
	_toolbar.help_toggled.connect(hud.set_legend_visible)

	_tools = QVoxelierTools.new()
	_tools.name = "Tools"
	add_child(_tools)
	_tools.tool_selected.connect(_set_tool)
	_tools.brush_step.connect(_step_brush)
	_tools.brush_scale_requested.connect(_scale_brush)
	_tools.erase_toggled.connect(func(on: bool): hud.flash("擦除模式：%s" % ("开" if on else "关")))
	_tools.symmetry_toggled.connect(_set_symmetry_axis)

	_palette = QVoxelierPalette.new()
	_palette.name = "Palette"
	add_child(_palette)
	_palette.material_selected.connect(_set_material)

	_view_bar = QVoxelierViewBar.new()
	_view_bar.name = "ViewBar"
	add_child(_view_bar)
	_view_bar.lens_selected.connect(_set_lens)
	_view_bar.view_selected.connect(_apply_view)
	_view_bar.grid_lines_toggled.connect(_set_grid_lines)

	# 朝向指示器要读相机基，故注入相机实例（它不持有相机，只是借来看一眼 —— see 类文档）。
	_gizmo = QVoxelierGizmo.new()
	_gizmo.name = "Gizmo"
	add_child(_gizmo)
	_gizmo.camera = camera
	_gizmo.view_requested.connect(_apply_view)

	# 右侧抽屉：颜色 / 对象 / 图层三组。分组各自只发"用户想干什么"，写世界与记撤销都在本类一处完成。
	_dock = QVoxelierDock.new()
	_dock.name = "Dock"
	add_child(_dock)

	_color_section = QVoxelierColorSection.new()
	_color_section.edit_began.connect(_begin_color_edit)
	_color_section.color_changed.connect(_live_color)
	_color_section.edit_ended.connect(_end_color_edit)
	_color_section.eyedropper_toggled.connect(_set_eyedropper)
	_color_section.add_material_requested.connect(_add_material)
	_color_section.import_requested.connect(func(): _palette_import_dialog.popup_centered_ratio(0.7))
	_color_section.export_requested.connect(func(): _palette_export_dialog.popup_centered_ratio(0.7))
	_dock.add_section(_color_section)

	_tree_section = QVoxelierTreeSection.new()
	_tree_section.node_selected.connect(_on_tree_selected)
	_tree_section.model_add_requested.connect(_add_model)
	_tree_section.group_add_requested.connect(_add_group)
	_tree_section.node_remove_requested.connect(_remove_node)
	_tree_section.node_visible_changed.connect(_set_node_visible)
	_tree_section.node_locked_changed.connect(_set_node_locked)
	_tree_section.node_rename_requested.connect(_rename_node)
	_tree_section.node_move_requested.connect(_move_node)
	_tree_section.modifier_add_requested.connect(_add_modifier)
	_tree_section.modifier_remove_requested.connect(_remove_modifier)
	_tree_section.modifier_enabled_changed.connect(_set_modifier_enabled)
	_tree_section.modifier_selected.connect(_on_modifier_selected)
	_dock.add_section(_tree_section)

	# 参数分组：链上选中哪条修改器，就反射生成它的参数控件（含"变换"的参数，故不再需要独立变换面板）。
	_inspector_section = QVoxelierInspectorSection.new()
	_inspector_section.edit_began.connect(_begin_prop_edit)
	_inspector_section.value_changed.connect(_live_prop)
	_inspector_section.edit_ended.connect(_end_prop_edit)
	_dock.add_section(_inspector_section)


## 新建一个空模型（grid 为 ZERO 时用导出的 grid_size）：建世界 → 建对象 → 装配。
func new_model(grid := Vector3i.ZERO) -> void:
	var g: Vector3i = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else grid_size
	var w := QVoxelWorld.create_empty()
	for c in default_palette:
		w.add_material(c)
	_install(w, w.create_model("Model", g))
	project_path = ""
	_dirty = false
	_update_title()


## 装配：世界 + 待编辑对象 → 会话 / 渲染器 / 地板 / 状态栏。
## **新建与打开共用这一条路径** —— 两套初始化迟早会分叉出"新建能画、打开画不了"这类怪病。
func _install(w: QVoxelWorld, obj: QVoxelModel) -> void:
	world = w
	# 每个对象一条展示会话：活动那条随后由 _activate 选出，其余只喂渲染器
	# （理由见 _sessions 的注释 —— 多对象世界才能"看见全部、只编辑一个"）。
	_sessions.clear()
	for o in w.all_models():
		if o != null:
			_sessions[o.model_id] = QVoxelEditSession.create_for(o, w)
	for s in _sessions.values():
		(s as QVoxelEditSession).request_render_update = model.request_update
		(s as QVoxelEditSession).history.changed.connect(_on_history_changed)
	_material_id = 1
	_stroke = false
	_erase = false
	_eyedropper = false
	_color_cmd = null

	model.voxel_scale = w.voxel_size()
	model.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	grid_floor.voxel_scale = model.voxel_scale
	# 调色板取**世界的材质表**（而不是 default_palette）：打开别人做的 256 色工程时也照显，
	# 否则界面上会是一排与工程无关的颜色。
	_palette.set_palette(_material_colors(w))

	session = null
	_activate(obj.model_id, false)
	hud.session = session
	frame_view()
	_refresh_hud()


## 切换"当前编辑对象"。三条入口共用这一条路径：对象列表点击、新建对象、打开工程挑初始对象。
##
## 【为什么不重建会话】非活动对象也早就有一条展示会话（见 _install），切换只是把 model.data
## 换成新活动对象那份、并把它的渲染器交回给 model。于是撤销栈按对象各自保留 ——
## 切走再切回来，那一个对象的撤销历史还在，不会因为"看了一眼别的对象"就清空。
func _activate(model_id: int, flash := true) -> void:
	if world == null:
		return
	var o := world.find_model(model_id)
	if o == null:
		return
	if session != null and session.object == o:
		return
	if _stroke and session != null:
		session.cancel()
		_stroke = false
	session = _sessions.get(model_id)
	if session == null:
		return
	model.data = session.data
	model.voxel_scale = world.voxel_size()
	# 地面网格框按**输出盒**画：链里一旦有重排（镜像 / 旋转 / 平铺），它就与手绘种子不同尺寸。
	grid_floor.grid_size = session.output_size()
	grid_floor.voxel_scale = model.voxel_scale
	hud.session = session
	_rebuild_view()
	_refresh_hud()
	if flash:
		hud.flash("已切换到 %s" % o.node_name)


## 让"世界的全部对象"都显示出来：活动对象用 model，其余各挂一个渲染器到 _extra_root。
##
## 【幂等 + 复用】本函数在切对象、图层可见性变化、撤销图层命令后都会被调到，所以它必须
## "算出现状"，而不是"推倒重来"：已有且仍该显示的渲染器原地复用（只改 visible），
## 该消失的回收，该新增的才建。若每次都重建，多对象场景每落一笔就重建一遍网格，会闪。
##
## 【为什么活动对象固定用 model】视口脚本按场景路径 $Model 引着它，重指代价大；
## 于是约定"model 永远渲染当前活动对象"，其余对象才走 _extra_root。切换只是换 model.data。
func _rebuild_view() -> void:
	if world == null or session == null:
		return
	if _extra_root == null:
		_extra_root = Node3D.new()
		_extra_root.name = "Objects"
		add_child(_extra_root)

	var active_id: int = session.object.model_id

	# 回收：不再属于世界、或已变成活动对象（该由 model 渲染）的旧渲染器。
	for id in _display.keys():
		var keep: bool = id != active_id and world.find_model(id) != null
		if keep:
			continue
		var old: VoxelRenderer = _display[id]
		if is_instance_valid(old):
			old.queue_free()
		_display.erase(id)

	for id in _sessions:
		var o := world.find_model(id)
		if o == null or id == active_id:
			continue
		var shown := _node_visible(o)
		var r: VoxelRenderer = _display.get(id)
		if r == null or not is_instance_valid(r):
			r = VoxelRenderer.new()
			r.name = "Model_%d" % id
			_extra_root.add_child(r)
			r.voxel_scale = model.voxel_scale
			r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
			r.data = (_sessions[id] as QVoxelEditSession).data
			(_sessions[id] as QVoxelEditSession).request_render_update = r.request_update
			_display[id] = r
		r.visible = shown

	model.visible = _node_visible(session.object)


## 取景：把"有东西可落笔"的范围落进画面（新建 / 打开 / Home 键）。
## 空图时唯一能落笔的是网格底面（`QVoxelGridPick` 的落笔面），所以对准底面 —— 若照搬"框住整块
## 32³ 网格"，默认 25° 视角下屏幕上半尽是空体积，点正中只会换来一句"这儿落不了笔"。
func frame_view() -> void:
	if session == null:
		return
	var g := Vector3(session.output_size()) * model.voxel_scale
	var extent := g if not session.object.is_empty() else Vector3(g.x, 0.0, g.z)
	camera.frame_aabb(model.global_transform * AABB(Vector3.ZERO, extent), true)


# ----------------------------------------------------------------------------
# 输入翻译
# ----------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or session == null:
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func _on_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			# 取色器优先于一切：开启时左键点击用来"吸取"，不该顺带落一笔。
			# 拖拽（含导航 / 平移）时若不放开手会一直吸，故只在**按下那一拍**取一次。
			if _eyedropper and e.pressed:
				_pick_material_at(e.position)
				return
			# 触摸屏没有中键，故「导航 / 平移」模式把左键借给视角：单手即可转 / 移模型。
			# 平板上的单指拖动经过 emulate_mouse_from_touch 就是这里的 LEFT，不需要另写一套触摸分支。
			if _nav or _pan_mode:
				_orbit = e.pressed and _nav
				_pan = e.pressed and _pan_mode
			elif e.pressed:
				_begin_stroke(e.position, _erasing())
			else:
				_end_stroke()
		MOUSE_BUTTON_RIGHT:
			# 导航 / 平移模式下右键不参与擦除 —— 否则"想转个视角却擦掉一片"。
			if _nav or _pan_mode:
				return
			if e.pressed:
				_begin_stroke(e.position, true)
			else:
				_end_stroke()
		MOUSE_BUTTON_MIDDLE:
			# 中键转视角、Shift+中键平移：与左右键（画 / 擦）互不干扰，
			# 于是"边画边转着看"不需要先切模式 —— 建模里这一步每天都在用。
			_orbit = e.pressed and not e.shift_pressed
			_pan = e.pressed and e.shift_pressed
		MOUSE_BUTTON_WHEEL_UP:
			camera.zoom_by_steps(1.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom_by_steps(-1.0)


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	if _stroke:
		session.drag(_pick_at(e.position))
		_refresh_cursor(e.position)
	elif _orbit:
		camera.orbit_by_pixels(e.relative)
		# 转完就不再对齐任何预设了：视图栏要如实回显这一点，否则"前视图"还亮着 ——
		# 用户会以为视角没动。
		_view_bar.set_view(camera.view)
	elif _pan:
		camera.pan_by_pixels(e.relative)
	else:
		_refresh_cursor(e.position)


func _on_key(e: InputEventKey) -> void:
	# 撤销 / 重做 / 存开走框架 InputTool（key_event 管修饰键，动作名可被重映射）。
	# 模式热键直接查工具表 —— 表即配置，不需要修饰键语义，也就没必要再声明一遍动作名。
	if _pressed(e, ACTION_UNDO):
		_undo()
	elif _pressed(e, ACTION_REDO):
		_redo()
	elif _pressed(e, ACTION_SAVE_AS):
		save_project_as()
	elif _pressed(e, ACTION_SAVE):
		save_project()
	elif _pressed(e, ACTION_OPEN):
		request_open()
	elif _pressed(e, ACTION_BRUSH_UP):
		_step_brush(1)
	elif _pressed(e, ACTION_BRUSH_DOWN):
		_step_brush(-1)
	elif e.keycode == KEY_ESCAPE:
		_cancel()
	elif e.keycode == KEY_HOME:
		frame_view()
		hud.flash("已取景")
	elif e.keycode == KEY_E:
		# 擦除开关的热键：平板用户点左侧「擦除」，桌面用户按 E —— 改的是同一份状态。
		_toggle_erase()
	elif e.keycode >= KEY_1 and e.keycode <= KEY_8:
		_set_material(e.keycode - KEY_0)
	elif _numpad_view(e.keycode):
		pass
	else:
		_switch_by_hotkey(e.keycode)


## 动作命中判定：**必须精确比对修饰键**（第 3 个参数 exact_match）。
## `is_action_pressed` 默认只比键码、不比修饰键 —— 于是 Ctrl+Shift+Z 会连"撤销"一起命中、
## Ctrl+Shift+S 会连"保存"一起命中，谁先判谁赢、另一个永远轮不到（"重做"就是这么坏的）。
func _pressed(e: InputEventKey, action: StringName) -> bool:
	return e.is_action_pressed(action, false, true)


## 热键切笔：与点工具坞走同一条 `_set_tool`，于是按钮高亮与提示文案不可能与实况不一致。
func _switch_by_hotkey(key: Key) -> void:
	for row in QVoxelBrushTool.MODES:
		if row.hotkey == key:
			_set_tool(row.mode)
			return


## 把屏幕坐标解成"这一次落笔打在哪"：相机射线 → 体素空间 → 网格拾取（含空图落在地板上）。
func _pick_at(screen: Vector2) -> QVoxelBrushTool.Pick:
	var scale := model.voxel_scale
	var origin: Vector3 = model.to_local(camera.project_ray_origin(screen)) / scale
	var dir: Vector3 = model.global_transform.basis.inverse() * camera.project_ray_normal(screen)
	var info := QVoxelGridPick.hit(session.data, origin, dir, session.output_size())
	return session.pick_from_hit(info, _erasing(), _material_id)


## 这一笔是擦还是画。两个来源取或：右键按下时的**一次性** `_erase`，与左侧「擦除」开关的
## **粘性**模式（平板上没有右键，全靠它）。取或而不是二选一，是为了让"开着擦除模式时按右键"
## 仍然擦 —— 用户不会因为多按了一个键反而改回画。
func _erasing() -> bool:
	return _erase or (_tools != null and _tools.erase_mode())


# ----------------------------------------------------------------------------
# 手势
# ----------------------------------------------------------------------------

func _begin_stroke(screen: Vector2, erase: bool) -> void:
	if _node_locked(session.object):
		hud.flash("这一层已锁定：先在右侧「图层」里解锁")
		return
	_erase = erase
	if not session.begin(_pick_at(screen)):
		hud.flash("这儿落不了笔：把光标放到网格上，或已经画出来的体素上")
		return
	_stroke = true
	_refresh_cursor(screen)


func _end_stroke() -> void:
	if not _stroke:
		return
	_stroke = false
	if not session.release():
		hud.flash("这一笔没有改动（网格外 / 同色覆盖 / 没东西可擦）")
	_erase = false
	_refresh_hud()


func _cancel() -> void:
	if _stroke:
		session.cancel()
		_stroke = false
		_erase = false
		hud.flash("已取消这一笔")
	elif hud.legend_visible():
		# 说明浮层挡着视口，Esc 应先关它 —— 与"Esc 先关最上面那层"的普遍习惯一致。
		hud.set_legend_visible(false)
		_toolbar.set_help(false)
	else:
		hud.flash("没有进行中的手势")


## 失焦时作废手势：否则"切出去松手"的那一拍会把笔卡在按下状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _stroke and session != null:
		session.cancel()
		_stroke = false
		_erase = false


func _undo() -> void:
	if _stroke:
		return
	var label := session.history.undo_label()
	if session.undo():
		hud.flash("已撤销：" + label)
	else:
		hud.flash("没有可撤销的")


func _redo() -> void:
	if _stroke:
		return
	var label := session.history.redo_label()
	if session.redo():
		hud.flash("已重做：" + label)
	else:
		hud.flash("没有可重做的")


## 切笔：工具坞的按钮与热键共用这一处 —— 于是"按钮高亮"永远是实况的投影，而不是第二份状态。
func _set_tool(mode: int) -> void:
	session.tool.set_mode(mode)
	hud.flash("工具：" + session.tool.label())
	_refresh_hud()


## 笔刷加减（工具坞的 [−]/[+] 与 [ ] 键共用）。面板只报"想加还是想减"（相对量），
## 钳制与语义留在这一层 —— 界面不必知道上限，也就不可能在两处写出不同的上限。
func _step_brush(delta: int) -> void:
	_set_brush(session.tool.brush_size + delta)


## 笔刷乘除（工具坞的 2X / 1÷2）。÷2 向下取整并兜底到 1 —— 与细调同一条底线：
## 笔刷永远至少一格，界面不必认识"上限"（clamp 仍在 _set_brush 一处）。
func _scale_brush(up: bool) -> void:
	var s: int = session.tool.brush_size
	_set_brush(s * 2 if up else maxi(1, s >> 1))


func _set_brush(size: int) -> void:
	var n := clampi(size, 1, max_brush_size)
	if n == session.tool.brush_size:
		hud.flash("笔刷已到 %s" % ("上限" if n == max_brush_size else "下限"))
		return
	session.tool.brush_size = n
	hud.flash("笔刷 %d" % n)
	_refresh_hud()


func _set_material(id: int) -> void:
	if id >= world.materials.size():
		hud.flash("没有 %d 号材质（当前色板 %d 色）" % [id, world.materials.size() - 1])
		return
	_material_id = id
	hud.flash("材质 %d" % id)
	_refresh_hud()


## 擦除开关（工具坞的「擦除」按钮与 E 键共用）：平板上没有右键，这是唯一的擦除入口。
func _toggle_erase() -> void:
	var on := not _tools.erase_mode()
	_tools.set_erase(on)
	hud.flash("擦除模式：%s" % ("开（画的时候挖掉体素）" if on else "关"))


## 对称轴开关（左侧「对称」三个按钮共用）。状态留在 App 这一层，再压进当前笔刷。
func _set_symmetry_axis(axis: int, on: bool) -> void:
	var axes := [_symmetry.x, _symmetry.y, _symmetry.z]
	axes[axis] = 1 if on else 0
	_symmetry = Vector3i(axes[0], axes[1], axes[2])
	_apply_symmetry()
	hud.flash("对称：X%s Y%s Z%s" % [_axis_mark(_symmetry.x), _axis_mark(_symmetry.y), _axis_mark(_symmetry.z)])


func _axis_mark(on: int) -> String:
	return "●" if on != 0 else "○"


## 把 App 级的笔刷设置压进**当前活动对象**的笔刷实例。切对象后必须再调一次 ——
## 新活动对象有它自己的工具实例，不压就退回默认（对称"莫名其妙自己关了"的根因）。
func _apply_symmetry() -> void:
	if session != null and session.tool != null:
		session.tool.symmetry = _symmetry


# ----------------------------------------------------------------------------
# 修改器链（右侧抽屉·层级组挂链 + 参数组改参数）
# ----------------------------------------------------------------------------
# 旋转 / 镜像 / 平铺不再是"一次性重写整片网格"的动作，而是链上一条 QVoxelTransformModifier。
# 于是本段只剩三件事：把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"，
# 并在动手前用 PcgTransform.within_budget 拦一次（那条命令本身在 QVoxelPropertyCommand）。


## 往 node 的链上追加一条修改器（一条可撤销的属性命令）。
##
## 【为什么先造条目再追加，而不是把"算子 + 合成方式"传进来】条目自带开关与合成方式，
## 而这些属于修改器而不属于算子（同一棵 Sdf 树既能被并进去、也能被减掉），
## 故由 QVoxelModifierSerializer.new_modifier 造空条目、本处填好默认核，见 QVoxelNode.add_modifier。
##
## 【为什么默认核是"镜像 X"而不是空】空条目求值为恒等 —— 挂上去画面纹丝不动，
## 用户会以为按钮坏了。镜像既是重排（看得出效果），又不改盒尺寸（不会突然撑大网格）。
func _add_modifier(node: QVoxelNode, kind: String) -> void:
	if world == null or session == null or node == null:
		return
	var m := QVoxelModifierSerializer.new_modifier(kind)
	if m == null:
		return
	if kind == QVoxelModifier.KIND_TRANSFORM:
		(m as QVoxelTransformModifier).transform = PcgTransform.mirror(0)
	var too_big := _over_budget(node, m)
	if too_big != Vector3i.ZERO:
		hud.flash("挂上「%s」会把网格撑到 %d×%d×%d，超过 %d 格的上限，未执行"
				% [m.display_name(), too_big.x, too_big.y, too_big.z,
						PcgTransform.MAX_OUTPUT_VOXELS])
		return
	var cmd := QVoxelPropertyCommand.begin(node, &"modifiers", node, "挂修改器 %s" % m.display_name())
	node.add_modifier(m)
	if not cmd.commit():
		return
	session.history.push(cmd)
	_select_modifier(node, m)
	_chain_changed()
	hud.flash("已挂 %s" % m.display_name())


## 从链上移除第 index 条（同样只记一条属性命令 —— modifiers 就是一个 @export 数组）。
func _remove_modifier(node: QVoxelNode, index: int) -> void:
	if world == null or session == null or node == null:
		return
	if index < 0 or index >= node.modifiers.size():
		return
	var m: QVoxelModifier = node.modifiers[index]
	var cmd := QVoxelPropertyCommand.begin(node, &"modifiers", node, "移除修改器 %s" % m.display_name())
	node.remove_modifier(index)
	if not cmd.commit():
		return
	session.history.push(cmd)
	if _modifier == m:
		_select_modifier(node, null)
	_chain_changed()
	hud.flash("已移除 %s" % m.display_name())


## 旁通 / 启用链上第 index 条。**不删条目** —— 与 Blender 的修改器眼睛同义：
## 试比较两种参数配置时不必反复删了重加。
func _set_modifier_enabled(node: QVoxelNode, index: int, on: bool) -> void:
	if world == null or session == null or node == null:
		return
	if index < 0 or index >= node.modifiers.size():
		return
	var m: QVoxelModifier = node.modifiers[index]
	if m.enabled == on:
		return
	var cmd := QVoxelPropertyCommand.apply(m, &"enabled", on, node,
			"%s修改器 %s" % ["启用" if on else "旁通", m.display_name()])
	if cmd != null:
		session.history.push(cmd)
	_chain_changed()


## 选中链上某条修改器 → 参数组显示它的参数。
func _on_modifier_selected(node: QVoxelNode, index: int) -> void:
	if node == null or index < 0 or index >= node.modifiers.size():
		return
	_select_modifier(node, node.modifiers[index])


## 把参数组绑到 m（null = 清空）。宿主节点一并记下 —— 改参数的命令要挂在它的 content_changed 上。
func _select_modifier(node: QVoxelNode, m: QVoxelModifier) -> void:
	_modifier = m
	_modifier_owner = node if m != null else null
	_inspector_section.bind(m)


## 改参数的手势三段：开始（抓改前值）→ 连续写（不入栈，实时预览）→ 结束（封口入栈）。
## 与改色 / 体素笔同一时间线（见 QVoxelPropertyCommand 的"手势即命令"）。
func _begin_prop_edit(target: Object, prop: StringName) -> void:
	if session == null or _modifier_owner == null or target == null:
		return
	_prop_cmd = QVoxelPropertyCommand.begin(target, prop, _modifier_owner, "修改器参数")


func _live_prop(target: Object, prop: StringName, value: Variant) -> void:
	if _prop_cmd == null or target == null:
		return
	target.set(prop, value)
	# 实时预览：只重建渲染，**不重建树** —— 重建会把正在拖的那根滑条销毁，手势当场断掉。
	# 与改色同理（见 QVoxelierColorSection），差异只在"链改了要连输出盒一起同步"。
	if session != null:
		session.rebuild()


func _end_prop_edit(_target: Object, _prop: StringName) -> void:
	if _prop_cmd == null:
		return
	if _prop_cmd.commit() and session != null:
		session.history.push(_prop_cmd)
	_prop_cmd = null
	_chain_changed()


## 链变了之后的四件事：标脏、重建显示、刷新层级（行上的显示名与超限提示跟着变）、重绑参数组。
##
## 【为什么统一走这里，而不是各入口各刷一遍】"链变了"的入口有四个（挂 / 删 / 旁通 / 改参数），
## 它们要刷的东西一模一样；分散写迟早漏一处 —— 表现为"撤销回去树上是旧名字"。
func _chain_changed() -> void:
	_mark_dirty()
	_rebuild_view()
	_refresh_hud()
	_tree_section.refresh()
	_rebind_inspector()


## 让参数组重看一眼数据。**两个出口共用**：链变了（_chain_changed）与撤销 / 重做（_on_history_changed）
## —— 两者都会把数据改到"面板控件被建出来时"之外的状态：
##   · 选中算子会顺带校正合成方式（见 QVoxelVolumeModifier.detail），而下拉框还停在旧值；
##   · 撤销一次改参数会把值退回去，滑条却还停在拖完的位置；
##   · 撤销掉"挂修改器"会让绑着的那条**不在链上**了 —— 再改它就是写进孤儿，还白占一次撤销。
## 故这里一并做"清理 + 重绑"：绑着的那条已不在链上就清空，否则重绑。
##
## 【为什么按 is_editing() 让开】重绑会重建控件、把正在拖的滑条销毁。手势中的实时预览本就不重建
## （见 _live_prop），而撤销栈的信号是在手势收尾（commit）之后才发的，故走到这里手势已经结束。
func _rebind_inspector() -> void:
	if _inspector_section == null or _inspector_section.is_editing():
		return
	if _modifier != null and not _owns_modifier(_modifier_owner, _modifier):
		_select_modifier(null, null)
	else:
		_inspector_section.bind(_modifier)


## 挂上 candidate 之后，node 的输出盒会变成多大。**超限则返回那个超限的尺寸**（供报错文案用），
## 没超限返回 ZERO。
##
## 【为什么问核的 raw_output_size 而不是引擎的 output_grid_size】后者会经过核的上限判定，
## 超限时"静静地原样返回"——于是 UI 看到的尺寸与没挂时一样，压根发现不了超限。
## 而界面上先拦一次只是为了给一句人话；真正生效的那道闸在 PcgTransform（撤销 / 读盘也过它），
## 判据共用 within_budget，故"提示"与"实际生效"不会说两套话。
func _over_budget(node: QVoxelNode, candidate: QVoxelModifier) -> Vector3i:
	var t := candidate.op() as PcgTransform
	if t == null:
		return Vector3i.ZERO
	var size := t.raw_output_size(_node_output_size(node))
	return Vector3i.ZERO if PcgTransform.within_budget(size) else size


## node 当前的输出盒尺寸。模型问会话（与显示层同源，且那份结果本来就算过）；
## 组要问引擎 —— 组的输入盒是"子树并集包围盒"，那是求值的产物，没有更便宜的来源。
func _node_output_size(node: QVoxelNode) -> Vector3i:
	if node == null:
		return Vector3i.ZERO
	if node.is_model():
		var s: QVoxelEditSession = _sessions.get((node as QVoxelModel).model_id)
		return s.output_size() if s != null else (node as QVoxelModel).grid_size
	# ctx 的 grid_size 随便给 —— 组求值第一件事就是把它换成"子树并集包围盒"（见 QVoxelEvalEngine）。
	var ctx := QVoxelEvalContext.make(Vector3i.ONE, 0)
	return QVoxelEvalEngine.evaluate_node(node, ctx, null, null).grid_size


## 视图模式：绘制 / 转视角 / 平移。触摸屏上没有中键，故左键会被借去当视角键，
## 切模式时若正按着笔，必须先收笔 —— 否则那一笔会以"松手"的形式留下半截改动。
func _set_view_mode(mode: int) -> void:
	_nav = mode == QVoxelierToolbar.VIEW_ORBIT
	_pan_mode = mode == QVoxelierToolbar.VIEW_PAN
	_orbit = false
	_pan = false
	if mode != QVoxelierToolbar.VIEW_PAINT and _stroke:
		session.cancel()
		_stroke = false
	match mode:
		QVoxelierToolbar.VIEW_ORBIT:
			hud.flash("导航模式：单指 / 左键拖动 = 转视角")
		QVoxelierToolbar.VIEW_PAN:
			hud.flash("平移模式：单指 / 左键拖动 = 平移画面")
		_:
			hud.flash("回到绘制：拖动 = 画")


# ----------------------------------------------------------------------------
# 视图（镜头 / 标准视角 / 网格线）
# ----------------------------------------------------------------------------

## 切镜头（视图栏「透视 / 正交」与小键盘 5 共用）。正交不是"另一种画风"：
## 没有近大远小才量得准比例、才对得齐体素 —— 体素建模里它是刚需而不是可选项。
func _set_lens(mode: int) -> void:
	camera.set_lens(mode)
	_view_bar.set_lens(mode)
	hud.flash("镜头：%s" % QVoxelViewCamera.LENS_NAMES[mode])


## 切标准视角。**三个入口共用这一条路径**：视图栏七个预设、朝向指示器点轴、小键盘 ——
## 于是三处的回显与提示永远一致（不存在"点了指示器但视图栏还亮着别的"）。
func _apply_view(view: int) -> void:
	camera.apply_view(view)
	_view_bar.set_view(view)
	hud.flash("%s视图" % QVoxelViewCamera.VIEW_NAMES[view])


## 网格线显隐（视图栏开关）。只摘格线、保留外框 —— 外框是"合法范围"的告知，见 QVoxelGridFloor。
func _set_grid_lines(on: bool) -> void:
	grid_floor.set_grid_lines_visible(on)
	_view_bar.set_grid_lines(on)
	hud.flash("网格线：%s" % ("开" if on else "关"))


## 小键盘切视角 —— 沿用 Blender 的约定（1 前 / 3 右 / 7 顶 / 5 切投影）。
## 【为什么照抄这套】建模用户的视角肌肉记忆大多来自 Blender，白捡的学习成本不捡白不捡。
## 小键盘在本应用没有任何既有用途，不会与工具热键（字母）或材质键（主键盘 1..8）相撞。
## 返回是否命中，供 _on_key 的 elif 链判断。
func _numpad_view(key: Key) -> bool:
	match key:
		KEY_KP_1: _apply_view(QVoxelViewCamera.View.FRONT)
		KEY_KP_2: _apply_view(QVoxelViewCamera.View.BACK)
		KEY_KP_3: _apply_view(QVoxelViewCamera.View.RIGHT)
		KEY_KP_4: _apply_view(QVoxelViewCamera.View.LEFT)
		KEY_KP_7: _apply_view(QVoxelViewCamera.View.TOP)
		KEY_KP_8: _apply_view(QVoxelViewCamera.View.BOTTOM)
		KEY_KP_0: _apply_view(QVoxelViewCamera.View.ISO)
		KEY_KP_5: _set_lens(QVoxelViewCamera.Lens.ORTHO
				if camera.lens == QVoxelViewCamera.Lens.PERSPECTIVE
				else QVoxelViewCamera.Lens.PERSPECTIVE)
		_:
			return false
	return true


# ----------------------------------------------------------------------------
# 工程文件（.qvx）
# ----------------------------------------------------------------------------

## 新建 / 打开都会**整体换掉**当前世界，故先过一道"未保存的改动"确认。
## 这层保护是必须的：平板上没有 Ctrl+S 的肌肉记忆，误触一次「新建」丢掉一下午是常事。
func request_new() -> void:
	_confirm_discard("新建", new_model)


## 打开工程（path 为空 = 弹文件对话框让用户选）。
func request_open(path := "") -> void:
	_confirm_discard("打开工程", _open_now.bind(path))


func _open_now(path: String) -> void:
	if path.is_empty():
		_open_dialog.popup_centered_ratio(0.7)
	else:
		open_project(path)


## 有未落盘改动时先问一句；没有就直接执行 —— 绝大多数情况下不该多出这一步。
func _confirm_discard(action: String, cb: Callable) -> void:
	if not _dirty:
		cb.call()
		return
	_confirm.dialog_text = "当前工程有未保存的改动。\n继续「%s」会丢掉这些改动。" % action
	_confirm.get_ok_button().text = "放弃改动并继续"
	_confirm.get_cancel_button().text = "返回"
	# 取消不触发 confirmed，于是连接会留着；下一次再来同一个动作就会重复连接而报错。
	# 这里先断再连，把它变成"最近一次请求说了算"。
	if _confirm.confirmed.is_connected(cb):
		_confirm.confirmed.disconnect(cb)
	_confirm.confirmed.connect(cb, CONNECT_ONE_SHOT)
	_confirm.popup_centered()


## 打开工程：读盘 → 接管世界 → 重建会话。**失败时视口保持原样**（绝不半途换掉用户正编辑的东西）。
func open_project(path: String) -> bool:
	if _stroke:
		session.cancel()
		_stroke = false
	var loaded := QVoxelProject.load_world(path)
	if loaded == null:
		hud.flash("打不开这个工程（缺失或已损坏）：%s" % path.get_file())
		return false
	var obj := _pick_editable(loaded)
	if obj == null:
		hud.flash("这个工程里没有可编辑的对象：%s" % path.get_file())
		return false
	_install(loaded, obj)
	project_path = path
	_dirty = false
	_update_title()
	var total := loaded.all_models().size()
	hud.flash("已打开 %s%s" % [path.get_file(),
			"（共 %d 个模型，可在右侧「层级」里切换）" % total if total > 1 else ""])
	return true


## 一期只编辑一个模型：优先挑"有内容"的那个（打开样例时第一眼就有东西看），都没有就取第一个。
## 多模型 / 组是二期的事（DESIGN §4.5）。
func _pick_editable(w: QVoxelWorld) -> QVoxelModel:
	var first: QVoxelModel = null
	for o in w.all_models():
		if o == null:
			continue
		if first == null:
			first = o
		if not o.is_empty():
			return o
	return first


## 保存到当前工程文件；还没存过盘就转"另存为"。
func save_project() -> void:
	if _stroke:
		session.cancel()
		_stroke = false
	if project_path.is_empty():
		save_project_as()
		return
	_write_project(project_path)


## 另存为：弹文件对话框，默认文件名取世界名。
func save_project_as() -> void:
	_save_dialog.current_file = "%s.%s" % [world.world_name(), QVoxelProject.EXTENSION]
	_save_dialog.popup_centered_ratio(0.7)


func _write_project(path: String) -> bool:
	var err := QVoxelProject.save(world, path)
	if err != OK:
		hud.flash("保存失败（错误码 %d）：%s" % [err, path.get_file()])
		return false
	project_path = path
	_dirty = false
	_update_title()
	hud.flash("已保存 %s" % path.get_file())
	return true


func _on_save_path_selected(path: String) -> void:
	_write_project(QVoxelProject.ensure_extension(path))


## 文件对话框：一个"打开"、一个"另存为"。走系统文件系统 —— `res://` 是只读的导入资源，
## 工程文件本就该落在用户自己的目录里（导出打包后 `res://` 更是读不到的）。
func _build_dialogs() -> void:
	_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_open_dialog.file_selected.connect(open_project)
	_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_save_dialog.file_selected.connect(_on_save_path_selected)

	_palette_import_dialog = _make_palette_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_palette_import_dialog.file_selected.connect(_import_palette)
	_palette_export_dialog = _make_palette_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_palette_export_dialog.file_selected.connect(_export_palette)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "未保存的改动"
	_confirm.cancel_button_text = "返回"
	# 对话框是独立的 Window，不会从 Node3D 父链上继承主题，得手挂一份 —— 否则它会顶着一套
	# 与全应用无关的默认皮，风格统一在这里破功。
	_confirm.theme = QVoxelUi.theme()
	add_child(_confirm)


func _make_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.current_dir = _default_dir()
	# 与 _confirm 同因：对话框的父链是 Node3D，主题传不下来，不挂就是一套 Godot 默认皮
	#（本应用是内嵌子窗口样式，所以这层皮是看得见的）。 Theme 是**叠加**而不是替换：
	# 本主题没定义的条目（Tree / LineEdit / OptionButton）继续走引擎默认值，不会把对话框弄坏。
	d.theme = QVoxelUi.theme()
	d.add_filter("*.%s" % QVoxelProject.EXTENSION, "QVoxelier 工程")
	d.title = "打开工程" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存工程"
	# 引擎自建文案在游戏进程里没有内置翻译，会显示成 "Save" / "Cancel"。
	# 其余（Path: / 列头 / 新建文件夹）同样来自引擎，改不动；但这两个是每次操作都要读、
	# 要按的，必须跟界面同一种语言。
	d.ok_button_text = "打开" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存"
	d.cancel_button_text = "取消"
	add_child(d)
	return d


## 调色板用的文件对话框。**PNG 而不是自定义格式**：MagicaVoxel 的调色板就是 256×1 的 PNG，
## 沿用它就能与其它体素工具互相倒色板，也不用再定义一套只有本程序认得的格式。
func _make_palette_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.current_dir = _default_dir()
	d.theme = QVoxelUi.theme()
	d.add_filter("*.png", "调色板 PNG（256×1）")
	d.title = "导入调色板" if mode == FileDialog.FILE_MODE_OPEN_FILE else "导出调色板"
	d.ok_button_text = "打开" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存"
	d.cancel_button_text = "取消"
	d.use_native_dialog = false
	add_child(d)
	return d


## 文件对话框的首选落地目录。**两个平台的"用户自己的目录"不是同一个地方**：
##   桌面：系统的「文档」—— 存完还能在资源管理器/访达里找回来（`user://` 在桌面上是
##         隐藏的 AppData/Godot/app_userdata/<项目>，用户绝不会去那儿翻自己的模型）。
##   移动 / Web：`user://` —— 那是唯一保证可写的沙箱，Android 的分区存储下写系统目录会被拒。
## 取不到系统目录（精简系统 / 权限受限）时一律退回 `user://`，绝不留下一个点不进去的首路径。
static func _default_dir() -> String:
	if OS.has_feature("pc"):
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if not docs.is_empty() and DirAccess.dir_exists_absolute(docs):
			return docs
	return ProjectSettings.globalize_path("user://")


## 把 `.qvx` 拖进窗口即打开（建模时最顺手的一步）；非工程文件一律忽略。
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if QVoxelProject.is_project_path(f):
			# 拖进来同样是"整体换掉当前世界"，走 request_open 才有那道未保存确认。
			request_open(f)
			return
	hud.flash("只认得 .%s 工程文件" % QVoxelProject.EXTENSION)


func _update_title() -> void:
	var name := project_path.get_file() if not project_path.is_empty() else "未命名"
	_toolbar.set_project(name, _dirty)
	if not Engine.is_editor_hint() and get_window() != null:
		get_window().title = "QVoxelier — %s%s" % [name, " *" if _dirty else ""]


# ----------------------------------------------------------------------------
# 状态栏
# ----------------------------------------------------------------------------

## 撤销栈一动就说明内容变了 —— 脏标记与状态栏由同一个信号驱动，不会各说各话。
func _on_history_changed() -> void:
	_mark_dirty()
	_refresh_hud()
	# 撤销 / 重做一条"图层可见性"命令时，node 回了去、视口还没换 —— 故这里补一次重建。
	# _rebuild_view 复用既有渲染器（见其注释），单对象场景等于空操作，不心疼。
	_rebuild_view()
	# 链上的重排条目（旋转 / 镜像 / 平铺）会改分辨率，撤销 / 重做同样会把它改回去 ——
	# 地面网格框是按输出盒画的，不同步就出现"模型缩回去了、外框还停在放大后的尺寸"。
	# 放在这里是因为本函数是**一切历史变化的唯一出口**（push / undo / redo 都发 changed）。
	if session != null:
		grid_floor.grid_size = session.output_size()
	# 参数组同样要重看一眼：撤销 / 重做会把数据退回到面板之外的状态（见 _rebind_inspector）。
	_rebind_inspector()


## 标记"有未落盘改动"。对象增删这类不入撤销栈的操作也走这里，保证标题星号不漏。
func _mark_dirty() -> void:
	if _dirty:
		return
	_dirty = true
	_update_title()


## 界面刷新的**唯一入口**：一处改状态（工具 / 笔刷 / 材质 / 撤销栈），所有界面跟着走。
## 不做增量 diff —— 状态栏与工具坞加起来不过几十个 Label，而"每个状态变更是谁负责刷新哪块"
## 才是真会出错的地方（漏一处就出现"按钮高亮着、提示还写着上一个工具"）。
func _refresh_hud() -> void:
	if hud.session == session:
		hud.refresh()
	if session == null:
		return
	_toolbar.set_history(session.history.can_undo(), session.history.can_redo())
	_tools.set_tool(session.tool.mode)
	_tools.set_brush(session.tool.brush_size, session.tool.supports_brush_size())
	# 对称是 App 级设置 → 每次刷新都把它压回当前对象的笔刷，并回写三个按钮的按下态。
	_apply_symmetry()
	_tools.set_symmetry(_symmetry)
	_palette.set_current(_material_id)
	hud.set_material_id(_material_id)
	_refresh_panels()


## 右列三组的刷新。与 _refresh_hud 同一入口，于是"改状态 → 全界面跟上"仍只有一条路径。
func _refresh_panels() -> void:
	if _color_section == null or world == null or session == null:
		return
	var has := _material_id > 0 and _material_id < world.materials.size()
	_color_section.bind(_material_id, world.material_color(_material_id) if has else Color(0, 0, 0, 0))
	_tree_section.set_world(world, session.object.model_id)


## 世界的材质表 → 调色板用的颜色数组：**下标即材质 ID**，0 位留空气占位。
## 不直接用 default_palette，是因为打开别人的工程时色板得跟着工程走。
func _material_colors(w: QVoxelWorld) -> Array[Color]:
	var colors: Array[Color] = [Color(0, 0, 0, 0)]
	for id in range(1, w.materials.size()):
		colors.append(w.material_color(id))
	return colors


## 光标格：画的时候看"要写哪一格"，擦的时候看"要擦哪一格"（Pick 已按擦除算好 place）。
## 屏幕坐标由调用方传入（鼠标事件里有，不必再问视口要一次 —— 内嵌视口时那个答案还是错的）。
func _refresh_cursor(screen: Vector2) -> void:
	var pick := _pick_at(screen)
	if not pick.valid():
		hud.set_cursor(Vector3i.MIN)
		return
	hud.set_cursor(pick.hit if pick.erase else pick.place)


func _bind_actions() -> void:
	InputTool.register_action(ACTION_UNDO, [InputTool.key_event(KEY_Z, true)])
	InputTool.register_action(ACTION_REDO, [
		InputTool.key_event(KEY_Z, true, true), InputTool.key_event(KEY_Y, true),
	])
	InputTool.register_action(ACTION_BRUSH_UP, [
		InputTool.key_event(KEY_BRACKETRIGHT), InputTool.key_event(KEY_EQUAL),
	])
	InputTool.register_action(ACTION_BRUSH_DOWN, [
		InputTool.key_event(KEY_BRACKETLEFT), InputTool.key_event(KEY_MINUS),
	])
	InputTool.register_action(ACTION_SAVE, [InputTool.key_event(KEY_S, true)])
	InputTool.register_action(ACTION_SAVE_AS, [InputTool.key_event(KEY_S, true, true)])
	InputTool.register_action(ACTION_OPEN, [InputTool.key_event(KEY_O, true)])


# ----------------------------------------------------------------------------
# 层级树（右侧抽屉·层级组）
# ----------------------------------------------------------------------------
# 本段只做一件事：把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"。
# 树视图本身是 QVoxelWorld.nodes 的**纯投影**（见 QVoxelierTreeSection）。

## 点树上的行：模型就切过去编辑；组只是容器，不改变当前编辑对象。
##
## 【为什么要顺手清掉参数组】选中的是"节点"，而参数组显示的是"链上某一条修改器"。
## 换了节点还留着上一条的参数，滑一下就把改动写进了另一个对象的链里（且看不出来）。
func _on_tree_selected(node: QVoxelNode) -> void:
	if _modifier != null and (_modifier_owner != node or not _owns_modifier(node, _modifier)):
		_select_modifier(null, null)
	if node != null and node.is_model():
		_activate((node as QVoxelModel).model_id)


## m 是否还在 node 的链上（撤销 / 重做会换掉整个数组，条目可能已经不在了）。
func _owns_modifier(node: QVoxelNode, m: QVoxelModifier) -> bool:
	return node != null and m != null and node.modifiers.has(m)


## 新建模型：尺寸随当前模型（"再做一个同样大小的"是最常见的心智模型）。
## 新模型会挂一条展示会话并**直接切过去** —— 建了却停在旧的上面，用户会以为没建成。
func _add_model(parent: QVoxelGroup) -> void:
	if world == null or session == null:
		return
	# 尺寸随**当前输出盒**（= 屏幕上看到的那个大小），而不是手绘种子的尺寸：
	# 当前模型若挂了平铺，照抄种子尺寸会做出一个明显更小的"同样大小"的模型。
	var o := world.create_model("", session.output_size(), parent)
	_sessions[o.model_id] = QVoxelEditSession.create_for(o, world)
	(_sessions[o.model_id] as QVoxelEditSession).request_render_update = model.request_update
	(_sessions[o.model_id] as QVoxelEditSession).history.changed.connect(_on_history_changed)
	_mark_dirty()
	_activate(o.model_id)


## 新建组。组没有内容，故只标脏 + 刷新（不切换编辑对象）。
func _add_group(parent: QVoxelGroup) -> void:
	if world == null:
		return
	world.create_group("Group", parent)
	_mark_dirty()
	_tree_section.refresh()
	hud.flash("已新建组")


## 删除节点（连同子树）。
##
## 【为什么删组不先拆散】"删掉这个组"在用户心里就是"这一坨不要了"；想留内容就先把它拖出来。
## 拆散是另一个动作，混进来会让"删除"变得不可预期。
##
## 【为什么不入撤销栈】结构增删与体素编辑是两类东西：后者才是高频、真正需要逐笔回退的手势。
func _remove_node(node: QVoxelNode) -> void:
	if world == null or node == null:
		return
	# 至少留一个模型：世界空了就无物可编。
	if node.is_model() and world.all_models().size() <= 1:
		hud.flash("至少要留一个模型")
		return
	var gone: Array[QVoxelModel] = []
	for n in world.all_nodes():
		if n.is_model() and _is_under(node, n):
			gone.append(n as QVoxelModel)
	for m in gone:
		var s: QVoxelEditSession = _sessions.get(m.model_id)
		if s != null and s.history.changed.is_connected(_on_history_changed):
			s.history.changed.disconnect(_on_history_changed)
		_sessions.erase(m.model_id)
	var was_active := session != null and gone.has(session.object)
	world.remove_node(node)
	_mark_dirty()
	if was_active:
		session = null
		var rest := world.all_models()
		if not rest.is_empty():
			_activate(rest[0].model_id, false)
			hud.flash("已删除当前模型，切到 %s" % rest[0].display_name())
		return
	_rebuild_view()
	_refresh_hud()
	_tree_section.refresh()
	hud.flash("已删除 %s" % node.display_name())


## node 是否在 root 的子树里（含 root 自己）。
func _is_under(root: QVoxelNode, node: QVoxelNode) -> bool:
	if root == node:
		return true
	if not root.is_group():
		return false
	for c in (root as QVoxelGroup).child_nodes:
		if c != null and _is_under(c, node):
			return true
	return false


## 沿树往上看：任何一层隐藏都算数（可见性**沿树继承**）。
func _node_visible(node: QVoxelNode) -> bool:
	var n := node
	while n != null:
		if not n.visible:
			return false
		n = world.find_parent(n)
	return true


## 沿树往上看：任何一层锁定都算数（锁定**沿树继承**）。
func _node_locked(node: QVoxelNode) -> bool:
	var n := node
	while n != null:
		if n.locked:
			return true
		n = world.find_parent(n)
	return false


func _set_node_visible(node: QVoxelNode, on: bool) -> void:
	_write_node_field(node, &"visible", on, "可见性")


func _set_node_locked(node: QVoxelNode, on: bool) -> void:
	_write_node_field(node, &"locked", on, "锁定")


func _rename_node(node: QVoxelNode, new_name: String) -> void:
	_write_node_field(node, &"node_name", new_name, "重命名")


## 拖拽落位：把节点挂到新父下的 index 位置。
##
## 【为什么"移动"和"插入"是同一个操作】树上没有"移动"这回事 —— 移动就是"从原父摘下来、
## 挂到新父"。QVoxelWorld.attach_node 直接拒绝"把组挂进自己的子树"（那会造出环）。
func _move_node(node: QVoxelNode, parent: QVoxelGroup, index: int) -> void:
	if world == null or node == null:
		return
	if not world.attach_node(node, parent, index):
		hud.flash("不能把组放进它自己里面")
		return
	_mark_dirty()
	_tree_section.refresh()


## 改节点的一个字段并记成一条可撤销命令。
##
## 【为什么改完要 _rebuild_view】可见性不只是个数据字段 —— 它决定该节点渲染与否；
## 而这条命令的 undo() 只写属性、不会替我们叫醒视口，故两条路径都得手动重建。
func _write_node_field(node: QVoxelNode, prop: StringName, value: Variant, label: String) -> void:
	if world == null or node == null or session == null:
		return
	var cmd := QVoxelPropertyCommand.apply(node, prop, value, node, label)
	if cmd != null:
		session.history.push(cmd)
	_rebuild_view()
	_refresh_hud()
	_tree_section.refresh()



# ----------------------------------------------------------------------------
# 颜色（右侧抽屉·颜色组）
# ----------------------------------------------------------------------------

## 改色的手势三段：开始（抓改前值）→ 连续写（不入栈）→ 结束（封口入栈）。
## 与体素笔同一时间线（见 QVoxelierColorSection 的"手势即命令"注释）。
func _begin_color_edit() -> void:
	if world == null or _material_id <= 0 or _material_id >= world.materials.size():
		return
	_color_cmd = QVoxelPropertyCommand.begin(world, &"materials", null, "修改材质颜色")


func _live_color(c: Color) -> void:
	if world == null or _material_id <= 0:
		return
	world.set_material_color(_material_id, c)
	_sync_material(_material_id)


func _end_color_edit() -> void:
	if _color_cmd != null and _color_cmd.commit():
		session.history.push(_color_cmd)
	_color_cmd = null
	_palette.set_palette(_material_colors(world))
	_refresh_hud()


## 把世界上某个材质刷进所有会话的 VoxelData（渲染器读的是那份），再重生成材质纹理。
## 【为什么每个会话都要刷】非活动对象也显示着，各自的 VoxelData 里也存着一份材质 ——
## 只刷活动对象的话，换个色会看到"当前对象变了、旁边的对象还是旧色"。
func _sync_material(id: int) -> void:
	if world == null or id <= 0 or id >= world.materials.size():
		return
	var mat := VoxelMaterial.from_mate(world.materials[id], id)
	for s in _sessions.values():
		(s as QVoxelEditSession).data.add_material(mat)
	_rerender_materials()


func _rerender_materials() -> void:
	if model != null:
		model.regenerate_materials()
	for r in _display.values():
		if is_instance_valid(r):
			r.regenerate_materials()


func _add_material() -> void:
	if world == null or session == null:
		return
	var cmd := QVoxelPropertyCommand.begin(world, &"materials", null, "新增材质")
	var id := world.add_material(Color(0.8, 0.8, 0.8))
	if cmd.commit():
		session.history.push(cmd)
	_sync_material(id)
	_palette.set_palette(_material_colors(world))
	_set_material(id)
	hud.flash("已新增材质 %d" % id)


# ----------------------------------------------------------------------------
# 取色器
# ----------------------------------------------------------------------------

func _set_eyedropper(on: bool) -> void:
	_eyedropper = on
	_color_section.set_eyedropper(on)
	hud.flash("取色器：%s" % ("开 —— 点视口里的体素吸取其材质色" if on else "关"))


## 吸取某屏幕位置下体素的材质，并把当前材质切过去。
func _pick_material_at(screen: Vector2) -> void:
	if session == null:
		return
	var pick := _pick_at(screen)
	if not pick.valid():
		hud.flash("这儿没有体素可吸取")
		return
	var id := session.data.get_voxel(pick.hit)
	if id <= 0:
		hud.flash("这儿是空的，没有材质可吸")
		return
	_set_material(id)
	hud.flash("已吸取材质 %d" % id)


# ----------------------------------------------------------------------------
# 调色板导入 / 导出（256×1 的 PNG，索引即材质 ID —— 与 MagicaVoxel 互通）
# ----------------------------------------------------------------------------

func _import_palette(path: String) -> void:
	if world == null or session == null:
		return
	var img := Image.load_from_file(path)
	if img == null:
		hud.flash("读不了这个 PNG：%s" % path.get_file())
		return
	img.convert(Image.FORMAT_RGBA8)
	var width := img.get_width()
	if width < 2:
		hud.flash("调色板 PNG 太窄（应是 256×1）")
		return
	var cmd := QVoxelPropertyCommand.begin(world, &"materials", null, "导入调色板")
	for i in range(1, mini(width, 256)):
		world.set_material_color(i, img.get_pixel(i, 0))
	if cmd.commit():
		session.history.push(cmd)
	_push_palette_into_all()
	_palette.set_palette(_material_colors(world))
	_refresh_hud()
	hud.flash("已导入调色板（%d 色）" % (mini(width, 256) - 1))


func _export_palette(path: String) -> void:
	if world == null:
		return
	if not path.to_lower().ends_with(".png"):
		path += ".png"
	var img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in 256:
		var c := Color(0, 0, 0, 0)
		if i > 0 and i < world.materials.size():
			c = world.material_color(i)
		img.set_pixel(i, 0, c)
	var err := img.save_png(path)
	if err != OK:
		hud.flash("导出失败（错误码 %d）" % err)
		return
	hud.flash("已导出调色板：%s" % path.get_file())


## 把整张材质表刷进每一条会话的 VoxelData（导入后一次性对齐，比逐色 _sync_material 省事）。
func _push_palette_into_all() -> void:
	if world == null:
		return
	for s in _sessions.values():
		var data: VoxelData = (s as QVoxelEditSession).data
		for id in range(1, world.materials.size()):
			data.add_material(VoxelMaterial.from_mate(world.materials[id], id))
	_rerender_materials()
