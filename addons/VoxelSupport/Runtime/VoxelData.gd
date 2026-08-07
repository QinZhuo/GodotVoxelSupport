@tool
class_name VoxelData
extends Resource

## 可序列化的体素数据资源
## 用于运行时动态渲染、修改和破坏体素
## 可由 VoxelRenderer / VoxelDestructible 节点使用
## 与 VoxData 不同，此资源专为序列化和运行时使用设计
## 注: 直接使用 Resource 内置的 changed 信号 (通过 emit_changed() 发射)
##
## 【存储方案】chunk 分区密集缓冲（性能关键）
## 旧方案：整个世界用 Dictionary[Vector3i, int]，每个体素一个 Vector3i 哈希键，
##         邻居查询/切片/网格生成全部命中字典哈希 → 大型场景慢一个量级。
## 新方案：非空 chunk 各持一块 PackedInt32Array(16³)，值 = 材质ID（0=空）。
##         体素读写 = 1 次 chunk 字典查询 + 1 次数组下标；稀疏性只存在于 chunk 层。
##         网格生成使用 18³ 密集"光环缓冲"，邻居读取全为数组下标、无越界检查。
##
## 【统一材质契约】（全项目权威，见 VoxelMaterial.gd）
##   - 材质ID 0 = 空/空气：既没有体素也没有材质
##   - 存储值 == 材质ID（0 = 空），无任何 +1/-1 编码偏移
##   - 对齐后材质数组索引 == 材质ID，索引 0 恒为 null 占位

## 材质数组 (索引即材质ID，使用 VoxelMaterial)
@export var materials: Array[VoxelMaterial] = []

## 帧数量 (保留用于未来动画扩展)
@export var frame_count: int = 1

## 体素网格尺寸 (体素个数，由导入时计算)
@export var grid_size: Vector3i = Vector3i.ZERO

## 缩放比例 (仅作为导入时的默认值，实际渲染缩放由 VoxelRenderer 控制)
@export var default_scale: float = 0.1

## 居中偏移 (体素单位，运行时渲染时叠加到网格顶点)
## 导入时若 center 选项开启，自动计算使模型左右前后居中(X/Z)、上下贴底(Y=0)
## 与 mesh 导入的居中策略一致，数据坐标仍保持在 [0, grid_size) 范围内
## 运行时渲染: 网格顶点 = (体素坐标 + center_offset) * voxel_scale
## 该偏移不影响破坏/查询逻辑 (它们基于原始数据坐标)
@export var center_offset: Vector3 = Vector3.ZERO

## 本次变更涉及的体素集合（由修改方法记录，供增量更新/外部查询）
## 调用 clear_dirty_voxels() 清空
var dirty_voxels: Dictionary[Vector3i, int] = {}

## Chunk 几何常量唯一权威源见 VoxelChunk，此处全部派生别名防止漂移
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const CHUNK_SLICE := VoxelChunk.CHUNK_SLICE
const HALO := VoxelChunk.HALO
const HALO_SIZE := VoxelChunk.HALO_SIZE
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

## chunk key -> 密集缓冲 (PackedInt32Array, 16³)。值 = 材质ID（0 = 空），材质ID 0 保留为空。
## 空 chunk 不在此字典中（稀疏性只存在于 chunk 层）。
var _chunk_buffers: Dictionary = {}

## 体素总数（增量维护，O(1) 查询，供 HUD 等高频读取）
var _voxel_count: int = 0

