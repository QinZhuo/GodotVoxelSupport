@tool
extends Node3D

## 综合场景：PCG × 体素框架的"上限展示"。
##
## 【这是什么】把两条 PCG 技术栈、四种算子、一条可交互破坏链路放进同一张图里，
## 用来回答两个问题：
##   ① 结合是否优雅 —— 每个模型都只是"一个普通 VoxelData + 一个 VoxelRenderer 节点"，
##      所以编辑 / 破坏 / 物理 / 碰撞 / LOD 全部自动可用。本场景里那座可破坏塔就是证据：
##      它和其他 13 个节点的组装代码完全一样，唯一区别是容器类从 `VoxelRenderer.new()`
##      换成了 `VoxelDestructible.new()`（见 PcgSceneKit.add_model 的 destructible 参数）。
##   ② PCG 能到什么水平 —— 基底（SDF 组合）+ 植被（L-系统）+ 洞穴（元胞自动机）
##      + 遗迹（socket 式 WFC）+ 有机岩壁（重叠式 WFC）同场共存，共约 50 个 chunk。
##
## 【两条技术栈的分工】
##   SDF（PcgSdfGenerator）：逐点采样 sample(p) —— 适合"由简单件组合出的实体"。
##     这里的岛体就是 Plane ∪ SmoothUnion{台地, 山丘} ⊖ 火山口。
##   PcgModel（PcgModelGenerator）：整体产出 build(grid_size) —— 适合"必须全局迭代
##     才算得出来的东西"。L-系统 / 元胞自动机 / 两种 WFC 都只能这样算。
##
## 【两条硬约束（布局时必须接受，不是 bug）】
##   · 生成器无法按位置给多材质：L-系统 material_id / PcgWfcTile.material_id / SDF 每个
##     原语的 material_id 都是"每模型或每图块一个主色"，没有"按高度染色"这回事。
##   · PcgModel 栈没有 overlay：build() 一次写满，后写覆盖先写。真正的"叠加 / 挖空"
##     只在 SDF 栈里存在（见基底与 pcg_porous_demo）。
##
## 【相机与 view_distance 的硬关系】有界程序化数据也走"按相机距离加载"——
##   对生成器世界，流式驱动恒开（不取决于 visibility_mode）。且超出 view_distance 的
##   LOD0 网格会被主动移除。所以相机必须让所有模型的 chunk 都落在 view_distance 内，
##   否则远处模型会"建了又删"或干脆不出现。本场景所有模型都排布在以相机为心、
##   半径 56 世界单位的球内。
##
## 【键位】左键 = 对着可破坏塔打一个球形洞；R = 重建该塔。

## 体素世界尺度（1 chunk = 32 体素 = 6.4 世界单位）
@export var voxel_scale: float = 0.2
## 加载半径（世界单位）。最远的是侧洞远端角（约 51），故 56 留出余量。
@export var view_distance: float = 56.0
## 破坏球半径（体素单位）
@export var damage_radius: float = 6.0

const BASE_GRID := Vector3i(128, 48, 128)
const TREE_GRID := Vector3i(32, 32, 32)
const CAVE_GRID := Vector3i(64, 32, 64)
const RUIN_GRID := Vector3i(32, 48, 32)
## 重叠式 WFC 的网格。PcgWfcOverlap 的类注释明确要求 grid_size ≤ 24³：
## 它"每格一个图案"，观察步是 O(格数²) 的扫描，32³ 会把构建时间推到分钟级。
const OVERLAP_GRID := Vector3i(24, 24, 24)

## 岛体台地顶面（体素 y）——所有地表物件都坐在这个高度上。
const PLATEAU_VOXEL_Y := 34.0
## 岛体节点的世界位置：让 128 宽的岛体以世界原点为中心。
const BASE_ORIGIN := Vector3(-12.8, 0.0, -12.8)

## 所有 PCG 模型节点（HUD 统计用）。
var _models: Array[Node3D] = []
## 可破坏塔（演示用的破坏目标）
var _tower: VoxelDestructible
## 塔的初始快照，供 R 重建
var _tower_snapshot: Dictionary

