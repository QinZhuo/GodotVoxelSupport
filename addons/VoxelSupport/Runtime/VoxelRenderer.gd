@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器
## 持有 VoxelData，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)

signal mesh_updated

## 网格生成模式
## 可见性管理模式（决定哪些 chunk 生成网格）
enum VisibilityMode {
	FULL,      ## 全量生成所有 chunk（简单，适合中小世界，内存随世界线性增长）
	FRUSTUM,   ## 视锥剔除：仅生成视锥内（或 view_distance 内）的 chunk，进视锥再补建
	STREAMING, ## 流式加载：按距离生成 + 卸载，远距 chunk 网格释放（适合超大型世界）
}

## 体素数据资源
@export var data: VoxelData:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储
		if data and data.changed.is_connected(_on_data_changed):
			data.changed.disconnect(_on_data_changed)
		data = v
		if data:
			data.changed.connect(_on_data_changed)
		_materials_cache.clear()
		_materials_snapshot_dirty = true
		_pending_chunks.clear()
		_configure_lod()
		_clear_lod_meshes()
		_request_update()

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		# Voxel scale 变化会影响 chunk mesh 的位置，需要重建
		if not _lod_meshes[0].is_empty():
			_clear_lod_meshes()
		_request_update()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
## 对大型动态场景(如水模拟)可显著降低重建频率，值越大越流畅但更新越滞后
@export_range(1, 30) var update_throttle_frames: int = 1

## 可见性管理模式（统一视锥剔除与流式加载）
## - FULL     ：全量生成所有 chunk（中小世界）
## - FRUSTUM  ：视锥剔除，仅生成视锥内/附近 chunk（大型世界，省生成与显存）
## - STREAMING：流式加载，按距离生成 + 卸载远距网格（超大型世界，显存友好）
## 注：渲染层 GPU 剔除由引擎自动完成，此选项控制 CPU 侧生成调度
@export var visibility_mode: VisibilityMode = VisibilityMode.FRUSTUM:
	set(v):
		visibility_mode = v
		# 同步流式启用状态：运行时切换 STREAMING 立即生效（原只在 _ready 设置一次，
		# demo 在 _ready 之后才设 STREAMING 会导致流式从不启用）
		_streaming_enabled = v == VisibilityMode.STREAMING
		if v == VisibilityMode.FULL:
			_deferred_chunks.clear()
			# 全量模式下补建已加载 chunk 的网格（卸载的由统一流式按需重载）
			if data:
				for ck in data.get_loaded_chunk_keys():
					data._mark_chunk_dirty(ck)
		_request_update()
		# 可见性变化影响多个属性的有效性 → 刷新 Inspector（隐藏/显示条件属性）
		notify_property_list_changed()


## Inspector 动态可见性：条件不生效时隐藏对应属性（避免用户设置后无效）。
## Godot 4 在 Inspector 刷新时对每个属性调用此方法，可修改 usage 隐藏。
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property["name"]
	var hide := false
	match name:
		&"view_distance", &"unload_distance", &"lod_count":
			# FULL 全量模式不走流式/LOD，距离参数无效
			hide = visibility_mode == VisibilityMode.FULL
		&"_stream_unload_per_frame", &"_stream_load_per_frame":
			# 流式加载/卸载限速仅 STREAMING 生效
			hide = visibility_mode != VisibilityMode.STREAMING
		&"_lod_build_per_frame", &"_lod_build_budget_ms":
			# LOD1 生成参数仅启用 LOD（lod_count > 1）时生效
			hide = lod_count <= 1
		&"_collision_rebuild_per_frame":
			# 碰撞重建限速仅开启碰撞（generate_collision）时生效
			hide = not generate_collision
	if hide:
		property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR

## 可见性加载距离（世界单位）：FRUSTUM 时视锥外仍生成的半径；STREAMING 时网格加载半径
@export var view_distance: float = 40.0:
	set(v):
		view_distance = v
		_recompute_lod_bands()

## 流式卸载距离（世界单位，仅 STREAMING）：超过此距离的 chunk 网格被卸载释放
## 默认 0 = 自动取 view_distance * 1.2
@export var unload_distance: float = 0.0

## LOD 层级数（含 LOD0）：1=仅全精度（默认，等价旧版 lod0_distance=0 关闭 LOD）；
## 2=LOD0+LOD1(2×)；3=+LOD2(4×)；4=+LOD3(8×)…
## 各层自动按 view_distance 等比（×2）分带：LOD_i 外半径 = view_distance / 2^(lod_count-1-i)。
@export_range(1, 8, 1) var lod_count: int = 1:
	set(v):
		lod_count = clampi(v, 1, 8)
		_configure_lod()
		notify_property_list_changed()

## 可见性检查间隔（帧）：视锥/流式统一每隔 N 帧检查一次相机位置。
## 值越大 CPU 开销越低，但进入视锥/加载距离后的补建响应越慢。
@export_range(1, 120) var visibility_check_interval: int = 8

## 各层外半径（世界单位）：_lod_outer[i] = LOD_i 显示区外边界（LOD0 区 = [0, _lod_outer[0]]）。
var _lod_outer: Array[float] = []

## 各 LOD 层渲染网格：_lod_meshes[lod] = {block_key: MeshInstance3D}。
## index 直接 = LOD 层级：0 = 全精度 chunk（level 0 block key == chunk key），>=1 = 粗层大块。
var _lod_meshes: Array[Dictionary] = []
## 各层待生成的 block（key -> true），由 _process_lod 限量生成
var _lod_pending: Array[Dictionary] = []
## 各层异步生成：已派发待结果的 block（去重）
var _lod_pending_tasks: Array[Dictionary] = []
## 失效重建标记：破坏/编辑后 block 数据变化，保留旧 mesh 直到新 mesh 就绪替换（防重建闪烁）
var _lod_rebuild: Array[Dictionary] = []
## 粗层降采样空结果重试计数（key: "level_bk" → n）：降采样空多为 LOD0 数据未就绪，
## 不设空标记（否则跳过导致洞永远），重试上限后设空标记防真空 block 循环。
var _lod_null_retries: Dictionary = {}
## 各层生成代数：数据变化（invalidate）时递增，丢弃旧任务过期结果
var _lod_generation_id: Array[int] = []
## 每帧一次对齐的各层材质（供所有 worker 复用）
var _lod_materials: Array[Array] = []
## 每帧最多派发/挂载的粗 LOD 网格数（硬上限；mesh 由工作线程构建，挂载仅赋值，可适当调大）
@export_range(1, 400, 1) var _lod_build_per_frame: int = 128

## 粗层预生成提前量（block 数）：把粗层 block 的生成范围向外扩展，
## 让它们在进入 LOD 带之前就生成好——相机跨带时新层级已就绪，
## 消除"旧层已移除、新层异步生成中"的真空窗口（移动中闪现空洞）。
## 0 = 关闭（只在进入带后才生成）；建议 1~3（越大越无感，预加载 ring 常驻量略增）。
@export_range(0, 6, 1) var _lod_preload_blocks: int = 1

# LOD 大块（godot_voxel 风格大 block）：LOD_GRID³ 大格，每格 = 2^level 体素。
#   level 0 = chunk（LOD_GRID = CHUNK_SIZE = 32，block key == chunk key）
#   level i = 大块覆盖 (32×2^i)³ 体素，block key = chunk key >> i
# 一次生成整个大块 mesh（原生 32³ 网格核心 generate_chunk_dense / generate_lod1_block_dense）。
const LOD_GRID := VoxelChunk.CHUNK_SIZE

## LOD level 的 block key：LOD0 chunk key >> level（level 0 = 自身）
static func _lod_block_of_chunk(ck: Vector3i, level: int) -> Vector3i:
	return Vector3i(ck.x >> level, ck.y >> level, ck.z >> level)


static func _lod_block_center(bk: Vector3i, world_offset: Vector3, block_edge_world: float) -> Vector3:
	return world_offset + Vector3(bk) * block_edge_world + Vector3.ONE * block_edge_world * 0.5


## LOD level block 世界边长（= 32×2^level 体素 × voxel_scale）
func _lod_block_edge_world(level: int) -> float:
	return voxel_scale * float(LOD_GRID << level)


## 粗层预生成提前量（世界单位）：_lod_preload_blocks 个本层 block 边长。
## level 0 不预生成（chunk 由流式加载逻辑负责）。
func _lod_preload_extent(level: int) -> float:
	if level <= 0 or _lod_preload_blocks <= 0:
		return 0.0
	return _lod_block_edge_world(level) * float(_lod_preload_blocks)


## LOD 层滞回带宽（世界单位）：该层显示区 = block 距离 ∈ (inner-margin, outer+margin)
func _lod_margin(level: int) -> float:
	return _lod_block_edge_world(level) * 0.5


## block 中心到相机的距离（统一 world_offset/block_edge 来源）
## block 中心到相机的距离（欧氏距离；粗层 needed 判定在 1a 用平方距离避免 sqrt，此处供最终判定/排序复用）
func _block_dist(bk: Vector3i, level: int, cam_pos: Vector3) -> float:
	return cam_pos.distance_to(_lod_block_center(bk, global_position, _lod_block_edge_world(level)))

## LOD1 生成每帧时间预算（毫秒）：超过即停止本帧生成，平滑移动时主线程峰值
@export_range(0.1, 50.0, 0.1) var _lod_build_budget_ms: float = 8.0
# 跨层共享的每帧 LOD 构建预算（避免每层各自满额 → 3 层共 9 个/帧 + 3× 时间）
var _lod_build_this_frame: int = 0
# 共享的后台数据生成提交预算：数量硬上限 _lod_submit_per_frame（防单帧洪峰打爆 WorkerThreadPool）。
# 数量足够大 → 近层提交完自然让位更远层（不饿死，各 LOD 层都能提交）。
@export_range(1, 500, 1) var _lod_submit_per_frame: int = 200
var _lod_submit_this_frame: int = 0

## 是否已启用流式加载（visibility_mode == STREAMING）
var _streaming_enabled: bool = false
var _cull_check_counter: int = 0

## 重新计算 LOD 分带并调整各层存储（lod_count/view_distance 变化时调用）。
## LOD_i 外半径 = view_distance / 2^(lod_count-1-i)（等比 ×2，对齐 Voxel Tools 标准做法）。
func _configure_lod() -> void:
	_recompute_lod_bands()
	# 关闭多余层级（释放网格）
	while _lod_meshes.size() > maxi(lod_count, 1):
		var level := _lod_meshes.size() - 1
		_clear_lod_level(level)
		_lod_meshes.pop_back()
		_lod_pending.pop_back()
		_lod_pending_tasks.pop_back()
		_lod_rebuild.pop_back()
		_lod_generation_id.pop_back()
		_lod_materials.pop_back()
	# 补齐层级（含 LOD0）
	while _lod_meshes.size() < maxi(lod_count, 1):
		_lod_meshes.append({})
		_lod_pending.append({})
		_lod_pending_tasks.append({})
		_lod_rebuild.append({})
		_lod_generation_id.append(0)
		_lod_materials.append([])
	if data:
		data.lod_count = lod_count
		if lod_count <= 1:
			data.clear_lod_cache()
	_request_update()


## 各层外半径：等比 2 倍分带（LOD_i 外边界 = view_distance / 2^(lod_count-1-i)）。
## LOD0 覆盖 [0, D/2^(n-1)]（最内层，跟随 view_distance 等比，不固定）：
## 几何分带：LOD0（全精度）只覆盖 D/2^n（近处精细），粗层自 LOD1 起等比 ×2 到 D。
##   lod_count=1 → [D]（单层全距）
##   lod_count=2 → [D/4, D]（LOD0=[0,D/4]，LOD1=[D/4,D]）
##   lod_count=3 → [D/8, D/2, D]（LOD0=[0,D/8]，LOD1=[D/8,D/2]，LOD2=[D/2,D]）
##   lod_count=4 → [D/16, D/4, D/2, D]（以此类推，LOD0 随层数等比缩小）
func _recompute_lod_bands() -> void:
	_lod_outer.clear()
	var n := maxi(lod_count, 1)
	if n == 1:
		_lod_outer.append(view_distance)
		return
	for i in n:
		if i == 0:
			_lod_outer.append(view_distance / pow(2.0, float(n)))
		else:
			_lod_outer.append(view_distance / pow(2.0, float(n - 1 - i)))


## 释放指定 LOD 层级的全部网格与待建状态
func _clear_lod_level(level: int) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	for bk in _lod_meshes[level]:
		var mi = _lod_meshes[level][bk]
		if mi != null and is_instance_valid(mi):
			mi.queue_free()
	_lod_meshes[level].clear()
	_lod_pending[level].clear()
	_lod_pending_tasks[level].clear()

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		_request_update()
		notify_property_list_changed()

## 是否在编辑器中也实时更新 (仅 @tool 模式)
@export var update_in_editor: bool = true

## 诊断模式开关：开启后在输出面板打印详细的网格重建日志，用于定位性能瓶颈
## 关闭（默认）时仅在单次重建超时阈值（如单 chunk 生成 >5ms）时才打印，避免刷屏
@export var diag_enabled: bool = false

var _dirty: bool = false
var _materials_cache: Array = []
var _collision_body: StaticBody3D = null
var _update_counter: int = 0

# 视锥外待生成的 chunk（key = chunk key，value = true），进入视锥后补建
var _deferred_chunks: Dictionary[Vector3i, bool] = {}

