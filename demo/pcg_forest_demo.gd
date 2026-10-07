@tool
extends Node3D

## 单技法场景：L-系统成林（`PcgLsystem`）——只看一种算子，把它推到能看的程度。
##
## 【这一场景要说清的一件事：同一套文法，形态差别从哪来】
## 现在有三层，每层单独可控：
##   后排 4 棵 = 四种不同**文法**（`rules` 不同）：决定"生长的规则本身"。
##   前排 5 棵 = 同一文法，只改 `iterations / step / thickness / angle_degrees`：
##               决定"同一规则的疏密与姿态"。
##   随机林     = 同一文法 + **同一套参数**，只给不同 `seed`：
##               形态差别全部来自 `variation` 的抖动（转角/步长/朝向/粗细）。
## 三者并排，"规则"、"参数"、"随机种子"各自对形态的贡献一眼可分。
##
## 【为什么对照排要整齐、随机林要散】
## 对照排**故意**保持等间距 —— 它是实验对照，位置不能成为干扰变量。
## 而随机林用 PcgScatter 按"最小间距 + 密度衰减"撒点：等间距 + 零旋转 + 等比缩放
## 是"人工摆放"的典型特征，也是场景廉价感的最大来源。两者的差异本身就是演示。
##
## 【两处让树脱离"棍子"观感的参数】
##   taper —— 枝干随分叉深度渐细。恒定粗细的树像一串等粗的棍子。
##   tip_material_id —— 末梢另盖一个叶团并换成第二种材质，于是"树干褐 / 叶片绿"
##             成为可能（`build()` 本来就返回每体素一个材质 ID，此前只是没往里写）。
##
## 【上限在哪】`PcgLsystem.MAX_SYMBOLS = 100_000`：单次展开超过 10 万符号会截断，
## 所以迭代次数与步长不能无脑加大 —— 但实测"能塞进 32×48×32 的量级"离这个上限
## 还很远：it=5 / step=2.5 展开后约 4 万符号、树高 26 体素。见下面 TREE 常量。
##
## 【与框架的关系】每个模型仍是"有界 VoxelData + PcgModelGenerator + VoxelRenderer"，
## 组装走 PcgSceneKit——场景脚本只描述"造什么树、摆在哪"。

@export var voxel_scale: float = 0.2
## 加载半径：所有树的 chunk 都要落进来（有界数据的流式驱动也看它，见 pcg_world_demo 文件头）。
@export var view_distance: float = 52.0
## 随机林：撒多少棵。
@export var forest_count: int = 14


# ----------------------------------------------------------------------------
# 树：分辨率与文法
# ----------------------------------------------------------------------------

## 树的网格。**32×48×32 而不是 32³** 是踩出来的：`PcgLsystem` 从网格中心生长，
## 树冠横向半径在 20 体素以上，32³ 会把两侧削平成刀切面；高度留一倍之后，
## 26 体素高的树在 32 宽的横截面里实测 0 体素越界。
## 网格变大只是**容量**变大（体素总量 32³→48k），不是分辨率变高——
## 真正让树"有细节"的是把树本身长到 26 体素高（见 TREE_* 常量），
## 此前 it=3 / step=1.5 长出来的树只有 11 体素、104 个实心体素，
## 那个分辨率下任何细节层都无处安放。
const GRID := Vector3i(32, 48, 32)

## 成林用的形态参数（实测标定：seed 1000/1002/2000 分别得 3390/3225/3274 个实心体素、
## 包围盒 20~22 × 26 × 24）。取 step=2.5 + it=5 是"塞满网格"与"不越界"的平衡点：
## step 再大会横向越界（22 + 树冠半径超过 32），it 再加只会让枝端互相重叠。
const TREE_STEP := 2.5
const TREE_ITERATIONS := 5
const TREE_ANGLE := 22.0
const TREE_THICKNESS := 0.9
const TREE_TIP_RADIUS := 2.4

