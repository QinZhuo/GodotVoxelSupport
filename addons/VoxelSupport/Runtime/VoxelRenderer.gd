@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器
## 持有 VoxelData，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)

# 【INF】视点相关成员标记约定（P2-1 施工图）
#   被 `# [INF]` 标注的成员属于"无限层"（视点相关调度）：① LOD 分带/块调度 ② 流式加载卸载
#   ③ 视锥剔除 ④ 原点漂移 ⑤ 异步块供需。**P2-1 期 0~4 已全部迁出**（2026-10-08），
#   现仅剩两类标记：**留节点的 `@export` 配置旋钮**（无限层是 RefCounted，挂不了 @export）
#   与 **1 个 deferred 委托壳**（`_flush_lod_mesh_apply_queue`：deferred 目标须是节点，
#   避免 RefCounted 被释放后野调用）。分带/调度逻辑与账本见 VoxelInfiniteLayer。
#   约定：标记行紧贴成员的 `##` 文档块上方；一个成员的区间 = 标记行起，至下一个顶格非空行止。
#   未标注但相关：_process（视点编排入口，本身留在内核）、_record_perf_stats（统计）。
#   行数/标记数逐期只记在 docs/REFACTOR_PLAN.md §3 P2-1 施工分期，不在此维护。
#
# ── 内核对外契约（P2-2）────────────────────────────────────────────────────────
# 【目标形态】内核公开 API 只有两种形状：**按 chunk 索引** 与 **脏区域事件**。
#   "整块重算"式接口（重算全部 chunk / 返回整个世界）一律不提供 —— 那是无限层挂不上来的根因。
#   注意 `request_update()` **不是**"整块重算"：它只置一个"下一帧重建"的唤醒位，真正的重建
#   粒度始终是 chunk，由数据层脏账本（`VoxelDirtyLedger` → `data.get_dirty_chunks()`）给出。
#
# 【A. 脏区域事件（内核 → 外层，唯一载体）】
#   内核在 `_update_mesh_async` 把脏 chunk 列表交给外层做可见性决策：
#     `infinite_layer.filter_visible_chunks(rebuild_chunks)`（首次全量时传的是全部 chunk 列表）。
#   脏区域真值只有一份：`VoxelData` 的 mesh 脏位（`get_dirty_chunks()` / `mark_chunk_dirty()`）。
#   粒度可断言（见 Scripts/Test/test_voxel_kernel_contract.gd）：内部点编辑 → 恰好 1 个 chunk；
#   chunk 角点编辑 → 恰好 4 个（自身 + 3 个负向邻块）；**永不**退化为"全部 chunk"。
#
# 【B. 按 chunk 索引 · 写】
#   request_update()               唤醒下一帧重建（粒度由脏账本决定）
#   remove_chunk_mesh(ck)          释放该 chunk 的网格（+碰撞+队列条目）
#   shift_render(shift, cs_world)  原点漂移：整体平移渲染账本（一次性，不在每帧路径）
#   mount_lod_mesh / mark_lod_block_empty / clear_lod_mesh    粗层块网格挂 / 标空 / 卸
#   set_lod_level_count / clear_lod_level                     粗层层数
#
# 【C. 按 chunk 索引 · 查】
#   has_chunk_mesh(ck) / has_lod_mesh(level, bk) / lod_mesh(level, bk) / lod_mesh_keys(level)
#   is_mesh_build_queued(ck) / lod_materials(level) / lod_level_count() / surface_materials()
#
# 【D. 只读环境】
#   data / voxel_scale / global_position（节点自带） / current_camera() / get_data()
#
# 【E. 生命周期覆盖点】
#   on_origin_shift(shift)   子类（VoxelDestructible）平移自己的在途队列
#
# 【F. 兼容别名 / 插件公开 API（P4 收口；勿新增依赖）】
#   mark_dirty（= request_update） / force_update / regenerate_materials
#   set_voxel / remove_voxel / get_voxel
#
# 【不在契约内】相机、LOD 分带、流式加载卸载、视锥剔除、原点漂移判定、异步块供需
#   —— 全在 VoxelInfiniteLayer。内核只回答"按 chunk 建 / 删网格"。
# 【依赖方向】无限层 → 内核：读上述面 + 按键写网格账本（另按既有约定读 5 个 `@export`
#   私有旋钮 `_stream_*` / `_lod_*`：RefCounted 挂不了 @export，配置有意留在节点上）。
#   内核 → 无限层：只走它的公开方法（`filter_visible_chunks` / `process_*` / `deferred_is_empty`
#   / `is_deferred` / `unload_d` / `lod_outer` / `take_lod_mesh_flush_request` / `abort` /
#   `clear_lod_state` / `on_mesh_removed` / `set_visibility_mode` / `configure_lod`），
#   **不触碰它的私有字段**。
# 【锁定】本清单与 test_voxel_kernel_contract 的期望表一一对应：增删任何公开方法必须同时改两处。
# ──────────────────────────────────────────────────────────────────────────────

signal mesh_updated

## 无限层（视点调度）：视锥剔除 / 延迟补建队列 / 流式加载与卸载 / 卸载半径 / 原点漂移。
## 【依赖方向】内核只回答"按 chunk 建 / 删网格"，视点决策全部委托给它（详见 VoxelInfiniteLayer）。
## 【为何惰性创建而非 _init 里建】脚本热重载不会对既有节点实例重跑 _init，用 getter 可自愈，
## 避免"重载后旧实例的 infinite_layer 仍为 null"这类只在编辑器里冒出来的空引用。
var infinite_layer: VoxelInfiniteLayer:
	get:
		if _infinite_layer == null:
			_infinite_layer = VoxelInfiniteLayer.new(self)
		return _infinite_layer

var _infinite_layer: VoxelInfiniteLayer

# [INF] 视点相关（P2-1 迁出）
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
		_materials.invalidate()
		_configure_lod()
		_clear_lod_meshes()
		request_update()

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		# Voxel scale 变化会影响 chunk mesh 的位置，需要重建。
		# 守卫：本 setter 可能在 _ready()/_configure_lod() 之前被调用（场景反序列化、
		# 编辑器 Inspector 赋值、在 add_child 之前设属性），此时 _lod_meshes 仍为空数组，
		# 直接取 [0] 会越界报错。空数组时无网格可清理，跳过即可。
		if not _lod_meshes.is_empty() and not _lod_meshes[0].is_empty():
			_clear_lod_meshes()
		request_update()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
## 对大型动态场景(如水模拟)可显著降低重建频率，值越大越流畅但更新越滞后
@export_range(1, 30) var update_throttle_frames: int = 1