## 支撑图增量缓存：pos -> 其 LOWER_5 中存在的实体素数 (0-5)
## 由 set_voxel/remove_voxel/remove_voxels/merge 增量维护，供 find_unsupported_around 使用
## 失稳判断从"每次扫描 LOWER_5 的 5 次字典查询"降为 O(1) 读计数
## 缓存构建开关：首次使用时全量构建一次（_support_cache_built），之后增量同步
var _support_cache: Dictionary = {}
var _support_cache_built: bool = false

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
## center 为 true 时，记录居中偏移使渲染时模型中心对齐原点 (与 mesh 导入行为一致)
static func from_voxel_data(voxel_data: VoxData, frame_index: int = 0, center: bool = true) -> VoxelData:
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
			res._write_buffer_impl(pos - min_pos, raw_voxels[pos_key], false)

		res.grid_size = max_pos - min_pos + Vector3i(1, 1, 1)
	else:
		res.grid_size = Vector3i(voxel_data.size)

	# 材质数组：voxel_data.materials 是固定长度数组，其数组索引 i 即材质 ID (体素值)
	# 因此直接按索引 i 复制到 res.materials，保证"体素值 = data.materials 索引"的约定
	# 注意：不能用 mat.id，因为 VoxAccess 未给每个材质设置不同的 id（默认全为0）
	# 索引 0 保留为空占位（材质ID 0 = 空），不复制
	res.materials.resize(256)
	for i in range(1, voxel_data.materials.size()):
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

	# 居中偏移：与 mesh 导入行为一致 —— 左右前后(X/Z)居中，上下(Y)不居中(底部贴原点)
	# 网格顶点 = (体素坐标 + center_offset) * voxel_scale
	# X/Z 偏移 = -(grid_size/2) floor，Y 偏移恒为 0，使模型水平居中且竖立于原点
	if center:
		var half_grid := (Vector3(res.grid_size) / 2.0).floor()
		res.center_offset = Vector3(-half_grid.x, 0.0, -half_grid.z)
	return res


# ----------------------------------------------------------------------------
# 核心存储原语（chunk 密集缓冲）
# ----------------------------------------------------------------------------

## 体素坐标 → chunk key（floori 向下取整，正确处理负坐标）
static func _chunk_of(pos: Vector3i) -> Vector3i:
	return VoxelChunk.chunk_of(pos)


## chunk 内局部坐标 → 缓冲下标（线性化：x + y*CS + z*CS²，覆盖 0..CHUNK_VOLUME-1）
static func _buf_index(local: Vector3i) -> int:
	return VoxelChunk.buf_index(local.x, local.y, local.z)


## 缓冲下标 → chunk 内局部坐标
static func _local_from_index(i: int) -> Vector3i:
	return VoxelChunk.local_from_index(i)


## 写入体素缓冲（核心原语）。不追踪 dirty_voxels / 不触发信号（由调用方处理）。
## 统一材质契约：材质ID 0 = 空，缓冲直接存材质ID（0 = 空）。
## check_empty=true 时，若写入后该 chunk 缓冲全空则移除 chunk 键（回收内存）。
func _write_buffer_impl(pos: Vector3i, mat_id: int, check_empty: bool) -> void:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		buf = PackedInt32Array()
		buf.resize(CHUNK_VOLUME)
		_chunk_buffers[ck] = buf
	var idx := _buf_index(pos - ck * CHUNK_SIZE)
	var cur: int = buf[idx]
	if mat_id <= 0:
		if cur > 0:
			buf[idx] = 0
			_voxel_count -= 1
			if check_empty:
				_maybe_erase_empty_chunk(ck)
	else:
		if cur <= 0:
			_voxel_count += 1
		buf[idx] = mat_id


## 若 chunk 缓冲已全空则移除该 chunk 键（仅当 check_empty 需要时调用）
func _maybe_erase_empty_chunk(ck: Vector3i) -> void:
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		return
	for i in CHUNK_VOLUME:
		if buf[i] > 0:
			return
	_chunk_buffers.erase(ck)


## 构建期/读档批量填充 {pos: mat_id}，不追踪 dirty_voxels、不触发信号。
## 适合一次性生成大量静态体素（demo 场景构建、外部数据导入）。
## 绕过增量维护，故使支撑缓存失效，下次失稳检测时全量重建。
func load_voxels_dict(dict: Dictionary) -> void:
	for pos_key in dict:
		_write_buffer_impl(pos_key, dict[pos_key], false)
	invalidate_support_cache()


## 获取所有非空 chunk key
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
	return keys


## 获取 chunk 的 18³ 密集"光环缓冲"（值 = 材质ID，0 = 空）。
## 覆盖 chunk 内部 + 1 体素外缘，供网格生成在子线程中只读使用（独立的深拷贝，无数据竞态）。
## 邻居读取全为数组下标且无越界检查（光环含完整 6 邻）。
func get_chunk_halo(chunk: Vector3i) -> PackedInt32Array:
	return VoxelChunkGenerator.build_halo_from_buffers(_chunk_buffers, chunk)


