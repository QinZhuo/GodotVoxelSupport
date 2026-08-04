@tool
class_name VoxelRenderer
extends MeshInstance3D

## 体素专属渲染器
## 持有 VoxelData，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)
## 支持异步网格生成：体素数据在后台线程生成，主线程不阻塞
## 
## 两种渲染模式（通过 use_chunk_generator 切换）：
## - Per-chunk 模式（默认）：每个非空 chunk 对应一个子 MeshInstance3D，体素变化时只增量重建
##   受影响 chunk，大型场景性能更好
## - 组合模式：所有体素合并为一个 ArrayMesh，适合中小场景

signal mesh_updated

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

## 是否使用 Per-chunk 模式（增量重建）
## 开启后每个非空 chunk 对应一个子 MeshInstance3D，体素变化时只重建受影响 chunk
## 关闭则使用全局生成（所有体素合并为一个 ArrayMesh），适合中小场景
@export var use_chunk_generator: bool = true:
	set(v):
		use_chunk_generator = v
		_clear_chunk_meshes()
		_request_update()

## 是否异步生成网格（后台线程生成，避免阻塞主线程，对大型场景体验更佳）
## 关闭则回退为在 _process 主线程同步生成
@export var async_generate: bool = true:
	set(v):
		async_generate = v
		if not v:
			_cancel_async()
		_clear_chunk_meshes()
		_request_update()

## 是否生成静态碰撞体 (StaticBody3D + ConcavePolygonShape3D)
@export var generate_collision: bool = false:
	set(v):
		generate_collision = v
		_request_update()

## 是否在编辑器中也实时更新 (仅 @tool 模式)
@export var update_in_editor: bool = true

var _dirty: bool = false
var _materials_cache: Array = []
var _collision_body: StaticBody3D = null
var _update_counter: int = 0

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

# 持久切片缓存：chunk_key -> {pos: mat_id}（chunk 内部 + 1 体素外缘快照）
# 由脏体素增量维护，避免每次重建都扫描 17³ 区域 + 对整世界大字典做 has() 查询。
# 派发任务时 duplicate(false) 交给子线程（值类型，浅拷贝即独立），主线程可安全继续改缓存。
var _chunk_slice_cache: Dictionary = {}

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


func _process(_delta: float) -> void:
	# 异步任务结果通过 call_deferred 直接传递到 _on_thread_result，无需轮询
	# 这里只处理限流和启动新任务

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
func force_update() -> void:
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

	if async_generate:
		_update_mesh_async()
	else:
		_update_mesh_sync()