## 后排：四种文法（[规则, 迭代]），起始符号统一 "F"。
##
## 【每条文法都必须是"三维"的，不能只是看起来分叉】起始朝向是**竖直**的，
## 此时 `+`/`-` 绕竖直轴旋转 = 没转，第一层分枝全部落在同一个竖直平面内。
## 实测 `F=F[+F]F[-F]F` 展开后包围盒 14×13×**4**（扁平度 0.29）、
## `F=FF-[-F+F+F]+[+F-F-F]` 是 9×16×**4**（0.25）—— 屏幕上就是两张**平面扇叶**。
## 修法是"先绕竖直轴掰开平面、再离轴俯仰"：把括号内的 `+F`/`-F` 写成 `+&F`/`-&F`。
## 改后同一对文法分别是 11×12×9（0.75）与 6×12×10（0.50）。
## `_two_stage` 只做符号改写（F→X），旋转一字不动，所以修好的必须写在常量里。
const GRAMMARS := [
	["F=FF[+F][-F][&F][^F]", 4],     # 主干翻倍 + 四向分枝 → 三维树
	["F=F[+&F]F[-&F]F", 4],          # 经典分叉 + 掰开平面，枝条细密
	["F=FF-[-&F+&F+&F]+[+&F-&F-&F]", 3], # 带卷曲的灌木形
	["F=F[&F][^F][+F][-F]", 4],      # 上下左右四向均分，伞形
]

## 前排：同一文法（取 GRAMMARS[0]），只调参数 [迭代, 步长, 粗细, 角度]。
const VARIANTS := [
	[4, 1.9, 0.8, 16.0],
	[4, 2.5, 0.9, 22.0],
	[5, 2.5, 0.9, 28.0],
	[5, 3.1, 1.1, 20.0],
	[5, 2.2, 1.3, 34.0],
]

## 随机林用的文法：分枝多且方向全，适合靠 seed 抖动拉开个体差异。
const FOREST_RULE := "F=F[&F][^F][+F][-F][+F]F[-F]"


# ----------------------------------------------------------------------------
# 调色板
# ----------------------------------------------------------------------------

## 树干色（同一片林里按树给不同深浅）。
const BARK_COLORS := [
	Color(0.32, 0.23, 0.15),
	Color(0.38, 0.28, 0.18),
	Color(0.27, 0.20, 0.14),
]
## 叶片色（按树给不同深浅，避免整片同色）。
const LEAF_COLORS := [
	Color(0.21, 0.38, 0.15),
	Color(0.27, 0.46, 0.18),
	Color(0.33, 0.52, 0.23),
]


# ----------------------------------------------------------------------------
# 地面
# ----------------------------------------------------------------------------

## 地面原点（节点位置）。x/z 让 240×220 体素的地形把整个场景罩住，
## y 让"平均地表"正好落在世界 y = 0：base_y=4 → 顶面在体素 y=4 的上边界，
## 即 position.y + (4+1)×0.2 = 0 → position.y = -1.0。改 base_y 必须同步改这里。
const GROUND_ORIGIN := Vector3(-24.0, -1.0, -32.0)
const GROUND_GRID := Vector3i(240, 10, 220)

## 地面调色板。ID 与 PcgTerrain 的参数一一对应（缺一个就会渲染成调色板首色/黑块）。
##
## 【为什么草与岩都不能只有一色】本项目不用贴图，表面层次只能靠"更多不同颜色的体素"。
## 每个色相给三档，且**暗档偏冷、亮档偏暖**（不是单纯乘以亮度）——
## 纯明度缩放在体素上读作"同一块塑料的不同曝光"，加色相偏移才读作"受光的草/背光的草"。
const GROUND_MATERIALS := [
	[1, Color(0.19, 0.15, 0.11), 0.95],   # 1 深土
	[2, Color(0.28, 0.22, 0.15), 0.95],   # 2 下层土
	[3, Color(0.27, 0.25, 0.21), 0.95],   # 3 岩·暗（暖灰，不要偏蓝）
	[4, Color(0.34, 0.31, 0.26), 0.95],   # 4 岩·中
	[5, Color(0.43, 0.39, 0.32), 0.95],   # 5 岩·亮
	[6, Color(0.17, 0.30, 0.13), 0.9],    # 6 草·暗
	[7, Color(0.26, 0.40, 0.17), 0.9],    # 7 草·中
	[8, Color(0.36, 0.48, 0.23), 0.9],    # 8 草·亮（同时用作草丛）
	[9, Color(0.45, 0.39, 0.24), 0.9],    # 9 干土 / 砂
	[10, Color(0.38, 0.36, 0.32), 0.95],  # 10 碎石
]

