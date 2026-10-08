@tool
class_name QVoxGridFloor
extends MeshInstance3D
## 网格地板：把"模型是**有界**的一块网格"这件事画出来。
##
## 【它回答两个用户看不见就会踩的问题】
##   ① 底在哪：新建的模型是空的，而空图上的第一笔落在地板那一层（见 QVoxGridPick）——
##      地板网格画在 y = 0 上，落笔位置就有了参照；
##   ② 界在哪：网格外的落笔会被丢弃。没有边界提示的话，用户会以为"画不上去"是坏了，
##      而不是"越界了"。故除了底面格线，另画整块网格的 12 条棱。
##
## 【坐标约定】顶点一律用**体素单位**，由节点自身的缩放乘以 voxel_size ——
## 与 VoxelRenderer 的网格同一套换算，于是它俩天然对齐，也不必在重建时重算一次缩放。
##
## 【为什么用线而不是面】地板是参照物，不是模型的一部分：线画起来零贴图、零光照，
## 也不会挡住体素（不写深度干预，仍受 z-buffer 正常遮挡）。

@export_group("网格")
## 被可视化的网格尺寸（体素单位）。
@export var grid_size := Vector3i(32, 32, 32):
	set(v):
		grid_size = v
		rebuild()
## 单个体素的世界尺寸。
@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		rebuild()

@export_group("配色")
## 底面格线（细）。
@export var line_color := Color(1.0, 1.0, 1.0, 0.10)
## 每 8 格一条的粗线（1 / 8 / 16 / 24 / 32 这类，便于估距）。
@export var major_color := Color(1.0, 1.0, 1.0, 0.22)
## 网格的 12 条棱（边界）。
@export var border_color := Color(0.55, 0.75, 1.0, 0.45)


## 按当前 grid_size / voxel_scale 重建线框。
func rebuild() -> void:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		mesh = null
		return
	scale = Vector3.ONE * voxel_scale
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	_build_floor(verts, colors)
	_build_border(verts, colors)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh = m
	material_override = _material()


## 底面格线（y = 0 平面）。每 8 格换一种颜色：整数幂的间隔是估距离最顺手的刻度。
func _build_floor(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var gx := grid_size.x
	var gz := grid_size.z
	for i in range(gx + 1):
		var c := major_color if i % 8 == 0 else line_color
		_line(verts, colors, Vector3(i, 0, 0), Vector3(i, 0, gz), c)
	for k in range(gz + 1):
		var c := major_color if k % 8 == 0 else line_color
		_line(verts, colors, Vector3(0, 0, k), Vector3(gx, 0, k), c)


## 整块网格的 12 条棱：底 4 + 顶 4 + 竖 4。
func _build_border(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var size := Vector3(grid_size)
	var bottom := [
		Vector3(0, 0, 0), Vector3(size.x, 0, 0), Vector3(size.x, 0, size.z), Vector3(0, 0, size.z),
	]
	for i in 4:
		_line(verts, colors, bottom[i], bottom[(i + 1) % 4], border_color)
	for i in 4:
		_line(verts, colors, bottom[i], bottom[i] + Vector3(0, size.y, 0), border_color)
	for i in 4:
		var top: Vector3 = bottom[i] + Vector3(0, size.y, 0)
		_line(verts, colors, top, bottom[(i + 1) % 4] + Vector3(0, size.y, 0), border_color)


func _line(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Color) -> void:
	verts.push_back(a)
	verts.push_back(b)
	colors.push_back(c)
	colors.push_back(c)


## 线材质：不受光、顶点色即颜色、透明。线本身是参照物，不该被光照改变明暗。
func _material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _ready() -> void:
	rebuild()
