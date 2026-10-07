@tool
extends Node3D

## 单技法场景：两种 WFC 并排（socket 式 `PcgWfc` vs 重叠式 `PcgWfcOverlap`）。
##
## 【要看清的差别：规则从哪里来】
##   socket 式（左两座）—— 作者**手写**每块图块六面的接口名，WFC 只做"接口配对"。
##       可控、可解释：图块集把"结构骨架"编码进接口名（详见 PcgSceneKit.ruin_tiles 的说明：
##       core/edge 对齐 + 柱墙居中 + rock/air 竖向链 + open 高权重稀疏化）。
##   重叠式（右两片）—— 作者只给**一块样例**，算法自己"数"出所有 N³ 小窗口当图案，
##       再让图案重叠地拼满输出。规则自动学到，代价是候选多得多（每格一个图案，
##       求解远重于 socket 式，故网格上限只有 24³）。样例是一块多孔岩，
##       输出即同类的多孔岩体。
##
## 【同参数不同 seed】同一档内两件只差 seed：布局不同，但各自完全确定可复现
## （同 seed 恒同结果）——这正是"随机外观 + 可复现世界"的常规做法。
##
## 【两件共用的表现层】两档都挂了细节层：PcgWeather 按噪声啃掉暴露体素制造缺角与
## 凹坑（破掉"刀切垂直的方盒"观感），遗迹还额外用 PcgSurfaceTint 按朝上表面挂苔藓。
## 细节层对三条产出栈统一生效，所以重叠式多孔岩同样吃到了风化。

@export var voxel_scale: float = 0.2
## 加载半径：所有模型的 chunk 都要落进来。
@export var view_distance: float = 42.0

## socket 式网格：TILE 必须整除，否则图块跨 block 边界、结构会被切断。
const TILE := 6
const RUIN_GRID := Vector3i(36, 48, 36)
## 重叠式每格一个图案，格数 = 输出体素数，故网格远小于 socket 式（上限 24³）。
const OVERLAP_GRID := Vector3i(24, 24, 24)

## 分区材质：不再"整块一个纯色"。同一座遗迹里地板/柱/墙/基岩/碎石各是一种材质，
## 苔藓色不由图块写入，而由细节层 PcgSurfaceTint 按位置生成。
## ID 需与 PcgSceneKit.ruin_tiles 里各图块的 material_id 对应。
##
## 【albedo 是反射率不是显示色，别按"好看的颜色"写】早先这套路是 0.62/0.72，
## 加上方向光直接过曝成一片白（截图里遗迹发白就是这个）。真实岩石反射率约 0.15~0.35，
## 与 pcg_world_demo 调过的一档看齐，中间调才落在 0.35 上下、体素颗粒才读得出来。
##
## 【6~11 是"同色系调色板梯度"，不是新结构材质】本项目不用贴图：每个体素一种颜色，
## 表面层次靠"更多不同颜色的体素"表达。1~5 是图块写入的结构色，6~11 只由
## PcgSurfaceTint 在后处理阶段逐体素挑档写入，不参与图块接口，故 ID 排在后面即可。
## 每档都是同一基色的 暗/中/亮，避免"拼色块"感。
const RUIN_MATERIALS := [
	[1, Color(0.34, 0.28, 0.18), 0.9],    # 1 地板（木/砂岩）
	[2, Color(0.30, 0.29, 0.27), 0.95],   # 2 石柱 / 墙（会被染苔藓）
	[3, Color(0.38, 0.35, 0.30), 0.95],   # 3 深土基岩
	[4, Color(0.24, 0.29, 0.20), 0.85],   # 4 苔藓（仅由 PcgSurfaceTint 写入）
	[5, Color(0.26, 0.22, 0.17), 0.9],    # 5 碎石
	# 石柱/墙三档（基色 0.30/0.29/0.27 的 暗/中/亮）
	[6, Color(0.23, 0.22, 0.21), 0.95],   # 6 墙·背光处
	[7, Color(0.30, 0.29, 0.27), 0.95],   # 7 墙·中
	[8, Color(0.36, 0.35, 0.33), 0.95],   # 8 墙·受光处
	# 地板三档（基色 0.34/0.28/0.18 的 暗/中/亮）
	[9, Color(0.27, 0.22, 0.14), 0.9],    # 9 地板·暗
	[10, Color(0.34, 0.28, 0.18), 0.9],   # 10 地板·中
	[11, Color(0.41, 0.34, 0.22), 0.9],   # 11 地板·亮
]

const POROUS_MATERIALS := [
	[1, Color(0.34, 0.32, 0.30), 0.95],
	[2, Color(0.30, 0.40, 0.27), 0.8],
	# 多孔岩三档（基色 0.34/0.32/0.30 的 暗/中/亮）
	[3, Color(0.27, 0.25, 0.24), 0.95],
	[4, Color(0.34, 0.32, 0.30), 0.95],
	[5, Color(0.41, 0.39, 0.36), 0.95],
]


