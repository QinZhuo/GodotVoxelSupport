@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器
## 持有 VoxelData，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)

signal mesh_updated

## 网格生成模式
enum MeshMode {
	GLOBAL_MESH,  ## 所有体素合并为一个 ArrayMesh（适合中小场景，变更时全量重建）
	CHUNK_SYNC,   ## 逐 chunk 网格，主线程同步生成（体素变化只重建受影响 chunk）
	CHUNK_ASYNC,  ## 逐 chunk 网格，后台线程并行生成（推荐：主线程不阻塞，大型场景性能最佳）
}

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
		if data and data_stream:
			data.set_stream(data_stream)
		_materials_cache.clear()
		_materials_snapshot_dirty = true
		_clear_chunk_meshes()
		_request_update()

## 数据层磁盘流（VoxelStream / VoxelFileStream）。
## 设置后 STREAMING 模式不仅卸载网格，还按距离把 chunk 数据写回磁盘并释放内存
## （数据层磁盘流式）。卸载/补建由 _process_streaming 驱动（data.unload_chunk /
## data.preload_chunk），保证破坏/编辑/网格生成始终能看到磁盘上已持久化的数据。
## 也可直接配置 VoxelData.stream；此处提供节点级快捷入口。
@export var data_stream: VoxelStream:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储
		if data_stream == v:
			return
		data_stream = v
		if data:
			data.set_stream(v)

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		# Voxel scale 变化会影响 chunk mesh 的位置，需要重建
		if not _chunk_meshes.is_empty():
			_clear_chunk_meshes()
		_request_update()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
## 对大型动态场景(如水模拟)可显著降低重建频率，值越大越流畅但更新越滞后
@export_range(1, 30) var update_throttle_frames: int = 1

## 网格生成模式（统一 chunk 生成与异步调度）
## - GLOBAL_MESH：整块网格，变更全量重建（中小场景）
## - CHUNK_SYNC ：逐 chunk，主线程同步生成
## - CHUNK_ASYNC：逐 chunk，后台线程并行生成（推荐）
@export var mesh_mode: MeshMode = MeshMode.CHUNK_ASYNC:
	set(v):
		mesh_mode = v
		if v != MeshMode.CHUNK_ASYNC:
			_cancel_async()
		_clear_chunk_meshes()
		_request_update()

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
		if _streaming_enabled and unload_distance <= 0.0:
			unload_distance = view_distance * 1.5
		if v == VisibilityMode.FULL:
			_deferred_chunks.clear()
			# 全量模式下补建被卸载的网格
			for ck in _streamed_out_chunks.keys():
				_streamed_out_chunks.erase(ck)
				if data:
					data._mark_chunk_dirty(ck)
		_request_update()

## 可见性加载距离（世界单位）：FRUSTUM 时视锥外仍生成的半径；STREAMING 时网格加载半径
@export var view_distance: float = 40.0

## 流式卸载距离（世界单位，仅 STREAMING）：超过此距离的 chunk 网格被卸载释放
## 默认 0 = 自动取 view_distance * 1.5
@export var unload_distance: float = 0.0

## LOD0 距离（世界单位）：该距离内用全精度 16³ chunk，之外用 LOD1 低分辨率大块
## （每格代表 2³ 体素，顶点约为 1/8）。默认 0 = 不启用 LOD（全部全精度）。
## 启用时建议 < view_distance，LOD0 与 LOD1 在 [lod0, unload] 区间互补。
@export var lod0_distance: float = 0.0:
	set(v):
		lod0_distance = v
		if v <= 0.0:
			# 关闭 LOD：清理 LOD1 网格与缓存
			for bk in _lod1_meshes:
				_lod1_meshes[bk].queue_free()
			_lod1_meshes.clear()
			_lod1_pending.clear()
			if data:
				data.clear_lod1_cache()

## 可见性检查间隔（帧）：视锥/流式统一每隔 N 帧检查一次相机位置。
## 值越大 CPU 开销越低，但进入视锥/加载距离后的补建响应越慢。
@export_range(1, 120) var visibility_check_interval: int = 8

## LOD1 渲染：LOD1 block（key -> MeshInstance3D），距离在 [lod0, unload] 区间用低分辨率大块
var _lod1_meshes: Dictionary[Vector3i, MeshInstance3D] = {}
## LOD1 待生成的 block（key -> true），由 _process_lod 限量生成
var _lod1_pending: Dictionary = {}
## LOD1 异步生成：已派发待结果的 block（去重）
var _lod1_pending_tasks: Dictionary = {}
## LOD1 生成代数：数据变化（invalidate）时递增，丢弃旧任务过期结果
var _lod1_generation_id: int = 0
## 每帧一次对齐的 LOD1 材质（供所有 worker 复用）
var _aligned_lod1_materials: Array = []
## 每帧最多生成的 LOD1 网格数（硬上限）
var _lod1_build_per_frame: int = 3

# LOD1 大块（godot_voxel 风格大 block）：一次性生成 32³ 大格 = 4×4×4 LOD0 chunk = 64³ 体素。
# 大块 key = LOD0 chunk >> 2。一次生成整个大块 mesh（原生 generate_lod1_block_dense），
# 降低 draw calls，且无"小块生成后合并"的额外开销。
const LOD1_BLOCK_SHIFT := 2
const LOD1_BLOCK_EDGE := 16 << LOD1_BLOCK_SHIFT  # 64 体素
const LOD1_BLOCK_SIZE := LOD1_BLOCK_EDGE >> 1    # 32 大格

static func _lod1_block_of_chunk(ck: Vector3i) -> Vector3i:
	return Vector3i(
			ck.x >> LOD1_BLOCK_SHIFT,
			ck.y >> LOD1_BLOCK_SHIFT,
			ck.z >> LOD1_BLOCK_SHIFT)


static func _lod1_block_center(bk: Vector3i, world_offset: Vector3, block_edge_world: float) -> Vector3:
	return world_offset + Vector3(bk) * block_edge_world + Vector3.ONE * block_edge_world * 0.5
## LOD1 生成每帧时间预算（毫秒）：超过即停止本帧生成，平滑移动时主线程峰值
var _lod1_build_budget_ms: float = 6.0

## 流式加载：已卸载网格的 chunk（key → true），进入加载距离后补建
var _streamed_out_chunks: Dictionary[Vector3i, bool] = {}
## 是否已启用流式加载（visibility_mode == STREAMING）
var _streaming_enabled: bool = false
var _cull_check_counter: int = 0

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		_request_update()

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
var _stream_unload_per_frame: int = 24
# 流式检查降频：卸载/加载的"全量遍历所有 chunk + 排序"每帧做一次在大场景（数千
# chunk）下是固定 CPU 成本。卸载仅在相机移动越界时才有意义 → 每 12 帧检查一次；
# 加载（走近补建）需及时 → 每 4 帧检查一次。移动边界附近延迟 ≤0.2s，可接受。
var _streaming_check_tick: int = 0
const STREAM_UNLOAD_INTERVAL := 8
const STREAM_LOAD_INTERVAL := 2
# 流式加载每帧限量：走近时优先补建最近的 chunk（磁盘读回 + 入异步重建）。
# 加载标脏后由 WorkerThreadPool 异步生成 + _process_mesh_build_queue 帧尾限量构建
# （GPU 上传限流 8 个/帧 + 3ms 预算），因此标脏量可适当放大：走近时每帧进入
# 管线的新块多，但实际 mesh 出现仍由 GPU 限流平滑分摊，不会掉帧也不会"一帧一块"。
var _stream_load_per_frame: int = 24
# 流式补建待强制的 chunk：进入 load 距离后应无条件构建（距离驱动，非朝向驱动），
# 不被 _filter_frustum_chunks 延迟到 _deferred_chunks（否则补建 chunk 因不在视锥内
# 被挂起等待，造成"补建慢、每帧只重建几个"的瓶颈）
var _stream_force_build: Dictionary = {}
# 异步网格生成状态（多任务并行，每个任务独立处理）
var _task_ids: Array[int] = []           # 多个并行任务 ID（仅用于取消时等待）
var _pending_task_count: int = 0         # 未完成的任务数（用于限流和批次完成判断）
var _generation_id := 0
# 材质快照缓存：材质对象深拷贝较昂贵，仅在材质变化时重建一次，供子线程安全读取
var _materials_snapshot: Array = []
var _materials_snapshot_dirty: bool = true
# 异步任务运行期间收到新变更时置位，任务完成后重新触发更新（保证数据始终最新且不并发）
var _pending_retrigger: bool = false
# 批次全部完成待处理标志：置位后下一帧 _process 执行 _on_batch_complete（避免主线程尖峰）
var _batch_complete_pending: bool = false
# Per-chunk 模式：每个非空 chunk 对应一个子 MeshInstance3D
var _chunk_meshes: Dictionary[Vector3i, MeshInstance3D] = {}
# Per-chunk 碰撞体：每个 chunk 对应一个子 StaticBody3D
var _chunk_collisions: Dictionary[Vector3i, StaticBody3D] = {}
# 碰撞重建队列：破坏后延迟重建 ConcavePolygonShape3D，每帧限量，避免连续破坏主线程卡顿
var _collision_rebuild_queue: Dictionary[Vector3i, bool] = {}
# 每帧最多重建的碰撞体数
var _collision_rebuild_per_frame: int = 4

