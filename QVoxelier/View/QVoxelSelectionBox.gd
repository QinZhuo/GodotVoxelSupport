@tool
class_name QVoxelSelectionBox
extends MeshInstance3D
## 选区的线框盒 —— 让"我框住了哪一块"看得见。
## 【为什么必须有它】选区是一份纯数据（一个整数盒），**看不见的选区等于没有选区**：用户按了
## "复制"却不知道复制了什么，按"移动"更不知道会搬走哪一片，只能靠撤销去试。故选区一变就重画。
## 【为什么只画 12 条棱，不画填充面】填充会把体素盖住 —— 而用户此刻正要看清楚自己框了什么。
## 线框只描边界，体素照旧看得见。
## 【坐标约定】顶点用**体素单位**，由节点自身缩放乘 voxel_scale —— 与 QVoxelGridFloor、
## VoxelRenderer 同一套换算，于是三者天然对齐，本类也不必在重建时重算一次缩放
## （见 QVoxelGridFloor 的坐标约定）。
## 【为什么棱要外偏一点】棱画在 lo / lo+size 上正好是体素块的外表面，共面会 z-fighting
## （斜视角下尤其花）。外偏一小截纯属视觉，不参与任何几何判断。

@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		_apply_scale()

## 线色。默认取界面强调色 —— 与网格足印框同族，"我框住的范围"和"能画的范围"是同一种信息。
@export var line_color := Color(QVoxelUi.ACCENT, 0.95):
	set(v):
		if line_color == v:
			return
		line_color = v
		rebuild()

## 逐格线框的格数上限。超过就退化成包围盒 —— 填充整块时几千个线框会叠成一片糊，
## 而"有这么大一片"正是那一刻唯一说得清的信息。
const CELLS_MAX := 1024

var _lo := Vector3i.ZERO
var _size := Vector3i.ZERO
var _cells: Array[Vector3i] = []
var _cells_mode := false
var _line_mat: StandardMaterial3D


## 设置选区盒（体素单位）。任一边 size <= 0 = 没有选区 → 整块隐藏。
func set_box(lo: Vector3i, size: Vector3i) -> void:
	if not _cells_mode and lo == _lo and size == _size:
		return
	_cells_mode = false
	_cells.clear()
	_lo = lo
	_size = size
	rebuild()


## 设置逐格线框（hover 预览）。空数组 = 没有预览 → 整块隐藏。
func set_cells(cells: Array[Vector3i]) -> void:
	if _cells_mode and cells.size() == _cells.size():
		var same := true
		for i in cells.size():
			if cells[i] != _cells[i]:
				same = false
				break
		if same:
			return
	_cells_mode = true
	_cells = cells
	_lo = Vector3i.ZERO
	_size = Vector3i.ZERO
	rebuild()


func rebuild() -> void:
	if _cells_mode:
		_rebuild_cells()
		return
	if _size.x <= 0 or _size.y <= 0 or _size.z <= 0:
		mesh = null
		visible = false
		return
	visible = true
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	_box_edges(verts, colors, _lo, _size)
	_commit(verts, colors)


## 逐格集合的**轮廓**：只画"组成形状的边界"（外侧棱），而不是每格一个方框。
## 内部相邻面与共享棱会被去重掉，于是不管选了多少格，看到的都是一个干净的轮廓线。
func _rebuild_cells() -> void:
	if _cells.is_empty():
		mesh = null
		visible = false
		return
	visible = true
	var verts := boundary_edges(_cells)
	var colors := PackedColorArray()
	for _i in verts.size():
		colors.push_back(line_color)
	_commit(verts, colors)


