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

## 数据层磁盘流（VoxelStream / VoxelFileStream）。非空时启用数据层按需加载/卸载：
##   - 内存只保留活跃 chunk，其余 chunk 数据由 stream 负责写盘/读盘（磁盘为权威）
##   - 修改过的 chunk 卸载时写回磁盘；变空时清盘；未修改且磁盘已有的直接丢弃
##   - 访问 / 范围查询 / 破坏 / 网格生成会自动从磁盘加载所需 chunk（见各方法注释）
## 渲染器可在 STREAMING 模式下按距离调用 unload_chunk() / preload_chunk() 驱动
## 数据层的卸载与补建（见 VoxelRenderer._process_streaming）。
## 通过 set_stream() 或 setter 赋值；切换时会先 flush 旧流并恢复新流的已持久化索引。
@export var stream: VoxelStream:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储（与 VoxelRenderer.data 同模式）
		if stream == v:
			return
		# 切换前把旧流上未写盘的数据 flush（避免丢失）
		if stream != null and not _dirty_chunks.is_empty():
			flush()
		stream = v
		_persisted_chunks.clear()
		# 注：不清空 _dirty_chunks —— 内存中未写盘的数据是"新数据"，切换流后
		# 仍需持久化（卸载时写盘到新流）。只有 _persisted_chunks 从新流重建。
		if stream != null:
			for ck in stream.get_all_chunk_keys():
				_persisted_chunks[ck] = true

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

## 每 chunk 体素计数（chunk key -> int，增量维护 O(1)）。
## 替代 _maybe_erase_empty_chunk 的 4096 全量扫描：增减体素时更新计数，
## 归零即视为空 chunk 可擦除——消除破坏/崩塌热路径的 16³ 循环。
var _chunk_voxel_counts: Dictionary = {}

## 磁盘上已持久化的 chunk（key -> true，权威标志：该 chunk 数据存在于流中）。
## 与内存缓存独立：chunk 卸载（unload_chunk）后仍保留此标志，供按需重载/索引。
var _persisted_chunks: Dictionary = {}

## 内存中被修改过、尚未写盘的 chunk（key -> true）。卸载时写盘；变空时清盘。
## 未修改且磁盘已有的 chunk 卸载时直接丢弃（磁盘为权威，无意义 IO 写入）。
var _dirty_chunks: Dictionary = {}

## 体素总数（增量维护，O(1) 查询，供 HUD 等高频读取）
## 注：流式模式下仅统计"内存中已加载"的体素，磁盘上的数据不计入
var _voxel_count: int = 0

## 6 方向邻居偏移（上下左右前后），连通性 BFS/泛洪共用
const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
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
		if stream != null and _persisted_chunks.has(ck):
			# 流式：该 chunk 在磁盘已有数据，先载入内存再修改（保留旧数据）
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			buf = PackedInt32Array()
			buf.resize(CHUNK_VOLUME)
			_chunk_buffers[ck] = buf
	# 标记需要写盘：内存数据已变更（若最终变空由 _maybe_erase_empty_chunk 清盘）
	_dirty_chunks[ck] = true
	var idx := _buf_index(pos - ck * CHUNK_SIZE)
	var cur: int = buf[idx]
	if mat_id <= 0:
		if cur > 0:
			buf[idx] = 0
			_voxel_count -= 1
			_chunk_voxel_counts[ck] = _chunk_voxel_counts.get(ck, 0) - 1
			if check_empty:
				_maybe_erase_empty_chunk(ck)
	else:
		if cur <= 0:
			_voxel_count += 1
			_chunk_voxel_counts[ck] = _chunk_voxel_counts.get(ck, 0) + 1
		buf[idx] = mat_id


## 若 chunk 体素计数归零则移除该 chunk 键（O(1)，替代 4096 全量扫描）
func _maybe_erase_empty_chunk(ck: Vector3i) -> void:
	if _chunk_voxel_counts.get(ck, 0) > 0:
		return
	_chunk_buffers.erase(ck)
	_chunk_voxel_counts.erase(ck)
	_dirty_chunks.erase(ck)
	if stream != null and _persisted_chunks.has(ck):
		# 流式：世界该处已清空，同步删除磁盘数据（否则重载会出现"幽灵 chunk"）
		stream.erase_chunk(ck)
		_persisted_chunks.erase(ck)