## 地形生成器。参数在这里集中，改一处即可（不在 _ready 里散着 new）。
##
## 【为什么 relief 只给 ±3 体素】地表起伏是"读感"而非"玩法"：0.6 世界单位的起伏
## 已足够破掉平板感，再高会让树与地面之间出现明显的高低错位（树是按 height_voxel
## 查询逐棵吸附的，起伏越大，相邻两棵的落差越显眼）。
##
## 【点缀比例是实测往下压过的】第一版 tuft 0.05 / pebble 0.02 / pit 0.04 合计 11% 的
## 柱列带特征，在 0.2 体素尺度上等于"每 3 格一个凸起"，屏幕上是一片噪声而不是草地
## （像刚犁过的田）。压到 1.5% / 0.8% / 1.2% 之后，点缀变成"偶尔能看见的那几处"，
## 才是细节。凡是"细节点缀"类参数，先按 1/3 量级往下压再往上调，比反过来省时间。
static func _make_terrain() -> PcgTerrain:
	var t := PcgTerrain.new()
	t.base_y = 4
	t.relief_height = 3.0
	t.cell = 18.0
	# octaves 从 3 收到 2：第 3 层倍频的波长只有 4~5 体素，栅格化后全是 1 体素台阶，
	# 每个台阶的竖直面受光量都比顶面低一截 → 地表浮起一层"深色砂砾"（实测最刺眼）。
	# 起伏只要"看不出是平面"就够，不需要高频细节；高频留给材质色阶。
	t.octaves = 2
	t.seed = 20261007
	t.deep_material_id = 1
	t.subsoil_material_id = 2
	t.rock_ids = PackedInt32Array([3, 4, 5])
	t.grass_ids = PackedInt32Array([6, 7, 8])
	t.dry_material_id = 9
	t.tuft_material_id = 8
	t.pebble_material_id = 10
	t.patch_cell = 16.0
	t.grass_coverage = 0.72
	t.slope_threshold = 2
	# shade_cell 从 2.0 放开到 4.0（= 0.8 世界单位）。2.0 时草与岩的斑块只有 2 体素宽，
	# 远看每块只有 3~4 像素 —— 三档色阶退化成"迷彩布"，是这一版最大的观感缺陷。
	# 斑块至少要有 4~5 体素（≈ 一个树冠的 1/5），才读作"这块地是石头的"。
	t.shade_cell = 4.0
	t.tuft_ratio = 0.015
	t.pebble_ratio = 0.008
	# 浅坑再收到 0.008：坑底用的是岩·暗，在偏蓝的环境光下会读成"紫灰颗粒"，
	# 而坑是**单个**体素级别的特征，数量一多就是噪点而不是地貌。
	t.pit_ratio = 0.008
	return t


## 地面节点持有的地形实例（摆放物件时要问它地表高度）。
var _terrain: PcgTerrain


func _ready() -> void:
	PcgSceneKit.apply_environment(self)
	_build_ground()
	_build_row_grammars()
	_build_row_variants()
	_build_random_forest()
	_setup_camera()
	print("[PCG森林Demo] 地形 1 块 + 对照 9 棵（规则/参数）+ 随机林 %d 棵（seed 抖动）已提交生成"
			% forest_count)


