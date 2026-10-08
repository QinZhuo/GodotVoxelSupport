@tool
class_name QVoxelierApp
extends Node3D
## 建模视口的应用壳：**装配 + 输入翻译 + 快捷键**，不含任何算法（DESIGN §4.1 的 View 层）。
##
## 【它只做三件事】
##   ① 装配：新建世界/对象 → 建会话 → 把显示层交给渲染器、把网格交给地板、把会话交给状态栏；
##   ② 翻译：鼠标事件 → 相机射线 → 网格拾取 → `QVoxEditSession` 的手势（begin/drag/release）；
##   ③ 快捷键：工具表里的热键切笔、[ ] 改笔刷、Ctrl+Z / Ctrl+Shift+Z 撤销重做、Esc 取消、Home 取景；
##      工程文件 Ctrl+S / Ctrl+Shift+S / Ctrl+O（`.qvox` 也能直接拖进窗口）。
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
@onready var camera: QVoxOrbitCamera = $Camera
@onready var grid_floor: QVoxGridFloor = $Model/Floor
@onready var hud: QVoxelierHud = $Hud

## 应用栏 / 工具坞 / 调色板：**在代码里建**而不是摆进 .tscn —— 它们的内容完全由运行时数据决定
## （工具表、世界的材质表），在场景里预摆只会得到一份立刻被推翻的空壳；
## 状态栏（Hud）留在场景里，因为它是静态骨架、且视口脚本要按路径引用它。
var _toolbar: QVoxelierToolbar
var _tools: QVoxelierTools
var _palette: QVoxelierPalette
var _confirm: ConfirmationDialog

## 当前世界与编辑会话（装配产物；换模型时整体重建）。
var world: QVoxWorld
var session: QVoxEditSession

## 当前工程文件路径（空 = 还没存过盘的新工程，"保存"会转成"另存为"）。
var project_path := ""

var _material_id := 1
var _stroke := false
var _erase := false
var _orbit := false
var _pan := false
## 导航 / 平移模式：拖动改的是视角而不是体素。桌面上的中键与 Shift+中键，在触摸屏上
## 没有对应物，故提升为常驻开关 —— 它与 `_orbit` / `_pan` 这类"某一帧正在发生的拖动"不同，
## 是**跨手势的粘性模式**，所以排在状态区而不是手势区。
var _nav := false
var _pan_mode := false
## 有未落盘的改动（状态栏与窗口标题上的 *）。
var _dirty := false

var _open_dialog: FileDialog
var _save_dialog: FileDialog

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
	_tools.erase_toggled.connect(func(on: bool): hud.flash("擦除模式：%s" % ("开" if on else "关")))

	_palette = QVoxelierPalette.new()
	_palette.name = "Palette"
	add_child(_palette)
	_palette.material_selected.connect(_set_material)


## 新建一个空模型（grid 为 ZERO 时用导出的 grid_size）：建世界 → 建对象 → 装配。
func new_model(grid := Vector3i.ZERO) -> void:
	var g: Vector3i = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else grid_size
	var w := QVoxWorld.create_empty()
	for c in default_palette:
		w.add_material(c)
	_install(w, w.create_object("Model", g))
	project_path = ""
	_dirty = false
	_update_title()


## 装配：世界 + 待编辑对象 → 会话 / 渲染器 / 地板 / 状态栏。
## **新建与打开共用这一条路径** —— 两套初始化迟早会分叉出"新建能画、打开画不了"这类怪病。
func _install(w: QVoxWorld, obj: QVoxObject) -> void:
	world = w
	session = QVoxEditSession.create_for(obj, w)
	session.request_render_update = model.request_update
	session.history.changed.connect(_on_history_changed)
	_material_id = 1
	_stroke = false
	_erase = false

	model.voxel_scale = w.voxel_size()
	model.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	model.data = session.data
	grid_floor.grid_size = obj.grid_size
	grid_floor.voxel_scale = model.voxel_scale

	hud.session = session
	# 调色板取**世界的材质表**（而不是 default_palette）：打开别人做的 256 色工程时也照显，
	# 否则界面上会是一排与工程无关的颜色。
	_palette.set_palette(_material_colors(w))
	frame_view()
	_refresh_hud()


## 取景：把"有东西可落笔"的范围落进画面（新建 / 打开 / Home 键）。
## 空图时唯一能落笔的是网格底面（`QVoxGridPick` 的落笔面），所以对准底面 —— 若照搬"框住整块
## 32³ 网格"，默认 25° 视角下屏幕上半尽是空体积，点正中只会换来一句"这儿落不了笔"。
func frame_view() -> void:
	if session == null:
		return
	var g := Vector3(session.object.grid_size) * model.voxel_scale
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
	else:
		_switch_by_hotkey(e.keycode)


