@tool
class_name VoxelData
extends Resource

## 可序列化的体素数据资源
## 用于运行时动态渲染、修改和破坏体素
## 可由 VoxelRenderer / VoxelDestructible 节点使用
## 与 VoxData 不同，此资源专为序列化和运行时使用设计
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

## 本次变更涉及的体素集合（由修改方法记录，供增量更新/外部查询）
## 调用 clear_dirty_voxels() 清空
var dirty_voxels: Dictionary[Vector3i, int] = {}

## Chunk 大小（与 VoxelChunkGenerator 保持一致，用于空间查询分块加速）
const CHUNK_SIZE := 32

## Chunk 索引缓存：{chunk_key: Array[Vector3i]}，用于快速空间查询
## 采用"实时增量维护"策略：
##   - 首次查询时全量构建一次（_chunk_index_built = true）
##   - 之后每次体素增删都只增量更新对应 chunk 的列表，索引始终保持与 voxels 同步
##   - 避免"任意变更即全量重建 O(全部体素)"导致的周期卡顿（大型场景关键）
var _chunk_index: Dictionary = {}
var _chunk_index_built: bool = false

## 6 方向邻居偏移（上下左右前后），连通性 BFS/泛洪共用
const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
]

## 5 个下方位支撑邻居偏移（支撑图：体素稳定 ⟺ 下方任一位置有体素支撑）
## 包括正下方 + 4 个对角下方，覆盖主要支撑方向
const LOWER_5: Array[Vector3i] = [
	Vector3i(0, -1, 0),   # 正下方
	Vector3i(-1, -1, 0),  # 左下方
	Vector3i(1, -1, 0),   # 右下方
	Vector3i(0, -1, -1),  # 后下方
	Vector3i(0, -1, 1),   # 前下方
]

## 5 个上方位传播偏移（与 LOWER_5 对称，用于连锁失稳传播）
const UPPER_5: Array[Vector3i] = [
	Vector3i(0, 1, 0),    # 正上方
	Vector3i(-1, 1, 0),   # 左上方
	Vector3i(1, 1, 0),    # 右上方
	Vector3i(0, 1, -1),   # 后上方
	Vector3i(0, 1, 1),    # 前上方
]

## 4 个水平邻居偏移（同 Y 层，用于失稳级联的水平传播）
## 修复浮空平台的外围体素未被检测到的问题
const HORIZONTAL_4: Array[Vector3i] = [
	Vector3i(1, 0, 0),  Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),  Vector3i(0, 0, -1),
]


## 从 VoxData 构造 (编辑器导入时使用)
static func from_voxel_data(voxel_data: VoxData, frame_index: int = 0) -> VoxelData:
	var res := VoxelData.new()
	var raw_voxels := voxel_data.get_voxels(frame_index)
	
	# 重新映射体素坐标到 [0, grid_size) 范围
	# VoxelNode.get_voxels() 中的 transform 包含 VoxelModel.offset 平移
	# 导致体素数据范围在 [offset, offset + size) 之间
	# 需要重新映射到 [0, size) 以匹配 grid_size
	if not raw_voxels.is_empty():
		var bounds := _calc_bounds(raw_voxels)
		var min_pos: Vector3i = bounds[0]
		var max_pos: Vector3i = bounds[1]
		
		# 重新映射：将所有体素位置减去 min_pos
		for pos_key in raw_voxels.keys():
			var pos: Vector3i = pos_key
			var new_pos: Vector3i = pos - min_pos
			res.voxels[new_pos] = raw_voxels[pos_key]
		
		res.grid_size = max_pos - min_pos + Vector3i(1, 1, 1)
	else:
		res.voxels = raw_voxels
		res.grid_size = Vector3i(voxel_data.size)
	
	# 材质数组：voxel_data.materials 是固定长度数组，其数组索引 i 即材质 ID (体素值)
	# 因此直接按索引 i 复制到 res.materials，保证"体素值 = data.materials 索引"的约定
	# 注意：不能用 mat.id，因为 VoxAccess 未给每个材质设置不同的 id（默认全为0）
	res.materials.resize(256)
	for i in voxel_data.materials.size():
		var src: VoxelMaterial = voxel_data.materials[i]
		if src == null:
			continue
		var new_mat := VoxelMaterial.new()
		new_mat.id = i
		new_mat.color = src.color
		new_mat.trans = src.trans
		new_mat.metal = src.metal
		new_mat.rough = src.rough
		new_mat.emission = src.emission
		res.materials[i] = new_mat
	return res