## 地表世界高度：地形高度是纯函数，直接问，不必等网格建完。
##
## 【为什么不让调用方查体素】物件的落脚点必须在"摆放时"就确定，而地形的体素是
## 异步灌进 VoxelData 的 —— 查体素就得 await 整个地形建完（pcg_world_demo 的
## _ground_y_at 正是为此不得不 await 基底）。纯函数查询把摆放与生成解耦。
func _ground_y(wx: float, wz: float) -> float:
	var gx := (wx - GROUND_ORIGIN.x) / voxel_scale
	var gz := (wz - GROUND_ORIGIN.z) / voxel_scale
	return GROUND_ORIGIN.y + (float(_terrain.height_voxel(gx, gz)) + 1.0) * voxel_scale


## 散布器的地面查询：顺带把地表高度给出去，落点 y 不必在下面再算一遍。
func _ground_query(p: Vector2) -> Variant:
	return {PcgScatter.GROUND_KEY_Y: _ground_y(p.x, p.y)}


func _build_ground() -> void:
	_terrain = _make_terrain()
	var gen := PcgModelGenerator.new()
	gen.model = _terrain
	var node := PcgSceneKit.add_model(self, "Ground", GROUND_ORIGIN, gen, GROUND_GRID,
			PcgSceneKit.materials(GROUND_MATERIALS), false, voxel_scale)
	(node as VoxelRenderer).view_distance = view_distance


# ----------------------------------------------------------------------------
# 树
# ----------------------------------------------------------------------------

## 建一棵树。seed 驱动 variation 抖动，分区材质（1=树干 / 2=叶），taper 让枝干渐细。
##
## 注意对照排用很低的 variation（0.12）：这一排的意义是"参数可控地改变形态"，
## 抖动太大反而掩盖了参数差异；随机林才把 variation 拉满。
func _make_tree(rule: String, iterations: int, step: float, thickness: float,
		angle: float, seed_value: int, variation: float) -> PcgLsystem:
	var tree := PcgLsystem.new()
	# 【为什么要把单符号文法改造成两段式】`F=FF[...]` 这类经典文法的第一步就是分枝，
	# 从 axiom 直接起步的话树干每长一步就分叉、叶子从地面开始裹，长出来是**灌木**
	# 不是树（实测木头只占实心体素的 1.6%，屏幕上找不到一根裸露主干）。
	# 实现已下沉到 PcgLsystem.two_stage（pcg_world_demo 同样要用，不该各写一份）。
	var two := PcgLsystem.two_stage(rule)
	tree.axiom = "A"
	tree.rules = two
	tree.iterations = iterations
	tree.step = step
	tree.thickness = thickness
	tree.angle_degrees = angle
	tree.material_id = 1
	# 渐细：根粗梢细，否则整棵树像一串等粗的棍子
	tree.taper = 0.5
	# 末梢叶团换成材质 2 —— 树干褐、叶片绿由此成立
	tree.tip_material_id = 2
	# 叶团只长在**真正的枝端**。默认的"全部 F"档在展开后对每个 F 都成立
	#（所有符号深度相等，见 PcgLsystem._branch_terminals 的实测数据），
	# 于是连主干关节都裹上绿团，整棵树成了没有树干的绿雾。
	tree.tip_scope = PcgLsystem.TipScope.BRANCH_END
	tree.tip_radius = TREE_TIP_RADIUS
	tree.seed = seed_value
	tree.variation = variation
	return tree