# [INF] 视点相关（P2-1 迁出）
## 可见性管理模式（统一视锥剔除与流式加载）
## - FULL     ：全量生成所有 chunk（中小世界）
## - FRUSTUM  ：视锥剔除，仅生成视锥内/附近 chunk（大型世界，省生成与显存）
## - STREAMING：流式加载，按距离生成 + 卸载远距网格（超大型世界，显存友好）
## 注：渲染层 GPU 剔除由引擎自动完成，此选项控制 CPU 侧生成调度
@export var visibility_mode: VisibilityMode = VisibilityMode.FRUSTUM:
	set(v):
		visibility_mode = v
		# 同步流式启用状态：运行时切换 STREAMING 立即生效（原只在 _ready 设置一次，
		# demo 在 _ready 之后才设 STREAMING 会导致流式从不启用）。
		# 无限层一并清空延迟队列（FULL 下补建队列失去意义）。
		infinite_layer.set_visibility_mode(v)
		if v == VisibilityMode.FULL:
			# 全量模式下补建已加载 chunk 的网格（卸载的由统一流式按需重载）
			if data:
				for ck in data.get_loaded_chunk_keys():
					data.mark_chunk_dirty(ck)
		request_update()
		# 可见性变化影响多个属性的有效性 → 刷新 Inspector（隐藏/显示条件属性）
		notify_property_list_changed()


# [INF] 视点相关（P2-1 迁出）
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

# [INF] 视点相关（P2-1 迁出）
## 可见性加载距离（世界单位）：FRUSTUM 时视锥外仍生成的半径；STREAMING 时网格加载半径
@export var view_distance: float = 40.0:
	set(v):
		view_distance = v
		infinite_layer.configure_lod(lod_count, view_distance)

# [INF] 视点相关（P2-1 迁出）
## 流式卸载距离（世界单位，仅 STREAMING）：超过此距离的 chunk 网格被卸载释放
## 默认 0 = 自动取 view_distance * 1.2
@export var unload_distance: float = 0.0

# [INF] 视点相关（P2-1 迁出）
## LOD 层级数（含 LOD0）：1=仅全精度（默认，等价旧版 lod0_distance=0 关闭 LOD）；
## 2=LOD0+LOD1(2×)；3=+LOD2(4×)；4=+LOD3(8×)…
## 各层自动按 view_distance 等比（×2）分带：LOD_i 外半径 = view_distance / 2^(lod_count-1-i)。
@export_range(1, 8, 1) var lod_count: int = 1:
	set(v):
		lod_count = clampi(v, 1, 8)
		_configure_lod()
		notify_property_list_changed()

# [INF] 视点相关（P2-1 迁出）
## 可见性检查间隔（帧）：视锥/流式统一每隔 N 帧检查一次相机位置。
## 值越大 CPU 开销越低，但进入视锥/加载距离后的补建响应越慢。
@export_range(1, 120) var visibility_check_interval: int = 8

# ── LOD 网格账本（渲染层）────────────────────────────────────────────────────
## 各 LOD 层渲染网格：_lod_meshes[lod] = {block_key: MeshInstance3D}。
## index 直接 = LOD 层级：0 = 全精度 chunk（level 0 block key == chunk key），>=1 = 粗层大块。
## 值为 null = "空标记"（该大块确定无体素，无限层据此停止重复派发）。
## 【为什么这套账本留在内核】见 VoxelInfiniteLayer 类注释"为什么网格账本留在内核"：
## remove_chunk_mesh / _update_chunk_collision / has_chunk_mesh / shift_render 都要读它，
## demo 与测试的 HUD 也直接读它统计 chunk 数；搬进无限层即构成反向依赖。
var _lod_meshes: Array[Dictionary] = []

# LOD 大块（godot_voxel 风格大 block）：GRID³ 大格，每格 = 2^level 体素。
#   level 0 = chunk（GRID = CHUNK_SIZE = 32，block key == chunk key）
#   level i = 大块覆盖 (32×2^i)³ 体素，block key = chunk key >> i
# 一次生成整个大块 mesh（原生 32³ 网格核心 generate_chunk_dense / generate_lod1_block_dense）。
# 几何数学（block 划分 / 层边长 / 中心距 / 滞回 / 预生成 / 分带）的唯一实现在 VoxelLodGrid；
# 分带调度（枚举 / 供需 / 可见性兜底）在无限层，本类只留节点挂载需要的层边长。
const LOD_GRID := VoxelLodGrid.GRID


## 见 VoxelLodGrid.block_edge_world（本类挂载节点与 origin shift 需要层边长）
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, voxel_scale)


# ── LOD 调度旋钮（配置留节点，逻辑归无限层）──────────────────────────────────
# 【为什么这些 @export 不随调度搬进无限层】`@export` 只能挂 Node / Resource，无限层是
# RefCounted（不进场景树、不序列化）。搬过去 = 用户从此在 Inspector 里看不到、也存不进场景，
# 对一个插件是把"可调"变成"要改代码"。故只搬状态与逻辑，配置留在节点由无限层读取。
## 每帧最多派发/挂载的粗 LOD 网格数（硬上限；mesh 由工作线程构建，挂载仅赋值，可适当调大）
@export_range(1, 400, 1) var _lod_build_per_frame: int = 128

## 粗层预生成提前量（block 数）：把粗层 block 的生成范围向外扩展，
## 让它们在进入 LOD 带之前就生成好——相机跨带时新层级已就绪，
## 消除"旧层已移除、新层异步生成中"的真空窗口（移动中闪现空洞）。
## 0 = 关闭（只在进入带后才生成）；建议 1~3（越大越无感，预加载 ring 常驻量略增）。
@export_range(0, 6, 1) var _lod_preload_blocks: int = 1

## LOD1 生成每帧时间预算（毫秒）：超过即停止本帧生成，平滑移动时主线程峰值
@export_range(0.1, 50.0, 0.1) var _lod_build_budget_ms: float = 8.0

# 共享的后台数据生成提交预算：数量硬上限 _lod_submit_per_frame（防单帧洪峰打爆 WorkerThreadPool）。
# 数量足够大 → 近层提交完自然让位更远层（不饿死，各 LOD 层都能提交）。
@export_range(1, 500, 1) var _lod_submit_per_frame: int = 200


## 重新计算 LOD 分带并调整各层存储（lod_count/view_distance 变化时调用）。
## LOD_i 外半径 = view_distance / 2^(lod_count-1-i)（等比 ×2，对齐 Voxel Tools 标准做法）。
func _configure_lod() -> void:
	# 分带计算 + 各层容器长度对齐都归无限层：它持 4 张调度表、本类持网格账本 `_lod_meshes`，
	# 长度由它唯一驱动（见 VoxelInfiniteLayer.configure_lod），避免两边各自 resize 后悄悄错位。
	infinite_layer.configure_lod(lod_count, view_distance)
	if data:
		data.lod_count = lod_count
		if lod_count <= 1:
			data.clear_lod_cache()
	request_update()


## 对齐本类网格账本 `_lod_meshes` 的层数（由无限层的 configure_lod 驱动）。
## 缩减时先释放被裁层的网格节点；扩充时补空的层容器。
func set_lod_level_count(n: int) -> void:
	while _lod_meshes.size() > n:
		clear_lod_level(_lod_meshes.size() - 1)
		_lod_meshes.pop_back()
	while _lod_meshes.size() < n:
		_lod_meshes.append({})
	# 材质对齐数组随层数同步（唯一缓存在 _materials 内，不再逐层单独维护）
	_materials.set_level_count(n)


