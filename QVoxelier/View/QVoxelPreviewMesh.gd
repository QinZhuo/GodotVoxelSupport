@tool
class_name QVoxelPreviewMesh
extends MeshInstance3D
## 落笔预览的**实体**渲染：把"这一次会写出 / 擦掉哪些格"画成半透明立方体，
## 而不是只描一层方框线 —— 用户要看的是"改完之后这块长什么样"。
## 【只画外露面】内部相邻两格之间的面被剔掉：一整片实心盒只留下外壳，
## 既省三角形又不会因为叠面导致半透明发白发脏。放置到空处时六面都在，就是一颗实心方块。
## 【为什么不参与光照】预览是"还没发生的改动"的示意，不是场景里的实体；
## 不受光、直接取材质色（擦除取警示红），一眼与真实体素区分开。
## 【坐标约定】顶点用体素单位，靠节点 scale 乘 voxel_scale —— 与 VoxelRenderer / QVoxelGridFloor
## / QVoxelSelectionBox 同一套换算，故天然对齐。

## 单格边长（世界单位）。由视口随模型一起喂入。
@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		_apply_scale()

## 逐格实体预览的格数上限。超过就退化成"包围盒实体" —— 两千多个半透明方块叠在一起
## 只会糊成一团，而"有这么大一片"正是那一刻唯一说得清的信息（同 QVoxelSelectionBox 的取舍）。
const CELLS_MAX := 2048
## 画时的不透明度 / 擦除时的不透明度。擦除更淡，避免整块醒目的红盖住模型本身的形态。
const DRAW_ALPHA := 0.55
const ERASE_ALPHA := 0.45
## 外偏一点点：擦除预览与真实体素表面共面，不偏会 z-fighting（斜视角下闪烁）。
const PAD := 0.02

var _cells: Array[Vector3i] = []
var _color := Color.WHITE
var _erase := false
var _mat: StandardMaterial3D


## 设置预览格集。color = 基色（不透明即可，透明度由本类按画 / 擦决定）；erase 决定色与淡度。
## 与上次完全一致时直接返回（悬停每帧调用，相同内容不该重建网格）。
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
	if _cells.size() > CELLS_MAX:
		_box_solid(verts, colors, _bounds())
	else:
		_exposed(verts, colors)
	_commit(verts, colors)


## 逐格外露面（内部面剔除）。
func _exposed(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var occupied := {}
	for c in _cells:
		occupied[c] = true
	for c in _cells:
		for i in 6:
			if not occupied.has(c + FACES[i].dir):
				_cube_face(verts, colors, c, i)


## 包围盒实体（超上限退化）：只画盒的六个外表面。
func _box_solid(verts: PackedVector3Array, colors: PackedColorArray, b: Dictionary) -> void:
	for i in 6:
		_cube_face(verts, colors, b.lo, i, b.hi)


## 向缓冲追加一个格（或一个盒）的第 face 面（两个三角形，六个顶点）。
## box_lo / box_hi 缺省时按单格 [lo, lo+1] 处理。
func _cube_face(verts: PackedVector3Array, colors: PackedColorArray,
		lo: Vector3i, face: int, hi := Vector3i.MIN) -> void:
	var a := Vector3(lo) - Vector3.ONE * PAD
	var b := (Vector3(hi + Vector3i.ONE) if hi != Vector3i.MIN else Vector3(lo + Vector3i.ONE)) + Vector3.ONE * PAD
	var p := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
		Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	var quad: Array = QUADS[face]
	var c := _fill_color()
	# 两个三角形：0-1-2、0-2-3（cull 关闭，缠绕方向无所谓）。
	verts.push_back(p[quad[0]]); verts.push_back(p[quad[1]]); verts.push_back(p[quad[2]])
	verts.push_back(p[quad[0]]); verts.push_back(p[quad[2]]); verts.push_back(p[quad[3]])
	for i in 6:
		colors.push_back(c)


func _fill_color() -> Color:
	var c := _color
	c.a = ERASE_ALPHA if _erase else DRAW_ALPHA
	return c


func _bounds() -> Dictionary:
	var lo := _cells[0]
	var hi := _cells[0]
	for c in _cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	return {lo = lo, hi = hi}


func _commit(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
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


## 六个面的方向与顶点索引（顶点顺序见 _cube_face 的 p）。
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