## 异步路径：后台线程生成网格数据，完成后通过 call_deferred 直接传递结果到主线程
## 主线程绝不阻塞：旧任务未完成时直接启动新任务覆盖，子线程完成后检查 gen_id 丢弃过期结果
func _update_mesh_async() -> void:
	# 若旧任务已完成但还未轮询应用（极端情况），不阻塞，直接启动新任务覆盖
	# 旧任务子线程完成后会因 gen_id 不匹配而不写入结果（自然丢弃）

	# 【分块快照方案】不深拷贝整个世界字典，而是为每个需要重建的 chunk 提取其
	# 局部体素切片（chunk 内部 + 1 体素外缘）。每个子线程只读取自己那个私有的小快照，
	# 主线程后续增删 data.voxels 不与之冲突，杜绝数据竞态（块随机显示/隐藏的根因），
	# 同时避免整世界深拷贝的性能与内存开销。
	var rebuild_chunks: Array[Vector3i] = []
	if use_chunk_generator:
		rebuild_chunks = VoxelChunkGenerator.chunks_for_dirty_voxels(data.dirty_voxels)
		# 先按脏体素增量更新切片缓存（须在 clear_dirty_voxels 之前），
		# 之后派发时直接复用缓存切片，避免每次都对整世界大字典做 17³ 扫描。
		_apply_dirty_to_slice_cache(data.dirty_voxels)
		# 在启动任务前清除脏体素追踪，后续新变更会重新添加，避免累积
		data.clear_dirty_voxels()
	# 材质快照复用缓存（仅在材质变化时深拷贝），避免每帧大对象深拷贝
	var snapshot_materials := _materials_snapshot
	var gen_id := _generation_id + 1
	_generation_id = gen_id
	# 渲染居中偏移（体素单位），子线程无权访问节点，随任务参数传入
	var render_offset: Vector3 = data.center_offset if data else Vector3.ZERO

	_task_ids.clear()
	_pending_task_count = 0

	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	# 将 use_chunk_generator 和 voxel_scale 作为参数传入，避免子线程访问节点属性
	#
	# 每个脏 chunk 独立一个线程任务，WorkerThreadPool 内部管理并发数
	if use_chunk_generator:
		# chunk 模式：每个任务只处理一个 chunk，为其提取私有的局部体素切片
		# 单任务路径（全量/空场景）仅当没有可拆分 chunk 时兜底使用，需要完整体素
		if rebuild_chunks.is_empty():
			# 全量构建（初始构建或切换模式后）：分 chunk 独立线程，逐个显示
			# 而不是等所有 chunk 生成完毕再一起显示
			var all_chunks := VoxelChunkGenerator.get_all_non_empty_chunk_keys(data.voxels)
			if all_chunks.is_empty():
				# 没有非空 chunk，使用单任务路径（空场景），此时无体素无竞态
				_pending_task_count = 1
				_task_ids.append(WorkerThreadPool.add_task(_generate_worker.bind(
					{}, snapshot_materials, rebuild_chunks, gen_id, use_chunk_generator, voxel_scale, render_offset)))
			else:
				print("[诊断] 全量构建 gen_id=%d: %d 个 Chunk，分块独立线程" % [gen_id, all_chunks.size()])
				_pending_task_count = all_chunks.size()
				for ck in all_chunks:
					var slice_voxels := _get_chunk_slice(ck)
					_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
						slice_voxels, snapshot_materials, ck, gen_id, voxel_scale, render_offset)))
		else:
			# 增量重建：每个 chunk 独立一个线程任务，真正并行处理
			print("[诊断] 增量重建 gen_id=%d: %d 个脏 Chunk" % [gen_id, rebuild_chunks.size()])
			_pending_task_count = rebuild_chunks.size()
			for ck in rebuild_chunks:
				var slice_voxels := _get_chunk_slice(ck)
				_task_ids.append(WorkerThreadPool.add_task(_generate_chunk_worker.bind(
					slice_voxels, snapshot_materials, ck, gen_id, voxel_scale, render_offset)))
	else:
		# 单任务路径（非 chunk 模式）：需要整个世界体素，深拷贝一次快照
		_pending_task_count = 1
		var snapshot_voxels: Dictionary = data.voxels.duplicate(true)
		_task_ids.append(WorkerThreadPool.add_task(_generate_worker.bind(
			snapshot_voxels, snapshot_materials, rebuild_chunks, gen_id, use_chunk_generator, voxel_scale, render_offset)))


## 获取（并缓存）chunk 的局部体素切片快照。
## 已缓存则复用缓存，避免每次重建都对整世界大字典做 17³=4913 次 has() 扫描；
## 未缓存则从当前数据构建一次并存入缓存。
## 返回独立副本（duplicate(false)，值类型键值即完整拷贝），供子线程安全读取，
## 主线程随后仍可继续增量修改缓存，无数据竞态。
func _get_chunk_slice(ck: Vector3i) -> Dictionary:
	if _chunk_slice_cache.has(ck):
		return _chunk_slice_cache[ck].duplicate(false)
	var slice := VoxelChunkGenerator.slice_chunk(data.voxels, ck)
	_chunk_slice_cache[ck] = slice
	return slice.duplicate(false)


## 按脏体素增量维护切片缓存（在 clear_dirty_voxels 之前调用）。
## 对每个变更位置，把增删同步到所有"切片范围覆盖该位置"的 chunk 缓存，
## 从而避免下次重建时对同一 chunk 重新扫描整个 17³ 区域。
## 体素位于 chunk 边界时会影响相邻 chunk 的切片（外缘 1 体素），因此候选为
## 自身 chunk + 边界方向相邻 chunk（每轴至多 2 个，至多 8 个 chunk）。
func _apply_dirty_to_slice_cache(dirty: Dictionary) -> void:
	if dirty.is_empty():
		return
	for pos_key in dirty:
		var p: Vector3i = pos_key
		var mat_id: int = dirty[pos_key]
		for ck in _candidate_slice_chunks(p):
			if _chunk_slice_cache.has(ck):
				if mat_id < 0:
					var s: Dictionary = _chunk_slice_cache[ck]
					s.erase(p)
					if s.is_empty():
						_chunk_slice_cache.erase(ck)
				else:
					_chunk_slice_cache[ck][p] = mat_id