# 流式卸载每帧限量：相机移动跨越边界时分批进行，避免一次 queue_free 大量节点
# 造成掉帧。卸载只释放资源+写盘（便宜），限量可稍大。
@export_range(1, 200, 1) var _stream_unload_per_frame: int = 24
# 流式检查降频：卸载/加载的"全量遍历所有 chunk + 排序"每帧做一次在大场景（数千
# chunk）下是固定 CPU 成本。卸载仅在相机移动越界时才有意义 → 每 12 帧检查一次；
# 加载（走近补建）需及时 → 每 4 帧检查一次。移动边界附近延迟 ≤0.2s，可接受。
var _streaming_check_tick: int = 0
# 上次流式扫描时的相机位置：移动时立即触发扫描（流式加载响应及时）
var _last_streaming_cam_pos := Vector3()
const STREAM_UNLOAD_INTERVAL := 8
# 流式加载每帧限量：走近时优先补建最近的 chunk（磁盘读回 + 入异步重建）。
# 加载标脏后由 WorkerThreadPool 异步生成 + _process_mesh_build_queue 帧尾限量构建
# （GPU 上传限流 8 个/帧 + 3ms 预算），因此标脏量可适当放大：走近时每帧进入
# 管线的新块多，但实际 mesh 出现仍由 GPU 限流平滑分摊，不会掉帧也不会"一帧一块"。
@export_range(1, 200, 1) var _stream_load_per_frame: int = 32
# 流式补建待强制的 chunk：进入 load 距离后应无条件构建（距离驱动，非朝向驱动），
# 不被可见性决策延迟到 _deferred_chunks（否则补建 chunk 因不在视锥内
# 被挂起等待，造成"补建慢、每帧只重建几个"的瓶颈）
var _stream_force_build: Dictionary = {}
# 统一流式异步请求：已提交后台任务（生成/读盘）待回填的 chunk（stream.request_chunk_async）
var _pending_chunks: Dictionary = {}
# 数据基准 chunk（origin shift 后）：相机 chunk 距基准超阈值时平移世界，保持 float 精度。
var _origin_chunk: Vector3i = Vector3i.ZERO
## origin shift 阈值（chunk）：相机 chunk 距基准超此值触发平移。chunk 16³ × 0.1 = 1.6 世界单位，
## 256 chunk ≈ 410 世界单位，远小于 float32 精度上限（~1677 万），安全。
const ORIGIN_SHIFT_THRESHOLD := 256
# 异步网格生成状态（多任务并行，每个任务独立处理）
var _task_ids: Array[int] = []           # 多个并行任务 ID（仅用于取消时等待）
var _coarse_task_ids: Array[int] = []    # 粗 LOD worker 任务 ID（退出时等待，防 call_deferred 打到已释放实例）
var _pending_task_count: int = 0         # 未完成的任务数（用于限流和批次完成判断）
var _generation_id := 0
var _exiting := false                    # 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据
# 材质快照缓存：材质对象深拷贝较昂贵，仅在材质变化时重建一次，供子线程安全读取
var _materials_snapshot: Array = []
var _materials_snapshot_dirty: bool = true
# 异步任务运行期间收到新变更时置位，任务完成后重新触发更新（保证数据始终最新且不并发）
var _pending_retrigger: bool = false
# 批次全部完成待处理标志：置位后下一帧 _process 执行 _on_batch_complete（避免主线程尖峰）
var _batch_complete_pending: bool = false
# Per-chunk 模式：每个非空 chunk 对应一个子 MeshInstance3D（LOD0 网格存于 _lod_meshes[0]）
# Per-chunk 碰撞体：每个 chunk 对应一个子 StaticBody3D
var _chunk_collisions: Dictionary[Vector3i, StaticBody3D] = {}
# 碰撞重建队列：破坏后延迟重建 ConcavePolygonShape3D，每帧限量，避免连续破坏主线程卡顿
var _collision_rebuild_queue: Dictionary[Vector3i, bool] = {}
# 每帧最多重建的碰撞体数
@export_range(1, 100, 1) var _collision_rebuild_per_frame: int = 12

# GPU 上传限流队列：异步结果先缓存数组数据，_process 帧尾批量构建 mesh（平滑 GPU 上传，
# 避免连续破坏时一帧大量 ArrayMesh 创建导致 Metal fence 超时）
# key: chunk_key -> {arrays: Dictionary, has_voxels: bool}
var _mesh_build_queue: Dictionary = {}
# 粗 LOD 大块 mesh 挂载队列：[[level, block_key, arrays]]，帧尾限量构建（GPU 上传摊平）。
# 粗块 mesh 覆盖数十万体素、构建成本高，多个后台结果同时到达时直接同步挂载会卡主线程。
var _lod_mesh_apply_queue: Array = []
var _lod_mesh_apply_scheduled: bool = false
# 每帧最多构建的 chunk 数（GPU 上传限流）
# 流式补建直接入此队列，单 chunk 构建成本低（~1ms），提高后补建更流畅；
# 配合 3ms 时间预算 + GPU 忙检测兜底防 Metal fence 超时
@export_range(1, 100, 1) var _mesh_build_per_frame: int = 12
# 增量重建每帧最多处理的 dirty chunk 数：超出放回下帧续建（防回原点/大崩塌单帧
# 快照+派发上千 worker 阻塞主线程）。值越大重建越快但帧尖峰风险越高。
@export_range(8, 512, 8) var _rebuild_batch_limit: int = 64
# 帧尾构建是否已排期（防重复 call_deferred）
var _mesh_build_scheduled: bool = false
# GPU 忙检测：上一帧渲染耗时超过此阈值(ms)时暂停本帧构建，避免 ArrayMesh
# add_surface_from_arrays 的同步 GPU 上传在 GPU 满载时 Metal fence wait() 超时
var _gpu_busy_threshold_ms: float = 25.0
# 上一帧 _delta（秒），GPU 忙检测用（帧耗时大 = GPU/渲染压力高）
var _last_frame_delta: float = 0.0
# 是否已开启 render time 测量（需 _ready 中调用一次 viewport_set_measure_render_time）
var _measure_render_time_enabled: bool = false

## 最近一次网格生成耗时（毫秒），供外部 HUD 等调试显示
var last_mesh_gen_time_ms: float = 0.0

## 性能追踪：上次生成的顶点数/三角形数
var last_solid_vertices: int = 0
var last_trans_vertices: int = 0
var last_solid_triangles: int = 0
var last_trans_triangles: int = 0
var last_total_chunks: int = 0

## 性能追踪：最近一次重建的 chunk 数量与耗时明细
var last_rebuild_chunk_count: int = 0      ## 本次重建的 chunk 数
var last_rebuild_affected_count: int = 0   ## 受影响的 chunk 数（含相邻边界）
var last_mesh_gen_time_slice_ms: float = 0.0  ## 生成阶段耗时（不含 apply）
var last_apply_time_ms: float = 0.0        ## 应用到场景的耗时 (ms)

## 累计性能统计（简化版 - 仅保留必要统计，避免数组操作开销）
var perf_stats: Dictionary = {
	"total_gen_time": 0.0,    # 累计生成耗时
	"total_apply_time": 0.0,  # 累计应用耗时
	"sample_count": 0,        # 采样次数
}

## 记录一次性能统计采样（轻量级，仅累加数值，不维护数组）
func _record_perf_stats(chunk_count: int, gen_time_ms: float, apply_time_ms: float) -> void:
	last_rebuild_chunk_count = chunk_count
	last_mesh_gen_time_slice_ms = gen_time_ms
	last_apply_time_ms = apply_time_ms
	
	var stats := perf_stats
	stats["total_gen_time"] = stats["total_gen_time"] as float + gen_time_ms
	stats["total_apply_time"] = stats["total_apply_time"] as float + apply_time_ms
	stats["sample_count"] = stats["sample_count"] as int + 1


const _COLLISION_BODY_NAME := "_VoxelRendererCollision"


func _ready() -> void:
	_configure_lod()
	_request_update()
	# 开启 viewport render time 测量，供 GPU 忙检测使用（_process_mesh_build_queue 用）
	# 注：viewport_set_measure_render_time 在部分驱动(如 Metal)上可能引发不稳定，
	# 已改用帧时长(_last_frame_delta)做 GPU 忙检测，此处仅保留标记不调用。
	_measure_render_time_enabled = false
	# 流式加载启用判定：visibility_mode == STREAMING 即启用（unload 默认 = view*1.5）
	_streaming_enabled = visibility_mode == VisibilityMode.STREAMING


func _process(_delta: float) -> void:
	# 记录上一帧耗时，供 GPU 忙检测使用（_process_mesh_build_queue）
	_last_frame_delta = _delta
	# 异步任务结果通过 call_deferred 直接传递到 _on_thread_result，无需轮询
	# 这里只处理限流和启动新任务

	# 可见性管理（每帧限量执行，走近/远离平滑）：
	#  - 视锥补建：每帧限量（_process_deferred_chunks 内限量）
	#  - 流式卸载/补建：每帧限量（按距离排序：远先卸载 / 近先加载）
	# 异步批次在跑时也可执行：卸载改数据层不影响 worker 快照（深拷贝）；
	# 补建标脏会在批次完成后统一重建（retrigger），不会丢失。
	if visibility_mode != VisibilityMode.FULL:
		_process_deferred_chunks()
	# 统一流式/程序化驱动：程序化无限世界总是按距离生成（不依赖 visibility_mode——
	# 无限世界只能按距离生成，设 FULL/FRUSTUM 若不走流式会导致数据永不生成 → 画面空白）；
	# 磁盘文件流仅在 STREAMING 模式启用加载/卸载。
	if _streaming_enabled or (data and data.stream is VoxelProceduralStream):
		_process_streaming()
	# LOD 管理：每 interval 帧限量生成/移除（降低每帧遍历开销，近处 LOD0 / 远处各粗层互补）。
	# 数据变化（破坏/编辑）时立即处理（不等降频周期 → 破坏重建更及时）。
	# 注意：lod_count=1（仅 LOD0）也必须调用——否则 LOD0 chunk mesh 永远不补建（画面空白）。
	_cull_check_counter += 1
	if data and (_cull_check_counter >= visibility_check_interval or data.has_lod_invalidated()):
		_cull_check_counter = 0
		_process_lod()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	# call_deferred 确保在帧末尾执行（本帧渲染已提交），且队列处理不阻塞主循环
	if not _mesh_build_queue.is_empty() and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	# 粗 LOD 大块 mesh 挂载同样帧尾限量（大块 build_mesh_from_arrays 覆盖数十万体素，GPU 上传昂贵）
	if not _lod_mesh_apply_queue.is_empty() and not _lod_mesh_apply_scheduled:
		_lod_mesh_apply_scheduled = true
		call_deferred("_process_lod_mesh_apply_queue")

	# 碰撞增量重建：破坏后限量重建 ConcavePolygonShape3D（延迟，避免连续破坏主线程卡顿）
	if generate_collision and not _collision_rebuild_queue.is_empty():
		var _built_col := 0
		var _col_keys := _collision_rebuild_queue.keys()
		for ck in _col_keys:
			if _built_col >= _collision_rebuild_per_frame:
				break
			var hm: bool = _collision_rebuild_queue[ck]
			_collision_rebuild_queue.erase(ck)
			_update_chunk_collision(ck, hm)
			_built_col += 1

	# 延迟批次完成：全部异步任务完成后，在下一帧处理剩余收尾逻辑，避免主线程尖峰
	if _batch_complete_pending:
		_batch_complete_pending = false
		_on_batch_complete()

	if not (_dirty and auto_update and (not Engine.is_editor_hint() or update_in_editor)):
		return
	# 限流：合并帧内多次变更，最多每 update_throttle_frames 帧重建一次
	_update_counter += 1
	if _update_counter < update_throttle_frames:
		return
	_update_counter = 0

	# 若有尚未完成的异步任务，不启动新批次：直接启动新批次会递增 gen_id，
	# 导致上一批次的 chunk 修复结果被丢弃（gen_id 不匹配），而上一批次的脏体素
	# 又已在其派发时被清除，这些 chunk 的重建将永久丢失 → 界面残留被破坏面的"幽灵面"。
	# 改为置位 retrigger，等当前批次全部完成后在 _on_batch_complete 中重新触发，
	# 保证每个脏 chunk 最终都得到一次应用。
	if _pending_task_count > 0:
		_pending_retrigger = true
		return

	_update_mesh()


func _on_data_changed() -> void:
	_request_update()


func _request_update() -> void:
	_dirty = true


## 标记为脏，下一帧自动更新 (若 auto_update=true)
func mark_dirty() -> void:
	_request_update()


## 立即强制重新生成 mesh
## 若仍有异步任务在运行，不直接启动新批次（否则 _update_mesh_async 会在 worker
## 读取共享切片时再次修改切片缓存 → 数据竞态），而是置位 retrigger，等当前批次
## 完成后由 _on_batch_complete 自动触发重建，保证共享切片引用安全。
func force_update() -> void:
	_dirty = true
	if _pending_task_count > 0:
		_pending_retrigger = true
		return
	_dirty = false
	_update_mesh()


## 强制重新生成纹理材质 (材质属性变化时调用)
func regenerate_materials() -> void:
	_materials_cache.clear()
	_materials_snapshot_dirty = true
	_request_update()


## 获取当前体素数据
func get_data() -> VoxelData:
	return data