# ----------------------------------------------------------------------------
# 数据层磁盘流式（VoxelStream 接入）
# ----------------------------------------------------------------------------

## 配置数据层流（等价于设置 stream 属性，供代码动态切换）。
## 切换逻辑见 stream setter（flush 旧流 + 恢复新流已持久化索引）。
func set_stream(s: VoxelStream) -> void:
	stream = s


## 数据层流式是否启用
func is_streaming() -> bool:
	return stream != null


## chunk 是否在内存中（有密集缓冲）
func is_chunk_loaded(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key)


## chunk 是否有数据（内存或磁盘）
func is_chunk_persisted(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key) or _persisted_chunks.has(chunk_key)


## 从流加载 chunk 数据到内存。已加载返回 true；流中不存在返回 false。
## 流式补建/网格生成前调用，保证后续读操作走内存数组。
func preload_chunk(chunk_key: Vector3i) -> bool:
	if _chunk_buffers.has(chunk_key):
		return true
	if stream == null or not _persisted_chunks.has(chunk_key):
		return false
	var buf := stream.load_chunk(chunk_key)
	if buf.is_empty():
		_persisted_chunks.erase(chunk_key)
		return false
	_chunk_buffers[chunk_key] = buf
	var cnt := 0
	for i in CHUNK_VOLUME:
		if buf[i] > 0:
			cnt += 1
	_chunk_voxel_counts[chunk_key] = cnt
	_voxel_count += cnt
	return true


## 确保一批 chunk 已加载（网格生成快照前调用）
func ensure_chunks_loaded(chunk_keys: Array) -> void:
	for ck in chunk_keys:
		preload_chunk(ck)


## 卸载 chunk：把内存中该 chunk 的数据按需写回磁盘（修改过的写盘、变空的清盘、
## 未修改且磁盘已有的直接丢弃），然后释放内存缓冲。
## 仅数据层流式启用时有效；无 stream 时返回 false（不卸载，避免数据丢失）。
func unload_chunk(chunk_key: Vector3i) -> bool:
	if stream == null:
		return false
	if not _chunk_buffers.has(chunk_key):
		return false
	if _dirty_chunks.has(chunk_key):
		if _chunk_voxel_counts.get(chunk_key, 0) > 0:
			stream.save_chunk(chunk_key, _chunk_buffers[chunk_key])
			_persisted_chunks[chunk_key] = true
		elif _persisted_chunks.has(chunk_key):
			stream.erase_chunk(chunk_key)
			_persisted_chunks.erase(chunk_key)
		_dirty_chunks.erase(chunk_key)
	_voxel_count -= _chunk_voxel_counts.get(chunk_key, 0)
	_chunk_voxel_counts.erase(chunk_key)
	_chunk_buffers.erase(chunk_key)
	return true


## 从流读取 chunk 数据（不缓存到内存，供全量序列化等一次性场景）
func _load_chunk_from_stream(chunk_key: Vector3i) -> PackedInt32Array:
	if stream == null:
		return PackedInt32Array()
	return stream.load_chunk(chunk_key)


## 获取内存中已加载的 chunk key 列表（流式卸载调度用）
func get_loaded_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
	return keys


## 获取磁盘上已持久化但不在内存的 chunk key 列表（流式补建调度用）
func get_unloaded_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if stream == null:
		return keys
	for ck: Vector3i in _persisted_chunks:
		if not _chunk_buffers.has(ck):
			keys.append(ck)
	return keys


## 把内存中所有被修改的 chunk 写回磁盘（存档 / 退出前调用）
func flush() -> void:
	if stream == null:
		return
	for ck in _dirty_chunks.keys():
		var buf: PackedInt32Array = _chunk_buffers.get(ck)
		if buf == null:
			_dirty_chunks.erase(ck)
			continue
		if _chunk_voxel_counts.get(ck, 0) > 0:
			stream.save_chunk(ck, buf)
			_persisted_chunks[ck] = true
		elif _persisted_chunks.has(ck):
			stream.erase_chunk(ck)
			_persisted_chunks.erase(ck)
	_dirty_chunks.clear()
	stream.flush()