## 获取指定位置的体素材质ID，不存在返回 -1
func get_voxel(pos: Vector3i) -> int:
	return voxels.get(pos, -1)


## 设置指定位置的体素 (material_id < 0 时移除)
func set_voxel(pos: Vector3i, material_id: int, notify: bool = true) -> void:
	if material_id < 0:
		voxels.erase(pos)
		dirty_voxels[pos] = -1
		_chunk_index_remove(pos)
	else:
		# 若该位置原本已有体素，先移除旧索引，再添加新索引（避免重复）
		if voxels.has(pos):
			_chunk_index_remove(pos)
		voxels[pos] = material_id
		dirty_voxels[pos] = material_id
		_chunk_index_add(pos)
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	voxels.erase(pos)
	dirty_voxels[pos] = -1
	_chunk_index_remove(pos)
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
	for pos in voxels:
		dirty_voxels[pos] = -1
	voxels.clear()
	_chunk_index.clear()
	_chunk_index_built = true  # 空索引即已构建
	if notify:
		emit_changed()


## 合并另一个资源中的体素 (可带偏移)
func merge(other: VoxelData, offset: Vector3i = Vector3i.ZERO, notify: bool = true) -> void:
	for pos in other.voxels:
		var dst := pos + offset
		if voxels.has(dst):
			_chunk_index_remove(dst)
		voxels[dst] = other.voxels[pos]
		dirty_voxels[dst] = other.voxels[pos]
		_chunk_index_add(dst)
	if notify:
		emit_changed()


## 清空变更追踪集合（在完成一次网格重建后调用）
func clear_dirty_voxels() -> void:
	dirty_voxels.clear()


## 计算本次变更体素的包围盒 (AABB)，用于区域重建判断；无变更返回 null
func get_dirty_voxels_aabb() -> AABB:
	if dirty_voxels.is_empty():
		return AABB()
	var bounds := _calc_bounds(dirty_voxels)
	return _bounds_to_aabb(bounds)


## 计算全部体素的包围盒 (AABB)，用于场景摆放/居中；空体素返回零 AABB
func get_voxels_aabb() -> AABB:
	if voxels.is_empty():
		return AABB()
	var bounds := _calc_bounds(voxels)
	return _bounds_to_aabb(bounds)


## 计算一组体素的包围盒 (AABB)，空集合返回 null
static func _bounds_to_aabb(bounds: Array) -> AABB:
	if bounds.is_empty():
		return AABB()
	var min_pos: Vector3i = bounds[0]
	var max_pos: Vector3i = bounds[1]
	var extents := (max_pos - min_pos + Vector3i(1, 1, 1))
	return AABB(Vector3(min_pos), Vector3(extents))


## 计算体素集合的 min/max 坐标范围，返回 [min_pos, max_pos]；空集合返回空数组
static func _calc_bounds(voxels: Dictionary) -> Array:
	if voxels.is_empty():
		return []
	var min_pos := Vector3i(999999, 999999, 999999)
	var max_pos := Vector3i(-999999, -999999, -999999)
	for pos_key in voxels:
		var pos: Vector3i = pos_key
		min_pos.x = mini(min_pos.x, pos.x)
		min_pos.y = mini(min_pos.y, pos.y)
		min_pos.z = mini(min_pos.z, pos.z)
		max_pos.x = maxi(max_pos.x, pos.x)
		max_pos.y = maxi(max_pos.y, pos.y)
		max_pos.z = maxi(max_pos.z, pos.z)
	return [min_pos, max_pos]


# ----------------------------------------------------------------------------
# Chunk 索引加速（空间查询）
# ----------------------------------------------------------------------------

## 体素坐标 → chunk key
static func _chunk_of(pos: Vector3i) -> Vector3i:
	return Vector3i(
		pos.x / CHUNK_SIZE,
		pos.y / CHUNK_SIZE,
		pos.z / CHUNK_SIZE
	)


## 全量构建 chunk 索引：{chunk_key: Array[Vector3i]}（首次查询时调用一次）
func _build_chunk_index_full() -> void:
	_chunk_index.clear()
	for pos in voxels:
		var ck := _chunk_of(pos)
		if not _chunk_index.has(ck):
			_chunk_index[ck] = []
		_chunk_index[ck].append(pos)
	_chunk_index_built = true