# GPU 上传限流队列：异步结果先缓存数组数据，_process 帧尾批量构建 mesh（平滑 GPU 上传，
# 避免连续破坏时一帧大量 ArrayMesh 创建导致 Metal fence 超时）
# key: chunk_key -> {arrays: Dictionary, has_voxels: bool}
var _mesh_build_queue: Dictionary = {}
# 每帧最多构建的 chunk 数（GPU 上传限流）
# 流式补建直接入此队列，单 chunk 构建成本低（~1ms），提高后补建更流畅；
# 配合 3ms 时间预算 + GPU 忙检测兜底防 Metal fence 超时
var _mesh_build_per_frame: int = 8
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
	_request_update()
	# 开启 viewport render time 测量，供 GPU 忙检测使用（_process_mesh_build_queue 用）
	# 注：viewport_set_measure_render_time 在部分驱动(如 Metal)上可能引发不稳定，
	# 已改用帧时长(_last_frame_delta)做 GPU 忙检测，此处仅保留标记不调用。
	_measure_render_time_enabled = false
	# 数据层磁盘流式：编辑器加载顺序不定，_ready 兜底把 stream 挂到 data
	if data and data_stream and data.stream != data_stream:
		data.set_stream(data_stream)
	# 流式加载启用判定：visibility_mode == STREAMING 即启用（unload 默认 = view*1.5）
	_streaming_enabled = visibility_mode == VisibilityMode.STREAMING
	if _streaming_enabled and unload_distance <= 0.0:
		unload_distance = view_distance * 1.5


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
	if _streaming_enabled:
		_process_streaming()
	# LOD1 低分辨率大块管理：每 interval 帧限量生成/移除（降低每帧遍历开销，
	# 近处 LOD0 / 远处 LOD1 互补）；数据变化（破坏/编辑）由 get_invalidated_lod1 即时重建
	_cull_check_counter += 1
	if lod0_distance > 0.0 and data and _cull_check_counter >= visibility_check_interval:
		_cull_check_counter = 0
		_process_lod()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	# call_deferred 确保在帧末尾执行（本帧渲染已提交），且队列处理不阻塞主循环
	if not _mesh_build_queue.is_empty() and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")

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
	_cancel_async()
	_clear_chunk_meshes()


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
		_clear_chunk_meshes()
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

	if mesh_mode == MeshMode.CHUNK_ASYNC:
		_update_mesh_async()
	else:
		_update_mesh_sync()


## 流式加载距离过滤（仅 STREAMING 模式生效）：
## 超出 unload_distance 的 chunk 不构建，直接标记为已流式卸载。
## 关键：避免大世界一次性全量构建（流式加载核心收益——远处永远不生成）。
## 与 _filter_frustum_chunks 组合使用：先流式过滤（距离），再视锥过滤（朝向）。
func _filter_streamed_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if not _streaming_enabled or unload_distance <= 0.0:
		return chunks
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return chunks
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var world_offset := global_position
	var kept: Array[Vector3i] = []
	# LOD0 生成边界：启用 LOD（lod0_distance>0）时，LOD0 chunk 只在 [0, lod0] 生成，
	# (lod0, unload] 区间由 LOD1 低分辨率大块覆盖（数据保留，网格用 _process_lod 生成）。
	# 决策按 LOD1 block 中心距离（与 _process_lod 一致），避免 block 跨 lod0 边界时
	# 部分 chunk 建 LOD0、部分建 LOD1 造成的重叠/空洞。
	var lod0_d: float = lod0_distance if lod0_distance > 0.0 else unload_distance
	var lod0_margin := (voxel_scale * VoxelData.LOD1_EDGE) * 0.5
	var block_edge_world := voxel_scale * float(LOD1_BLOCK_EDGE)
	for ck in chunks:
		# 无数据的空 chunk：无需流式网格管理（不建不卸，且不占用 streamed_out 字典）
		if data and not data.has_chunk(ck):
			continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		var dist := cam_pos.distance_to(aabb.get_center())
		if dist > unload_distance:
			_streamed_out_chunks[ck] = true
		elif lod0_distance > 0.0:
			var bk := _lod1_block_of_chunk(ck)
			var bcenter := _lod1_block_center(bk, world_offset, block_edge_world)
			# LOD0 生成边界用 lod0+margin（与步骤1/步骤4 的 LOD0 区一致，而非 lod0）：
			# 边界带 [lod0, lod0+margin] 是 LOD0 滞回区，若不生成 LOD0 会因步骤4 标脏、
			# 此处拦截 → LOD0 永不生成 → 近处该带永远只有 LOD1 低精度兜底（LOD0 不完备）
			if cam_pos.distance_to(bcenter) > lod0_d + lod0_margin:
				# LOD1 区：不建 LOD0 全精度网格，标记对应 LOD1 大块待生成（数据保留在内存）
				_lod1_pending[bk] = true
				# 流式补建强制的 chunk 落在 LOD1 区时无 LOD0 可建：清除标记避免 _stream_force_build 无界累积
				_stream_force_build.erase(ck)
			else:
				kept.append(ck)
		else:
			kept.append(ck)
	return kept


## 视锥剔除过滤（FULL 模式全量返回）。FRUSTUM / STREAMING 均保留视锥剔除
## （双层优化：距离卸载 + 朝向剔除）：
##   - 视锥内：立即构建（量受 FOV 限制，转向扫过的量可控）
##   - 视锥外：进待建队列，由 _process_deferred_chunks 限量补建（每帧若干个），
##     走近/转向时分批平滑出现，避免一次把大量 chunk 全部派发 → 主线程快照+生成+上传掉帧
func _filter_frustum_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if visibility_mode == VisibilityMode.FULL:
		return chunks
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return chunks
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var world_offset := global_position
	# 近处 LOD0 区（block 中心 < lod0+margin）不视锥剔除：快速转向/快速后退时
	# 新进入视野的 chunk 已提前生成，避免"近处也空"。仅远处 LOD 做视锥剔除。
	var _block_edge_world := voxel_scale * float(LOD1_BLOCK_EDGE)
	var _lod0_d := lod0_distance if lod0_distance > 0.0 else 0.0
	var _lod0_margin := (voxel_scale * VoxelData.LOD1_EDGE) * 0.5
	var visible: Array[Vector3i] = []
	for ck in chunks:
		# 无数据的空 chunk：不纳入视锥管理（无体素无需构建/补建，
		# 否则边界空邻居会被反复标 deferred → 补建空 chunk 死循环）
		if data and not data.has_chunk(ck):
			continue
		# 流式补建强制的 chunk：距离驱动，无条件构建（清除标记避免重复）
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		# 近处 LOD0 区：无条件构建（不视锥剔除）
		if _lod0_d > 0.0:
			var _bk := _lod1_block_of_chunk(ck)
			var _bc := _lod1_block_center(_bk, world_offset, _block_edge_world)
			if cam_pos.distance_to(_bc) <= _lod0_d + _lod0_margin:
				visible.append(ck)
				continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if _aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


