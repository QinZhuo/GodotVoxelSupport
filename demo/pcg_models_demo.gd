@tool
extends Node3D

## 程序化体素模型演示（PCG / SDF）——四个彼此独立的模型。
##
## 每个模型 = 【有界 VoxelData】+【PcgSdfGenerator（内嵌一棵 SDF 树）】+【VoxelRenderer 节点】，
## 各自持有独立 VoxelData 实例。因为就是一个普通节点，所以可以单独平移/旋转、单独挂脚本、
## 单独开碰撞（VoxelRenderer.generate_collision），互不干扰——无需任何新的节点类。
##
## 沿 X 轴依次排开：
##   ① 平滑并 + 差：两球 SmoothUnion 焊成雪人/岩石，再用圆柱 Subtract 打穿一个洞
##   ② 交 + 并：盒 ∩ 球 得到圆角块，再并上两根胶囊腿
##   ③ 域重复 + 变换：Repeat 重复圆柱得到柱林，再用 Transform 把重复图案对齐到模型中心，并上底座
##   ④ 圆环 + 圆台 + 半空间：Torus ∪ Cone 叠成一个立环塔，再用 Plane 把底座切平
##
## 验证：改 SDF 参数或 grid_size 重建，形状与有界范围随之变化。

## 体素世界尺度（模型 32³ 体素 → 世界 6.4 单位）
@export var voxel_scale: float = 0.2
## 相邻模型的世界间距（四个模型按 ±1.5s / ±0.5s 排布）
@export var model_spacing: float = 12.0


func _ready() -> void:
	_build_model_a(Vector3(-model_spacing * 1.5, 0.0, 0.0))
	_build_model_b(Vector3(-model_spacing * 0.5, 0.0, 0.0))
	_build_model_c(Vector3(model_spacing * 0.5, 0.0, 0.0))
	_build_model_d(Vector3(model_spacing * 1.5, 0.0, 0.0))
	_setup_camera()
	print("[PCG模型Demo] 四个独立 SDF 模型已生成")


## 相机对准四个模型（用 look_at，避免手写基矢）
func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 60.0
	# 相机须让四个模型的 chunk 都落在 VoxelRenderer 的 LOD0 半径内，否则最外侧两个不会生成
	cam.global_position = Vector3(0.0, 12.0, 30.0)
	cam.look_at(Vector3(0.0, 3.5, 0.0), Vector3.UP)


## 模型 A：平滑并两球 → 圆柱打洞
func _build_model_a(pos: Vector3) -> void:
	var head := _sphere(Vector3(16, 10, 16), 9.0, 1)
	var body := _sphere(Vector3(16, 23, 16), 6.0, 2)
	var weld := SdfSmoothUnion.new()
	weld.a = head
	weld.b = body
	weld.k = 3.0

	var hole := SdfSubtract.new()
	hole.a = weld
	hole.b = _cylinder(Vector3(16, 16, 16), 3.0, 44.0, 0)
	_add_model("ModelA_Rock", pos, hole, [
		_material(1, Color(0.45, 0.5, 0.55), 0.9),
		_material(2, Color(0.7, 0.35, 0.3), 0.8),
	])


## 模型 B：盒 ∩ 球 得圆角块 → 并上两根胶囊腿
func _build_model_b(pos: Vector3) -> void:
	var slab := SdfBox.new()
	slab.center = Vector3(16, 20, 16)
	slab.size = Vector3(22.0, 16.0, 22.0)
	slab.material_id = 1

	var rounder := _sphere(Vector3(16, 20, 16), 12.0, 2)
	var rounded := SdfIntersect.new()
	rounded.a = slab
	rounded.b = rounder

	var legs := SdfUnion.new()
	legs.a = rounded
	var leg_pair := SdfUnion.new()
	leg_pair.a = _capsule(Vector3(11, 12, 16), Vector3(11, 1, 16), 2.5, 3)
	leg_pair.b = _capsule(Vector3(21, 12, 16), Vector3(21, 1, 16), 2.5, 3)
	legs.b = leg_pair

	_add_model("ModelB_Stool", pos, legs, [
		_material(1, Color(0.55, 0.45, 0.3), 0.9),
		_material(2, Color(0.35, 0.55, 0.4), 0.85),
		_material(3, Color(0.4, 0.4, 0.45), 0.95),
	])