var _camera: Camera3D
var _hud: Label
var _hint: Label
var _prev_left := false
var _prev_r := false


func _ready() -> void:
	_setup_ground()
	_build_base()
	_build_cave()
	_build_ruins_and_wall()
	_build_tower()
	_build_forest()
	_setup_camera()
	_setup_hud()
	print("[PCG综合场景] %d 个模型 / 期望 %d 个 chunk 已提交生成" % [_models.size(), _expected_chunks()])


## 台地顶面的世界 y（跟着 voxel_scale 走，避免改尺度后物件悬空 / 埋进地里）。
func _plateau_world_y() -> float:
	return BASE_ORIGIN.y + PLATEAU_VOXEL_Y * voxel_scale


# ----------------------------------------------------------------------------
# 基底：SDF 组合（Plane ∪ SmoothUnion{台地, 山丘} ⊖ 火山口）
# ----------------------------------------------------------------------------

## 岛体。这是全场景唯一"由简单件组合出实体"的部分——也正因为 SDF 有真正的
## 组合算子（并/交/差/平滑并/域重复），它才能一次算出整个岛。
func _build_base() -> void:
	# 岛底：半空间（y < 7 体素），无界，靠"并"来用。
	var ground := SdfPlane.new()
	ground.normal = Vector3.UP
	ground.offset = 7.0
	ground.material_id = 3

	# 台地：平顶大方块，顶面 y = 34 体素——地表物件的落脚面。
	var mesa := SdfBox.new()
	mesa.center = Vector3(64, 17, 64)
	mesa.size = Vector3(100, 34, 100)
	mesa.material_id = 1

	# 山丘：球经 Transform 挪到台地一角，给轮廓加点起伏（纯方块太生硬）。
	var knoll_shape := SdfSphere.new()
	knoll_shape.center = Vector3.ZERO
	knoll_shape.radius = 17.0
	knoll_shape.material_id = 2
	var knoll := SdfTransform.new()
	knoll.child = knoll_shape
	knoll.transform = Transform3D(Basis.IDENTITY, Vector3(30, 20, 92))

	# 平滑并：台地与山丘焊成一体（k 越大过渡越软）。
	var weld := SdfSmoothUnion.new()
	weld.a = mesa
	weld.b = knoll
	weld.k = 6.0

	var island := SdfUnion.new()
	island.a = ground
	island.b = weld

	# 火山口：从台地顶部挖走一个球，露出内壁。
	var crater := SdfSphere.new()
	crater.center = Vector3(44, 36, 44)
	crater.radius = 15.0

	var field := SdfSubtract.new()
	field.a = island
	field.b = crater

	var gen := PcgSdfGenerator.new()
	gen.field = field
	_register(PcgSceneKit.add_model(self, "Base_Island", BASE_ORIGIN, gen, BASE_GRID,
			PcgSceneKit.materials([
				[1, Color(0.52, 0.5, 0.46), 0.95],   # 岩石
				[2, Color(0.38, 0.5, 0.32), 0.9],    # 苔原
				[3, Color(0.3, 0.32, 0.34), 0.85],   # 湿岩
			])))


# ----------------------------------------------------------------------------
# 洞穴：元胞自动机（PcgCellular）
# ----------------------------------------------------------------------------

## 嵌在岛体 -X 侧壁上的岩体。
##
## 【为什么让它探出去半个身位】元胞自动机的空腔在"实心块"内部。若整块埋进岛体，
## 空腔会被岛体的实心体素填满（两个渲染器的实体互相穿插，看到的并集仍是实心），
## 就什么都看不见了。让它探出岛体侧壁 6.4 世界单位，空腔才有"外面"可通风。
func _build_cave() -> void:
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
	_register(PcgSceneKit.add_model(self, "Side_Cave", Vector3(-19.2, 0.0, -6.4), gen, CAVE_GRID,
			PcgSceneKit.materials([
				[1, Color(0.5, 0.47, 0.44), 0.95],
			])))