## 找出所有"切片范围覆盖位置 p"的 chunk key（自身 + 边界相邻，至多 8 个）
static func _candidate_slice_chunks(p: Vector3i) -> Array[Vector3i]:
	var CS := VoxelChunkGenerator.CHUNK_SIZE
	var c0 := Vector3i(floori(float(p.x) / float(CS)), floori(float(p.y) / float(CS)), floori(float(p.z) / float(CS)))
	var xs := [c0.x]
	var ys := [c0.y]
	var zs := [c0.z]
	if posmod(p.x, CS) == 0:
		xs.append(c0.x - 1)
	elif posmod(p.x, CS) == CS - 1:
		xs.append(c0.x + 1)
	if posmod(p.y, CS) == 0:
		ys.append(c0.y - 1)
	elif posmod(p.y, CS) == CS - 1:
		ys.append(c0.y + 1)
	if posmod(p.z, CS) == 0:
		zs.append(c0.z - 1)
	elif posmod(p.z, CS) == CS - 1:
		zs.append(c0.z + 1)
	var result: Array[Vector3i] = []
	for x in xs:
		for y in ys:
			for z in zs:
				result.append(Vector3i(x, y, z))
	return result


## 后台工作线程入口：生成网格数据并写入结果缓冲
## 主线程通过 _process 轮询 WorkerThreadPool.is_task_completed 后读取，保证线程安全
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
func _generate_worker(voxels: Dictionary, materials: Array, rebuild_chunks: Array, gen_id: int,
		use_chunk: bool, scale: float, offset: Vector3 = Vector3.ZERO) -> void:
	var result: Dictionary = {}

	# 增量重建路径：每个 chunk 的顶点使用局部坐标，生成独立子 MeshInstance3D
	if use_chunk:
		var t0 := Time.get_ticks_usec()
		var chunk_arrays: Dictionary
		var affected_count := rebuild_chunks.size()
		if rebuild_chunks.is_empty():
			# 无脏体素时全量生成所有非空 chunk（初始构建或切换模式后）
			if gen_id <= 1:
				print("[诊断] 初始全量构建（gen_id=%d）..." % gen_id)
			chunk_arrays = VoxelChunkGenerator.generate_all_chunks_arrays_runtime(
				voxels, materials, {"scale": scale, "offset": offset})
			affected_count = chunk_arrays.size()
			print("[诊断] 全量构建完成: %d 个非空 Chunk" % affected_count)
		else:
			# P1: 并行生成多个 chunk
			print("[诊断] 增量重建 gen_id=%d: %d 个脏 Chunk" % [gen_id, rebuild_chunks.size()])
			chunk_arrays = _generate_chunks_parallel(voxels, materials, scale, rebuild_chunks, offset)
		var gen_time_ms := (Time.get_ticks_usec() - t0) / 1000.0
		# 统计顶点/三角形数
		var sv := 0; var tv := 0
		for ck in chunk_arrays:
			var arr = chunk_arrays[ck]
			if arr is Dictionary:
				sv += arr.get("solid_verts", PackedVector3Array()).size()
				tv += arr.get("trans_verts", PackedVector3Array()).size()
		result = {
			"arrays": chunk_arrays,
			"gen_time_ms": gen_time_ms,
			"solid_vertices": sv,
			"trans_vertices": tv,
			"total_chunks": chunk_arrays.size(),
			"affected_count": affected_count,
			"gen_id": gen_id,
		}
	else:
		# 全量重建路径：所有体素合并为一个 ArrayMesh
		var t1 := Time.get_ticks_usec()
		var arrays: Variant = VoxelChunkGenerator.generate_arrays_runtime(voxels, materials, {"scale": scale, "offset": offset})
		var gen_time_ms := (Time.get_ticks_usec() - t1) / 1000.0
		var sv := 0; var tv := 0
		if arrays is Dictionary:
			sv = arrays.get("solid_verts", PackedVector3Array()).size()
			tv = arrays.get("trans_verts", PackedVector3Array()).size()
		result = {
			"arrays": arrays,
			"gen_time_ms": gen_time_ms,
			"solid_vertices": sv,
			"trans_vertices": tv,
			"total_chunks": 1,
			"affected_count": 1,
			"gen_id": gen_id,
		}

	# 使用 call_deferred 将结果传回主线程（线程安全，仅排队到主线程消息队列，不直接操作 Node 属性）
	call_deferred("_on_thread_result", result)