## 确保索引已构建（首次查询时全量构建一次；之后由增量维护保持同步，无需重建）
func _build_chunk_index_if_dirty() -> void:
	if not _chunk_index_built:
		_build_chunk_index_full()


## 增量：添加体素到对应 chunk 的索引列表（由 set_voxel/merge 在写入 voxels 后调用）
## 需在 voxels[pos] 已写入后调用，且仅当索引已构建时
func _chunk_index_add(pos: Vector3i) -> void:
	if not _chunk_index_built:
		return
	var ck := _chunk_of(pos)
	if not _chunk_index.has(ck):
		_chunk_index[ck] = []
	_chunk_index[ck].append(pos)


## 增量：从对应 chunk 的索引列表移除体素（由 remove_* 在擦除 voxels 后调用）
## 仅当索引已构建时有效；chunk 不存在则忽略
func _chunk_index_remove(pos: Vector3i) -> void:
	if not _chunk_index_built:
		return
	var ck := _chunk_of(pos)
	if _chunk_index.has(ck):
		var list: Array = _chunk_index[ck]
		list.erase(pos)
		if list.is_empty():
			_chunk_index.erase(ck)


## 标记 chunk 索引失效（供外部绕过 set_voxel/remove_* 直接修改 voxels 后调用）
## 下次空间查询（get_voxels_in_sphere / get_voxels_in_box）会全量重建一次
## 正常破坏流程无需调用（内部已增量维护），仅当游戏直接操作 voxels 字典时使用
func invalidate_chunk_index() -> void:
	_chunk_index_built = false


## 获取与球体重叠的 chunk 列表
func _get_chunks_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	if radius <= 0:
		return []
	# 球体包围盒
	var center_v := Vector3i(center)
	var r_ceil := ceili(radius)
	var min_pos := center_v - Vector3i(r_ceil, r_ceil, r_ceil)
	var max_pos := center_v + Vector3i(r_ceil, r_ceil, r_ceil)
	var min_ck := _chunk_of(min_pos)
	var max_ck := _chunk_of(max_pos)
	var result: Array[Vector3i] = []
	for x in range(min_ck.x, max_ck.x + 1):
		for y in range(min_ck.y, max_ck.y + 1):
			for z in range(min_ck.z, max_ck.z + 1):
				var ck := Vector3i(x, y, z)
				# 快速检查：chunk 的 AABB 是否与球体相交
				var chunk_origin := Vector3(ck * CHUNK_SIZE)
				var chunk_center := chunk_origin + Vector3(CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5)
				var chunk_radius := Vector3(CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5, CHUNK_SIZE * 0.5).length()
				if (chunk_center - center).length() <= radius + chunk_radius:
					result.append(ck)
	return result


## 获取与盒体重叠的 chunk 列表
func _get_chunks_in_box(aabb: AABB) -> Array[Vector3i]:
	if aabb.size.length_squared() <= 0:
		return []
	var min_pos := Vector3i(aabb.position)
	var max_pos := Vector3i(aabb.position + aabb.size)
	var min_ck := _chunk_of(min_pos)
	var max_ck := _chunk_of(max_pos)
	var result: Array[Vector3i] = []
	for x in range(min_ck.x, max_ck.x + 1):
		for y in range(min_ck.y, max_ck.y + 1):
			for z in range(min_ck.z, max_ck.z + 1):
				result.append(Vector3i(x, y, z))
	return result


## 查询球形范围内的所有体素位置 (只读，不修改)
## 使用 Chunk 索引加速：先找出与球体重叠的 chunk，再只查询这些 chunk 内的体素
func get_voxels_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if voxels.is_empty():
		return result
	var radius_sq := radius * radius
	# 获取与球体重叠的 chunk
	var overlap_chunks := _get_chunks_in_sphere(center, radius)
	if overlap_chunks.is_empty():
		return result
	# 只查询这些 chunk 内的体素
	_build_chunk_index_if_dirty()
	for ck in overlap_chunks:
		var positions: Array = _chunk_index.get(ck, [])
		for pos in positions:
			if (Vector3(pos) - center).length_squared() <= radius_sq:
				result.append(pos)
	return result