## 每棵树的调色板：1/2 是树干与叶片基色（跨树按 index 换色，拉开个体差异），
## 3~7 是**同色系梯度**，由 PcgSurfaceTint 逐体素挑档写入。
##
## 【为什么梯度要跟着基色算，而且要动色相】本项目不用贴图：每个体素一种颜色，
## 表面层次靠"更多不同颜色的体素"表达。若梯度只按亮度缩放，暗档 = 同一块塑料调低曝光，
## 读作"脏"而不是"背光"。故暗档往冷（蓝绿）偏、亮档往暖（黄）偏 —— 见 _graded。
func _tree_materials(i: int) -> Array:
	var bark: Color = BARK_COLORS[i % BARK_COLORS.size()]
	var leaf: Color = LEAF_COLORS[i % LEAF_COLORS.size()]
	return PcgSceneKit.materials([
		[1, bark, 0.95],                                # 树干基色
		[2, leaf, 0.85],                                # 叶片基色
		[3, PcgSceneKit.graded(bark, 0.62), 0.95],      # 树干·暗（偏冷）
		[4, PcgSceneKit.graded(bark, 1.30), 0.95],      # 树干·亮（偏暖）
		[5, PcgSceneKit.graded(leaf, 0.58), 0.9],       # 叶·暗
		[6, leaf, 0.85],                                # 叶·中
		[7, PcgSceneKit.graded(leaf, 1.32), 0.85],      # 叶·亮
	])


## 树叶分档：材质 2 → [5,6,7]。树冠是树的主要视觉体量，单色时整棵像塑料玩具。
## shade_cell 取 2.0：叶团本身只有几个体素宽，再细就会退化成逐体素随机的噪点。
## cell 从 3.0 放宽到 4.0：树冠现在有 22 体素宽，3.0 会把"苔藓斑"切得过碎。
func _leaf_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([5, 6, 7])
	t.only_source_material_id = 2
	t.coverage = 0.92
	t.cell = 4.0
	t.shade_cell = 2.0
	t.min_exposure = 1
	return t


## 树干分档：材质 1 → [3,4] 两档。树干只有 1~2 体素粗，三档会读成斑点狗。
func _trunk_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([3, 4])
	t.only_source_material_id = 1
	t.coverage = 0.85
	t.cell = 4.0
	t.shade_cell = 1.0
	t.min_exposure = 1
	return t


func _add_tree(model_name: String, pos: Vector3, tree: PcgLsystem, color_i: int,
		yaw: float = 0.0, scale_mul: float = 1.0) -> void:
	var gen := PcgModelGenerator.new()
	gen.model = tree
	# 风化让枝叶表面出现缺角，抵消"纯数学体素"的规整感。
	# strength 从 0.1 提到 0.16：树体一轮从 104 体素涨到 3300+，
	# 这个量级经得起啃，且叶团表面的"锯齿缺口"正是体素植物的关键质感。
	var weather := PcgWeather.new()
	weather.strength = 0.16
	weather.cell = 2.5
	weather.min_exposure = 2   # 只蚀细枝末端，保住主干的完整感
	gen.details = [weather, _leaf_shade(), _trunk_shade()]
	var node := PcgSceneKit.add_model(self, model_name, pos, gen, GRID,
			_tree_materials(color_i), false, voxel_scale * scale_mul)
	if node is VoxelRenderer:
		(node as VoxelRenderer).view_distance = view_distance
	if node is Node3D:
		(node as Node3D).rotation.y = yaw


## 后排：四种文法各一棵。位置刻意等间距 —— 对照实验不能让位置成为变量。
func _build_row_grammars() -> void:
	var z := -5.0
	var x0 := -13.2
	for i in GRAMMARS.size():
		var g: Array = GRAMMARS[i]
		var tree := _make_tree(g[0], g[1], TREE_STEP, TREE_THICKNESS, TREE_ANGLE, 1000 + i, 0.12)
		_add_tree("Grammar_%d" % (i + 1), Vector3(x0 + i * 8.8, _ground_y(x0 + i * 8.8, z), z), tree, i)


## 前排：同一文法，只改参数。
func _build_row_variants() -> void:
	var z := 4.0
	var x0 := -17.6
	for i in VARIANTS.size():
		var v: Array = VARIANTS[i]
		var tree := _make_tree(GRAMMARS[0][0], v[0], v[1], v[2], v[3], 2000 + i, 0.12)
		_add_tree("Variant_%d" % (i + 1), Vector3(x0 + i * 8.8, _ground_y(x0 + i * 8.8, z), z), tree, i)


