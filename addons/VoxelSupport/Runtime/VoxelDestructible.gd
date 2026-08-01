@tool
class_name VoxelDestructible
extends VoxelRenderer

const _CHUNK_GEN := preload("res://addons/VoxelSupport/VoxelChunkGenerator.gd")

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

## 支撑强度系数：单个支撑接触体素能承受的重量
## 支撑强度分析用：块重量 > 支撑点数 × 该系数 时，判定支撑不足而断裂崩塌
## 值越小越容易断裂（需更多支撑），实心结构建议较高以保证稳定
@export var collapse_support_strength: float = 15.0

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

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成整块刚体掉落
## 支持"支撑强度分析"：与主结构/地面只有少量接触、重量超出支撑能力的块也会自动断裂崩塌
func _trigger_collapse() -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var unstable := _find_unstable_voxels()
	if unstable.is_empty():
		return
	# 崩塌前反馈信号
	voxels_about_to_collapse.emit(unstable)
	last_collapse_count = unstable.size()

	# 崩塌的悬空/支撑不足体素转成"整块刚体"掉落（按连通块分组）
	var mat_map := _collect_voxel_materials(unstable)
	data.remove_voxels(unstable)
	if not Engine.is_editor_hint():
		_spawn_collapse_blocks(unstable, mat_map)
	# 崩塌也算破坏，发信号
	voxel_damaged.emit(unstable, true)


## 找出所有"失稳"体素（与地面断开 + 支撑不足的块），返回这些体素位置的并集
## 通过支撑强度分析：对每个连通块，计算重量 vs 支撑接触点，
## 无支撑（完全悬空）或支撑不足（重量超出支撑能力）的块判定为失稳
func _find_unstable_voxels() -> Array:
	var voxels: Dictionary = data.voxels
	if voxels.is_empty():
		return []

	# 把所有体素按 6 方向连通分量分组
	var blocks := _partition_all_connected_blocks(voxels)

	# 每个块独立判定稳定性
	var unstable_set := {}
	for block in blocks:
		if _is_block_unstable(block, voxels):
			for p in block:
				unstable_set[p] = true

	var unstable: Array = []
	for key in unstable_set:
		unstable.append(key)
	return unstable


## 判定一个连通块是否失稳（无支撑 或 支撑不足）
func _is_block_unstable(block: Array, all_voxels: Dictionary) -> bool:
	if block.is_empty():
		return false
	var block_set := {}
	for p in block:
		block_set[p] = true

	var total_mass := 0.0
	var support_points := 0
	for p in block:
		var pos: Vector3i = p
		total_mass += _get_material_mass(all_voxels[pos])
		# 支撑接触点：该体素下方是地面(y==0) 或下方是"外部块"体素(不在本块且存在)
		var below := pos + Vector3i(0, -1, 0)
		var has_external_support := all_voxels.has(below) and not block_set.has(below)
		if below.y < 0 or has_external_support:
			support_points += 1

	# 无任何支撑接触 → 完全悬空，失稳
	if support_points == 0:
		return true
	# 有支撑但支撑能力 < 块质量 → 支撑不足，失稳断裂
	var support_capacity := float(support_points) * collapse_support_strength
	return total_mass > support_capacity


## 把所有体素按 6 方向连通性分组为连通块
func _partition_all_connected_blocks(voxels: Dictionary) -> Array:
	var blocks: Array = []
	var visited := {}
	var dirs := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	]
	for key in voxels:
		var start: Vector3i = key
		if visited.has(start):
			continue
		var block: Array = []
		var queue: Array = [start]
		visited[start] = true
		while not queue.is_empty():
			var cur: Vector3i = queue.pop_front()
			block.append(cur)
			for d: Vector3i in dirs:
				var nb := cur + d
				if voxels.has(nb) and not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		blocks.append(block)
	return blocks


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


## 崩塌掉落的悬空体素 → 按连通块分组，每个块作为一个整块刚体塌落
## 避免悬空体素"整体消失"，而是作为完整块从原位置落下
func _spawn_collapse_blocks(positions: Array, mat_map: Dictionary) -> void:
	_ensure_debris_root()
	if positions.is_empty():
		return
	# 将悬空体素按 6 方向连通分量分组
	var blocks := _partition_connected_blocks(positions)
	for block in blocks:
		_spawn_collapse_block(block, mat_map)


## 将体素位置集合按 6 方向连通性分组
func _partition_connected_blocks(positions: Array) -> Array:
	var result: Array = []
	var visited := {}
	var all_pos := {}
	for p in positions:
		all_pos[p] = true
	var dirs := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	]
	for key in all_pos:
		var start: Vector3i = key
		if visited.has(start):
			continue
		var block: Array = []
		var queue: Array = [start]
		visited[start] = true
		while not queue.is_empty():
			var cur: Vector3i = queue.pop_front()
			block.append(cur)
			for d: Vector3i in dirs:
				var nb := cur + d
				if all_pos.has(nb) and not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		result.append(block)
	return result