# ----------------------------------------------------------------------------
# 遗迹（socket 式 WFC）与有机岩壁（重叠式 WFC）
# ----------------------------------------------------------------------------

## 四块 4³ 图块按**手写的六面接口名**拼接。竖向约束最强（地板下方必须是 rock，
## 上方必须留空），于是自然叠出"石基 - 地板 - 柱 - 地板"的多层结构。
## 返回类型必须是 Array[PcgWfcTile]：PcgWfc.tiles 是强类型数组，直接赋值**行内**字面量
## 时 GDScript 会按目标类型构造；但函数返回值在静态类型上是普通 Array，运行期不会自动转换，
## 赋值即报 "Invalid assignment of property 'tiles'"。
func _make_ruin_tiles() -> Array[PcgWfcTile]:
	var tile := Vector3i(4, 4, 4)
	# 空：六面皆 air，纯留白。
	var open := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "air", "air", "air"], 2.0, 0,
			func(_x, _y, _z): return false)
	# 石：实心，上下皆 rock → 只能夹在"上下面朝 rock"的图块之间。
	var rock := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "rock", "air", "air"], 1.0, 3,
			func(_x, _y, _z): return true)
	# 地板：底层实心；下方必须接 rock，上方留空。
	var floor_t := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "rock", "air", "air"], 1.5, 1,
			func(_x, y, _z): return y == 0)
	# 柱：2×2 通高；下方留空（可立于地板），上方为 rock（可再叠地板）。
	var pillar := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "air", "air", "air"], 0.8, 2,
			func(x, _y, z): return x >= 1 and x <= 2 and z >= 1 and z <= 2)
	var out: Array[PcgWfcTile] = [open, rock, floor_t, pillar]
	return out


const RUIN_MATERIALS := [
	[1, Color(0.55, 0.45, 0.3), 0.9],    # 地板（木/砂岩）
	[2, Color(0.42, 0.4, 0.4), 0.95],    # 石柱
	[3, Color(0.75, 0.7, 0.6), 0.95],    # 石基
]

## 两座遗迹 + 一面有机岩壁。
func _build_ruins_and_wall() -> void:
	var y := _plateau_world_y()
	for i in 2:
		var wfc := PcgWfc.new()
		wfc.tiles = _make_ruin_tiles()
		# 同参数不同 seed → 两座遗迹形态不同，但各自仍是确定的（同 seed 恒同结果）。
		wfc.seed = 20261007 + i * 977
		wfc.max_retries = 12
		var gen := PcgModelGenerator.new()
		gen.model = wfc
		var pos := Vector3(-3.2 + i * 6.4, y, -5.6)
		_register(PcgSceneKit.add_model(self, "Ruin_%d" % (i + 1), pos, gen, RUIN_GRID,
				PcgSceneKit.materials(RUIN_MATERIALS)))

	# 有机岩壁：规则不手写，从一块 8³ 样例里"数"出可重叠的 3³ 图案，再拼成一片同类岩体。
	var sample_size := Vector3i(8, 8, 8)
	var overlap := PcgWfcOverlap.new()
	overlap.sample = PcgSceneKit.overlap_sample(sample_size)
	overlap.sample_size = sample_size
	overlap.pattern_size = 3
	overlap.seed = 20261007
	overlap.max_retries = 8
	var ov_gen := PcgModelGenerator.new()
	ov_gen.model = overlap
	_register(PcgSceneKit.add_model(self, "Organic_Wall", Vector3(3.2, y, 1.6), ov_gen, OVERLAP_GRID,
			PcgSceneKit.materials([
				[1, Color(0.5, 0.47, 0.44), 0.95],
				[2, Color(0.45, 0.6, 0.4), 0.8],
			])))


# ----------------------------------------------------------------------------
# 可破坏塔：唯一的 VoxelDestructible，其余组装代码一字未改
# ----------------------------------------------------------------------------

