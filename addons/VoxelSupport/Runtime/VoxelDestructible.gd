@tool
class_name VoxelDestructible
extends VoxelRenderer

## 动态体素破坏系统
## 继承 VoxelRenderer，在渲染基础上提供体素破坏能力
## 支持球形/盒形/单体素/射线破坏 + 逐体素健康度 + 悬空崩塌 + 碎片系统
## 破坏直接修改 VoxelDataResource，自动触发 mesh 重新生成

## 破坏反馈信号：具体表现（粒子/音效/震动）由游戏自行连接实现
signal voxel_damaged(positions: Array, spawn_debris: bool)      ## 体素被移除时 (含崩塌)
signal voxel_hardened(pos: Vector3i, remaining: float)          ## 体素受伤但未摧毁 (材质硬度未达)
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

## 碎片模式枚举
enum DebrisMode {
	DEBRIS_PHYSICS,  ## 物理碎片：每个碎片是 RigidBody3D，真实物理但 Draw Call 多
	DEBRIS_VISUAL,   ## 视觉碎片：MultiMeshInstance3D 实例化，单 Draw Call 高性能
}

## 崩塌掉落模式枚举
enum CollapseMode {
	COLLAPSE_NONE,   ## 不启用悬空崩塌
	COLLAPSE_DEBRIS, ## 悬空体素转成动态碎片掉落
}

## 破坏时是否生成碎片
@export var spawn_debris_on_damage: bool = true

## 单次破坏生成的最大碎片数量 (性能保护)
@export var max_debris_per_hit: int = 64

## 碎片模式
@export var debris_mode: DebrisMode = DebrisMode.DEBRIS_PHYSICS:
	set(v):
		debris_mode = v
		_clear_debris()

## 崩塌掉落模式
@export var collapse_mode: CollapseMode = CollapseMode.COLLAPSE_DEBRIS

## 逐体素健康度系统开关：关闭时忽略材质硬度，一击即碎
@export var use_voxel_health: bool = true

## 单次破坏对每个体素造成的伤害 (逐体素健康度用)
## 结合材质 hardness，伤害累积达到 hardness 才真正移除体素
@export var damage_per_voxel: float = 1.0

## 碎片初始速度范围 (物理模式)
@export var debris_min_speed: float = 2.0
@export var debris_max_speed: float = 6.0

## 碎片生命周期 (秒) —— 落地保留的碎片不受此限制，仅影响仍在运动的碎片
@export var debris_lifetime: float = 3.0

## 碎片大小倍数 (相对于体素 scale)
@export var debris_size_scale: float = 0.9

## 碎片重力倍数
@export var debris_gravity_scale: float = 1.0

## 碎片落地判定速度阈值 (低于该速度认为静止，转静态保留)
@export var debris_rest_threshold: float = 0.5

## 碎片池大小 (物理碎片对象池，减少创建/销毁开销)
@export var debris_pool_size: int = 128

## 整体健康度 (<=0 时触发完全破坏，-1 表示不启用健康度系统)
@export var health: float = -1.0

## 监控统计
var debris_count: int = 0          ## 当前存活碎片数
var last_damage_count: int = 0     ## 最近一次破坏实际移除的体素数
var last_damage_time_ms: float = 0 ## 最近一次破坏耗时 (ms)
var last_collapse_count: int = 0   ## 最近一次崩塌的悬空体素数

## 逐体素累计伤害 (位置 -> 累计伤害)
var damage_map: Dictionary[Vector3i, float] = {}

var _debris_root: Node3D = null
var _debris_pool: Array[RigidBody3D] = []          # 物理碎片对象池 (空闲)
var _settled_debris: Array[RigidBody3D] = []       # 已落地保留的碎片
var _debris_mesh_cache: Dictionary = {}            # material_id -> BoxMesh
var _multimesh_cache: Dictionary = {}              # material_id -> MultiMesh
var _multimesh_instances: Dictionary = {}          # material_id -> MultiMeshInstance3D

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()


