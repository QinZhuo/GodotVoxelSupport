@tool
extends Node3D

## 单技法场景：两种 WFC 并排（socket 式 `PcgWfc` vs 重叠式 `PcgWfcOverlap`）。
##
## 【要看清的差别：规则从哪里来】
##   socket 式（左两座）—— 作者**手写**每块图块六面的接口名，WFC 只做"接口配对"。
##       可控、可解释：本场景用 4³ 图块拼出"石基 - 地板 - 柱 - 地板"的多层遗迹。
##       竖向约束最强（地板下方必须 rock、上方必须留空），于是结构自然向上堆叠。
##   socket 式（右两片）—— 重叠式，作者只给**一块样例**，算法自己"数"出所有 N³
##       小窗口当图案，再让图案重叠地拼满输出。规则自动学到，代价是候选多得多
##       （每格一个图案，求解远重于 socket 式，故网格上限只有 24³）。
##       样例是一块多孔岩（见 PcgSceneKit.overlap_sample），输出即同类的多孔岩体。
##
## 【同参数不同 seed】同一档内两件只差 seed：布局不同，但各自完全确定可复现
## （同 seed 恒同结果）——这正是"随机外观 + 可复现世界"的常规做法。

@export var voxel_scale: float = 0.2
## 加载半径：所有模型的 chunk 都要落进来。
@export var view_distance: float = 42.0

const RUIN_GRID := Vector3i(32, 48, 32)
## 重叠式每格一个图案，格数 = 输出体素数，故网格远小于 socket 式（上限 24³）。
const OVERLAP_GRID := Vector3i(24, 24, 24)

const RUIN_MATERIALS := [
	[1, Color(0.55, 0.45, 0.3), 0.9],    # 地板（木/砂岩）
	[2, Color(0.75, 0.7, 0.6), 0.95],    # 石柱
	[3, Color(0.42, 0.4, 0.4), 0.95],    # 石基
]

const POROUS_MATERIALS := [
	[1, Color(0.5, 0.47, 0.44), 0.95],
	[2, Color(0.45, 0.6, 0.4), 0.8],
]


func _ready() -> void:
	_build_ruins()
	_build_walls()
	_setup_camera()
	print("[PCG遗迹Demo] 2 座 socket 式遗迹 + 2 片重叠式多孔岩已提交生成")


## 左：socket 式 WFC。图块手写接口名，四块拼出多层结构。
func _build_ruins() -> void:
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

	for i in 2:
		var wfc := PcgWfc.new()
		wfc.tiles = [open, rock, floor_t, pillar]
		wfc.seed = 20261007 + i * 977
		wfc.max_retries = 12
		var gen := PcgModelGenerator.new()
		gen.model = wfc
		_add("Ruin_%d" % (i + 1), Vector3(-16.0 + i * 10.5, 0.0, 0.0), gen, RUIN_GRID,
				PcgSceneKit.materials(RUIN_MATERIALS))


## 右：重叠式 WFC。规则从 8³ 样例里学，输出一片同类多孔岩。
func _build_walls() -> void:
	var sample_size := Vector3i(8, 8, 8)
	for i in 2:
		var overlap := PcgWfcOverlap.new()
		overlap.sample = PcgSceneKit.overlap_sample(sample_size)
		overlap.sample_size = sample_size
		overlap.pattern_size = 3
		overlap.seed = 20261007 + i * 977
		overlap.max_retries = 8
		var gen := PcgModelGenerator.new()
		gen.model = overlap
		_add("Porous_%d" % (i + 1), Vector3(6.5 + i * 10.0, 0.0, 0.0), gen, OVERLAP_GRID,
				PcgSceneKit.materials(POROUS_MATERIALS))


func _add(model_name: String, pos: Vector3, gen: VoxelGenerator, grid_size: Vector3i, mats: Array) -> void:
	var node := PcgSceneKit.add_model(self, model_name, pos, gen, grid_size, mats, false, voxel_scale)
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
	cam.global_position = Vector3(0.0, 16.0, 30.0)
	cam.look_at(Vector3(0.0, 6.0, 0.0), Vector3.UP)