# 立方体的 6 个面方向与对应四角顺序（与预览体素同一套）。
const _FACES := [
	Vector3i(0, -1, 0), Vector3i(0, 1, 0),
	Vector3i(0, 0, -1), Vector3i(0, 0, 1),
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
]
const _QUADS := [
	[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [3, 2, 6, 7], [0, 3, 7, 4], [1, 2, 6, 5],
]


## 一组格的**外轮廓棱**（整体 mesh 的轮廓，而不是每格的方框）：
## 只看"暴露面"（邻格为空的那些面），且同一平面内相邻暴露面之间的**接缝棱不画** ——
## 于是不管是一格还是几千格，看到的都是这个形状的边界线（平面上的内部网格线被省掉）。
## offset 把顶点整体平移（预览体素要叠 center_offset）。
static func boundary_edges(cells: Array[Vector3i], offset := Vector3.ZERO) -> PackedVector3Array:
	var set := {}
	for c in cells:
		set[c] = true
	var verts := PackedVector3Array()
	var seen := {}
	for c in cells:
		var a := Vector3(c)
		var b := Vector3(c + Vector3i.ONE)
		var corners := [
			Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
			Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
		]
		for i in 6:
			var n: Vector3i = _FACES[i]
			if set.has(c + n):
				continue  # 内部面不画
			var q: Array = _QUADS[i]
			var quad := [corners[q[0]], corners[q[1]], corners[q[2]], corners[q[3]]]
			var fc: Vector3 = (quad[0] + quad[1] + quad[2] + quad[3]) / 4.0
			for k in 4:
				var p0: Vector3 = quad[k]
				var p1: Vector3 = quad[(k + 1) % 4]
				# 这条棱的平面外邻格方向（由棱中点相对面心得到，±1 单轴）。
				var em: Vector3 = (p0 + p1) / 2.0
				var d := em - fc
				var dcell := Vector3i(roundi(d.x * 2.0), roundi(d.y * 2.0), roundi(d.z * 2.0))
				var nb := c + dcell
				# 共面接缝（相邻格在同一平面上也暴露）→ 不画，得到的是整体轮廓。
				if set.has(nb) and not set.has(nb + n):
					continue
				var e0: Vector3 = p0 + offset
				var e1: Vector3 = p1 + offset
				var key := _edge_key(e0, e1)
				if seen.has(key):
					continue
				seen[key] = true
				verts.push_back(e0)
				verts.push_back(e1)
	return verts


## 棱的无向去重键（两个端点排序后拼串）。
static func _edge_key(p0: Vector3, p1: Vector3) -> String:
	var s0 := "%d,%d,%d" % [int(p0.x), int(p0.y), int(p0.z)]
	var s1 := "%d,%d,%d" % [int(p1.x), int(p1.y), int(p1.z)]
	return (s0 + "|" + s1) if s0 < s1 else (s1 + "|" + s0)


## 顶点 → 网格 → 材质 → 缩放，两种模式共用的提交动作。
func _commit(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	mesh = m
	set_surface_override_material(0, _line_material())
	_apply_scale()


func _apply_scale() -> void:
	scale = Vector3.ONE * voxel_scale


## 12 条棱（底 4 + 顶 4 + 竖 4）。用顶点色而非 uniform，于是换色只重建顶点，不碰材质。
func _box_edges(verts: PackedVector3Array, colors: PackedColorArray,
		lo: Vector3i, size: Vector3i) -> void:
	const PAD := 0.04
	var a := Vector3(lo) - Vector3.ONE * PAD
	var b := Vector3(lo + size) + Vector3.ONE * PAD
	var c := [
		Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z), Vector3(a.x, a.y, b.z),
		Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z), Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z),
	]
	var edges := [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]]
	for e in edges:
		verts.push_back(c[e[0]])
		verts.push_back(c[e[1]])
		colors.push_back(line_color)
		colors.push_back(line_color)


## 线材质：不受光、顶点色即颜色、透明、不裁剪。线与地板边框同一套路数 —— 它是参照物，
## 不该被光照改变明暗，也不该因为从盒内往外看而消失。
func _line_material() -> StandardMaterial3D:
	if _line_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.no_depth_test = true
		_line_mat = m
	return _line_mat


func _ready() -> void:
	rebuild()