func _exit_tree() -> void:
	_clear_debris()


# ----------------------------------------------------------------------------
# 破坏入口
# ----------------------------------------------------------------------------

## 球形破坏: 对中心点半径内的体素造成伤害
## center 为体素空间坐标 (1单位 = 1体素)，radius 单位同上
## 返回实际被移除(彻底摧毁)的体素位置数组
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	var positions := data.get_voxels_in_sphere(center, radius)
	var mat_map := _collect_voxel_materials(positions)
	var removed := _apply_damage(positions, mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 盒形破坏
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	var positions := data.get_voxels_in_box(aabb)
	var mat_map := _collect_voxel_materials(positions)
	var removed := _apply_damage(positions, mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 单体素破坏
func damage_voxel(pos: Vector3i, spawn_debris: Variant = null) -> bool:
	if not data or not data.has_voxel(pos):
		return false
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mat_map := _collect_voxel_materials([pos])
	var removed := _apply_damage([pos], mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
	return not removed.is_empty()


## 射线破坏 (DDA)，朝指定方向破坏命中的第一个体素
func damage_ray(origin: Vector3, direction: Vector3, max_distance: float = 100.0, spawn_debris: Variant = null) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var hit := raycast_voxel(origin, direction, max_distance)
	if hit != Vector3i.MIN:
		damage_voxel(hit, spawn_debris)
	return hit


## 射线检测体素 (DDA 算法)
func raycast_voxel(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var dir := direction.normalized()
	var pos := Vector3i(floor(origin.x), floor(origin.y), floor(origin.z))
	var step := Vector3i(
		1 if dir.x > 0 else -1,
		1 if dir.y > 0 else -1,
		1 if dir.z > 0 else -1
	)
	var t_delta := Vector3(
		abs(1.0 / dir.x) if dir.x != 0 else INF,
		abs(1.0 / dir.y) if dir.y != 0 else INF,
		abs(1.0 / dir.z) if dir.z != 0 else INF
	)
	var t_max := Vector3(
		(float(pos.x + (1 if step.x > 0 else 0)) - origin.x) / dir.x if dir.x != 0 else INF,
		(float(pos.y + (1 if step.y > 0 else 0)) - origin.y) / dir.y if dir.y != 0 else INF,
		(float(pos.z + (1 if step.z > 0 else 0)) - origin.z) / dir.z if dir.z != 0 else INF
	)
	var traveled := 0.0
	while traveled < max_distance:
		if data.has_voxel(pos):
			return pos
		if t_max.x < t_max.y and t_max.x < t_max.z:
			pos.x += step.x
			traveled = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			pos.y += step.y
			traveled = t_max.y
			t_max.y += t_delta.y
		else:
			pos.z += step.z
			traveled = t_max.z
			t_max.z += t_delta.z
	return Vector3i.MIN


## 完全破坏: 移除所有体素
func destroy_all(spawn_debris: Variant = null) -> void:
	if not data:
		return
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions: Array = data.get_positions()
	var mat_map := _collect_voxel_materials(positions)
	if do_spawn and not Engine.is_editor_hint():
		_spawn_debris_with_materials(positions, mat_map)
	data.clear()
	voxel_damaged.emit(positions, do_spawn)


## 修复整体健康度
func repair(amount: float) -> void:
	if health >= 0:
		health = max(health + amount, 0.0)


# ----------------------------------------------------------------------------
# 逐体素健康度 + 伤害应用
# ----------------------------------------------------------------------------

## 对一组体素应用伤害，返回实际被彻底移除的体素
## 若开启逐体素健康度，累计伤害达到材质 hardness 才移除；否则一击即碎
func _apply_damage(positions: Array, mat_map: Dictionary, damage: float, do_spawn: bool) -> Array:
	var removed: Array = []
	var damaged_but_alive: Array = []
	for pos in positions:
		var mat_id: int = mat_map.get(pos, -1)
		if not use_voxel_health:
			removed.append(pos)
			continue
		var hardness := _get_material_hardness(mat_id)
		if hardness <= 0.0:
			removed.append(pos)
			continue
		var cur: float = float(damage_map.get(pos, 0.0)) + damage
		if cur >= hardness:
			# 伤害足够，摧毁体素
			damage_map.erase(pos)
			removed.append(pos)
		else:
			damage_map[pos] = cur
			damaged_but_alive.append([pos, hardness - cur])

	# 实际移除已摧毁的体素
	if not removed.is_empty():
		data.remove_voxels(removed)

	# 发出"受伤但未摧毁"反馈
	for entry in damaged_but_alive:
		voxel_hardened.emit(entry[0], entry[1])

	# 生成碎片 (仅对已移除的体素)
	if do_spawn and not Engine.is_editor_hint() and not removed.is_empty():
		var removed_map := {}
		for pos in removed:
			removed_map[pos] = mat_map.get(pos, -1)
		_spawn_debris_with_materials(removed, removed_map)

	last_damage_count = removed.size()
	return removed


func _get_material_hardness(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.hardness
	return 1.0


## 破坏后的统一处理：崩塌检测 + 整体健康度扣减
func _after_removal(removed: Array) -> void:
	# 触发悬空崩塌
	_trigger_collapse()
	# 整体健康度扣减
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()


# ----------------------------------------------------------------------------
# 悬空检测 + 崩塌掉落
# ----------------------------------------------------------------------------

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成动态碎片掉落
func _trigger_collapse() -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var detached := _find_detached_voxels()
	if detached.is_empty():
		return
	# 崩塌前反馈信号
	voxels_about_to_collapse.emit(detached)
	last_collapse_count = detached.size()

	# 崩塌的悬空体素转成动态碎片掉落
	var mat_map := _collect_voxel_materials(detached)
	data.remove_voxels(detached)
	if not Engine.is_editor_hint():
		_spawn_falling_debris(detached, mat_map)
	# 崩塌也算破坏，发信号
	voxel_damaged.emit(detached, true)


## 洪水填充(BFS)：从"有支撑"的体素出发标记连通体素，未被标记的即为悬空(孤立)
## 有支撑 = 位于地面(y==0) 或 正下方有体素
func _find_detached_voxels() -> Array:
	var voxels: Dictionary = data.voxels
	if voxels.is_empty():
		return []

	# 找到所有"有支撑"的体素作为 BFS 种子
	var seeds: Array = []
	var is_supported := {}
	for key in voxels:
		var pos: Vector3i = key
		var below: Vector3i = pos + Vector3i(0, -1, 0)
		if pos.y == 0 or voxels.has(below):
			seeds.append(pos)
			is_supported[pos] = true

	if seeds.is_empty():
		return []

	# BFS 从所有种子出发，标记可达（与支撑连通的）体素
	var connected := {}
	var queue: Array = []
	for seed in seeds:
		if not connected.has(seed):
			connected[seed] = true
			queue.append(seed)
	var dirs := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()
		for d: Vector3i in dirs:
			var nb := cur + d
			if voxels.has(nb) and not connected.has(nb):
				connected[nb] = true
				queue.append(nb)

	# 未被标记的体素 = 悬空
	var detached: Array = []
	for pos in voxels:
		if not connected.has(pos):
			detached.append(pos)
	return detached


# ----------------------------------------------------------------------------
# 碎片系统：生成 / 池化 / 落地保留
# ----------------------------------------------------------------------------

func _ensure_debris_root() -> void:
	if not _debris_root:
		_debris_root = Node3D.new()
		_debris_root.name = _DEBRIS_ROOT_NAME
		add_child(_debris_root, false, Node.INTERNAL_MODE_BACK)


func _collect_voxel_materials(positions: Array) -> Dictionary:
	var mat_map := {}
	if not data:
		return mat_map
	for pos in positions:
		mat_map[pos] = data.voxels[pos]
	return mat_map


func _spawn_debris_with_materials(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	if debris_mode == DebrisMode.DEBRIS_PHYSICS:
		for i in count:
			var pos: Vector3i = positions[i]
			var mat_id: int = mat_map.get(pos, -1)
			_spawn_physics_debris(pos, mat_id, false)
	else:
		_spawn_visual_debris_batch(positions, mat_map, count)


## 崩塌掉落的悬空体素 → 动态碎片 (带重力，落地保留)
func _spawn_falling_debris(positions: Array, mat_map: Dictionary) -> void:
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	if debris_mode == DebrisMode.DEBRIS_PHYSICS:
		for i in count:
			var pos: Vector3i = positions[i]
			var mat_id: int = mat_map.get(pos, -1)
			# 崩塌碎片带重力，落地后保留
			_spawn_physics_debris(pos, mat_id, true)
	else:
		# 视觉模式：崩塌碎片也走 MultiMesh，但做短暂下落 (视觉近似)
		_spawn_visual_debris_batch(positions, mat_map, count)


# --- 物理碎片 (RigidBody) + 对象池 + 落地保留 ---

func _spawn_physics_debris(pos: Vector3i, mat_id: int, is_collapse: bool) -> void:
	var box_size := voxel_scale * debris_size_scale
	var body := _acquire_debris_body(box_size)
	var mesh_inst := body.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_inst == null:
		mesh_inst = MeshInstance3D.new()
		mesh_inst.name = "MeshInstance3D"
		body.add_child(mesh_inst)
	mesh_inst.mesh = _get_debris_mesh(mat_id, box_size)
	body.position = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	if is_collapse:
		# 崩塌碎片：从原位置下落
		body.linear_velocity = Vector3(randf_range(-0.5, 0.5), -debris_min_speed, randf_range(-0.5, 0.5))
		body.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
	else:
		var speed := randf_range(debris_min_speed, debris_max_speed)
		var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1), randf_range(-1, 1)).normalized()
		body.linear_velocity = dir * speed
		body.angular_velocity = Vector3(randf_range(-5, 5), randf_range(-5, 5), randf_range(-5, 5))
	body.gravity_scale = debris_gravity_scale
	body.visible = true
	_debris_root.add_child(body)
	debris_count += 1


## 从对象池获取或创建物理碎片 (池化，减少 GC)
## box_size 为碎片碰撞体尺寸，必须与显示尺寸一致，否则碰撞范围会偏离
func _acquire_debris_body(box_size: float) -> RigidBody3D:
	var body: RigidBody3D
	if not _debris_pool.is_empty():
		body = _debris_pool.pop_back()
	else:
		body = RigidBody3D.new()
	# 更新碰撞形状尺寸，使其与显示大小一致
	var owner_ids := body.get_shape_owners()
	if owner_ids.is_empty():
		var shape := BoxShape3D.new()
		shape.size = Vector3(box_size, box_size, box_size)
		var owner_id := body.create_shape_owner(body)
		body.shape_owner_add_shape(owner_id, shape)
	else:
		for owner in owner_ids:
			if body.shape_owner_get_shape_count(owner) > 0:
				var shape: BoxShape3D = body.shape_owner_get_shape(owner, 0)
				shape.size = Vector3(box_size, box_size, box_size)
	body.sleeping = false
	return body


## 物理碎片落地后转静态保留（由 _process 每帧检查）
func _process(_delta: float) -> void:
	super._process(_delta)
	if Engine.is_editor_hint():
		return
	_settle_resting_debris()


## 检查物理碎片：落地后（物理引擎判定睡眠）转静态保留，不再被清除
## 用 RigidBody.sleeping（物理引擎在接触静止后自动判定）而非速度阈值，
## 避免碎片在空中（刚生成速度慢）被误判为静止而冻结
func _settle_resting_debris() -> void:
	if _debris_root == null:
		return
	for child in _debris_root.get_children():
		if child is RigidBody3D and child.sleeping and child.linear_velocity.length() < debris_rest_threshold:
			# 落地静止 → 转静态保留，并放到已落地列表
			child.freeze = true
			child.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			if not _settled_debris.has(child):
				_settled_debris.append(child)


## 移除碎片（落地保留的除外），释放到对象池
func _remove_physics_debris(body: Node) -> void:
	if not body or not is_instance_valid(body):
		return
	var rb := body as RigidBody3D
	# 已落地保留的碎片不回收
	if _settled_debris.has(rb):
		return
	rb.get_parent().remove_child(rb)
	if _debris_pool.size() < debris_pool_size:
		_debris_pool.append(rb)
	debris_count = maxi(0, debris_count - 1)


# --- 视觉碎片 (MultiMesh) ---

func _spawn_visual_debris_batch(positions: Array, mat_map: Dictionary, count: int) -> void:
	var box_size := voxel_scale * debris_size_scale
	var by_mat := {}
	for i in count:
		var pos: Vector3i = positions[i]
		var mat_id: int = mat_map.get(pos, -1)
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos)
	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		var mm := _get_multimesh(mat_id, box_size)
		var inst := _get_multimesh_instance(mat_id)
		for pos in list:
			var idx := mm.instance_count
			mm.instance_count = idx + 1
			mm.set_instance_transform(idx, _debris_transform(pos))
			mm.set_instance_color(idx, _get_debris_color(mat_id))
			inst.visible = true
			debris_count += 1
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(debris_lifetime)
		timer.timeout.connect(_cleanup_visual_debris.bind(count))


func _debris_transform(pos: Vector3i) -> Transform3D:
	var scale := voxel_scale * debris_size_scale
	var origin := (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	var basis := Basis(Vector3.RIGHT, randf_range(0, TAU)) * Basis(Vector3.UP, randf_range(0, TAU))
	basis = basis.scaled(Vector3(scale, scale, scale))
	return Transform3D(basis, origin)


func _get_multimesh(mat_id: int, box_size: float) -> MultiMesh:
	if _multimesh_cache.has(mat_id):
		return _multimesh_cache[mat_id]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _get_debris_mesh(mat_id, box_size)
	_multimesh_cache[mat_id] = mm
	return mm


func _get_multimesh_instance(mat_id: int) -> MultiMeshInstance3D:
	if _multimesh_instances.has(mat_id):
		var inst: MultiMeshInstance3D = _multimesh_instances[mat_id]
		if is_instance_valid(inst):
			return inst
		_multimesh_instances.erase(mat_id)
	var inst := MultiMeshInstance3D.new()
	inst.name = "DebrisMM_%d" % mat_id
	inst.multimesh = _get_multimesh(mat_id, voxel_scale * debris_size_scale)
	_debris_root.add_child(inst)
	_multimesh_instances[mat_id] = inst
	return inst


func _get_debris_color(mat_id: int) -> Color:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.color
	return Color.WHITE


func _cleanup_visual_debris(count: int) -> void:
	var remaining := count
	for mat_id in _multimesh_cache:
		var mm: MultiMesh = _multimesh_cache[mat_id]
		if mm.instance_count <= 0:
			continue
		var remove_n := mini(mm.instance_count, remaining)
		mm.instance_count -= remove_n
		debris_count = maxi(0, debris_count - remove_n)
		remaining -= remove_n
		if remaining <= 0:
			break


func _get_debris_mesh(mat_id: int, size: float) -> Mesh:
	if _debris_mesh_cache.has(mat_id):
		return _debris_mesh_cache[mat_id]
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var mat_res = data.materials[mat_id]
		if mat_res:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = mat_res.color
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			box.material = mat
	_debris_mesh_cache[mat_id] = box
	return box


func _clear_debris() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	debris_count = 0
	_settled_debris.clear()
	_debris_mesh_cache.clear()
	_multimesh_cache.clear()
	_multimesh_instances.clear()
