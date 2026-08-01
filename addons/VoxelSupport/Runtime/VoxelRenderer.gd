@tool
class_name VoxelRenderer
extends MeshInstance3D

const _CHUNK_GENERATOR := preload("res://addons/VoxelSupport/VoxelChunkGenerator.gd")

## 体素专属渲染器
## 持有 VoxelDataResource，在运行时动态生成并更新 mesh
## 监听数据变化自动重新生成，支持运行时动态修改体素
## 提供与编辑器导入等价的纹理材质 (基于材质ID的UV采样)
## 支持异步网格生成：体素数据在后台线程生成，主线程不阻塞

signal mesh_updated

## 体素数据资源
@export var data: VoxelDataResource:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储
		if data and data.changed.is_connected(_on_data_changed):
			data.changed.disconnect(_on_data_changed)
		data = v
		if data:
			data.changed.connect(_on_data_changed)
		_materials_cache.clear()
		_request_update()

## 体素缩放比例 (单个体素的边长，世界单位)
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		_request_update()

## 数据变化时是否自动重新生成 mesh
@export var auto_update: bool = true

## 重建限流帧数：一帧内多次数据变化会被合并，最多每 N 帧重建一次 mesh
## 对大型动态场景(如水模拟)可显著降低重建频率，值越大越流畅但更新越滞后
@export_range(1, 30) var update_throttle_frames: int = 1

## 是否使用高性能 Chunk 生成器（增量重建）
## 开启后体素按 16³ chunk 分区生成，体素变化时只重建受影响 chunk，大型动态场景性能更好
## 默认开启，自动分块处理；关闭则使用全局生成（中小场景兼容）
@export var use_chunk_generator: bool = true:
	set(v):
		use_chunk_generator = v
		_request_update()

## 是否异步生成网格（后台线程生成，避免阻塞主线程，对大型场景体验更佳）
## 关闭则回退为在 _process 主线程同步生成
@export var async_generate: bool = true:
	set(v):
		async_generate = v
		if not v:
			_cancel_async()
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

# 异步网格生成状态
var _task_id := -1
var _pending_arrays: Variant = null
var _has_pending := false
var _generation_id := 0

const _COLLISION_BODY_NAME := "_VoxelRendererCollision"


func _ready() -> void:
	_request_update()


func _process(_delta: float) -> void:
	# 异步任务完成后，轮询并应用结果（在主线程执行，保证安全）
	if _has_pending and _task_id >= 0 and WorkerThreadPool.is_task_completed(_task_id):
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		var arrays := _pending_arrays
		_pending_arrays = null
		_has_pending = false
		_build_and_apply_mesh(arrays)

	if not (_dirty and auto_update and (not Engine.is_editor_hint() or update_in_editor)):
		return
	# 限流：合并帧内多次变更，最多每 update_throttle_frames 帧重建一次
	_update_counter += 1
	if _update_counter < update_throttle_frames:
		return
	_update_counter = 0
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
	_request_update()


## 获取当前体素数据
func get_data() -> VoxelDataResource:
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


## 取消尚未完成的异步网格生成任务
func _cancel_async() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_generation_id += 1
	_has_pending = false
	_pending_arrays = null


func _update_mesh() -> void:
	_dirty = false
	if not data:
		_cancel_async()
		mesh = null
		_clear_collision()
		mesh_updated.emit()
		return

	# 生成纹理材质 (缓存，材质变化时需手动调用 regenerate_materials)
	if _materials_cache.is_empty() or _materials_cache[0] == null:
		_materials_cache = VoxelMeshGenerator.generate_textured_materials_runtime(data.materials)

	if async_generate:
		_update_mesh_async()
	else:
		_update_mesh_sync()


## 异步路径：后台线程生成网格数据，完成后在 _process 轮询应用
func _update_mesh_async() -> void:
	# 若上一轮异步任务仍在运行，等待其结束（限流已保证频率不会过高）
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1

	# 快照本次要生成的体素数据（子线程只读，避免与主线程写入竞争）
	var snapshot_voxels := data.voxels.duplicate()
	var snapshot_materials := data.materials.duplicate(true)
	var rebuild_chunks: Array[Vector3i] = []
	if use_chunk_generator:
		rebuild_chunks = _CHUNK_GENERATOR.chunks_for_dirty_voxels(data.dirty_voxels)
	var gen_id := _generation_id + 1
	_generation_id = gen_id

	_has_pending = false
	_pending_arrays = null
	# 后台线程生成纯数据（线程安全，不触碰 ArrayMesh）
	_task_id = WorkerThreadPool.add_task(_generate_worker.bind(snapshot_voxels, snapshot_materials, rebuild_chunks, gen_id))


## 后台工作线程入口：生成网格数据并写入结果缓冲
## 主线程通过 _process 轮询 WorkerThreadPool.is_task_completed 后读取，保证线程安全
func _generate_worker(voxels: Dictionary, materials: Array, rebuild_chunks: Array, gen_id: int) -> void:
	var options := {
		"scale": voxel_scale,
	}
	var arrays: Variant = _CHUNK_GENERATOR.generate_arrays_runtime(voxels, materials, options, rebuild_chunks)
	# 仅在 gen_id 仍有效时写入结果（避免覆盖更新的任务）
	if gen_id == _generation_id:
		_pending_arrays = arrays
		_has_pending = true


## 同步路径：主线程直接生成并应用（兼容模式）
func _update_mesh_sync() -> void:
	var options := {
		"scale": voxel_scale,
	}
	var rebuild_chunks: Array[Vector3i] = []
	if use_chunk_generator:
		rebuild_chunks = _CHUNK_GENERATOR.chunks_for_dirty_voxels(data.dirty_voxels)
	var arrays := _CHUNK_GENERATOR.generate_arrays_runtime(data.voxels, data.materials, options, rebuild_chunks)
	_build_and_apply_mesh(arrays)


## 将网格数据组装为 ArrayMesh 并应用到节点（必须主线程）
func _build_and_apply_mesh(arrays: Variant) -> void:
	var new_mesh: ArrayMesh
	if arrays != null and arrays is Dictionary and not arrays.is_empty():
		new_mesh = _CHUNK_GENERATOR.build_mesh_from_arrays(arrays as Dictionary)
		# 给 chunk mesh 的两个表面赋材质（实心/透明）
		if new_mesh:
			if new_mesh.get_surface_count() > 0 and _materials_cache[0]:
				new_mesh.surface_set_material(0, _materials_cache[0])
			if new_mesh.get_surface_count() > 1 and _materials_cache[1]:
				new_mesh.surface_set_material(1, _materials_cache[1])

	if new_mesh:
		mesh = new_mesh
	else:
		mesh = null

	if generate_collision:
		_update_collision()
	else:
		_clear_collision()

	# 重建完成，清空变更追踪
	if data:
		data.clear_dirty_voxels()
	mesh_updated.emit()


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
