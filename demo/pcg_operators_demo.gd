@tool
extends Node3D

## 程序化体素算子演示（PCG：L-系统 / 元胞自动机 / WFC）——三个彼此独立的模型。
##
## 这三个算子与 SDF 走的是**两条路**：
##   SDF      —— 逐点函数 sample(p)，适合"由简单件组合出的实体"（见 pcg_models_demo）
##   PcgModel —— 整体产出 build(grid_size)，适合"必须全局迭代才算得出来的东西"
## 三者都实现 PcgModel，因此共用同一个适配器 PcgModelGenerator——
## 要加一种新算子，只需再写一个 build()，切 chunk / 缓存 / LOD 全项目只此一份。
##
## 左（L-系统）：文法改写 + 3D 乌龟盖章 → 一棵树
## 中（元胞自动机）：随机播撒 + 26 邻域平滑 → 洞穴
## 右（WFC）：图块按六面接口拼接 → 涌现出多层遗迹
##
## 每个模型 = 【有界 VoxelData】+【PcgModelGenerator（内嵌一个 PcgModel）】+【VoxelRenderer 节点】。

## 体素世界尺度（模型 32³ 体素 → 世界 6.4 单位）
@export var voxel_scale: float = 0.2
## 模型的世界间距
@export var model_spacing: float = 13.0

const GRID := Vector3i(32, 32, 32)


func _ready() -> void:
	_build_lsystem(Vector3(-model_spacing, 0.0, 0.0))
	_build_cellular(Vector3.ZERO)
	_build_wfc(Vector3(model_spacing, 0.0, 0.0))
	_setup_camera()
	print("[PCG算子Demo] L-系统 / 元胞自动机 / WFC 三个模型已生成")


func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 60.0
	cam.global_position = Vector3(0.0, 12.0, 26.0)
	cam.look_at(Vector3(0.0, 3.5, 0.0), Vector3.UP)


# ----------------------------------------------------------------------------
# 三个算子
# ----------------------------------------------------------------------------

## L-系统：一条产生式迭代 2 次，乌龟从底面中心向上长出树冠。
func _build_lsystem(pos: Vector3) -> void:
	var tree := PcgLsystem.new()
	# 主干每轮翻倍（"FF"），四个方向各分一枝（+/− 偏航、&/^ 俯仰）→ 三维树而非平面树。
	tree.axiom = "F"
	tree.rules = PackedStringArray(["F=FF[+F][-F][&F][^F]"])
	tree.iterations = 3
	tree.step = 1.6
	tree.thickness = 0.8
	tree.angle_degrees = 30.0
	tree.material_id = 1
	_add_model("ModelL_Tree", pos, tree, GRID, [
		_material(1, Color(0.36, 0.55, 0.28), 0.9),
	])


## 元胞自动机：随机播撒 + 4 轮 26 邻域平滑 → 洞穴。
## 这里关掉封闭外壳（shell_is_solid=false），好让内腔在外部可见；要"正宗"的封闭洞穴把它打开即可。
func _build_cellular(pos: Vector3) -> void:
	var cave := PcgCellular.new()
	cave.fill_ratio = 0.50
	cave.iterations = 4
	cave.birth_limit = 13
	cave.death_limit = 12
	cave.seed = 20261007
	cave.shell_is_solid = false
	cave.material_id = 1
	_add_model("ModelC_Cave", pos, cave, GRID, [
		_material(1, Color(0.5, 0.47, 0.44), 0.95),
	])


## WFC：四块 4³ 图块按六面接口拼接（竖向约束最强 → 自然叠出"石基-地板-柱-地板"的多层结构）。
func _build_wfc(pos: Vector3) -> void:
	var tile := Vector3i(4, 4, 4)

	# 空：六面皆 air，纯留白。
	var open := _wfc_tile(tile, ["air", "air", "air", "air", "air", "air"], 2.0, 0,
			func(_x, _y, _z): return false)
	# 石：实心，上下皆为 rock → 只能夹在"上下面朝 rock"的图块之间。
	var rock := _wfc_tile(tile, ["air", "air", "rock", "rock", "air", "air"], 1.0, 3,
			func(_x, _y, _z): return true)
	# 地板：底层实心；下方必须接 rock，上方留空。
	var floor_t := _wfc_tile(tile, ["air", "air", "air", "rock", "air", "air"], 1.5, 1,
			func(_x, y, _z): return y == 0)
	# 柱：2×2 通高；下方留空（可立于地板），上方为 rock（可再叠地板）。
	var pillar := _wfc_tile(tile, ["air", "air", "rock", "air", "air", "air"], 0.8, 2,
			func(x, _y, z): return x >= 1 and x <= 2 and z >= 1 and z <= 2)

	var wfc := PcgWfc.new()
	wfc.tiles = [open, rock, floor_t, pillar]
	wfc.seed = 20261007
	wfc.max_retries = 12
	_add_model("ModelW_Ruins", pos, wfc, GRID, [
		_material(1, Color(0.55, 0.45, 0.3), 0.9),
		_material(2, Color(0.75, 0.7, 0.6), 0.95),
		_material(3, Color(0.42, 0.4, 0.4), 0.95),
	])


# ----------------------------------------------------------------------------
# 组装
# ----------------------------------------------------------------------------

## 一个模型 = 有界 VoxelData（grid_size 即生成范围）+ PcgModelGenerator + VoxelRenderer 节点。
func _add_model(model_name: String, pos: Vector3, pcg: PcgModel, grid_size: Vector3i,
		materials: Array) -> void:
	var data := VoxelData.new()
	for m in materials:
		data.add_material(m)

	var generator := PcgModelGenerator.new()
	generator.model = pcg
	data.generator = generator
	data.grid_size = grid_size

	var renderer := VoxelRenderer.new()
	renderer.name = model_name
	renderer.data = data
	renderer.voxel_scale = voxel_scale
	renderer.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	add_child(renderer)
	renderer.global_position = pos


## 构造一块 WFC 图块：solid(x, y, z) 返回 true 的格子填 material_id。
func _wfc_tile(tile_size: Vector3i, sockets: Array, weight: float, material_id: int,
		solid: Callable) -> PcgWfcTile:
	var voxels := PackedInt32Array()
	voxels.resize(tile_size.x * tile_size.y * tile_size.z)
	for z in tile_size.z:
		for y in tile_size.y:
			for x in tile_size.x:
				if solid.call(x, y, z):
					voxels[x + y * tile_size.x + z * tile_size.x * tile_size.y] = material_id
	return PcgWfcTile.make(tile_size, voxels, PackedStringArray(sockets), weight)


func _material(id: int, color: Color, rough: float) -> VoxelMaterial:
	var m := VoxelMaterial.new()
	m.id = id
	m.color = color
	m.rough = rough
	m.hardness = 5.0
	m.connection_strength = 20.0
	m.mass = 2.0
	return m
