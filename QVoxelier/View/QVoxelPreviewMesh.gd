@tool
class_name QVoxelPreviewMesh
extends MeshInstance3D
## 落笔预览的**实体**渲染：把"这一次会写出 / 擦掉哪些格"画出来。
## 【画 = 半透明实体】只画外露面的立方体，于是用户看到的是"改完之后这块长什么样"，
## 而不是几根框线。内部相邻两格之间的面被剔掉，一整片实心盒只留外壳（省三角形、不发白）。
## 【擦 = 红色空心框】"将会被挖掉"没法用体积表达（体积是"会有"），故切成红色线框：
## 一眼读出"这几格要没了"，而不是又叠一层实心块把模型糊住。
## 【为什么不参与光照、也不做深度测试】预览是"还没发生的改动"的示意，不是场景实体；
## 不受光、直接取材质色，压在模型上也始终看得见（否则会被挡在背后读不出来）。
## 【坐标约定】顶点用体素单位，靠节点 scale 乘 voxel_scale —— 与 VoxelRenderer 同一套换算。
## origin 再叠上数据层的 center_offset（导入模型会有非零偏移），否则预览与体素错开。

## 单格边长（世界单位）。由视口随模型一起喂入。
@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		_apply_scale()

## 体素单位下的整体偏移（= QVoxelSource.center_offset）。导入资产非零，编辑器新建为零。
@export var origin := Vector3.ZERO:
	set(v):
		origin = v
		rebuild()

## 逐格实体的格数上限。超过就退化成"包围盒"——两千多个块叠在一起只会糊成一团。
const CELLS_MAX := 2048
## 画时的不透明度（半透明实体）。
const DRAW_ALPHA := 0.55
## 外偏一点点：预览与真实体素表面共面，不偏会 z-fighting（斜视角下闪烁）。
const PAD := 0.02

var _cells: Array[Vector3i] = []
var _color := Color.WHITE
var _erase := false
var _mat: StandardMaterial3D


## 设置预览格集。color = 基色（不透明即可）；erase 决定"实心 / 空心"与颜色语义。
func set_cells(cells: Array[Vector3i], color: Color, erase := false) -> void:
	if color == _color and erase == _erase and _same(cells):
		return
	_cells = cells
	_color = color
	_erase = erase
	rebuild()


func clear() -> void:
	set_cells([] as Array[Vector3i], _color, _erase)


func rebuild() -> void:
	if _cells.is_empty():
		mesh = null
		visible = false
		return
	visible = true
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if _erase:
		_erase_wire(verts, colors)
		_commit(verts, colors, Mesh.PRIMITIVE_LINES)
	else:
		if _cells.size() > CELLS_MAX:
			_box_faces(verts, colors, _bounds().lo, _bounds().hi)
		else:
			_exposed(verts, colors)
		_commit(verts, colors, Mesh.PRIMITIVE_TRIANGLES)


## 逐格外露面（内部面剔除）。
func _exposed(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var occupied := {}
	for c in _cells:
		occupied[c] = true
	for c in _cells:
		for i in 6:
			if not occupied.has(c + FACES[i].dir):
				_cube_face(verts, colors, c, i)


## 擦除预览：红色线框（超上限退化为包围盒线框）。
func _erase_wire(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var c := Color(_color, 1.0)
	if _cells.size() > CELLS_MAX:
		var b := _bounds()
		_box_edges(verts, colors, b.lo, b.hi, c)
	else:
		for cell in _cells:
			_box_edges(verts, colors, cell, cell, c)


## 向缓冲追加一个格（或盒）的第 face 面（两个三角形）。
func _cube_face(verts: PackedVector3Array, colors: PackedColorArray,
		lo: Vector3i, face: int, hi := Vector3i.MIN) -> void:
	var a := Vector3(lo) + origin - Vector3.ONE * PAD
	var b := (Vector3(hi + Vector3i.ONE) if hi != Vector3i.MIN else Vector3(lo + Vector3i.ONE)) \
			+ origin + Vector3.ONE * PAD
	var p := _corners(a, b)
	var quad: Array = QUADS[face]
	var c := Color(_color, DRAW_ALPHA)
	verts.push_back(p[quad[0]]); verts.push_back(p[quad[1]]); verts.push_back(p[quad[2]])
	verts.push_back(p[quad[0]]); verts.push_back(p[quad[2]]); verts.push_back(p[quad[3]])
	for i in 6:
		colors.push_back(c)


## 某格（或盒）的 12 条棱线框。
func _box_edges(verts: PackedVector3Array, colors: PackedColorArray,
		lo: Vector3i, hi: Vector3i, c: Color) -> void:
	var a := Vector3(lo) + origin - Vector3.ONE * PAD
	var b := Vector3(hi + Vector3i.ONE) + origin + Vector3.ONE * PAD
	var p := _corners(a, b)
	for e in EDGES:
		verts.push_back(p[e[0]]); verts.push_back(p[e[1]])
		colors.push_back(c); colors.push_back(c)


## 由两个对角点造 8 个角（顺序见 FACES/QUADS 的约定）。
func _corners(a: Vector3, b: Vector3) -> Array:
	return [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
		Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]


func _box_faces(verts: PackedVector3Array, colors: PackedColorArray, lo: Vector3i, hi: Vector3i) -> void:
	for i in 6:
		_cube_face(verts, colors, lo, i, hi)


func _bounds() -> Dictionary:
	var lo := _cells[0]
	var hi := _cells[0]
	for c in _cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	return {lo = lo, hi = hi}


func _commit(verts: PackedVector3Array, colors: PackedColorArray, primitive: int) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(primitive, arrays)
	mesh = m
	set_surface_override_material(0, _material())
	_apply_scale()


func _material() -> StandardMaterial3D:
	if _mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		# 压在模型上、且多半在被遮挡处：不做深度测试才"看得见即将发生什么"。
		m.no_depth_test = true
		_mat = m
	return _mat


func _apply_scale() -> void:
	scale = Vector3.ONE * voxel_scale


## 与上次格集逐格相同？（悬停每帧调用；相同就不重建。）
func _same(cells: Array[Vector3i]) -> bool:
	if cells.size() != _cells.size():
		return false
	for i in cells.size():
		if cells[i] != _cells[i]:
			return false
	return true


func _ready() -> void:
	rebuild()


## 六个面的方向（顶点顺序见 _corners）。
const FACES := [
	{dir = Vector3i(0, -1, 0)}, {dir = Vector3i(0, 1, 0)},
	{dir = Vector3i(0, 0, -1)}, {dir = Vector3i(0, 0, 1)},
	{dir = Vector3i(-1, 0, 0)}, {dir = Vector3i(1, 0, 0)},
]
const QUADS := [
	[0, 1, 2, 3],  # -Y
	[4, 5, 6, 7],  # +Y
	[0, 1, 5, 4],  # -Z
	[3, 2, 6, 7],  # +Z
	[0, 3, 7, 4],  # -X
	[1, 2, 6, 5],  # +X
]
## 12 条棱（底 4 + 顶 4 + 竖 4）。
const EDGES := [
	[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
	[0, 4], [1, 5], [2, 6], [3, 7],
]