## 构建期/读档批量填充 {pos: mat_id}，不追踪 dirty_voxels、不触发信号。
## 适合一次性生成大量静态体素（demo 场景构建、外部数据导入）。
## 绕过增量维护，直接写 chunk 密集缓冲（不建立支撑缓存，失稳检测实时查询）。
func load_voxels_dict(dict: Dictionary) -> void:
	for pos_key in dict:
		_write_buffer_impl(pos_key, dict[pos_key], false)


## 获取所有有数据的 chunk key（内存 + 磁盘流中已持久化的）
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
		seen[ck] = true
	if stream != null:
		for ck: Vector3i in _persisted_chunks:
			if not seen.has(ck):
				keys.append(ck)
				seen[ck] = true
	return keys


## 获取 chunk 的 18³ 密集"光环缓冲"（值 = 材质ID，0 = 空）。
## 覆盖 chunk 内部 + 1 体素外缘，供网格生成在子线程中只读使用（独立的深拷贝，无数据竞态）。
## 邻居读取全为数组下标且无越界检查（光环含完整 6 邻）。
## 流式模式下先确保 chunk 及其 27 邻居已加载（跨界面的面可见性需要邻居）。
func get_chunk_halo(chunk: Vector3i) -> PackedInt32Array:
	if stream != null:
		for nz in 3:
			for ny in 3:
				for nx in 3:
					preload_chunk(chunk + Vector3i(nx - HALO, ny - HALO, nz - HALO))
	return VoxelChunkGenerator.build_halo_from_buffers(_chunk_buffers, chunk)


## 生成"受影响区域"的 chunk 缓冲深拷贝快照（chunk key → PackedInt32Array 独立副本）。
## 只快照 rebuild_chunks 及其 27 邻居（构建 halo 需要），避免整世界深拷贝。
## 主线程一次性调用，随后供各子线程 worker 从快照构建自己的 halo（线程安全只读）。
## 流式模式下先把相关 chunk 从磁盘载入内存，确保快照包含磁盘上的数据。
func snapshot_chunks_halo(rebuild_chunks: Array[Vector3i]) -> Dictionary:
	if stream != null:
		for ck in rebuild_chunks:
			for nz in 3:
				for ny in 3:
					for nx in 3:
						preload_chunk(ck + Vector3i(nx - HALO, ny - HALO, nz - HALO))
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
## 流式模式下合并磁盘流中已持久化但不在内存的 chunk（临时加载，不缓存）
func get_voxels_dict_snapshot() -> Dictionary[Vector3i, int]:
	var out := {}
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out[origin + _local_from_index(i)] = buf[i]
		seen[ck] = true
	if stream != null:
		for ck: Vector3i in _persisted_chunks:
			if seen.has(ck):
				continue
			var buf := _load_chunk_from_stream(ck)
			if buf.is_empty():
				continue
			var origin := VoxelChunk.origin_of(ck)
			for i in CHUNK_VOLUME:
				if buf[i] > 0:
					out[origin + _local_from_index(i)] = buf[i]
	return out


# ----------------------------------------------------------------------------
# 基本访问
# ----------------------------------------------------------------------------

## 获取指定位置的体素材质ID，不存在返回 -1
## 流式模式下若该 chunk 在磁盘上有数据则自动载入内存（保证读语义一致）
func get_voxel(pos: Vector3i) -> int:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		if stream != null and _persisted_chunks.has(ck):
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			return -1
	var v: int = buf[_buf_index(pos - ck * CHUNK_SIZE)]
	return v if v > 0 else -1


## 是否存在体素（流式模式下磁盘上的 chunk 会自动载入内存）
func has_voxel(pos: Vector3i) -> bool:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		if stream != null and _persisted_chunks.has(ck):
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			return false
	return buf[_buf_index(pos - ck * CHUNK_SIZE)] > 0


