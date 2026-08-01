@tool
class_name VoxelDestructible
extends VoxelRenderer

## 动态体素破坏系统
## 继承 VoxelRenderer，在渲染基础上提供体素破坏能力
## 支持球形/盒形/单体素破坏，并可选生成碎片
## 破坏直接修改 VoxelDataResource，自动触发 mesh 重新生成
## 碎片提供两种模式：物理模式(RigidBody) 与 视觉模式(MultiMesh 实例化，高性能)

signal voxel_damaged(positions: Array, spawn_debris: bool)

## 碎片模式枚举
enum DebrisMode {
	DEBRIS_PHYSICS,  ## 物理碎片：每个碎片是 RigidBody3D，真实物理但 Draw Call 多
	DEBRIS_VISUAL,   ## 视觉碎片：MultiMeshInstance3D 实例化，单 Draw Call 高性能
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

## 碎片初始速度范围 (物理模式)
@export var debris_min_speed: float = 2.0
@export var debris_max_speed: float = 6.0

## 碎片生命周期 (秒)
@export var debris_lifetime: float = 3.0

## 碎片大小倍数 (相对于体素 scale)
@export var debris_size_scale: float = 0.9

## 碎片重力倍数
@export var debris_gravity_scale: float = 1.0

## 整体健康度 (<=0 时触发完全破坏，-1 表示不启用健康度系统)
@export var health: float = -1.0

## 监控统计
var debris_count: int = 0          ## 当前存活碎片数
var last_damage_count: int = 0     ## 最近一次破坏移除的体素数
var last_damage_time_ms: float = 0 ## 最近一次破坏耗时 (ms)

var _debris_root: Node3D = null
var _debris_mesh_cache: Dictionary = {}      # material_id -> BoxMesh
var _multimesh_cache: Dictionary = {}        # material_id -> MultiMesh
var _multimesh_instances: Dictionary = {}    # material_id -> MultiMeshInstance3D

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()


func _exit_tree() -> void:
	_clear_debris()


## 球形破坏: 移除中心点半径内的所有体素
## center 为体素空间坐标 (1单位 = 1体素，与 Vector3i 对应)
## radius 单位同上，返回被移除的体素位置数组
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	# 先记录每个体素的材质ID，再移除 (移除后无法读取)
	var mat_map := _collect_voxel_materials(data.get_voxels_in_sphere(center, radius))
	var removed := data.remove_voxels_in_sphere(center, radius)
	_on_voxels_removed(removed, mat_map, do_spawn)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 盒形破坏: 移除 AABB 内的所有体素
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	var mat_map := _collect_voxel_materials(data.get_voxels_in_box(aabb))
	var removed := data.remove_voxels_in_box(aabb)
	_on_voxels_removed(removed, mat_map, do_spawn)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 单体素破坏
func damage_voxel(pos: Vector3i, spawn_debris: Variant = null) -> bool:
	if not data or not data.has_voxel(pos):
		return false
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mat_id := data.get_voxel(pos)
	data.remove_voxel(pos)
	_on_voxels_removed([pos], {pos: mat_id}, do_spawn)
	return true


## 统一的破坏后处理：发射信号、生成碎片、扣减健康度
func _on_voxels_removed(removed: Array, mat_map: Dictionary, do_spawn: bool) -> void:
	if removed.is_empty():
		return
	voxel_damaged.emit(removed, do_spawn)
	if do_spawn and not Engine.is_editor_hint():
		_spawn_debris_with_materials(removed, mat_map)
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()


## 射线检测破坏 (从原点沿方向射线，命中第一个体素并移除)
## 返回被破坏的体素位置，未命中返回 Vector3i.MIN
func damage_ray(origin: Vector3, direction: Vector3, max_distance: float = 100.0, spawn_debris: Variant = null) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var hit := raycast_voxel(origin, direction, max_distance)
	if hit != Vector3i.MIN:
		damage_voxel(hit, spawn_debris)
	return hit


## 射线检测体素 (DDA 算法)
## origin/direction 为体素空间坐标，返回命中的体素位置
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


## 完全破坏: 移除所有体素并生成碎片
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


## 修复: 恢复健康度 (不会恢复已破坏的体素，需配合外部数据源)
func repair(amount: float) -> void:
	if health >= 0:
		health = max(health + amount, 0.0)


func _ensure_debris_root() -> void:
	if not _debris_root:
		_debris_root = Node3D.new()
		_debris_root.name = _DEBRIS_ROOT_NAME
		add_child(_debris_root, false, Node.INTERNAL_MODE_BACK)


## 收集指定位置集合的材质ID (不移除)
## 供各破坏方法统一使用，避免重复的"范围筛选 + 材质收集"逻辑
func _collect_voxel_materials(positions: Array) -> Dictionary:
	var mat_map := {}
	if not data:
		return mat_map
	for pos in positions:
		mat_map[pos] = data.voxels[pos]
	return mat_map


## 为被破坏的体素生成碎片 (带材质映射)，按材质模式分发
func _spawn_debris_with_materials(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	last_damage_count = count
	if debris_mode == DebrisMode.DEBRIS_PHYSICS:
		for i in count:
			var pos: Vector3i = positions[i]
			var mat_id: int = mat_map.get(pos, -1)
			_spawn_physics_debris(pos, mat_id)
	else:
		_spawn_visual_debris_batch(positions, mat_map, count)


# ----------------------------------------------------------------------------
# 物理碎片模式 (RigidBody3D，真实物理)
# ----------------------------------------------------------------------------

func _spawn_physics_debris(pos: Vector3i, mat_id: int) -> void:
	var body := RigidBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	var box_size := voxel_scale * debris_size_scale
	var box_mesh := _get_debris_mesh(mat_id, box_size)
	mesh_inst.mesh = box_mesh
	body.add_child(mesh_inst)
	body.position = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	var speed := randf_range(debris_min_speed, debris_max_speed)
	var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1), randf_range(-1, 1)).normalized()
	body.linear_velocity = dir * speed
	body.angular_velocity = Vector3(randf_range(-5, 5), randf_range(-5, 5), randf_range(-5, 5))
	body.gravity_scale = debris_gravity_scale
	var shape := BoxShape3D.new()
	shape.size = Vector3(box_size, box_size, box_size)
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	_debris_root.add_child(body)
	debris_count += 1
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(debris_lifetime)
		timer.timeout.connect(_remove_physics_debris.bind(body))


