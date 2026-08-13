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
		# 程序化流：把本数据层的 grid_size（体素世界尺寸）同步给流做有限范围限制。
		# 流按此 AABB 只生成世界范围内 chunk（地面矩形地图）；无限流传 ZERO 自动关闭。
		if stream is VoxelProceduralStream:
			(stream as VoxelProceduralStream).set_grid_size(grid_size)
		if stream != null:
			for ck in stream.get_all_chunk_keys():
				_persisted_chunks[ck] = true

## 居中偏移 (体素单位，运行时渲染时叠加到网格顶点)
## 导入时若 center 选项开启，自动计算使模型左右前后居中(X/Z)、上下贴底(Y=0)
## 与 mesh 导入的居中策略一致，数据坐标仍保持在 [0, grid_size) 范围内
## 运行时渲染: 网格顶点 = (体素坐标 + center_offset) * voxel_scale
## 该偏移不影响破坏/查询逻辑 (它们基于原始数据坐标)
@export var center_offset: Vector3 = Vector3.ZERO

## 本次变更涉及的体素集合（单格 set_voxel/remove_voxel 记录；大批量修改走 chunk 级
## _dirty_mesh_chunks，不写此字典避免大崩塌主线程 dict 写入瓶颈）。
## 注：渲染器增量重建基于 chunk 级 _dirty_mesh_chunks，此集合无内部消费，仅对外提供。
var dirty_voxels: Dictionary[Vector3i, int] = {}

## 脏 mesh chunk（chunk 级，供渲染器增量重建）。大批量修改标记到 chunk 粒度，
## 替代逐体素 dirty_voxels 的主线程 dict 写入瓶颈。含跨界面的边界邻居。
var _dirty_mesh_chunks: Dictionary = {}

## 标记体素所在 chunk 需要重建（含 6 个跨界面的边界邻居——面可见性依赖邻居）。
## 大批量修改（_remove_voxels/set_voxels）走此路径；单格 set_voxel 也调用。
func _mark_voxel_dirty(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	_dirty_mesh_chunks[ck] = true
	# LOD0 用户编辑 → 失效对应高层 block 并标记需降采样（编辑数据不能用纯生成器输出）
	mark_lod_modified(pos)
	var local := pos - ck * CHUNK_SIZE
	if local.x == 0:
		_dirty_mesh_chunks[ck + Vector3i(-1, 0, 0)] = true
	elif local.x == CHUNK_SIZE - 1:
		_dirty_mesh_chunks[ck + Vector3i(1, 0, 0)] = true
	if local.y == 0:
		_dirty_mesh_chunks[ck + Vector3i(0, -1, 0)] = true
	elif local.y == CHUNK_SIZE - 1:
		_dirty_mesh_chunks[ck + Vector3i(0, 1, 0)] = true
	if local.z == 0:
		_dirty_mesh_chunks[ck + Vector3i(0, 0, -1)] = true
	elif local.z == CHUNK_SIZE - 1:
		_dirty_mesh_chunks[ck + Vector3i(0, 0, 1)] = true


## 标记单个 chunk 需要重建（补建/流式加载路径用）
func _mark_chunk_dirty(ck: Vector3i) -> void:
	_dirty_mesh_chunks[ck] = true


# ----------------------------------------------------------------------------
# LOD 支持（多层级：LOD0 = CHUNK_SIZE³ 全精度 chunk；LOD i = LOD_GRID³ 大块，每格代表 2^i 体素）
#   block_key = LOD0 chunk_key >> i（每 2^i × 2^i × 2^i 个 chunk 一个 block）
#   block 覆盖 (LOD_GRID × 2^i)³ 体素，内部 LOD_GRID³ 个大格（降采样 2^i³ 体素 → 1 大格）
#   层级数由 lod_count 控制（渲染器同步设置），默认 2 = 原行为（LOD0 + LOD1 2×）
# ----------------------------------------------------------------------------
## LOD 层级数（含 LOD0）。编辑体素时按此失效所有更高层 block；1 = 仅全精度无 LOD。
@export var lod_count: int = 2

## 大块网格边长（大格数，每格 = 2^lod 体素）；恒等于 CHUNK_SIZE（与原生 32³ 网格核心一致）
const LOD_GRID := VoxelChunk.CHUNK_SIZE

# 每级失效的 block（index = lod；LOD0 数据变化时记录，渲染器消费后重建远距离网格）
var _lod_invalidated: Array[Dictionary] = []


## 失效体素所在 chunk 对应的所有更高层 LOD block（LOD0 数据变化后调用）。
## 仅失效网格重建（数据回填/程序化生成也会触发，见 accept_chunk_buffer）；
## 用户编辑额外标记 modified 用 mark_lod_modified*。
func invalidate_lod(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	for lod in range(1, maxi(lod_count, 1)):
		_mark_lod_invalid(Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod), lod)


## 失效指定 LOD0 chunk 对应的所有更高层 LOD block（仅网格重建，不标记 modified）
func invalidate_lod_for_chunk(ck: Vector3i) -> void:
	for lod in range(1, maxi(lod_count, 1)):
		_mark_lod_invalid(Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod), lod)