## 设置指定位置体素 (会触发自动更新)
func set_voxel(pos: Vector3i, material_id: int) -> void:
	if data:
		data.set_voxel(pos, material_id)


## 移除指定位置体素 (会触发自动更新)
func remove_voxel(pos: Vector3i) -> void:
	if data:
		data.remove_voxel(pos)


## 获取指定位置体素材质ID
func get_voxel(pos: Vector3i) -> int:
	if data:
		return data.get_voxel(pos)
	return -1


func _exit_tree() -> void:
	# 退出：等待所有 worker 任务完成后再释放，否则 worker 完成时 call_deferred
	# 会打到已释放实例（"Cannot call method 'call_deferred' on a previously freed instance"）。
	_exiting = true
	_cancel_async()
	for tid in _coarse_task_ids:
		WorkerThreadPool.wait_for_task_completion(tid)
	_coarse_task_ids.clear()
	_clear_lod_meshes()


## 取消尚未完成的异步网格生成任务
func _cancel_async() -> void:
	for tid in _task_ids:
		WorkerThreadPool.wait_for_task_completion(tid)
	_task_ids.clear()
	_pending_task_count = 0
	_generation_id += 1


func _update_mesh() -> void:
	_dirty = false
	if not data:
		_cancel_async()
		mesh = null
		_clear_lod_meshes()
		_clear_collision()
		mesh_updated.emit()
		return

	# 生成纹理材质 (缓存，材质变化时需手动调用 regenerate_materials)
	if _materials_cache.is_empty() or _materials_cache[0] == null:
		_materials_cache = VoxelMeshGenerator.generate_textured_materials_runtime(data.materials)

	# 材质快照只在材质变化时深拷贝一次，供异步子线程安全读取 (体素变化不触发，避免每帧大对象拷贝)
	if _materials_snapshot_dirty:
		_materials_snapshot = data.materials.duplicate(true)
		_materials_snapshot_dirty = false

	# 统一走异步生成（CHUNK_ASYNC 为唯一路径；同步渲染路径已移除简化）
	_update_mesh_async()


## 统一可见性决策：流式距离过滤（超 unload 标 streamed_out、LOD1 区标 pending）
## + 视锥/近处全向过滤（近处 LOD0 区无条件构建、视锥内构建、视锥外进 deferred 待补建）。
## 替代原 _filter_streamed_chunks + _filter_frustum_chunks 两步过滤，消除重复遍历与判定分歧。
func _filter_visible_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if visibility_mode == VisibilityMode.FULL:
		return chunks
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return chunks
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var world_offset := global_position
	# LOD0 显示区外边界。count=1 时 _recompute_lod_bands 会 append view_distance
	# （lod0 带 = [0, D]，全 lod0），此处必须取 _lod_outer[0] 而非"count>1 否则 0"——
	# 否则 count=1 时"近处 LOD0 区无条件构建"失效，所有 chunk 走视锥剔除，
	# 视锥外 chunk 被 deferred 不建 mesh → lod0 只覆盖视锥内而非 [0, D]（"越改越近"）。
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	var unload_d := _unload_d()
	var visible: Array[Vector3i] = []
	for ck in chunks:
		# 无数据的空 chunk：不纳入网格管理（无体素无需构建/补建，避免补建空 chunk 死循环）
		if data and not data.has_chunk(ck):
			continue
		# 流式距离层（仅 STREAMING）：超 unload 不建网格（数据由统一流式卸载，
		# 重进范围再按需重载）
		if _streaming_enabled and unload_d > 0.0:
			if _chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > unload_d:
				continue
		# 【关键】LOD 层级过滤：与流式模式无关（LOD 按距离用不同分辨率，正交于流式加载）。
		# 超出 LOD0 带的 chunk 由对应粗层 block 覆盖——从一开始就决定显示哪个层级，
		# 否则 FRUSTUM 等非流式模式下远处 chunk 也会构建 LOD0 网格 → "先细后粗"闪烁。
		if lod0_d > 0.0:
			var level := _chunk_render_level(ck, cam_pos)
			if level > 0:
				var bk := _lod_block_of_chunk(ck, level)
				if level < _lod_pending.size():
					_lod_pending[level][bk] = true
				_stream_force_build.erase(ck)
				continue
		# 流式补建强制的 chunk：距离驱动，无条件构建（清除标记避免重复）
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		# 近处 LOD0 区（chunk 中心 < lod0+margin）不视锥剔除：快速转向/后退近处不空
		if lod0_d > 0.0:
			if _block_dist(ck, 0, cam_pos) <= lod0_d + lod0_margin:
				visible.append(ck)
				continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if _aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


## chunk 的世界空间 AABB（统一实现见 VoxelWorldUtil，此处转发供内部旧调用复用）
static func _chunk_world_aabb(ck: Vector3i, chunk_size_world: float, world_offset: Vector3) -> AABB:
	return VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)


## 相机到 chunk 中心的距离（统一实现见 VoxelWorldUtil，chunk/流式距离判定统一走此接口）
static func _chunk_center_dist(ck: Vector3i, cam_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> float:
	return VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)


## AABB 是否有任意顶点在视锥内（统一实现见 VoxelWorldUtil）
static func _aabb_has_vertex_in_frustum(aabb: AABB, cam: Camera3D) -> bool:
	return VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam)


## 世界坐标 → chunk key（统一实现见 VoxelWorldUtil）
static func _chunk_from_world(world_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> Vector3i:
	return VoxelWorldUtil.chunk_from_world(world_pos, chunk_size_world, world_offset)


static func _is_chunk_beyond_unload(ck: Vector3i, cam: Camera3D, chunk_size_world: float, world_offset: Vector3, unload_d: float) -> bool:
	if cam == null or unload_d <= 0.0:
		return false
	return _chunk_center_dist(ck, cam.global_position, chunk_size_world, world_offset) > unload_d


## 统一卸载距离：unload_distance 未显式设置（<= view_distance）时回退为 view_distance * 1.2。
## 所有距离判定（网格过滤/数据卸载/LOD 挂载/过期结果丢弃）共用此值，避免各处分歧。
## 惰性计算：不 mutate unload_distance 字段，规避属性加载顺序导致的错误固化值。
func _unload_d() -> float:
	return unload_distance if unload_distance > view_distance else view_distance * 1.2


## 统一视锥可见性判定（对外统一接口）：世界坐标是否在当前相机视锥内。
## 供粒子/破碎/掉落体等"视锥外跳过"优化使用（相机看不到的位置跳过昂贵效果）。
## 与 _aabb_has_vertex_in_frustum 同源（is_position_in_frustum），保证判定一致。
## 无相机/未入树时返回 true（保守：不裁剪）。
func is_world_visible(world_pos: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	return cam.is_position_in_frustum(world_pos)


## 周期性检查待建队列：视锥外的 chunk 进入视锥（或相机靠近）后触发补建。
## 【限量补建】每帧最多 _stream_load_per_frame 个（与流式加载限量一致），
## 走近/转向时避免一次把大量待建 chunk 全部标脏 → 主线程快照 + 生成 + GPU 上传掉帧。
## 视锥内优先，其次 view_distance 半径内。由 _process 每帧调用。
func _process_deferred_chunks() -> void:
	if _deferred_chunks.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var margin := view_distance
	var cam_pos := cam.global_position
	var world_offset := global_position
	var built := 0
	var _iter := 0
	# 直接迭代字典（避免 keys() 分配上万数组）；每帧限量扫描（避免视锥外
	# 大量待建 chunk 全遍历 → 走近/转向时主线程持续高开销）
	for ck in _deferred_chunks:
		_iter += 1
		if _iter > _stream_load_per_frame * 8:
			break
		if built >= _stream_load_per_frame:
			break
		# 已构建网格的 chunk 无需补建（从待建队列移除，避免重复重建）；
		# 无数据的空 chunk 也无需补建（否则空重建死循环，三角=0 刷日志）
		if _lod_meshes[0].has(ck) or (data and not data.has_chunk(ck)):
			_deferred_chunks.erase(ck)
			continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if not _aabb_has_vertex_in_frustum(aabb, cam):
			if not (margin > 0.0 and _chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) <= margin):
				continue
		_deferred_chunks.erase(ck)
		if data:
			# 强制构建标记：确保增量重建时不被视锥剔除拦截回 deferred
			# （该 chunk 在视锥外但已在加载范围，必须真正构建）
			_stream_force_build[ck] = true
			data._mark_chunk_dirty(ck)
		built += 1
	if built > 0:
		_request_update()


## 统一流式/程序化驱动（合并原 _process_streaming / _process_procedural）：
## 按相机距离管理 chunk 数据与网格，数据源差异全部下沉到 VoxelStream 接口：
##   - 程序化流（VoxelProceduralStream）：未修改 chunk 后台确定性生成（request_chunk_async），
##     修改过的 chunk 同步预载已存数据（防止重新生成覆盖用户修改）
##   - 文件流（VoxelFileStream）：region 异步读盘（request_region_load），chunk 数据回内存
## 统一流程：① poll 回填异步结果 → ② 距离内扫描缺失 chunk 提交（限量/降频）→ ③ 卸载超范围。
## "想要集合"统一 = 相机加载半径内缺失 chunk；存在性判定统一走廉价接口
## （程序化 = is_in_generation_bounds；文件 = VoxelData 已持久化索引），
## 不再维护 _streamed_out_chunks 渲染层注册表。
func _process_streaming() -> void:
	if not is_inside_tree():
		return
	if data == null:
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var stream: VoxelStream = data.stream
	if stream == null:
		return
	var cam_pos := cam.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var world_offset := global_position
	# 加载半径 = view_distance（LOD0 数据需要半径）；卸载半径 = unload_distance（保留半径）
	var load_d := view_distance
	var unload_d := _unload_d()
	var cam_ck := _chunk_from_world(cam_pos, chunk_size_world, world_offset)
	var is_procedural := stream is VoxelProceduralStream

	# 程序化无限世界：origin shift（相机 chunk 距基准超阈值 → 平移数据+渲染+相机）
	if is_procedural:
		_check_origin_shift(cam)

	# 1) 回填后台异步结果（程序化生成 / 文件流 region 读盘），统一 poll → accept（按 lod 分流）
	# poll 限量 = 加载预算的 2 倍：避免来回移动时每帧 accept 过多（主线程写入 + 失效开销大 → 掉帧）
	var applied := 0
	var results := stream.poll_all_ready(maxi(_stream_load_per_frame * 2, 32))
	for r in results:
		var lod: int = r[0]
		var ck: Vector3i = r[1]
		var buf: PackedInt32Array = r[2]
		data.accept_chunk_buffer(ck, buf, lod)
		if lod == 0:
			_pending_chunks.erase(ck)
		elif lod < _lod_pending.size():
			_lod_pending[lod].erase(ck)
		applied += 1

	# 2) 距离内扫描缺失 chunk 并提交（限量每帧；降频扫描，相机不动时结果不变）
	_streaming_check_tick += 1
	# 相机移动：用更快的扫描间隔（interval/2，默认 4 帧）而非每帧全量扫描——
	# 保证移动响应及时，同时避免连续移动时每帧全量遍历拖慢帧率
	var cam_moved := cam_pos != _last_streaming_cam_pos
	if cam_moved:
		_last_streaming_cam_pos = cam_pos
		if _streaming_check_tick >= maxi(visibility_check_interval >> 1, 1):
			_streaming_check_tick = 0
	var submitted := 0
	# 相机移动中 → 提高本帧加载吞吐（移动时更快补建，减少前方空白）
	var load_budget := _stream_load_per_frame
	if cam_moved:
		load_budget = _stream_load_per_frame * 2
	if _streaming_check_tick % visibility_check_interval == 0:
		var r := ceili(load_d / chunk_size_world) + 1
		var yspan := stream.get_vertical_half_span()
		var exhausted := false
		for dz in range(-r, r + 1):
			if exhausted:
				break
			for dy in range(-yspan, yspan + 1):
				if exhausted:
					break
				for dx in range(-r, r + 1):
					if submitted >= load_budget:
						exhausted = true
						break
					var ck := cam_ck + Vector3i(dx, dy, dz)
					# 【统一距离→LOD 决策】近处（LOD0 带）加载全精度 chunk 数据；
					# 远处（粗层带）跳过——LOD0 chunk 不加载，粗层 block 数据由 _process_lod_level
					# 按带请求独立数据（生成器 _generate_chunk_lod 直接生成，省内存/生成量）。
					if _chunk_render_level(ck, cam_pos) > 0:
						continue
					# 存在性统一判定（廉价，无磁盘 IO）：
					#   程序化 = is_in_generation_bounds（无限流恒 true / 有限模板流查范围）
					#   文件流 = VoxelData 已持久化索引（O(1)，避免 has_chunk 同步读 region）
					var available := stream.has_chunk(ck) if is_procedural else data._persisted_chunks.has(ck)
					if not available:
						continue
					if data.is_chunk_loaded(ck):
						continue
					if _pending_chunks.has(ck):
						continue
					if _chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > load_d:
						continue
					# 程序化修改过的 chunk：重新生成会覆盖用户修改 → 同步预载已存数据
					if is_procedural and data._persisted_chunks.has(ck):
						if data.preload_chunk(ck):
							_stream_force_build[ck] = true
							data._mark_chunk_dirty(ck)
							submitted += 1
						continue
					# 未修改（程序化可重生成）或文件流（磁盘读）：统一异步请求
					data.request_chunk_async(ck, 0)
					_pending_chunks[ck] = true
					submitted += 1

	# 3) 卸载超范围数据+网格（程序化：未修改丢弃可重生成、修改写盘；文件：写盘/清盘）
	#    最粗 LOD 层区数据保留（供降采样合并），否则降采样读空 → 大格缺失
	if _streaming_check_tick % STREAM_UNLOAD_INTERVAL == 0:
		var coarse_level := maxi(lod_count - 1, 1)
		var block_edge_world := _lod_block_edge_world(coarse_level)
		var unload_margin := _lod_margin(coarse_level)
		var unload_block_extent := block_edge_world * 0.5
		var candidates: Array = []
		for ck in data.get_loaded_chunk_keys():
			var bk := _lod_block_of_chunk(ck, coarse_level)
			if _block_dist(bk, coarse_level, cam_pos) <= unload_d + unload_margin + unload_block_extent:
				continue
			var dist: float = _chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)
			if dist > unload_d:
				candidates.append([dist, ck])
		# 从远到近（距离降序）：最远的先卸载
		candidates.sort_custom(func(a, b): return a[0] > b[0])
		var unloaded := 0
		for item in candidates:
			if unloaded >= _stream_unload_per_frame:
				break
			_unload_chunk(item[1])
			unloaded += 1
		# 取消超范围仍未完成的异步请求（避免后台白做，结果回来由卸载逻辑丢弃）
		if not _pending_chunks.is_empty():
			for ck in _pending_chunks.keys():
				if _chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > unload_d:
					_pending_chunks.erase(ck)
		# 清理超范围的粗 LOD 独立数据块（未修改可重新生成，修改的写盘）
		for lev in range(1, _lod_meshes.size()):
			var edge_w := _lod_block_edge_world(lev)
			for bk in data.get_lod_block_keys(lev).duplicate():
				if _block_dist(bk, lev, cam_pos) > unload_d + edge_w * 0.5:
					if data.is_lod_block_modified(lev, bk):
						data.flush_lod_block(lev, bk)
					else:
						data.erase_lod_block(lev, bk)

	if applied > 0 or submitted > 0:
		_request_update()