## 生成"受影响区域"的 chunk 缓冲深拷贝快照（chunk key → PackedInt32Array 独立副本）。
## 只快照 rebuild_chunks 及其 27 邻居（构建 halo 需要），避免整世界深拷贝。
## 主线程一次性调用，随后供各子线程 worker 从快照构建自己的 halo（线程安全只读）。
func snapshot_chunks_halo(rebuild_chunks: Array[Vector3i]) -> Dictionary:
	var needed := {}
	for ck in rebuild_chunks:
		for nz in 3:
			for ny in 3:
				for nx in 3:
					var nck := ck + Vector3i(nx - HALO, ny - HALO, nz - HALO)
					if _chunk_buffers.has(nck):
						needed[nck] = _chunk_buffers[nck].duplicate()
	return needed


## 全量体素字典快照 {pos: mat_id}（兼容旧的非 chunk 渲染路径 / 旧式外部代码）
func get_voxels_dict_snapshot() -> Dictionary[Vector3i, int]:
	var out := {}
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out[origin + _local_from_index(i)] = buf[i]
	return out


# ----------------------------------------------------------------------------
# 基本访问
# ----------------------------------------------------------------------------

## 获取指定位置的体素材质ID，不存在返回 -1
func get_voxel(pos: Vector3i) -> int:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		return -1
	var v: int = buf[_buf_index(pos - ck * CHUNK_SIZE)]
	return v if v > 0 else -1


## 是否存在体素
func has_voxel(pos: Vector3i) -> bool:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		return false
	return buf[_buf_index(pos - ck * CHUNK_SIZE)] > 0


## 获取所有体素位置
func get_positions() -> Array:
	var out: Array = []
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out.append(origin + _local_from_index(i))
	return out


## 获取体素数量 (O(1))
func get_voxel_count() -> int:
	return _voxel_count


## 是否完全没有体素
func is_empty() -> bool:
	return _chunk_buffers.is_empty()


## 设置指定位置的体素 (material_id <= 0 时移除；0 = 空)
func set_voxel(pos: Vector3i, material_id: int, notify: bool = true) -> void:
	if material_id <= 0:
		remove_voxel(pos, notify)
		return
	var existed := has_voxel(pos)
	_write_buffer_impl(pos, material_id, false)
	dirty_voxels[pos] = material_id
	if not existed:
		_support_cache_on_add(pos)
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	_remove_voxels([pos], notify)


## 清空所有体素
func clear(notify: bool = true) -> void:
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				dirty_voxels[origin + _local_from_index(i)] = -1
	_chunk_buffers.clear()
	_voxel_count = 0
	_support_cache.clear()
	_support_cache_built = true
	if notify:
		emit_changed()


## 合并另一个资源中的体素 (可带偏移)
## 直接遍历 other 的 chunk 密集缓冲（单趟，避免 get_positions+get_voxel 两趟扫描）
func merge(other: VoxelData, offset: Vector3i = Vector3i.ZERO, notify: bool = true) -> void:
	var new_positions: Array = []
	for ck: Vector3i in other._chunk_buffers:
		var buf = other._chunk_buffers[ck]
		var o_origin: Vector3i = VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			var mat_id: int = buf[i]
			if mat_id <= 0:
				continue
			var dst: Vector3i = o_origin + VoxelChunk.local_from_index(i) + offset
			if not has_voxel(dst):
				# 新位置：支撑图需要增量添加（覆盖已存在的体素时支撑图不变化）
				new_positions.append(dst)
			_write_buffer_impl(dst, mat_id, false)
			dirty_voxels[dst] = mat_id
	if not new_positions.is_empty():
		for p in new_positions:
			_support_cache_on_add(p)
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
	if _voxel_count == 0:
		return AABB()
	var min_pos := Vector3i.MAX
	var max_pos := Vector3i.MIN
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				var pos := origin + _local_from_index(i)
				min_pos.x = mini(min_pos.x, pos.x)
				min_pos.y = mini(min_pos.y, pos.y)
				min_pos.z = mini(min_pos.z, pos.z)
				max_pos.x = maxi(max_pos.x, pos.x)
				max_pos.y = maxi(max_pos.y, pos.y)
				max_pos.z = maxi(max_pos.z, pos.z)
	return _bounds_to_aabb([min_pos, max_pos])


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
	var min_pos := Vector3i.MAX
	var max_pos := Vector3i.MIN
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
# 空间查询（基于 chunk 密集缓冲扫描，数组下标而非字典哈希）
# ----------------------------------------------------------------------------

