@tool
class_name VoxelCollision
extends Node3D

## 碰撞组件：把宿主的 chunk 网格转成静态碰撞体（每个 chunk 一个
## `StaticBody3D + CollisionShape3D(ConcavePolygonShape3D)`）。
##
## 【负责】建 / 删 / 复用碰撞体，以及**每帧限量**的重建调度：
##   从 `MeshInstance3D.mesh.get_faces()` 取面点填进 `ConcavePolygonShape3D`。
## 【不负责】
##   · 网格生成 —— 那是宿主（`VoxelRenderer`）的事，本组件只在网格已就绪后取面；
##   · "要不要碰撞"的语义 —— 要不要把 chunk 交给本组件由宿主决定（宿主关掉碰撞时
##     不调用 `enqueue`，并调 `clear_all()`）；
##   · 破坏/编辑后的重建触发 —— 宿主在网格应用完成后 `enqueue(ck, true/false)` 即可。
## 【依赖方向】
##   · 宿主 → 本组件：`configure(host)` / `enqueue(ck, has_mesh)` / `remove(ck)` / `clear_all()`。
##   · 本组件 → 宿主：**只读**公开面 `host.lod_mesh(0, ck)`（内核契约「按 chunk 索引·查」）
##     与 `host.voxel_scale`。**不碰宿主私有成员**（无 `host._xxx`）。
## 【为什么是宿主的子节点】
##   宿主的 chunk 网格节点也是它的子节点，位置 = `Vector3(ck) * (voxel_scale * CHUNK_SIZE)`。
##   本组件作为子节点（identity 变换）后碰撞体可用**同一套局部坐标**，不必做世界坐标换算，
##   并且随宿主移动 / 原点漂移自动跟随（`shift_render` 只需要重排子节点位置策略）。
## 【为什么必须限流（数量 + 毫秒双限）】
##   `Mesh.get_faces()` 会把索引三角形**展开**成面点数组（一次全量分配 + 遍历），
##   单块 32³ chunk 约 10~15 ms。只按块数限流仍可能一帧堆 12 块 → 百毫秒级尖峰，
##   所以数量上限之外再加毫秒预算，预算到点就停，宁可分几帧建完。

## 碰撞体所属物理层（3D 物理层位掩码，第 1 层 = 1）。
@export var collision_layer: int = 1
## 碰撞体检测的物理层（3D 物理层位掩码，第 1 层 = 1）。
@export var collision_mask: int = 1

## 每帧最多重建的 chunk 数（数量限流）。
@export_range(1, 100, 1) var rebuild_per_frame: int = 12

## 每帧碰撞重建的时间预算（毫秒）。0 = 只受 `rebuild_per_frame` 限制。
## 【为什么不是"只按块数"】见文件头：单块 `get_faces()` + `set_faces()` 是毫秒级的，
## 固定块数在 32³ chunk 上等于放弃预算控制。
@export_range(0.0, 100.0, 0.5) var rebuild_budget_ms: float = 4.0

## 宿主（只读上下文来源；由 `configure()` 绑定，之后不变）。
var host: VoxelRenderer = null

## 总开关：关闭后不再建新碰撞体、也不再消费队列（已建的保留到 `clear_all()`）。
## 宿主切换自己的 `generate_collision` 时同步置它，避免"关掉碰撞后队列还在长"。
var enabled: bool = true

## 最近一次单块碰撞重建耗时（毫秒，含 `get_faces()`），供宿主 HUD / 诊断显示。
var last_build_ms: float = 0.0

## chunk 容器：ck -> StaticBody3D。子节点归本组件所有，`clear_all()` 一并释放。
var _bodies: Dictionary[Vector3i, StaticBody3D] = {}
## 重建队列：ck -> 该 chunk 当前是否**有网格**（false = 需要在应用时移除碰撞体）。
## 用 Dictionary 去重：同一 chunk 连续多次入队只保留最后一次状态。
var _queue: Dictionary[Vector3i, bool] = {}


func _ready() -> void:
	# 组件由宿主 `add_child` 创建，此时 get_parent() 一定是宿主能做的最早时机；
	# 但宿主也可能在 add_child 前就调了 configure()，故只在未绑定时兜底。
	_bind_if_needed()


## 绑定宿主。可重复调用（幂等）；换宿主时清空旧账本。
## 【为什么首次绑定不清队列】宿主可能在 `configure()` 之前就 `enqueue()`（先入队再 add_child）。
## 首次绑定时的队列属于**同一个**宿主，清掉就会丢待办 → 那些 chunk 永远没有碰撞体（且不报错）。
## 只有"换宿主"才清，那时旧账本确实失效。
func configure(host_ref: VoxelRenderer) -> void:
	if host == host_ref:
		return
	if host != null:
		clear_all()
	host = host_ref


## 把某个 chunk 交给本组件处理（幂等去重，状态以最后一次为准）。
## [param has_mesh] false 表示该 chunk 已无网格 → 应用时释放它的碰撞体。
func enqueue(ck: Vector3i, has_mesh: bool) -> void:
	if not enabled:
		return
	# 先兜底绑定：宿主可能先 enqueue 再 add_child，此时 get_parent() 还没宿主。
	_bind_if_needed()
	_queue[ck] = has_mesh


## 立即移除某个 chunk 的碰撞体（并丢弃它在队列里的待办）。
func remove(ck: Vector3i) -> void:
	_queue.erase(ck)
	if _bodies.has(ck):
		var body: StaticBody3D = _bodies[ck]
		_bodies.erase(ck)
		if body != null and is_instance_valid(body):
			body.queue_free()


