@tool
class_name QVoxelGridFloor
extends MeshInstance3D
## 网格背景面：给"当前可作为落笔面的那些面"描边框，并**按角度渐变**（越正对背景越完整）。
## 【谁是背景面】面的外法线与"该面指向相机"的方向夹角越大 = 越背离镜头 = 越适合作为落笔背景：
##    · 底面阈值 90°（相机在上方即可，优先级最高）；
##    · 其余面（含顶面）阈值 145°。
## 边框的**显示长度与透明度随角度渐变**：刚好达标 ~ 完整；偏离时只露出一小段并半透明 ——
## 于是"背景面"随视角平滑过渡，而不是突然出现 / 消失。底面在相机转到下方时也会随之退场。
## 【坐标约定】顶点用**体素单位**，节点 scale = voxel_scale。

@export var grid_size := Vector3i(32, 32, 32):
	set(v):
		grid_size = v
		rebuild()
@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		rebuild()

## 判定背景面用的相机（由 App 注入）。
var camera: Camera3D

const FLOOR_ANGLE := 90.0
const OTHER_ANGLE := 145.0
## 渐变带宽（度）：只有**很接近阈值**的这一小段角度才半透明；再远就完全透明。
const FADE_BAND := 16.0
## 低于它视为该面不作背景面（拾取也不用它）。
const MIN_FACTOR := 0.5

## 背景面边框色（**完全不透明**）：只有作背景面的那几条棱才实；其余靠顶点透明度渐隐到全透明。
@export var border_color := Color(QVoxelUi.ACCENT, 1.0):
	set(v):
		border_color = v
		rebuild()
## 背景面边框显隐（顶栏「网格线」开关）。
@export var borders_visible := true:
	set(v):
		borders_visible = v
		rebuild()

## 6 个面：外法线。顺序：0 底面 / 1 顶面 / 2 -X / 3 +X / 4 -Z / 5 +Z。
const _FACES := [
	Vector3(0, -1, 0), Vector3(0, 1, 0),
	Vector3(-1, 0, 0), Vector3(1, 0, 0),
	Vector3(0, 0, -1), Vector3(0, 0, 1),
]