## 获取与球体重叠的 chunk 列表
func _get_chunks_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	if radius <= 0:
		return []
	# 球体包围盒（使用 floori 统一向下取整，与 get_voxels_in_sphere 保持一致）
	var center_v := Vector3i(floori(center.x), floori(center.y), floori(center.z))
	var r_ceil := ceili(radius)
	var min_pos := center_v - Vector3i(r_ceil, r_ceil, r_ceil)
	var max_pos := center_v + Vector3i(r_ceil, r_ceil, r_ceil)
	var min_ck := _chunk_of(min_pos)
	var max_ck := _chunk_of(max_pos)
	var radius_sq := int(radius * radius)
	var result: Array[Vector3i] = []
	for x in range(min_ck.x, max_ck.x + 1):
		for y in range(min_ck.y, max_ck.y + 1):
			for z in range(min_ck.z, max_ck.z + 1):
				var ck := Vector3i(x, y, z)
				# 整型平方距离：体素中心(整数)到 chunk AABB 的最小距离平方。
				# 逐轴取区间最近距离，避免 Vector3.length() 浮点开销。
				var c_origin := VoxelChunk.origin_of(ck)
				var d_x := _axis_dist_sq(center_v.x, c_origin.x, c_origin.x + CHUNK_SIZE - 1)
				var d_y := _axis_dist_sq(center_v.y, c_origin.y, c_origin.y + CHUNK_SIZE - 1)
				var d_z := _axis_dist_sq(center_v.z, c_origin.z, c_origin.z + CHUNK_SIZE - 1)
				if d_x + d_y + d_z <= radius_sq:
					result.append(ck)
	return result


## 计算整数坐标点 p 到区间 [lo, hi]（含端点）的最近距离平方
static func _axis_dist_sq(p: int, lo: int, hi: int) -> int:
	var d := 0
	if p < lo:
		d = lo - p
	elif p > hi:
		d = p - hi
	return d * d


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
## 先找出与球体重叠的 chunk，再只扫描这些 chunk 的密集缓冲
func get_voxels_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if _chunk_buffers.is_empty():
		return result
	var radius_sq := radius * radius
	var overlap_chunks := _get_chunks_in_sphere(center, radius)
	if overlap_chunks.is_empty():
		return result
	var cxi := floori(center.x)
	var cyi := floori(center.y)
	var czi := floori(center.z)
	for ck in overlap_chunks:
		if not _chunk_buffers.has(ck):
			continue
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for z in CHUNK_SIZE:
			for y in CHUNK_SIZE:
				for x in CHUNK_SIZE:
					if buf[x + y * CHUNK_SIZE + z * CHUNK_SLICE] <= 0:
						continue
					var px := origin.x + x
					var py := origin.y + y
					var pz := origin.z + z
					var dx: int = px - cxi
					var dy: int = py - cyi
					var dz: int = pz - czi
					if float(dx * dx + dy * dy + dz * dz) <= radius_sq:
						result.append(Vector3i(px, py, pz))
	return result


## 查询盒形范围内的所有体素位置 (只读，不修改)
## 先找出与盒体重叠的 chunk，再只扫描这些 chunk 的密集缓冲
func get_voxels_in_box(aabb: AABB) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if _chunk_buffers.is_empty():
		return result
	var overlap_chunks := _get_chunks_in_box(aabb)
	if overlap_chunks.is_empty():
		return result
	for ck in overlap_chunks:
		if not _chunk_buffers.has(ck):
			continue
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for z in CHUNK_SIZE:
			for y in CHUNK_SIZE:
				for x in CHUNK_SIZE:
					if buf[x + y * CHUNK_SIZE + z * CHUNK_SLICE] <= 0:
						continue
					var pos := origin + Vector3i(x, y, z)
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