## 动态原点重定位：相机 chunk 距数据基准超阈值时，平移数据层 + 渲染层 + 相机，
## 使相机附近 chunk 回到小坐标，避免 float32 精度损失（无限移动世界）。
func _check_origin_shift(cam: Camera3D) -> void:
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_ck := _chunk_from_world(cam.global_position, chunk_size_world, global_position)
	var delta := cam_ck - _origin_chunk
	var shift := Vector3i.ZERO
	if delta.x >= ORIGIN_SHIFT_THRESHOLD:
		shift.x = delta.x - ORIGIN_SHIFT_THRESHOLD
	elif delta.x <= -ORIGIN_SHIFT_THRESHOLD:
		shift.x = delta.x + ORIGIN_SHIFT_THRESHOLD
	if delta.y >= ORIGIN_SHIFT_THRESHOLD:
		shift.y = delta.y - ORIGIN_SHIFT_THRESHOLD
	elif delta.y <= -ORIGIN_SHIFT_THRESHOLD:
		shift.y = delta.y + ORIGIN_SHIFT_THRESHOLD
	if delta.z >= ORIGIN_SHIFT_THRESHOLD:
		shift.z = delta.z - ORIGIN_SHIFT_THRESHOLD
	elif delta.z <= -ORIGIN_SHIFT_THRESHOLD:
		shift.z = delta.z + ORIGIN_SHIFT_THRESHOLD
	if shift == Vector3i.ZERO:
		return
	data.shift_origin(shift)
	_origin_chunk += shift
	_shift_render(shift, chunk_size_world)
	cam.global_position -= Vector3(shift) * chunk_size_world


## origin shift 后平移渲染层：所有网格节点 key 平移 + 节点 position 更新 + 各类集合字典 key 平移。
func _shift_render(shift: Vector3i, chunk_size_world: float) -> void:
	var new_lod0: Dictionary[Vector3i, MeshInstance3D] = {}
	for ck in _lod_meshes[0]:
		var nck: Vector3i = ck + shift
		var mi: MeshInstance3D = _lod_meshes[0][ck]
		if mi != null:
			mi.position = Vector3(nck) * chunk_size_world
		new_lod0[nck] = mi
	_lod_meshes[0] = new_lod0
	# 各粗 LOD 层网格节点平移（每层 block 边长不同）
	for level in range(1, _lod_meshes.size()):
		var edge_world := _lod_block_edge_world(level)
		var new_c: Dictionary = {}
		for bk in _lod_meshes[level]:
			var nbk: Vector3i = bk + shift
			var mi = _lod_meshes[level][bk]
			if mi != null:
				mi.position = Vector3(nbk) * edge_world
			new_c[nbk] = mi
		_lod_meshes[level] = new_c
	# 各类 chunk/block 集合字典 key 整体平移（typed dict 需 typed 构建，_shift_keys 仅普通 Dictionary）
	var ndf: Dictionary[Vector3i, bool] = {}
	for k in _deferred_chunks:
		ndf[Vector3i(k) + shift] = true
	_deferred_chunks = ndf
	_stream_force_build = _shift_keys(_stream_force_build, shift)
	for level in range(1, _lod_pending.size()):
		_lod_pending[level] = _shift_keys(_lod_pending[level], shift)
		_lod_pending_tasks[level] = _shift_keys(_lod_pending_tasks[level], shift)
	_mesh_build_queue = _shift_keys(_mesh_build_queue, shift)
	# 粗 LOD 挂载队列存的是旧坐标系生成的数组数据，平移会错位 → 直接清空（数据未变，重挂载）
	_lod_mesh_apply_queue.clear()
	_pending_chunks = _shift_keys(_pending_chunks, shift)
	var ncr: Dictionary[Vector3i, bool] = {}
	for k in _collision_rebuild_queue:
		ncr[Vector3i(k) + shift] = true
	_collision_rebuild_queue = ncr


static func _shift_keys(d: Dictionary, shift: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + shift] = d[k]
	return nd


# ----------------------------------------------------------------------------
# 多层级 LOD 渲染（lod_count 控制层级数，view_distance 自动等比 ×2 分带）
#   LOD0 全精度 chunk（level 0 block == chunk）；LOD i 大块每格 2^i 体素。
#   分带：LOD_i 显示区 = [outer[i-1], outer[i]]（outer[i] = view_distance / 2^(lod_count-1-i)）。
#   各层 block 生成/移除/可见性带滞回 margin，交界处内层未就绪时用外层兜底防空洞。
# ----------------------------------------------------------------------------

## LOD 管理：各粗层限量生成/移除 + LOD0 全精度补建。由 _process 每 interval 帧调用。
func _process_lod() -> void:
	if not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var cam_pos := cam.global_position
	var world_offset := global_position
	var unload_d := _unload_d()
	var n_levels := maxi(lod_count, 1)
	# 内存 chunk 键快照：多步骤同帧复用，避免每帧多次分配
	var loaded_chunks := data.get_loaded_chunk_keys()
	var cam_dir: Vector3 = -cam.global_transform.basis.z

	# 0. 数据变化 → 各粗层 block 失效重建（编辑/破坏触发）。
	#    不立即移除旧 mesh（防重建期间可见性振荡 → 闪烁）：标记重建并立即派发降采样，
	#    新 mesh 就绪后复用节点替换（内带区 mesh 应用由 _should_apply 丢弃，但数据仍同步更新）。
	for level in range(1, n_levels):
		var invalidated := data.get_invalidated_lod(level)
		if not invalidated.is_empty():
			while _lod_rebuild.size() <= level:
				_lod_rebuild.append({})
			_lod_generation_id[level] += 1
			if _lod_materials[level].is_empty():
				_lod_materials[level].assign(VoxelMaterial.align_by_id(_materials_snapshot))
			for bk in invalidated:
				_lod_rebuild[level][bk] = true
				_lod_pending_tasks[level].erase(bk)
				# 内带（LOD0 显示区）：mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被丢弃——
				# 只降采样同步数据（拆两阶段，避免内带生成完整粗层 mesh 的 worker 浪费）；
				# 粗层带：完整重建（数据 + mesh 替换反映破坏）。
				var bdist := _block_dist(bk, level, cam_pos)
				var _inner := _lod_outer[level - 1] if level > 0 else 0.0
				var _margin := _lod_margin(level)
				if bdist < _inner - _margin:
					_build_lod_data_only(level, bk)
				else:
					_build_lod_block(level, bk)

	# 1. 各层：移除超出区间 / 生成带内缺失 / 可见性兜底（跨层共享构建预算）
	_lod_build_this_frame = 0
	_lod_submit_this_frame = 0
	# 程序化流：粗层独立数据生成较慢（噪声），收紧每帧粗层 request 预算，
	# 让出 WorkerThreadPool 给 LOD0 chunk 生成（切换后快速看到地形，粗层随后补充）。
	var submit_budget: int = _lod_submit_per_frame
	if data and data.stream is VoxelProceduralStream:
		submit_budget = 40
	# 每层独立构建预算 = 总数均分（保证近层建完前更粗层也能推进，不被近层 in-flight
	# 队列饿死——否则 LOD1 海量候选每帧占满共享配额，LOD2 永远 0 个 → 远处空洞）。
	var per_level_build := maxi(_lod_build_per_frame / maxi(n_levels, 1), 4)
	for level in range(n_levels):
		_process_lod_level(level, cam, cam_pos, cam_dir, unload_d, world_offset, loaded_chunks, submit_budget, per_level_build)