## 动作命中判定：**必须精确比对修饰键**（第 3 个参数 exact_match）。
## `is_action_pressed` 默认只比键码、不比修饰键 —— 于是 Ctrl+Shift+Z 会连"撤销"一起命中、
## Ctrl+Shift+S 会连"保存"一起命中，谁先判谁赢、另一个永远轮不到（"重做"就是这么坏的）。
func _pressed(e: InputEventKey, action: StringName) -> bool:
	return e.is_action_pressed(action, false, true)


## 热键切笔：与点工具坞走同一条 `_set_tool`，于是按钮高亮与提示文案不可能与实况不一致。
func _switch_by_hotkey(key: Key) -> void:
	for row in QVoxBrushTool.MODES:
		if row.hotkey == key:
			_set_tool(row.mode)
			return


## 把屏幕坐标解成"这一次落笔打在哪"：相机射线 → 体素空间 → 网格拾取（含空图落在地板上）。
func _pick_at(screen: Vector2) -> QVoxBrushTool.Pick:
	var scale := model.voxel_scale
	var origin: Vector3 = model.to_local(camera.project_ray_origin(screen)) / scale
	var dir: Vector3 = model.global_transform.basis.inverse() * camera.project_ray_normal(screen)
	var info := QVoxGridPick.hit(session.data, origin, dir, session.object.grid_size)
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
# 工程文件（.qvox）
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
	var loaded := QVoxProject.load_world(path)
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
	var extra := loaded.objects.size() - 1
	hud.flash("已打开 %s%s" % [path.get_file(),
			"（另有 %d 个对象，一期只编辑这个）" % extra if extra > 0 else ""])
	return true


## 一期只编辑一个对象：优先挑"有内容"的那个（打开样例时第一眼就有东西看），都没有就取第一个。
## 多对象 / 图层是二期的事（DESIGN §4.5）。
func _pick_editable(w: QVoxWorld) -> QVoxObject:
	var first: QVoxObject = null
	for o in w.objects:
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
	_save_dialog.current_file = "%s.%s" % [world.world_name(), QVoxProject.EXTENSION]
	_save_dialog.popup_centered_ratio(0.7)


func _write_project(path: String) -> bool:
	var err := QVoxProject.save(world, path)
	if err != OK:
		hud.flash("保存失败（错误码 %d）：%s" % [err, path.get_file()])
		return false
	project_path = path
	_dirty = false
	_update_title()
	hud.flash("已保存 %s" % path.get_file())
	return true


func _on_save_path_selected(path: String) -> void:
	_write_project(QVoxProject.ensure_extension(path))


## 文件对话框：一个"打开"、一个"另存为"。走系统文件系统 —— `res://` 是只读的导入资源，
## 工程文件本就该落在用户自己的目录里（导出打包后 `res://` 更是读不到的）。
func _build_dialogs() -> void:
	_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_open_dialog.file_selected.connect(open_project)
	_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_save_dialog.file_selected.connect(_on_save_path_selected)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "未保存的改动"
	_confirm.cancel_button_text = "返回"
	# 对话框是独立的 Window，不会从 Node3D 父链上继承主题，得手挂一份 —— 否则它会顶着一套
	# 与全应用无关的默认皮，风格统一在这里破功。
	_confirm.theme = QVoxUi.theme()
	add_child(_confirm)


func _make_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.current_dir = _default_dir()
	# 与 _confirm 同因：对话框的父链是 Node3D，主题传不下来，不挂就是一套 Godot 默认皮
	#（本应用是内嵌子窗口样式，所以这层皮是看得见的）。 Theme 是**叠加**而不是替换：
	# 本主题没定义的条目（Tree / LineEdit / OptionButton）继续走引擎默认值，不会把对话框弄坏。
	d.theme = QVoxUi.theme()
	d.add_filter("*.%s" % QVoxProject.EXTENSION, "QVoxelier 工程")
	d.title = "打开工程" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存工程"
	# 引擎自建文案在游戏进程里没有内置翻译，会显示成 "Save" / "Cancel"。
	# 其余（Path: / 列头 / 新建文件夹）同样来自引擎，改不动；但这两个是每次操作都要读、
	# 要按的，必须跟界面同一种语言。
	d.ok_button_text = "打开" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存"
	d.cancel_button_text = "取消"
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


## 把 `.qvox` 拖进窗口即打开（建模时最顺手的一步）；非工程文件一律忽略。
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if QVoxProject.is_project_path(f):
			# 拖进来同样是"整体换掉当前世界"，走 request_open 才有那道未保存确认。
			request_open(f)
			return
	hud.flash("只认得 .%s 工程文件" % QVoxProject.EXTENSION)


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
	if not _dirty:
		_dirty = true
		_update_title()
	_refresh_hud()


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
	_palette.set_current(_material_id)
	hud.set_material_id(_material_id)


## 世界的材质表 → 调色板用的颜色数组：**下标即材质 ID**，0 位留空气占位。
## 不直接用 default_palette，是因为打开别人的工程时色板得跟着工程走。
func _material_colors(w: QVoxWorld) -> Array[Color]:
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
