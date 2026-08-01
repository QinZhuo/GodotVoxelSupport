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

## 体素网格尺寸 (体素个数，由导入时计算)
@export var grid_size: Vector3i = Vector3i.ZERO

## 缩放比例 (仅作为导入时的默认值，实际渲染缩放由 VoxelRenderer 控制)
@export var default_scale: float = 0.1


## 从 VoxelData 构造 (编辑器导入时使用)
static func from_voxel_data(voxel_data: VoxelData, frame_index: int = 0) -> VoxelDataResource:
	var res := VoxelDataResource.new()
	var raw_voxels := voxel_data.get_voxels(frame_index)
	
	# 重新映射体素坐标到 [0, grid_size) 范围
	# VoxelNode.get_voxels() 中的 transform 包含 VoxelModel.offset 平移
	# 导致体素数据范围在 [offset, offset + size) 之间
	# 需要重新映射到 [0, size) 以匹配 grid_size
	if not raw_voxels.is_empty():
		var min_pos := Vector3i(999999, 999999, 999999)
		var max_pos := Vector3i(-999999, -999999, -999999)
		for pos in raw_voxels:
			min_pos.x = mini(min_pos.x, pos.x)
			min_pos.y = mini(min_pos.y, pos.y)
			min_pos.z = mini(min_pos.z, pos.z)
			max_pos.x = maxi(max_pos.x, pos.x)
			max_pos.y = maxi(max_pos.y, pos.y)
			max_pos.z = maxi(max_pos.z, pos.z)
		
		# 重新映射：将所有体素位置减去 min_pos
		for pos_key in raw_voxels.keys():
			var pos: Vector3i = pos_key
			var new_pos: Vector3i = pos - min_pos
			res.voxels[new_pos] = raw_voxels[pos_key]
		
		res.grid_size = max_pos - min_pos + Vector3i(1, 1, 1)
	else:
		res.voxels = raw_voxels
		res.grid_size = Vector3i(voxel_data.size)
	
	# 材质数组按材质 ID 对齐存储，确保 res.voxels 中的材质ID能直接作为数组索引
	# (体素值 = 材质ID = data.materials 数组索引，这是 VoxelMeshGenerator 的约定)
	for mat in voxel_data.materials:
		var new_mat := VoxelMaterial.new()
		new_mat.id = mat.id
		new_mat.color = mat.color
		new_mat.trans = mat.trans
		new_mat.metal = mat.metal
		new_mat.rough = mat.rough
		new_mat.emission = mat.emission
		# 确保数组长度足够容纳索引 id
		while res.materials.size() <= mat.id:
			res.materials.append(null)
		res.materials[mat.id] = new_mat
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


## 添加材质，自动按材质 ID 对齐数组索引（体素存的 ID 即可直接作数组索引）
## 索引 0 保留为占位；索引 = 材质 ID 处存放该材质
## 若该 ID 位置已有材质，则覆盖
func add_material(mat: VoxelMaterial, notify: bool = false) -> VoxelMaterial:
	if mat == null:
		return null
	# 确保数组长度足够容纳索引 id
	while materials.size() <= mat.id:
		materials.append(null)
	materials[mat.id] = mat
	if notify:
		emit_changed()
	return mat


## 获取材质 (按材质 ID / 数组索引，越界返回 null)
func get_material(index: int) -> VoxelMaterial:
	if index >= 0 and index < materials.size():
		return materials[index]
	return null


## 按材质 ID 查找材质（数组可能未对齐时也能找到）
func get_material_by_id(mat_id: int) -> VoxelMaterial:
	if mat_id >= 0 and mat_id < materials.size() and materials[mat_id] != null \
			and materials[mat_id].id == mat_id:
		return materials[mat_id]
	# 数组未对齐时，遍历查找
	for mat in materials:
		if mat != null and mat.id == mat_id:
			return mat
	return null


## 获取按材质 ID 对齐的材质数组（用于 VoxelMeshGenerator，保证索引==ID）
func get_aligned_materials() -> Array[VoxelMaterial]:
	var aligned: Array[VoxelMaterial] = []
	for mat in materials:
		if mat == null:
			continue
		while aligned.size() <= mat.id:
			aligned.append(null)
		aligned[mat.id] = mat
	return aligned


## 获取所有材质的浅拷贝 (用于 VoxelMeshGenerator)
func get_materials_array() -> Array:
	return materials.duplicate(false)


## 触发 changed 信号 (批量修改后手动调用)
func notify_changed() -> void:
	emit_changed()
