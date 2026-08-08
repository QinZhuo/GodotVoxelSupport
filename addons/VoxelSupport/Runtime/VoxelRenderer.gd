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
		_materials_cache.clear()
		_materials_snapshot_dirty = true
		_clear_chunk_meshes()
		_request_update()

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
		if v == VisibilityMode.FULL:
			_deferred_chunks.clear()
			# 全量模式下补建被卸载的网格
			for ck in _streamed_out_chunks.keys():
				_streamed_out_chunks.erase(ck)
				if data:
					data.dirty_voxels[VoxelChunk.origin_of(ck)] = data.get_voxel(VoxelChunk.origin_of(ck))
		_request_update()

## 可见性加载距离（世界单位）：FRUSTUM 时视锥外仍生成的半径；STREAMING 时网格加载半径
@export var view_distance: float = 40.0

## 流式卸载距离（世界单位，仅 STREAMING）：超过此距离的 chunk 网格被卸载释放
## 默认 0 = 自动取 view_distance * 1.5
@export var unload_distance: float = 0.0

## 可见性检查间隔（帧）：视锥/流式统一每隔 N 帧检查一次相机位置。
## 值越大 CPU 开销越低，但进入视锥/加载距离后的补建响应越慢。
@export_range(1, 120) var visibility_check_interval: int = 8

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

# 流式加载每帧限量（卸载/补建共用）：相机移动跨越边界时，卸载与补建分批进行，
# 避免一次处理几十个 chunk（queue_free + 重建 + GPU 上传）造成掉帧
var _stream_per_frame: int = 8
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
	# 流式加载启用判定：visibility_mode == STREAMING 即启用（unload 默认 = view*1.5）
	_streaming_enabled = visibility_mode == VisibilityMode.STREAMING
	if _streaming_enabled and unload_distance <= 0.0:
		unload_distance = view_distance * 1.5


func _process(_delta: float) -> void:
	# 记录上一帧耗时，供 GPU 忙检测使用（_process_mesh_build_queue）
	_last_frame_delta = _delta
	# 异步任务结果通过 call_deferred 直接传递到 _on_thread_result，无需轮询
	# 这里只处理限流和启动新任务

	# 可见性管理周期检查（视锥剔除补建 + 流式加载/卸载 统一节奏）
	# 仅在无进行中任务时触发，避免与批次冲突
	_cull_check_counter += 1
	if _cull_check_counter >= visibility_check_interval:
		_cull_check_counter = 0
		if _pending_task_count == 0:
			if visibility_mode != VisibilityMode.FULL:
				_process_deferred_chunks()
			if _streaming_enabled:
				_process_streaming()

	# GPU 上传限流：帧尾批量构建队列中的 chunk mesh（避免与渲染/崩塌竞争 GPU）
	# call_deferred 确保在帧末尾执行（本帧渲染已提交），且队列处理不阻塞主循环
	if not _mesh_build_queue.is_empty() and not _mesh_build_scheduled:
		_mesh_build_scheduled = true
		call_deferred("_process_mesh_build_queue")

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
	for ck in chunks:
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if cam_pos.distance_to(aabb.get_center()) > unload_distance:
			_streamed_out_chunks[ck] = true
		else:
			kept.append(ck)
	return kept


## 视锥剔除过滤（FULL 模式全量返回）。FRUSTUM/STREAMING 模式仅保留视锥内或
## view_distance 内（相机附近）的 chunk，视锥外加入待建队列延迟补建。
func _filter_frustum_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if visibility_mode == VisibilityMode.FULL:
		return chunks
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return chunks
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var margin := view_distance
	var cam_pos := cam.global_position
	var world_offset := global_position
	var visible: Array[Vector3i] = []
	for ck in chunks:
		# 流式补建强制的 chunk：距离驱动，忽略朝向，无条件构建（清除标记避免重复）
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if _aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		elif margin > 0.0 and cam_pos.distance_to(aabb.get_center()) <= margin:
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


## chunk 的世界空间 AABB（chunk 子节点的局部坐标需加上 VoxelDestructible 的 global_position）
static func _chunk_world_aabb(ck: Vector3i, chunk_size_world: float, world_offset: Vector3) -> AABB:
	var origin := world_offset + Vector3(ck) * chunk_size_world
	return AABB(origin, Vector3(chunk_size_world, chunk_size_world, chunk_size_world))


## AABB 是否有任意顶点在视锥内（保守：8 顶点逐一测试，任一在内则生成整个 chunk）
## 使用 Godot 内置 is_position_in_frustum，保证判定与引擎渲染剔除一致
static func _aabb_has_vertex_in_frustum(aabb: AABB, cam: Camera3D) -> bool:
	for i in 8:
		var v := Vector3(
			aabb.position.x if (i & 1) == 0 else aabb.end.x,
			aabb.position.y if (i & 2) == 0 else aabb.end.y,
			aabb.position.z if (i & 4) == 0 else aabb.end.z)
		if cam.is_position_in_frustum(v):
			return true
	return false


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
## 由 _process 按 visibility_check_interval 帧调用一次。
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
	var to_build: Array[Vector3i] = []
	for ck in _deferred_chunks:
		var aabb := _chunk_world_aabb(ck, chunk_size_world, world_offset)
		if _aabb_has_vertex_in_frustum(aabb, cam):
			to_build.append(ck)
		elif margin > 0.0 and cam_pos.distance_to(aabb.get_center()) <= margin:
			to_build.append(ck)
	if to_build.is_empty():
		return
	for ck in to_build:
		_deferred_chunks.erase(ck)
		if data:
			var origin := VoxelChunk.origin_of(ck)
			data.dirty_voxels[origin] = data.get_voxel(origin)
	_request_update()


