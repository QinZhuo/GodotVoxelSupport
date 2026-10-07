@tool
extends Node3D

## 单技法场景：L-系统成林（`PcgLsystem`）——只看一种算子，把它推到能看的程度。
##
## 【这一场景要说清的一件事：同一套文法，形态差别从哪来】
## `PcgLsystem` **没有 seed**——它本来就不含随机，输出是文法展开的确定结果。
## 所以"每棵树不一样"只能靠**参数**，于是这里分两排做对照：
##   后排 4 棵 = 四种不同**文法**（`rules` 不同）：决定"生长的规则本身"。
##   前排 5 棵 = 同一文法，只改 `iterations / step / thickness / angle_degrees`：
##               决定"同一规则的疏密与姿态"。
## 两排并排，"规则"与"参数"各自对形态的贡献一眼可分。
##
## 【上限在哪】`PcgLsystem.MAX_SYMBOLS = 100_000`：单次展开超过 10 万符号会截断，
## 所以迭代次数与步长不能无脑加大——树冠撑满 32 体素见方就是这台生成器的实际上限。
## 32³ 体素 = 1 个 chunk = 6.4 世界单位（voxel_scale = 0.2）。
##
## 【与框架的关系】每个模型仍是"有界 VoxelData + PcgModelGenerator + VoxelRenderer"，
## 组装走 PcgSceneKit——场景脚本只描述"造什么树、摆在哪"。

@export var voxel_scale: float = 0.2
## 加载半径：所有树的 chunk 都要落进来（有界数据的流式驱动也看它，见 pcg_world_demo 文件头）。
@export var view_distance: float = 42.0

const GRID := Vector3i(32, 32, 32)

## 后排：四种文法（[规则, 迭代]），起始符号统一 "F"。
const GRAMMARS := [
	["F=FF[+F][-F][&F][^F]", 3],   # 主干翻倍 + 四向分枝 → 三维树
	["F=F[+F]F[-F]F", 4],          # 经典分叉，枝条细密
	["F=FF-[-F+F+F]+[+F-F-F]", 3], # 带卷曲的灌木形
	["F=F[&F][^F][+F][-F]", 4],    # 上下左右四向均分，伞形
]

## 前排：同一文法（取 GRAMMARS[0]），只调参数 [迭代, 步长, 粗细, 角度]。
const VARIANTS := [
	[3, 1.0, 0.6, 18.0],
	[3, 1.4, 0.8, 24.0],
	[3, 1.7, 0.9, 30.0],
	[4, 1.1, 0.7, 20.0],
	[4, 1.3, 0.8, 27.0],
]

## 树叶/树干的绿，按树给不同深浅，避免整片同色。
const LEAF_COLORS := [
	Color(0.30, 0.48, 0.24),
	Color(0.36, 0.55, 0.28),
	Color(0.42, 0.60, 0.33),
]


func _ready() -> void:
	_build_row_grammars()
	_build_row_variants()
	_setup_camera()
	print("[PCG森林Demo] %d 棵 L-系统树已提交生成" % (GRAMMARS.size() + VARIANTS.size()))


## 后排：四种文法各一棵，位置固定、参数固定。
func _build_row_grammars() -> void:
	var z := -5.0
	var x0 := -13.2
	for i in GRAMMARS.size():
		var g: Array = GRAMMARS[i]
		var tree := PcgLsystem.new()
		tree.axiom = "F"
		tree.rules = PackedStringArray([g[0]])
		tree.iterations = g[1]
		tree.step = 1.5
		tree.thickness = 0.8
		tree.angle_degrees = 26.0
		tree.material_id = 1
		_add_tree("Grammar_%d" % (i + 1), Vector3(x0 + i * 8.8, 0.0, z), tree, LEAF_COLORS[0])


## 前排：同一文法，只改参数（对照"参数对形态的调制"）。
func _build_row_variants() -> void:
	var z := 3.0
	var x0 := -17.6
	for i in VARIANTS.size():
		var v: Array = VARIANTS[i]
		var tree := PcgLsystem.new()
		tree.axiom = "F"
		tree.rules = PackedStringArray([GRAMMARS[0][0]])
		tree.iterations = v[0]
		tree.step = v[1]
		tree.thickness = v[2]
		tree.angle_degrees = v[3]
		tree.material_id = 1
		_add_tree("Variant_%d" % (i + 1), Vector3(x0 + i * 8.8, 0.0, z), tree, LEAF_COLORS[i % LEAF_COLORS.size()])


func _add_tree(model_name: String, pos: Vector3, tree: PcgLsystem, color: Color) -> void:
	var gen := PcgModelGenerator.new()
	gen.model = tree
	var node := PcgSceneKit.add_model(self, model_name, pos, gen, GRID,
			PcgSceneKit.materials([[1, color, 0.9]]), false, voxel_scale)
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
	cam.global_position = Vector3(0.0, 15.0, 27.0)
	cam.look_at(Vector3(0.0, 4.0, -1.0), Vector3.UP)