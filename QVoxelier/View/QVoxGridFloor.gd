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
## 【两个面，两套画法】它们的问题不一样，硬凑成一套反而两边都做不好：
##   · 格线 → 着色器（QVoxGridFloor.gdshader）。密线用几何画在掠射角会堆叠成亮雾，
##     着色器按像素距离归一化线宽、按格密度自动淡出，远近都干净；
##   · 底 4 条足印棱 → 线几何。只有几条，永远不会堆叠，且要的就是一根实打实的细线。
##
## 【坐标约定】顶点一律用**体素单位**，由节点自身的缩放乘以 voxel_size ——
## 与 VoxelRenderer 的网格同一套换算，于是它俩天然对齐，也不必在重建时重算一次缩放。
## 格线在 UV 空间算，因此缩放节点不会让线变粗，格距恒等于 grid_size 等分。

const SHADER := preload("res://QVoxelier/View/QVoxGridFloor.gdshader")

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
## 每几格一条粗线（整数幂的间隔是估距离最顺手的刻度）。
@export var major_step := 8:
	set(v):
		major_step = maxi(v, 1)
		rebuild()

@export_group("配色")
## 底面格线（细）。
@export var line_color := Color(0.78, 0.85, 1.0, 0.06):
	set(v):
		line_color = v
		rebuild()
## 每 major_step 格一条的粗线。
@export var major_color := Color(0.82, 0.88, 1.0, 0.14):
	set(v):
		major_color = v
		rebuild()
## 底面的足印框（合法范围的正面告知）。取界面强调色 —— 与"可交互"同色，颜色本身即是信息。
@export var border_color := Color(0.4353, 0.8275, 1.0, 0.30):
	set(v):
		border_color = v
		rebuild()
## 四角的立棱短柱（体积暗示）。刻意压得比足印更弱：它只回答"底面往上还有空间"，
## 而强对比的笼子会盖过体素本身（此前 0.45 亮蓝、整根到顶，实测像调试线框）。
@export var cage_color := Color(0.4353, 0.8275, 1.0, 0.13):
	set(v):
		cage_color = v
		rebuild()

## 是否画底面格线。关掉只剩外框与短立棱 —— 密集格线在斜视角下会糊成一层雾，
## 想看形状（尤其是曲面/斜面）时需要能把它摘掉。**外框始终保留**：它不是装饰，
## 是"合法范围的正面告知"（见类文档第 ② 条），关掉会让越界落笔重新变成"坏了"。
@export var grid_lines_visible := true:
	set(v):
		grid_lines_visible = v
		_push_grid_colors()

var _grid_mat: ShaderMaterial
var _line_mat: StandardMaterial3D


## 按当前 grid_size / voxel_scale 重建。
func rebuild() -> void:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		mesh = null
		return
	scale = Vector3.ONE * voxel_scale
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _floor_arrays())
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	_build_border(verts, colors)
	var line_arrays := []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = verts
	line_arrays[Mesh.ARRAY_COLOR] = colors
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	mesh = m
	# 用逐面覆盖材质而不是 material_override：后者会把两个面一起盖掉。
	set_surface_override_material(0, _grid_material())
	set_surface_override_material(1, _line_material())


## 地板的格线面：一块铺满整个网格的四边形，格线交给着色器画。
func _floor_arrays() -> Array:
	var gx := float(grid_size.x)
	var gz := float(grid_size.z)
	# 沉下一点点：与 y = 0 层体素的底面共面会 z-fighting（从下方看时尤其花）。
	var y := -0.002
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.0, y, 0.0), Vector3(gx, y, 0.0), Vector3(gx, y, gz), Vector3(0.0, y, gz),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	return arrays


## 整块网格的 12 条棱：底 4（足印，最实）+ 竖 4 + 顶 4（笼子，最虚）。
func _build_border(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var size := Vector3(grid_size)
	var bottom := [
		Vector3(0, 0, 0), Vector3(size.x, 0, 0), Vector3(size.x, 0, size.z), Vector3(0, 0, size.z),
	]
	for i in 4:
		_line(verts, colors, bottom[i], bottom[(i + 1) % 4], border_color)
	# 立棱只在四角各立起一小段（下 15%）并淡出到零，不画顶框。
	# 【为什么不做整根】网格常比模型高得多（默认 32 格高，世界长 3.2），整根立棱在屏上
	# 几乎贯穿画面：无论怎么压 alpha，透视下都读成"四角向屏幕边发散的长斜线"，
	# 而不是"体积暗示"，把体素本身盖过去了。短柱只回答"底面往上还有空间"，不抢戏。
	# 【为什么能直接淡到零】线段的顶点色会被插值，"渐变"不需要额外机制 —— 两端给不同 alpha 即可。
	for i in 4:
		var knee: Vector3 = bottom[i] + Vector3(0, size.y * 0.15, 0)
		_line_gradient(verts, colors, bottom[i], knee, cage_color, Color(cage_color, 0.0))


func _line(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Color) -> void:
	_line_gradient(verts, colors, a, b, c, c)


func _line_gradient(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3,
		ca: Color, cb: Color) -> void:
	verts.push_back(a)
	verts.push_back(b)
	colors.push_back(ca)
	colors.push_back(cb)


## 格线材质（复用同一个实例，只改 uniform —— 重建可能很频繁）。
func _grid_material() -> ShaderMaterial:
	if _grid_mat == null:
		_grid_mat = ShaderMaterial.new()
		_grid_mat.shader = SHADER
		_grid_mat.set_shader_parameter("cell_count", Vector2(grid_size.x, grid_size.z))
		_grid_mat.set_shader_parameter("major_step", float(major_step))
	_push_grid_colors()
	return _grid_mat


## 把颜色推到着色器。**显隐也用同一组 uniform 表达**（alpha 置 0），而不是换材质或摘面 ——
## 摘面要重建整个网格，换材质要多留一份实例；而颜色 uniform 本来就要推，顺手复用最省。
func _push_grid_colors() -> void:
	if _grid_mat == null:
		return
	_grid_mat.set_shader_parameter("line_color",
			line_color if grid_lines_visible else Color(line_color, 0.0))
	_grid_mat.set_shader_parameter("major_color",
			major_color if grid_lines_visible else Color(major_color, 0.0))


## 对外：网格线显隐（由视图栏开关调用）。
func set_grid_lines_visible(on: bool) -> void:
	grid_lines_visible = on


## 线材质：不受光、顶点色即颜色、透明。线本身是参照物，不该被光照改变明暗。
func _line_material() -> StandardMaterial3D:
	if _line_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_line_mat = m
	return _line_mat


func _ready() -> void:
	rebuild()