## 释放指定 LOD 层级的全部网格节点（粗层的调度账本归无限层，由它自己 pop 掉）
func clear_lod_level(level: int) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	for bk in _lod_meshes[level]:
		var mi = _lod_meshes[level][bk]
		if mi != null and is_instance_valid(mi):
			mi.queue_free()
	_lod_meshes[level].clear()

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		request_update()
		notify_property_list_changed()

## 是否在编辑器中也实时更新 (仅 @tool 模式)
@export var update_in_editor: bool = true

## 诊断模式开关：开启后在输出面板打印详细的网格重建日志，用于定位性能瓶颈
## 关闭（默认）时仅在单次重建超时阈值（如单 chunk 生成 >5ms）时才打印，避免刷屏
@export var diag_enabled: bool = false

var _dirty: bool = false
## 材质唯一缓存：快照 / 运行时材质 / 各层对齐数组三份派生都在它内部，失效只有 invalidate() 一个入口
var _materials := VoxelMaterialCache.new()
var _update_counter: int = 0

# 流式卸载每帧限量：相机移动跨越边界时分批进行，避免一次 queue_free 大量节点
# 造成掉帧。卸载只释放资源+写盘（便宜），限量可稍大。
# [INF] 视点相关（P2-1 迁出）
@export_range(1, 200, 1) var _stream_unload_per_frame: int = 24
# 流式加载每帧限量：走近时优先补建最近的 chunk（磁盘读回 + 入异步重建）。
# 加载标脏后由 WorkerThreadPool 异步生成 + _process_mesh_build_queue 帧尾限量构建
# （GPU 上传限流 8 个/帧 + 3ms 预算），因此标脏量可适当放大：走近时每帧进入
# 管线的新块多，但实际 mesh 出现仍由 GPU 限流平滑分摊，不会掉帧也不会"一帧一块"。
# [INF] 视点相关（P2-1 迁出）
@export_range(1, 200, 1) var _stream_load_per_frame: int = 32
# 统一流式异步请求的在途状态不再本地留存：账本唯一在 VoxelAsyncLoader。
# 查询走 VoxelData.is_chunk_pending() / 列举 get_unready_chunk_keys() / 取消 cancel_chunk_request()。
# 当前渲染扇出批次：同时持有"任务计数"与"只读快照句柄"，结算点唯一（见 VoxelMeshBatch）。
# 任务计数与快照不再各自散落维护——旧实现里结果处理的两条早退路径各减一次计数，
# 导致计数提前归零、快照在 worker 仍在读时被释放，COW 写保护被击穿。
var _batch: VoxelMeshBatch = null
var _exiting := false                    # 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据
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
# 每帧最多构建的 chunk 数（GPU 上传限流）
# 流式补建直接入此队列，单 chunk 构建成本低（~1ms），提高后补建更流畅；
# 配合 3ms 时间预算 + GPU 忙检测兜底防 Metal fence 超时
@export_range(1, 100, 1) var _mesh_build_per_frame: int = 12
# 增量重建每帧最多处理的 dirty chunk 数：超出放回下帧续建（防回原点/大崩塌单帧
# 快照+派发上千 worker 阻塞主线程）。值越大重建越快但帧尖峰风险越高。
# 默认按 CHUNK_VOLUME 等比缩放：64 是 16³（4096 体素）时代调的值；32³ 单个 halo
# 快照约 2~4ms，64 个/帧 ≈ 主线程 130~200ms → 等比换算 16³的64 ≈ 32³的8。
# 数量之外另有毫秒预算双保险（_snapshot_budgeted）。
@export_range(8, 512, 8) var _rebuild_batch_limit: int = 64 * 4096 / VoxelChunk.CHUNK_VOLUME

# 帧尾构建是否已排期（防重复 call_deferred）
var _mesh_build_scheduled: bool = false
# 上一帧 _delta（秒），GPU 忙检测用（帧耗时大 = GPU/渲染压力高）
var _last_frame_delta: float = 0.0

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

## 记录一次性能统计采样（轻量级，仅累加数值，不维护数组）。
## apply_time_ms 由调用方传入**实测值**；此前这里被以 `last_apply_time_ms` 自身为实参调用，
## 于是该字段永远是"把自己的旧值赋给自己"（恒为 0），而 demo 会读它做展示。
func _record_perf_stats(chunk_count: int, gen_time_ms: float, apply_time_ms: float) -> void:
	last_rebuild_chunk_count = chunk_count
	last_mesh_gen_time_slice_ms = gen_time_ms
	last_apply_time_ms = apply_time_ms
	
	var stats := perf_stats
	stats["total_gen_time"] = stats["total_gen_time"] as float + gen_time_ms
	stats["total_apply_time"] = stats["total_apply_time"] as float + apply_time_ms
	stats["sample_count"] = stats["sample_count"] as int + 1


func _ready() -> void:
	_configure_lod()
	request_update()
	# GPU 忙检测统一用帧时长（_last_frame_delta）：viewport_set_measure_render_time
	# 在部分驱动(如 Metal)上可能引发不稳定，故不启用引擎侧的 render time 测量。
	# 流式加载启用判定：visibility_mode == STREAMING 即启用（unload 默认见 infinite_layer.unload_d()）
	infinite_layer.set_visibility_mode(visibility_mode)


func _process(_delta: float) -> void:
	# 记录上一帧耗时，供 GPU 忙检测使用（_process_mesh_build_queue）
	_last_frame_delta = _delta
	# 异步任务结果由 VoxelMeshBatch 回传（批次结算时才释放快照），此处无需轮询
	# 这里只处理限流和启动新任务

	# 可见性管理（每帧限量执行，走近/远离平滑）：
	#  - 视锥补建：每帧限量（infinite_layer.process_deferred_chunks 内限量）
	#  - 流式卸载/补建：每帧限量（按距离排序：远先卸载 / 近先加载）
	# 异步批次在跑时也可执行：卸载改数据层不影响 worker 快照（深拷贝）；
	# 补建标脏会在批次完成后统一重建（retrigger），不会丢失。
	if visibility_mode != VisibilityMode.FULL:
		infinite_layer.process_deferred_chunks()
	# 统一流式/程序化驱动：程序化无限世界总是按距离生成（不依赖 visibility_mode——
	# 无限世界只能按距离生成，设 FULL/FRUSTUM 若不走流式会导致数据永不生成 → 画面空白）；
	# 磁盘文件流仅在 STREAMING 模式启用加载/卸载。
	if infinite_layer.streaming_enabled or (data and data.generator != null):
		infinite_layer.process_streaming()
	# LOD 管理：每 interval 帧限量生成/移除（降低每帧遍历开销，近处 LOD0 / 远处各粗层互补）。
	# 降频与"数据变化立即处理"的判定都在无限层内部（它持有 _cull_check_counter）。
	infinite_layer.process_lod()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	# call_deferred 确保在帧末尾执行（本帧渲染已提交），且队列处理不阻塞主循环
	if not _mesh_build_queue.is_empty() and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	# 粗 LOD 大块 mesh 挂载同样帧尾限量（大块 build_mesh_from_arrays 覆盖数十万体素，GPU 上传昂贵）
	# 队列与排期标记都归无限层，本类只负责把 deferred 挂在自己身上。
	if infinite_layer.take_lod_mesh_flush_request():
		call_deferred("_flush_lod_mesh_apply_queue")

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

	# 若有尚未完成的批次，不启动新批次：批次的脏体素在其派发时已被清除，
	# 若此时覆盖 _batch，上一批的结果会因"批次身份不符"被丢弃，这些 chunk 的重建
	# 将永久丢失 → 界面残留被破坏面的"幽灵面"。
	# 改为置位 retrigger，等当前批次完成后在 _on_batch_complete 中重新触发，
	# 保证每个脏 chunk 最终都得到一次应用。
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return

	_update_mesh()