## 随机林：同一文法、同一套参数，形态差别只来自 seed。
## 位置来自 PcgScatter（最小间距 + 密度衰减 + 随机 yaw/缩放 + 地面高度查询），
## 每棵树的 seed 直接取该次摆放的 variant_seed —— 于是"位置"与"形态"由同一种子决定。
func _build_random_forest() -> void:
	var scatter := PcgScatter.new()
	scatter.center = Vector2(0.0, -14.0)
	scatter.radius = 14.0
	scatter.count = forest_count
	# 树冠实测 20~22 体素宽（4~4.4 世界单位），间距低于 4.6 就会挤成一团；
	# 散布器是"每格取一点、格边长 = spacing"的网格采样，间距同时决定上限与密度。
	scatter.spacing = 4.6
	scatter.spacing_jitter = 0.35
	scatter.density = 0.9
	scatter.density_scale = 16.0
	scatter.seed = 20261007
	scatter.scale_min = 0.7
	scatter.scale_max = 1.15
	scatter.ground_query = _ground_query
	var placements := scatter.generate()
	for i in placements.size():
		var pl: PcgScatter.Placement = placements[i]
		# 散布器给的 basis 已含随机 yaw 与随机缩放：旋转取欧拉 Y，
		# 缩放要单独取出（作用在 voxel_scale 上，而不是缩放整个节点——
		# 节点被缩放会把 32×48×32 网格的体素一起放大，而体素生成是按体素算的）。
		var basis := pl.xform.basis
		var yaw := basis.get_euler().y
		var scale_mul := basis.get_scale().x
		var tree := _make_tree(FOREST_RULE, TREE_ITERATIONS, TREE_STEP, TREE_THICKNESS,
				TREE_ANGLE, pl.variant_seed, 0.45)
		# 落点必须落在**树干**上，而不是节点原点。PcgLsystem 从网格中心 (x/2, 1, z/2)
		# 生长，而 add_model 把节点原点钉在网格最小角 —— 于是树干比落点偏了半个网格
		# （16 体素 × 0.2 = 3.2 单位）。这正是原来"半径 14 的圆里有一半树悬空在岛外"
		# 的根因：偏移不是靠缩小树体能消掉的常量，而是固定等于半个网格。
		# 节点自身还要绕 Y 转 yaw，所以偏移要一起转到世界空间再减掉。
		var trunk_offset := Vector3(GRID.x * 0.5, 0.0, GRID.z * 0.5) * (voxel_scale * scale_mul)
		var pos := pl.xform.origin - Basis(Vector3.UP, yaw) * trunk_offset
		# 树心与落点错开半个网格后，y 要用**树心处**的地表高度，否则坡地上的树会半悬。
		pos.y = _ground_y(pl.xform.origin.x, pl.xform.origin.z)
		_add_tree("Forest_%d" % (i + 1), pos, tree, i, yaw, scale_mul)


## 相机：**贴地平视**是这一场景的关键。
##
## 【为什么不能沿用俯视机位】原来是 (0,17,30) 俯视 —— 树高 1.4~3 单位，
## 在 60° 视场下只占画面 20%，实测 77% 的像素是同一片天空灰（同色桶占比 99.5%）。
## 画面里"空"比"模型差"更致命。改成 y≈4（树冠中部高度）平视之后，
## 树占据画面主体，地面与投影把景深撑开。
func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 56.0
	cam.far = 400.0
	# 机位在**树冠中部**（树高 5~7 世界单位，故 y≈5.6）：低了只能看到一片树干，
	# 高了又变回俯视（地面吃掉半屏）。视线略过树冠下沿，景深由"近树—远林"撑开。
	cam.global_position = Vector3(6.5, 5.6, 15.0)
	cam.look_at(Vector3(-1.0, 3.0, -7.0), Vector3.UP)