func _build_tower() -> void:
	var wfc := PcgWfc.new()
	wfc.tiles = _make_ruin_tiles()
	wfc.seed = 424242
	wfc.max_retries = 12
	var gen := PcgModelGenerator.new()
	gen.model = wfc

	# destructible = true 是这里与其余 13 个模型的**唯一**区别。
	_register(PcgSceneKit.add_model(self, "Tower_Destructible", Vector3(-3.2, _plateau_world_y(), 5.6),
			gen, RUIN_GRID, PcgSceneKit.materials(RUIN_MATERIALS), true))
	_tower = _models.back() as VoxelDestructible
	# 伤害必须**单次**越过材质硬度才能立刻出洞：材质 hardness = 5.0（见 PcgSceneKit），
	# 而 PcgSceneKit 给破坏容器配的 damage_per_voxel = 1.0 是"按住连打"式的（destruction_demo
	# 就是按住不放靠多帧累伤）。本场景是"点一下出一个洞"，故把单次伤害提到硬度之上。
	_tower.damage_per_voxel = 8.0
	_tower_snapshot = _tower.data.save_data()


# ----------------------------------------------------------------------------
# 植被：L-系统（PcgLsystem）
# ----------------------------------------------------------------------------

## 成林。PcgLsystem 没有 seed —— 形态差异只能靠
## `rules / iterations / step / thickness / angle_degrees / material_id` 参数化。
func _build_forest() -> void:
	var y := _plateau_world_y()
	# [节点位置, axiom, rules, 迭代, 步长, 粗细, 角度]
	var specs := [
		[Vector3(-11.7, y, -3.2), "F", "F=FF[+F][-F][&F][^F]", 3, 1.7, 0.9, 30.0],
		[Vector3(-11.7, y, -11.7), "F", "F=F[+F]F[-F]F", 4, 1.3, 0.8, 24.0],
		[Vector3(5.3, y, -2.7), "F", "F=FF-[-F+F+F]+[+F-F-F]", 3, 1.2, 0.8, 22.0],
		[Vector3(5.3, y, 4.8), "F", "F=FF[+F][-F][&F][^F]", 3, 1.5, 1.0, 28.0],
		[Vector3(-3.2, y, 6.0), "F", "F=F[+F]F[-F]F", 4, 1.2, 0.7, 26.0],
		[Vector3(-3.2, y, -12.2), "F", "F=FF-[-F+F+F]+[+F-F-F]", 3, 1.4, 0.9, 20.0],
		[Vector3(-1.7, y, 6.2), "F", "F=F[+F][&F][^F]", 4, 1.1, 0.7, 30.0],
		[Vector3(6.0, y, -9.5), "F", "F=FF[+F][-F][&F][^F]", 3, 1.3, 0.8, 32.0],
	]
	for i in specs.size():
		var s: Array = specs[i]
		var tree := PcgLsystem.new()
		tree.axiom = s[1]
		tree.rules = PackedStringArray([s[2]])
		tree.iterations = s[3]
		tree.step = s[4]
		tree.thickness = s[5]
		tree.angle_degrees = s[6]
		tree.material_id = 1
		var gen := PcgModelGenerator.new()
		gen.model = tree
		_register(PcgSceneKit.add_model(self, "Tree_%d" % (i + 1), s[0], gen, TREE_GRID,
				PcgSceneKit.materials([
					[1, Color(0.35, 0.52, 0.28), 0.9],
				])))


# ----------------------------------------------------------------------------
# 场景装配
# ----------------------------------------------------------------------------

func _register(node: Node3D) -> void:
	# 统一相机半径：让每个模型都落在 view_distance 内（详见文件头）。
	(node as VoxelRenderer).view_distance = view_distance
	_models.append(node)


