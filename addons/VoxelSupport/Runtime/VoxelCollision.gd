@tool
class_name VoxelCollision
extends Node3D

## 碰撞组件：把宿主的**绘制单元**转成静态碰撞体（每个单元一个

## 碰撞体所属物理层（3D 物理层位掩码，第 1 层 = 1）。
@export var collision_layer: int = 1
## 碰撞体检测的物理层（3D 物理层位掩码，第 1 层 = 1）。
@export var collision_mask: int = 1

## 每帧最多重建的绘制单元数（数量限流）。
@export_range(1, 100, 1) var rebuild_per_frame: int = 12

## 每帧碰撞重建的时间预算（毫秒）。
@export_range(0.0, 100.0, 0.5) var rebuild_budget_ms: float = 4.0

## 宿主（只读上下文来源；由 `configure()` 绑定，之后不变）。
var host: VoxelRenderer = null

## 总开关：关闭后不再建新碰撞体、也不再消费队列（已建的保留到 `clear_all()`）。
var enabled: bool = true

## 碰撞体容器：unit_key -> StaticBody3D。
var _bodies: Dictionary[Vector3i, StaticBody3D] = {}
## 重建队列：unit_key -> 一个**属于该单元**的代表 chunk（应用时用它向宿主查网格）。
var _queue: Dictionary[Vector3i, Vector3i] = {}

func _ready() -> void:
	# 组件由宿主 `add_child` 创建，此时 get_parent() 一定是宿主能做的最早时机；
	_bind_if_needed()

## 绑定宿主。
func configure(host_ref: VoxelRenderer) -> void:
	if host == host_ref:
		return
	if host != null:
		clear_all()
	host = host_ref

## 把某个 chunk 交给本组件处理（幂等去重，状态以最后一次为准）。
func enqueue(ck: Vector3i, has_mesh: bool) -> void:
	if not enabled:
		return
	# 先兜底绑定：宿主可能先 enqueue 再 add_child，此时 get_parent() 还没宿主。
	_bind_if_needed()
	if host == null:
		return
	var u := _unit_of(ck)
	if has_mesh:
		_queue[u] = ck
	elif not _queue.has(u):
		# 无网格：仍需让应用阶段去**核对**一次（可能同单元别的 chunk 还有网格，
		_queue[u] = ck

## 立即处理某个 chunk 所属单元（移除 / 重新核对）。
func remove(ck: Vector3i) -> void:
	if host == null:
		return
	var u := _unit_of(ck)
	_queue.erase(u)
	if _is_per_chunk():
		_release(u)
		return
	_queue[u] = ck

## 释放全部碰撞体与队列（宿主清理网格 / 退出 / 关闭碰撞时调用）。
func clear_all() -> void:
	_queue.clear()
	for u in _bodies:
		var body: StaticBody3D = _bodies[u]
		if body != null and is_instance_valid(body):
			body.queue_free()
	_bodies.clear()

func _process(_delta: float) -> void:
	if not enabled or _queue.is_empty():
		return
	_bind_if_needed()
	if host == null:
		return

	var built := 0
	var budget_us := int(rebuild_budget_ms * 1000.0)
	var started_us := Time.get_ticks_usec()
	# 【先取 keys 快照】循环体里会 erase 队列，直接遍历字典键在部分引擎版本上不安全。
	var units := _queue.keys()
	for u in units:
		if built >= rebuild_per_frame:
			break
		# 至少建一个（单个单元本身可能就超预算），之后才按时间预算截断。
		if built > 0 and budget_us > 0 and Time.get_ticks_usec() - started_us >= budget_us:
			break
		var rep: Vector3i = _queue.get(u, Vector3i.ZERO)
		_queue.erase(u)
		_apply_unit(u, rep)
		built += 1

# ── 内部：单元抽象 ───────────────────────────────────────────────────────────…

## DYNAMIC + group_shift=0 → 每个 chunk 就是自己的绘制单元。
func _is_per_chunk() -> bool:
	return host != null and host.draw_mode == VoxelRenderer.DrawMode.DYNAMIC and host.group_shift == 0

## chunk → 它所属的绘制单元键（与宿主几何账本的键完全一致）。
func _unit_of(ck: Vector3i) -> Vector3i:
	if host == null or _is_per_chunk():
		return ck
	if host.draw_mode == VoxelRenderer.DrawMode.STATIC:
		return Vector3i.ZERO
	return VoxelMesher.group_of(ck, host.group_shift)