## 单个 LOD 层级管理：按 level 参数自动分流——
##   level 0 = 全精度 chunk 网格（移除超出 LOD0 带、补建带内缺失）
##   level >=1 = 粗层 block（覆盖 32×2^level 体素），每层严格在自身 band
##   （inner-margin, upper] 内生成/保留（最粗层延伸至 unload），避免多层重叠 z-fight。
func _process_lod_level(level: int, cam: Camera3D, cam_pos: Vector3, cam_dir: Vector3, unload_d: float, world_offset: Vector3, loaded_chunks: Array, submit_budget: int, build_quota: int) -> void:
	if level == 0:
		_process_chunk_level(loaded_chunks, cam, cam_pos, world_offset, unload_d)
		return
	if level >= _lod_meshes.size():
		return
	var inner := _lod_outer[level - 1]
	var outer := _lod_outer[level]
	var edge_world := _lod_block_edge_world(level)
	var margin := _lod_margin(level)
	var is_coarsest := level >= _lod_meshes.size() - 1
	# 本层生成/保留上界：非最粗层 = outer+margin（之外由更粗层覆盖）；最粗层 = unload+half-edge
	var upper := (unload_d + edge_world * 0.5) if is_coarsest else (outer + margin)
	# 1a. 推导需要：按本层 band 直接枚举 block（Voxel Tools 式——粗层数据独立，无需从 LOD0 chunk 推导）
	#   needed 存 block 中心距离（float），1c 复用，避免同一 block 重复算 distance_to。
	#   预生成提前量：生成范围向外扩 _lod_preload_extent，让粗层 block 在进入带前就生成好——
	#   相机跨带时新层级已就绪，消除"旧层移除/新层异步生成"的真空窗口（移动中闪现空洞）。
	var preload_d := _lod_preload_extent(level)
	var needed := {}
	var r_bk := ceili((outer + margin + preload_d) / edge_world) + 1
	var cam_bk := _lod_block_of_chunk(_chunk_from_world(cam_pos, voxel_scale * VoxelChunk.CHUNK_SIZE, world_offset), level)
	# 平方距离判定（避免 distance_to 的 sqrt）。先用整数 block 距离做球内预筛，
	# 大幅减少候选（立方体角部 block 直接跳过，大半径时省一半以上循环），
	# 通过时再算一次实际欧氏距离缓存，供 1c 精确判定 / 排序复用。
	var radius := outer + margin + preload_d
	var radius_sq := radius * radius
	var r_blocks := ceili(radius / edge_world) + 2
	var r2 := r_blocks * r_blocks
	for dz in range(-r_bk, r_bk + 1):
		var dzz := dz * dz
		for dy in range(-r_bk, r_bk + 1):
			var dyz := dzz + dy * dy
			if dyz > r2:
				continue
			for dx in range(-r_bk, r_bk + 1):
				if dyz + dx * dx > r2:
					continue
				var bk := cam_bk + Vector3i(dx, dy, dz)
				var to_cam := _lod_block_center(bk, global_position, edge_world) - cam_pos
				var dsq := to_cam.length_squared()
				if dsq <= radius_sq:
					needed[bk] = sqrt(dsq)
	# 1b. 移除超出区间的：>unload 卸载；<inner-margin 进入内层带（内层就绪才移除）；
	#     >upper 进入更粗层带（更粗层就绪才移除，否则保留兜底防空洞）。
	#     预生成范围（<= upper+preload_d）内的 block 即使更粗层就绪也保留——
	#     它们作为预加载常驻（1d 隐藏），进入带内时直接显示，消除切换真空。
	var remove_keys: Array = []
	for bk in _lod_meshes[level]:
		var dist := _block_dist(bk, level, cam_pos)
		if dist > unload_d + edge_world * 0.5:
			remove_keys.append(bk)
		elif dist < inner - margin and _level_finer_ready(level, bk, cam):
			remove_keys.append(bk)
		elif dist > upper + preload_d and _has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			remove_keys.append(bk)
	for bk in remove_keys:
		_remove_lod_mesh(level, bk)
	# 1c. 带内缺失：数据未就绪 → 请求独立数据（生成器 _generate_chunk_lod）；就绪 → 派发 mesh
	var to_build: Array = []
	for bk in needed:
		if _has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
			# 空标记（null mesh）但粗层数据已就绪 → 重建 mesh（数据生成晚于首次 mesh 尝试——
			# 否则粗层一直空标记，LOD0 移除后出现过渡空洞）。
			if _lod_meshes[level][bk] != null or not data.has_lod_block(level, bk):
				continue
		var dist: float = needed[bk]
		# 近处（LOD0 带内，dist<inner-margin）的 block 由 LOD0 chunk 显示，不生成 L1 mesh——
		# 否则与 1b 移除（近处内层就绪→移除 L1）形成"生成→移除→再生成"循环 → L0/L1 交替闪烁。
		# 带内及带外预生成范围（upper+preload_d 内）正常生成：进入带前就绪，消除切换真空。
		if dist < inner - margin or (not data.has_lod_block(level, bk) and dist > upper + preload_d):
			continue
		# 修改过的 block 由降采样回退（_build_lod_block 处理，数据来自 LOD0）；未修改优先独立数据。
		# 流若无粗层独立数据能力（程序化流会生成；文件流/自定义流仅实现 lod=0 → request 无效果）：
		# request 后 is_chunk_pending 仍 false → 走 to_build 由 _build_lod_block 降采样回退（保证任意流都出 LOD）。
		if not data.is_lod_block_modified(level, bk) and not data.has_lod_block(level, bk):
			# 文件流：直接降采样生成（一次完成——mesh + 数据缓存同步），不等异步 request 两阶段。
			# 异步降采样（request → 数据 → 下次帧 mesh）完成时机晚，近处粗层块长期无 mesh → 固定空洞。
			if data.stream is VoxelFileStream:
				to_build.append([dist, bk])
				continue
			var _pending := data.is_chunk_pending(bk, level)
			if not _pending and _lod_submit_this_frame < submit_budget:
				_lod_submit_this_frame += 1
				data.request_chunk_async(bk, level)
				_pending = data.is_chunk_pending(bk, level)
				if not _pending:
					_lod_submit_this_frame -= 1  # 流无粗层能力，request 无效果 → 回滚预算
			if _pending:
				continue  # 独立数据生成中（程序化流），等待回填
			# 无粗层独立数据能力 → 降采样（_build_lod_block 快照空时回退降采样）
		to_build.append([dist, bk])
	# 构建预算有限：先按距离粗排（用缓存的 dist，便宜），截断候选，再按加载优先级细排
	# （避免大 to_build 时对数百 block 全量算 priority，单层可省数十 ms）。
	if to_build.size() > build_quota * 8:
		to_build.sort_custom(func(a, b): return a[0] < b[0])
		to_build = to_build.slice(0, build_quota * 8)
	to_build.sort_custom(func(a, b):
		return _lod_load_priority(a[1], level, cam_pos, cam_dir) < _lod_load_priority(b[1], level, cam_pos, cam_dir))
	if not to_build.is_empty():
		var aligned: Array = VoxelMaterial.align_by_id(_materials_snapshot)
		# 用 assign 避免 typed 数组（_lod_materials 为 Array[Array]）直接赋值类型校验失败
		_lod_materials[level].assign(aligned)
	# 每层构建数独立计数（上限 build_quota），互不抢占——近层在途任务多时
	# 不拖垮更粗层（否则 LOD1 海量 in-flight 占满共享配额 → LOD2 饿死 → 远处空洞）。
	# 只在真正派发（_build_lod_block 返回 true）时计数：已 pending 的跳过调用不再耗配额。
	var _built_this := 0
	for item in to_build:
		if _built_this >= build_quota:
			break
		if _build_lod_block(level, item[1]):
			_built_this += 1
	_lod_pending[level].clear()
	# 1d. 可见性兜底：进入内层带且内层未就绪 → 本层显示（防切换空洞）；
	#     超出本层带且更粗层已就绪 → 隐藏本层（防远处多层重叠 z-fight）
	for bk in _lod_meshes[level]:
		var mi: MeshInstance3D = _lod_meshes[level][bk]
		if mi == null:
			continue  # 空大块（无体素）
		# 失效重建中：冻结可见性——破坏瞬间不因重建切换 LOD 层级（避免"不同层级闪烁"），
		# 新 mesh 就绪替换并清除重建标记后，下一帧按当前状态恢复正常可见性判定。
		if _lod_rebuilding(level, bk):
			continue
		var dist := _block_dist(bk, level, cam_pos)
		if dist < inner + margin:
			mi.visible = not _level_finer_ready(level, bk, cam)
		elif dist > outer + margin and _has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			mi.visible = false
		else:
			mi.visible = true


## LOD0（chunk 层）网格管理：移除超出 LOD0 带的（粗层已就绪），补建带内缺失
func _process_chunk_level(loaded_chunks: Array, cam: Camera3D, cam_pos: Vector3, world_offset: Vector3, unload_d: float) -> void:
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	# 移除超出 LOD0 带的 chunk 网格：
	#   - 对应粗层已就绪 → 移除（避免"先细后粗"残留）
	#   - 超出最粗层覆盖带（block 中心 > outer[coarsest]+margin）→ 直接移除
	#     （该区域超出可视范围，粗层不再覆盖；视锥外空洞不可见，安全）
	var remove_lod0: Array = []
	var coarsest := maxi(lod_count, 1) - 1
	for ck in _lod_meshes[0]:
		# 移除阈值统一用 lod0_d + margin（与下方补建阈值一致），消除 (lod0_d, lod0_d+margin]
		# 重叠区间——否则该区间内 chunk 每帧"移除→补建"来回抖动，_level_finer_ready
		# 随之在就绪/未就绪间跳变，LOD1 块可见性闪烁（lod_count=2 严重）。
		if _block_dist(ck, 0, cam_pos) <= lod0_d + lod0_margin:
			continue  # 仍在 LOD0 带（含滞回 margin），保留
		var level := _chunk_render_level(ck, cam_pos)
		if level > 0:
			var bk := _lod_block_of_chunk(ck, level)
			# 粗层 mesh 已实际就绪（非空标记）才移除 LOD0：空标记（null）表示粗层数据未就绪/生成晚，
			# 此时保留 LOD0 兜底显示，避免移动时 LOD0/LOD1 边界出现过渡空洞。
			var coarse_mesh: MeshInstance3D = _lod_meshes[level].get(bk)
			if coarse_mesh != null or _block_dist(bk, level, cam_pos) > _lod_outer[level] + _lod_margin(level):
				remove_lod0.append(ck)
		else:
			# lod_count=1 无更粗层 → 超出 LOD0 显示区直接移除，否则残留旧网格
			remove_lod0.append(ck)
	for ck in remove_lod0:
		_remove_chunk_mesh(ck)
	# 补建视锥内 LOD0 区未建的 chunk（相机移动不产生 dirty，需主动补建）
	var need_lod0_update := false
	if cam != null:
		var _chunk_world := voxel_scale * VoxelChunk.CHUNK_SIZE
		var _r_ck := ceili((lod0_d + lod0_margin) / _chunk_world) + 1
		var _cam_ck := _chunk_from_world(cam_pos, _chunk_world, world_offset)
		if loaded_chunks.is_empty():
			# 移动后新区域：loaded_chunks 为空（LOD0 数据未加载）→ 从相机位置推导补建。
			# 否则 LOD0 chunk 永不被 request/加载 → 近处 LOD0 空洞固定存在。
			for dx in range(-_r_ck, _r_ck + 1):
				for dy in range(-_r_ck, _r_ck + 1):
					for dz in range(-_r_ck, _r_ck + 1):
						var ck: Vector3i = _cam_ck + Vector3i(dx, dy, dz)
						if _lod_meshes[0].has(ck):
							continue
						if _block_dist(ck, 0, cam_pos) > lod0_d + lod0_margin:
							continue
						if not data.has_chunk(ck):
							data.request_chunk_async(ck, 0)  # LOD0 数据加载（文件流读盘/程序化生成）
						data._mark_chunk_dirty(ck)
						need_lod0_update = true
		else:
			for ck in loaded_chunks:
				if absi(ck.x - _cam_ck.x) > _r_ck or absi(ck.y - _cam_ck.y) > _r_ck or absi(ck.z - _cam_ck.z) > _r_ck:
					continue
				if _lod_meshes[0].has(ck):
					continue
				var bdist := _block_dist(ck, 0, cam_pos)
				if bdist > lod0_d + lod0_margin:
					continue  # 粗 LOD 区
				# 粗层带（render_level>0）的 chunk 由对应粗层 block 覆盖，
				# 不标记 LOD0 dirty——否则补建→转交粗层→无 L0 mesh→再补建死循环，
				# 且 _level_finer_ready 会把它当"重建中就绪"→ L1 隐藏 → LOD0/LOD1 交界空洞。
				if _chunk_render_level(ck, cam_pos) > 0:
					continue
				data._mark_chunk_dirty(ck)
				need_lod0_update = true
	if need_lod0_update:
		_request_update()


## 该 chunk 区域应渲染的 LOD 层级（block 中心距离所属的分带）
## 用 _lod_outer.size() 而非 lod_count，避免 lod_count 切换瞬间 _lod_outer 未同步时越界
func _chunk_render_level(ck: Vector3i, cam_pos: Vector3) -> int:
	var n: int = mini(_lod_outer.size(), maxi(lod_count, 1))
	if n <= 0:
		return 0
	for level in n:
		if _block_dist(_lod_block_of_chunk(ck, level), level, cam_pos) <= _lod_outer[level]:
			return level
	return n - 1


## 本层 block 的覆盖区域在内层（level-1）是否已全部就绪（有网格或为空）。
## level 1 的内层 = chunk（level 0）；仅统计视锥内的（视锥外不显示、无需网格不阻塞）。
func _level_finer_ready(level: int, bk: Vector3i, cam: Camera3D) -> bool:
	if level <= 0:
		return true
	var fine := level - 1
	for k in 2:
		for j in 2:
			for i in 2:
				var sbk := Vector3i(bk.x * 2 + i, bk.y * 2 + j, bk.z * 2 + k)
				# 内层就绪判定：LOD0 chunk 无空标记（有 mesh 即就绪）；
				# 粗层 block 的空标记（null，数据/网格未就绪）不算就绪 → 更粗层兜底显示，防过渡空洞。
				var fine_ready: bool = _has_lod_mesh(fine, sbk) if fine == 0 else (_lod_meshes[fine].get(sbk) != null)
				if fine_ready:
					continue
				if fine == 0:
					if data.has_chunk(sbk):
						# 重建中（mesh 在构建队列或数据层标脏）→ 仅当该 chunk 实际属于
						# LOD0 带（render_level==0，会被 L0 构建）才视为就绪：
						# 破坏瞬间内层未就绪会导致粗层临时替代（LOD 边界来回移动 → 闪烁）。
						# 而 LOD1 带的 chunk 由粗层覆盖、L0 永不构建，若当成就绪会让
						# _process_lod_level 隐藏粗层 → LOD0/LOD1 交界处背景透出空洞。
						if _mesh_build_queue.has(sbk) or (data and data._dirty_mesh_chunks.has(sbk)):
							if _chunk_render_level(sbk, cam.global_position) == 0:
								continue
						var aabb := _chunk_world_aabb(sbk, voxel_scale * VoxelChunk.CHUNK_SIZE, global_position)
						if _aabb_has_vertex_in_frustum(aabb, cam):
							return false
				else:
					return false
	return true


## LOD 网格表访问助手：index 直接 = LOD 层级（0 = 全精度 chunk，>=1 = 粗层大块）
func _has_lod_mesh(level: int, bk: Vector3i) -> bool:
	return level < _lod_meshes.size() and _lod_meshes[level].has(bk)


## 该粗层 block 是否处于失效重建中（破坏/编辑触发，保留旧 mesh 等待新 mesh 替换）
func _lod_rebuilding(level: int, bk: Vector3i) -> bool:
	return level < _lod_rebuild.size() and _lod_rebuild[level].get(bk, false)


func _set_lod_mesh(level: int, bk: Vector3i, mi) -> void:
	if level < _lod_meshes.size():
		_lod_meshes[level][bk] = mi


## 移除指定层级 block 网格（level 0 = chunk mesh；>=1 = 粗 LOD 大块）
func _remove_lod_mesh(level: int, bk: Vector3i) -> void:
	if level == 0:
		_remove_chunk_mesh(bk)
		return
	if level >= _lod_meshes.size():
		return
	var mi = _lod_meshes[level].get(bk)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[level].erase(bk)
	_lod_pending[level].erase(bk)
	_lod_pending_tasks[level].erase(bk)


## LOD 生成优先级：距离 + 视线方向加权（前方 block 先生成）。返回值越小越优先。
func _lod_load_priority(bk: Vector3i, level: int, cam_pos: Vector3, cam_dir: Vector3) -> float:
	var center := _lod_block_center(bk, global_position, _lod_block_edge_world(level))
	var to_center := center - cam_pos
	var dist := to_center.length()
	if dist < 0.001:
		return 0.0
	var forward := to_center.normalized().dot(cam_dir)
	return dist - forward * dist * 0.5