## 地面板：纯粹给画面一个"底"，同时充当碎片落点（碎片是纯粒子，不需要碰撞体，
## 这里保留 StaticBody3D 只是为了将来接物理碎片时不用改场景）。
func _setup_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	var shape := BoxShape3D.new()
	shape.size = Vector3(120.0, 1.0, 120.0)
	var oid := body.create_shape_owner(body)
	body.shape_owner_add_shape(oid, shape)
	body.position = Vector3(0.0, -0.6, 0.0)
	add_child(body)

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(120.0, 1.0, 120.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.23, 0.26)
	mat.roughness = 0.95
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0.0, -0.6, 0.0)
	add_child(mesh_inst)


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 60.0
	_camera.far = 400.0
	# 抬高 + 后退的 3/4 视角：可破坏塔在 z=+5.6（离相机最近），贴地看会被它挡住半个画面。
	_camera.global_position = Vector3(0.0, 25.0, 24.0)
	_camera.look_at(Vector3(0.0, 3.0, 0.0), Vector3.UP)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

	_hint = Label.new()
	_hint.position = Vector2(10, 128)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.45, 0.9, 1.0))
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hint)

	_hint.text = """[左键] 对着石塔打球形洞   [R] 重建石塔
【关键证据】那座可破坏塔与其余 13 个模型的组装代码完全一致，
唯一区别是容器类 VoxelRenderer → VoxelDestructible。
产出即享全链路：编辑 / 破坏 / 物理 / LOD 无需任何 PCG 专属分支。"""


# ----------------------------------------------------------------------------
# 交互：破坏（复刻 destruction_demo 的手法）
# ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var key_r := Input.is_key_pressed(KEY_R)

	if left and not _prev_left:
		_damage_at_mouse()
	if key_r and not _prev_r:
		_rebuild_tower()

	_prev_left = left
	_prev_r = key_r
	_update_hud()


func _damage_at_mouse() -> void:
	if _tower == null or _camera == null:
		return
	var hit := _mouse_to_voxel()
	if hit == Vector3i.MIN:
		return
	_tower.damage_sphere(Vector3(hit) + Vector3(0.5, 0.5, 0.5), damage_radius)


## 屏幕射线 → 塔的局部体素坐标。VoxelDestructible 的 raycast 收的是
## "局部体素空间"的射线，故要把世界射线换算到局部再除以 voxel_scale。
func _mouse_to_voxel() -> Vector3i:
	var from := _camera.project_ray_origin(get_viewport().get_mouse_position())
	var dir := _camera.project_ray_normal(get_viewport().get_mouse_position())
	var local_origin := _tower.to_local(from)
	var local_dir := _tower.global_transform.basis.inverse() * dir
	return _tower.raycast_voxel(local_origin / voxel_scale, local_dir, 1000.0)


func _rebuild_tower() -> void:
	if _tower == null:
		return
	_tower.clear_damage()
	_tower.data.load_data(_tower_snapshot)
	print("[PCG综合场景] 石塔已重建")


# ----------------------------------------------------------------------------
# HUD：已建 chunk / 期望 chunk —— 这是"数据真的按 grid_size 全建出来了"的判据
# ----------------------------------------------------------------------------

func _expected_chunks() -> int:
	var n := 0
	for node in _models:
		var gs: Vector3i = (node as VoxelRenderer).data.grid_size
		var span := Vector3i(
			(gs.x + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.y + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.z + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE)
		n += span.x * span.y * span.z
	return n


func _built_chunks() -> int:
	var n := 0
	for node in _models:
		var data: VoxelData = (node as VoxelRenderer).data
		var gs: Vector3i = data.grid_size
		var span := Vector3i(
			(gs.x + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.y + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE,
			(gs.z + VoxelChunk.CHUNK_SIZE - 1) / VoxelChunk.CHUNK_SIZE)
		for cz in span.z:
			for cy in span.y:
				for cx in span.x:
					if data.is_chunk_loaded(Vector3i(cx, cy, cz)):
						n += 1
	return n


func _update_hud() -> void:
	if _hud == null:
		return
	var damage := 0
	if _tower != null:
		damage = int(_tower.last_damage_count)
	_hud.text = """===== PCG 综合场景 =====
FPS: %d    模型: %d    已建 chunk: %d / %d
可破坏塔: 最近一次破坏移除 %d 体素
相机 (%.0f, %.0f, %.0f)   view_distance %.0f
""" % [
		Engine.get_frames_per_second(), _models.size(), _built_chunks(), _expected_chunks(),
		damage, _camera.global_position.x, _camera.global_position.y, _camera.global_position.z,
		view_distance,
	]