## chunk 的世界空间 AABB（chunk 子节点的局部坐标需加上 VoxelDestructible 的 global_position）
static func _chunk_world_aabb(ck: Vector3i, chunk_size_world: float, world_offset: Vector3) -> AABB:
	var origin := world_offset + Vector3(ck) * chunk_size_world
	return AABB(origin, Vector3(chunk_size_world, chunk_size_world, chunk_size_world))


## 加载/生成优先级：距离 + 视线方向加权（前方优先、后方延后），返回值越小越优先。
## 前方(相机朝向方向,dot≈+1) 加权距离≈0.5×dist 优先；后方(dot≈-1)≈1.5×dist 延后。
## 用于流式加载/LOD1 生成排序：移动时前方地形先出现，减少"走近才加载"。
static func _load_priority(ck: Vector3i, cam_pos: Vector3, cam_dir: Vector3, chunk_size_world: float, world_offset: Vector3) -> float:
	var center := _chunk_world_aabb(ck, chunk_size_world, world_offset).get_center()
	var to_center := center - cam_pos
	var dist := to_center.length()
	if dist < 0.001:
		return 0.0
	var forward := to_center.normalized().dot(cam_dir)
	return dist - forward * dist * 0.5


## AABB 是否有任意顶点在视锥内（保守：8 顶点逐一测试，任一在内则生成整个 chunk）
## 使用 Godot 内置 is_position_in_frustum，保证判定与引擎渲染剔除一致
static func _aabb_has_vertex_in_frustum(aabb: AABB, cam: Camera3D) -> bool:
	# 用 Godot 内置 is_position_in_frustum 逐个测 8 顶点（与引擎渲染剔除判定一致）。
	for i in 8:
		var v := Vector3(
			aabb.position.x if (i & 1) == 0 else aabb.end.x,
			aabb.position.y if (i & 2) == 0 else aabb.end.y,
			aabb.position.z if (i & 4) == 0 else aabb.end.z)
		if cam.is_position_in_frustum(v):
			return true
	return false