## 批量设置体素为同一材质（公开接口，供水模拟等高频动态系统使用）。
## 相比逐个 set_voxel：只 emit_changed 一次，且一次性维护支撑缓存，
## 并填充 dirty_voxels，让 VoxelRenderer 走增量重建（只重建受影响 chunk）。
## 语义与 set_voxel 一致：material_id <= 0（含 0=空）视为批量移除；已存在体素被覆盖时支撑图不变。
func set_voxels(positions: Array, material_id: int, notify: bool = true) -> void:
	if positions.is_empty():
		return
	if material_id <= 0:
		_remove_voxels(positions, notify)
		return
	# 新位置（原本为空）单独收集，供支撑缓存增量添加
	var new_positions: Array = []
	for p in positions:
		var pos: Vector3i = p
		if not has_voxel(pos):
			new_positions.append(pos)
		_write_buffer_impl(pos, material_id, false)
		dirty_voxels[pos] = material_id
	if not new_positions.is_empty():
		for p in new_positions:
			_support_cache_on_add(p)
	if notify:
		emit_changed()


## 批量移除指定位置的体素 (内部统一实现，供各 remove_* 复用)
func _remove_voxels(positions: Array, notify: bool = true) -> Array:
	if positions.is_empty():
		return []
	var _diag_t0 := Time.get_ticks_usec()
	var touched: Dictionary = {}
	for pos in positions:
		dirty_voxels[pos] = -1
		var ck := _chunk_of(pos)
		var buf = _chunk_buffers.get(ck)
		if buf == null:
			continue
		var idx := _buf_index(pos - ck * CHUNK_SIZE)
		if buf[idx] > 0:
			buf[idx] = 0
			_voxel_count -= 1
			touched[ck] = true
	# 批量移除后统一回收被清空的 chunk 键（避免逐体素 4096 扫描）
	for ck in touched:
		_maybe_erase_empty_chunk(ck)
	if NativeLoader.is_available():
		# 原生加速：支撑缓存增量更新（C++ 返回增量 delta，避免全量深拷贝 143 万条）
		var delta: Dictionary = NativeLoader.update_support_cache_remove(_support_cache, _chunk_buffers, positions)
		for p in delta["removed"]:
			_support_cache.erase(p)
		var updated: Dictionary = delta["updated"]
		for nb in updated:
			var count: int = updated[nb]
			if count > 0:
				_support_cache[nb] = count
			else:
				_support_cache.erase(nb)
	else:
		_support_cache_on_remove_batch(positions)
	if notify:
		emit_changed()
	# 诊断：批量移除超过 100 体素时打印耗时
	var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	if _t_ms > 2.0:
		print("[诊断] VoxelData._remove_voxels: %d 体素, 耗时 %.2f ms" % [positions.size(), _t_ms])
	return positions


## 添加材质，自动按材质 ID 对齐数组索引（体素存的 ID 即可直接作数组索引）
## 统一材质契约：索引 0 保留为空（材质ID 0 = 空），索引 = 材质 ID 处存放该材质
## 若该 ID 位置已有材质，则覆盖
func add_material(mat: VoxelMaterial, notify: bool = false) -> VoxelMaterial:
	if mat == null or mat.id <= 0:
		return null
	# 确保数组长度足够容纳索引 id
	while materials.size() <= mat.id:
		materials.append(null)
	materials[mat.id] = mat
	if notify:
		emit_changed()
	return mat


## 获取材质 (按对齐数组下标 == 材质ID 直接访问，越界/空位返回 null)
## 前提：materials 保持"索引 == 材质ID"对齐（add_material / 导入保证）。索引 0 = 空。
func get_material(index: int) -> VoxelMaterial:
	if index >= 0 and index < materials.size():
		return materials[index]
	return null


## 按材质 ID 查找材质（对外鲁棒接口：即使传入未对齐数组也能找到；id<=0/不存在返回 null）
## 生成器内部一律走对齐数组直接下标（见 VoxelMaterial.align_by_id），不需要此接口
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

## 序列化所有体素为 [[x, y, z, mat_id], ...]（统一材质契约：mat_id>=1，0=空 不存在）
## 唯一权威的体素序列化器，供 save_data()（JSON 存档）与资源持久化（_get/_set）共用
func _serialize_voxels() -> Array:
	var voxel_list := []
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				var p := origin + _local_from_index(i)
				voxel_list.append([p.x, p.y, p.z, buf[i]])
	return voxel_list


## 从 [[x, y, z, mat_id], ...] 重建体素（绕过增量维护，需调用方 invalidate_support_cache）
func _deserialize_voxels(voxel_list: Variant) -> void:
	if voxel_list == null:
		return
	for vox in voxel_list:
		if vox is Array and vox.size() >= 4:
			var pos := Vector3i(int(vox[0]), int(vox[1]), int(vox[2]))
			_write_buffer_impl(pos, int(vox[3]), false)