func _on_data_changed() -> void:
	request_update()


func request_update() -> void:
	_dirty = true


## 标记为脏，下一帧自动更新 (若 auto_update=true)
func mark_dirty() -> void:
	request_update()


## 立即强制重新生成 mesh
## 若仍有异步任务在运行，不直接启动新批次（否则 _update_mesh_async 会在 worker
## 读取共享切片时再次修改切片缓存 → 数据竞态），而是置位 retrigger，等当前批次
## 完成后由 _on_batch_complete 自动触发重建，保证共享切片引用安全。
func force_update() -> void:
	_dirty = true
	if _batch != null and _batch.is_active():
		_pending_retrigger = true
		return
	_dirty = false
	_update_mesh()


## 强制重新生成纹理材质 (材质属性变化时调用)
func regenerate_materials() -> void:
	# 三份派生一起作废。粗层用的是"按 ID 对齐后的材质快照"，漏作废它的话，已失效重建的
	# 粗层 block 会先用旧对齐材质建网格（新材质只在后续 to_build 路径才刷新）→ 颜色不更新。
	_materials.invalidate()
	request_update()


## 获取当前体素数据
func get_data() -> VoxelData:
	return data


## 当前渲染相机（未入树 / 无相机时为 null）。统一入口，替代各处重复的 is_inside_tree 判定。
func current_camera() -> Camera3D:
	return get_viewport().get_camera_3d() if is_inside_tree() else null


## LOD0 chunk 是否已有渲染网格（网格账本 _lod_meshes[0] 的唯一查询入口）。
func has_chunk_mesh(ck: Vector3i) -> bool:
	return not _lod_meshes.is_empty() and _lod_meshes[0].has(ck)


## LOD 层数（含 LOD0），= 网格账本 `_lod_meshes` 的长度。
## 长度由无限层 configure_lod 驱动（它持 4 张调度表，长度唯一维护点在那里）。
func lod_level_count() -> int:
	return _lod_meshes.size()


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
	# 粗层 worker 的任务 ID 与在途状态都在无限层，由它统一置停 + wait（必须在释放节点前）
	infinite_layer.abort()
	_clear_lod_meshes()


# [INF] 视点相关（P2-1 迁出）
## 取消尚未完成的异步网格生成任务。
## 批次自己负责结算：cancel() 释放只读快照并停止发射结果，wait_tasks() 保证 worker
## 在节点释放前全部结束（否则其 call_deferred 会打到已释放实例）。
func _cancel_async() -> void:
	# 【必须先取局部引用】Signal 的 emit 是**同步**的：cancel() 内部 _finish() 会 emit
	# finished，进而同步回调 _on_batch_finished 把 _batch 置空。若之后仍用 `_batch.xxx`，
	# 就会在 null 上调用 → "Nonexistent function 'wait_tasks' in base 'Nil'"。
	# （只有"_exit_tree 时批次仍在途"才触发，故长期潜伏：正常游玩极少命中。）
	var batch := _batch
	if batch == null:
		return
	batch.cancel()
	batch.wait_tasks()
	_batch = null


func _update_mesh() -> void:
	_dirty = false
	if not data:
		_cancel_async()
		mesh = null
		_clear_lod_meshes()
		mesh_updated.emit()
		return

	# 纹理材质与材质快照都走唯一缓存（材质变化时需手动调用 regenerate_materials 作废）：
	# 快照只在作废后深拷贝一次，供异步子线程安全读取，体素变化不触发大对象拷贝。
	_materials.surfaces(data.materials)
	_materials.snapshot(data.materials)

	# 统一走异步生成（CHUNK_ASYNC 为唯一路径；同步渲染路径已移除简化）
	_update_mesh_async()



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


## origin shift 后平移**渲染层**：所有网格节点 key 平移 + 节点 position 更新 + 各类集合字典 key 平移。
## 由无限层在判定需要平移后调用（何时平移是视点逻辑，归无限层；平移哪些账本是内核私有状态）。
## 【为什么整体平移而不让无限层逐个来改】下面 10+ 个字典全是内核私有渲染层状态，
## 逐个开访问器等于把内核内部结构泄漏出去；一个整体入口反而是更窄的接口。
func shift_render(shift: Vector3i, chunk_size_world: float) -> void:
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
	# 各类 chunk/block 集合字典 key 整体平移（统一实现见 VoxelChunk.shift_key_dict；
	# 其中 typed dict 需 typed 构建，故就地累加）。延迟队列 / 强制标记 / 粗层调度账本
	# 全归无限层，由它自行 shift_keys（内核不碰它的账本，见 VoxelInfiniteLayer.shift_keys）。
	_mesh_build_queue = VoxelChunk.shift_key_dict(_mesh_build_queue, shift)
	var ncr: Dictionary[Vector3i, bool] = {}
	for k in _collision_rebuild_queue:
		ncr[Vector3i(k) + shift] = true
	_collision_rebuild_queue = ncr
	# 碰撞体：键平移**且**节点位置/名字同步。只平移键会让 StaticBody3D 停留在旧世界坐标
	# （碰撞与视觉错位），而新键处又会重复建体 → 幽灵碰撞体。
	var ncc: Dictionary[Vector3i, StaticBody3D] = {}
	for k in _chunk_collisions:
		var nck2: Vector3i = Vector3i(k) + shift
		var body: StaticBody3D = _chunk_collisions[k]
		if body != null:
			body.position = Vector3(nck2) * chunk_size_world
			body.name = "Collision_%d_%d_%d" % [nck2.x, nck2.y, nck2.z]
		ncc[nck2] = body
	_chunk_collisions = ncc
	# 子类钩子：本类只平移**渲染层**状态。子类若持有体素坐标队列（破坏系统的待移除 /
	# 级联 / 待生成掉落体等），必须在此同步平移，否则在途操作会打到平移后的错位体素。
	on_origin_shift(shift)


