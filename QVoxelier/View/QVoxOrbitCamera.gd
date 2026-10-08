@tool
class_name QVoxOrbitCamera
extends Camera3D
## 建模视口的轨道相机（Orbit / Turntable）：绕一个**注视点**转，而不是绕自己转。
##
## 【为什么不是自由视角】建模时的"视点"是模型的一部分：用户想的是"绕到模型左侧看一眼"，
## 而不是"让相机转 30°"。轨道相机把注视点留在模型上，转完还在看模型 —— 这是建模软件的
## 通用手感（MagicaVoxel / Blender / 3ds Max 的默认视角都是这一类）。
##
## 【为什么不用框架的 CameraBrain3D】框架那套解决的是"多机位竞争与混合"（跟随 / 过场 /
## 不同面板切不同视角）。建模视口只有一个机位，且它的"手感参数"（轨道速度 / 缩放曲线）
## 按 LAYERS 的划分本就属于项目侧 —— 引入机位竞争只会多一层间接。
##
## 【手感约定】三个自由度各自独立，互不叠加：
##   ① 轨道：绕注视点转（yaw 绕世界 Y，pitch 抬到俯视/仰视，两端留 1° 防退化）；
##   ② 平移：把注视点沿**屏幕轴**推 —— 每像素对应的世界距离按当前距离与 FOV 反算，
##      于是"拖住的那一点跟着手走"，与缩放级别无关；
##   ③ 缩放：改距离（不改 FOV）—— 透视不变，用户看到的永远是同一支镜头。

## 注视点（世界坐标）。
var target := Vector3.ZERO
## 绕世界 Y 的方位角（弧度）。0 = 从 +Z 看向 -Z。
var yaw := 0.0
## 俯仰角（弧度）。正 = 相机在注视点**上方**（俯视）。
var pitch := deg_to_rad(25.0)
## 注视点到相机的距离（世界单位）。
var distance := 6.0

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
## pitch 的两端极限（留 1°：完全垂直时 look_at 的 up 向量退化）。
@export var pitch_limit := deg_to_rad(89.0)
## 取景时的留白倍率（1.0 = 包围球正好贴边）。
@export var frame_margin := 1.25


## 绕注视点转（参数是鼠标像素位移，右/下为正）。
func orbit_by_pixels(relative: Vector2) -> void:
	yaw -= relative.x * orbit_per_pixel * yaw_gain
	pitch += relative.y * orbit_per_pixel
	pitch = clampf(pitch, -pitch_limit, pitch_limit)
	_apply()


## 平移：把注视点沿屏幕右/上轴推。每像素的世界距离由当前距离与 FOV 反算 ——
## "拖住的那一点跟着手走"，才是看得住的手感。
func pan_by_pixels(relative: Vector2) -> void:
	if not is_inside_tree():
		return
	var h := get_viewport().get_visible_rect().size.y
	if h <= 0.0:
		return
	var per_pixel := 2.0 * distance * tan(deg_to_rad(fov) * 0.5) / h
	target += global_transform.basis.x * (-relative.x * per_pixel)
	target += global_transform.basis.y * (relative.y * per_pixel)
	_apply()


## 缩放：改距离。steps > 0 = 拉近。
func zoom_by_steps(steps: float) -> void:
	distance = clampf(distance * pow(zoom_step, -steps), min_distance, max_distance)
	_apply()


## 取景：让整块包围盒落进画面（新建 / 载入 / 按 Home 时用）。
## 用包围球半径与竖直 FOV 算距离 —— 球在任何朝向都被完整罩住，故转视角不会忽然出画。
func frame_aabb(aabb: AABB, reset_angles := false) -> void:
	if aabb.size == Vector3.ZERO:
		return
	target = aabb.get_center()
	var radius := aabb.get_longest_axis_size() * 0.5
	var half := deg_to_rad(fov) * 0.5
	distance = clampf(radius / maxf(sin(half), 0.001) * frame_margin, min_distance, max_distance)
	if reset_angles:
		yaw = 0.0
		pitch = deg_to_rad(25.0)
	_apply()


## 把 target/yaw/pitch/distance 落到节点变换上。所有入口最后都走这里 ——
## 状态与变换只有这一处换算，不存在"改了状态没生效"的第二种路径。
##
## offset 是**注视点 → 相机**的方向（相机在 target + offset * distance 处回头看），
## 故 offset.y = sin(pitch)：pitch 为正 = 相机在注视点上方（俯视）—— 与字段注释同一套约定。
func _apply() -> void:
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	global_position = target + offset * distance
	look_at(target, Vector3.UP)


func _ready() -> void:
	if not Engine.is_editor_hint():
		# 建模视口要能看清最近的体素：远端按最远距离给足。
		near = 0.01
		far = maxf(far, 4000.0)
	_apply()