## 获取所有体素位置（内存 + 磁盘流中已持久化的，磁盘部分临时加载不缓存）
func get_positions() -> Array:
	var out: Array = []
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out.append(origin + _local_from_index(i))
		seen[ck] = true
	if stream != null:
		for ck: Vector3i in _persisted_chunks:
			if seen.has(ck):
				continue
			var buf := _load_chunk_from_stream(ck)
			if buf.is_empty():
				continue
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
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	_remove_voxels([pos], notify)


## 清空所有体素（同时清除磁盘流中的持久化数据）
func clear(notify: bool = true) -> void:
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				dirty_voxels[origin + _local_from_index(i)] = -1
	_chunk_buffers.clear()
	_chunk_voxel_counts.clear()
	_voxel_count = 0
	_dirty_chunks.clear()
	if stream != null:
		for ck: Vector3i in _persisted_chunks:
			stream.erase_chunk(ck)
		_persisted_chunks.clear()
	if notify:
		emit_changed()


## 合并另一个资源中的体素 (可带偏移)
## 直接遍历 other 的 chunk 密集缓冲（单趟，避免 get_positions+get_voxel 两趟扫描）
func merge(other: VoxelData, offset: Vector3i = Vector3i.ZERO, notify: bool = true) -> void:
	for ck: Vector3i in other._chunk_buffers:
		var buf = other._chunk_buffers[ck]
		var o_origin: Vector3i = VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			var mat_id: int = buf[i]
			if mat_id <= 0:
				continue
			var dst: Vector3i = o_origin + VoxelChunk.local_from_index(i) + offset
			_write_buffer_impl(dst, mat_id, false)
			dirty_voxels[dst] = mat_id
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
			if stream != null and _persisted_chunks.has(ck):
				# 流式：磁盘上的 chunk 载入内存再查询（保证范围查询覆盖持久化数据）
				preload_chunk(ck)
			else:
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
			if stream != null and _persisted_chunks.has(ck):
				# 流式：磁盘上的 chunk 载入内存再查询
				preload_chunk(ck)
			else:
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
	for p in positions:
		var pos: Vector3i = p
		_write_buffer_impl(pos, material_id, false)
		dirty_voxels[pos] = material_id
	if notify:
		emit_changed()


## 批量移除指定位置的体素 (内部统一实现，供各 remove_* 复用)
## 按 chunk 分组处理：chunk 查询 / buf 读取 / dirty 标记每 chunk 一次，
## 替代逐体素重复（大批量崩塌移除 4096 体素时显著提速，避免每帧主线程卡顿）。
func _remove_voxels(positions: Array, notify: bool = true) -> Array:
	if positions.is_empty():
		return []
	if stream != null:
		# 流式：确保涉及 chunk 已加载（磁盘上的 chunk 未加载时删除会被跳过 → 数据丢失）
		var _preload_ck := {}
		for pos in positions:
			_preload_ck[_chunk_of(pos)] = true
		for ck in _preload_ck:
			preload_chunk(ck)
	var _diag_t0 := Time.get_ticks_usec()
	# 按 chunk 分组（positions → {ck: [pos, ...]}）
	var by_chunk: Dictionary = {}
	for pos in positions:
		var ck := _chunk_of(pos)
		var arr: Variant = by_chunk.get(ck)
		if arr == null:
			arr = []
			by_chunk[ck] = arr
		arr.append(pos)
	var touched: Dictionary = {}
	for ck in by_chunk:
		var buf = _chunk_buffers.get(ck)
		if buf == null:
			continue
		touched[ck] = true
		# 流式：批量删除同样标记写盘（否则 chunk 被流式卸载时未 dirty → 直接丢弃，
		# 磁盘旧数据残留导致重载后体素"复活"）
		_dirty_chunks[ck] = true
		var origin := VoxelChunk.origin_of(ck)
		var entries: Array = by_chunk[ck]
		for pos in entries:
			dirty_voxels[pos] = -1
			var idx := _buf_index(pos - origin)
			if buf[idx] > 0:
				buf[idx] = 0
				_voxel_count -= 1
				_chunk_voxel_counts[ck] = _chunk_voxel_counts.get(ck, 0) - 1
	# 批量移除后统一回收被清空的 chunk 键（O(1) 计数判断，替代逐体素 4096 扫描）
	for ck in touched:
		_maybe_erase_empty_chunk(ck)
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


