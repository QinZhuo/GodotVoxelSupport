@tool
class_name QVoxelViewCamera
extends Camera3D
## 建模视口的相机：轨道手感 + 投影模式 + 标准视图预设。
## 【为什么是轨道相机】建模时的"视点"是模型的一部分：用户想的是"绕到模型左侧看一眼"，
## 而不是"让相机转 30°"。轨道相机把注视点留在模型上，转完还在看模型 —— 这是建模软件的
## 通用手感（MagicaVoxel / Blender / 3ds Max 的默认视角都是这一类）。
## 【为什么不用框架的 CameraBrain3D】框架那套解决的是"多机位竞争与混合"（跟随 / 过场 /
## 不同面板切不同视角）。建模视口只有一个机位，且它的"手感参数"（轨道速度 / 缩放曲线）
## 按 LAYERS 的划分本就属于项目侧 —— 引入机位竞争只会多一层间接。
## 【正交为什么要独立一个高度】正交下改距离**不改变成像大小**，只改变裁切深度：
## 若让 size 跟着距离走，拉近就变成"模型被近平面切开"。故正交可见高度是独立状态
## （Blender 的 ortho_scale / Unity 的 orthographicSize 同理），进正交时从透视高度
## 同步一次，于是来回切换投影不会跳变。
## 【手感约定】三个自由度各自独立，互不叠加：
##   ① 轨道：绕注视点转（yaw 绕世界 Y，pitch 抬到俯视/仰视，两端留 1° 防退化）；
##   ② 平移：把注视点沿**屏幕轴**推 —— 每像素对应的世界距离按当前可见高度反算，
##      于是"拖住的那一点跟着手走"，与缩放级别无关；
##   ③ 缩放：改距离（透视）/ 改可见高度（正交）—— 镜头本身不变。
## 【为什么枚举叫 Lens 而不叫 Projection】`Projection` 是引擎内建的 4×4 矩阵类型名，
## 用它当枚举名会直接编译不过；而 `Camera3D` 自带 `projection` 属性，任何 `set_projection()`
## 都会被当成"试图遮蔽内建 setter"。换个名字（镜头）语义一样准确，还省掉一堆遮蔽告警。

## 镜头类型。透视有纵深感，正交没有近大远小 —— 体素对齐、量比例必须用正交。
enum Lens { PERSPECTIVE, ORTHO }

## 标准视图。除 FREE 外都只改角度（不动注视点与缩放），故可来回快切。
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
## 等轴用真正的 35.264°（arctan(1/√2)）：这个角度下三条世界轴在屏幕上等长，
## 是"等轴"而不是"随便斜一下"。
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
## 绕世界 Y 的方位角（弧度）。0 = 从 +Z 看向 -Z。
var yaw := 0.0
## 俯仰角（弧度）。正 = 相机在注视点**上方**（俯视）。
var pitch := deg_to_rad(25.0)
## 注视点到相机的距离（世界单位）。透视下即成像大小，正交下只管裁切深度。
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
## 最近 / 最远距离。近端留得下单个体素，远端看得全 256³ 的模型。
@export var min_distance := 0.05
@export var max_distance := 4000.0
## 正交可见高度的上下限。
@export var min_ortho_height := 0.05
@export var max_ortho_height := 4000.0
## pitch 的两端极限（留 1°：完全垂直时 look_at 的 up 向量退化）。
@export var pitch_limit := deg_to_rad(89.0)
## 取景时的留白倍率（1.0 = 包围球正好贴边）。
@export var frame_margin := 1.25


## 切换镜头类型。进正交时把可见高度从当前透视高度同步一次，来回切换不跳变。
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


## 应用标准视图。FREE 是"不改变角度"的标签，不在这里处理。
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


## 平移：把注视点沿屏幕右/上轴推。每像素的世界距离由当前可见高度反算 ——
## "拖住的那一点跟着手走"，才是看得住的手感。
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


## 缩放。steps > 0 = 拉近。透视改距离，正交改可见高度（改距离在正交下只会裁切）。
func zoom_by_steps(steps: float) -> void:
	var factor := pow(zoom_step, -steps)
	if lens == Lens.ORTHO:
		ortho_height = clampf(ortho_height * factor, min_ortho_height, max_ortho_height)
	else:
		distance = clampf(distance * factor, min_distance, max_distance)
	_apply()


## 俯仰微调（滚轮用）。deg > 0 = 抬头。滚轮一维只能给俯仰，偏航留给水平滚轮（触摸板双指左右滑）。
func pitch_by_degrees(deg: float) -> void:
	pitch = clampf(pitch + deg_to_rad(deg), -pitch_limit, pitch_limit)
	view = View.FREE
	_apply()


## 偏航微调（水平滚轮 = 触摸板双指左右滑）。
func yaw_by_degrees(deg: float) -> void:
	yaw -= deg_to_rad(deg)
	view = View.FREE
	_apply()


## 按比例连续缩放（捏合手势用）。ratio > 1 = 拉近。与步进式共用同一条钳制与生效路径。
func zoom_by_ratio(ratio: float) -> void:
	if ratio <= 0.0:
		return
	if lens == Lens.ORTHO:
		ortho_height = clampf(ortho_height / ratio, min_ortho_height, max_ortho_height)
	else:
		distance = clampf(distance / ratio, min_distance, max_distance)
	_apply()


## 当前屏幕竖直方向覆盖的世界高度。平移与取景都按它换算 —— 透视/正交只有这一处分岔。
func view_height() -> float:
	if lens == Lens.ORTHO:
		return ortho_height
	return _perspective_height()


## 透视下的成像高度（距离与 FOV 决定）。
func _perspective_height() -> float:
	return 2.0 * distance * tan(deg_to_rad(fov) * 0.5)


## 取景：让整块包围盒落进画面（新建 / 载入 / 按 Home 时用）。
## 用包围球半径与竖直 FOV 算距离 —— 球在任何朝向都被完整罩住，故转视角不会忽然出画。
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


## 把 target/yaw/pitch/distance/lens 落到节点变换上。所有入口最后都走这里 ——
## 状态与变换只有这一处换算，不存在"改了状态没生效"的第二种路径。
## offset 是**注视点 → 相机**的方向（相机在 target + offset * distance 处回头看），
## 故 offset.y = sin(pitch)：pitch 为正 = 相机在注视点上方（俯视）—— 与字段注释同一套约定。
func _apply() -> void:
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	global_position = target + offset * distance
	look_at(target, Vector3.UP)
	if lens == Lens.ORTHO:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = ortho_height
	else:
		projection = Camera3D.PROJECTION_PERSPECTIVE


func _ready() -> void:
	if not Engine.is_editor_hint():
		# 建模视口要能看清最近的体素：远端按最远距离给足。
		near = 0.01
		far = maxf(far, 4000.0)
	_apply()