## 派发粗 LOD 大块异步生成（独立数据层）：快照 block+邻居大格（COW）+ WorkerThreadPool
## 后台直接由大格数据生成 mesh（无需 LOD0 chunk）。修改过的 block 走降采样回退
## （从 LOD0 数据降采样，编辑区在近处 LOD0 通常在内存）。
## 返回是否真正派发（已 pending / 无效 level 时 false——调用方据此决定是否消耗构建预算）。
func _build_lod_block(level: int, bk: Vector3i) -> bool:
	if not data:
		return false
	if level < 1 or level >= _lod_pending_tasks.size():
		return false
	if _lod_pending_tasks[level].has(bk):
		return false
	_lod_pending_tasks[level][bk] = true
	# 只派发（主线程轻量）：快照/降采样/mesh 全部在 worker 内完成——
	# 数据保留在内存（_chunk_buffers/粗层大格只读），worker 一次生成完整 mesh（halo 完整——无空洞），
	# 主线程不构造快照（不卡），每帧按数量派发全部 needed block（不饿死）。
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_build.bind(
		data, bk, level, _lod_generation_id[level], voxel_scale,
		data.center_offset if data else Vector3.ZERO, _lod_materials[level].duplicate())))
	return true


## 内带失效 block（LOD0 显示区）：只降采样同步粗层数据（_coarse_buffers + 持久化）。
## mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被丢弃——拆分两阶段，避免内带生成完整粗层 mesh 的 worker 浪费。
func _build_lod_data_only(level: int, bk: Vector3i) -> void:
	if not data:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	if _lod_pending_tasks[level].has(bk):
		return
	_lod_pending_tasks[level][bk] = true
	var snapshot := data.snapshot_lod_block_chunks(bk, level)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_data_only.bind(
		snapshot, bk, level, _lod_generation_id[level])))


## 工作线程：粗 LOD 大块由独立大格数据直接生成 mesh（线程安全，只读参数快照）。
## 直接在此构建 ArrayMesh（add_surface_from_arrays 走 RenderingServer，线程安全；
## GPU 上传由引擎延迟到主线程渲染提交，摊平上传尖峰），主线程只做轻量挂载。
func _lod_worker(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int, scale: float,
		offset: Vector3, aligned_materials: Array) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(buffers, bk)
	var arr := VoxelChunkGenerator.generate_lod_block_arrays(halo, aligned_materials, scale, bk, offset, level)
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
	call_deferred("_on_lod_thread_result", bk, level, mesh, gen_id)


## 工作线程：粗 LOD 大块 mesh 生成（快照/降采样/mesh 全在 worker 内——主线程只轻量派发）。
## 数据保留在内存（VoxelData 只读 COW 安全），一次生成完整 halo（边界无缺面空洞），
## 降采样时顺带返回大格数据（buf）同步粗层缓存。
func _lod_worker_build(vd: VoxelData, bk: Vector3i, level: int, gen_id: int, scale: float,
		offset: Vector3, aligned_materials: Array) -> void:
	var need_downsample := vd.is_lod_block_modified(level, bk)
	var halo: PackedInt32Array
	var buf := PackedInt32Array()
	if not need_downsample:
		var coarse_idx := level - 1
		var coarse: Dictionary = vd._coarse_buffers[coarse_idx] if coarse_idx < vd._coarse_buffers.size() else {}
		if not coarse.has(bk):
			need_downsample = true
		else:
			for d in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0), Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
				if not coarse.has(bk + d):
					need_downsample = true
					break
	if need_downsample:
		# 从 LOD0 降采样（一次生成完整 halo——边界无缺面空洞）。
		# 用纯只读快照：worker 线程内不 preload/不写 _chunk_buffers（线程安全），
		# 数据保留在内存（LOD 区不禁用卸载）时结果完整；缺失 chunk 视为空（真空区域）。
		var buffers := vd.snapshot_lod_block_chunks_readonly(bk, level)
		halo = VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
		var g := VoxelChunkGenerator.LOD_BLOCK_SIZE
		var hs := VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
		var off := VoxelChunkGenerator.LOD_BLOCK_HALO
		buf.resize(g * g * g)
		for lz in g:
			for ly in g:
				for lx in g:
					buf[lx + ly * g + lz * g * g] = halo[(off + lx) + (off + ly) * hs + (off + lz) * hs * hs]
	else:
		var snap := vd.snapshot_lod_block_data(bk, level)
		halo = VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(snap, bk)
	var arr := VoxelChunkGenerator.generate_lod_block_arrays(halo, aligned_materials, scale, bk, offset, level)
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
	call_deferred("_on_lod_thread_result", bk, level, mesh, gen_id, buf)


## 工作线程：修改过的粗 LOD 大块降采样 halo + 一次性网格生成（线程安全，只读参数快照）。
## 顺带返回降采样大格数据（buf），主线程同步粗层缓存（_coarse_buffers + 持久化），
## 让"request 早于 LOD0 就绪 → 自动降采样空"的块也能补上缓存（mesh 与数据一致，重启复用）。
func _lod_worker_downsample(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int, scale: float,
		offset: Vector3, aligned_materials: Array) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
	var arr := VoxelChunkGenerator.generate_lod_block_arrays(halo, aligned_materials, scale, bk, offset, level)
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
	var buf := PackedInt32Array()
	buf.resize(VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE)
	var g := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var hs := VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var off := VoxelChunkGenerator.LOD_BLOCK_HALO
	for lz in g:
		for ly in g:
			for lx in g:
				buf[lx + ly * g + lz * g * g] = halo[(off + lx) + (off + ly) * hs + (off + lz) * hs * hs]
	call_deferred("_on_lod_thread_result", bk, level, mesh, gen_id, buf)


## 工作线程：内带失效 block 只降采样大格数据（不生成 mesh——mesh 由 LOD0 chunk 反映）。
## 拆分两阶段：内带 block 的粗层 mesh 应用会被 _should_apply 丢弃，省去 arrays/mesh 构建。
func _lod_worker_data_only(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
	var g := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var hs := VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var off := VoxelChunkGenerator.LOD_BLOCK_HALO
	var buf := PackedInt32Array()
	buf.resize(g * g * g)
	for lz in g:
		for ly in g:
			for lx in g:
				buf[lx + ly * g + lz * g * g] = halo[(off + lx) + (off + ly) * hs + (off + lz) * hs * hs]
	call_deferred("_on_lod_data_ready", bk, level, gen_id, buf)


## 主线程：内带失效 block 降采样数据同步（_coarse_buffers + 持久化），mesh 由 LOD0 反映。
func _on_lod_data_ready(bk: Vector3i, level: int, gen_id: int, buf: PackedInt32Array) -> void:
	if _exiting:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	_lod_pending_tasks[level].erase(bk)
	if gen_id != _lod_generation_id[level]:
		return
	if buf.size() > 0 and data != null:
		data.set_lod_block(level, bk, buf)
		if data.stream is VoxelFileStream:
			data.stream.save_chunk(bk, buf, level)
	else:
		# 降采样空（LOD0 数据未就绪）：不设空标记（否则跳过→洞永远），重试计数防真空循环
		var _rk := str(level) + "_" + str(bk)
		var _rn: int = _lod_null_retries.get(_rk, 0)
		if _rn >= 3:
			_lod_null_retries.erase(_rk)
			_lod_meshes[level][bk] = null  # 真空 block：标记空，避免重复派发
		else:
			_lod_null_retries[_rk] = _rn + 1
	# 数据已同步（mesh 由 LOD0 chunk 反映），解除重建标记防重复派发
	if level < _lod_rebuild.size():
		_lod_rebuild[level].erase(bk)


## 主线程粗 LOD 结果处理：校验 gen_id，然后入队帧尾限量挂载。
## mesh 已在工作线程构建（ArrayMesh），此处仅轻量挂载——避免主线程同步构建大 mesh 卡顿。
## 降采样回退路径会顺带返回大格数据 buf，同步粗层缓存（_coarse_buffers + 持久化），避免缓存缺口。
func _on_lod_thread_result(bk: Vector3i, level: int, mesh: ArrayMesh, gen_id: int,
		buf := PackedInt32Array()) -> void:
	if _exiting:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	_lod_pending_tasks[level].erase(bk)
	if gen_id != _lod_generation_id[level]:
		return
	# 同步粗层缓存（降采样回退的数据与 mesh 一致，供后续复用/持久化）。
	# 仅 mesh 非空（有实际体素）才写缓存：真空 block 若写全 0 buffer，
	# has_lod_block=true → _process_lod_level 判"数据就绪但 mesh 空"→ 每帧重新派发
	# → 死循环占满跨层构建预算，更粗层永远分不到（远处空洞）。
	if buf.size() > 0 and data != null and mesh != null and mesh.get_surface_count() > 0:
		data.set_lod_block(level, bk, buf)
		if data.stream is VoxelFileStream:
			data.stream.save_chunk(bk, buf, level)
	if _lod_meshes[level].has(bk) and not _lod_rebuilding(level, bk):
		return
	if mesh == null or mesh.get_surface_count() == 0:
		# 降采样结果为空：多为 LOD0 数据未就绪（快照空）→ 不设空标记，移除条目让后续重试。
		# 否则空标记会让 _process_lod_level 跳过该 block，LOD0 数据就绪后也不会重建 → 洞永远。
		# 真空 block 防循环：重试计数上限后设空标记。
		if _lod_rebuilding(level, bk):
			_remove_lod_mesh(level, bk)
		if level < _lod_rebuild.size():
			_lod_rebuild[level].erase(bk)
		var _rk := str(level) + "_" + str(bk)
		var _rn: int = _lod_null_retries.get(_rk, 0)
		if _rn >= 3:
			_lod_null_retries.erase(_rk)
			_lod_meshes[level][bk] = null  # 真空 block：标记空，避免重复派发
			return
		_lod_null_retries[_rk] = _rn + 1
		_lod_meshes[level].erase(bk)  # 移除条目 → 下次 _process_lod_level 重新派发降采样
		return
	_lod_mesh_apply_queue.append([level, bk, mesh])


## 主线程挂载粗 LOD 大块网格（mesh 已由工作线程构建，此处仅建节点 + 赋材质 + 挂载，很轻）
## 失效重建时复用已有节点（直接替换 mesh，避免节点销毁/重建造成闪烁）
func _build_lod_from_arrays(level: int, bk: Vector3i, mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D
	if _lod_meshes[level].has(bk) and _lod_meshes[level][bk] is MeshInstance3D:
		mi = _lod_meshes[level][bk]
	else:
		mi = MeshInstance3D.new()
		mi.name = "LOD%dB_%d_%d_%d" % [level, bk.x, bk.y, bk.z]
		add_child(mi)
		mi.position = Vector3(bk) * _lod_block_edge_world(level)
	if mesh != null and mesh.get_surface_count() > 0:
		_apply_materials(mesh)
		mi.mesh = mesh
	_set_lod_mesh(level, bk, mi)
	_lod_null_retries.erase(str(level) + "_" + str(bk))
	if level < _lod_rebuild.size():
		_lod_rebuild[level].erase(bk)


## 卸载单个 chunk 网格（非超级块模式）：释放 mesh + 节点。
## 重载不再需要渲染层注册表：统一流式扫描用 stream.has_chunk（程序化）/VoxelData._persisted_chunks
## （文件流）判定存在性，重进加载范围即按需重载。
func _unload_chunk(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _lod_meshes[0].get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[0].erase(ck)
	_remove_chunk_collision(ck)
	_mesh_build_queue.erase(ck)
	_stream_force_build.erase(ck)
	# 数据层流式卸载（磁盘写盘/丢弃）——禁用：LOD0 chunk 数据保留内存，
	# 粗层降采样直接从内存 _chunk_buffers 快照（数据始终就绪 → mesh 完整 → 无空洞，零写盘）。
	# 若 data and data.is_streaming():
	# 	data.unload_chunk(ck)
	# 记录性能/内存释放（诊断）
	if diag_enabled:
		print("[诊断] 流式卸载: Chunk%s" % ck)


## 清除单个 chunk 的渲染网格（数据层已变空、但渲染层 mesh 残留时调用）。
## 破坏/崩塌后 chunk 内体素全被移除（has_chunk=false），增量重建时 _filter_visible_chunks
## 会跳过空 chunk 不派发 → 若不主动清除，旧 mesh 残留 → 视觉上"悬空块还在"（数据其实已掉）。
func _remove_chunk_mesh(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _lod_meshes[0].get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[0].erase(ck)
	_remove_chunk_collision(ck)
	_mesh_build_queue.erase(ck)
	_stream_force_build.erase(ck)
	_deferred_chunks.erase(ck)


## 异步路径：后台线程生成网格数据，完成后通过 call_deferred 直接传递结果到主线程
## 主线程绝不阻塞：旧任务未完成时直接启动新任务覆盖，子线程完成后检查 gen_id 丢弃过期结果
func _update_mesh_async() -> void:
	# 若旧任务已完成但还未轮询应用（极端情况），不阻塞，直接启动新任务覆盖
	# 旧任务子线程完成后会因 gen_id 不匹配而不写入结果（自然丢弃）

	# 【密集光环快照方案】不为每个 chunk 提取字典切片，而是让 VoxelData 直接从其
	# dense chunk 缓冲构建 18³ 密集"光环"（chunk + 1 体素外缘，PackedInt32Array 深拷贝）。
	# 每个子线程只读取自己那个私有的光环快照，主线程后续增删 data 不与之冲突，
	# 杜绝数据竞态（块随机显示/隐藏的根因），同时避免整世界深拷贝与字典切片扫描。
	var rebuild_chunks: Array[Vector3i] = []
	# chunk 级脏标记（_mark_voxel_dirty 已含跨界面的边界邻居），
	# 替代逐体素 dirty_voxels 的大批量追踪——大崩塌移除不再主线程逐体素写 dict
	rebuild_chunks = data.get_dirty_chunks()
	# 限量批次：超过上限的放回 dirty（下帧续建）。回原点/大崩塌时 dirty 可上千，
	# 单帧全量快照 + 派发上千 worker → 主线程阻塞（update_mesh 数百 ms → 帧率个位数）。
	# 分批后每帧快照/派发量受限，网格经 _process_mesh_build_queue 平滑上传。
	if rebuild_chunks.size() > _rebuild_batch_limit:
		for i in range(_rebuild_batch_limit, rebuild_chunks.size()):
			data._mark_chunk_dirty(rebuild_chunks[i])
		rebuild_chunks.resize(_rebuild_batch_limit)
		# 放回剩余 dirty 后必须重新置位：_update_mesh 开头会清 _dirty，
		# 若不重新 _request_update，剩余 dirty 将永久卡住 → 初始构建/大批量
		# 重建只生成第一批，其余 chunk 网格缺失（破坏demo初始只显示一个小角落、
		# 流式demo脚底下不显示）。置位后下帧 _process 继续消费下一批。
		_request_update()
	# 材质快照复用缓存（仅在材质变化时深拷贝），避免每帧大对象深拷贝
	var snapshot_materials := _materials_snapshot
	# 一次对齐材质供所有 per-chunk worker 复用，避免每个任务重复 align_by_id
	# （生成器内部要求"数组索引==材质ID"，对齐后可 O(1) 按 ID 取材质）
	var aligned_materials := VoxelMaterial.align_by_id(snapshot_materials)
	var gen_id := _generation_id + 1
	_generation_id = gen_id
	# 渲染居中偏移（体素单位），子线程无权访问节点，随任务参数传入
	var render_offset: Vector3 = data.center_offset if data else Vector3.ZERO

	_task_ids.clear()
	_pending_task_count = 0

	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	# 将 voxel_scale 等渲染参数作为任务参数传入，避免子线程访问节点属性
	#
	# 每个脏 chunk 独立一个线程任务，WorkerThreadPool 内部管理并发数
	# per-chunk 异步生成（唯一网格路径）
	if rebuild_chunks.is_empty():
		# 全量构建（初始构建或切换模式后）：分 chunk 独立线程，逐个显示
		var all_chunks := data.get_all_chunk_keys()
		if all_chunks.is_empty():
			# 空场景：无 chunk 可生成，直接返回（无任务，pending 保持 0）
			return
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		var visible: Array[Vector3i] = _filter_visible_chunks(all_chunks)
		if diag_enabled:
			print("[诊断] 全量构建 gen_id=%d: 总%d Chunk, 视锥内%d, 延迟%d" % [gen_id, all_chunks.size(), visible.size(), all_chunks.size() - visible.size()])
		var snapshot: Dictionary = data.snapshot_chunks_halo(visible)
		_pending_task_count = visible.size()
		for ck in visible:
			_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
				snapshot, aligned_materials, ck, gen_id, voxel_scale, render_offset, diag_enabled)))
	else:
		# 增量重建：每个 chunk 独立一个线程任务，真正并行处理
		# 【关键】先清除"已变空"chunk 的残留 mesh：破坏/崩塌后 chunk 内体素
		# 全被移除（has_chunk=false），而 _filter_visible_chunks 会跳过空 chunk
		# 不派发重建 → 若不主动清除，旧 mesh 残留，视觉上"悬空块还在"（数据其实已掉）。
		for ck in rebuild_chunks:
			if _lod_meshes[0].has(ck) and not data.has_chunk(ck):
				_remove_chunk_mesh(ck)
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		var visible: Array[Vector3i] = _filter_visible_chunks(rebuild_chunks)
		if diag_enabled:
			print("[诊断] 增量重建 gen_id=%d: 脏%d Chunk, 视锥内%d, 延迟%d" % [gen_id, rebuild_chunks.size(), visible.size(), rebuild_chunks.size() - visible.size()])
		var snapshot: Dictionary = data.snapshot_chunks_halo(visible)
		_pending_task_count = visible.size()
		for ck in visible:
			_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
				snapshot, aligned_materials, ck, gen_id, voxel_scale, render_offset, diag_enabled)))