## 单 chunk 工作线程入口：每个脏 chunk 独立一个线程任务，真正并行处理
## 每个 chunk 独立生成网格数据，完成后通过 call_deferred 直接传回主线程
## 注意：此函数在子线程中运行，不能访问除参数外的节点属性！
func _generate_chunk_worker(voxels: Dictionary, materials: Array, chunk_key: Vector3i,
		gen_id: int, scale: float, offset: Vector3 = Vector3.ZERO) -> void:
	var t0 := Time.get_ticks_usec()
	var aligned := VoxelMaterial.align_by_id(materials)
	var _align_time := (Time.get_ticks_usec() - t0) / 1000.0
	var arr := VoxelChunkGenerator.generate_single_chunk_array(voxels, aligned, scale, chunk_key, offset)
	var gen_time_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# 诊断：每 chunk 生成耗时 > 5ms 时打印（含 align_by_id 开销）
	if gen_time_ms > 5.0:
		print("[诊断] _generate_chunk_worker: Chunk%s, align=%.2fms, 总=%.2fms" % [chunk_key, _align_time, gen_time_ms])

	# 统计顶点数
	var sv := 0
	var tv := 0
	if not arr.is_empty():
		sv = arr.get("solid_verts", PackedVector3Array()).size()
		tv = arr.get("trans_verts", PackedVector3Array()).size()

	# 构建结果字典（包含 chunk_key 供 _apply_single_chunk_result 识别单个 chunk）
	var result: Dictionary = {
		"arrays": {},
		"chunk_key": chunk_key,
		"gen_time_ms": gen_time_ms,
		"solid_vertices": sv,
		"trans_vertices": tv,
		"total_chunks": 1 if not arr.is_empty() else 0,
		"affected_count": 1,
		"gen_id": gen_id,
	}
	if not arr.is_empty():
		result["arrays"][chunk_key] = arr

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
		if _t_ms > 0.5:
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

	# 更新统计信息
	last_mesh_gen_time_ms = gen_time_ms
	last_solid_vertices = result.get("solid_vertices", 0)
	last_trans_vertices = result.get("trans_vertices", 0)
	last_solid_triangles = last_solid_vertices / 3
	last_trans_triangles = last_trans_vertices / 3
	last_total_chunks = result.get("total_chunks", 0)
	last_rebuild_affected_count = 1
	last_rebuild_chunk_count = 1

	# 单 chunk 结果（来自 _generate_chunk_worker）
	if chunk_key.x != -999:
		var arr = arrays.get(chunk_key, {})
		var has_voxels_in_data := false
		if data:
			var _t1 := Time.get_ticks_usec()
			var current_voxels: Array = data.get_chunk_voxels(chunk_key)
			_t_get_chunk = (Time.get_ticks_usec() - _t1) / 1000.0
			has_voxels_in_data = not current_voxels.is_empty()

		# 获取或创建该 chunk 的子 MeshInstance3D
		var chunk_mesh: MeshInstance3D
		if _chunk_meshes.has(chunk_key):
			chunk_mesh = _chunk_meshes[chunk_key]
		else:
			chunk_mesh = MeshInstance3D.new()
			chunk_mesh.name = "Chunk_%d_%d_%d" % [chunk_key.x, chunk_key.y, chunk_key.z]
			add_child(chunk_mesh)
			_chunk_meshes[chunk_key] = chunk_mesh

		# 构建或清空 mesh，同时清理空 chunk 节点防止累积
		var has_mesh := false
		if arr is Dictionary and not arr.is_empty() and has_voxels_in_data:
			var new_mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr as Dictionary)
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
			# has_voxels_in_data 为 true 但 arr 为空（竞态：生成后体素被重新添加）
			# 保留已有 mesh，等待下一帧重建
			has_mesh = chunk_mesh.mesh != null

		# Per-chunk 碰撞体：
		# - 有体素数据时按正常流程更新
		# - 节点已被清理时直接移除碰撞体
		if has_voxels_in_data or _chunk_meshes.has(chunk_key):
			chunk_mesh.position = Vector3(chunk_key) * (voxel_scale * VoxelChunkGenerator.CHUNK_SIZE)
			_update_chunk_collision(chunk_key, has_mesh)
		else:
			_remove_chunk_collision(chunk_key)

		# 记录性能
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
	if _t_apply_ms > 1.0 and chunk_key.x != -999:
		print("[诊断] _apply_single_chunk_result: Chunk%s, get_chunk=%.2fms, 总=%.2fms" % [chunk_key, _t_get_chunk, _t_apply_ms])