## origin shift 完成后的子类钩子（默认空实现）。
## 只开一个定点钩子，而不让子类 override shift_render：后者要连带复制上面整套渲染层
## 平移逻辑（网格节点、碰撞体、各 block 级账本），漏一处就是幽灵节点/幽灵碰撞体。
func on_origin_shift(_shift: Vector3i) -> void:
	pass


# ----------------------------------------------------------------------------
# 多层级 LOD 渲染（lod_count 控制层级数，view_distance 自动等比 ×2 分带）
#   LOD0 全精度 chunk（level 0 block == chunk）；LOD i 大块每格 2^i 体素。
#   分带：LOD_i 显示区 = [outer[i-1], outer[i]]（outer[i] = view_distance / 2^(lod_count-1-i)）。
#   各层 block 生成/移除/可见性带滞回 margin，交界处内层未就绪时用外层兜底防空洞。
# ----------------------------------------------------------------------------



# ── LOD 网格账本 API（无限层经此读写）────────────────────────────────────────
# 账本 index 直接 = LOD 层级（0 = 全精度 chunk，>=1 = 粗层大块）。
# 有意只开"按键存取"的窄访问器，不暴露整表引用 —— 与既有的 has_chunk_mesh 同一风格，
# 既让无限层拿得到所需，又不把内核的私有结构泄漏出去（对比 shift_render 的整体入口）。

## 该层该 block 是否有条目（含"空标记"null —— 表示确定无体素、停止重复派发）
func has_lod_mesh(level: int, bk: Vector3i) -> bool:
	return level >= 0 and level < _lod_meshes.size() and _lod_meshes[level].has(bk)


## 取该层该 block 的网格节点；返回 null = 无条目或"空标记"（判定"是否已就绪"时两者同义）
func lod_mesh(level: int, bk: Vector3i) -> MeshInstance3D:
	if level < 0 or level >= _lod_meshes.size():
		return null
	return _lod_meshes[level].get(bk)


## 该层全部 block key 快照（无限层遍历用）。返回新数组，调用方在遍历中改动账本也安全。
func lod_mesh_keys(level: int) -> Array:
	if level < 0 or level >= _lod_meshes.size():
		return []
	return _lod_meshes[level].keys()


## 标记该 block"确定空"（无体素）：保留条目但置 null
func mark_lod_block_empty(level: int, bk: Vector3i) -> void:
	if level >= 0 and level < _lod_meshes.size():
		_lod_meshes[level][bk] = null


## 主线程挂载粗 LOD 大块网格（mesh 已由工作线程构建，此处仅建节点 + 赋材质 + 挂载，很轻）
## 失效重建时复用已有节点（直接替换 mesh，避免节点销毁/重建造成闪烁）
func mount_lod_mesh(level: int, bk: Vector3i, mesh: ArrayMesh) -> void:
	if level < 0 or level >= _lod_meshes.size():
		return
	var mi: MeshInstance3D = _lod_meshes[level].get(bk)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "LOD%dB_%d_%d_%d" % [level, bk.x, bk.y, bk.z]
		add_child(mi)
		mi.position = Vector3(bk) * _lod_block_edge_world(level)
	if mesh != null and mesh.get_surface_count() > 0:
		_apply_materials(mesh)
		mi.mesh = mesh
	_lod_meshes[level][bk] = mi


## 释放某层某 block 的网格节点并移除条目（粗层的调度账本归无限层，由它自己清）
## level 0（chunk）不走这里 —— LOD0 的移除是 remove_chunk_mesh（含碰撞与延迟队列，语义不同）
func clear_lod_mesh(level: int, bk: Vector3i) -> void:
	if level < 1 or level >= _lod_meshes.size():
		return
	var mi = _lod_meshes[level].get(bk)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[level].erase(bk)


## 该 chunk 是否在构建队列中（无限层判定"内层是否就绪"用）
func is_mesh_build_queued(ck: Vector3i) -> bool:
	return _mesh_build_queue.has(ck)


## 取（必要时重建）某 LOD 层的材质对齐数组：层级 → 体素材质 id 数组
## force=true 用于"材质或层数已变"的场景（内核在派发前与失效时调用）
func lod_materials(level: int, force: bool = false) -> Array:
	if data == null:
		return []
	if force:
		return _materials.rebuild_aligned(data.materials, level)
	return _materials.aligned(data.materials, level)


## 取渲染用的运行时 Material 对象数组（表面 0/1）。
## 走唯一材质缓存 `_materials`：源引用变化或 regenerate_materials 时自动作废，
## 故表现层（掉落块 mesh）与渲染层共用同一份 Material 对象，无需各自再建一份。
func surface_materials() -> Array:
	return _materials.surfaces(data.materials) if data else []




