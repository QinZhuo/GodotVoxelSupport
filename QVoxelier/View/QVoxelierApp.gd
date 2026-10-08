@tool
class_name QVoxelierApp
extends Node3D
## 建模视口的应用壳：**装配 + 输入翻译 + 快捷键**，不含任何算法（DESIGN §4.1 的 View 层）。
##
## 【它只做三件事】
##   ① 装配：新建世界/对象 → 建会话 → 把显示层交给渲染器、把网格交给地板、把会话交给状态栏；
##   ② 翻译：鼠标事件 → 相机射线 → 网格拾取 → `QVoxEditSession` 的手势（begin/drag/release）；
##   ③ 快捷键：工具表里的热键切笔、[ ] 改笔刷、Ctrl+Z / Ctrl+Shift+Z 撤销重做、Esc 取消、Home 取景。
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

## 当前世界与编辑会话（装配产物；换模型时整体重建）。
var world: QVoxWorld
var session: QVoxEditSession

var _material_id := 1
var _stroke := false
var _erase := false
var _orbit := false
var _pan := false

const ACTION_UNDO := &"qvoxelier_undo"
const ACTION_REDO := &"qvoxelier_redo"
const ACTION_BRUSH_UP := &"qvoxelier_brush_up"
const ACTION_BRUSH_DOWN := &"qvoxelier_brush_down"


# ----------------------------------------------------------------------------
# 装配
# ----------------------------------------------------------------------------

func _ready() -> void:
	_bind_actions()
	new_model()
	# 编辑器里只装配外观（网格地板与取景），输入留给编辑器自己 —— @tool 脚本不该抢编辑器的键。
	if Engine.is_editor_hint():
		return
	hud.session = session


## 新建一个空模型（grid 为 ZERO 时用导出的 grid_size）：建世界 → 建对象 → 建会话 → 接线。
## 载入 / 换模型也走这里 —— "装配"只有这一条路径，不存在第二套初始化。
func new_model(grid := Vector3i.ZERO) -> void:
	var g: Vector3i = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else grid_size
	world = QVoxWorld.create_empty()
	for c in default_palette:
		world.add_material(c)
	var obj := world.create_object("Model", g)
	session = QVoxEditSession.create_for(obj, world)
	session.request_render_update = model.request_update
	session.history.changed.connect(_refresh_hud)
	_material_id = 1

	model.voxel_scale = world.voxel_size()
	model.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	model.data = session.data
	grid_floor.grid_size = obj.grid_size
	grid_floor.voxel_scale = model.voxel_scale

	hud.session = session
	frame_view()
	_refresh_hud()


## 取景：让整块网格落进画面（新建 / Home 键）。
func frame_view() -> void:
	if session == null:
		return
	var size := Vector3(session.object.grid_size) * model.voxel_scale
	camera.frame_aabb(model.global_transform * AABB(Vector3.ZERO, size), true)


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
			if e.pressed:
				_begin_stroke(e.position, false)
			else:
				_end_stroke()
		MOUSE_BUTTON_RIGHT:
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
	# 撤销 / 重做走框架 InputTool（key_event 管修饰键，且动作名可被重映射）。
	# 模式热键直接查工具表 —— 表即配置，不需要修饰键语义，也就没必要再声明一遍动作名。
	if e.is_action_pressed(ACTION_UNDO):
		_undo()
	elif e.is_action_pressed(ACTION_REDO):
		_redo()
	elif e.is_action_pressed(ACTION_BRUSH_UP):
		_set_brush(session.tool.brush_size + 1)
	elif e.is_action_pressed(ACTION_BRUSH_DOWN):
		_set_brush(session.tool.brush_size - 1)
	elif e.keycode == KEY_ESCAPE:
		_cancel()
	elif e.keycode == KEY_HOME:
		frame_view()
		hud.flash("已取景")
	elif e.keycode >= KEY_1 and e.keycode <= KEY_8:
		_set_material(e.keycode - KEY_0)
	else:
		_switch_by_hotkey(e.keycode)


func _switch_by_hotkey(key: Key) -> void:
	for row in QVoxBrushTool.MODES:
		if row.hotkey == key:
			session.tool.set_mode(row.mode)
			hud.flash("工具：" + row.label)
			_refresh_hud()
			return


## 把屏幕坐标解成"这一次落笔打在哪"：相机射线 → 体素空间 → 网格拾取（含空图落在地板上）。
func _pick_at(screen: Vector2) -> QVoxBrushTool.Pick:
	var scale := model.voxel_scale
	var origin: Vector3 = model.to_local(camera.project_ray_origin(screen)) / scale
	var dir: Vector3 = model.global_transform.basis.inverse() * camera.project_ray_normal(screen)
	var info := QVoxGridPick.hit(session.data, origin, dir, session.object.grid_size)
	return session.pick_from_hit(info, _erase, _material_id)


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


# ----------------------------------------------------------------------------
# 状态栏
# ----------------------------------------------------------------------------

func _refresh_hud() -> void:
	if hud.session == session:
		hud.refresh()


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
