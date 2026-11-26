@tool
class_name QVoxelViewCamera
extends Camera3D
## 建模视口的相机：轨道手感 + 投影模式 + 标准视图预设。

## 视角有变（轨道 / 平移 / 缩放 / 换视图 / 换镜头）。
signal view_changed

## 镜头类型。
enum Lens { PERSPECTIVE, ORTHO }

## 标准视图。
enum View { FREE, FRONT, BACK, LEFT, RIGHT, TOP, BOTTOM, ISO }

const LENS_NAMES := {
	Lens.PERSPECTIVE: "透视",
	Lens.ORTHO: "正交",
}

const VIEW_NAMES := {
	View.FREE: "自由",
	View.FRONT: "前",
	View.BACK: "后",
	View.LEFT: "左",
	View.RIGHT: "右",
	View.TOP: "顶",
	View.BOTTOM: "底",
	View.ISO: "等轴",
}

## 各标准视图的 (yaw, pitch)，单位**度**（弧度在运行时换算 —— 常量表里放浮点数最稳）。
const VIEW_ANGLES_DEG := {
	View.FRONT: Vector2(0.0, 0.0),
	View.BACK: Vector2(180.0, 0.0),
	View.RIGHT: Vector2(90.0, 0.0),
	View.LEFT: Vector2(-90.0, 0.0),
	View.TOP: Vector2(0.0, 89.0),
	View.BOTTOM: Vector2(0.0, -89.0),
	View.ISO: Vector2(45.0, 35.264),
}

## 注视角（世界坐标）。
var target := Vector3.ZERO
## 绕世界 Y 的方位角（弧度）。
var yaw := 0.0
## 俯仰角（弧度）。
var pitch := deg_to_rad(25.0)
## 注视点到相机的距离（世界单位）。
var distance := 6.0

## 当前镜头类型（命名见类文档：不能叫 Projection）。
var lens := Lens.PERSPECTIVE
## 当前标准视图（用户一转动就回落到 FREE）。
var view := View.FREE
## 正交下的可见**高度**（世界单位）。
var ortho_height := 6.0

@export_group("手感")
## 每像素轨道旋转量（弧度）。
@export var orbit_per_pixel := 0.0075
## 偏航速度倍率（水平拖动比垂直更"钝"一点更稳）。
@export var yaw_gain := 1.0
## 滚轮每一格的缩放倍率（> 1：向上滚 = 拉近）。
@export var zoom_step := 1.15
## 最近 / 最远距离。
@export var min_distance := 0.6
@export var max_distance := 200.0
## 正交可见高度的上下限（同距离，两端都夹住）。
@export var min_ortho_height := 0.6
@export var max_ortho_height := 200.0
## pitch 的两端极限（留 1°：完全垂直时 look_at 的 up 向量退化）。
@export var pitch_limit := deg_to_rad(89.0)
## 取景时的留白倍率（1.0 = 包围球正好贴边）。
@export var frame_margin := 1.25

## 切换镜头类型。
func set_lens(mode: Lens) -> void:
	if mode == lens:
		return
	if mode == Lens.ORTHO:
		ortho_height = clampf(_perspective_height(), min_ortho_height, max_ortho_height)
	lens = mode
	_apply()

## 正交 ⇄ 透视互换（小键盘 5 与视图栏的"切换"语义）。
func toggle_lens() -> void:
	set_lens(Lens.PERSPECTIVE if lens == Lens.ORTHO else Lens.ORTHO)

## 应用标准视图。
func apply_view(v: View) -> void:
	if not VIEW_ANGLES_DEG.has(v):
		return
	var angles: Vector2 = VIEW_ANGLES_DEG[v]
	yaw = deg_to_rad(angles.x)
	pitch = deg_to_rad(angles.y)
	view = v
	_apply()

## 绕注视点转（参数是鼠标像素位移，右/下为正）。
func orbit_by_pixels(relative: Vector2) -> void:
	yaw -= relative.x * orbit_per_pixel * yaw_gain
	pitch += relative.y * orbit_per_pixel
	pitch = clampf(pitch, -pitch_limit, pitch_limit)
	view = View.FREE
	_apply()

## 平移：把注视点沿屏幕右/上轴推。
func pan_by_pixels(relative: Vector2) -> void:
	if not is_inside_tree():
		return
	var h := get_viewport().get_visible_rect().size.y
	if h <= 0.0:
		return
	var per_pixel := view_height() / h
	target += global_transform.basis.x * (-relative.x * per_pixel)
	target += global_transform.basis.y * (relative.y * per_pixel)
	_apply()

## 缩放。
func zoom_by_steps(steps: float) -> void:
	var factor := pow(zoom_step, -steps)
	if lens == Lens.ORTHO:
		ortho_height = clampf(ortho_height * factor, min_ortho_height, max_ortho_height)
	else:
		distance = clampf(distance * factor, min_distance, max_distance)
	_apply()

## 俯仰微调（滚轮用）。
func pitch_by_degrees(deg: float) -> void:
	pitch = clampf(pitch + deg_to_rad(deg), -pitch_limit, pitch_limit)
	view = View.FREE
	_apply()

## 偏航微调（水平滚轮 = 触摸板双指左右滑）。
func yaw_by_degrees(deg: float) -> void:
	yaw -= deg_to_rad(deg)
	view = View.FREE
	_apply()

## 按比例连续缩放（捏合手势用）。
func zoom_by_ratio(ratio: float) -> void:
	if ratio <= 0.0:
		return
	if lens == Lens.ORTHO:
		ortho_height = clampf(ortho_height / ratio, min_ortho_height, max_ortho_height)
	else:
		distance = clampf(distance / ratio, min_distance, max_distance)
	_apply()

## 当前屏幕竖直方向覆盖的世界高度。
func view_height() -> float:
	if lens == Lens.ORTHO:
		return ortho_height
	return _perspective_height()

## 透视下的成像高度（距离与 FOV 决定）。
func _perspective_height() -> float:
	return 2.0 * distance * tan(deg_to_rad(fov) * 0.5)

## 取景：让整块包围盒落进画面（新建 / 载入 / 按 Home 时用）。
func frame_aabb(aabb: AABB, reset_angles := false) -> void:
	if aabb.size == Vector3.ZERO:
		return
	target = aabb.get_center()
	var radius := aabb.get_longest_axis_size() * 0.5
	var half := deg_to_rad(fov) * 0.5
	var framed := clampf(radius / maxf(sin(half), 0.001) * frame_margin, min_distance, max_distance)
	distance = framed
	# 正交下距离不参与成像，取景体现为可见高度；两者同时写，切换镜头即对齐。
	ortho_height = clampf(2.0 * framed * tan(half), min_ortho_height, max_ortho_height)
	if reset_angles:
		yaw = 0.0
		pitch = deg_to_rad(25.0)
		view = View.FREE
	_apply()

## 把 target/yaw/pitch/distance/lens 落到节点变换上。
func _apply() -> void:
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	global_position = target + offset * distance
	look_at(target, Vector3.UP)
	if lens == Lens.ORTHO:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = ortho_height
	else:
		projection = Camera3D.PROJECTION_PERSPECTIVE
	view_changed.emit()

func _ready() -> void:
	# 长焦：观感配方统一给（快照相机也是本类，FOV 因此天然一致）。
	fov = QVoxelRenderPreset.FOV
	if not Engine.is_editor_hint():
		# 建模视口要能看清最近的体素：远端按最远距离给足。
		near = 0.01
		far = maxf(far, 4000.0)
	_apply()