func _remove_physics_debris(body: Node) -> void:
	if body and is_instance_valid(body):
		body.queue_free()
		debris_count = maxi(0, debris_count - 1)


# ----------------------------------------------------------------------------
# 视觉碎片模式 (MultiMeshInstance3D 实例化，高性能)
# ----------------------------------------------------------------------------

## 批量生成视觉碎片：按材质 ID 分组到各自的 MultiMeshInstance3D (单 Draw Call)
func _spawn_visual_debris_batch(positions: Array, mat_map: Dictionary, count: int) -> void:
	var box_size := voxel_scale * debris_size_scale
	# 按材质分组
	var by_mat := {}
	for i in count:
		var pos: Vector3i = positions[i]
		var mat_id: int = mat_map.get(pos, -1)
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos)
	# 每组生成/复用 MultiMesh 实例
	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		var mm := _get_multimesh(mat_id, box_size)
		var inst := _get_multimesh_instance(mat_id)
		# 把新碎片追加到 MultiMesh (从 instance_count 开始分配新索引)
		for pos in list:
			var idx := mm.instance_count
			mm.instance_count = idx + 1
			mm.set_instance_transform(idx, _debris_transform(pos))
			mm.set_instance_color(idx, _get_debris_color(mat_id))
			inst.visible = true
			debris_count += 1
	# 用定时器清理 (渐进移除旧实例，避免一次性清空闪烁)
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(debris_lifetime)
		timer.timeout.connect(_cleanup_visual_debris.bind(count))


## 计算碎片实例变换 (位置 + 随机旋转)
func _debris_transform(pos: Vector3i) -> Transform3D:
	var scale := voxel_scale * debris_size_scale
	var origin := (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	# 随机旋转
	var basis := Basis(Vector3.RIGHT, randf_range(0, TAU)) * Basis(Vector3.UP, randf_range(0, TAU))
	basis = basis.scaled(Vector3(scale, scale, scale))
	return Transform3D(basis, origin)


## 获取或创建材质对应的 MultiMesh
func _get_multimesh(mat_id: int, box_size: float) -> MultiMesh:
	if _multimesh_cache.has(mat_id):
		return _multimesh_cache[mat_id]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _get_debris_mesh(mat_id, box_size)
	_multimesh_cache[mat_id] = mm
	return mm


## 获取或创建材质对应的 MultiMeshInstance3D
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


## 碎片颜色 (用材质基础色)
func _get_debris_color(mat_id: int) -> Color:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.color
	return Color.WHITE


## 清理指定数量的视觉碎片实例 (从每个 MultiMesh 末尾移除)
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


## 缓存碎片 mesh (按材质ID)
func _get_debris_mesh(mat_id: int, size: float) -> Mesh:
	var key := mat_id
	if _debris_mesh_cache.has(key):
		var cached: Mesh = _debris_mesh_cache[key]
		return cached
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var mat_res = data.materials[mat_id]
		if mat_res:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = mat_res.color
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			box.material = mat
	_debris_mesh_cache[key] = box
	return box


func _clear_debris() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	debris_count = 0
	_debris_mesh_cache.clear()
	_multimesh_cache.clear()
	_multimesh_instances.clear()
