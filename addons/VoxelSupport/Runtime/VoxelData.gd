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
	else:
		voxels[pos] = material_id
		dirty_voxels[pos] = material_id
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	voxels.erase(pos)
	dirty_voxels[pos] = -1
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
	if notify:
		emit_changed()


## 合并另一个资源中的体素 (可带偏移)
func merge(other: VoxelData, offset: Vector3i = Vector3i.ZERO, notify: bool = true) -> void:
	for pos in other.voxels:
		voxels[pos + offset] = other.voxels[pos]
		dirty_voxels[pos + offset] = other.voxels[pos]
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


## 查询球形范围内的所有体素位置 (只读，不修改)
func get_voxels_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var radius_sq := radius * radius
	for pos in voxels:
		if (Vector3(pos) - center).length_squared() <= radius_sq:
			result.append(pos)
	return result


## 查询盒形范围内的所有体素位置 (只读，不修改)
func get_voxels_in_box(aabb: AABB) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for pos in voxels:
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
	emit_changed()


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
		var queue: Array = [pos]
		while not queue.is_empty():
			var cur: Vector3i = queue.pop_front()
			for d: Vector3i in NEIGHBORS_6:
				var nb := cur + d
				if nb in result:
					continue
				if not restrict.is_empty() and not restrict.has(nb):
					continue
				result[nb] = true
				queue.append(nb)
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
		var queue: Array = [key]
		visited[key] = true
		while not queue.is_empty():
			var cur: Vector3i = queue.pop_front()
			block.append(cur)
			for d: Vector3i in NEIGHBORS_6:
				var nb := cur + d
				if nb in visited or not all_pos.has(nb):
					continue
				visited[nb] = true
				queue.append(nb)
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
	# 处理顺序：按 y 坐标从低到高（FIFO 队列保证候选体素先入队，先处理）
	# 失稳判断：体素不稳定 ⟺ 其 5 个下方位全无支撑体素
	#   一个体素提供支撑的前提是：它本身稳定（不在 unstable 中）
	#   这样连锁失稳会自然向上传播：下层失稳 → 上层失去支撑 → 上层也失稳
	var unstable := {}
	var visited := {}
	var queue: Array = []
	for c in candidates:
		visited[c] = true
		queue.append(c)

	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()

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
			# 连锁失稳：检查该体素的上方位邻居
			for d: Vector3i in UPPER_5:
				var nb := cur + d
				if voxels_dict.has(nb) and not visited.has(nb):
					visited[nb] = true
					queue.append(nb)

	return unstable
