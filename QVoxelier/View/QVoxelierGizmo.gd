@tool
class_name QVoxelierGizmo
extends Control
## 朝向指示器（视口右下角）—— 把"现在正朝哪看"画成一组轴。
## 【它解决什么问题】透视图里没有"上/前后"的刻度：用户转了几圈之后，无法从模型本身判断
## 现在看的是正面还是背面（体素模型常常左右对称）。于是拉完一个形状后，切到"前视图"一看
## 才发现是反的 —— 这类返工全部来自"不知道当前朝向"。六个轴尖正好把这信息补上。
## 【为什么是轴而不是小方块】小方块要靠明暗与棱边读出朝向，在 24px 见方里几乎不可辨；
## 轴尖带字母（X/Y/Z）在任何尺寸下都能一眼定位，且天然可点（点哪根轴就转到那一侧）——
## 与视图栏的预设按钮是同一个动作的两个入口，符合"每个操作都有可见按钮"的约定。
## 【屏幕投影怎么算】不新开一个 3D 视口（那要再付一份渲染开销，还要同步相机）。
## 相机基（x=右, y=上, z=朝后）是正交归一矩阵，故"世界轴在相机本地系下的方向"
## = basis.transposed() * axis（转置即逆）。取其 x/y 分量就是屏幕方向，z 分量决定前后遮挡。

## 点了某个轴尖，请求切到那一侧的视图（值同 QVoxelViewCamera.View）。
signal view_requested(view: int)
## 在盘上按住拖动，请求自由旋转视角（位移小于阈值的"点击"仍走 view_requested）。
signal orbit_requested(relative: Vector2)

const AXIS_COLORS := [
	Color(1.0, 0.42, 0.42),   # X
	Color(0.48, 0.92, 0.55),  # Y
	Color(0.45, 0.66, 1.0),   # Z
]
const AXIS_NAMES := ["X", "Y", "Z"]
## 每根轴的两个方向 → 视图。+Z 从眼前指出屏幕（前视图的相机就在 +Z 侧）。
const AXIS_VIEWS := [
	[QVoxelViewCamera.View.RIGHT, QVoxelViewCamera.View.LEFT],
	[QVoxelViewCamera.View.TOP, QVoxelViewCamera.View.BOTTOM],
	[QVoxelViewCamera.View.FRONT, QVoxelViewCamera.View.BACK],
]
## 拖过这个像素数才算"转视角"，否则仍是"切视图的点击" —— 点击前手指总会抖几像素。
const DRAG_START_PX := 4.0

## 指示器要看着的相机（由 App 注入）。
var camera: Camera3D

## 右侧要让开的宽度（右列抽屉的实际宽度 + 一条缝），由 App 装配时报进来；
## 默认退回设计宽度 —— 单独跑时也摆得对。HUD 的两块浮层吃的是同一个数。
## 【为什么不能按常量摆】右列宽度是**内容驱动**的（同工具坞，见 QVoxelierDock._fit），
## 展开「层级」后实测 228px；而指示器是 160px 见方钉在右下角 —— 按常量摆会被整块压住，
## 只透过面板的半透明底露出几根轴的鬼影。
var right_inset := float(QVoxelUi.dock_width() + QVoxelUi.space_l() + QVoxelUi.space_m()):
	set(v):
		right_inset = v
		_sync_rect()

## 底部让位（动画面板展开时抬高它）。
var bottom_inset := 0.0:
	set(v):
		bottom_inset = v
		_sync_rect()

var _last_basis := Basis()
var _tip_radius := 0.0
var _tips: Array = []        # [{pos: Vector2, view: int}]
var _press := false          # 左键正按在盘上（拖拽中）
var _dragged := false        # 本次按下已越过点击/拖拽的分界阈值
## 鼠标是否悬在本控件上。它是"补充工具"，平时压暗、不抢视线；悬停时才提亮。
var _hover := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 四边锚点都钉在右下，于是窗口缩放时它跟着那个角走。
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	_sync_rect()
	mouse_entered.connect(func(): _hover = true; queue_redraw())
	mouse_exited.connect(func(): _hover = false; queue_redraw())