## 批次完成清理：当所有任务都完成后执行
## 处理 _pending_retrigger 并发出 mesh_updated 信号
## 空 Chunk 清理已在 _apply_single_chunk_result 中增量完成，无需全量遍历
func _on_batch_complete() -> void:
	# 处理 _pending_retrigger（极少情况下被外部设置）
	if _pending_retrigger:
		_pending_retrigger = false
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

	# Per-chunk 增量重建
	if use_chunk_generator:
		var rebuild_chunks: Array[Vector3i] = VoxelChunkGenerator.chunks_for_dirty_voxels(data.dirty_voxels)
		last_rebuild_affected_count = rebuild_chunks.size()
		var t0 := Time.get_ticks_usec()
		var chunk_arrays: Dictionary
		if rebuild_chunks.is_empty():
			chunk_arrays = VoxelChunkGenerator.generate_all_chunks_arrays_runtime(
				data.voxels, data.materials, options)
			last_rebuild_affected_count = chunk_arrays.size()
		else:
			chunk_arrays = VoxelChunkGenerator.generate_chunks_arrays_runtime(
				data.voxels, data.materials, options, rebuild_chunks)
		last_mesh_gen_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
		# 统计顶点/三角形数
		var sv := 0; var tv := 0
		for ck in chunk_arrays:
			var arr = chunk_arrays[ck]
			if arr is Dictionary:
				sv += arr.get("solid_verts", PackedVector3Array()).size()
				tv += arr.get("trans_verts", PackedVector3Array()).size()
		last_solid_vertices = sv; last_trans_vertices = tv
		last_solid_triangles = sv / 3; last_trans_triangles = tv / 3
		last_total_chunks = chunk_arrays.size()
		_build_and_apply_chunk_meshes(chunk_arrays)
		# _build_and_apply_chunk_meshes 内部在 mesh_updated 前设置了 last_apply_time_ms
		_record_perf_stats(last_rebuild_affected_count, last_mesh_gen_time_ms, last_apply_time_ms)
		return

	# 全量重建（组合模式）
	var t1 := Time.get_ticks_usec()
	var arrays := VoxelChunkGenerator.generate_arrays_runtime(data.voxels, data.materials, options)
	last_mesh_gen_time_ms = (Time.get_ticks_usec() - t1) / 1000.0
	if arrays is Dictionary:
		last_solid_vertices = arrays.get("solid_verts", PackedVector3Array()).size()
		last_trans_vertices = arrays.get("trans_verts", PackedVector3Array()).size()
		last_solid_triangles = last_solid_vertices / 3
		last_trans_triangles = last_trans_vertices / 3
		last_total_chunks = 1
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
	for ck in _chunk_meshes:
		_chunk_meshes[ck].queue_free()
	_chunk_meshes.clear()
	_chunk_slice_cache.clear()
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

	# 诊断：记录重建规模
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
				print("[诊断] Chunk %s 不在重建列表且已无体素，清除旧 Mesh" % ck)
				_chunk_meshes[ck].queue_free()
				_chunk_meshes.erase(ck)
				_remove_chunk_collision(ck)

	if cleared_count > 0:
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