## chunk 是否已超出流式卸载距离（当前相机位置判定）。
## 用于异步结果到达时判断是否丢弃：相机快速远离的 chunk 结果作废。
## 无相机时返回 false（保守：不丢弃）。
## 世界坐标 → chunk key（与 _chunk_world_aabb 一致）
static func _chunk_from_world(world_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> Vector3i:
	var local := world_pos - world_offset
	return Vector3i(
			floori(local.x / chunk_size_world),
			floori(local.y / chunk_size_world),
			floori(local.z / chunk_size_world))


static func _is_chunk_beyond_unload(ck: Vector3i, cam: Camera3D, chunk_size_world: float, world_offset: Vector3, unload_d: float) -> bool:
	if cam == null or unload_d <= 0.0:
		return false
	return cam.global_position.distance_to(_chunk_world_aabb(ck, chunk_size_world, world_offset).get_center()) > unload_d


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
		if _chunk_meshes.has(ck) or (data and not data.has_chunk(ck)):
			_deferred_chunks.erase(ck)
			continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if not _aabb_has_vertex_in_frustum(aabb, cam):
			if not (margin > 0.0 and cam_pos.distance_to(aabb.get_center()) <= margin):
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


## 流式加载/卸载（距离 LOD）——参考主流体素引擎做法，按距离排序 + 分帧限量：
##   - 卸载：距离 > unload_d 的 chunk，按距离【从远到近】排序，远的先卸载
##   - 加载：已卸载但距离 < load_d 的 chunk，按距离【从近到远】排序，近的先加载
## 走进时近处 chunk 先出现、远离时远处 chunk 先消失，移动时表现平滑。
## 加载不在此同步生成网格（避免主线程卡顿），而是数据回内存 + 标脏 + force_build，
## 交给 _update_mesh_async 异步批次重建（WorkerThreadPool 生成，GPU 上传再限量）。
func _process_streaming() -> void:
	if not _streaming_enabled or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var world_offset := global_position
	var load_d := view_distance
	var unload_d := unload_distance

	# 1. 卸载：距离 > unload_d，远的优先。降频检查（相机未移动时距离不变，无需全量扫描）
	# 数据层磁盘流式：遍历数据层内存 chunk，远距统一 _unload_chunk → 网格释放 + 数据写盘
	_streaming_check_tick += 1
	if unload_d > 0.0 and _streaming_check_tick % STREAM_UNLOAD_INTERVAL == 1:
		var lod1_edge_world: float = voxel_scale * float(VoxelData.LOD1_EDGE)
		var block_edge_world: float = voxel_scale * float(LOD1_BLOCK_EDGE)
		var unload_margin: float = lod1_edge_world * 0.5
		var unload_block_extent: float = block_edge_world * 0.5
		var candidates: Array = []
		if data:
			for ck in data.get_loaded_chunk_keys():
				# LOD1 区数据保留：chunk 所属 LOD1 大块中心仍处于 LOD1 显示区时
				# （≤ unload+margin+大块半径），其数据供降采样合并，不卸载——
				# 否则降采样读空，LOD1 大格缺失 → "该有体素的地方没有"。
				var bk := _lod1_block_of_chunk(ck)
				var bcenter := _lod1_block_center(bk, world_offset, block_edge_world)
				if cam_pos.distance_to(bcenter) <= unload_d + unload_margin + unload_block_extent:
					continue
				var dist: float = cam_pos.distance_to(_chunk_world_aabb(ck, chunk_size_world, world_offset).get_center())
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

	# 2. 加载：距离 < unload_d 的 streamed_out 补建（含 load~unload 滞留区），近的优先。
	# 【关键】之前只加载 < load_d：相机走近后距离落在 load~unload 滞留区的 chunk
	# streamed_out 标记残留、无任何路径触发重建 → "走近不出现"。改 < unload_d 后
	# 滞留区也补建（网格由异步重建 + GPU 限流平滑生成，不会掉帧）。
	# 降频检查（每 STREAM_LOAD_INTERVAL 帧一次，走近补建延迟 ≤0.1s）
	if unload_d > 0.0 and _streaming_check_tick % STREAM_LOAD_INTERVAL == 0:
		# 清理 streamed_out 中无数据的残留键（数据已清空的 chunk 无需流式管理，
		# 否则字典随相机移动持续膨胀）
		if data:
			for ck_clean in _streamed_out_chunks.keys():
				if not data.has_chunk(ck_clean):
					_streamed_out_chunks.erase(ck_clean)
		var to_load: Array = []
		# 粗筛：只计算相机加载半径内的 chunk（避免世界累积的 streamed_out（上万）全量
		# distance 计算 + 排序——移动时这是主线程固定成本）。远处 chunk 等相机走近
		# 进入范围再由本循环补建。
		var r_ck := ceili(unload_d / chunk_size_world)
		var cam_ck := _chunk_from_world(cam_pos, chunk_size_world, world_offset)
		for ck in _streamed_out_chunks:
			if absi(ck.x - cam_ck.x) > r_ck or absi(ck.y - cam_ck.y) > r_ck or absi(ck.z - cam_ck.z) > r_ck:
				continue
			var dist: float = cam_pos.distance_to(_chunk_world_aabb(ck, chunk_size_world, world_offset).get_center())
			if dist <= unload_d:
				to_load.append([dist, ck])
		# 加载优先级优化：距离 + 视线方向加权排序（前方优先、后方延后）——
		# 移动时前方地形先出现，减少"走近才加载"；后方延后节省带宽/IO。
		var _cam_dir: Vector3 = -cam.global_transform.basis.z
		to_load.sort_custom(func(a, b):
			return _load_priority(a[1], cam_pos, _cam_dir, chunk_size_world, world_offset) < \
					_load_priority(b[1], cam_pos, _cam_dir, chunk_size_world, world_offset))
		# 异步预读：先请求后台线程加载候选涉及 region（磁盘 IO 移出主线程），
		# 随后同步 preload 命中缓存则无 IO（未命中仅兜底，通常后台已就绪）——
		# 根治流式移动时主线程同步读盘卡顿。
		if data and data.is_streaming() and not to_load.is_empty():
			var _stream_obj := data.stream
			if _stream_obj != null and _stream_obj.has_method("request_region_load"):
				# 限量预读：只对最近的 _stream_load_per_frame 个 region 发起 IO，
				# 避免回原点/大距离瞬移时上千 region 一次性 add_task 塞满线程池
				# （磁盘并发读 + 主线程 add_task/mutex 排队 → 帧率掉到个位数）
				var _prefetch := 0
				for item in to_load:
					if _prefetch >= _stream_load_per_frame:
						break
					_stream_obj.request_region_load(_stream_obj._region_key(item[1]))
					_prefetch += 1
		var reloaded := 0
		for item in to_load:
			if reloaded >= _stream_load_per_frame:
				break
			var ck3: Vector3i = item[1]
			_streamed_out_chunks.erase(ck3)
			if data:
				if data.is_streaming():
					# 数据层磁盘流式：先把 chunk 数据从磁盘读回内存
					data.preload_chunk(ck3)
				# 标脏 + 强制构建标记：交给异步批次重建（WorkerThreadPool 生成网格，
				# 主线程不做同步网格生成 → 走近不掉帧）
				_stream_force_build[ck3] = true
				data._mark_chunk_dirty(ck3)
			reloaded += 1
		if reloaded > 0:
			_request_update()


# ----------------------------------------------------------------------------
# LOD1 低分辨率大块渲染（简化两层级 LOD）
#   距离 < lod0_distance：LOD0 全精度 chunk（由正常流式/视锥路径生成）
#   距离 [lod0_distance, unload_distance]：LOD1 大块（每格 2³ 体素，顶点约 1/8）
#   距离 > unload_distance：卸载（数据写回磁盘）
# ----------------------------------------------------------------------------

## LOD1 管理：每帧限量生成待建的 LOD1 大块 + 移除超出区间的旧 LOD1。
## 生成包含降采样（从内存 LOD0 buffer 合并 2³ 体素）+ 网格生成，主线程开销有限（限量）。
func _process_lod() -> void:
	if not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var cam_pos := cam.global_position
	var world_offset := global_position
	var lod1_edge_world := voxel_scale * VoxelData.LOD1_EDGE
	var block_edge_world := voxel_scale * float(LOD1_BLOCK_EDGE)
	var unload_d := unload_distance if unload_distance > 0.0 else view_distance * 1.5
	# LOD0/LOD1 滞回切换带：进出 LOD0 区用不同阈值（±margin），配合 LOD1 兜底，
	# 消除移动时远近分界处块反复隐藏/显示闪烁（标准 LOD 切换滞回做法）
	var lod0_d := lod0_distance
	var lod0_margin := lod1_edge_world * 0.5

	# 0. 处理数据变化导致的 LOD1 失效（破坏/编辑 → 移除旧网格，重新降采样生成）
	var invalidated := data.get_invalidated_lod1()
	if not invalidated.is_empty():
		for bk in invalidated:
			_remove_lod1(_lod1_block_of_chunk(bk))
		# 数据变化：递增代数，丢弃旧快照任务的过期结果
		_lod1_generation_id += 1

	# 1. 移除超出 LOD0 区的 LOD0 chunk 网格（远离后 >lod0+margin 的全精度网格应消失，
	#    由 LOD1 大块覆盖；增量重建不处理"非 dirty 但需移除"的 chunk，这里主动清理——
	#    否则移动后旧的全精度面残留 → "有的面没消失"）
	# 滞回：切换阈值带 [lod0-margin, lod0+margin]，离开旧 LOD 区才移除、进入新 LOD 区
	# 提前准备；且移除 LOD0 需对应 LOD1 已就绪（否则保留 LOD0 兜底），
	# 避免移动分界处"移除旧→异步生成新"的真空 → 块来回隐藏显示闪烁
	var remove_lod0: Array = []
	for ck in _chunk_meshes:
		# 与 _filter_streamed_chunks / LOD1 生成统一按 LOD1 大块中心距离决策
		var bk := _lod1_block_of_chunk(ck)
		var bcenter := _lod1_block_center(bk, world_offset, block_edge_world)
		if cam_pos.distance_to(bcenter) > lod0_d + lod0_margin and _lod1_meshes.has(bk):
			remove_lod0.append(ck)
	for ck in remove_lod0:
		_remove_chunk_mesh(ck)

	# 1. 推导需要 LOD1 的大块（从内存 chunk 主动推导，不依赖 dirty 触发）
	var needed := {}
	for ck in data.get_loaded_chunk_keys():
		needed[_lod1_block_of_chunk(ck)] = true
	# 并入待建集合（含 _filter_streamed_chunks 标记的）
	for bk in _lod1_pending:
		needed[bk] = true

	# 2. 移除已超出区间的 LOD1（> unload 卸载；< lod0-margin 完全进入 LOD0 区，
	#    但需该 block 的 LOD0 chunk 网格全部就绪才移除——否则保留 LOD1 兜底，
	#    避免 LOD0 异步生成未完成时的切换空洞/部分缺失）
	var remove_keys: Array = []
	for bk in _lod1_meshes:
		var center := _lod1_block_center(bk, world_offset, block_edge_world)
		var dist := cam_pos.distance_to(center)
		if dist > unload_d + block_edge_world * 0.5:
			remove_keys.append(bk)
		elif dist < lod0_d - lod0_margin:
			# 只统计视锥内就绪（视锥外 chunk 不显示、无需网格，不应阻塞 LOD0 显示）
			if _block_lod0_ready(bk, cam):
				remove_keys.append(bk)
				# 恢复该 block 的 LOD0 显示（步骤3.5 可能因旧就绪判定隐藏过）
				var b4 := bk * 4
				for cz in 4:
					for cy in 4:
						for cx in 4:
							var cm: Node = _chunk_meshes.get(b4 + Vector3i(cx, cy, cz))
							if cm != null:
								cm.visible = true
	for bk in remove_keys:
		_remove_lod1(bk)

	# 3. 限量生成缺失的 LOD1（最近优先：先算距离排序，再限量）。
	#    生成区间放宽到 [lod0-margin, unload]，进入 LOD0 边界带就提前生成 LOD1 兜底，
	#    使 LOD0 移除时 LOD1 已就绪（不产生切换空洞）
	var to_build: Array = []
	for bk in needed:
		if _lod1_meshes.has(bk):
			continue
		var center := _lod1_block_center(bk, world_offset, block_edge_world)
		var dist := cam_pos.distance_to(center)
		if dist < lod0_d - lod0_margin or dist > unload_d + block_edge_world * 0.5:
			continue
		to_build.append([dist, bk])
	to_build.sort_custom(func(a, b):
		# 加载优先级优化：距离 + 视线方向加权（前方 LOD1 先生成，移动时前方地形先就绪）
		var _cd: Vector3 = -cam.global_transform.basis.z
		return _lod1_load_priority(a[1], cam_pos, _cd) < _lod1_load_priority(b[1], cam_pos, _cd))
	# 生成预算控制：快照 + 派发 WorkerThreadPool（降采样/网格生成在后台线程）。
	if not to_build.is_empty():
		_aligned_lod1_materials = VoxelMaterial.align_by_id(_materials_snapshot)
	var built := 0
	var _lod1_budget_us := int(_lod1_build_budget_ms * 1000.0)
	var _t_lod1 := Time.get_ticks_usec()
	for item in to_build:
		if built >= _lod1_build_per_frame:
			break
		if (Time.get_ticks_usec() - _t_lod1) > _lod1_budget_us:
			break
		_build_lod1(item[1])
		built += 1
	_lod1_pending.clear()

	# 3.5 LOD1 可见性兜底：带内（block 中心 < lod0+margin）若该 block 的 LOD0 chunk 网格
	#    未全部就绪 → 显示 LOD1（防切换真空空洞），同时隐藏已生成的 LOD0 chunk
	#    （防 LOD1 兜底与部分 LOD0 重叠 → z-fighting 闪烁）；LOD0 全部就绪 → 隐藏 LOD1、
	#    显示 LOD0。LOD1 区（≥ lod0+margin）恒显示（此时 LOD0 已移除）。
	for bk in _lod1_meshes:
		var mi: MeshInstance3D = _lod1_meshes[bk]
		if mi == null:
			continue  # 空大块（无体素）
		var center := _lod1_block_center(bk, world_offset, block_edge_world)
		if cam_pos.distance_to(center) < lod0_d + lod0_margin:
			# 只统计视锥内就绪：视锥外 chunk 无网格不阻塞 LOD0 显示
			var lod0_ready := _block_lod0_ready(bk, cam)
			mi.visible = not lod0_ready
			var b4 := bk * 4
			for cz in 4:
				for cy in 4:
					for cx in 4:
						var cm: Node = _chunk_meshes.get(b4 + Vector3i(cx, cy, cz))
						if cm != null:
							cm.visible = lod0_ready
		else:
			mi.visible = true

	# 4. 视锥内 LOD0 区未建的 chunk → 标 dirty 补建。
	#    相机移动本身不产生 dirty，若视锥内的新区域（block 中心 <lod0+margin，应全精度）
	#    不在脏集合，增量重建不会派发 → 视锥内空洞（"有的面没显示"）。
	#    LOD1 区由上面的生成逻辑覆盖（不限视锥），此处只补 LOD0 区。
	var need_lod0_update := false
	if cam != null:
		# 粗筛：相机周围 (lod0+margin) 半径外的 chunk 必在 LOD1 区，跳过——
		# 避免每帧对全部内存 chunk（数千）算 block 距离（移动时固定 CPU 成本）
		var _chunk_world := voxel_scale * VoxelChunk.CHUNK_SIZE
		var _r_ck := ceili((lod0_d + lod0_margin) / _chunk_world) + 1
		var _cam_ck := _chunk_from_world(cam_pos, _chunk_world, world_offset)
		for ck in data.get_loaded_chunk_keys():
			# 粗筛：block 中心 > lod0+margin 的 chunk 必然在 LOD1 区，跳过
			if absi(ck.x - _cam_ck.x) > _r_ck or absi(ck.y - _cam_ck.y) > _r_ck or absi(ck.z - _cam_ck.z) > _r_ck:
				continue
			# 统一按 LOD1 大块中心距离判断 LOD0 区（与移除/生成一致）：
			# 大块中心 <lod0+margin → 全精度 LOD0（提前补建，覆盖滞回带，
			# 使 LOD1 移除时 LOD0 已就绪），否则该 chunk 会因"距离>lod0"被跳过补建、
			# 又因"大块在LOD0区"不生成 LOD1 → 空洞
			var bk := _lod1_block_of_chunk(ck)
			var bcenter := _lod1_block_center(bk, world_offset, block_edge_world)
			var bdist := cam_pos.distance_to(bcenter)
			if bdist > lod0_d + lod0_margin:
				continue  # LOD1 区（由 _build_lod1 覆盖）
			if _chunk_meshes.has(ck):
				continue
			# 近处 LOD0 区（block 中心 < lod0+margin）全向补建（不视锥剔除）：
			# 快速转向/快速后退时新进入视野的 chunk 已提前生成，避免近处空洞。
			# 视锥外的近处 chunk 由引擎视锥剔除隐藏，不渲染但不缺数据。
			data._mark_chunk_dirty(ck)
			need_lod0_update = true
	if need_lod0_update:
		_request_update()


## block 的 LOD0 网格是否就绪（只统计视锥内）：视锥外的 chunk 不显示、无需网格，
## 若纳入会因"有数据无网格"误判未就绪 → LOD1 永兜底 + LOD0 全隐藏 → 近处低精度缺面。
func _block_lod0_ready(bk: Vector3i, cam: Camera3D) -> bool:
	var b4 := bk * 4
	var chunk_w := voxel_scale * VoxelChunk.CHUNK_SIZE
	for cz in 4:
		for cy in 4:
			for cx in 4:
				var ck := b4 + Vector3i(cx, cy, cz)
				if data.has_chunk(ck) and not _chunk_meshes.has(ck):
					var aabb := _chunk_world_aabb(ck, chunk_w, global_position)
					if _aabb_has_vertex_in_frustum(aabb, cam):
						return false
	return true


## LOD1 生成优先级：距离 + 视线方向加权（前方 block 先生成）。返回值越小越优先。
func _lod1_load_priority(bk: Vector3i, cam_pos: Vector3, cam_dir: Vector3) -> float:
	var center := _lod1_block_center(bk, global_position, voxel_scale * float(LOD1_BLOCK_EDGE))
	var to_center := center - cam_pos
	var dist := to_center.length()
	if dist < 0.001:
		return 0.0
	var forward := to_center.normalized().dot(cam_dir)
	return dist - forward * dist * 0.5


## 派发 LOD1 大块异步生成：快照 chunk（COW）+ WorkerThreadPool 后台降采样/网格生成。
## 一次性生成 32³ 大格 mesh（godot_voxel 大 block 方案），结果由 _on_lod1_thread_result 主线程挂载。
func _build_lod1(bk: Vector3i) -> void:
	if not data:
		return
	if _lod1_pending_tasks.has(bk):
		return
	var snapshot := data.snapshot_lod1_block_chunks(bk)
	_lod1_pending_tasks[bk] = true
	WorkerThreadPool.add_task(_lod1_worker.bind(
		snapshot, bk, _lod1_generation_id, voxel_scale,
		data.center_offset if data else Vector3.ZERO, _aligned_lod1_materials))


## 工作线程：LOD1 大块降采样 halo + 一次性网格生成（线程安全，只读参数快照）。
func _lod1_worker(buffers: Dictionary, bk: Vector3i, gen_id: int, scale: float,
		offset: Vector3, aligned_materials: Array) -> void:
	var halo := VoxelChunkGenerator.build_lod1_block_halo_from_buffers(buffers, bk)
	var arr := VoxelChunkGenerator.generate_lod1_block_arrays(halo, aligned_materials, scale, bk, offset)
	call_deferred("_on_lod1_thread_result", bk, arr, gen_id)


## 主线程 LOD1 结果处理：校验 gen_id / 区间，然后挂载大块 MeshInstance3D
func _on_lod1_thread_result(bk: Vector3i, arr: Dictionary, gen_id: int) -> void:
	_lod1_pending_tasks.erase(bk)
	if gen_id != _lod1_generation_id:
		return
	if _lod1_meshes.has(bk):
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var block_edge_world := voxel_scale * float(LOD1_BLOCK_EDGE)
	var center := _lod1_block_center(bk, global_position, block_edge_world)
	var dist := cam.global_position.distance_to(center)
	var lod0_d := lod0_distance
	var lod0_margin := (voxel_scale * VoxelData.LOD1_EDGE) * 0.5
	var unload_d := unload_distance if unload_distance > 0.0 else view_distance * 1.5
	if dist < lod0_d - lod0_margin or dist > unload_d + block_edge_world * 0.5:
		return  # 已移出区间，丢弃过期结果
	if arr.is_empty():
		_lod1_meshes[bk] = null  # 空大块：标记已处理，避免重复派发
		return
	_build_lod1_from_arrays(bk, arr)


## 主线程挂载 LOD1 大块网格（一次性生成结果已就绪，仅建 mesh + 挂载）
func _build_lod1_from_arrays(bk: Vector3i, arr: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "LOD1B_%d_%d_%d" % [bk.x, bk.y, bk.z]
	add_child(mi)
	var block_edge_world := voxel_scale * float(LOD1_BLOCK_EDGE)
	mi.position = Vector3(bk) * block_edge_world
	if not arr.is_empty():
		var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
		if new_mesh and _materials_cache.size() >= 2:
			if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
				new_mesh.surface_set_material(0, _materials_cache[0])
			if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
				new_mesh.surface_set_material(1, _materials_cache[1])
		mi.mesh = new_mesh
	_lod1_meshes[bk] = mi


## 移除 LOD1 大块
func _remove_lod1(bk: Vector3i) -> void:
	var mi: MeshInstance3D = _lod1_meshes.get(bk)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_lod1_meshes.erase(bk)
	_lod1_pending.erase(bk)
	_lod1_pending_tasks.erase(bk)


## 卸载单个 chunk 网格（非超级块模式）：释放 mesh + 节点，记录到 _streamed_out_chunks
func _unload_chunk(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _chunk_meshes.get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_chunk_meshes.erase(ck)
	_remove_chunk_collision(ck)
	_mesh_build_queue.erase(ck)
	_stream_force_build.erase(ck)
	_streamed_out_chunks[ck] = true
	# 数据层磁盘流式：卸载 chunk 数据（修改过的写盘、变空的清盘、未修改丢弃，释放内存）
	if data and data.is_streaming():
		data.unload_chunk(ck)
	# 记录性能/内存释放（诊断）
	if diag_enabled:
		print("[诊断] 流式卸载: Chunk%s" % ck)


## 清除单个 chunk 的渲染网格（数据层已变空、但渲染层 mesh 残留时调用）。
## 破坏/崩塌后 chunk 内体素全被移除（has_chunk=false），增量重建时 _filter_frustum_chunks
## 会跳过空 chunk 不派发 → 若不主动清除，旧 mesh 残留 → 视觉上"悬空块还在"（数据其实已掉）。
func _remove_chunk_mesh(ck: Vector3i) -> void:
	var mi: MeshInstance3D = _chunk_meshes.get(ck)
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_chunk_meshes.erase(ck)
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
	if mesh_mode != MeshMode.GLOBAL_MESH:
		# chunk 级脏标记（_mark_voxel_dirty 已含跨界面的边界邻居），
		# 替代逐体素 dirty_voxels 的大批量追踪——大崩塌移除不再主线程逐体素写 dict
		rebuild_chunks = data.get_dirty_chunks()
		# 限量批次：超过上限的放回 dirty（下帧续建）。回原点/大崩塌时 dirty 可上千，
		# 单帧全量快照 + 派发上千 worker → 主线程阻塞（update_mesh 数百 ms → 帧率个位数）。
		# 分批后每帧快照/派发量受限，网格经 _process_mesh_build_queue 平滑上传。
		const _REBUILD_BATCH_LIMIT := 64
		if rebuild_chunks.size() > _REBUILD_BATCH_LIMIT:
			for i in range(_REBUILD_BATCH_LIMIT, rebuild_chunks.size()):
				data._mark_chunk_dirty(rebuild_chunks[i])
			rebuild_chunks.resize(_REBUILD_BATCH_LIMIT)
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
	# 将 mesh_mode 和 voxel_scale 作为参数传入，避免子线程访问节点属性
	#
	# 每个脏 chunk 独立一个线程任务，WorkerThreadPool 内部管理并发数
	if mesh_mode != MeshMode.GLOBAL_MESH:
		# chunk 模式：每个任务只处理一个 chunk。
		# 优化（移走主线程 halo 提取）：主线程只做一次"受影响区域"的 chunk 缓冲
		# 深拷贝快照（引擎级 memcpy，微秒级），各子线程 worker 再从快照构建自己的
		# 18³ halo。相比旧方案主线程逐 chunk 调用 get_chunk_halo（GDScript 循环，
		# ~0.9ms/chunk，全量构建时主线程阻塞秒级），大幅降低主线程阻塞。
		# 单任务路径（全量/空场景）仅当没有可拆分 chunk 时兜底使用，需要完整体素
		if rebuild_chunks.is_empty():
			# 全量构建（初始构建或切换模式后）：分 chunk 独立线程，逐个显示
			# 而不是等所有 chunk 生成完毕再一起显示
			var all_chunks := data.get_all_chunk_keys()
			if all_chunks.is_empty():
				# 没有非空 chunk，使用单任务路径（空场景），此时无体素无竞态
				_pending_task_count = 1
				_task_ids.append(WorkerThreadPool.add_task(_generate_worker.bind(
					{}, snapshot_materials, rebuild_chunks, gen_id, mesh_mode, voxel_scale, render_offset, diag_enabled)))
			else:
				# 先流式距离过滤（无条件，远距 chunk 不生成），再视锥过滤（朝向）
				var after_stream: Array[Vector3i] = _filter_streamed_chunks(all_chunks)
				var visible: Array[Vector3i] = _filter_frustum_chunks(after_stream)
				if diag_enabled:
					print("[诊断] 全量构建 gen_id=%d: 总%d Chunk, 流式卸载%d, 视锥内%d, 延迟%d" % [gen_id, all_chunks.size(), all_chunks.size() - after_stream.size(), visible.size(), after_stream.size() - visible.size()])
				var snapshot: Dictionary = data.snapshot_chunks_halo(visible)
				_pending_task_count = visible.size()
				for ck in visible:
					_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
						snapshot, aligned_materials, ck, gen_id, voxel_scale, render_offset, diag_enabled)))
		else:
			# 增量重建：每个 chunk 独立一个线程任务，真正并行处理
			# 【关键】先清除"已变空"chunk 的残留 mesh：破坏/崩塌后 chunk 内体素
			# 全被移除（has_chunk=false），而 _filter_frustum_chunks 会跳过空 chunk
			# 不派发重建 → 若不主动清除，旧 mesh 残留，视觉上"悬空块还在"（数据其实已掉）。
			for ck in rebuild_chunks:
				if _chunk_meshes.has(ck) and not data.has_chunk(ck):
					_remove_chunk_mesh(ck)
			# 先流式距离过滤（无条件），再视锥过滤（朝向）
			var after_stream: Array[Vector3i] = _filter_streamed_chunks(rebuild_chunks)
			var visible: Array[Vector3i] = _filter_frustum_chunks(after_stream)
			if diag_enabled:
				print("[诊断] 增量重建 gen_id=%d: 脏%d Chunk, 流式卸载%d, 视锥内%d, 延迟%d" % [gen_id, rebuild_chunks.size(), rebuild_chunks.size() - after_stream.size(), visible.size(), after_stream.size() - visible.size()])
			var snapshot: Dictionary = data.snapshot_chunks_halo(visible)
			_pending_task_count = visible.size()
			for ck in visible:
				_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
					snapshot, aligned_materials, ck, gen_id, voxel_scale, render_offset, diag_enabled)))
	else:
		# 单任务路径（全局模式）：需要整个世界体素，做一次字典快照
		_pending_task_count = 1
		var snapshot_voxels: Dictionary = data.get_voxels_dict_snapshot()
		_task_ids.append(WorkerThreadPool.add_task(_generate_worker.bind(
			snapshot_voxels, snapshot_materials, rebuild_chunks, gen_id, mesh_mode, voxel_scale, render_offset, diag_enabled)))


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
func _generate_worker(voxels: Dictionary, materials: Array, rebuild_chunks: Array, gen_id: int,
		use_chunk: bool, scale: float, offset: Vector3 = Vector3.ZERO,
		diag_enabled: bool = false) -> void:
	var result: Dictionary = {}

	# 增量重建路径：每个 chunk 的顶点使用局部坐标，生成独立子 MeshInstance3D
	if use_chunk:
		var t0 := Time.get_ticks_usec()
		var chunk_arrays: Dictionary
		var affected_count := rebuild_chunks.size()
		if rebuild_chunks.is_empty():
			# 无脏体素时全量生成所有非空 chunk（初始构建或切换模式后）
			if diag_enabled and gen_id <= 1:
				print("[诊断] 初始全量构建（gen_id=%d）..." % gen_id)
			chunk_arrays = VoxelChunkGenerator.generate_all_chunks_arrays_runtime(
				voxels, materials, {"scale": scale, "offset": offset})
			affected_count = chunk_arrays.size()
			if diag_enabled:
				print("[诊断] 全量构建完成: %d 个非空 Chunk" % affected_count)
		else:
			# P1: 并行生成多个 chunk
			if diag_enabled:
				print("[诊断] 增量重建 gen_id=%d: %d 个脏 Chunk" % [gen_id, rebuild_chunks.size()])
			chunk_arrays = _generate_chunks_parallel(voxels, materials, scale, rebuild_chunks, offset)
		var gen_time_ms := (Time.get_ticks_usec() - t0) / 1000.0
		# 统计顶点/三角形数
		var counts := _count_chunk_vertices(chunk_arrays)
		result = _make_result(chunk_arrays, gen_time_ms, counts.x, counts.y,
			chunk_arrays.size(), affected_count, gen_id)
	else:
		# 全量重建路径：所有体素合并为一个 ArrayMesh
		var t1 := Time.get_ticks_usec()
		var arrays: Variant = VoxelChunkGenerator.generate_arrays_runtime(voxels, materials, {"scale": scale, "offset": offset})
		var gen_time_ms := (Time.get_ticks_usec() - t1) / 1000.0
		var sv := 0; var tv := 0
		if arrays is Dictionary:
			sv = arrays.get("solid_verts", PackedVector3Array()).size()
			tv = arrays.get("trans_verts", PackedVector3Array()).size()
		result = _make_result(arrays, gen_time_ms, sv, tv, 1, 1, gen_id)

	# 使用 call_deferred 将结果传回主线程（线程安全，仅排队到主线程消息队列，不直接操作 Node 属性）
	call_deferred("_on_thread_result", result)


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
## 根据 result 中是否包含 chunk_key 区分：
## - 有 chunk_key：单个 chunk 的结果，直接更新对应子 MeshInstance3D
## - 无 chunk_key：全量结果（来自 _generate_worker），委托 _build_and_apply_mesh 处理
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
		# 注意用【当前距离】判断而非残留标记：相机重新走近（<unload）的 chunk
		# 即使带旧 streamed_out 标记也必须应用结果，否则永久缺失。
		var cam_now := get_viewport().get_camera_3d() if is_inside_tree() else null
		if _streamed_out_chunks.has(chunk_key) and _is_chunk_beyond_unload(
				chunk_key, cam_now, voxel_scale * VoxelChunk.CHUNK_SIZE, global_position, unload_distance):
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

		# 入队待构建（GPU 上传限流，_process 每帧批量处理）
		# 避免连续破坏时一帧大量 ArrayMesh 创建 + GPU 上传 → Metal fence 超时
		_mesh_build_queue[chunk_key] = {
			"arrays": arr if (arr is Dictionary and not arr.is_empty() and has_voxels_in_data) else {},
			"has_voxels": has_voxels_in_data,
		}
		_record_perf_stats(1, gen_time_ms, last_apply_time_ms)
	else:
		# 全量结果（来自 _generate_worker，初始全量构建或非 chunk 模式）
		# 注意：_build_and_apply_mesh 会清空脏 chunk 标记，
		# 如果 _pending_retrigger 为 true，需要保存脏 chunk 以便后续恢复
		var saved_dirty: Array = []
		if _pending_retrigger and data:
			saved_dirty = data.get_dirty_chunks()

		_build_and_apply_mesh(arrays)

		# 恢复脏 chunk（用于 _on_batch_complete 中的 retrigger 逻辑）
		if _pending_retrigger and data and not saved_dirty.is_empty():
			for ck in saved_dirty:
				data._mark_chunk_dirty(ck)

		_record_perf_stats(last_rebuild_affected_count, gen_time_ms, last_apply_time_ms)

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

	# GPU 忙检测：上一帧渲染耗时（_delta）过高时暂停本帧构建，把同步 GPU 上传（ArrayMesh
	# add_surface_from_arrays → Metal fence wait）避开 GPU 满载时刻，消除 wait() 超时。
	# 用帧时长而非 RenderingServer 测量 API（后者在部分驱动上返回 0 不可靠）。
	# 注意：忙时不 call_deferred 自续排（会与 _process 的排期叠加成 call_deferred 堆积，
	# 导致消息队列爆炸 → 进程退出），只清空 scheduled 标记，让 _process 下一帧自然重新排期。
	if _last_frame_delta > _gpu_busy_threshold_ms / 1000.0:
		# GPU 忙：本帧不构建，下帧 _process 会重新排期（scheduled 已置 false）
		if diag_enabled:
			print("[诊断] GPU忙(帧%.1fms), 暂停mesh构建" % (_last_frame_delta * 1000.0))
		return

	var t0 := Time.get_ticks_usec()
	var built := 0
	var keys := _mesh_build_queue.keys()
	# 优先处理已有 mesh 的 chunk（保证破坏面及时更新），再处理新 chunk
	keys.sort_custom(func(a, b):
		return _chunk_meshes.has(a) and not _chunk_meshes.has(b))
	for ck in keys:
		if built >= _mesh_build_per_frame:
			break
		var entry: Dictionary = _mesh_build_queue[ck]
		_mesh_build_queue.erase(ck)
		_apply_built_chunk(ck, entry)
		built += 1
		# 自适应：若本帧构建已超 3ms，提前停止避免帧尖峰
		if (Time.get_ticks_usec() - t0) / 1000.0 > 3.0:
			break
	# 若还有剩余，下帧继续
	if not _mesh_build_queue.is_empty():
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")
	if diag_enabled and built > 0:
		print("[诊断] GPU上传批处理: %d chunk, 耗时%.2f ms, 剩余%d" % [
			built, (Time.get_ticks_usec() - t0) / 1000.0, _mesh_build_queue.size()])