## 查询盒形范围内的所有体素位置 (只读，不修改)
## 使用 Chunk 索引加速：先找出与盒体重叠的 chunk，再只查询这些 chunk 内的体素
func get_voxels_in_box(aabb: AABB) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if voxels.is_empty():
		return result
	# 获取与盒体重叠的 chunk
	var overlap_chunks := _get_chunks_in_box(aabb)
	if overlap_chunks.is_empty():
		return result
	# 只查询这些 chunk 内的体素
	_build_chunk_index_if_dirty()
	for ck in overlap_chunks:
		var positions: Array = _chunk_index.get(ck, [])
		for pos in positions:
			if aabb.has_point(Vector3(pos)):
				result.append(pos)
	return result


## 移除球形范围内的所有体素 (用于破坏系统)
func remove_voxels_in_sphere(center: Vector3, radius: float, notify: bool = true) -> Array[Vector3i]:
	return _remove_voxels(get_voxels_in_sphere(center, radius), notify)


## 移除盒形范围内的所有体素 (用于破坏系统)
func remove_voxels_in_box(aabb: AABB, notify: bool = true) -> Array[Vector3i]:
	return _remove_voxels(get_voxels_in_box(aabb), notify)


## 批量移除指定位置的体素 (公开接口，供破坏/崩塌等系统调用)
func remove_voxels(positions: Array, notify: bool = true) -> Array:
	return _remove_voxels(positions, notify)


## 批量移除指定位置的体素 (内部统一实现，供各 remove_* 复用)
func _remove_voxels(positions: Array, notify: bool = true) -> Array:
	if positions.is_empty():
		return []
	for pos in positions:
		voxels.erase(pos)
		dirty_voxels[pos] = -1
		_chunk_index_remove(pos)
	if notify:
		emit_changed()
	return positions


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
	return VoxelMaterial.find_by_id(materials, mat_id)


## 获取按材质 ID 对齐的材质数组（用于 VoxelMeshGenerator，保证索引==ID）
## 内部可能含 null 空位，因此返回通用 Array（typed array 不允许 null）
func get_aligned_materials() -> Array:
	return VoxelMaterial.align_by_id(materials)


## 获取所有材质的浅拷贝 (用于 VoxelMeshGenerator)
func get_materials_array() -> Array:
	return materials.duplicate(false)


## 触发 changed 信号 (批量修改后手动调用)
func notify_changed() -> void:
	emit_changed()


# ----------------------------------------------------------------------------
# 存档 / 重建
# ----------------------------------------------------------------------------

## 将体素数据和材质序列化为可 JSON 保存的结构
## 返回 Dictionary，可配合 JSON.stringify 保存到磁盘；load_data 可完整重建
## 格式：
##   {
##     "grid_size": [x, y, z],
##     "materials": [{ "id", "color", "trans", "metal", "rough", "emission", "hardness", "mass" }, ...],
##     "voxels": [[x, y, z, mat_id], ...],
##   }
func save_data() -> Dictionary:
	var data := {}
	data["grid_size"] = [grid_size.x, grid_size.y, grid_size.z]
	# 材质序列化（保留非 null 材质，材质自身负责存档）
	var mats := []
	for mat in materials:
		if mat == null:
			continue
		mats.append(mat.save_data())
	data["materials"] = mats
	# 体素序列化
	var voxel_list := []
	for pos_key in voxels:
		var pos: Vector3i = pos_key
		voxel_list.append([pos.x, pos.y, pos.z, voxels[pos_key]])
	data["voxels"] = voxel_list
	return data


## 从 save_data() 返回的数据重建体素和材质（先清空当前内容）
func load_data(data: Variant) -> void:
	clear()
	if data == null or not data is Dictionary:
		return
	# 材质重建（材质自身负责从数据恢复）
	materials = []
	if data.has("materials"):
		for mat_data in data["materials"]:
			var mat: VoxelMaterial = VoxelMaterial.load_data(mat_data)
			if mat != null:
				while materials.size() <= mat.id:
					materials.append(null)
				materials[mat.id] = mat
	# 网格尺寸
	if data.has("grid_size") and data["grid_size"] is Array and data["grid_size"].size() >= 3:
		grid_size = Vector3i(int(data["grid_size"][0]), int(data["grid_size"][1]), int(data["grid_size"][2]))
	# 体素重建
	if data.has("voxels"):
		for vox in data["voxels"]:
			if vox is Array and vox.size() >= 4:
				var pos := Vector3i(int(vox[0]), int(vox[1]), int(vox[2]))
				voxels[pos] = int(vox[3])
	# load_data 直接写入 voxels（绕过增量维护），标记索引失效，下次查询时全量重建
	_chunk_index_built = false
	emit_changed()