## 释放全部碰撞体与队列（宿主清理网格 / 退出 / 关闭碰撞时调用）。
func clear_all() -> void:
	_queue.clear()
	for ck in _bodies:
		var body: StaticBody3D = _bodies[ck]
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
	var keys := _queue.keys()
	for ck in keys:
		if built >= rebuild_per_frame:
			break
		# 至少建一个（单块本身可能就超预算），之后才按时间预算截断。
		if built > 0 and budget_us > 0 and Time.get_ticks_usec() - started_us >= budget_us:
			break
		var has_mesh: bool = _queue[ck]
		_queue.erase(ck)
		_apply_chunk(ck, has_mesh)
		built += 1


# ── 内部：单块应用 ────────────────────────────────────────────────────────────

## 应用单个 chunk：有网格就（复用）建碰撞形状，没网格就移除。
func _apply_chunk(ck: Vector3i, has_mesh: bool) -> void:
	if not has_mesh:
		remove(ck)
		return
	# 【碰撞只对"一 chunk 一个网格"成立】本组件的几何来源是 mesh.get_faces()，然后按
	# `Vector3(ck) * chunk_size` 摆到该 chunk 的位置 —— 这只有在"这块 mesh 恰好只覆盖这一个
	# chunk"时才对。而 STATIC 模式整份模型只有一个 mesh（chunk_mesh 返回宿主自身）、DYNAMIC
	# 分组模式下绘制单元是整个 group：拿它们当单 chunk 碰撞源会生成**错位的巨型碰撞体**。
	# 这类模式下直接不生成（与重构前"查不到节点 → remove"的实际行为一致，只是从静默变显式）。
	if not _supports_chunk_collision():
		remove(ck)
		return
	var mi := chunk_mesh(ck)
	if mi == null or mi.mesh == null:
		remove(ck)
		return
	var started_us := Time.get_ticks_usec()
	# 【这是唯一昂贵的一步】get_faces() 把索引三角形展开成逐面点数组。
	var faces := mi.mesh.get_faces()
	if faces.is_empty():
		# 有 mesh 但无顶点（空 chunk 残留）→ 不该有碰撞体
		remove(ck)
		return
	var body := _ensure_body(ck)
	# 位置与对应 chunk 网格节点严格一致（同一套局部坐标）。
	body.position = Vector3(ck) * _chunk_world_size()
	_apply_shape(body, faces)
	last_build_ms = float(Time.get_ticks_usec() - started_us) / 1000.0


## 取某个 chunk 的网格节点 —— 唯一来源是内核的公开查询 `host.chunk_mesh(ck)`。
## 【为什么不再有兜底】这里曾先试 `lod_mesh(0, ck)`，查不到再按 "Chunk_x_y_z" 遍历宿主子节点。
## 两点都已删：① 内核早就有 `chunk_mesh(ck)`，它把 STATIC / DYNAMIC 分组 / per-chunk 三种
## 账本归一成一个查询，本组件不该再自己判断宿主用哪套账本；② 那个兜底是**热路径上的
## O(子节点数) 遍历**（每帧应用若干 chunk，宿主可能有上千子节点），且把内核的节点命名当成契约
## —— 命名一改就静默查不到（表现为"碰撞时有时无"，最难查的一类症状）。
func chunk_mesh(ck: Vector3i) -> MeshInstance3D:
	if host == null:
		return null
	var mi := host.chunk_mesh(ck)
	return mi if mi != null and is_instance_valid(mi) else null


## 当前宿主配置下"网格与 chunk 是否一一对应"——碰撞形状的构建前提。
## 只有 DYNAMIC + per-chunk（group_shift == 0）满足：此时每个 chunk 一个 MeshInstance3D。
func _supports_chunk_collision() -> bool:
	if host == null:
		return false
	return host.draw_mode == VoxelRenderer.DrawMode.DYNAMIC and host.group_shift == 0


## 单个 chunk 的世界边长（= 体素边长 × chunk 体素数）。
func _chunk_world_size() -> float:
	var scale := host.voxel_scale if host != null else 0.1
	return scale * VoxelChunk.CHUNK_SIZE


## 取（必要时创建）chunk 的 StaticBody3D，并同步物理层/遮罩。
func _ensure_body(ck: Vector3i) -> StaticBody3D:
	var body: StaticBody3D = _bodies.get(ck)
	if body != null and is_instance_valid(body):
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask
		return body
	body = StaticBody3D.new()
	body.name = "Collision_%d_%d_%d" % [ck.x, ck.y, ck.z]
	body.collision_layer = collision_layer
	body.collision_mask = collision_mask
	add_child(body)
	_bodies[ck] = body
	return body


## 把面点写进该 body 的 CollisionShape3D。
## 【为什么复用 shape 对象】`ConcavePolygonShape3D.set_faces()` 原地替换面数据，
## 物理服务器只需重建这一块的 BVH；每帧 new 一个 shape 会多一次形状注册/注销，
## 而且 `CollisionShape3D.shape` 换对象会触发物理体重新挂接（破坏期间是热路径）。
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
## 【为什么必须同步节点】只平移键会让 StaticBody3D 停留在旧世界坐标（碰撞与视觉错位），
## 而新键处又会重复建体 → 幽灵碰撞体。
func on_origin_shift(shift: Vector3i, chunk_size_world: float) -> void:
	if shift == Vector3i.ZERO:
		return
	_queue = VoxelChunk.shift_key_dict(_queue, shift)
	var moved: Dictionary[Vector3i, StaticBody3D] = {}
	for k in _bodies:
		var nck: Vector3i = Vector3i(k) + shift
		var body: StaticBody3D = _bodies[k]
		if body != null and is_instance_valid(body):
			body.position = Vector3(nck) * chunk_size_world
			body.name = "Collision_%d_%d_%d" % [nck.x, nck.y, nck.z]
		moved[nck] = body
	_bodies = moved