# --- 资源持久化（编辑器导入 .vox 为 VoxelData 后，体素数据随资源保存/加载） ---
# materials/grid_size/default_scale/center_offset/frame_count 已由 @export 持久化；
# _chunk_buffers 非 @export，通过隐藏 storage 属性在此序列化（编辑器不可见，随资源保存）。

## 声明隐藏的 storage 属性（PROPERTY_USAGE_STORAGE：不显示在编辑器，但随资源保存/加载）
func _get_property_list() -> Array[Dictionary]:
	return [{
		"name": "voxel_data_payload",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_STORAGE,
	}]


func _get(property: StringName) -> Variant:
	if property == &"voxel_data_payload":
		return var_to_str({
			"grid_size": [grid_size.x, grid_size.y, grid_size.z],
			"voxels": _serialize_voxels(),
		})
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"voxel_data_payload":
		clear(false)
		var payload: Variant = str_to_var(value)
		if payload is Dictionary:
			var gs: Variant = payload.get("grid_size", [0, 0, 0])
			if gs is Array and gs.size() >= 3:
				grid_size = Vector3i(int(gs[0]), int(gs[1]), int(gs[2]))
			_deserialize_voxels(payload.get("voxels", null))
		invalidate_support_cache()
		return true
	return false


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
	# 体素序列化（复用唯一权威序列化器）
	data["voxels"] = _serialize_voxels()
	return data


## 从 save_data() 返回的数据重建体素和材质（先清空当前内容）
func load_data(data: Variant) -> void:
	clear(false)
	if data == null or not data is Dictionary:
		emit_changed()
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
	# 体素重建（复用唯一权威反序列化器）
	_deserialize_voxels(data.get("voxels", null))
	# load_data 直接写入缓冲（绕过增量维护），使支撑缓存失效，下次查询时全量重建
	invalidate_support_cache()
	emit_changed()


## 获取指定 chunk 内的所有体素位置（基于密集缓冲扫描）
## 返回 Array[Vector3i]（体素位置列表），空 chunk 返回空数组
func get_chunk_voxels(chunk_key: Vector3i) -> Array:
	var buf = _chunk_buffers.get(chunk_key)
	if buf == null:
		return []
	var result: Array = []
	var origin := VoxelChunk.origin_of(chunk_key)
	for i in CHUNK_VOLUME:
		if buf[i] > 0:
			result.append(origin + _local_from_index(i))
	return result


## O(1) 判断指定 chunk 是否含体素（基于 chunk 缓冲字典，不扫描）
func has_chunk(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key)


# ----------------------------------------------------------------------------
# 支撑图增量缓存（供 find_unsupported_around 失稳检测 O(1) 读计数）
# ----------------------------------------------------------------------------

## 全量构建支撑缓存：对每个实体素统计其 LOWER_5 中存在的邻居数
## 首次调用失稳检测前执行一次，之后由 set/remove 增量同步
func _build_support_cache() -> void:
	_support_cache.clear()
	for pos: Vector3i in get_positions():
		var count := 0
		for d: Vector3i in LOWER_5:
			if has_voxel(pos + d):
				count += 1
		if count > 0:
			_support_cache[pos] = count
	_support_cache_built = true


## 确保支撑缓存已构建
func _ensure_support_cache() -> void:
	if not _support_cache_built:
		_build_support_cache()


## 预热查询缓存（支撑缓存）：把首次全量构建从"第一次破坏"推迟到"加载完成后"。
## 在初始体素填充完毕后调用一次即可，之后由 set/remove 增量维护保持同步。
func warm_up_cache() -> void:
	_ensure_support_cache()


## 增量：体素被设置后更新支撑缓存（需在 voxels[pos] 写入后调用）
## 1) pos 自身计数重算 2) pos 成为其 UPPER_5 邻居的新支撑，邻居计数 +1
func _support_cache_on_add(pos: Vector3i) -> void:
	if not _support_cache_built:
		return
	# pos 自身计数
	var count := 0
	for d: Vector3i in LOWER_5:
		if has_voxel(pos + d):
			count += 1
	if count > 0:
		_support_cache[pos] = count
	# pos 支撑其 UPPER_5 邻居
	for d: Vector3i in UPPER_5:
		var nb := pos + d
		if has_voxel(nb):
			_support_cache[nb] = _support_cache.get(nb, 0) + 1