## 12 条棱（底 4 / 顶 4 / 竖 4）与每条棱两侧的面下标（与 _CAGE_EDGES 一一对应）。
const _CAGE_EDGES := [
	[0, 1], [1, 2], [2, 3], [3, 0],
	[4, 5], [5, 6], [6, 7], [7, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]
const _CAGE_EDGE_FACES := [
	[0, 4], [0, 3], [0, 5], [0, 2],   # 底 4（底面 + 各侧墙）
	[1, 4], [1, 3], [1, 5], [1, 2],   # 顶 4（顶面 + 各侧墙）
	[2, 4], [3, 4], [3, 5], [2, 5],   # 竖 4（两堵侧墙）
]

var _line_mat: StandardMaterial3D
var _last_cam := Vector3.INF


## 面 i 的背景程度 0~1（按角度渐变）。0 = 不作背景面。
func face_factor(i: int) -> float:
	if camera == null:
		return 1.0 if i == 0 else 0.0
	var nw: Vector3 = (global_transform.basis * _FACES[i]).normalized()
	var to_cam: Vector3 = (camera.global_position - global_transform * _face_center(i)).normalized()
	var ang := rad_to_deg(acos(clampf(nw.dot(to_cam), -1.0, 1.0)))
	var thr := FLOOR_ANGLE if i == 0 else OTHER_ANGLE
	return smoothstep(thr - FADE_BAND, thr, ang)


## 当前可作落笔面的面（边框可见的那些）——供网格拾取对齐，保证"有边框的面才作画笔地面"。
func visible_faces() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in _FACES.size():
		if face_factor(i) > MIN_FACTOR:
			out.append(i)
	return out


func rebuild() -> void:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		mesh = null
		return
	scale = Vector3.ONE * voxel_scale
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if borders_visible:
		_build_cage(verts, colors)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh = m
	set_surface_override_material(0, _line_material())


## 整块网格的 12 条棱：**长度恒定**，透明度**按棱**判定 ——
## 一条棱只要属于某个背景面（= 它两侧的面里有一个当前是背景面）就不透明，否则**全透明**。
## 于是只有"背景面的边框"看得见，其余（含前面那些非背景面的棱）完全不画；接近阈值的角度半透明。
func _build_cage(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var s := Vector3(grid_size)
	var corners := [
		Vector3(0, 0, 0), Vector3(s.x, 0, 0), Vector3(s.x, 0, s.z), Vector3(0, 0, s.z),
		Vector3(0, s.y, 0), Vector3(s.x, s.y, 0), Vector3(s.x, s.y, s.z), Vector3(0, s.y, s.z),
	]
	for i in _CAGE_EDGES.size():
		var e: Array = _CAGE_EDGES[i]
		var fs: Array = _CAGE_EDGE_FACES[i]
		var f := maxf(face_factor(fs[0]), face_factor(fs[1]))
		if f <= 0.01:
			continue  # 不属于任何背景面 → 全透明（不画）
		_line(verts, colors, corners[e[0]], corners[e[1]], Color(border_color, border_color.a * f))


func _face_center(i: int) -> Vector3:
	var s := Vector3(grid_size)
	match i:
		0:
			return Vector3(s.x * 0.5, 0.0, s.z * 0.5)
		1:
			return Vector3(s.x * 0.5, s.y, s.z * 0.5)
		2:
			return Vector3(0.0, s.y * 0.5, s.z * 0.5)
		3:
			return Vector3(s.x, s.y * 0.5, s.z * 0.5)
		4:
			return Vector3(s.x * 0.5, s.y * 0.5, 0.0)
	return Vector3(s.x * 0.5, s.y * 0.5, s.z)


## 某个面的 4 个角（顺序成环），体素单位。
func _face_corners(i: int) -> Array:
	var s := Vector3(grid_size)
	match i:
		0:
			return [Vector3(0, 0, 0), Vector3(s.x, 0, 0), Vector3(s.x, 0, s.z), Vector3(0, 0, s.z)]
		1:
			return [Vector3(0, s.y, 0), Vector3(s.x, s.y, 0), Vector3(s.x, s.y, s.z), Vector3(0, s.y, s.z)]
		2:
			return [Vector3(0, 0, 0), Vector3(0, 0, s.z), Vector3(0, s.y, s.z), Vector3(0, s.y, 0)]
		3:
			return [Vector3(s.x, 0, 0), Vector3(s.x, 0, s.z), Vector3(s.x, s.y, s.z), Vector3(s.x, s.y, 0)]
		4:
			return [Vector3(0, 0, 0), Vector3(s.x, 0, 0), Vector3(s.x, s.y, 0), Vector3(0, s.y, 0)]
	return [Vector3(0, 0, s.z), Vector3(s.x, 0, s.z), Vector3(s.x, s.y, s.z), Vector3(0, s.y, s.z)]


func _line(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Color) -> void:
	verts.push_back(a)
	verts.push_back(b)
	colors.push_back(c)
	colors.push_back(c)


## 带渐变透明度的一段线（两端给不同 alpha，插值自然过渡）。
func _line_grad(verts: PackedVector3Array, colors: PackedColorArray,
		a: Vector3, b: Vector3, ca: Color, cb: Color) -> void:
	verts.push_back(a)
	verts.push_back(b)
	colors.push_back(ca)
	colors.push_back(cb)


func set_grid_lines_visible(on: bool) -> void:
	borders_visible = on


func _line_material() -> StandardMaterial3D:
	if _line_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_line_mat = m
	return _line_mat


## 相机移动 → 渐变边框要跟着重画（边框随角度平滑变化）。
func _process(_delta: float) -> void:
	if camera == null or grid_size.x <= 0:
		return
	var p := camera.global_position
	if p.distance_squared_to(_last_cam) < 1e-8:
		return
	_last_cam = p
	rebuild()


func _ready() -> void:
	if camera != null:
		_last_cam = camera.global_position
	rebuild()