## 应用单个待构建 chunk（构建 mesh + 挂载节点 + 更新碰撞）
func _apply_built_chunk(chunk_key: Vector3i, entry: Dictionary) -> void:
	var arr: Dictionary = entry["arrays"]
	var has_voxels_in_data: bool = entry["has_voxels"]

	# 获取或创建该 chunk 的子 MeshInstance3D
	var chunk_mesh: MeshInstance3D
	if _chunk_meshes.has(chunk_key):
		chunk_mesh = _chunk_meshes[chunk_key]
	else:
		chunk_mesh = MeshInstance3D.new()
		chunk_mesh.name = "Chunk_%d_%d_%d" % [chunk_key.x, chunk_key.y, chunk_key.z]
		add_child(chunk_mesh)
		_chunk_meshes[chunk_key] = chunk_mesh

	var has_mesh := false
	if not arr.is_empty() and has_voxels_in_data:
		var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
		if new_mesh and _materials_cache.size() >= 2:
			if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
				new_mesh.surface_set_material(0, _materials_cache[0])
			if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
				new_mesh.surface_set_material(1, _materials_cache[1])
		chunk_mesh.mesh = new_mesh
		has_mesh = new_mesh != null
	elif not has_voxels_in_data:
		# chunk 已无体素，清除 mesh 数据并移除容器防止累积
		chunk_mesh.mesh = null
		chunk_mesh.queue_free()
		_chunk_meshes.erase(chunk_key)
	else:
		# 竞态：生成后体素被重新添加，保留已有 mesh
		has_mesh = chunk_mesh.mesh != null

	if has_voxels_in_data or _chunk_meshes.has(chunk_key):
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
static func _generate_chunks_parallel(voxels: Dictionary, materials: Array, scale: float,
		chunk_keys: Array[Vector3i], offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var aligned := VoxelMaterial.align_by_id(materials)
	var result := {}
	for ck in chunk_keys:
		var arr := VoxelChunkGenerator.generate_single_chunk_array(voxels, aligned, scale, ck, offset)
		if not arr.is_empty():
			result[ck] = arr
	return result


## 同步路径：主线程直接生成并应用（兼容模式）
func _update_mesh_sync() -> void:
	var options := {
		"scale": voxel_scale,
		"offset": data.center_offset if data else Vector3.ZERO,
	}

	# Per-chunk 增量重建（同步版，密集光环直连生成）
	if mesh_mode != MeshMode.GLOBAL_MESH:
		var rebuild_chunks: Array[Vector3i] = data.get_dirty_chunks()
		last_rebuild_affected_count = rebuild_chunks.size()
		var t0 := Time.get_ticks_usec()
		var chunk_keys: Array[Vector3i] = rebuild_chunks
		if chunk_keys.is_empty():
			chunk_keys = data.get_all_chunk_keys()
			last_rebuild_affected_count = chunk_keys.size()
		var aligned := VoxelMaterial.align_by_id(data.materials)
		var chunk_arrays: Dictionary = {}
		for ck in chunk_keys:
			var arr := VoxelChunkGenerator.generate_single_chunk_dense(
				data.get_chunk_halo(ck), aligned, options["scale"], ck, options["offset"])
			if not arr.is_empty():
				chunk_arrays[ck] = arr
		last_mesh_gen_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
		# 统计顶点/三角形数（统一 _count_chunk_vertices / _set_last_vertex_stats）
		var counts := _count_chunk_vertices(chunk_arrays)
		_set_last_vertex_stats(counts.x, counts.y, chunk_arrays.size())
		_build_and_apply_chunk_meshes(chunk_arrays)
		# _build_and_apply_chunk_meshes 内部在 mesh_updated 前设置了 last_apply_time_ms
		_record_perf_stats(last_rebuild_affected_count, last_mesh_gen_time_ms, last_apply_time_ms)
		return

	# 全量重建（组合模式）
	var t1 := Time.get_ticks_usec()
	var arrays := VoxelChunkGenerator.generate_arrays_runtime(data.get_voxels_dict_snapshot(), data.materials, options)
	last_mesh_gen_time_ms = (Time.get_ticks_usec() - t1) / 1000.0
	if arrays is Dictionary:
		_set_last_vertex_stats(
			arrays.get("solid_verts", PackedVector3Array()).size(),
			arrays.get("trans_verts", PackedVector3Array()).size(),
			1)
		last_rebuild_affected_count = 1
	_build_and_apply_mesh(arrays)
	# _build_and_apply_mesh 内部已设置 last_apply_time_ms
	_record_perf_stats(last_rebuild_affected_count, last_mesh_gen_time_ms, last_apply_time_ms)


## 将网格数据组装为 ArrayMesh 并应用到节点（必须主线程）
func _build_and_apply_mesh(arrays: Variant) -> void:
	# 检测是否为 per-chunk 字典（key 为 Vector3i）
	if arrays is Dictionary and _is_chunk_arrays_result(arrays):
		_build_and_apply_chunk_meshes(arrays as Dictionary)
		return

	var t0 := Time.get_ticks_usec()
	var new_mesh: ArrayMesh
	if arrays != null and arrays is Dictionary and not arrays.is_empty():
		new_mesh = VoxelChunkGenerator.build_mesh_from_arrays(arrays as Dictionary)
		# 给 chunk mesh 的两个表面赋材质（实心/透明）
		if new_mesh and _materials_cache.size() >= 2:
			if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
				new_mesh.surface_set_material(0, _materials_cache[0])
			if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
				new_mesh.surface_set_material(1, _materials_cache[1])

	if new_mesh:
		mesh = new_mesh
		# 切换到组合模式时清理旧的 chunk meshes
		if not _chunk_meshes.is_empty():
			_clear_chunk_meshes()
	else:
		mesh = null

	if generate_collision:
		_update_collision()
	else:
		_clear_collision()

	# 重建完成，清空变更追踪
	if data:
		data.clear_dirty_chunks()
	# 在信号触发前更新 apply 耗时，确保外部读取的数据正确
	last_apply_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	mesh_updated.emit()


## 判断是否为 per-chunk 结果字典（key 为 Vector3i 类型）
static func _is_chunk_arrays_result(arrays: Dictionary) -> bool:
	if arrays.is_empty():
		return false
	var first_key = arrays.keys()[0]
	return first_key is Vector3i


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
func _clear_chunk_meshes() -> void:
	_deferred_chunks.clear()
	_mesh_build_queue.clear()
	for ck in _chunk_meshes:
		_chunk_meshes[ck].queue_free()
	_chunk_meshes.clear()
	# 清理 LOD1 大块
	for bk in _lod1_meshes:
		_lod1_meshes[bk].queue_free()
	_lod1_meshes.clear()
	_lod1_pending.clear()
	if data:
		data.clear_lod1_cache()
	_clear_chunk_collisions()


## 清理所有 per-chunk 碰撞体
func _clear_chunk_collisions() -> void:
	for ck in _chunk_collisions:
		_chunk_collisions[ck].queue_free()
	_chunk_collisions.clear()


## 将 per-chunk 网格数据应用到子 MeshInstance3D
## 注意：chunk_arrays 中可能包含空 chunk（空字典），用于清空已无体素的 chunk mesh
func _build_and_apply_chunk_meshes(chunk_arrays: Dictionary) -> void:
	var t_start := Time.get_ticks_usec()
	var chunk_scale := voxel_scale * VoxelChunkGenerator.CHUNK_SIZE

	# 收集本次重建涉及的所有 chunk key
	var rebuilt_keys: Array[Vector3i] = []
	for ck in chunk_arrays:
		rebuilt_keys.append(ck)

	# 诊断：记录重建规模（仅诊断模式开启时）
	if diag_enabled:
		print("[诊断] 重建 Chunk=%d 已有Mesh=%d" % [rebuilt_keys.size(), _chunk_meshes.size()])

	# 处理所有重建的 chunk
	var cleared_count := 0
	for ck in rebuilt_keys:
		var arrays = chunk_arrays[ck]
		# 获取或创建该 chunk 的子 MeshInstance3D
		var chunk_mesh: MeshInstance3D
		if _chunk_meshes.has(ck):
			chunk_mesh = _chunk_meshes[ck]
		else:
			chunk_mesh = MeshInstance3D.new()
			chunk_mesh.name = "Chunk_%d_%d_%d" % [ck.x, ck.y, ck.z]
			add_child(chunk_mesh)
			_chunk_meshes[ck] = chunk_mesh

		# 【修复】检查当前数据中该 chunk 是否已无体素（异步任务快照滞后导致）
		# 如果 chunk 在快照中还有体素，但当前数据中已被完全破坏，清空其 mesh
		var has_voxels_in_data := false
		if data:
			var current_voxels: Array = data.get_chunk_voxels(ck)
			has_voxels_in_data = not current_voxels.is_empty()

		# 构建 mesh
		var has_mesh := false
		if arrays is Dictionary and not arrays.is_empty() and has_voxels_in_data:
			var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arrays as Dictionary)
			if new_mesh and _materials_cache.size() >= 2:
				if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
					new_mesh.surface_set_material(0, _materials_cache[0])
				if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
					new_mesh.surface_set_material(1, _materials_cache[1])
			chunk_mesh.mesh = new_mesh
			has_mesh = new_mesh != null
		elif not has_voxels_in_data:
			# chunk 已无体素，清除 mesh 并移除节点防止累积
			chunk_mesh.mesh = null
			_chunk_meshes.erase(ck)
			chunk_mesh.queue_free()
		else:
			# has_voxels_in_data 为 true 但 arrays 为空（竞态：生成后体素被重新添加）
			# 保留已有 mesh，等待下一帧重建
			has_mesh = chunk_mesh.mesh != null

		# Per-chunk 碰撞体（节点被清理时不执行）
		if has_voxels_in_data or _chunk_meshes.has(ck):
			chunk_mesh.position = Vector3(ck) * chunk_scale
			_collision_rebuild_queue[ck] = has_mesh
		else:
			_remove_chunk_collision(ck)

	# 检查是否有 chunk 在重建后变为空但未被清理（不在 rebuilt_keys 中的）
	# 遍历所有已存在的 chunk mesh，如果不在本次重建列表中且已无体素，清空其 mesh
	for ck in _chunk_meshes.keys():
		if rebuilt_keys.has(ck):
			continue  # 已在本轮重建中处理
		# 检查该 chunk 是否已无体素
		if data:
			var chunk_positions: Array = data.get_chunk_voxels(ck)
			if chunk_positions.is_empty():
				cleared_count += 1
				if diag_enabled:
					print("[诊断] Chunk %s 不在重建列表且已无体素，清除旧 Mesh" % ck)
				_chunk_meshes[ck].queue_free()
				_chunk_meshes.erase(ck)
				_remove_chunk_collision(ck)

	if diag_enabled and cleared_count > 0:
		print("[诊断] 本轮共清除 %d 个空 Chunk Mesh" % cleared_count)

	# 清理变更追踪
	if data:
		data.clear_dirty_chunks()
	# 在信号触发前更新 apply 耗时，确保外部读取的数据正确
	last_apply_time_ms = (Time.get_ticks_usec() - t_start) / 1000.0
	mesh_updated.emit()


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
		var chunk_mesh: MeshInstance3D = _chunk_meshes.get(ck)
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