## 序列化所有体素（内存 + 磁盘流中已持久化的数据）。
## 流式模式下磁盘数据由 stream 管理，一次性全量存档时需合并；
## 磁盘部分临时加载，不污染内存缓存。
## save_data()（显式存档）使用此完整版；资源持久化（_get）仍走 _serialize_voxels
## （仅内存，避免编辑器保存触发海量 IO——流式数据本身就在磁盘上）。
func _serialize_all_voxels() -> Array:
	var voxel_list := _serialize_voxels()
	if stream == null:
		return voxel_list
	var seen := {}
	for ck in _chunk_buffers:
		seen[ck] = true
	for ck: Vector3i in _persisted_chunks:
		if seen.has(ck):
			continue
		var buf := _load_chunk_from_stream(ck)
		if buf.is_empty():
			continue
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				var p := origin + _local_from_index(i)
				voxel_list.append([p.x, p.y, p.z, buf[i]])
	return voxel_list


## 从 [[x, y, z, mat_id], ...] 重建体素（直接写 chunk 密集缓冲，不追踪 dirty_voxels）
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
	# 体素序列化（复用唯一权威序列化器；流式模式下含磁盘持久化数据）
	data["voxels"] = _serialize_all_voxels()
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
	emit_changed()


## 获取指定 chunk 内的所有体素位置（基于密集缓冲扫描）
## 返回 Array[Vector3i]（体素位置列表），空 chunk 返回空数组
func get_chunk_voxels(chunk_key: Vector3i) -> Array:
	if not _chunk_buffers.has(chunk_key) and stream != null and _persisted_chunks.has(chunk_key):
		# 流式：磁盘上的 chunk 载入内存再遍历（保证结果完整）
		preload_chunk(chunk_key)
	var buf = _chunk_buffers.get(chunk_key)
	if buf == null:
		return []
	var result: Array = []
	var origin := VoxelChunk.origin_of(chunk_key)
	for i in CHUNK_VOLUME:
		if buf[i] > 0:
			result.append(origin + _local_from_index(i))
	return result


## O(1) 判断指定 chunk 是否有数据（内存或磁盘流中）
func has_chunk(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key) or (stream != null and _persisted_chunks.has(chunk_key))


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


## 找出"悬空"体素（连通性检测，原生 C++ 实现）：只检查 removed 附近可能失稳的体素
##
## 算法（业界标准做法，与 Minecraft 沙砾 / Teardown 类破坏游戏一致）：
##   体素稳定 ⟺ 与地面（y<=0）6 方向连通。
##   破坏移除 R 后，从 R 的 6 方向邻居 + 正上方列扫描收集候选；
##   对每个候选做局部 6 方向 BFS：若所在连通分量含地面 → 稳定；否则该分量整体悬空。
##
## 效果真实（区别于"只正下方"的一刀切）：
##   - 台阶/斜坡：斜向通过水平+垂直连到地面 → 稳定不掉
##   - 悬空平台（多柱支撑）：平台通过柱子连通地面 → 稳定
##   - 外墙底部被破坏但侧连完好墙（连地面）→ 稳定；完全断连 → 掉落
##
## 性能（局部 + 早停）：
##   - 只从破坏点附近候选出发，不遍历整世界
##   - 共享 visited 去重；BFS 遇到地面提前终止（稳定分量不用遍历完）
##   - 悬空分量必须完整遍历（需要移除），规模受破坏影响区域限制
##
## 实现完全在 GDExtension (C++) 中，无 GDScript 兜底。
## 返回失稳体素位置集合 {pos: true}
func find_unsupported_around(removed: Array) -> Dictionary:
	if removed.is_empty() or _chunk_buffers.is_empty():
		return {}
	if not NativeLoader.is_available():
		push_error("[VoxelData] find_unsupported_around 需要原生库 VoxelNative，未加载则无法进行崩塌检测")
		return {}
	return NativeLoader.find_unsupported_around(_chunk_buffers, removed)