## 单元的局部原点（与宿主给该单元几何节点设置的位置口径一致）。
func _unit_origin(u: Vector3i) -> Vector3:
	if host == null:
		return Vector3.ZERO
	var chunk_world := host.voxel_scale * VoxelChunk.CHUNK_SIZE
	if host.draw_mode == VoxelRenderer.DrawMode.STATIC:
		# 整份 mesh 挂在宿主自己身上，碰撞体也以宿主原点为准
		return Vector3.ZERO
	if _is_per_chunk():
		return Vector3(u) * chunk_world
	return Vector3(u) * (chunk_world * float(1 << host.group_shift))

func _apply_unit(u: Vector3i, rep: Vector3i) -> void:
	var mi := chunk_mesh(rep)
	if mi == null or mi.mesh == null:
		_release(u)
		return
	# 【这是唯一昂贵的一步】get_faces() 把索引三角形展开成逐面点数组。
	var faces := mi.mesh.get_faces()
	if faces.is_empty():
		# 有 mesh 但无顶点（空单元残留）→ 不该有碰撞体
		_release(u)
		return
	var body := _ensure_body(u)
	# 位置与对应几何节点严格一致（同一套局部坐标）。
	body.position = _unit_origin(u)
	_apply_shape(body, faces)

## 取某个 chunk 的网格节点 —— 唯一来源是内核的公开查询 `host.chunk_mesh(ck)`。
func chunk_mesh(ck: Vector3i) -> MeshInstance3D:
	if host == null:
		return null
	var mi := host.chunk_mesh(ck)
	return mi if mi != null and is_instance_valid(mi) else null

## 释放某个单元的碰撞体（幂等）。
func _release(u: Vector3i) -> void:
	if not _bodies.has(u):
		return
	var body: StaticBody3D = _bodies[u]
	_bodies.erase(u)
	if body != null and is_instance_valid(body):
		body.queue_free()

## 取（必要时创建）单元的 StaticBody3D，并同步物理层/遮罩。
func _ensure_body(u: Vector3i) -> StaticBody3D:
	var body: StaticBody3D = _bodies.get(u)
	if body != null and is_instance_valid(body):
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask
		return body
	body = StaticBody3D.new()
	body.name = "Collision_%d_%d_%d" % [u.x, u.y, u.z]
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	add_child(body)
	_bodies[u] = body
	return body

## 把面点写进该 body 的 CollisionShape3D。
func _apply_shape(body: StaticBody3D, faces: PackedVector3Array) -> void:
	var shape_node: CollisionShape3D = null
	if body.get_child_count() > 0 and body.get_child(0) is CollisionShape3D:
		shape_node = body.get_child(0)
	if shape_node == null:
		shape_node = CollisionShape3D.new()
		body.add_child(shape_node)
	if shape_node.shape is ConcavePolygonShape3D:
		(shape_node.shape as ConcavePolygonShape3D).set_faces(faces)
	else:
		# shape 被外部换成了别的类型（例如项目自己的凸包）：改回凹面形状。
		var new_shape := ConcavePolygonShape3D.new()
		new_shape.set_faces(faces)
		shape_node.shape = new_shape

## 惰性绑定：宿主在 `_ready` 里 `add_child` 本组件即可，无需显式 configure。
func _bind_if_needed() -> void:
	if host != null:
		return
	var parent := get_parent()
	if parent is VoxelRenderer:
		configure(parent as VoxelRenderer)

## origin shift 时由宿主调用：键平移**且**节点位置/名字同步。
func on_origin_shift(shift: Vector3i, _chunk_size_world: float = 0.0) -> void:
	if shift == Vector3i.ZERO:
		return
	_queue = VoxelChunk.shift_key_dict(_queue, shift)
	var moved: Dictionary[Vector3i, StaticBody3D] = {}
	for k in _bodies:
		var nk: Vector3i = Vector3i(k) + shift
		var body: StaticBody3D = _bodies[k]
		if body != null and is_instance_valid(body):
			body.position = _unit_origin(nk)
			body.name = "Collision_%d_%d_%d" % [nk.x, nk.y, nk.z]
		moved[nk] = body
	_bodies = moved