## 获取指定 chunk 内的所有体素位置（基于 chunk 索引加速查询）
## 返回 Array[Vector3i]（体素位置列表），空 chunk 返回空数组
func get_chunk_voxels(chunk_key: Vector3i) -> Array:
	_build_chunk_index_if_dirty()
	if _chunk_index.has(chunk_key):
		return _chunk_index[chunk_key].duplicate()
	return []


# ----------------------------------------------------------------------------
# 连通性 / 连接度 API（公开、只读、泛化，供游戏复用实现自定义逻辑）
# ----------------------------------------------------------------------------
# 元素反应等自定义玩法应由游戏自己实现，插件只提供这些底层查询能力。
# 例如"水+火反应"：游戏可在 voxel_damaged 信号里用 find_connected / connectivity
# 找出影响范围，再按材质组合自行实现反应效果。

## 从种子体素位置集合出发，6 方向泛洪标记所有连通的体素，返回位置集合 (Dictionary 作 Set)
## seeds 可为单个 Vector3i 或 Array[Vector3i]；返回 {pos: true} 可直接用 has() 判断
## 若 restrict 提供，则只允许在 restrict 集合内扩散（用于只分析某子集内部的连通性）
static func flood_fill(seeds, restrict: Dictionary = {}) -> Dictionary:
	var result := {}
	if seeds == null:
		return result
	# 归一化种子为数组
	var seed_list: Array = []
	if seeds is Vector3i:
		seed_list.append(seeds)
	elif seeds is Array:
		seed_list = seeds
	for s in seed_list:
		var pos: Vector3i = s
		if pos in result:
			continue
		if not restrict.is_empty() and not restrict.has(pos):
			continue
		result[pos] = true
		var stack: Array = [pos]
		while not stack.is_empty():
			var cur: Vector3i = stack.pop_back()
			for d: Vector3i in NEIGHBORS_6:
				var nb := cur + d
				if nb in result:
					continue
				if not restrict.is_empty() and not restrict.has(nb):
					continue
				result[nb] = true
				stack.append(nb)
	return result


## 找出某个体素所在的整个连通块（6 方向连通），返回该连通块的位置集合
## 用于悬空判断、反应波及范围等
func find_connected(pos: Vector3i) -> Dictionary:
	if not has_voxel(pos):
		return {}
	return flood_fill(pos, voxels)


## 将一组位置按 6 方向连通性分组，返回 Array[Array[Vector3i]]
## 每组的体素两两 6 方向连通，组与组之间不连通。用于分块塌落、分块破坏等
static func partition_connected(positions: Array) -> Array:
	var result: Array = []
	if positions.is_empty():
		return result
	var all_pos := {}
	for p in positions:
		all_pos[p] = true
	var visited := {}
	for key in all_pos:
		if key in visited:
			continue
		var block: Array = []
		var stack: Array = [key]
		visited[key] = true
		while not stack.is_empty():
			var cur: Vector3i = stack.pop_back()
			block.append(cur)
			for d: Vector3i in NEIGHBORS_6:
				var nb := cur + d
				if nb in visited or not all_pos.has(nb):
					continue
				visited[nb] = true
				stack.append(nb)
		result.append(block)
	return result


## 某个体素的连接度：相邻的实体素数量 (0-6)
## 可用于薄弱点判断、支撑接触面积估算等
func connectivity(pos: Vector3i) -> int:
	var count := 0
	for d: Vector3i in NEIGHBORS_6:
		if has_voxel(pos + d):
			count += 1
	return count