## 用户编辑体素：失效高层 block 并标记"需降采样"（编辑影响该 block，不能用纯生成器数据），
## 同时从独立数据层移除缓存（下次重生成时降采样合并编辑）。
func mark_lod_modified(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		erase_lod_block(lod, bk)


## 用户编辑 chunk（批量）：标记覆盖它的所有高层 block 需降采样（同上）
func mark_lod_modified_for_chunk(ck: Vector3i) -> void:
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		erase_lod_block(lod, bk)


## 记录指定层级 block 失效（通知渲染器重建）
func _mark_lod_invalid(block_key: Vector3i, lod: int) -> void:
	while _lod_invalidated.size() <= lod:
		_lod_invalidated.append({})
	_lod_invalidated[lod][block_key] = true


## 标记粗层 block 需降采样（编辑影响该 block，不能用纯生成器数据）
func _mark_coarse_modified(block_key: Vector3i, lod: int) -> void:
	if lod < 1:
		return
	while _coarse_modified.size() <= lod - 1:
		_coarse_modified.append({})
	_coarse_modified[lod - 1][block_key] = true


## 清空所有层级失效标记
func clear_lod_cache() -> void:
	for d in _lod_invalidated:
		d.clear()


## 获取指定层级的失效 block（渲染器 _process_lod 消费后重建），并清空
func get_invalidated_lod(lod: int) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if lod >= 0 and lod < _lod_invalidated.size():
		var d := _lod_invalidated[lod]
		for k in d:
			keys.append(k)
		d.clear()
	return keys


## 是否有失效的粗层 block 待重建（渲染器据此在数据变化时立即触发 LOD 处理，不等降频周期）
func has_lod_invalidated() -> bool:
	for d in _lod_invalidated:
		if not d.is_empty():
			return true
	return false


## 获取所有脏 chunk（渲染器增量重建用），并清空
func get_dirty_chunks() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck in _dirty_mesh_chunks:
		keys.append(ck)
	_dirty_mesh_chunks.clear()
	return keys


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

## 每粗 LOD 独立数据层：_coarse_buffers[level-1] = {block_key: PackedInt32Array(LOD_GRID³ 大格)}
## 值 = 材质ID（0=空），每格 = 2^level 体素。与 Voxel Tools 一致：各 LOD 数据块独立，
## 未修改的粗层 block 由生成器 _generate_chunk_lod 直接生成（无需加载全部 LOD0 chunk）。
var _coarse_buffers: Array[Dictionary] = []

## 需降采样回退的粗 LOD block（编辑传播标记）：_coarse_modified[level-1] = {block_key: true}。
## LOD0 编辑影响该 block 时标记，下次渲染走降采样（合并 LOD0 数据）而非生成器。
var _coarse_modified: Array[Dictionary] = []

## 文件流粗层降采样任务去重：_lod_downsample_pending[level-1] = {block_key: true}。
## 文件流（VoxelFileStream 无粗层生成器）的粗层数据从 LOD0 chunk 降采样生成，结果缓存到
## _coarse_buffers（移动复用）并持久化到文件流（重启保留），避免每次渲染都重复降采样。
var _lod_downsample_pending: Array[Dictionary] = []

## 降采样空结果重试计数：_lod_downsample_retries[level-1] = {block_key: n}。
## 自动 request 可能早于 LOD0 chunk 加载（相机移动时前方 chunk 未就绪 → 快照空），
## 空结果延迟重试（上限 3 次）等 LOD0 就绪，防空区域死循环。
var _lod_downsample_retries: Array[Dictionary] = []

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

## 配置数据层流（等价于设置 stream 属性，供代码动态切换，触发 stream setter 的
## flush 旧流 + 恢复新流已持久化索引逻辑）。
func set_stream(s: VoxelStream) -> void:
	stream = s


## 数据层流式是否启用
func is_streaming() -> bool:
	return stream != null


## chunk 是否在内存中（有密集缓冲）。has_chunk 的严格子集（仅内存，不含磁盘）。
func is_chunk_loaded(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key)


## 从流加载 chunk 数据到内存。已加载返回 true；流中不存在返回 false。
## 流式补建/网格生成前调用，保证后续读操作走内存数组。
func preload_chunk(chunk_key: Vector3i) -> bool:
	if _chunk_buffers.has(chunk_key):
		return true
	if stream == null:
		return false
	# 数据可用性：磁盘持久化(缓存索引) 或 程序化流(任意 chunk 可生成)
	var available := _persisted_chunks.has(chunk_key)
	if not available and stream is VoxelProceduralStream:
		available = stream.has_chunk(chunk_key)
	if not available:
		return false
	# 程序化流 + 数据不在内存（非持久化）：提交后台生成并返回 false，不在主线程同步
	# 生成（网格/LOD1 的 halo snapshot 大量调用会卡顿）。就绪后由 accept_chunk_buffer 回填。
	if stream is VoxelProceduralStream and not _persisted_chunks.has(chunk_key):
		(stream as VoxelProceduralStream).request_chunk_async(chunk_key)
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


## 回填统一异步流式结果（程序化后台生成 / 文件流 region 读盘，主线程调用）。
## 按 lod 分流：lod=0 存全精度 chunk；lod>=1 存粗层 32³ 大格数据。
## 已存在则忽略。与 preload_chunk 不同：数据来自异步队列，无需再走 stream.load_chunk。
func accept_chunk_buffer(chunk_key: Vector3i, buf: PackedInt32Array, lod: int = 0) -> void:
	if lod == 0:
		if _chunk_buffers.has(chunk_key):
			return
		if buf.size() != CHUNK_VOLUME:
			return
		_chunk_buffers[chunk_key] = buf
		var cnt := 0
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				cnt += 1
		_chunk_voxel_counts[chunk_key] = cnt
		_voxel_count += cnt
		# 数据就绪 → 标记网格重建。未修改的粗层块用独立数据层，不依赖 LOD0 回填，
		# 无需失效（否则每回填一个 chunk 就递增渲染器全局 gen_id，作废全部在途粗层任务）；
		# 仅"需降采样(用户编辑)"的粗层块在 LOD0 数据就绪后失效重建。
		_dirty_mesh_chunks[chunk_key] = true
		for lv in range(1, maxi(lod_count, 1)):
			var bk := Vector3i(chunk_key.x >> lv, chunk_key.y >> lv, chunk_key.z >> lv)
			if is_lod_block_modified(lv, bk):
				_mark_lod_invalid(bk, lv)
		return
	if has_lod_block(lod, chunk_key):
		return
	if buf.size() != LOD_GRID * LOD_GRID * LOD_GRID:
		return
	set_lod_block(lod, chunk_key, buf)
	# 数据就绪 → 标记对应 block 网格重建
	_dirty_mesh_chunks[chunk_key] = true


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


## 平移所有 chunk key（origin shift 用）：数据层坐标整体偏移，保持世界连续。
## 相机远离时调用，使相机附近 chunk 回到小坐标，避免 float 精度损失。
## offset = 平移的 chunk 数（世界体素 = chunk×16）。
func shift_origin(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	_chunk_buffers = _shift_dict_keys(_chunk_buffers, offset)
	_chunk_voxel_counts = _shift_dict_keys(_chunk_voxel_counts, offset)
	_persisted_chunks = _shift_dict_keys(_persisted_chunks, offset)
	_dirty_chunks = _shift_dict_keys(_dirty_chunks, offset)
	_dirty_mesh_chunks = _shift_dict_keys(_dirty_mesh_chunks, offset)
	var ndv: Dictionary[Vector3i, int] = {}
	for k in dirty_voxels:
		ndv[Vector3i(k) + offset] = dirty_voxels[k]
	dirty_voxels = ndv
	for i in _lod_invalidated.size():
		_lod_invalidated[i] = _shift_dict_keys(_lod_invalidated[i], offset)
	for i in _coarse_buffers.size():
		_coarse_buffers[i] = _shift_dict_keys(_coarse_buffers[i], offset)
	for i in _coarse_modified.size():
		_coarse_modified[i] = _shift_dict_keys(_coarse_modified[i], offset)
	if stream is VoxelProceduralStream:
		(stream as VoxelProceduralStream).shift_origin(offset)


static func _shift_dict_keys(d: Dictionary, offset: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + offset] = d[k]
	return nd


## 获取 chunk 的 18³ 密集"光环缓冲"（值 = 材质ID，0 = 空）。
## 覆盖 chunk 内部 + 1 体素外缘，供网格生成在子线程中只读使用（独立的深拷贝，无数据竞态）。
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
## 快照本身由原生 C++ 完成：COW 共享 PackedInt32Array（原子 refcount，worker 只读，
## 主线程后续写 buffers 触发写时拷贝）→ 省去逐 chunk 64KB 深拷贝（大场景快照提速）。
func snapshot_chunks_halo(rebuild_chunks: Array[Vector3i]) -> Dictionary:
	if stream != null:
		for ck in rebuild_chunks:
			for nz in 3:
				for ny in 3:
					for nx in 3:
						preload_chunk(ck + Vector3i(nx - HALO, ny - HALO, nz - HALO))
	return NativeLoader.snapshot_chunks_halo(_chunk_buffers, rebuild_chunks)


## LOD 大块（LOD_GRID³ 大格 = 每格 2^lod 体素，覆盖 2^lod³ 个 chunk）异步生成快照：
## 大块覆盖的 2^lod³ 个 chunk + 外扩 ±2^lod 层 chunk（halo 边界大格降采样需要），COW 共享。
## 仅 preload 大块自身 chunk（必须）；外部从内存快照（LOD 区数据保留，磁盘不 preload）。
## lod=1 即原 LOD1（2×2×2 chunk）。
func snapshot_lod_block_chunks(block_key: Vector3i, lod: int) -> Dictionary:
	var chunks_per_axis := 1 << lod
	var cks: Array[Vector3i] = []
	var seen := {}
	var base := block_key * chunks_per_axis
	for cz in chunks_per_axis:
		for cy in chunks_per_axis:
			for cx in chunks_per_axis:
				var ck := base + Vector3i(cx, cy, cz)
				cks.append(ck)
				seen[ck] = true
				preload_chunk(ck)
	for oz in range(-chunks_per_axis, 3 * chunks_per_axis):
		for oy in range(-chunks_per_axis, 3 * chunks_per_axis):
			for ox in range(-chunks_per_axis, 3 * chunks_per_axis):
				var ck := base + Vector3i(ox, oy, oz)
				if not seen.has(ck) and _chunk_buffers.has(ck):
					seen[ck] = true
					cks.append(ck)
	return NativeLoader.snapshot_chunks_halo(_chunk_buffers, cks)


# ----------------------------------------------------------------------------
# 每 LOD 独立数据层（Voxel Tools 式：粗 LOD block 数据独立，未修改块由生成器直接生成）
# ----------------------------------------------------------------------------

func _ensure_coarse_arrays(level: int) -> void:
	while _coarse_buffers.size() <= level - 1:
		_coarse_buffers.append({})
	while _coarse_modified.size() <= level - 1:
		_coarse_modified.append({})


## 取指定 LOD 的数据块（level 0 = LOD0 chunk；>=1 = 粗层 32³ 大格数据）。无则返回空数组。
func get_lod_block(level: int, key: Vector3i) -> PackedInt32Array:
	if level == 0:
		return _chunk_buffers.get(key, PackedInt32Array())
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return PackedInt32Array()
	return _coarse_buffers[idx].get(key, PackedInt32Array())


func has_lod_block(level: int, key: Vector3i) -> bool:
	if level == 0:
		return _chunk_buffers.has(key)
	var idx := level - 1
	return idx < _coarse_buffers.size() and _coarse_buffers[idx].has(key)


func set_lod_block(level: int, key: Vector3i, buf: PackedInt32Array) -> void:
	if level == 0:
		_chunk_buffers[key] = buf
		return
	_ensure_coarse_arrays(level)
	_coarse_buffers[level - 1][key] = buf


func erase_lod_block(level: int, key: Vector3i) -> void:
	if level == 0:
		_chunk_buffers.erase(key)
		return
	var idx := level - 1
	if idx < _coarse_buffers.size():
		_coarse_buffers[idx].erase(key)


## 指定 LOD 层的所有数据块 key
func get_lod_block_keys(level: int) -> Array:
	if level == 0:
		return _chunk_buffers.keys()
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return []
	return _coarse_buffers[idx].keys()


## 修改过的粗层 block 写盘（stream 记录修改），再释放内存（卸载时调用）
func flush_lod_block(level: int, key: Vector3i) -> void:
	var buf := get_lod_block(level, key)
	var s := stream
	if s != null and buf.size() > 0:
		s.save_chunk(key, buf, level)
	erase_lod_block(level, key)


## 该粗层 block 是否被编辑过（需降采样合并 LOD0 数据，而非纯生成器输出）
func is_lod_block_modified(level: int, key: Vector3i) -> bool:
	var idx := level - 1
	return idx < _coarse_modified.size() and _coarse_modified[idx].has(key)


## 请求异步生成/加载 chunk/block 数据（后台线程：程序化走生成器，文件流走 region 读盘）。
## 统一带 lod 参数（0 = LOD0 chunk，>=1 = 粗层 block）。数据就绪后经 poll_all_ready 回填。
func request_chunk_async(chunk_key: Vector3i, lod: int = 0) -> void:
	if has_lod_block(lod, chunk_key):
		return
	var s := stream
	if s != null and s.has_method("request_chunk_async"):
		s.request_chunk_async(chunk_key, lod)
	# 文件流粗层：先查持久化（region 已存降采样缓存）→ 直接读回填；无 → 从 LOD0 降采样生成（后台）并持久化
	if lod >= 1 and s is VoxelFileStream and not has_lod_block(lod, chunk_key):
		if s.has_chunk(chunk_key, lod):
			var buf := s.load_chunk(chunk_key, lod)
			if buf.size() > 0:
				set_lod_block(lod, chunk_key, buf)
		else:
			_start_lod_downsample(chunk_key, lod)


## 文件流粗层降采样任务去重（_lod_downsample_pending[level-1]）
## 数据在主线程构造快照（preload 磁盘回读 + 内存读取），避免后台线程读 _chunk_buffers 撞 COW 旧副本。
func _start_lod_downsample(block_key: Vector3i, lod: int) -> void:
	while _lod_downsample_pending.size() <= lod - 1:
		_lod_downsample_pending.append({})
	if _lod_downsample_pending[lod - 1].has(block_key):
		return
	_lod_downsample_pending[lod - 1][block_key] = true
	var cell := 1 << lod
	var chunks_per_block := (VoxelChunkGenerator.LOD_BLOCK_SIZE * cell) / VoxelChunk.CHUNK_SIZE
	var base_chunk := block_key * chunks_per_block
	var buffers := {}
	for cz in chunks_per_block:
		for cy in chunks_per_block:
			for cx in chunks_per_block:
				var ck := base_chunk + Vector3i(cx, cy, cz)
				if not _chunk_buffers.has(ck):
					preload_chunk(ck)
				if _chunk_buffers.has(ck):
					buffers[ck] = _chunk_buffers[ck]
	if buffers.is_empty():
		call_deferred("_on_lod_downsample_ready", block_key, lod, PackedInt32Array())
		return
	WorkerThreadPool.add_task(_lod_downsample_worker.bind(block_key, lod, buffers))


## 后台线程：从 LOD0 chunk 数据降采样生成粗层 block 数据（32³ 大格，每格 = 2^lod 体素）。
## buffers 为主线程快照（引用共享，只读安全），结果经 call_deferred 回主线程。
func _lod_downsample_worker(block_key: Vector3i, lod: int, buffers: Dictionary) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, block_key, lod)
	var g := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var hs := VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var off := VoxelChunkGenerator.LOD_BLOCK_HALO
	var buf := PackedInt32Array()
	buf.resize(g * g * g)
	for lz in g:
		for ly in g:
			for lx in g:
				buf[lx + ly * g + lz * g * g] = halo[(off + lx) + (off + ly) * hs + (off + lz) * hs * hs]
	call_deferred("_on_lod_downsample_ready", block_key, lod, buf)


## 主线程：粗层降采样完成 → 缓存 _coarse_buffers + 持久化文件流（重启保留），供渲染器复用
func _on_lod_downsample_ready(block_key: Vector3i, lod: int, buf: PackedInt32Array) -> void:
	if lod - 1 < _lod_downsample_pending.size():
		_lod_downsample_pending[lod - 1].erase(block_key)
	if buf.is_empty():
		# LOD0 chunk 可能尚未加载（自动 request 早于 LOD0 就绪，或覆盖 chunk 仅存磁盘）→
		# 主线程 preload 覆盖 chunk 后重试，上限防空区域死循环
		_retry_lod_downsample(block_key, lod)
		return
	if lod - 1 < _lod_downsample_retries.size():
		_lod_downsample_retries[lod - 1].erase(block_key)
	set_lod_block(lod, block_key, buf)
	if stream is VoxelFileStream:
		stream.save_chunk(block_key, buf, lod)


## 粗层降采样空结果延迟重试：LOD0 chunk 常晚于粗层 request 就绪（流式加载），
## 延迟 0.5s 跨帧重试（preload 会在 _start_lod_downsample 内执行），5 次上限防空区域死循环。
func _retry_lod_downsample(block_key: Vector3i, lod: int) -> void:
	while _lod_downsample_retries.size() <= lod - 1:
		_lod_downsample_retries.append({})
	var n: int = _lod_downsample_retries[lod - 1].get(block_key, 0)
	if n >= 5:
		_lod_downsample_retries[lod - 1].erase(block_key)
		return
	_lod_downsample_retries[lod - 1][block_key] = n + 1
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(0.5).timeout.connect(
			func() -> void: _start_lod_downsample(block_key, lod))
	else:
		_start_lod_downsample(block_key, lod)


## 该 chunk/block 是否已有后台生成任务进行中或结果就绪（渲染器每帧预算限流用，避免重复提交）。
## 程序化流有内部异步队列；无该方法的数据源视为无防重需求（返回 false）。
func is_chunk_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	if has_lod_block(lod, chunk_key):
		return true
	var s := stream
	if s != null and s.has_method("is_chunk_pending"):
		if s.is_chunk_pending(chunk_key, lod):
			return true
	# 文件流粗层降采样任务进行中（防重复降采样）
	if lod >= 1 and s is VoxelFileStream:
		var idx := lod - 1
		if idx < _lod_downsample_pending.size() and _lod_downsample_pending[idx].has(chunk_key):
			return true
	return false


## 粗 LOD 数据块快照（block 自身 + 27 邻居大格，COW 共享）：供独立数据层网格生成 worker 使用。
func snapshot_lod_block_data(block_key: Vector3i, level: int) -> Dictionary:
	var out := {}
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return out
	var cb: Dictionary = _coarse_buffers[idx]
	for nz in 3:
		for ny in 3:
			for nx in 3:
				var bk := block_key + Vector3i(nx - 1, ny - 1, nz - 1)
				if cb.has(bk):
					out[bk] = cb[bk]
	return out


## 主线程批量取回异步就绪的 chunk/block 数据。返回 [[lod, key, PackedInt32Array], ...]。
func poll_all_ready(max_count: int) -> Array:
	var s := stream
	if s != null and s.has_method("poll_all_ready"):
		return s.poll_all_ready(max_count)
	return []


# ----------------------------------------------------------------------------
# 基本访问
# ----------------------------------------------------------------------------

## 全量体素字典快照 {pos: mat_id}（兼容旧的非 chunk 渲染路径 / 外部一次性读取）
## 流式模式下合并磁盘流中已持久化但不在内存的 chunk（临时加载，不缓存）
## 遍历所有内存中的非空体素，调用 cb(pos: Vector3i, mat_id: int)。
## 内部迭代统一入口：get_positions / get_voxels_dict_snapshot / get_voxels_aabb /
## _serialize_voxels 等"全量扫非空体素"方法复用，避免重复同一嵌套循环。
## 注：非热路径（热路径均走原生 C++）；稀疏迭代回调开销可接受。
func _for_each_non_empty_voxel(cb: Callable) -> void:
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				cb.call(origin + _local_from_index(i), buf[i])


func get_voxels_dict_snapshot() -> Dictionary[Vector3i, int]:
	var out := {}
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		seen[ck] = true
	_for_each_non_empty_voxel(func(pos: Vector3i, mat_id: int): out[pos] = mat_id)
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
		seen[ck] = true
	_for_each_non_empty_voxel(func(pos: Vector3i, mat_id: int): out.append(pos))
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
	_mark_voxel_dirty(pos)
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
		_mark_chunk_dirty(ck)
	_chunk_buffers.clear()
	_chunk_voxel_counts.clear()
	_voxel_count = 0
	_dirty_chunks.clear()
	for d in _coarse_buffers:
		d.clear()
	for d in _coarse_modified:
		d.clear()
	if stream != null:
		for ck: Vector3i in _persisted_chunks:
			stream.erase_chunk(ck)
		_persisted_chunks.clear()
	if notify:
		emit_changed()


## 计算全部体素的包围盒 (AABB)，用于场景摆放/居中；空体素返回零 AABB
## 注：min/max 为值类型，lambda 按值捕获无法回写 → 保持内联循环（_for_each_non_empty_voxel
## 只适合"向引用容器追加"的消费模式）。
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
	var r_i := ceili(radius)
	for ck in overlap_chunks:
		if not _chunk_buffers.has(ck):
			if stream != null and _persisted_chunks.has(ck):
				# 流式：磁盘上的 chunk 载入内存再查询（保证范围查询覆盖持久化数据）
				preload_chunk(ck)
			else:
				continue
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		# 只遍历球 AABB 与 chunk 的交集（避免整 chunk 32³ 全扫，大半径下百倍提速）
		var min_x := maxi(origin.x, cxi - r_i)
		var max_x := mini(origin.x + CHUNK_SIZE - 1, cxi + r_i)
		var min_y := maxi(origin.y, cyi - r_i)
		var max_y := mini(origin.y + CHUNK_SIZE - 1, cyi + r_i)
		var min_z := maxi(origin.z, czi - r_i)
		var max_z := mini(origin.z + CHUNK_SIZE - 1, czi + r_i)
		for z in range(min_z, max_z + 1):
			for y in range(min_y, max_y + 1):
				for x in range(min_x, max_x + 1):
					if buf[(x - origin.x) + (y - origin.y) * CHUNK_SIZE + (z - origin.z) * CHUNK_SLICE] <= 0:
						continue
					var dx: int = x - cxi
					var dy: int = y - cyi
					var dz: int = z - czi
					if float(dx * dx + dy * dy + dz * dz) <= radius_sq:
						result.append(Vector3i(x, y, z))
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
		# 只遍历盒 AABB 与 chunk 的交集（避免整 chunk 32³ 全扫）
		var min_x := maxi(origin.x, floori(aabb.position.x))
		var max_x := mini(origin.x + CHUNK_SIZE - 1, floori(aabb.end.x - 1))
		var min_y := maxi(origin.y, floori(aabb.position.y))
		var max_y := mini(origin.y + CHUNK_SIZE - 1, floori(aabb.end.y - 1))
		var min_z := maxi(origin.z, floori(aabb.position.z))
		var max_z := mini(origin.z + CHUNK_SIZE - 1, floori(aabb.end.z - 1))
		for z in range(min_z, max_z + 1):
			for y in range(min_y, max_y + 1):
				for x in range(min_x, max_x + 1):
					if buf[(x - origin.x) + (y - origin.y) * CHUNK_SIZE + (z - origin.z) * CHUNK_SLICE] <= 0:
						continue
					result.append(Vector3i(x, y, z))
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
## 并标记脏 chunk，让 VoxelRenderer 走增量重建（只重建受影响 chunk）。
## 语义与 set_voxel 一致：material_id <= 0（含 0=空）视为批量移除；已存在体素被覆盖时支撑图不变。
## 性能：走原生 C++ set_voxels_bulk（按 chunk 分组直接改 PackedInt32Array，对称 remove_voxels_bulk），
## 替代旧的逐体素 GDScript 字典写（每体素 5~8 次哈希）；原生不可用时回退逐体素循环。
func set_voxels(positions: Array, material_id: int, notify: bool = true) -> void:
	if positions.is_empty():
		return
	if material_id <= 0:
		_remove_voxels(positions, notify)
		return
	# 确保涉及 chunk 在内存（流式下磁盘数据先 preload，避免原生建空 buffer 覆盖旧数据）。
	# 用原生 collect_chunks 收集去重 chunk（遍历在 C++），避免 GDScript 逐体素计算；
	# 非流式无需 preload，原生 set_voxels_bulk 会为全新 chunk 创建空 buffer。
	if stream != null:
		var ck_list: Array = NativeLoader.collect_chunks(positions)
		if ck_list.is_empty() and not positions.is_empty():
			var need_ck := {}
			for p in positions:
				need_ck[_chunk_of(p)] = true
			ck_list.assign(need_ck.keys())
		for ck in ck_list:
			if not _chunk_buffers.has(ck) and _persisted_chunks.has(ck):
				preload_chunk(ck)
	var res: Dictionary = NativeLoader.set_voxels_bulk(_chunk_buffers, positions, material_id)
	if res.is_empty():
		# 原生不可用/旧库缺方法 → 回退逐体素（保持行为一致）
		for p in positions:
			var pos: Vector3i = p
			_write_buffer_impl(pos, material_id, false)
			_mark_voxel_dirty(pos)
		if notify:
			emit_changed()
		return
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_set: Dictionary = res["chunk_set"]
	for ck in chunk_set:
		_chunk_buffers[ck] = modified_buffers[ck]
		var cnt: int = chunk_set[ck]
		_voxel_count += cnt
		_chunk_voxel_counts[ck] = _chunk_voxel_counts.get(ck, 0) + cnt
		# 流式：批量写入标记写盘（否则 chunk 被流式卸载时未 dirty → 磁盘旧数据残留）
		_dirty_chunks[ck] = true
	# 标记脏 chunk + 跨界面的边界邻居（用 C++ 返回的边界掩码，按 chunk 标记，
	# 避免逐体素 _mark_voxel_dirty 的多词条 dict 写入瓶颈）
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty_mesh_chunks[ck] = true
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		var b: int = boundary[ck]
		if b & 1:
			_dirty_mesh_chunks[ck + Vector3i(1, 0, 0)] = true
		if b & 2:
			_dirty_mesh_chunks[ck + Vector3i(-1, 0, 0)] = true
		if b & 4:
			_dirty_mesh_chunks[ck + Vector3i(0, 1, 0)] = true
		if b & 8:
			_dirty_mesh_chunks[ck + Vector3i(0, -1, 0)] = true
		if b & 16:
			_dirty_mesh_chunks[ck + Vector3i(0, 0, 1)] = true
		if b & 32:
			_dirty_mesh_chunks[ck + Vector3i(0, 0, -1)] = true
	if notify:
		emit_changed()


## 批量移除指定位置的体素 (内部统一实现，供各 remove_* 复用)
## 写 buffer 由原生 C++ 完成（remove_voxels_bulk，按 chunk 分组直接改 PackedInt32Array），
## 替代 GDScript 逐体素循环——大崩塌（每帧 4096+ 体素）主线程大幅提速。
## GDScript 只做计数维护 + 标记脏 chunk（chunk 级 _mark_voxel_dirty，替代逐体素
## dirty_voxels 的 dict 写入瓶颈；边界邻居由 _mark_voxel_dirty 一并标记）。
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
	# 原生批量移除（C++ 按 chunk 分组改 buffer，返回修改后的 buffer + 每 chunk 移除数 + 边界掩码）
	var res: Dictionary = NativeLoader.remove_voxels_bulk(_chunk_buffers, positions)
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_removed: Dictionary = res["chunk_removed"]
	var touched: Dictionary = {}
	for ck in chunk_removed:
		_chunk_buffers[ck] = modified_buffers[ck]  # 覆盖为修改后的 buffer
		var cnt: int = chunk_removed[ck]
		_voxel_count -= cnt
		_chunk_voxel_counts[ck] = _chunk_voxel_counts.get(ck, 0) - cnt
		# 流式：批量删除同样标记写盘（否则 chunk 被流式卸载时未 dirty → 直接丢弃，
		# 磁盘旧数据残留导致重载后体素"复活"）
		_dirty_chunks[ck] = true
		touched[ck] = true
	# 标记脏 chunk + 跨界面的边界邻居（用 C++ 返回的边界掩码，按 chunk 标记，
	# 避免逐体素 7 次 dict 写入的大崩塌瓶颈）
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty_mesh_chunks[ck] = true
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		var b: int = boundary[ck]
		if b & 1:
			_dirty_mesh_chunks[ck + Vector3i(1, 0, 0)] = true
		if b & 2:
			_dirty_mesh_chunks[ck + Vector3i(-1, 0, 0)] = true
		if b & 4:
			_dirty_mesh_chunks[ck + Vector3i(0, 1, 0)] = true
		if b & 8:
			_dirty_mesh_chunks[ck + Vector3i(0, -1, 0)] = true
		if b & 16:
			_dirty_mesh_chunks[ck + Vector3i(0, 0, 1)] = true
		if b & 32:
			_dirty_mesh_chunks[ck + Vector3i(0, 0, -1)] = true
	# 批量移除后统一回收被清空的 chunk 键（O(1) 计数判断）
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
func get_material_by_id(mat_id: int) -> VoxelMaterial:
	return VoxelMaterial.find_by_id(materials, mat_id)


## 触发 changed 信号 (批量修改后手动调用)
func notify_changed() -> void:
	emit_changed()


# ----------------------------------------------------------------------------
# 存档 / 重建
# ----------------------------------------------------------------------------

## 序列化所有体素为 [[x, y, z, mat_id], ...]（统一材质契约：mat_id>=1，0=空 不存在）
## 只序列化内存中的 chunk（资源持久化 / save_data 的基础序列化器）
func _serialize_voxels() -> Array:
	var voxel_list := []
	_for_each_non_empty_voxel(func(pos: Vector3i, mat_id: int):
		voxel_list.append([pos.x, pos.y, pos.z, mat_id]))
	return voxel_list


## 从一组 chunk key 序列化体素为 [[x, y, z, mat_id], ...]。
## 每 chunk 取缓冲：内存优先，否则从流读取（程序化修改块存于 stream._modified /
## 文件流存于 region 文件）。供 _serialize_voxels_for_storage（修改块集）与
## _serialize_all_voxels（磁盘合并）两个全量入口复用同一收集循环。
func _serialize_chunks_to_list(chunk_keys: Array) -> Array:
	var voxel_list := []
	for ck in chunk_keys:
		var ck3: Vector3i = ck
		var buf := _get_chunk_buffer_for_storage(ck3)
		if buf.is_empty():
			continue
		var origin := VoxelChunk.origin_of(ck3)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				var p := origin + _local_from_index(i)
				voxel_list.append([p.x, p.y, p.z, buf[i]])
	return voxel_list


## 收集"需随资源持久化"的 chunk key（程序化流：用户修改过的 = 内存未写盘 _dirty_chunks +
## 流已持久化的修改 get_all_chunk_keys）。非程序化流返回空（由 _serialize_voxels 全量覆盖）。
func _collect_modified_chunk_keys() -> Array:
	var keys := {}
	if stream is VoxelProceduralStream:
		var proc: VoxelProceduralStream = stream
		for ck in _dirty_chunks:
			keys[ck] = true
		for ck in proc.get_all_chunk_keys():
			keys[ck] = true
	var out: Array = []
	for ck in keys:
		out.append(ck)
	return out


## 序列化"需要随资源持久化"的体素（_get 存储专用）。
## 程序化流：只序列化用户修改过的 chunk（未修改的由 _generate_chunk 确定性生成、无需存储——
##   全部序列化会把 .tscn 撑成上百 MB（历史上 734 万体素 → 137MB 的灾难即由此而来））。
## 静态数据（无流 / 文件流）：数据只存在于内存（文件流磁盘为权威），序列化全部内存体素。
func _serialize_voxels_for_storage() -> Array:
	if stream is VoxelProceduralStream:
		var keys := _collect_modified_chunk_keys()
		if keys.is_empty():
			return []
		return _serialize_chunks_to_list(keys)
	return _serialize_voxels()


## 取 chunk 缓冲（内存优先；未加载则从流读取——程序化流修改数据存于 stream._modified / 文件流）
func _get_chunk_buffer_for_storage(chunk_key: Vector3i) -> PackedInt32Array:
	var buf = _chunk_buffers.get(chunk_key)
	if buf != null:
		return buf
	if stream != null:
		return _load_chunk_from_stream(chunk_key)
	return PackedInt32Array()


## 序列化所有体素（内存 + 磁盘流中已持久化的数据）。
## 流式模式下磁盘数据由 stream 管理，一次性全量存档时需合并；
## 磁盘部分临时加载，不污染内存缓存。
## 程序化流：未修改 chunk 可确定性重新生成，只序列化修改过的（磁盘为权威，与资源存储一致）。
## save_data()（显式存档）使用此完整版；资源持久化（_get）走 _serialize_voxels_for_storage。
func _serialize_all_voxels() -> Array:
	if stream is VoxelProceduralStream:
		return _serialize_voxels_for_storage()
	var voxel_list := _serialize_voxels()
	if stream == null:
		return voxel_list
	# 磁盘流（VoxelFileStream）：合并已持久化但不在内存的 chunk（临时加载，不污染内存缓存）
	var extra: Array = []
	for ck: Vector3i in _persisted_chunks:
		if not _chunk_buffers.has(ck):
			extra.append(ck)
	voxel_list.append_array(_serialize_chunks_to_list(extra))
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
#
# 【防超大 .tscn 设计】双保险：
#   1. 程序化流只序列化"用户修改过的 chunk"（未修改的可确定性重新生成）。
#   2. 载荷整体 GZIP 压缩后 base64 存储（SaveTool 同款：var_to_bytes + COMPRESSION_GZIP），
#      即使静态大模型数据也压缩到可接受体积。
# 载荷格式固定为 GZIP 压缩（无旧版明文兼容，_decode_payload 见注释）。

## 载荷压缩魔数（与 SaveTool 的 "GZIP" 头一致，用于识别压缩格式）
const PAYLOAD_MAGIC := "GZIP"

## 声明隐藏的 storage 属性（PROPERTY_USAGE_STORAGE：不显示在编辑器，但随资源保存/加载）
func _get_property_list() -> Array[Dictionary]:
	return [{
		"name": "voxel_data_payload",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_STORAGE,
	}]


func _get(property: StringName) -> Variant:
	if property == &"voxel_data_payload":
		return _encode_payload()
	return null


## 编码资源载荷：{v, grid_size, voxels} → var_to_bytes → GZIP → base64 字符串。
## 返回的是可写进 .tscn 的字符串；解码见 _decode_payload。
func _encode_payload() -> String:
	var data := {
		"v": 2,
		"grid_size": [grid_size.x, grid_size.y, grid_size.z],
		"voxels": _serialize_voxels_for_storage(),
	}
	var raw := var_to_bytes(data)
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	var out := PAYLOAD_MAGIC.to_utf8_buffer()
	out.append_array(compressed)
	return Marshalls.raw_to_base64(out)


## 解码资源载荷：base64 → GZIP 解压 → 恢复 Dictionary。
## 仅支持新版 GZIP 压缩格式（旧版 var_to_str 明文载荷不再兼容）。
func _decode_payload(value: String) -> Variant:
	if value.is_empty():
		return null
	# 新格式首字符必为 base64 字母表（[A-Za-z0-9]）；旧明文以 '{' 开头，直接报错不空转。
	var c0 := value.unicode_at(0)
	var is_b64 := (c0 >= 65 and c0 <= 90) or (c0 >= 97 and c0 <= 122) or (c0 >= 48 and c0 <= 57)
	if not is_b64:
		push_error("[VoxelData] voxel_data_payload 格式不受支持（旧版明文载荷已不再兼容，请重新导入/保存）")
		return null
	var raw := Marshalls.base64_to_raw(value)
	if raw.size() < 4 or raw[0] != 0x47 or raw[1] != 0x5A:  # "GZ"
		push_error("[VoxelData] voxel_data_payload 缺少 GZIP 压缩头，载荷无效")
		return null
	var decompressed := raw.slice(4).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if decompressed.size() == 0:
		return null
	var data: Variant = bytes_to_var(decompressed)
	return data if data is Dictionary else null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"voxel_data_payload":
		# 只清内存缓冲，不动 stream 的磁盘持久化数据——场景加载时 stream 已先赋值，
		# 若调 clear() 会走 stream.erase_chunk 误删磁盘上已持久化的修改 chunk。
		_chunk_buffers.clear()
		_chunk_voxel_counts.clear()
		_voxel_count = 0
		_dirty_chunks.clear()
		_dirty_mesh_chunks.clear()
		for d in _coarse_buffers:
			d.clear()
		for d in _coarse_modified:
			d.clear()
		clear_lod_cache()
		var payload: Variant = _decode_payload(str(value))
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


## O(1) 判断指定 chunk 数据是否已就绪（内存已加载 / 磁盘持久化）。
## 程序化流未加载的 chunk 返回 false（需统一流式 _process_streaming 生成后才有数据）。
func has_chunk(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key) or (stream != null and _persisted_chunks.has(chunk_key))


# ----------------------------------------------------------------------------
# 连通性检测（崩塌支撑判定）
# ----------------------------------------------------------------------------
# 全量支撑检测由 find_unsupported（GDScript 泛洪）与 find_unsupported_around（原生 C++）
# 提供；批量分组由 partition_connected（原生）完成。

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


## 将一组位置按 6 方向连通性分组，返回 Array[Array[Vector3i]]
## 每组的体素两两 6 方向连通，组与组之间不连通。用于分块塌落、分块破坏等。
## 实现完全在原生 C++（partition_connected）：大崩塌掉落体分组主线程提速。
static func partition_connected(positions: Array) -> Array:
	if positions.is_empty():
		return []
	return NativeLoader.partition_connected(positions)


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