func _ready() -> void:
	PcgSceneKit.apply_environment(self)
	_build_ruins()
	_build_walls()
	_setup_camera()
	print("[PCG遗迹Demo] 2 座 socket 式遗迹（柱网图块集 + 风化/苔藓细节层）"
			+ " + 2 片重叠式多孔岩已提交生成")


## 左：socket 式 WFC。图块集是共享实现（world demo 的遗迹也用同一套）。
func _build_ruins() -> void:
	var tiles := PcgSceneKit.ruin_tiles(TILE)
	for i in 2:
		var wfc := PcgWfc.new()
		wfc.tiles = tiles
		wfc.seed = 20261007 + i * 977
		wfc.max_retries = 16
		var gen := PcgModelGenerator.new()
		gen.model = wfc
		# 细节层顺序有意义：先风化挖出不规则表面，再挂苔藓。
		# 暴露判定是在风化之后算的，故新挖出的凹坑侧面也会被判为暴露面而正常上色。
		gen.details = [_make_weather(0.16), _make_moss(),
				_make_wall_shade(), _make_floor_shade()]
		gen.detail_seed = 20261007 + i * 977
		_add("Ruin_%d" % (i + 1), Vector3(-16.0 + i * 10.5, 0.0, 0.0), gen, RUIN_GRID,
				PcgSceneKit.materials(RUIN_MATERIALS))


## 风化：按噪声把暴露体素啃出缺角，破掉"刀切垂直的方盒"观感。
func _make_weather(strength: float) -> PcgWeather:
	var w := PcgWeather.new()
	w.strength = strength
	w.cell = 4.0
	w.edge_bias = 0.7       # 棱角先磨损
	w.protect_ground = true  # 保底不挖，模型仍与地面接触
	return w


## 苔藓：只染石柱/墙（材质 2），且偏向朝上的表面。
##
## 【coverage 别开大】0.26 时苔藓连成大片盖在柱子的**侧面**上，配上纯绿就成了一块块
## 绿漆，把石头的分档层次全盖掉。苔藓在这套画面里是**点缀**，得让石头当主角：
## 覆盖率压到 0.15、绿色往灰里靠一档（albedo 越纯越"荧光"）、噪声尺度放大到 4
## 让它成小团而不是均匀撒开。
func _make_moss() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_id = 4
	t.only_source_material_id = 2
	t.coverage = 0.15
	t.up_bias = 0.7
	t.cell = 4.0
	return t


## 石柱/墙分档：把剩下的墙面对应到 [6,7,8] 三档同色系深浅。
## 必须排在苔藓**之后** —— 苔藓先占掉朝上的那部分表面，剩下的才做深浅分档。
## shade_cell 取 2.0（约 2 体素一斑），是"看得出是一个个体素、又不碎成电视雪花"的档位；
## 取 1.0 会退化成逐体素随机、观感像噪点。
func _make_wall_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([6, 7, 8])
	t.only_source_material_id = 2
	t.coverage = 0.9
	t.cell = 5.0
	t.shade_cell = 2.0
	t.min_exposure = 1
	return t


## 地板分档：同上，作用于材质 1。地板是画面里最大的连续面，不分档时最显平涂。
func _make_floor_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([9, 10, 11])
	t.only_source_material_id = 1
	t.coverage = 0.9
	t.cell = 5.0
	t.shade_cell = 2.5
	t.min_exposure = 1
	t.protect_ground = false
	return t


## 多孔岩分档：材质 1 → [3,4,5]。
func _make_rock_shade() -> PcgSurfaceTint:
	var t := PcgSurfaceTint.new()
	t.material_ids = PackedInt32Array([3, 4, 5])
	t.only_source_material_id = 1
	t.coverage = 0.85
	t.cell = 5.0
	t.shade_cell = 2.0
	t.min_exposure = 1
	return t


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
		# 多孔岩同样吃风化，否则强重叠样本只会产出规整的孔洞方块。
		# 再叠一层分档换色：孔洞边缘的石块逐体素挑暗/中/亮，破掉整片平涂。
		gen.details = [_make_weather(0.12), _make_rock_shade()]
		gen.detail_seed = 4242 + i * 31
		_add("Porous_%d" % (i + 1), Vector3(6.5 + i * 10.0, 0.0, 0.0), gen, OVERLAP_GRID,
				PcgSceneKit.materials(POROUS_MATERIALS))


func _add(model_name: String, pos: Vector3, gen: VoxelGenerator, grid_size: Vector3i, mats: Array) -> void:
	var node := PcgSceneKit.add_model(self, model_name, pos, gen, grid_size, mats, false, voxel_scale)
	if node is VoxelRenderer:
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
	cam.global_position = Vector3(0.0, 18.0, 32.0)
	cam.look_at(Vector3(0.0, 6.0, 0.0), Vector3.UP)