## 贴右下角：让开状态栏与右列抽屉（宽度由 right_inset 报进来）。
## 尺寸只占 3 个命中区见方 —— 它只是"朝向补充"，不该抢模型的地方。
func _sync_rect() -> void:
	var s := 3 * QVoxelUi.hit_size()
	custom_minimum_size = Vector2(s, s)
	offset_right = -right_inset
	offset_bottom = -(QVoxelUi.status_height() + QVoxelUi.space_s() + bottom_inset)
	offset_left = offset_right - s
	offset_top = offset_bottom - s
	_tip_radius = s * 0.5 - QVoxelUi.hit_size() * 0.34


func _process(_delta: float) -> void:
	if camera == null:
		return
	# 只在朝向真的变了时重画：这个控件每帧都在视口上，无谓的重绘没必要。
	if camera.global_transform.basis.is_equal_approx(_last_basis):
		return
	_last_basis = camera.global_transform.basis
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	# 平时压暗（dim < 1）、悬停时提亮：它是补充工具，不该与模型争视线。
	var dim := 1.0 if _hover else 0.55
	# 底盘：透过 3D 视口看它，没有底衬的话轴会与模型糊在一起。取界面同一族的冷灰黑，
	# 但压得更暗、更透 —— 六个轴尖已经占满红/绿/蓝，底衬若带上台面色就会像"第七根轴"。
	draw_circle(center, size.x * 0.5, Color(0.035, 0.043, 0.058, (0.5 if _hover else 0.24)))

	if camera == null:
		return
	var local_basis := camera.global_transform.basis.transposed()
	_tips.clear()

	# 六个轴尖按"离视线的远近"排序：先画远的，后画近的，于是朝向观察者的那几根压在前。
	var entries := []
	for axis in 3:
		for sign_ in [1.0, -1.0]:
			var dir := Vector3.ZERO
			dir[axis] = sign_
			var local := local_basis * dir
			entries.append({
				"axis": axis,
				"sign": sign_,
				"depth": local.z,
				"pos": center + Vector2(local.x, -local.y) * _tip_radius,
			})
	entries.sort_custom(func(a, b): return a.depth > b.depth)

	var font := ThemeDB.fallback_font
	var font_size := QVoxelUi.FONT_S
	for e in entries:
		# 背向观察者的轴压暗：它们贴在底盘后面，画太亮会显得朝向反了。
		var facing := clampf(0.5 - e.depth * 0.5, 0.25, 1.0) * dim
		var color: Color = AXIS_COLORS[e.axis]
		color.a = facing
		draw_line(center, e.pos, color, 2.0, true)
		# 轴尖：正方向实心 + 字母，负方向空心 —— 一个字母就分得出两端。
		if e.sign > 0.0:
			draw_circle(e.pos, QVoxelUi.FONT_S * 0.85, color)
			draw_string(font, e.pos - Vector2(font_size * 0.32, -font_size * 0.34),
					AXIS_NAMES[e.axis], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
					Color(0.06, 0.07, 0.09, facing))
		else:
			draw_arc(e.pos, QVoxelUi.FONT_S * 0.85, 0, TAU, 16, color, 1.5, true)
		_tips.append({"pos": e.pos, "view": AXIS_VIEWS[e.axis][0 if e.sign > 0.0 else 1],
				"depth": e.depth, "color": color})


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press = true
			_dragged = false
			accept_event()
		elif _press:
			# 松手时才判型：位移不足阈值 = 点击轴尖切视图，越过 = 拖拽转视角（按下后视口
			# 会把 motion 持续派发给本控件，拖出盘外也不中断）。
			_press = false
			if not _dragged:
				var hit := _nearest_tip(event.position)
				# 点轴尖 = 切到那一侧；点中心的盘面 = 等轴视图（补齐坐标系唯一给不了的预设）。
				view_requested.emit(_tips[hit].view if hit >= 0 else QVoxelViewCamera.View.ISO)
			accept_event()
	elif event is InputEventMouseMotion and _press:
		if _dragged or event.relative.length() >= DRAG_START_PX:
			_dragged = true
			orbit_requested.emit(event.relative)
			accept_event()


## 命中的轴尖（只认"最近的且在阈值内"的那个）——轴尖挨得近，取最近最不容易误点。
func _nearest_tip(at: Vector2) -> int:
	var best := -1
	var best_d := QVoxelUi.hit_size() * 0.6
	for i in _tips.size():
		var d: float = at.distance_to(_tips[i].pos)
		if d < best_d:
			best_d = d
			best = i
	return best