## 生成一个整块刚体：用 VoxelChunkGenerator 生成与掉落前一致的贪婪合并 mesh，从质心下落
## body 位于 _debris_root 原点，mesh/碰撞用体素绝对坐标，保证整块与掉落前外观一致
func _spawn_collapse_block(block: Array, mat_map: Dictionary) -> void:
	if block.is_empty():
		return
	# 用块的体素构建临时数据并生成贪婪合并 mesh（与原体素块外观完全一致）
	var block_voxels: Dictionary[Vector3i, int] = {}
	for p in block:
		var pos: Vector3i = p
		block_voxels[pos] = mat_map.get(pos, -1)
	var options := {"scale": voxel_scale}
	var arrays: Variant = _CHUNK_GEN.generate_arrays_runtime(block_voxels, data.materials, options)
	if arrays == null:
		return
	var arr_mesh: ArrayMesh = _CHUNK_GEN.build_mesh_from_arrays(arrays as Dictionary)
	# 给整块 mesh 赋材质（复用与原体素一致的纹理材质，保证颜色正确）
	_apply_mesh_materials(arr_mesh)

	# 计算块包围盒质心（用于下落旋转中心）
	var min_pos := Vector3(99999, 99999, 99999)
	var max_pos := Vector3(-99999, -99999, -99999)
	for p in block:
		var pos: Vector3i = p
		min_pos = min_pos.min(Vector3(pos))
		max_pos = max_pos.max(Vector3(pos))
	var center := (min_pos + max_pos) * 0.5 + Vector3(0.5, 0.5, 0.5)  # 块中心（体素空间）

	var body := RigidBody3D.new()
	# 整块质量 = 块内体素质量之和（材质质量影响塌落物理表现）
	var block_mass := _compute_block_mass(block, mat_map)
	body.mass = maxf(block_mass, 0.01)
	# 组合碰撞形状：每个体素一个独立的 shape owner + BoxShape，偏移到体素绝对位置（相对 body 原点）
	for p in block:
		var pos: Vector3i = p
		var shape := BoxShape3D.new()
		shape.size = Vector3(voxel_scale, voxel_scale, voxel_scale)
		var oid := body.create_shape_owner(body)
		body.shape_owner_add_shape(oid, shape)
		body.shape_owner_set_transform(oid, Transform3D.IDENTITY.translated(
			(Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale))

	# 整块显示：贪婪合并 mesh（顶点为体素绝对坐标，与 body 原点对齐）
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	body.add_child(mesh_inst)

	body.position = Vector3.ZERO
	# 整块从质心缓慢下落，带轻微随机旋转；质量越大越"沉重"
	body.linear_velocity = Vector3(randf_range(-0.3, 0.3), -debris_min_speed * 0.5, randf_range(-0.3, 0.3))
	body.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	body.gravity_scale = debris_gravity_scale
	body.sleeping = false
	body.set_meta("_born_ms", Time.get_ticks_msec())
	_debris_root.add_child(body)
	debris_count += 1


## 计算块的质量（块内体素质量之和）
func _compute_block_mass(block: Array, mat_map: Dictionary) -> float:
	var total := 0.0
	for p in block:
		var pos: Vector3i = p
		var mat_id: int = mat_map.get(pos, -1)
		total += _get_material_mass(mat_id)
	return total


func _get_material_mass(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.mass
	return 1.0


## 给整块 mesh 赋材质：复用与原体素一致的纹理材质 (VoxelMeshGenerator 生成的 PBR 材质)
## 保证崩塌整块与原体素块颜色/材质完全一致
var _block_mat_cache: Array = []

func _apply_mesh_materials(arr_mesh: ArrayMesh) -> void:
	if arr_mesh == null:
		return
	if _block_mat_cache.is_empty():
		_block_mat_cache = VoxelMeshGenerator.generate_textured_materials_runtime(data.materials)
	for i in arr_mesh.get_surface_count():
		if i < _block_mat_cache.size() and _block_mat_cache[i] != null:
			arr_mesh.surface_set_material(i, _block_mat_cache[i])


## 崩塌掉落的悬空体素 → 动态碎片 (带重力，落地保留)  [兼容：散碎片模式，非默认]
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
	# 设置速度会自动唤醒 RigidBody；显式清除睡眠确保物理启动
	body.sleeping = false
	# 记录出生时间，用于出生保护期（避免刚生成就被误判冻结）
	body.set_meta("_born_ms", Time.get_ticks_msec())
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
		if child is RigidBody3D:
			var rb := child as RigidBody3D
			# 出生保护期：刚生成的碎片（<0.5秒）不冻结，确保物理有时间作用下落
			if rb.has_meta("_born_ms") and Time.get_ticks_msec() - rb.get_meta("_born_ms") < 500:
				continue
			if rb.sleeping and rb.linear_velocity.length() < debris_rest_threshold:
				# 落地静止 → 转静态保留，并放到已落地列表
				rb.freeze = true
				rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				if not _settled_debris.has(rb):
					_settled_debris.append(rb)


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
			return VoxelMaterial.albedo_color(m)
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
			# 碎片材质复用原体素材质的完整 PBR 属性 (颜色/金属/粗糙/自发光)，
			# 保证光照下颜色与原体素块一致
			var mat := StandardMaterial3D.new()
			mat.albedo_color = VoxelMaterial.albedo_color(mat_res)
			mat.metallic = mat_res.metal
			mat.roughness = mat_res.rough
			mat.emission_enabled = mat_res.emission > 0.0
			mat.emission = VoxelMaterial.emission_color(mat_res)
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			if mat_res.trans > 0:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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
