@tool
class_name VoxelDataResource
extends Resource

## 可序列化的体素数据资源
## 用于运行时动态渲染、修改和破坏体素
## 可由 VoxelRenderer / VoxelDestructible 节点使用
## 与 VoxelData 不同，此资源专为序列化和运行时使用设计
## 注: 直接使用 Resource 内置的 changed 信号 (通过 emit_changed() 发射)

## 体素字典: 位置 -> 材质ID
@export var voxels: Dictionary[Vector3i, int] = {}

## 材质数组 (索引即材质ID，使用 VoxelMaterial)
@export var materials: Array[VoxelMaterial] = []

## 帧数量 (保留用于未来动画扩展)
@export var frame_count: int = 1

## 缩放比例 (仅作为导入时的默认值，实际渲染缩放由 VoxelRenderer 控制)
@export var default_scale: float = 0.1


## 从 VoxelData 构造 (编辑器导入时使用)
static func from_voxel_data(voxel_data: VoxelData, frame_index: int = 0) -> VoxelDataResource:
	var res := VoxelDataResource.new()
	res.voxels = voxel_data.get_voxels(frame_index)
	for mat in voxel_data.materials:
		var new_mat := VoxelMaterial.new()
		new_mat.id = mat.id
		new_mat.color = mat.color
		new_mat.trans = mat.trans
		new_mat.metal = mat.metal
		new_mat.rough = mat.rough
		new_mat.emission = mat.emission
		res.materials.append(new_mat)
	return res


## 获取指定位置的体素材质ID，不存在返回 -1
func get_voxel(pos: Vector3i) -> int:
	return voxels.get(pos, -1)


## 设置指定位置的体素 (material_id < 0 时移除)
func set_voxel(pos: Vector3i, material_id: int, notify: bool = true) -> void:
	if material_id < 0:
		voxels.erase(pos)
	else:
		voxels[pos] = material_id
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	voxels.erase(pos)
	if notify:
		emit_changed()


## 是否存在体素
func has_voxel(pos: Vector3i) -> bool:
	return voxels.has(pos)


## 获取所有体素位置
func get_positions() -> Array:
	return voxels.keys()


## 获取体素数量
func get_voxel_count() -> int:
	return voxels.size()


## 清空所有体素
func clear(notify: bool = true) -> void:
	voxels.clear()
	if notify:
		emit_changed()


## 合并另一个资源中的体素 (可带偏移)
func merge(other: VoxelDataResource, offset: Vector3i = Vector3i.ZERO, notify: bool = true) -> void:
	for pos in other.voxels:
		voxels[pos + offset] = other.voxels[pos]
	if notify:
		emit_changed()


## 移除球形范围内的所有体素 (用于破坏系统)
func remove_voxels_in_sphere(center: Vector3, radius: float, notify: bool = true) -> Array[Vector3i]:
	var removed: Array[Vector3i] = []
	var radius_sq := radius * radius
	var keys := voxels.keys()
	for pos in keys:
		if (Vector3(pos) - center).length_squared() <= radius_sq:
			removed.append(pos)
			voxels.erase(pos)
	if notify and not removed.is_empty():
		emit_changed()
	return removed


## 移除盒形范围内的所有体素 (用于破坏系统)
func remove_voxels_in_box(aabb: AABB, notify: bool = true) -> Array[Vector3i]:
	var removed: Array[Vector3i] = []
	var keys := voxels.keys()
	for pos in keys:
		if aabb.has_point(Vector3(pos)):
			removed.append(pos)
			voxels.erase(pos)
	if notify and not removed.is_empty():
		emit_changed()
	return removed


## 获取材质 (索引越界返回 null)
func get_material(index: int) -> Resource:
	if index >= 0 and index < materials.size():
		return materials[index]
	return null


## 获取所有材质的浅拷贝 (用于 VoxelMeshGenerator)
func get_materials_array() -> Array:
	return materials.duplicate(false)


## 触发 changed 信号 (批量修改后手动调用)
func notify_changed() -> void:
	emit_changed()