## 增量：体素被移除后更新支撑缓存（需在 voxels.erase(pos) 后调用）
## 1) pos 自身删除 2) 其 UPPER_5 邻居失去一个支撑，计数 -1（降到 0 可删键）
func _support_cache_on_remove(pos: Vector3i) -> void:
	if not _support_cache_built:
		return
	_support_cache.erase(pos)
	for d: Vector3i in UPPER_5:
		var nb := pos + d
		if has_voxel(nb):
			var c: int = _support_cache.get(nb, 0) - 1
			if c > 0:
				_support_cache[nb] = c
			else:
				_support_cache.erase(nb)


## 批量：体素被批量移除后更新支撑缓存（比逐个 _support_cache_on_remove 更高效）
## 先收集所有受影响邻居（被删体素的 UPPER_5），避免重复增减
func _support_cache_on_remove_batch(positions: Array) -> void:
	if not _support_cache_built or positions.is_empty():
		return
	# 待删集合（用于判断邻居是否仍存在）
	var remove_set := {}
	for p in positions:
		remove_set[p] = true
		_support_cache.erase(p)
	# 受影响邻居 = 所有被删体素的 UPPER_5 中未被删且仍存在的体素
	var affected := {}
	for p in positions:
		var pos: Vector3i = p
		for d: Vector3i in UPPER_5:
			var nb := pos + d
			if has_voxel(nb) and not remove_set.has(nb):
				affected[nb] = true
	# 逐受影响邻居重算计数（重算比递增更稳，避免多次删同一个邻居）
	for nb_key in affected:
		var nb: Vector3i = nb_key
		var count := 0
		for d: Vector3i in LOWER_5:
			var lower := nb + d
			if has_voxel(lower) and not remove_set.has(lower):
				count += 1
		if count > 0:
			_support_cache[nb] = count
		else:
			_support_cache.erase(nb)


## 使支撑缓存失效（批量直接改体素时调用，如 load_data/clear/from_voxel_data 重建）
func invalidate_support_cache() -> void:
	_support_cache_built = false
	_support_cache.clear()


## 兼容存根：chunk 索引已由密集缓冲取代，无需外部失效。
func invalidate_chunk_index() -> void:
	pass


# ----------------------------------------------------------------------------
# 连通性 / 连接度 API（公开、只读、泛化，供游戏复用实现自定义逻辑）
# ----------------------------------------------------------------------------
# 元素反应等自定义玩法应由游戏自己实现，插件只提供这些底层查询能力。
# 例如"水+火反应"：游戏可在 voxel_damaged 信号里用 find_connected / connectivity
# 找出影响范围，再按材质组合自行实现反应效果。

## 从种子体素位置集合出发，6 方向泛洪标记所有连通的体素，返回位置集合 (Dictionary 作 Set)
## seeds 可为单个 Vector3i 或 Array[Vector3i]；返回 {pos: true} 可直接用 has() 判断
## 若 restrict 提供，则只允许在 restrict 集合内扩散（用于只分析某子集内部的连通性）
## 否则以"实体素"（密集缓冲查询）为扩散边界
func flood_fill(seeds, restrict: Dictionary = {}) -> Dictionary:
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
		if restrict.is_empty() and not has_voxel(pos):
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
				if restrict.is_empty() and not has_voxel(nb):
					continue
				result[nb] = true
				stack.append(nb)
	return result


## 找出某个体素所在的整个连通块（6 方向连通），返回该连通块的位置集合
## 用于悬空判断、反应波及范围等
func find_connected(pos: Vector3i) -> Dictionary:
	if not has_voxel(pos):
		return {}
	return flood_fill(pos)


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