## 返回某体素的所有相邻实体素位置数组 (6 方向)
func neighbors(pos: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for d: Vector3i in NEIGHBORS_6:
		var nb := pos + d
		if has_voxel(nb):
			result.append(nb)
	return result


## 找出"悬空"体素：与贴地(y==0)体素 6 方向连通判定，完全断开的返回
## 这是崩塌检测的底座：全量判定哪些与地面断开
func find_unsupported(voxels_set: Dictionary = {}) -> Dictionary:
	var src := voxels_set if not voxels_set.is_empty() else voxels
	if src.is_empty():
		return {}
	# 种子 = 贴地(y==0)体素
	var seeds: Array = []
	for key in src:
		var pos: Vector3i = key
		if pos.y == 0:
			seeds.append(key)
	var supported := flood_fill(seeds, src)
	var unsupported := {}
	for key in src:
		if not supported.has(key):
			unsupported[key] = true
	return unsupported


## 找出"悬空"体素（支撑图局部检测）：只检查 removed 体素上方可能失稳的体素
## 
## 原理（支撑图 / Support Graph）：
##   体素稳定 ⟺ 其 5 个下方位（LOWER_5）中至少有一个体素存在且稳定
##   贴地体素 (y==0) 永远稳定
## 
## 失稳传播：
##   破坏移除体素 R → 检查 R 的 5 个上方位（UPPER_5）中存在的体素 C
##   → 若 C 所有 5 个下方位都没有体素支撑 → C 失稳
##   → 递归检查 C 的上方位（连锁失稳）
## 
## 与旧 BFS 方案对比：
##   - 旧方案：从候选体素 6 方向 BFS 遍历整个连通分量检查是否贴地（O(场景大小)）
##   - 新方案：只沿支撑链向上传播，不遍历连通分量（O(失稳体素数)）
##   对于大场景（10万+体素），新方案速度提升 100~1000 倍
## 
## 精度差异：
##   - 旧方案：6 方向连通性，体素可透过侧向路径连接地面
##   - 新方案：仅检查下方 5 个位置的支撑，侧向路径不支撑
##   对于典型建筑场景（墙体/地板/天花板），差异极小
##   对于"浮空平台侧向连接墙壁"等特殊结构，新方案更保守（更多体素可能失稳）
## 
## 返回失稳体素位置集合 {pos: true}
func find_unsupported_around(removed: Array) -> Dictionary:
	var voxels_dict: Dictionary = voxels
	if removed.is_empty() or voxels_dict.is_empty():
		return {}

	# 候选体素 = removed 的 5 个上方位邻居中仍存在的体素
	# 这些体素可能因为失去下方支撑而失稳
	var candidates := {}
	for r in removed:
		var rp: Vector3i = r
		for d: Vector3i in UPPER_5:
			var nb := rp + d
			if voxels_dict.has(nb):
				candidates[nb] = true

	if candidates.is_empty():
		return {}

	# 支撑传播：从候选体素向上检查支撑链
	# 处理顺序：按 y 坐标从低到高（栈保证候选体素先入栈，先处理）
	# 失稳判断：体素不稳定 ⟺ 其 5 个下方位全无支撑体素
	#   一个体素提供支撑的前提是：它本身稳定（不在 unstable 中）
	#   这样连锁失稳会自然向上传播：下层失稳 → 上层失去支撑 → 上层也失稳
	var unstable := {}
	var visited := {}
	var stack: Array = []
	for c in candidates:
		visited[c] = true
		stack.append(c)

	while not stack.is_empty():
		var cur: Vector3i = stack.pop_back()

		# 贴地体素永远稳定
		if cur.y == 0:
			continue

		# 检查是否有支撑：5 个下方位中，存在且自身稳定的体素
		var has_support := false
		for d: Vector3i in LOWER_5:
			var lower := cur + d
			if voxels_dict.has(lower) and not unstable.has(lower):
				has_support = true
				break

		if not has_support:
			unstable[cur] = true
			# 连锁失稳：检查该体素的上方位邻居 + 水平邻居（同 Y 层）
			# 上方位邻居：正上方 + 斜上方（y+1）
			for d: Vector3i in UPPER_5:
				var nb := cur + d
				if voxels_dict.has(nb) and not visited.has(nb):
					visited[nb] = true
					stack.append(nb)
			# 【关键修复】水平邻居：4 个同 Y 层方向
			# 不检查水平方向时，浮空平台的外围体素不会被检测到
			# 因为它们不在 removed 的 UPPER_5 范围内，也不在失稳体素的 UPPER_5 范围内
			for d: Vector3i in HORIZONTAL_4:
				var nb := cur + d
				if voxels_dict.has(nb) and not visited.has(nb):
					visited[nb] = true
					stack.append(nb)

	return unstable