## 流式加载处理（距离 LOD 卸载）：
## 按相机距离管理 chunk 网格：
##   - 超过 unload_distance 的已建 chunk → 卸载网格（释放 ArrayMesh+节点）
##   - 已卸载但相机进入 view_distance 的 chunk → 重新标记待建（补建）
## 数据层（VoxelData）全量保留，仅渲染网格按需加载/卸载。
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

	# 1. 卸载：距离 > unload_d 的已建 chunk 网格释放
	# 【每帧限量】卸载分批进行，避免一次 queue_free 大量节点造成掉帧
	var unloaded := 0
	if unload_d > 0.0:
		for ck in _chunk_meshes.keys():
			if unloaded >= _stream_per_frame:
				break
			var ck3: Vector3i = ck
			var aabb := _chunk_world_aabb(ck3, chunk_size_world, world_offset)
			if cam_pos.distance_to(aabb.get_center()) > unload_d:
				_unload_chunk(ck3)
				unloaded += 1

	# 2. 重新加载：已卸载但距离 < load_d 的 chunk 补建
	# 【每帧限量】补建分批进行，避免相机移动跨越边界时一次重建几十个 chunk 造成掉帧。
	# 补建同步生成单 chunk 数组直接入 GPU 限流队列（绕过异步 pipeline 的
	# _pending_task_count 串行等待——否则补建任务积压、每帧只建几个）。
	# 每帧最多 _stream_per_frame 个同步生成（~1ms/chunk），主线程可接受。
	var reloaded := 0
	if load_d > 0.0:
		for ck in _streamed_out_chunks:
			if reloaded >= _stream_per_frame:
				break
			var ck3: Vector3i = ck
			var aabb := _chunk_world_aabb(ck3, chunk_size_world, world_offset)
			if cam_pos.distance_to(aabb.get_center()) <= load_d:
				_streamed_out_chunks.erase(ck3)
				_rebuild_single_chunk_direct(ck3)
				reloaded += 1
	if reloaded > 0:
		_request_update()


## 流式补建：同步生成单个 chunk 网格数组并直接入 GPU 限流队列。
## 绕过异步 pipeline（_pending_task_count 串行等待 + 视锥朝向延迟），
## 补建 chunk 由 _process_mesh_build_queue 帧尾限量构建——不受"每批完成后才下一批"
## 限制，移动时网格快速出现。单 chunk 生成走原生路径 ~1ms，主线程可接受。
func _rebuild_single_chunk_direct(ck: Vector3i) -> void:
	if not data:
		return
	var has_voxels := data.has_chunk(ck)
	var arr: Dictionary = {}
	if has_voxels:
		# 构建该 chunk 的 18³ 光环缓冲并生成网格数组（原生 C++ 加速）
		var halo := data.get_chunk_halo(ck)
		var aligned := VoxelMaterial.align_by_id(_materials_snapshot)
		arr = VoxelChunkGenerator.generate_single_chunk_dense(
			halo, aligned, voxel_scale, ck, data.center_offset if data else Vector3.ZERO)
	# 直接入 GPU 限流队列（与异步结果同格式），由 _process_mesh_build_queue 帧尾构建
	_mesh_build_queue[ck] = {
		"arrays": arr,
		"has_voxels": has_voxels,
	}


## 卸载单个 chunk 网格（非超级块模式）：释放 mesh + 节点，记录到 _streamed_out_chunks


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
	# 记录性能/内存释放（诊断）
	if diag_enabled:
		print("[诊断] 流式卸载: Chunk%s" % ck)


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
		rebuild_chunks = VoxelChunkGenerator.chunks_for_dirty_voxels(data.dirty_voxels)
		# 在启动任务前清除脏体素追踪，后续新变更会重新添加，避免累积
		data.clear_dirty_voxels()
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
		# 注意：_build_and_apply_mesh 会清空 data.dirty_voxels，
		# 如果 _pending_retrigger 为 true，需要保存脏体素以便后续恢复
		var saved_dirty: Dictionary = {}
		if _pending_retrigger and data:
			saved_dirty = data.dirty_voxels.duplicate()

		_build_and_apply_mesh(arrays)

		# 恢复脏体素（用于 _on_batch_complete 中的 retrigger 逻辑）
		if _pending_retrigger and data and not saved_dirty.is_empty():
			for pos in saved_dirty:
				data.dirty_voxels[pos] = saved_dirty[pos]

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
		# chunk 已无体素，清除 mesh 并移除节点防止累积
		chunk_mesh.mesh = null
		chunk_mesh.queue_free()
		_chunk_meshes.erase(chunk_key)
	else:
		# 竞态：生成后体素被重新添加，保留已有 mesh
		has_mesh = chunk_mesh.mesh != null

	if has_voxels_in_data or _chunk_meshes.has(chunk_key):
		chunk_mesh.position = Vector3(chunk_key) * (voxel_scale * VoxelChunkGenerator.CHUNK_SIZE)
		_update_chunk_collision(chunk_key, has_mesh)
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
		var rebuild_chunks: Array[Vector3i] = VoxelChunkGenerator.chunks_for_dirty_voxels(data.dirty_voxels)
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
		data.clear_dirty_voxels()
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
			_update_chunk_collision(ck, has_mesh)
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
		data.clear_dirty_voxels()
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
	if _chunk_collisions.has(ck):
		_chunk_collisions[ck].queue_free()
		_chunk_collisions.erase(ck)