## 清除单个 chunk 的渲染网格（释放 mesh + 碰撞 + 相关队列条目）。两类调用场景：
##   · 数据层已变空但渲染层 mesh 残留：破坏/崩塌后 chunk 内体素全被移除（has_chunk=false），
##     增量重建时 infinite_layer.filter_visible_chunks 会跳过空 chunk 不派发 → 不主动清除则旧 mesh 残留
##     （视觉上"悬空块还在"，数据其实已掉）；
##   · 流式卸载：超出距离直接释放网格（重进范围由统一流式扫描按 can_supply_chunk 重新补建）。
## 【数据层不在此卸载】本函数只管渲染网格；数据层卸载由流式卸载段单独按更外扩的半径调
## VoxelData.unload_chunk()（见 VoxelInfiniteLayer.lod0_data_unload_d）——网格半径与数据半径分开，
## 是因为粗层降采样还需要比网格更远一圈的 LOD0 数据。
func remove_chunk_mesh(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _lod_meshes[0].get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod_meshes[0].erase(ck)
	_remove_chunk_collision(ck)
	_mesh_build_queue.erase(ck)
	# 该 chunk 的重建权随网格移除作废（否则延迟队列里残留"幽灵补建"条目）
	infinite_layer.on_mesh_removed(ck)


## 异步路径：后台线程生成网格数据，完成后通过 call_deferred 直接传递结果到主线程
## 主线程绝不阻塞：旧任务未完成时直接启动新任务覆盖，子线程完成后检查 gen_id 丢弃过期结果
func _update_mesh_async() -> void:
	# 若旧任务已完成但还未轮询应用（极端情况），不阻塞，直接启动新任务覆盖
	# 旧任务子线程完成后会因 gen_id 不匹配而不写入结果（自然丢弃）

	# 【密集光环快照方案】不为每个 chunk 提取字典切片，而是让 VoxelData 直接从其
	# dense chunk 缓冲构建 34³ 密集"光环"（chunk + 1 体素外缘，PackedInt32Array）。
	# 每个子线程只读取自己那个私有的光环快照；快照是独立字典，主线程后续对字典的
	# 增删不与之冲突。注意快照与活动缓冲**共享底层**：GDScript 的逐元素写不会触发
	# 写时拷贝，故批次在途期间用 VoxelData 的只读快照计数把单点写降级为显式拷贝
	# （见 begin_readonly_snapshot），杜绝数据竞态（块随机显示/隐藏的根因）。
	var rebuild_chunks: Array[Vector3i] = []
	# chunk 级脏标记（_mark_voxel_dirty 已含跨界面的边界邻居）：
	# 大崩塌移除不再主线程逐体素写 dict
	rebuild_chunks = data.get_dirty_chunks()
	var had_dirty := not rebuild_chunks.is_empty()
	# 【流式防抖】剔除已在延迟补建队列的脏 chunk：其重建权归无限层的延迟队列
	# （晋升时 process_deferred_chunks 重新 mark_chunk_dirty，且未来构建的快照必含
	# 已到达的邻居数据，无需边界缝合标记）。否则流式波次中每个新到 chunk 都把视锥外
	# 的延迟邻居重新标脏 → 每帧一轮"脏N→视锥内0→再延迟"空转：gen_id 无限递增、
	# 枚举+视锥判定每帧照付、永不收敛（STREAMING 大波次主线程卡顿的根源）。
	var dropped := 0
	if not infinite_layer.deferred_is_empty():
		for i in range(rebuild_chunks.size() - 1, -1, -1):
			if infinite_layer.is_deferred(rebuild_chunks[i]):
				rebuild_chunks.remove_at(i)
				dropped += 1
	if diag_enabled and dropped > 0:
		print("[诊断] 增量重建防抖: 剔除已在延迟队列的脏 chunk %d 个" % dropped)
	# 限量批次：超过上限的放回 dirty（下帧续建）。回原点/大崩塌时 dirty 可上千，
	# 单帧全量快照 + 派发上千 worker → 主线程阻塞（update_mesh 数百 ms → 帧率个位数）。
	# 分批后每帧快照/派发量受限，网格经 _process_mesh_build_queue 平滑上传。
	if rebuild_chunks.size() > _rebuild_batch_limit:
		for i in range(_rebuild_batch_limit, rebuild_chunks.size()):
			data.mark_chunk_dirty(rebuild_chunks[i])
		rebuild_chunks.resize(_rebuild_batch_limit)
		# 放回剩余 dirty 后必须重新置位：_update_mesh 开头会清 _dirty，
		# 若不重新 request_update，剩余 dirty 将永久卡住 → 初始构建/大批量
		# 重建只生成第一批，其余 chunk 网格缺失（破坏demo初始只显示一个小角落、
		# 流式demo脚底下不显示）。置位后下帧 _process 继续消费下一批。
		request_update()
	# 有脏标记但全部已在延迟队列 → 本帧无生产性工作：不递增 gen_id、不派发任务、
	# 不再触发下一帧（延迟队列晋升补建时自会标脏触发），杜绝空转轮次。
	if rebuild_chunks.is_empty() and had_dirty:
		return
	# 材质快照复用缓存（仅在材质变化时深拷贝），避免每帧大对象深拷贝
	var snapshot_materials := _materials.snapshot(data.materials)
	# 一次对齐材质供所有 per-chunk worker 复用，避免每个任务重复 align_by_id
	# （生成器内部要求"数组索引==材质ID"，对齐后可 O(1) 按 ID 取材质）
	var aligned_materials := VoxelMaterial.align_by_id(snapshot_materials)
	# 透明标志表按批次算一次（逐块重建要扫一遍材质表，批量重建时纯属重复劳动）
	var trans_flags := VoxelMaterial.build_trans_flags(aligned_materials)
	# 渲染居中偏移（体素单位），子线程无权访问节点，随任务参数传入
	var render_offset: Vector3 = data.center_offset if data else Vector3.ZERO

	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	# 将 voxel_scale 等渲染参数作为任务参数传入，避免子线程访问节点属性
	#
	# 每个脏 chunk 独立一个线程任务，WorkerThreadPool 内部管理并发数
	# per-chunk 异步生成（唯一网格路径）
	# 可见性决策：全量走所有 chunk；增量先清除"已变空"chunk 的残留 mesh 再决策。
	# 两分支决策不同，但下方"快照预算 + 派发"完全一致，合并到一处。
	var visible: Array[Vector3i]
	if rebuild_chunks.is_empty():
		# 全量构建（初始构建或切换模式后）：分 chunk 独立线程，逐个显示
		var all_chunks := data.get_all_chunk_keys()
		if all_chunks.is_empty():
			# 空场景：无 chunk 可生成，直接返回（无任务，pending 保持 0）
			return
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		visible = infinite_layer.filter_visible_chunks(all_chunks)
		if diag_enabled:
			print("[诊断] 全量构建: 总%d Chunk, 视锥内%d, 延迟%d" % [all_chunks.size(), visible.size(), all_chunks.size() - visible.size()])
	else:
		# 增量重建：每个 chunk 独立一个线程任务，真正并行处理
		# 【关键】先清除"已变空"chunk 的残留 mesh：破坏/崩塌后 chunk 内体素
		# 全被移除（has_chunk=false），而 infinite_layer.filter_visible_chunks 会跳过空 chunk
		# 不派发重建 → 若不主动清除，旧 mesh 残留，视觉上"悬空块还在"（数据其实已掉）。
		for ck in rebuild_chunks:
			if _lod_meshes[0].has(ck) and not data.has_chunk(ck):
				remove_chunk_mesh(ck)
		# 统一可见性决策（流式距离 + 视锥/近处全向）
		visible = infinite_layer.filter_visible_chunks(rebuild_chunks)
		if diag_enabled:
			print("[诊断] 增量重建: 脏%d Chunk, 视锥内%d, 延迟%d" % [rebuild_chunks.size(), visible.size(), rebuild_chunks.size() - visible.size()])
	# 本帧渲染批次：任务计数与只读快照句柄都由它持有，结算点唯一（见 VoxelMeshBatch）。
	# 结果处理里任何提前 return 都不可能再让计数失衡——这正是"双重递减击穿 COW"的根治。
	var batch := VoxelMeshBatch.new()
	batch.result_ready.connect(_on_batch_result.bind(batch))
	batch.finished.connect(_on_batch_finished.bind(batch))
	_batch = batch
	# 快照预算：超预算尾部放回 dirty 下帧续建（_update_mesh 开头清 _dirty，须重置位），
	# 避免初始/切换模式一帧全量快照尖峰。
	# 声明"只读快照"：快照与活动缓冲共享底层，而 GDScript 的逐元素写不会触发写时拷贝，
	# 故本批次在途期间主线程的单点写必须先在目标缓冲上分叉（见 VoxelData.begin_readonly_snapshot）。
	# 句柄交给批次，由它在结算（完成 / 取消）时唯一一次释放。
	if data and not visible.is_empty():
		batch.attach_snapshot(data.begin_readonly_snapshot())
	var snap := _snapshot_budgeted(visible)
	var snapshot: Dictionary = snap["snapshot"]
	var taken: int = snap["taken"]
	if taken < visible.size():
		for j in range(taken, visible.size()):
			data.mark_chunk_dirty(visible[j])
		request_update()
		visible.resize(taken)
	# 【为什么先捕获成局部】worker 在子线程执行，约定是"只读参数、不碰节点属性"。
	# voxel_scale / render_offset / diag_enabled 原先是在 lambda 里直接读节点属性，
	# 属于违反约定（虽然读一个 float 实际不会崩，但会被后续改动踩成真竞态）。
	# lambda 按值捕获局部变量，跨线程安全。
	var w_scale := voxel_scale
	var w_offset := render_offset
	var w_diag := diag_enabled
	for ck in visible:
		# 【必须用 lambda 显式绑定 out 的位置】Godot 4 的 Callable.bind() 把绑定实参放在
		# call() 实参**之后**，所以 `_generate_chunk_worker.bind(args...).call(out)` 会让 out
		# 落到第 1 个形参上、其余参数整体错位（曾因此报 "Cannot convert argument 2 from
		# Dictionary to Array"）。旧代码用 add_task(bind(...)) 时没有额外实参，故掩盖了这一点。
		# 下面的 lambda 只有一个自由形参 out，与 VoxelMeshBatch._wrap 的调用方式严格对应。
		batch.spawn(func(out: Dictionary) -> void:
			_generate_chunk_worker(snapshot, aligned_materials, trans_flags, ck,
				w_scale, w_offset, w_diag, out))
	# 一个任务都没派发出去时必须立即结算：否则 _batch 永远"在途"，会挡住后续所有更新
	# （旧实现用裸计数 0 天然表示"无在途"，换成对象后要显式结清）。
	batch.settle_if_idle()


## 可见 chunk halo 快照的每帧毫秒预算：常规 6ms；可见集超过 _rebuild_batch_limit 时放宽到 10ms
const _SNAPSHOT_BUDGET_MS := 6.0
const _SNAPSHOT_BUDGET_MS_LARGE := 10.0


## 可见 chunk 的 halo 快照（毫秒预算版）：逐片快照、超预算即止。
## 原生 snapshot_chunks_halo 会自动外扩 27 邻居，故切片不产生边界洞。
## 实测单 chunk 约 0.31ms（带流、邻居从盘重载），整批远小于预算。
## 返回 {snapshot: Dictionary(ck -> 缓冲), taken: int}；未快照尾部由调用方放回 dirty。
func _snapshot_budgeted(visible: Array[Vector3i]) -> Dictionary:
	var budget_ms := _SNAPSHOT_BUDGET_MS
	if visible.size() > _rebuild_batch_limit:
		budget_ms = _SNAPSHOT_BUDGET_MS_LARGE
	var t0 := Time.get_ticks_usec()
	var snapshot: Dictionary = {}
	var taken := 0
	while taken < visible.size():
		var endi := mini(taken + 4, visible.size())
		snapshot.merge(data.snapshot_chunks_halo(visible.slice(taken, endi)))
		taken = endi
		if taken < visible.size() and (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
	return {snapshot = snapshot, taken = taken}


## 统一工作线程结果字典契约（#6）：全量/增量/单chunk/空场景所有生成路径
## 都通过 _make_result 构建结果，消费方 _apply_single_chunk_result 统一按键读取。
## chunk_key 缺省为 (-999,-999,-999) 表示"非单chunk结果"（全量结果）。
## 不含 gen_id：过期判定已由 VoxelMeshBatch 的对象身份承担（取消即不再发射结果）。
static func _make_result(arrays: Variant, gen_time_ms: float, solid_vertices: int,
		trans_vertices: int, total_chunks: int, affected_count: int,
		chunk_key: Vector3i = Vector3i(-999, -999, -999)) -> Dictionary:
	return {
		"arrays": arrays,
		"chunk_key": chunk_key,
		"gen_time_ms": gen_time_ms,
		"solid_vertices": solid_vertices,
		"trans_vertices": trans_vertices,
		"total_chunks": total_chunks,
		"affected_count": affected_count,
	}


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
## 每个 chunk 独立生成网格数据，结果由 VoxelMeshBatch 统一回传并结算
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
## buffers 为主线程派发时一次性构建的"受影响区域"chunk 缓冲快照（深拷贝字典），
## worker 在子线程内据此构建自己的 18³ halo（纯只读，无数据竞态），
## 避免主线程逐 chunk 提取 halo 造成秒级阻塞（旧方案）。
## materials 参数为已按 ID 对齐的材质数组（主线程派发时一次对齐，worker 复用避免重复开销）
## diag_enabled 由主线程派发时捕获传入，子线程只读参数，避免跨线程访问节点属性
func _generate_chunk_worker(buffers: Dictionary, materials: Array, trans_flags: PackedByteArray,
		chunk_key: Vector3i, scale: float, offset: Vector3 = Vector3.ZERO,
		diag_enabled: bool = false, out: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_usec()
	var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, chunk_key)
	var arr := VoxelChunkGenerator.generate_single_chunk_dense(
			halo, materials, scale, chunk_key, offset, trans_flags)
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
	# 结果写进 out（由 VoxelMeshBatch 传入）：回传与计数结算都由批次负责。
	# 本函数不再自己 call_deferred —— 那会让"结果回传"与"计数递减"分处两地，
	# 正是旧实现计数失衡的来源。
	out.merge(_make_result(arrays, gen_time_ms, sv, tv, 1 if has_data else 0, 1, chunk_key))


## 主线程结果处理入口（由 VoxelMeshBatch 在主线程发射）。
## **本函数不碰计数**：结算在批次内部唯一一处完成，故这里的任何提前 return
## 都不可能让批次失衡（旧实现正是在这里与两条早退路径各减一次 → 双重递减）。
## batch 由信号 bind 传入：batch != _batch 即说明已被换批 / 取消，结果过期。
## 收尾仍延迟到下一帧（_on_batch_finished 置 _batch_complete_pending），
## 避免"最后一个任务完成"瞬间在主线程做重活造成帧尖峰（曾观测到 83ms）。
func _on_batch_result(result: Dictionary, batch: VoxelMeshBatch) -> void:
	if batch != _batch or _exiting:
		return
	var _diag_t0 := Time.get_ticks_usec()
	
	# 应用结果
	_apply_single_chunk_result(result)
	
	# 计数不在此处递减：结算点在 VoxelMeshBatch 内部唯一一处。
	var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	if diag_enabled and _t_ms > 0.5:
		print("[诊断] _on_batch_result: 剩余%d任务, 应用耗时%.2f ms" % [batch.pending_count(), _t_ms])


## 批次结算（全部完成 / 被取消）：只读快照已由批次释放。
## 仅"真的派发过任务"的批次才置收尾标志 —— 空批次等价于旧实现的裸计数 0，不做任何收尾。
func _on_batch_finished(batch: VoxelMeshBatch) -> void:
	if batch != _batch:
		return
	_batch = null
	if batch.has_dispatched():
		_batch_complete_pending = true


## 应用单个 chunk 的异步结果（在主线程 _process 中调用）
## 结果恒为单 chunk（per-chunk 生成），直接更新对应子 MeshInstance3D
func _apply_single_chunk_result(result: Dictionary) -> void:
	var _diag_t0 := Time.get_ticks_usec()
	var _t_get_chunk := 0.0
	var arrays = result.get("arrays", {})
	var chunk_key: Vector3i = result.get("chunk_key", Vector3i(-999, -999, -999))
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
		var cam_now := current_camera()
		if _is_chunk_beyond_unload(
				chunk_key, cam_now, voxel_scale * VoxelChunk.CHUNK_SIZE, global_position, infinite_layer.unload_d()):
			# 丢弃过期结果：计数由 VoxelMeshBatch 统一结算，这里直接返回即可
			return
		var arr = arrays.get(chunk_key, {})
		var has_voxels_in_data := false
		if data:
			var _t1 := Time.get_ticks_usec()
			has_voxels_in_data = data.has_chunk(chunk_key)
			_t_get_chunk = (Time.get_ticks_usec() - _t1) / 1000.0
		# 程序化生成：数据已被 LOD1 区释放（超 LOD0 区、由 LOD1 覆盖）→ 该异步结果过期丢弃。
		# 否则释放后异步 mesh 结果回来仍建网格 → 地块"显示→消失→再显示"闪烁。
		if data and data.generator != null and not has_voxels_in_data:
			# 同上：结果过期丢弃，不碰计数
			return

		# 入队待构建（GPU 上传限流，_process 每帧批量处理）
		# 避免连续破坏时一帧大量 ArrayMesh 创建 + GPU 上传 → Metal fence 超时
		_mesh_build_queue[chunk_key] = {
			"arrays": arr if (arr is Dictionary and not arr.is_empty() and has_voxels_in_data) else {},
			"has_voxels": has_voxels_in_data,
		}
		_record_perf_stats(1, gen_time_ms, _t_get_chunk)

	# 诊断：单 chunk 应用耗时 > 1ms 时打印（顺带把实测应用耗时写进公开统计字段）
	var _t_apply_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	last_apply_time_ms = _t_apply_ms
	if diag_enabled and _t_apply_ms > 1.0 and chunk_key.x != -999:
		print("[诊断] _apply_single_chunk_result: Chunk%s, get_chunk=%.2fms, 总=%.2fms" % [chunk_key, _t_get_chunk, _t_apply_ms])


# GPU 上传限流（批量构建队列）
# 用 call_deferred 在帧尾执行，避开渲染循环内的 GPU 竞争；每帧限量构建。

## mesh 组装（同步 GPU 上传）的每帧时间预算与数量上限：常规 3ms / _mesh_build_per_frame；
## 大量破坏（脏 chunk 多于 _mesh_build_per_frame）时放宽到 8ms / 24，降低 mesh 更新延迟感。
const _MESH_BUILD_BUDGET_MS := 3.0
const _MESH_BUILD_BUDGET_MS_BURST := 8.0
const _MESH_BUILD_BURST_COUNT := 24


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
	var budget_ms := _MESH_BUILD_BUDGET_MS
	if data and data.get_dirty_mesh_chunk_count() > _mesh_build_per_frame:
		budget_n = maxi(budget_n, _MESH_BUILD_BURST_COUNT)
		budget_ms = _MESH_BUILD_BUDGET_MS_BURST
	# 优先处理已有 mesh 的 chunk（保证破坏面及时更新），再处理新 chunk。
	# 用"分组两趟"而非自定义比较器："已有优先"不构成严格弱序，sort_custom 要求合法比较器。
	var pending_keys := _mesh_build_queue.keys()
	var keys: Array = []
	for ck in pending_keys:
		if _lod_meshes[0].has(ck):
			keys.append(ck)
	for ck in pending_keys:
		if not _lod_meshes[0].has(ck):
			keys.append(ck)
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
	# 剩余留待下帧：由 _process 每帧检测非空后调度（一帧至多一次）。
	# 【不能】在此 call_deferred 自续调度——MessageQueue.flush 会把 flush 期间新推入的
	# 调用在同帧继续执行，自续 = 同帧反复进本函数（每次 budget 个/3ms 直至清空积压），
	# 流式波次期几十个 worker 结果回主线程时整队一帧打穿，数量+毫秒限流双双失效。
	if diag_enabled and built > 0:
		print("[诊断] GPU上传批处理: %d chunk, 耗时%.2f ms, 剩余%d" % [
			built, (Time.get_ticks_usec() - t0) / 1000.0, _mesh_build_queue.size()])


## 帧尾挂载粗 LOD 大块 mesh（转发给无限层）。
## deferred 目标必须是本节点：节点被释放时引擎会自动丢弃排期，而 RefCounted 的无限层
## 不享受这层保护（其内部另有 _exiting 标记兜底）。
func _flush_lod_mesh_apply_queue() -> void:
	infinite_layer.process_lod_mesh_apply_queue()


## 给 ArrayMesh 的两个表面赋材质（实心/透明）。chunk/LOD1/碎片应用统一走此辅助。
func _apply_materials(new_mesh: ArrayMesh) -> void:
	var mats := _materials.surfaces(data.materials) if data else []
	if new_mesh and mats.size() >= 2:
		if new_mesh.get_surface_count() > 0 and mats[0]:
			new_mesh.surface_set_material(0, mats[0])
		if new_mesh.get_surface_count() > 1 and mats[1]:
			new_mesh.surface_set_material(1, mats[1])


## 应用单个待构建 chunk（构建 mesh + 挂载节点 + 更新碰撞）
func _apply_built_chunk(chunk_key: Vector3i, entry: Dictionary) -> void:
	# 带外校验：破坏/编辑不应让超出 LOD0 带的 chunk 临时挂载（否则粗层区破坏时
	# LOD0 细网格"闪现"后被移除 → 与粗层交替闪烁）。粗层区破坏由粗层 mesh 反映，
	# LOD0 chunk 只挂载带内；此处与 _process_chunk_level 的移除判定保持一致。
	var cam := current_camera()
	# 显式标注：内核 ↔ 无限层互持引用（类型环），此处 `:=` 推导会失败。
	var lod_outer: Array[float] = infinite_layer.lod_outer()
	if cam and not lod_outer.is_empty():
		var lod0_d: float = lod_outer[0]
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
	# 只读快照已由 VoxelMeshBatch 在结算时释放，此处无需再配对释放。
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


## 清理所有 chunk 子 MeshInstance3D 及关联碰撞体
## 分工：粗层的调度账本（待办 / 重建 / 代次 / 重试 / 挂载队列 / 延迟队列）归无限层，
## 由它一并清空；本类只清自己的网格账本、构建队列与材质对齐缓存。
func _clear_lod_meshes() -> void:
	infinite_layer.clear_lod_state()
	_mesh_build_queue.clear()
	_materials.invalidate_aligned()
	# 清理所有 LOD 层网格（LOD0 chunk + 各粗层大块；null 表示空大块标记，跳过）
	for level in _lod_meshes.size():
		for bk in _lod_meshes[level]:
			var mi: MeshInstance3D = _lod_meshes[level][bk]
			if mi != null and is_instance_valid(mi):
				mi.queue_free()
		_lod_meshes[level].clear()
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