## 某个体素的连接度：相邻的实体素数 (0-6)
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
## voxels_set 提供时只在该集合内判定（子集场景）；否则基于全部实体素
func find_unsupported(voxels_set: Dictionary = {}) -> Dictionary:
	if voxels_set.is_empty() and _voxel_count == 0:
		return {}
	# 种子 = 贴地(y==0)体素
	var seeds: Array = []
	if voxels_set.is_empty():
		for pos: Vector3i in get_positions():
			if pos.y == 0:
				seeds.append(pos)
	else:
		for key in voxels_set:
			var pos: Vector3i = key
			if pos.y == 0:
				seeds.append(key)
	var supported := flood_fill(seeds, voxels_set)
	var unsupported := {}
	if voxels_set.is_empty():
		for pos: Vector3i in get_positions():
			if not supported.has(pos):
				unsupported[pos] = true
	else:
		for key in voxels_set:
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
	var _diag_t0 := Time.get_ticks_usec()
	if removed.is_empty() or _chunk_buffers.is_empty():
		return {}

	# 确保支撑缓存已构建（首次调用全量构建一次，之后由 set/remove 增量维护）
	_ensure_support_cache()

	# 原生加速路径：GDExtension (C++) 已加载时优先调用（失稳检测 ~10 倍提速）。
	# 传入 _chunk_buffers / _support_cache 快照（C++ 侧只读，无副作用）
	if NativeLoader.is_available():
		var result: Dictionary = NativeLoader.find_unsupported_around(_chunk_buffers, _support_cache, removed)
		return result
	# 纯 GDScript 兜底路径
	return _find_unsupported_around_gd(removed)


## 纯 GDScript 兜底实现（与原生版算法完全一致）
func _find_unsupported_around_gd(removed: Array) -> Dictionary:
	var _diag_t0 := Time.get_ticks_usec()
	if removed.is_empty() or _chunk_buffers.is_empty():
		return {}

	# 确保支撑缓存已构建（首次调用全量构建一次，之后由 set/remove 增量维护）
	_ensure_support_cache()

	# 候选体素 = removed 的 5 个上方位邻居中仍存在的体素
	# 这些体素可能因为失去下方支撑而失稳
	var candidates := {}
	for r in removed:
		var rp: Vector3i = r
		for d: Vector3i in UPPER_5:
			var nb := rp + d
			if has_voxel(nb):
				candidates[nb] = true

	if candidates.is_empty():
		return {}

	# 失稳传播（增量支撑图，O(1) 读计数）：
	#   - 缓存 _support_cache 已反映"removed 已从 voxels 移除"的事实（调用方先
	#     remove_voxels 再检测），因此候选体素的缓存计数已扣减其失去的下方支撑
	#   - 传播中失稳的体素仍存在于 voxels（尚未真正移除），不能用缓存直接扣，
	#     因此用 local_dec 记录"被几个失稳邻居夺走的支撑数"
	#   - 有效支撑 = 缓存计数 - local_dec；<= 0 且 y>0 则失稳
	var unstable := {}
	var local_dec := {}
	var stack: Array = []
	for c in candidates:
		stack.append(c)

	while not stack.is_empty():
		var cur: Vector3i = stack.pop_back()

		# 已判定失稳则跳过（避免重复处理）
		if unstable.has(cur):
			continue
		# 贴地体素永远稳定
		if cur.y == 0:
			continue

		# 有效支撑数 = 缓存计数 - 被失稳邻居夺走的支撑
		var effective: int = _support_cache.get(cur, 0) - local_dec.get(cur, 0)
		if effective > 0:
			continue

		# 失稳
		unstable[cur] = true
		# 连锁失稳：夺走其 UPPER_5 邻居的一个支撑
		for d: Vector3i in UPPER_5:
			var nb := cur + d
			if has_voxel(nb) and not unstable.has(nb):
				local_dec[nb] = local_dec.get(nb, 0) + 1
				stack.append(nb)
		# 【关键修复】水平邻居：4 个同 Y 层方向
		# 不检查水平方向时，浮空平台的外围体素不会被检测到
		# 因为它们不在 removed 的 UPPER_5 范围内，也不在失稳体素的 UPPER_5 范围内
		for d: Vector3i in HORIZONTAL_4:
			var nb := cur + d
			if has_voxel(nb) and not unstable.has(nb):
				stack.append(nb)

	# 诊断：检查量级较大时打印耗时
	var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
	if _t_ms > 1.0:
		print("[诊断] VoxelData.find_unsupported_around: 起点%d, 候选%d, 失稳%d, 耗时%.2f ms" % [removed.size(), candidates.size(), unstable.size(), _t_ms])

	return unstable
