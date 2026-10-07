@tool
extends Node3D

## 单技法场景：洞穴的两种造法（`PcgCellular` vs SDF 挖洞）。
##
## 【同一个目标，两条路】
##   中（元胞自动机）—— 随机播撒 + 26 邻域平滑迭代。**不描述形状，只迭代规则**，
##       于是长出的是"自然成团的孔洞网络"，没有一处是作者画出来的。
##       关掉封闭外壳（`shell_is_solid = false`）让内腔从外部可见。
##   左 / 右（SDF 差集）—— 手写实体再**减掉**通道：`Subtract(Box, Union/Sphere/Cylinder)`。
##       形状完全可控、可解释（想要几条道就减几个体），代价是要自己设计。
## 两者放在一排：前者"生成"，后者"雕凿"。
##
## 【为什么 SDF 的洞能看见】减集是**真的挖空**（`max(a, -b)`）——被挖处体素为空，
## 于是光线能照进内壁。PcgModel 栈没有这种算子（它一次写满、后写覆盖先写）。
##
## 【与框架的关系】两条路都只实现 VoxelGenerator 的"按 key 造数"：
##   元胞 → PcgModelGenerator（整体 build 后切 chunk）
##   SDF  → PcgSdfGenerator（逐点 sample）
## 输出形态一致，后续渲染 / 编辑 / LOD 链路完全相同。

@export var voxel_scale: float = 0.2
## 加载半径：三块的 chunk 都要落进来。
@export var view_distance: float = 44.0

const GRID := Vector3i(64, 32, 64)

const ROCK_MATERIALS := [
	[1, Color(0.5, 0.47, 0.44), 0.95],
	[2, Color(0.4, 0.36, 0.34), 0.95],   # 内壁（SDF 差集保留 a 的材质，这里仅备用）
]


func _ready() -> void:
	PcgSceneKit.apply_environment(self)
	_build_sdf_tunnels(Vector3(-16.0, 0.0, 0.0))
	_build_cellular(Vector3(0.0, 0.0, 0.0))
	_build_sdf_chamber(Vector3(16.0, 0.0, 0.0))
	_setup_camera()
	print("[PCG洞穴Demo] 元胞洞穴 + 两组 SDF 挖洞已提交生成")


## 元胞自动机：随机播撒 + 4 轮 26 邻域平滑 → 成团的孔洞网络。
func _build_cellular(pos: Vector3) -> void:
	var cave := PcgCellular.new()
	cave.fill_ratio = 0.50
	cave.iterations = 4
	cave.birth_limit = 13
	cave.death_limit = 12
	cave.seed = 20261007
	# 关掉封闭外壳：内腔要在外部可见（要"正宗"的封闭洞穴把它打开即可）。
	cave.shell_is_solid = false
	cave.material_id = 1
	var gen := PcgModelGenerator.new()
	gen.model = cave
	_add("Cellular_Cave", pos, gen)


## SDF 挖洞（一）：石台里减掉两条交叉的圆管 → 十字通道，两端通到石台外侧。
func _build_sdf_tunnels(pos: Vector3) -> void:
	var block := SdfBox.new()
	block.center = Vector3(32.0, 16.0, 32.0)
	block.size = Vector3(60.0, 30.0, 60.0)
	block.material_id = 1

	# 圆柱原语轴沿 +Y，故用 SdfTransform 把它转到 X / Z 轴。
	var along_x := _cylinder_on(Vector3(1.0, 0.0, 0.0), Vector3(32.0, 14.0, 32.0))
	var along_z := _cylinder_on(Vector3(0.0, 0.0, 1.0), Vector3(32.0, 14.0, 32.0))

	var cross := SdfUnion.new()
	cross.a = along_x
	cross.b = along_z

	var field := SdfSubtract.new()
	field.a = block
	field.b = cross
	_add_sdf("Sdf_CrossTunnel", pos, field)


## SDF 挖洞（二）：石台里减掉一个球腔 + 一条正对的圆管 → 有"厅"有"廊"。
func _build_sdf_chamber(pos: Vector3) -> void:
	var block := SdfBox.new()
	block.center = Vector3(32.0, 16.0, 32.0)
	block.size = Vector3(60.0, 30.0, 60.0)
	block.material_id = 1

	var hall := SdfSphere.new()
	hall.center = Vector3(32.0, 15.0, 32.0)
	hall.radius = 16.0

	# 沿 Z 轴开廊：开口正对相机，否则从正面看只是一个实心方块（厅在内部，看不见）。
	var bore := _cylinder_on(Vector3(0.0, 0.0, 1.0), Vector3(32.0, 15.0, 32.0), 10.0)

	var carved := SdfSubtract.new()
	carved.a = block
	carved.b = hall
	var field := SdfSubtract.new()
	field.a = carved
	field.b = bore
	_add_sdf("Sdf_Hall", pos, field)


## 造一根"轴沿 dir 的圆管"（dir 只需是某根坐标轴的单位向量）。
func _cylinder_on(dir: Vector3, center: Vector3, radius := 9.0, height := 80.0) -> SdfTransform:
	var cyl := SdfCylinder.new()
	cyl.center = Vector3.ZERO
	cyl.radius = radius
	cyl.height = height
	var t := SdfTransform.new()
	t.child = cyl
	t.transform = Transform3D(Basis(Vector3.UP.cross(dir).normalized(), Vector3.UP.angle_to(dir)), center)
	return t


func _add_sdf(model_name: String, pos: Vector3, field: Sdf) -> void:
	var gen := PcgSdfGenerator.new()
	gen.field = field
	_add(model_name, pos, gen)


func _add(model_name: String, pos: Vector3, gen: VoxelGenerator) -> void:
	var node := PcgSceneKit.add_model(self, model_name, pos, gen, GRID,
			PcgSceneKit.materials(ROCK_MATERIALS), false, voxel_scale)
	(node as VoxelRenderer).view_distance = view_distance


func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 60.0
	cam.far = 400.0
	cam.global_position = Vector3(0.0, 14.0, 32.0)
	cam.look_at(Vector3(0.0, 5.0, 0.0), Vector3.UP)