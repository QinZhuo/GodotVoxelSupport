@tool
class_name VoxelDestructible
extends VoxelRenderer

## 动态体素破坏系统
## 继承 VoxelRenderer，在渲染基础上提供体素破坏能力
## 支持球形/盒形/单体素破坏，并可选生成物理碎片
## 破坏直接修改 VoxelDataResource，自动触发 mesh 重新生成

signal voxel_damaged(positions: Array, spawn_debris: bool)

## 破坏时是否生成物理碎片
@export var spawn_debris_on_damage: bool = true

## 单次破坏生成的最大碎片数量 (性能保护)
@export var max_debris_per_hit: int = 64

## 碎片初始速度范围
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

var _debris_root: Node3D = null
var _debris_mesh_cache: Dictionary = {}  # material_id -> BoxMesh

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()


## 球形破坏: 移除中心点半径内的所有体素
## center 为体素空间坐标 (1单位 = 1体素，与 Vector3i 对应)
## radius 单位同上
## 返回被移除的体素位置数组
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	# 先记录每个体素的材质ID，再移除 (移除后无法读取)
	var mat_map := _collect_voxel_materials_in_sphere(center, radius)
	var removed := data.remove_voxels_in_sphere(center, radius)
	_on_voxels_removed(removed, mat_map, do_spawn)
	return removed


## 盒形破坏: 移除 AABB 内的所有体素
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mat_map := _collect_voxel_materials_in_box(aabb)
	var removed := data.remove_voxels_in_box(aabb)
	_on_voxels_removed(removed, mat_map, do_spawn)
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
	# 先收集所有体素的材质ID
	var mat_map := {}
	for pos in positions:
		mat_map[pos] = data.get_voxel(pos)
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


## 收集球形范围内体素的材质ID (不移除)
func _collect_voxel_materials_in_sphere(center: Vector3, radius: float) -> Dictionary:
	var mat_map := {}
	if not data:
		return mat_map
	var radius_sq := radius * radius
	for pos in data.voxels:
		if (Vector3(pos) - center).length_squared() <= radius_sq:
			mat_map[pos] = data.voxels[pos]
	return mat_map


## 收集盒形范围内体素的材质ID (不移除)
func _collect_voxel_materials_in_box(aabb: AABB) -> Dictionary:
	var mat_map := {}
	if not data:
		return mat_map
	for pos in data.voxels:
		if aabb.has_point(Vector3(pos)):
			mat_map[pos] = data.voxels[pos]
	return mat_map


## 为被破坏的体素生成物理碎片 (带材质映射)
func _spawn_debris_with_materials(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	for i in count:
		var pos: Vector3i = positions[i]
		var mat_id: int = mat_map.get(pos, -1)
		_spawn_single_debris(pos, mat_id)


func _spawn_single_debris(pos: Vector3i, mat_id: int) -> void:
	var body := RigidBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	var box_size := voxel_scale * debris_size_scale
	var box_mesh := _get_debris_mesh(mat_id, box_size)
	mesh_inst.mesh = box_mesh
	body.add_child(mesh_inst)
	# 碎片位置 (局部坐标，与 VoxelRenderer mesh 对齐)
	body.position = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	# 随机初始速度
	var speed := randf_range(debris_min_speed, debris_max_speed)
	var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1), randf_range(-1, 1)).normalized()
	body.linear_velocity = dir * speed
	body.angular_velocity = Vector3(randf_range(-5, 5), randf_range(-5, 5), randf_range(-5, 5))
	body.gravity_scale = debris_gravity_scale
	# 碰撞形状
	var shape := BoxShape3D.new()
	shape.size = Vector3(box_size, box_size, box_size)
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	_debris_root.add_child(body)
	# 生命周期到期删除
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(debris_lifetime)
		timer.timeout.connect(_remove_debris.bind(body))


func _remove_debris(body: Node) -> void:
	if body and is_instance_valid(body):
		body.queue_free()


## 缓存碎片 mesh (按材质ID)
func _get_debris_mesh(mat_id: int, size: float) -> Mesh:
	var key := mat_id
	if _debris_mesh_cache.has(key):
		var cached: Mesh = _debris_mesh_cache[key]
		return cached
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	# 设置材质颜色
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
	_debris_mesh_cache.clear()