## 统一工作线程结果字典契约（#6）：全量/增量/单chunk/空场景所有生成路径
## 都通过 _make_result 构建结果，消费方 _apply_single_chunk_result 统一按键读取。
## chunk_key 缺省为 (-999,-999,-999) 表示"非单chunk结果"（全量结果）。
static func _make_result(arrays: Variant, gen_time_ms: float, solid_vertices: int,
		trans_vertices: int, total_chunks: int, affected_count: int, gen_id: int,
		chunk_key: Vector3i = Vector3i(-999, -999, -999)) -> Dictionary:
	return {
		"arrays": arrays,
		"chunk_key": chunk_key,
		"gen_time_ms": gen_time_ms,
		"solid_vertices": solid_vertices,
		"trans_vertices": trans_vertices,
		"total_chunks": total_chunks,
		"affected_count": affected_count,
		"gen_id": gen_id,
	}


## 统计 chunk_arrays 字典（ck -> {solid_verts, trans_verts}）的总实心/透明顶点数
static func _count_chunk_vertices(chunk_arrays: Dictionary) -> Vector2i:
	var sv := 0
	var tv := 0
	for ck in chunk_arrays:
		var arr = chunk_arrays[ck]
		if arr is Dictionary:
			sv += arr.get("solid_verts", PackedVector3Array()).size()
			tv += arr.get("trans_verts", PackedVector3Array()).size()
	return Vector2i(sv, tv)


## 以顶点计数更新 last_* 统计字段（实心/透明三角形 = 顶点数 / 3）
func _set_last_vertex_stats(solid_vertices: int, trans_vertices: int, total_chunks: int) -> void:
	last_solid_vertices = solid_vertices
	last_trans_vertices = trans_vertices
	last_solid_triangles = solid_vertices / 3
	last_trans_triangles = trans_vertices / 3
	last_total_chunks = total_chunks


## 从统一结果字典更新 last_* 统计字段
func _apply_stats_from_result(result: Dictionary) -> void:
	last_mesh_gen_time_ms = result.get("gen_time_ms", 0.0) as float
	_set_last_vertex_stats(
		result.get("solid_vertices", 0),
		result.get("trans_vertices", 0),
		result.get("total_chunks", 0))


## 后台工作线程入口：生成网格数据并写入结果缓冲
## 主线程通过 _process 轮询 WorkerThreadPool.is_task_completed 后读取，保证线程安全
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
## diag_enabled 由主线程派发时捕获传入，子线程只读参数，避免跨线程访问节点属性
## 单 chunk 工作线程入口：每个脏 chunk 独立一个线程任务，真正并行处理
## 每个 chunk 独立生成网格数据，完成后通过 call_deferred 直接传回主线程
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
## buffers 为主线程派发时一次性构建的"受影响区域"chunk 缓冲快照（深拷贝字典），
## worker 在子线程内据此构建自己的 18³ halo（纯只读，无数据竞态），
## 避免主线程逐 chunk 提取 halo 造成秒级阻塞（旧方案）。
## materials 参数为已按 ID 对齐的材质数组（主线程派发时一次对齐，worker 复用避免重复开销）
## diag_enabled 由主线程派发时捕获传入，子线程只读参数，避免跨线程访问节点属性
func _generate_chunk_worker(buffers: Dictionary, materials: Array, chunk_key: Vector3i,
		gen_id: int, scale: float, offset: Vector3 = Vector3.ZERO,
		diag_enabled: bool = false) -> void:
	var t0 := Time.get_ticks_usec()
	var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, chunk_key)
	var arr := VoxelChunkGenerator.generate_single_chunk_dense(halo, materials, scale, chunk_key, offset)
	var gen_time_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# 诊断：每 chunk 生成耗时 > 5ms 时打印（仅诊断模式开启时）
	if diag_enabled and gen_time_ms > 5.0:
		print("[诊断] _generate_chunk_worker: Chunk%s, 总=%.2fms" % [chunk_key, gen_time_ms])

	# 统计顶点数
	var sv := 0
	var tv := 0
	var has_data := not arr.is_empty()
	if has_data:
		sv = arr.get("solid_verts", PackedVector3Array()).size()
		tv = arr.get("trans_verts", PackedVector3Array()).size()

	# 构建结果字典（统一契约 _make_result，含 chunk_key 供 _apply_single_chunk_result 识别单个 chunk）
	var arrays := {}
	if has_data:
		arrays[chunk_key] = arr
	var result := _make_result(arrays, gen_time_ms, sv, tv,
		1 if has_data else 0, 1, gen_id, chunk_key)

	# 使用 call_deferred 将结果传回主线程
	call_deferred("_on_thread_result", result)


## 主线程结果处理入口（通过 call_deferred 从工作线程调用）
## 检查 gen_id 有效性，应用结果，递减计数器，全部完成后延迟到下一帧做批次清理
## 延迟批处理避免"最后一个任务完成"瞬间在主线程做重活（_on_batch_complete 可能触发
## 新任务启动/emit 信号），防止偶发帧尖峰（曾观测到 83ms 主线程 spike）
func _on_thread_result(result: Dictionary) -> void:
	if _exiting:
		return
	var _diag_t0 := Time.get_ticks_usec()
	# 丢弃过期结果（gen_id 不匹配说明是旧批次）
	var gen_id = result.get("gen_id", -1)
	if gen_id != _generation_id:
		return
	
	# 应用结果
	_apply_single_chunk_result(result)
	
	# 递减任务计数器，全部完成后延迟到下一帧执行批次清理
	_pending_task_count -= 1
	if _pending_task_count <= 0:
		_pending_task_count = 0  # 防止负数
		_batch_complete_pending = true

	if _pending_task_count >= 0:
		var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if diag_enabled and _t_ms > 0.5:
			print("[诊断] _on_thread_result: 剩余%d任务, 应用耗时%.2f ms" % [_pending_task_count, _t_ms])


## 应用单个 chunk 的异步结果（在主线程 _process 中调用）
## 结果恒为单 chunk（per-chunk 生成），直接更新对应子 MeshInstance3D
func _apply_single_chunk_result(result: Dictionary) -> void:
	var _diag_t0 := Time.get_ticks_usec()
	var _t_get_chunk := 0.0
	var arrays = result.get("arrays", {})
	var chunk_key: Vector3i = result.get("chunk_key", Vector3i(-999, -999, -999))
	var gen_id = result.get("gen_id", -1)
	var gen_time_ms = result.get("gen_time_ms", 0.0) as float

	# 更新统计信息（统一契约 _apply_stats_from_result）
	_apply_stats_from_result(result)
	last_rebuild_affected_count = 1
	last_rebuild_chunk_count = 1

	# 单 chunk 结果（来自 _generate_chunk_worker）
	if chunk_key.x != -999:
		# 流式：结果回来时 chunk 仍超出卸载距离（相机快速远离）→ 丢弃过期结果，
		# 避免卸载后的旧网格/旧数据复活。
		# 直接按【当前距离】判断（不依赖残留标记）：相机重新走近（<unload）的 chunk
		# 必须应用结果，否则永久缺失。
		var cam_now := get_viewport().get_camera_3d() if is_inside_tree() else null
		if _is_chunk_beyond_unload(
				chunk_key, cam_now, voxel_scale * VoxelChunk.CHUNK_SIZE, global_position, _unload_d()):
			_pending_task_count -= 1
			if _pending_task_count <= 0:
				_pending_task_count = 0
				_batch_complete_pending = true
			return
		var arr = arrays.get(chunk_key, {})
		var has_voxels_in_data := false
		if data:
			var _t1 := Time.get_ticks_usec()
			has_voxels_in_data = data.has_chunk(chunk_key)
			_t_get_chunk = (Time.get_ticks_usec() - _t1) / 1000.0
		# 程序化流：数据已被 LOD1 区释放（超 LOD0 区、由 LOD1 覆盖）→ 该异步结果过期丢弃。
		# 否则释放后异步 mesh 结果回来仍建网格 → 地块"显示→消失→再显示"闪烁。
		if data and data.stream is VoxelProceduralStream and not has_voxels_in_data:
			_pending_task_count -= 1
			if _pending_task_count <= 0:
				_pending_task_count = 0
				_batch_complete_pending = true
			return

		# 入队待构建（GPU 上传限流，_process 每帧批量处理）
		# 避免连续破坏时一帧大量 ArrayMesh 创建 + GPU 上传 → Metal fence 超时
		_mesh_build_queue[chunk_key] = {
			"arrays": arr if (arr is Dictionary and not arr.is_empty() and has_voxels_in_data) else {},
			"has_voxels": has_voxels_in_data,
		}
		_record_perf_stats(1, gen_time_ms, last_apply_time_ms)

	# 诊断：单 chunk 应用耗时 > 1ms 时打印
	var _t_apply_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	if diag_enabled and _t_apply_ms > 1.0 and chunk_key.x != -999:
		print("[诊断] _apply_single_chunk_result: Chunk%s, get_chunk=%.2fms, 总=%.2fms" % [chunk_key, _t_get_chunk, _t_apply_ms])


