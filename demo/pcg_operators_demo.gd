@tool
extends Node3D

## 程序化体素算子演示（PCG：L-系统 / 元胞自动机 / WFC / 重叠式 WFC）——四个彼此独立的模型。
##
## 这四个算子与 SDF 走的是**两条路**：
##   SDF      —— 逐点函数 sample(p)，适合"由简单件组合出的实体"（见 pcg_models_demo）
##   PcgModel —— 整体产出 build(grid_size)，适合"必须全局迭代才算得出来的东西"
## 四者都实现 PcgModel，因此共用同一个数据层组装——
## 要加一种新算子，只需再写一个 build()，切 chunk / 缓存 / LOD 全项目只此一份。
##
## 左上（L-系统）：文法改写 + 3D 乌龟盖章 → 一棵树
## 右上（元胞自动机）：随机播撒 + 26 邻域平滑 → 洞穴
## 左下（WFC socket 式）：图块按**手写的六面接口名**拼接 → 多层遗迹
## 右下（WFC 重叠式）：规则不手写，从一块**样例**里"数"出可重叠的图案 → 再拼出一片废墟
##
## 每个模型 = 【有界 QVoxelSource（node = 内嵌一个 PcgModel）】+【VoxelRenderer 节点】。

## 体素世界尺度（模型 32³ 体素 → 世界 6.4 单位）
@export var voxel_scale: float = 0.2
## 模型的世界间距（四模型摆成 2×2）
@export var model_spacing: float = 13.0

const GRID := Vector3i(32, 32, 32)
## 重叠式 WFC 的网格：它每格一个图案，格数 = 输出体素数，远重于 socket 式，故用更小的网格。
const OVERLAP_GRID := Vector3i(24, 24, 24)


func _ready() -> void:
	PcgSceneKit.apply_environment(self)
	var h := model_spacing * 0.5
	_build_lsystem(Vector3(-h, 0.0, -h))
	_build_cellular(Vector3(h, 0.0, -h))
	_build_wfc(Vector3(-h, 0.0, h))
	_build_wfc_overlap(Vector3(h, 0.0, h))
	_setup_camera()
	print("[PCG算子Demo] L-系统 / 元胞自动机 / WFC / 重叠式WFC 四个模型已生成")


func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 60.0
	cam.global_position = Vector3(0.0, 13.0, 24.0)
	cam.look_at(Vector3(0.0, 3.5, 0.0), Vector3.UP)


# ----------------------------------------------------------------------------
# 四个算子
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


## 重叠式 WFC：规则不手写，从一块 8³ 样例里"数"出可重叠的 N³ 图案。
## 样例是一块多孔岩（见 _overlap_sample）—— 学出来的图案再被拼成一片同类岩体。
func _build_wfc_overlap(pos: Vector3) -> void:
	var sample_size := Vector3i(8, 8, 8)
	var ov := PcgWfcOverlap.new()
	ov.sample = _overlap_sample(sample_size)
	ov.sample_size = sample_size
	ov.pattern_size = 3
	ov.seed = 20261007
	ov.max_retries = 8
	_add_model("ModelO_Overlap", pos, ov, OVERLAP_GRID, [
		_material(1, Color(0.5, 0.47, 0.44), 0.95),
		_material(2, Color(0.45, 0.6, 0.4), 0.8),
	])


## 样例：一块多孔岩 —— 实心岩石里挖出孔洞，部分孔洞填着另一种材质。
##
## 【样例怎么挑：重叠式能不能求出解，全看样例的图案有没有重复】
##   ① 不能是"地板 + 一圈墙"这类**稀疏骨架**：8³ 里大部分为空的样例学出的图案
##      绝大多数是纯空气，且纯空气自相容，WFC 会整体坍缩进"整块全空"的退化解。
##   ② 也不能是**白噪声**：每个 N³ 窗口都唯一（8³ 配 N=3 即 216/216 全不同），
##      相容图近乎一条无环长链，铺到网格边缘必然死路，8 次重试全矛盾（实测）。
##   ③ 要的是**致密 + 图案重复**：孔洞用两族周期互质（5 与 6）的斜切取并集，
##      于是 8³ 样例内每族各自重复数轮，学出的图案既能拼、又有多样性。
##   单族斜切是平行平面，输出会露出明显的"格栅"；两族相交后才成团状的天然孔隙。
func _overlap_sample(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var m := 0
				if (x + 2 * y + 3 * z) % 5 < 2 or (2 * x + y - z) % 6 < 2:
					m = 2 if (x + z) % 3 == 0 else 1
				v[x + y * size.x + z * size.x * size.y] = m
	return v


# ----------------------------------------------------------------------------
# 组装
# ----------------------------------------------------------------------------

## 一个模型 = 有界 QVoxelSource（grid_size 即生成范围）+ QVoxelModel（链上挂产出算子）
## + VoxelRenderer 节点。
func _add_model(model_name: String, pos: Vector3, pcg: PcgModel, grid_size: Vector3i,
		materials: Array) -> void:
	var data := QVoxelSource.new()
	for m in materials:
		data.add_material(m)

	data.node = QVoxelModel.of_source(pcg, grid_size)
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