## 模型 C：域重复 + 变换 —— Repeat 重复圆柱得到柱林，再平移到模型中心，并上底座
func _build_model_c(pos: Vector3) -> void:
	# 重复以"原点所在格"为基准，故子形状放在原点；Y 轴不重复 → 纵向是连续柱体
	var pillar := _cylinder(Vector3(0, 16, 0), 2.5, 30.0, 3)
	var forest := SdfRepeat.new()
	forest.child = pillar
	forest.spacing = Vector3(8.0, 0.0, 8.0)

	# 把重复图案整体平移，使柱子落在 4/12/20/28 而非贴着网格边
	var centered := SdfTransform.new()
	centered.child = forest
	centered.transform = Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, 4.0))

	var base := SdfBox.new()
	base.center = Vector3(16, 1.5, 16)
	base.size = Vector3(32.0, 3.0, 32.0)
	base.material_id = 1

	var model := SdfUnion.new()
	model.a = base
	model.b = centered
	_add_model("ModelC_Pillars", pos, model, [
		_material(1, Color(0.4, 0.42, 0.45), 0.95),
		_material(3, Color(0.3, 0.5, 0.65), 0.7),
	])


## 模型 D：Torus ∪ Cone 叠成立环塔 → 再用半空间 Plane 把底座切平
func _build_model_d(pos: Vector3) -> void:
	# 圆环横躺在顶部，环心在 y=22
	var ring := SdfTorus.new()
	ring.center = Vector3(16, 22, 16)
	ring.major_radius = 6.0
	ring.minor_radius = 3.5
	ring.material_id = 2

	# 圆台从底部撑起，顶面 (r=5, y=20) 落在环管内部 → 两件真的连成一体
	var stem := SdfCone.new()
	stem.center = Vector3(16, 10, 16)
	stem.bottom_radius = 9.0
	stem.top_radius = 5.0
	stem.height = 20.0
	stem.material_id = 3

	var tower := SdfUnion.new()
	tower.a = ring
	tower.b = stem

	# 半空间无界，靠"差"来用：挖掉 y < 1.5 的一切 → 底部被切平
	var cutter := SdfPlane.new()
	cutter.normal = Vector3.UP
	cutter.offset = 1.5

	var model := SdfSubtract.new()
	model.a = tower
	model.b = cutter

	_add_model("ModelD_RingTower", pos, model, [
		_material(2, Color(0.75, 0.4, 0.35), 0.85),
		_material(3, Color(0.3, 0.5, 0.7), 0.7),
	])


## 组装一个模型：有界 VoxelData（grid_size 即生成范围）+ PcgSdfGenerator + VoxelRenderer 节点。
func _add_model(model_name: String, pos: Vector3, field: Sdf, materials: Array) -> void:
	var data := VoxelData.new()
	for m in materials:
		data.add_material(m)

	var generator := PcgSdfGenerator.new()
	generator.field = field
	data.generator = generator
	data.grid_size = Vector3i(32, 32, 32)

	var renderer := VoxelRenderer.new()
	renderer.name = model_name
	renderer.data = data
	renderer.voxel_scale = voxel_scale
	renderer.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	add_child(renderer)
	renderer.global_position = pos


# ----------------------------------------------------------------------------
# SDF 构造小工具（每个字符号只对应一个 SDF 节点，参数内联便于对照）
# ----------------------------------------------------------------------------

func _sphere(center: Vector3, radius: float, material_id: int) -> SdfSphere:
	var s := SdfSphere.new()
	s.center = center
	s.radius = radius
	s.material_id = material_id
	return s


func _cylinder(center: Vector3, radius: float, height: float, material_id: int) -> SdfCylinder:
	var c := SdfCylinder.new()
	c.center = center
	c.radius = radius
	c.height = height
	c.material_id = material_id
	return c


func _capsule(a: Vector3, b: Vector3, radius: float, material_id: int) -> SdfCapsule:
	var c := SdfCapsule.new()
	c.a = a
	c.b = b
	c.radius = radius
	c.material_id = material_id
	return c


func _material(id: int, color: Color, rough: float) -> VoxelMaterial:
	var m := VoxelMaterial.new()
	m.id = id
	m.color = color
	m.rough = rough
	m.hardness = 5.0
	m.connection_strength = 20.0
	m.mass = 2.0
	return m