# GPU 上传限流（批量构建队列）
# 用 call_deferred 在帧尾执行，避开渲染循环内的 GPU 竞争；每帧限量构建。

## 每帧从构建队列取一批 chunk 构建 mesh（GPU 上传限流）。
## 连续破坏时大量异步结果回主线程，若每帧全部立即 build_mesh_from_arrays（同步 GPU 上传），
## Metal 驱动 fence 等待会超时。改为帧尾限量构建，把 GPU 上传摊平到多帧。
func _process_mesh_build_queue() -> void:
	_mesh_build_scheduled = false
	if _mesh_build_queue.is_empty():
		return

	var t0 := Time.get_ticks_usec()
	var built := 0
	# 大量破坏（dirty 多）→ 临时提高本帧构建数/时间预算，减少连续破坏的 mesh 更新延迟感
	var budget_n := _mesh_build_per_frame
	var budget_ms := 3.0
	if data and data._dirty_mesh_chunks.size() > _mesh_build_per_frame:
		budget_n = maxi(budget_n, 24)
		budget_ms = 8.0
	var keys := _mesh_build_queue.keys()
	# 优先处理已有 mesh 的 chunk（保证破坏面及时更新），再处理新 chunk
	keys.sort_custom(func(a, b):
		return _lod_meshes[0].has(a) and not _lod_meshes[0].has(b))
	for ck in keys:
		if built >= budget_n:
			break
		var entry: Dictionary = _mesh_build_queue[ck]
		_mesh_build_queue.erase(ck)
		_apply_built_chunk(ck, entry)
		built += 1
		# 自适应：若本帧构建已超预算，提前停止避免帧尖峰（大量破坏时预算放宽）
		if (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
	# 若还有剩余，下帧继续
	if not _mesh_build_queue.is_empty():
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	if diag_enabled and built > 0:
		print("[诊断] GPU上传批处理: %d chunk, 耗时%.2f ms, 剩余%d" % [
			built, (Time.get_ticks_usec() - t0) / 1000.0, _mesh_build_queue.size()])


## 帧尾限量挂载粗 LOD 大块 mesh（build_mesh_from_arrays + GPU 上传摊平到多帧）。
## 复用 _lod_build_per_frame 数量 + 3ms 时间预算；已移出区间的结果丢弃。
func _process_lod_mesh_apply_queue() -> void:
	_lod_mesh_apply_scheduled = false
	if _lod_mesh_apply_queue.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var built := 0
	var i := 0
	while i < _lod_mesh_apply_queue.size():
		if built >= _lod_build_per_frame:
			break
		if (Time.get_ticks_usec() - t0) / 1000.0 > 3.0:
			break
		var item: Array = _lod_mesh_apply_queue[i]
		var level: int = item[0]
		var bk: Vector3i = item[1]
		var mesh: ArrayMesh = item[2]
		# 重新校验区间（结果排队期间相机可能移动）
		if _should_apply_lod_mesh(level, bk):
			_build_lod_from_arrays(level, bk, mesh)
			built += 1
		elif level < _lod_rebuild.size() and _lod_rebuild[level].has(bk):
			# 内带丢弃（LOD0 区由 LOD0 chunk 反映洞）：数据已同步，解除重建标记防重复派发
			_lod_rebuild[level].erase(bk)
		_lod_mesh_apply_queue.remove_at(i)
	if not _lod_mesh_apply_queue.is_empty():
		_lod_mesh_apply_scheduled = true
		call_deferred("_process_lod_mesh_apply_queue")


## 粗 LOD 大块是否仍在显示区间（挂载前校验，相机移动后过期结果丢弃）。
## 失效重建的 block：强制应用（替换旧 mesh 反映破坏）——近处内带由 _level_finer_ready
## （重建中视为就绪）隐藏本层，不产生 LOD 层级切换；远处粗层区替换后显示含洞网格。
func _should_apply_lod_mesh(level: int, bk: Vector3i) -> bool:
	if level < 1 or level >= _lod_meshes.size():
		return false
	if _lod_meshes[level].has(bk) and not _lod_rebuilding(level, bk):
		return false
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return false
	var edge_world := _lod_block_edge_world(level)
	var dist := _block_dist(bk, level, cam.global_position)
	var unload_d := _unload_d()
	if _lod_rebuilding(level, bk):
		# 失效重建的粗层 mesh：只在粗层带内替换（反映破坏）；
		# LOD0 区内带不替换（粗层隐藏、由 LOD0 chunk mesh 反映洞），
		# 避免"LOD0 细洞先出现 → 粗层粗洞后替换"的先后交替闪烁。
		var inner := _lod_outer[level - 1] if level > 0 else 0.0
		var margin := _lod_margin(level)
		return dist > inner - margin and dist <= unload_d + edge_world * 0.5
	# 粗层数据已就绪：内带也挂载（mesh 预生成——LOD0 移除后粗层直接显示，防块状空洞；
	# 可见性由 _process_lod_level 的 _level_finer_ready 控制——LOD0 就绪则隐藏本层，无重叠）
	if data and data.has_lod_block(level, bk):
		return dist <= unload_d + edge_world * 0.5
	var inner := _lod_outer[level - 1] if level > 0 else 0.0
	var margin := _lod_margin(level)
	return not (dist < inner - margin or dist > unload_d + edge_world * 0.5)


## 给 ArrayMesh 的两个表面赋材质（实心/透明）。chunk/LOD1/碎片应用统一走此辅助。
func _apply_materials(new_mesh: ArrayMesh) -> void:
	if new_mesh and _materials_cache.size() >= 2:
		if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
			new_mesh.surface_set_material(0, _materials_cache[0])
		if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
			new_mesh.surface_set_material(1, _materials_cache[1])


## 应用单个待构建 chunk（构建 mesh + 挂载节点 + 更新碰撞）
func _apply_built_chunk(chunk_key: Vector3i, entry: Dictionary) -> void:
	# 带外校验：破坏/编辑不应让超出 LOD0 带的 chunk 临时挂载（否则粗层区破坏时
	# LOD0 细网格"闪现"后被移除 → 与粗层交替闪烁）。粗层区破坏由粗层 mesh 反映，
	# LOD0 chunk 只挂载带内；此处与 _process_chunk_level 的移除判定保持一致。
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam and _lod_outer.size() > 0:
		var lod0_d := _lod_outer[0]
		var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
		if _chunk_center_dist(chunk_key, cam.global_position, chunk_size_world, global_position) > lod0_d + chunk_size_world * 0.5:
			_remove_chunk_collision(chunk_key)
			return
	var arr: Dictionary = entry["arrays"]
	var has_voxels_in_data: bool = entry["has_voxels"]

	# 获取或创建该 chunk 的子 MeshInstance3D
	var chunk_mesh: MeshInstance3D
	if _lod_meshes[0].has(chunk_key):
		chunk_mesh = _lod_meshes[0][chunk_key]
	else:
		chunk_mesh = MeshInstance3D.new()
		chunk_mesh.name = "Chunk_%d_%d_%d" % [chunk_key.x, chunk_key.y, chunk_key.z]
		add_child(chunk_mesh)
		_lod_meshes[0][chunk_key] = chunk_mesh

	var has_mesh := false
	if not arr.is_empty() and has_voxels_in_data:
		var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
		_apply_materials(new_mesh)
		chunk_mesh.mesh = new_mesh
		has_mesh = new_mesh != null
	elif not has_voxels_in_data:
		# chunk 已无体素，清除 mesh 数据并移除容器防止累积
		chunk_mesh.mesh = null
		chunk_mesh.queue_free()
		_lod_meshes[0].erase(chunk_key)
	else:
		# 竞态：生成后体素被重新添加，保留已有 mesh
		has_mesh = chunk_mesh.mesh != null

	if has_voxels_in_data or _lod_meshes[0].has(chunk_key):
		chunk_mesh.position = Vector3(chunk_key) * (voxel_scale * VoxelChunkGenerator.CHUNK_SIZE)
		# 碰撞增量重建：入队延迟，_process 每帧限量重建（避免连续破坏主线程卡顿）
		_collision_rebuild_queue[chunk_key] = has_mesh
	else:
		_remove_chunk_collision(chunk_key)


## 批次完成清理：当所有任务都完成后执行
## 处理 _pending_retrigger 并发出 mesh_updated 信号
## 空 Chunk 清理已在 _apply_single_chunk_result 中增量完成，无需全量遍历
func _on_batch_complete() -> void:
	# 处理 _pending_retrigger（极少情况下被外部设置）
	if _pending_retrigger:
		_pending_retrigger = false
		if diag_enabled:
			print("[诊断] 触发 Retrigger: 启动新任务")
		_dirty = true
		_update_mesh()
	else:
		# 脏体素追踪已在 _update_mesh_async 启动任务时清除，无需重复清理
		pass

	# 批次完成信号（外部依赖此信号感知场景更新完毕）
	mesh_updated.emit()


## 生成多个 chunk 的网格数据（串行，在工作线程内调用时避免嵌套线程池死锁）
## 注意：此函数在工作线程内调用，禁止使用 add_group_task 等嵌套线程池调用
func _update_collision() -> void:
	_clear_collision()
	if not mesh:
		return
	_collision_body = StaticBody3D.new()
	_collision_body.name = _COLLISION_BODY_NAME
	var shape := ConcavePolygonShape3D.new()
	var faces := mesh.get_faces()
	if faces.size() > 0:
		shape.set_faces(faces)
		var owner_id := _collision_body.create_shape_owner(_collision_body)
		_collision_body.shape_owner_add_shape(owner_id, shape)
	add_child(_collision_body, false, Node.INTERNAL_MODE_BACK)


func _clear_collision() -> void:
	if _collision_body:
		_collision_body.queue_free()
		_collision_body = null


## 清理所有 chunk 子 MeshInstance3D 及关联碰撞体
func _clear_lod_meshes() -> void:
	_deferred_chunks.clear()
	_mesh_build_queue.clear()
	_lod_mesh_apply_queue.clear()
	for lv in _lod_rebuild.size():
		_lod_rebuild[lv].clear()
	# 清理所有 LOD 层网格（LOD0 chunk + 各粗层大块；null 表示空大块标记，跳过）
	for level in _lod_meshes.size():
		for bk in _lod_meshes[level]:
			var mi: MeshInstance3D = _lod_meshes[level][bk]
			if mi != null and is_instance_valid(mi):
				mi.queue_free()
		_lod_meshes[level].clear()
		_lod_pending[level].clear()
		_lod_pending_tasks[level].clear()
	if data:
		data.clear_lod_cache()
	_clear_chunk_collisions()


## 清理所有 per-chunk 碰撞体
func _clear_chunk_collisions() -> void:
	for ck in _chunk_collisions:
		var col = _chunk_collisions[ck]
		if col != null and is_instance_valid(col):
			col.queue_free()
	_chunk_collisions.clear()


## 将 per-chunk 网格数据应用到子 MeshInstance3D
## 注意：chunk_arrays 中可能包含空 chunk（空字典），用于清空已无体素的 chunk mesh
## 更新单个 chunk 的碰撞体（Per-chunk StaticBody3D + ConcavePolygonShape3D）
func _update_chunk_collision(ck: Vector3i, has_mesh: bool) -> void:
	if generate_collision and has_mesh:
		# 获取或创建 StaticBody3D
		var body: StaticBody3D
		if _chunk_collisions.has(ck):
			body = _chunk_collisions[ck]
		else:
			body = StaticBody3D.new()
			body.name = "Collision_%d_%d_%d" % [ck.x, ck.y, ck.z]
			add_child(body)
			_chunk_collisions[ck] = body

		# 位置与对应 MeshInstance3D 对齐
		var chunk_scale := voxel_scale * VoxelChunkGenerator.CHUNK_SIZE
		body.position = Vector3(ck) * chunk_scale

		# 从 chunk mesh 提取 faces 构建碰撞形状
		var chunk_mesh: MeshInstance3D = _lod_meshes[0].get(ck)
		if chunk_mesh and chunk_mesh.mesh:
			var faces := chunk_mesh.mesh.get_faces()
			if faces.size() > 0:
				# 复用或更新 CollisionShape3D
				var shape_node: CollisionShape3D
				if body.get_child_count() > 0 and body.get_child(0) is CollisionShape3D:
					shape_node = body.get_child(0)
					# 复用 ConcavePolygonShape3D，只更新 faces
					if shape_node.shape is ConcavePolygonShape3D:
						shape_node.shape.set_faces(faces)
					else:
						var new_shape := ConcavePolygonShape3D.new()
						new_shape.set_faces(faces)
						shape_node.shape = new_shape
				else:
					shape_node = CollisionShape3D.new()
					var new_shape := ConcavePolygonShape3D.new()
					new_shape.set_faces(faces)
					shape_node.shape = new_shape
					body.add_child(shape_node)
			else:
				# 有 mesh 但无顶点，移除碰撞体
				_remove_chunk_collision(ck)
		else:
			_remove_chunk_collision(ck)
	else:
		_remove_chunk_collision(ck)


## 移除单个 chunk 的碰撞体
func _remove_chunk_collision(ck: Vector3i) -> void:
	_collision_rebuild_queue.erase(ck)
	if _chunk_collisions.has(ck):
		_chunk_collisions[ck].queue_free()
		_chunk_collisions.erase(ck)
