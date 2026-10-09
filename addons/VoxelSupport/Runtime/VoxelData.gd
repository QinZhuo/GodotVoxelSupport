@tool
class_name VoxelData
extends Resource

## 可序列化的体素数据资源
## 用于运行时动态渲染、修改和破坏体素
## 可由 VoxelRenderer / VoxelDestructible 节点使用
## 与 VoxAsset 不同，此资源专为序列化和运行时使用设计
## 注: 直接使用 Resource 内置的 changed 信号 (通过 emit_changed() 发射)
##
## 【存储方案】chunk 分区密集缓冲（性能关键）
## 非空 chunk 各持一块 PackedInt32Array(32³)，值 = 材质ID（0=空）。体素读写 = 1 次 chunk
## 字典查询 + 1 次数组下标，稀疏性只存在于 chunk 层；网格生成使用 18³ 密集"光环缓冲"，
## 邻居读取全为数组下标、无越界检查。
## （对比"每体素一个 Vector3i 哈希键"的字典方案：邻居查询/切片/网格生成全部命中哈希，
## 大型场景慢一个量级。）
##
## 【统一材质契约】（全项目权威，见 VoxelMaterial.gd）
##   - 材质ID 0 = 空/空气：既没有体素也没有材质
##   - 存储值 == 材质ID（0 = 空），无任何 +1/-1 编码偏移
##   - 对齐后材质数组索引 == 材质ID，索引 0 恒为 null 占位

# ============================================================================
# 【API 稳定等级】
# ----------------------------------------------------------------------------
# 本文件是内核的**数据层**。GDScript 没有访问修饰符，对外可见性只有两种表达：
#   · 不带 `_` 的公开方法 = **公开 / 实验** 两级（见下）；
#   · 带 `_` 前缀 = **内部协议**，只有同插件的内核层（VoxelRenderer /
#     VoxelEditKernel / VoxelInfiniteLayer）可以调用；插件消费者（QVoxelier、
#     用户脚本、demo）一律不得调用。
#
# 【公开】稳定能力 API —— 承诺向后兼容，破坏性改动须走弃用期：
#   读写       set_voxel / remove_voxel / get_voxel / has_voxel /
#              set_voxels / remove_voxels / clear
#   区域批量   get_voxels_in_sphere / get_voxels_in_box /
#              remove_voxels_in_sphere / remove_voxels_in_box /
#              ensure_sphere_loaded / ensure_box_loaded
#   查询统计   get_voxel_count / is_empty / get_positions / get_voxels_aabb /
#              get_chunk_voxels / has_chunk / get_voxels_dict_snapshot /
#              voxel_bounds(静态) / origin_offset(静态)
#   材质       add_material / get_material / get_material_by_id
#   脏账事件   mark_chunk_dirty / is_chunk_mesh_dirty / get_dirty_mesh_chunk_count /
#              get_dirty_chunks / notify_changed
#   存档生命周期 save_data / load_data / flush / bake_to / load_voxels_dict /
#              from_voxel_data(静态) / from_qvx(静态)
#   连通塌落   flood_fill / find_connected / connectivity / neighbors /
#              partition_connected(静态) / find_unsupported / find_unsupported_around
#   数据源     set_stream / is_streaming / shift_origin / invalidate_chunk_source /
#              invalidate_chunk_source_range
#
# 【实验】可用但形态可能变（收口期仍在动；用前请确认版本）：
#   两级存储查询 is_chunk_loaded / is_stored / can_supply_chunk / get_vertical_half_span /
#              get_unloaded_chunk_keys / get_unloaded_chunk_count / get_all_chunk_keys /
#              get_loaded_chunk_keys / preload_chunk / unload_chunk
#   异步取数   request_chunk_async / cancel_chunk_request / poll_all_ready /
#              apply_ready_results / is_chunk_pending / get_unready_chunk_keys
#   只读快照   begin_readonly_snapshot / end_readonly_snapshot（写时拷贝的读侧句柄）
#   粗层 LOD   get_lod_block / has_lod_block / set_lod_block / store_lod_block /
#              erase_lod_block / get_lod_block_keys / flush_lod_block /
#              is_lod_block_modified / patch_lod_block
#   LOD 脏账   invalidate_lod / invalidate_lod_for_chunk / mark_lod_modified /
#              mark_lod_modified_for_chunk / get_lod_dirty_region / clear_lod_cache /
#              clear_lod_dirty_regions / get_invalidated_lod / has_lod_invalidated
#   伤害账     get_damage / clear_damage / clear_damage_bulk / clear_all_damage
#
# 【内部】`_` 前缀协议（内核外不可见：缓冲整表 / 快照原料 / 原生回填通道）：
#   _chunk_buffers_view / _lod_buffers_view / _damage_buffers_view / _set_damage_buffers
#   _accept_chunk_buffer / _chunk_halo / _snapshot_chunks_halo /
#   _snapshot_lod_block_chunks / _snapshot_lod_block_chunks_readonly /
#   _snapshot_lod_block_data / _can_mesh_lod_block_standalone
#   —— 内核外调用者不得绕过封装直改存储；无限层需要的两个入口已封装为公开 API：
#      patch_lod_block / apply_ready_results。
#
# 锁：Scripts/Test/test_voxel_kernel_contract.gd 的 VOXEL_DATA_PUBLIC_API /
#     VOXEL_DATA_INTERNAL_PROTOCOLS 与本清单一一对应（多一个少一个都失败）。
# ============================================================================

## 材质数组 (索引即材质ID，使用 VoxelMaterial)
@export var materials: Array[VoxelMaterial] = []

## 帧数量 (保留用于未来动画扩展)
@export var frame_count: int = 1

## 体素网格尺寸 (体素个数，由导入时计算)。
## 有限尺寸同时就是**生成器的可生成范围**（见 _sync_generator_bounds），故变化时要立刻同步：
## 否则"先设 generator、后设 grid_size"的调用方会拿到一个范围没生效的生成器
## （渲染器于是对 view_distance 内每个 chunk 都提交生成 → 海量空 chunk）。
@export var grid_size: Vector3i = Vector3i.ZERO:
	set(v):
		if grid_size == v:
			return
		grid_size = v
		_sync_generator_bounds()

## 缩放比例 (仅作为导入时的默认值，实际渲染缩放由 VoxelRenderer 控制)
@export var default_scale: float = 0.1

## 数据层磁盘流（VoxelStream / QVoxelStream）。非空时启用数据层按需加载：
##   - 内存只保留"已加载"的 chunk，其余数据由 stream 负责读盘（磁盘为权威）
##   - 修改过的 chunk 写回磁盘；变空时清盘；未修改且磁盘已有的可直接丢弃
##   - 访问 / 范围查询 / 破坏 / 网格生成会自动从磁盘加载所需 chunk（见各方法注释）
## unload_chunk() 由**调用方**决定何时释放内存缓冲。
## VoxelRenderer 在流式卸载时按距离调用它（无限世界内存回收的落脚点），但半径外扩了
## "最粗层 block 的覆盖范围"——粗层降采样要读它覆盖的 LOD0 chunk，卸早了降采样会读到假空块。
## 通过 set_stream() 或 setter 赋值；切换时会先 flush 旧流。
@export var stream: VoxelStream:
	set(v):
		# setter 内部赋值不会递归，可直接设置底层存储（与 VoxelRenderer.data 同模式）
		if stream == v:
			return
		# 切换前把旧流上未写盘的数据 flush（避免丢失）
		if stream != null and _dirty.has_any(0, VoxelDirtyLedger.PERSIST):
			flush()
		stream = v
		# 内存里已有、新流里没有的 chunk 必须重新标记为"待写"：上面的 flush 只保证旧流完好
		# （它已清空待写标记），若不补标，这些 chunk 卸载时会被当成"流里已有"直接丢弃，
		# 而新流其实从未见过它们 → 数据静默丢失。
		for ck in _chunk_buffers:
			if stream == null or not stream.has_chunk(ck, 0):
				_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
		_sync_sources()

## 生成器（VoxelGenerator 子类）。与 stream 是**并列**的两个数据源：
##   stream    "存"：用户编辑、存档、导入的静态数据（见上）
##   generator "造"：程序化地形 —— 未编辑部分按 key 确定性生成，零存储
## 二者可并存（程序化世界 + 破坏存档）。取数优先级恒为 **流 > 生成器**：
## 存过的东西必须权威，不能被生成结果覆盖。
##
## 只设 generator 不设 stream 时，会自动补一个 VoxelMemoryStream 作编辑的落脚处
## （否则编辑过的 chunk 无处可存，卸载后被重新生成覆盖 → 破坏成果丢失）。
@export var generator: VoxelGenerator:
	set(v):
		if generator == v:
			return
		generator = v
		if generator != null and stream == null:
			stream = VoxelMemoryStream.new()
		_sync_sources()

## 取数编排器（在途 / 就绪 / 去重 / 限流 / 后台派发）。全项目唯一持有这本账的地方。
var _async := VoxelAsyncLoader.new()


## 把两个数据源同步给编排器，并把本数据层的 grid_size 转成生成器的可生成范围。
func _sync_sources() -> void:
	_sync_generator_bounds()
	if _async == null:
		return
	# 换源时丢弃在途 / 就绪登记：那些请求属于旧数据源，回填进新世界会写出错坐标的数据。
	# （早先这本账挂在流对象上，换流自然带走；现在它归本数据层所有，必须显式清。）
	_async.clear()
	_async.configure(stream, generator)


## 把 grid_size 转成生成器的可生成范围 AABB（ZERO = 无限世界，自动关闭）。
## 生成器只生成世界范围内的 chunk（矩形地图），否则渲染器会对 view_distance 内每个 chunk
## 都提交生成 → 海量空 chunk。数据源与尺寸任一变化都要重跑，故单独成一个函数供两处调用。
func _sync_generator_bounds() -> void:
	if generator != null:
		generator.set_grid_size(grid_size)

## 居中偏移 (体素单位，运行时渲染时叠加到网格顶点)
## 导入时若 center 选项开启，自动计算使模型左右前后居中(X/Z)、上下贴底(Y=0)
## 与 mesh 导入的居中策略一致，数据坐标仍保持在 [0, grid_size) 范围内
## 运行时渲染: 网格顶点 = (体素坐标 + center_offset) * voxel_scale
## 该偏移不影响破坏/查询逻辑 (它们基于原始数据坐标)
@export var center_offset: Vector3 = Vector3.ZERO

## 脏账本唯一权威（写盘 / 网格重建 / LOD 失效 / 粗层回退 / 脏区域 全在里面，见 VoxelDirtyLedger）。
## 所有修改都标记到 chunk 粒度，避免逐体素脏集合的主线程 dict 写入瓶颈（大崩塌每帧数千体素）。
var _dirty := VoxelDirtyLedger.new()

## 标记体素所在 chunk 需要重建（含 6 个跨界面的边界邻居——面可见性依赖邻居）。
## 大批量修改（_remove_voxels/set_voxels）走此路径；单格 set_voxel 也调用。
func _mark_voxel_dirty(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
	# LOD0 用户编辑 → 失效对应高层 block 并标记需降采样（编辑数据不能用纯生成器输出）
	mark_lod_modified(pos)
	var local := pos - ck * CHUNK_SIZE
	if local.x == 0:
		_dirty.mark(0, ck + Vector3i(-1, 0, 0), VoxelDirtyLedger.MESH)
	elif local.x == CHUNK_SIZE - 1:
		_dirty.mark(0, ck + Vector3i(1, 0, 0), VoxelDirtyLedger.MESH)
	if local.y == 0:
		_dirty.mark(0, ck + Vector3i(0, -1, 0), VoxelDirtyLedger.MESH)
	elif local.y == CHUNK_SIZE - 1:
		_dirty.mark(0, ck + Vector3i(0, 1, 0), VoxelDirtyLedger.MESH)
	if local.z == 0:
		_dirty.mark(0, ck + Vector3i(0, 0, -1), VoxelDirtyLedger.MESH)
	elif local.z == CHUNK_SIZE - 1:
		_dirty.mark(0, ck + Vector3i(0, 0, 1), VoxelDirtyLedger.MESH)


## 标记单个 chunk 需要重建（补建 / 流式加载 / 粗层回填路径用）。
## 公开：渲染器在"数据已就绪但 mesh 未建"时需要它，而脏集合是数据层的状态，不该由外部直改。
func mark_chunk_dirty(ck: Vector3i) -> void:
	_dirty.mark(0, ck, VoxelDirtyLedger.MESH)


## 让一个 chunk 的**来源数据**作废：丢掉内存副本，下次取数重新按"流 > 生成器"读入。
##
## 【为什么内核必须提供这一条】数据源不是常量：QVoxelier 里用户手绘一笔，该块要重新求值
## 再重新生成；运行时改程序化世界的参数同理。过去唯一的"重取"入口是 unload_chunk()，
## 而它会先把内存缓冲**写回流**（把生成结果固化成用户数据），此后该块永远不会再重新生成
## —— 那是**卸载**语义，不是**失效**语义，两者混用会让程序化地形被"冻结"在第一帧的形态。
##
## 【为什么连 LOD 一起失效】粗层块由 LOD0 降采样而来；LOD0 换了而粗层不换，远处就继续显示旧形状。
##
## 调用方（渲染器 / 编辑器）拿到脏账后照常 request_update()，实际重取由流式泵按需发起
## （见 preload_chunk → _async.request），所以本方法是"作废"而非"同步重载"。
func invalidate_chunk_source(ck: Vector3i) -> void:
	# 在途 / 就绪登记属于旧内容，留着会被回填进已作废的块（与换源时 _async.clear() 同理）
	_async.cancel(ck, 0)
	_chunk_buffers.erase(ck)
	_chunk_voxel_counts.erase(ck)
	# 伤害账随内容一起作废：重新生成后的形态与旧账无关，留着会变成幽灵伤害
	_damage.erase_chunk(ck)
	invalidate_lod_for_chunk(ck)
	# 待写盘标记随内存副本一起清（没有缓冲可写）；MESH 标记必须留，否则旧网格不会被清掉
	_dirty.clear_flag(0, ck, VoxelDirtyLedger.PERSIST)
	_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
	_mark_neighbors_dirty(ck)


## 让一个**体素范围**覆盖的所有 chunk 的来源数据作废（闭区间，含端点）。返回覆盖的 chunk 数。
##
## 【为什么要有范围形式】单块形式要求调用方自己把"改了哪些体素"翻成 chunk 键，而"体素范围 →
## chunk 键"是数据层的换算（`VoxelChunk.chunk_of` + 越界语义），让每个消费者各写一遍只会
## 各自漏掉边界情形。本函数与 `get_voxels_in_box` / `remove_voxels_in_box` / `ensure_box_loaded`
## 同族：单块/单点能力 + 一个范围便利形式，范围形式只做换算与转发，语义一字不差。
##
## 【典型调用方：编辑器的一笔手势】QVoxelEditCommand 封口时给出 block 粒度的脏范围
## （dirty_lo..dirty_hi），视口把它交给本函数即可；范围外的 chunk 缓冲保留旧内容 ——
## 那些内容对未编辑区域仍然正确，故不必整对象重算。
func invalidate_chunk_source_range(lo: Vector3i, hi: Vector3i) -> int:
	var a := Vector3i(mini(lo.x, hi.x), mini(lo.y, hi.y), mini(lo.z, hi.z))
	var b := Vector3i(maxi(lo.x, hi.x), maxi(lo.y, hi.y), maxi(lo.z, hi.z))
	var c0 := _chunk_of(a)
	var c1 := _chunk_of(b)
	var n := 0
	for cz in range(c0.z, c1.z + 1):
		for cy in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				invalidate_chunk_source(Vector3i(cx, cy, cz))
				n += 1
	return n


## 该 chunk 是否已标脏待重建。**不取走**（取走并清空请用 get_dirty_chunks）。
func is_chunk_mesh_dirty(ck: Vector3i) -> bool:
	return _dirty.has(0, ck, VoxelDirtyLedger.MESH)


## 待重建 chunk 数（渲染器每帧预算判断用；不构造数组）。
func get_dirty_mesh_chunk_count() -> int:
	return _dirty.count(0, VoxelDirtyLedger.MESH)


## chunk 数据就绪 → 标记依赖其 halo 的 6 个相邻 chunk 重建（边界 mesh 缝合）。
## 否则相邻 chunk 生成 mesh 时该 chunk 数据未就绪（halo 缺数据）→ 边界外侧面缺失，
## 该 chunk 数据就绪后也不触发重建 → 横/竖/块状空洞固定存在。
func _mark_neighbors_dirty(chunk_key: Vector3i) -> void:
	for dir in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0), Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
		var nb: Vector3i = chunk_key + dir
		if _chunk_buffers.has(nb) and not _dirty.has(0, nb, VoxelDirtyLedger.MESH):
			_dirty.mark(0, nb, VoxelDirtyLedger.MESH)


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

# 每级失效的 block 记在 _dirty 的粗层账里（见 VoxelDirtyLedger.LOD_MESH）


## 取"分层字典数组"的第 level 层（必要时补足到该层）。全项目唯一维护这类数组的地方：
## 各层各自一张 {key: value} 表；越界即补空层，避免每处手写 while-append（易漏、易越界）。
static func _layer(layers: Array[Dictionary], level: int) -> Dictionary:
	while layers.size() <= level:
		layers.append({})
	return layers[level]


## 失效体素所在 chunk 对应的所有更高层 LOD block（LOD0 数据变化后调用）。
## 仅失效网格重建（数据回填/程序化生成也会触发，见 _accept_chunk_buffer）；
## 用户编辑额外标记 modified 用 mark_lod_modified*。
func invalidate_lod(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	for lod in range(1, maxi(lod_count, 1)):
		_mark_lod_invalid(Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod), lod)


## 失效指定 LOD0 chunk 对应的所有更高层 LOD block（仅网格重建，不标记 modified）
func invalidate_lod_for_chunk(ck: Vector3i) -> void:
	for lod in range(1, maxi(lod_count, 1)):
		_mark_lod_invalid(Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod), lod)


## 用户编辑体素：失效高层 block 并标记"需降采样"（编辑影响该 block，不能用纯生成器数据）。
## 金字塔增量：保留 coarse 缓存（不 erase），只记录脏大格区域（增量降采样，未脏大格复用）。
func mark_lod_modified(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		_mark_lod_dirty_region(bk, lod, pos, pos)


## 用户编辑 chunk（批量）：标记覆盖它的所有高层 block 需降采样（同上，记录整 chunk 脏区域）
func mark_lod_modified_for_chunk(ck: Vector3i) -> void:
	var vox_min := ck * CHUNK_SIZE
	var vox_max := vox_min + Vector3i(CHUNK_SIZE - 1, CHUNK_SIZE - 1, CHUNK_SIZE - 1)
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		_mark_lod_dirty_region(bk, lod, vox_min, vox_max)


## 记录 block 的脏大格区域（体素范围 [vox_min, vox_max] 覆盖的 block 内大格，并集）。
## 体素 → block 内大格的换算与 clamp 属几何职责，留在数据层；并集记账交给账本。
func _mark_lod_dirty_region(block_key: Vector3i, lod: int, vox_min: Vector3i, vox_max: Vector3i) -> void:
	var gmin := Vector3i(vox_min.x >> lod, vox_min.y >> lod, vox_min.z >> lod) - block_key * LOD_GRID
	var gmax := Vector3i(vox_max.x >> lod, vox_max.y >> lod, vox_max.z >> lod) - block_key * LOD_GRID
	gmin = Vector3i(clampi(gmin.x, 0, LOD_GRID - 1), clampi(gmin.y, 0, LOD_GRID - 1), clampi(gmin.z, 0, LOD_GRID - 1))
	gmax = Vector3i(clampi(gmax.x, 0, LOD_GRID - 1), clampi(gmax.y, 0, LOD_GRID - 1), clampi(gmax.z, 0, LOD_GRID - 1))
	if gmax.x < gmin.x or gmax.y < gmin.y or gmax.z < gmin.z:
		return
	_dirty.mark_region(lod, block_key, gmin, gmax)


## 取并清空指定 block 的脏大格区域（渲染器增量降采样消费）
func get_lod_dirty_region(lod: int, bk: Vector3i) -> Array:
	return _dirty.take_region(lod, bk)


## 记录指定层级 block 失效（通知渲染器重建）
func _mark_lod_invalid(block_key: Vector3i, lod: int) -> void:
	_dirty.mark(lod, block_key, VoxelDirtyLedger.LOD_MESH)


## 标记粗层 block 需降采样（编辑影响该 block，不能用纯生成器数据）
func _mark_coarse_modified(block_key: Vector3i, lod: int) -> void:
	if lod < 1:
		return
	_dirty.mark(lod, block_key, VoxelDirtyLedger.COARSE_MODIFIED)


## 清空所有层级失效标记
func clear_lod_cache() -> void:
	_dirty.clear_flags_all(VoxelDirtyLedger.LOD_MESH)


## 清空所有层级的"脏大格区域"增量标记（世界级重置：clear / 载荷重建时调用）。
## 与 clear_lod_cache 分开：两者分别服务"失效重建"与"增量降采样 patch"两条路径，
## 只清一个会留下另一半陈旧账本继续驱动渲染器。
func clear_lod_dirty_regions() -> void:
	_dirty.clear_regions()


## 获取指定层级的失效 block（渲染器 _process_lod 消费后重建），并清空
func get_invalidated_lod(lod: int) -> Array[Vector3i]:
	return _dirty.take(lod, VoxelDirtyLedger.LOD_MESH)


## 是否有失效的粗层 block 待重建（渲染器据此在数据变化时立即触发 LOD 处理，不等降频周期）
func has_lod_invalidated() -> bool:
	return _dirty.has_any_from(1, VoxelDirtyLedger.LOD_MESH)


## 获取所有脏 chunk（渲染器增量重建用），并清空
func get_dirty_chunks() -> Array[Vector3i]:
	return _dirty.take(0, VoxelDirtyLedger.MESH)


## Chunk 几何常量唯一权威源见 VoxelChunk，此处全部派生别名防止漂移
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const CHUNK_SLICE := VoxelChunk.CHUNK_SLICE
const HALO := VoxelChunk.HALO
const HALO_SIZE := VoxelChunk.HALO_SIZE
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

## chunk key -> 密集缓冲 (PackedInt32Array, 32³)。值 = 材质ID（0 = 空），材质ID 0 保留为空。
## 空 chunk 不在此字典中（稀疏性只存在于 chunk 层）。
var _chunk_buffers: Dictionary = {}

## 逐体素累计伤害账（存储结构 / 生命周期规则 / 线程约定见 VoxelDamageStore）。
## 留在数据层是硬要求：它必须与 chunk 缓冲同生共死（卸载 / 清空 / origin shift /
## 载荷重建都要同步处理），破坏节点无人负责清理。
var _damage := VoxelDamageStore.new()

## 每粗 LOD 独立数据层：_coarse_buffers[level-1] = {block_key: PackedInt32Array(LOD_GRID³ 大格)}
## 值 = 材质ID（0=空），每格 = 2^level 体素。与 Voxel Tools 一致：各 LOD 数据块独立，
## 未修改的粗层 block 由生成器 _generate_chunk_lod 直接生成（无需加载全部 LOD0 chunk）。
var _coarse_buffers: Array[Dictionary] = []

## 需降采样回退的粗 LOD block 记在 _dirty 的粗层账里（见 VoxelDirtyLedger.COARSE_MODIFIED）。
## LOD0 编辑影响该 block 时标记，下次渲染走降采样（合并 LOD0 数据）而非生成器。

## 文件流（QVoxelStream 无粗层生成器）的粗层数据从 LOD0 chunk 降采样生成，结果缓存到
## _coarse_buffers（移动复用）并持久化到文件流（重启保留），避免每次渲染都重复降采样。
## 【账本不在这里】它的"在途去重 + 空结果重试计数"由 VoxelAsyncLoader 统一持有
## （begin_derived / end_derived / is_derived / note_derived_retry）——本类只负责构造快照、
## 派发 worker、把结果交回编排器，不再另存一份并行的 pending 账本。

## 只读快照持有者计数（见 begin_readonly_snapshot）。
## 单点写路径（_write_buffer_impl）的 O(1) 判据：>0 即表示有 worker 可能共享底层缓冲。
var _snapshot_readers: int = 0

## 存活的快照句柄（handle -> true）。用于两件事：
##   1) clear() / 载荷重建等世界级重置时强制回收，避免泄漏句柄永久钉住 _snapshot_readers；
##   2) end_readonly_snapshot() 兼容 shim 需要知道"当前该释放哪一个"。
var _live_snapshots: Dictionary = {}

## 每 chunk 体素计数（chunk key -> int，增量维护 O(1)）。**体素数的唯一权威**：
## 全局总数由它派生（见 get_voxel_count），不存在第二份存储可以漂移。
## 不变式：只含 > 0 的条目（归零即移除），故 is_empty() 恒等价于"总数为 0"。
## 写入口只有 _count_delta / _count_set 两个，其余路径一律不得直接改本字典。
## 用途：替代 _maybe_erase_empty_chunk 的 4096 全量扫描——增减体素时更新计数，
## 归零即视为空 chunk 可擦除，消除破坏/崩塌热路径的 32³ 循环。
var _chunk_voxel_counts: Dictionary = {}

## 内存中被修改过的 chunk 记在 _dirty 的 level 0 账里（见 VoxelDirtyLedger.PERSIST）。**两个用途**：
##   1) 存储回写：卸载时写盘、变空时清盘（未修改且磁盘已有的直接丢弃）；
##   2) 资源持久化：有生成器的世界只把"改过的块"写进资源载荷（见 _collect_persist_blocks）。
## 因此它不能只在有 stream 时才维护——加载/导入路径也必须逐块登记。

## 6 方向邻居偏移（上下左右前后）。真值在 VoxelConnectivity.NEIGHBORS_6（连通性内核）；
## 这里保留同名别名，避免出现第二份真值（LOD 块邻接判定等处仍按原名引用）。
const NEIGHBORS_6: Array[Vector3i] = VoxelConnectivity.NEIGHBORS_6


# ----------------------------------------------------------------------------
# 资产原点（导入选项 mesh/origin）—— 四条链路共用的唯一约定
# ----------------------------------------------------------------------------
## 导入时的**资产原点**模式。`.vox`/`.qvx` × mesh/data 四条链路全走同一套语义。
##
## 【为什么必须统一】同一个模型经 mesh 与 data 两条路径进场景，必须落在同一位置。此前
## mesh 路径保留 MagicaVoxel 的"作者摆放"（顶点从 SIZE 盒中心起算），data 路径把内容 AABB
## 的角点当原点（贴地）——本仓库实测同一个模型两侧底面差 0.35~0.50（模型边长 2.2），看着
## 就像"位置差很多"，而体素数据其实完全一致。现在两条路径共用本枚举：同值 → 同位置。
##
## 【为什么默认 WORLD_ORIGIN】导入器不该在没被要求时移动顶点几何：这一档原样保留文件里的
## 坐标，也正是本插件网格导入一直以来的行为——默认沿用它，已有资产不会因升级而挪位；
## 多模型装配在 MagicaVoxel 世界里的相对位置也只有它保得住（其余两档会把每个模型各自归位）。
## 需要"贴地居中"这种游戏资产惯例（角色/道具原点在脚底中心）时，再显式选 `BOTTOM_CENTER`。
##
## 【名字的确切含义】"源文件世界的原点 (0,0,0) 就是 Godot 的原点"——模型停在作者把它放在
## 世界里的位置，而不是被搬到原点。是 **origin** 而不是 center：`.vox` 侧的实现确实让
## "模型自己的 SIZE 盒中心落在世界原点"（MagicaVoxel 的默认摆放本就如此，所以单模型时
## "盒中心"与"世界原点"在数值上是同一个点），但多模型装配时位置来自**每个模型各自套自己的
## 节点变换**，整体并不居中——`demo/cars.vox` 的 8 个模型就是这种。
## `.qvx` 没有"世界"这一层（体素坐标就是块坐标），此档对它即"文件里的坐标原样"：
## 与 `.vox` 同一个意思——文件里是什么就是什么。
##
## 顺带一提，"原点该在哪"本就没有格式级定论：MagicaVoxel 自己的原点落在**包围盒中心、
## 且落在体素之间**（奇数尺寸如 5×5×3 时是 (2,2,1) 而非 (2.5,2.5,1.5)），而 Blender 上
## 装机量最高的 `.vox` 导入器（MagicaVoxel VOX format）专门加了个 "Center Origins" 开关
## 把它改成几何中心。所以这里默认忠实于文件，其余交给开关。
enum OriginMode {
	WORLD_ORIGIN,    ## 保留文件坐标：`.vox` 即 MagicaVoxel 世界里的位置——**默认**
	BOTTOM_CENTER,   ## 内容包围盒：X/Z 居中 + Y 贴底（游戏资产惯例）
	CONTENT_CENTER,  ## 内容包围盒三轴居中（绕自身旋转/做预览友好）
}

## 体素单位的原点偏移：把内容摆成 `mode` 描述的样子，渲染顶点再叠加它。
##
## **四条链路唯一的实现**：各写一份必然漂移，而漂移的表现是"模型位置莫名错开"。
## 包围盒用内容 AABB（不是 .vox 的 SIZE 盒）——这正是与 MagicaVoxel 的差异所在。
##
## 【取整方式：先除再 floor，即 `-floor(extent/2)`】结果**恒为整数体素**，于是：
##   · 奇数边长恰好居中（内容跨 [0, w-1]，其中心 (w-1)/2 = floor(w/2) 正是整数）；
##   · 偶数边长差半个体素——无法避免（真中心是半整数），但模型至少仍落在体素格点上。
## 反过来"先 floor 再除"（`-floor(w)/2`）对奇数边长会平白多偏半格：既没对齐格点、又没居中。
## 本插件运行时以整数体素为单位（chunk 边界 = 32 的倍数），资产原点必须落在格点上，
## 否则模型与体素世界错相位。这也正是改造前 `.vox → data` 的取法（`(grid_size/2).floor()`）；
## 而改造前 QVX 走的是较差的那版，统一时以本条为准。
##
## `WORLD_ORIGIN` 返回零向量：文件里的摆放已体现在顶点坐标里，不该再动。
static func origin_offset(bounds: Dictionary, mode: int) -> Vector3:
	if bounds.is_empty() or mode == OriginMode.WORLD_ORIGIN:
		return Vector3.ZERO
	var lo: Vector3i = bounds["min"]
	var hi: Vector3i = bounds["max"]
	var half := (Vector3(hi - lo + Vector3i.ONE) / 2.0).floor()
	var y := -float(lo.y) if mode == OriginMode.BOTTOM_CENTER else -(float(lo.y) + half.y)
	return Vector3(-(float(lo.x) + half.x), y, -(float(lo.z) + half.z))


## 从 VoxAsset 构造 (编辑器导入时使用)
## `origin_mode` 见 `OriginMode`：决定模型摆到哪，并据此写 `center_offset`（渲染时叠加）。
static func from_voxel_data(voxel_data: VoxAsset, frame_index: int = 0,
		origin_mode: int = OriginMode.WORLD_ORIGIN) -> VoxelData:
	var res := VoxelData.new()
	var raw_voxels := voxel_data.get_voxels(frame_index)

	# 体素坐标重映射到 [0, grid_size)：VoxelNode.get_voxels() 的 transform 含 VoxelModel.offset
	# 与节点变换，故原始坐标落在 [offset, offset + size) 之间。
	# 【WORLD_ORIGIN 例外】原样保留文件里的摆放 → 一律不重映射（坐标为负无妨，chunk 键本就支持负数）。
	if not raw_voxels.is_empty():
		var bounds := voxel_bounds(raw_voxels)
		var min_pos: Vector3i = bounds["min"]
		var max_pos: Vector3i = bounds["max"]
		var base := Vector3i.ZERO if origin_mode == OriginMode.WORLD_ORIGIN else min_pos

		for pos_key in raw_voxels.keys():
			var pos: Vector3i = pos_key
			res._write_buffer_impl(pos - base, raw_voxels[pos_key], false)

		res.grid_size = max_pos - min_pos + Vector3i(1, 1, 1)
		# 原点偏移：非 WORLD_ORIGIN 时体素已重映射到"内容最小角 = 0"，故把同一套公式作用在**相对**包围盒上
		res.center_offset = origin_offset({"min": Vector3i.ZERO, "max": max_pos - base}, origin_mode)
	else:
		# 空模型：VoxAsset 没有 `size` 属性（那是 VoxelModel 的），此前这里会运行期报错。
		# 空资产按零尺寸处理即可，调用方随后通常也不会渲染它。
		res.grid_size = Vector3i.ZERO

	# 材质数组：以**数组索引**为准复制到 res.materials（索引 i 即材质ID = 体素值），
	# 这样即使来源材质对象的 id 字段未被设置也正确（索引才是权威映射）。
	# 索引 0 保留为空占位（材质ID 0 = 空），不复制。
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

	# 原点偏移已在上面的 if 里按 origin_mode 写好（见 OriginMode）：
	# 渲染顶点 = (体素坐标 + center_offset) * voxel_scale。
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


## 写入体素缓冲（核心原语）。不标记脏 chunk / 不触发信号（由调用方处理）。
## 统一材质契约：材质ID 0 = 空，缓冲直接存材质ID（0 = 空）。
## check_empty=true 时，若写入后该 chunk 缓冲全空则移除 chunk 键（回收内存）。
func _write_buffer_impl(pos: Vector3i, mat_id: int, check_empty: bool) -> void:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		if is_stored(ck):
			# 流式：该 chunk 在磁盘已有数据，先载入内存再修改（保留旧数据）
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			buf = PackedInt32Array()
			buf.resize(CHUNK_VOLUME)
			_chunk_buffers[ck] = buf
	# 只读快照在途：该缓冲可能与 worker 共享底层，先分叉再写（GDScript 逐元素写不会 COW）
	if _snapshot_readers > 0:
		buf = (buf as PackedInt32Array).duplicate()
		_chunk_buffers[ck] = buf
	# 标记需要写盘：内存数据已变更（若最终变空由 _maybe_erase_empty_chunk 清盘）
	_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
	# 该位置被改写或移除 → 清零其累计伤害，否则残留伤害会"继承"给新体素（一放就被秒杀）
	_damage.clear_at(pos)
	var idx := _buf_index(pos - ck * CHUNK_SIZE)
	var cur: int = buf[idx]
	if mat_id <= 0:
		if cur > 0:
			buf[idx] = 0
			_count_delta(ck, -1)
			if check_empty:
				_maybe_erase_empty_chunk(ck)
	else:
		if cur <= 0:
			_count_delta(ck, 1)
		buf[idx] = mat_id


## 非空体素数（全项目唯一实现）：原生 count(0) 比 GDScript 逐元素循环快约 40 倍，
## 而这条计数在流式回填与粗层降采样里都是必经步骤。
static func _count_voxels(buf: PackedInt32Array) -> int:
	return buf.size() - buf.count(0)


## 计数账本唯一的增量写入口：保证不变式"只含 > 0 条目"（归零即移除）。
## 由此 is_empty() 恒等价于"总数为 0"，派生求和恒等于真实总数。
func _count_delta(ck: Vector3i, delta: int) -> void:
	var v := int(_chunk_voxel_counts.get(ck, 0)) + delta
	if v > 0:
		_chunk_voxel_counts[ck] = v
	else:
		_chunk_voxel_counts.erase(ck)


## 计数账本唯一的覆盖写入口（装入整块缓冲时用；调用方保证该块此前未计数）
func _count_set(ck: Vector3i, n: int) -> void:
	if n > 0:
		_chunk_voxel_counts[ck] = n
	else:
		_chunk_voxel_counts.erase(ck)


## 直接装入一块密集缓冲（导入 / 资源载荷恢复专用）：不做逐体素写。
func _install_block_buffer(chunk_key: Vector3i, buf: PackedInt32Array) -> void:
	if buf.size() != CHUNK_VOLUME:
		push_error("[VoxelData] 块 %s 的缓冲长度 %d != %d，已跳过" % [chunk_key, buf.size(), CHUNK_VOLUME])
		return
	_chunk_buffers[chunk_key] = buf
	_count_set(chunk_key, _count_voxels(buf))


## 若 chunk 体素计数归零则移除该 chunk 键（O(1)，替代 4096 全量扫描）
func _maybe_erase_empty_chunk(ck: Vector3i) -> void:
	if _chunk_voxel_counts.has(ck):
		return
	_chunk_buffers.erase(ck)
	_chunk_voxel_counts.erase(ck)
	# 只清"待写盘"：MESH 标记必须留着，否则渲染器不会重建来清掉该 chunk 的旧 mesh
	_dirty.clear_flag(0, ck, VoxelDirtyLedger.PERSIST)
	_damage.erase_chunk(ck)
	if is_stored(ck):
		# 流式：世界该处已清空，同步删除存储里的旧数据（否则重载会出现"幽灵 chunk"）
		stream.erase_chunk(ck)


# ----------------------------------------------------------------------------
# 数据层磁盘流式（VoxelStream 接入）
# ----------------------------------------------------------------------------

## 配置数据层流（等价于设置 stream 属性，供代码动态切换，触发 stream setter 的
## flush 旧流 + 恢复新流已持久化索引逻辑）。
func set_stream(s: VoxelStream) -> void:
	stream = s


## 数据层流式是否启用（有流可读/写，或能程序化生成）
func is_streaming() -> bool:
	return stream != null or generator != null


## chunk 是否在内存中（有密集缓冲）。has_chunk 的严格子集（仅内存，不含存储）。
func is_chunk_loaded(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key)


## 该 chunk 是否**已存在流中**（纯存储事实，与"能否生成"无关）。
## 取代早先的 _persisted_chunks 镜像——那时它靠 save/erase 处手工同步，
## origin shift 一平移就与流的真实内容脱节（镜像的经典失效方式）。
## 直接问流既是权威的，也是 O(1) 的（QVoxelStream 的键索引常驻内存）。
func is_stored(chunk_key: Vector3i) -> bool:
	return stream != null and stream.has_chunk(chunk_key, 0)


## 该 chunk 的数据能否取到：流里已存 或 生成器可生成。廉价、无 IO，供渲染器距离扫描用。
func can_supply_chunk(chunk_key: Vector3i) -> bool:
	if stream != null and stream.has_chunk(chunk_key, 0):
		return true
	return generator != null and generator.is_in_generation_bounds(chunk_key)


## 渲染器距离扫描的垂直半跨度（无生成器时只有 ±1 层）。
func get_vertical_half_span() -> int:
	return generator.get_vertical_half_span() if generator != null else 1


## 把 chunk 数据**同步**载入内存。已加载返回 true；取不到返回 false。
## 流式补建/网格生成前调用，保证后续读操作走内存数组。
##
## 两条路分开处理（这正是"存"与"造"分工的价值）：
##   流里已存 → 同步直读。存储取数是确定的、快的（QVoxelStream 索引常驻内存），
##             没有理由为此绕一趟异步队列。
##   只有生成器 → 交给异步。生成慢，而网格 / LOD halo 会成片调用它，
##             同步生成会把主线程卡死；就绪后由 _accept_chunk_buffer 回填。
func preload_chunk(chunk_key: Vector3i) -> bool:
	if _chunk_buffers.has(chunk_key):
		return true
	if is_stored(chunk_key):
		var buf := stream.load_chunk(chunk_key, 0)
		if buf.size() != CHUNK_VOLUME:
			# 索引说有、实际读不到（文件被外部改写等）→ 以读结果为准，顺手清掉
			stream.erase_chunk(chunk_key, 0)
			return false
		_chunk_buffers[chunk_key] = buf
		_count_set(chunk_key, _count_voxels(buf))
		# halo 数据就绪 → 重建依赖该 chunk 作为 halo 的相邻 chunk（边界 mesh 缝合）
		_mark_neighbors_dirty(chunk_key)
		return true
	if generator != null and generator.is_in_generation_bounds(chunk_key):
		_async.request(chunk_key, 0)
	return false


## 【内部】回填统一异步流式结果（程序化后台生成 / 文件流 region 读盘，主线程调用）。
## 按 lod 分流：lod=0 存全精度 chunk；lod>=1 存粗层 32³ 大格数据。
## 已存在则忽略。与 preload_chunk 不同：数据来自异步队列，无需再走 stream.load_chunk。
## 内核外请用公开入口 apply_ready_results（poll + accept 的封装）。
func _accept_chunk_buffer(chunk_key: Vector3i, buf: PackedInt32Array, lod: int = 0) -> void:
	if lod == 0:
		if _chunk_buffers.has(chunk_key):
			return
		if buf.size() != CHUNK_VOLUME:
			return
		_chunk_buffers[chunk_key] = buf
		_count_set(chunk_key, _count_voxels(buf))
		# 数据就绪 → 标记网格重建。未修改的粗层块用独立数据层，不依赖 LOD0 回填，
		# 无需失效（否则每回填一个 chunk 就递增渲染器全局 gen_id，作废全部在途粗层任务）；
		# 仅"需降采样(用户编辑)"的粗层块在 LOD0 数据就绪后失效重建。
		_dirty.mark(0, chunk_key, VoxelDirtyLedger.MESH)
		# halo 数据就绪 → 重建依赖该 chunk 作为 halo 的相邻 LOD0 chunk（边界 mesh 缝合，
		# 否则相邻 chunk 生成时 halo 未就绪，边界缺外侧面 → 横/竖/块状空洞）
		_mark_neighbors_dirty(chunk_key)
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
	# 数据就绪 → 标记对应 block 网格重建。
	# 注意 key 落在 level 0 的 chunk 空间（与 is_chunk_mesh_dirty 读的是同一张表）——历史行为，
	# 收拢时原样保留：粗层 block key 与 LOD0 chunk key 可能数值相同，会连带重建那个 chunk。
	_dirty.mark(0, chunk_key, VoxelDirtyLedger.MESH)


## 卸载 chunk：把内存中该 chunk 的数据按需写回磁盘（修改过的写盘、变空的清盘、
## 未修改且磁盘已有的直接丢弃），然后释放内存缓冲。
## 仅数据层流式启用时有效；无 stream 时返回 false（不卸载，避免数据丢失）。
func unload_chunk(chunk_key: Vector3i) -> bool:
	if stream == null:
		return false
	if not _chunk_buffers.has(chunk_key):
		return false
	if _dirty.has(0, chunk_key, VoxelDirtyLedger.PERSIST):
		if _chunk_voxel_counts.has(chunk_key):
			stream.save_chunk(chunk_key, _chunk_buffers[chunk_key])
		elif is_stored(chunk_key):
			# 世界该处已清空 → 同步清掉存储里的旧数据，否则重载会出现"幽灵 chunk"
			stream.erase_chunk(chunk_key)
		_dirty.clear_flag(0, chunk_key, VoxelDirtyLedger.PERSIST)
	_chunk_voxel_counts.erase(chunk_key)
	_chunk_buffers.erase(chunk_key)
	# 伤害账随 chunk 一起释放，否则卸载后残留账目会随世界遍历无限增长
	_damage.erase_chunk(chunk_key)
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


## 【内部】内存中的 chunk 缓冲字典（chunk_key → PackedInt32Array(CHUNK_VOLUME)）。
##
## **仅供原生批量接口直接读取**（C++ 侧按字典取缓冲，省掉逐体素走 GDScript 字典查询）；
## 不要持有引用、也不要就地改写——写入请走 set_voxel / set_voxels_bulk。
## 之所以返回内部字典而非副本：这些调用点每次都是整世界量级的读取，拷贝一份 32³×N 的
## 缓冲比"绕过封装"代价更大，故把这条通道显式化并写清约束，而不是让它散落成私有访问。
## 内核外调用者拿不到整表：粗层增量重算请走 patch_lod_block。
func _chunk_buffers_view() -> Dictionary:
	return _chunk_buffers


# ----------------------------------------------------------------------------
# 逐体素累计伤害账（体素相邻状态，随 chunk 生命周期同步）
# ----------------------------------------------------------------------------

## 【内部】累计伤害缓冲字典（chunk_key -> PackedFloat32Array(CHUNK_VOLUME)）。
## 与 _chunk_buffers_view 同样**仅供原生批量接口直接读写**。
func _damage_buffers_view() -> Dictionary:
	return _damage.buffers()


## 【内部】写回原生伤害内核修改过的伤害缓冲（契约同 remove_voxels_bulk 的 buffers 回写）。
func _set_damage_buffers(changed: Dictionary) -> void:
	_damage.write_back(changed)


## 取某 chunk 的伤害缓冲（不存在返回空数组）。
func get_damage(chunk_key: Vector3i) -> PackedFloat32Array:
	return _damage.get_chunk(chunk_key)


## 丢弃某 chunk 的伤害账（chunk 卸载 / 被清空时调用，防无界增长）。
func clear_damage(chunk_key: Vector3i) -> void:
	_damage.erase_chunk(chunk_key)


## 清零若干体素位置的累计伤害（体素被移除后调用）。
## positions 可为 Array[Vector3i]，也可为原生内核返回的 PackedVector3Array ——
## 两者都暴露 x/y/z，故按分量构造，避免依赖具体元素类型。
func clear_damage_bulk(positions: Variant) -> void:
	_damage.clear_at_bulk(positions)


## 清空全部伤害账（世界级重置用）。
func clear_all_damage() -> void:
	_damage.clear_all()


## 【内部】指定 LOD 层（level >= 1）的粗层大格数据字典（block_key → PackedInt32Array(LOD_GRID³)）。
## 与 _chunk_buffers_view 同样**仅供原生批量接口读取**；内核外的粗层重算走 patch_lod_block。
func _lod_buffers_view(level: int) -> Dictionary:
	var idx := level - 1
	if idx < 0 or idx >= _coarse_buffers.size():
		return {}
	return _coarse_buffers[idx]


# ----------------------------------------------------------------------------
# 只读快照生命周期（写时拷贝的"另一半"）
# ----------------------------------------------------------------------------

## 只读快照句柄 —— **所有权式**的快照生命周期。
##
## 【为什么不用裸计数 begin/end 配对】快照的"结束"必须由**获得它的那一方**负责。裸计数下，
## 任何一条提前返回路径漏掉 end，计数就永久 >0，此后每一次单点写都会分叉整块 32³ 缓冲
## ——静默的性能塌陷，且从外部无从察觉（曾真实发生：批次提前释放击穿写保护）。
## 改为返回句柄后，"谁持有谁释放"由引用关系本身表达，句柄被回收时还有 PREDELETE 兜底。
##
## 【为什么必须是句柄而不是 bool】粗层降采样与渲染批次可并发持有多个快照，
## 裸计数无法区分"这次该释放哪一个"，句柄天然区分。
class ReadonlySnapshot extends RefCounted:
	var _data: VoxelData = null
	var _released := false

	func _init(d: VoxelData) -> void:
		_data = d

	## 释放快照（幂等）。调用后不得再使用本句柄。
	func release() -> void:
		if _released:
			return
		_released = true
		var d := _data
		_data = null
		# VoxelData 可能已先被释放（资源换世界/退出）：此时没有账可还，直接返回。
		if d != null and is_instance_valid(d):
			d._on_snapshot_released(self)

	## 泄漏兜底：句柄被 GC 而从未 release 时也要把计数还回去。
	## 否则一次漏释放就会让写路径**永久**分叉——这正是本设计要根除的失效模式。
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and not _released:
			release()


## 声明"缓冲即将交给后台线程只读"。返回的句柄负责释放（可并发多批）。
##
## 实测 GDScript 对 PackedInt32Array 的逐元素写不触发写时拷贝，故浅拷贝快照并不安全：
## 快照活跃期内单点写必须先分叉（见 _write_buffer_impl）。选写侧守卫而非读侧脱钩，是因为后者
## 要按快照集深拷贝（约 27MB/批），写侧只在真的写时付一次（实测约 5µs/次）。
func begin_readonly_snapshot() -> ReadonlySnapshot:
	_snapshot_readers += 1
	var handle := ReadonlySnapshot.new(self)
	_live_snapshots[handle] = true
	return handle


## 句柄释放回调（由 ReadonlySnapshot.release 调用；幂等性由句柄自身的 _released 保证）。
func _on_snapshot_released(handle: ReadonlySnapshot) -> void:
	if _live_snapshots.erase(handle):
		_snapshot_readers = maxi(_snapshot_readers - 1, 0)


## 【兼容入口】释放最近一次 begin 的句柄。
## 仅在"begin/end 严格配对"时语义正确（本类内部与渲染器的粗层任务恰好如此）；
## 每个句柄至多释放一次，故即便 LIFO 释放了"另一个"句柄，聚合计数依然正确。
## 新的可并发调用点请直接使用 begin 返回的句柄。
func end_readonly_snapshot() -> void:
	if _live_snapshots.is_empty():
		return
	var handles := _live_snapshots.keys()
	(handles[handles.size() - 1] as ReadonlySnapshot).release()


## 强制回收全部存活快照（clear / 载荷重建等**世界级重置**专用）。
##
## 只断链不改缓冲：调用方必须已保证此刻没有 worker 在读这些缓冲
## （渲染器先取消其批次，再调用 data.clear()，见 VoxelRenderer._cancel_async）。
## 不这么做的话，一个泄漏的句柄会让 _snapshot_readers 永久 >0，
## 于是此后**每一次**单点写都要复制一整块 32³ 缓冲。
func _force_release_snapshots() -> void:
	for h in _live_snapshots.keys():
		(h as ReadonlySnapshot)._released = true
	_live_snapshots.clear()
	_snapshot_readers = 0


# ----------------------------------------------------------------------------
# 取数在途查询 / 取消（账本在 VoxelAsyncLoader；查询走 is_chunk_pending）
# ----------------------------------------------------------------------------

## 撤销该 chunk/block 的在途 / 就绪登记（流式卸载：超出范围的取数结果不再需要，
## 其迟到回填会因"登记已撤销"而被丢弃）。
func cancel_chunk_request(chunk_key: Vector3i, lod: int = 0) -> void:
	_async.cancel(chunk_key, lod)


## 某层全部**在途（未就绪）**的取数 key（流式卸载时批量取消用）。
func get_unready_chunk_keys(lod: int = 0) -> Array:
	return _async.get_unready_keys(lod)


## 获取流中已存但不在内存的 chunk key 列表（流式补建调度用）
func get_unloaded_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if stream == null:
		return keys
	for ck in stream.get_all_chunk_keys(0):
		if not _chunk_buffers.has(ck):
			keys.append(ck)
	return keys


## 流中已存但不在内存的 chunk 数量。**不构造数组**，供 HUD 等每帧读取者使用。
## 算法 = 流中总数 − 内存里"流中也有"的那些：后者只遍历已加载的小集合，
## 且 has_chunk 是 O(1)，故整体 O(已加载数) 而非 O(流中总数)。
func get_unloaded_chunk_count() -> int:
	if stream == null:
		return 0
	var n := stream.get_chunk_count(0)
	for ck in _chunk_buffers:
		if stream.has_chunk(ck, 0):
			n -= 1
	return n


## 把内存中所有被修改的 chunk 写回磁盘（存档 / 退出前调用）
func flush() -> void:
	if stream == null:
		return
	# QVX 流：先注入材质调色板，使 .qvx 自带 MATE（文件自包含，P2 每条事实只存一次）
	var qs := stream as QVoxelStream
	if qs != null:
		qs.set_materials(materials)
	for ck in _dirty.keys(0, VoxelDirtyLedger.PERSIST):
		var buf: PackedInt32Array = _chunk_buffers.get(ck)
		if buf == null:
			_dirty.clear_flag(0, ck, VoxelDirtyLedger.PERSIST)
			continue
		if _chunk_voxel_counts.has(ck):
			stream.save_chunk(ck, buf)
		elif is_stored(ck):
			stream.erase_chunk(ck)
	_dirty.clear_flags(0, VoxelDirtyLedger.PERSIST)
	stream.flush()


## 把本数据层「程序化生成的有界模型」烘焙（冻结）为静态存档：逐 chunk 调用 generator，
## 非空块写入 target（典型是新建的 QVoxelStream → .qvx），材质调色板一并写入，最后 flush。
##
## 【用途】把 SDF / 蓝图模型"烧"成普通体素文件——之后加载它不再需要生成器与逐体素采样，
## 直接走既有 stream → 渲染 / 破坏 / 编辑链路（加载快、可手工再改、可当静态资产分发）。
##
## 【为何放在 VoxelData】只有它同时认识"造"(generator) 与"存"(stream)；烘焙范围就是
## grid_size（与运行时"有界模型"同一套语义），因此生成器侧一行 I/O 都不必加。
##
## 【同步】在主线程直接调 generator.generate——这是显式的离线 / 编辑期操作，不进异步队列
## （异步是运行期流式的机制，烘焙不需要）。
##
## 范围 = grid_size；ZERO（无限世界）无范围可烘焙，拒绝。
## 返回写入的 chunk 数（0 = 范围内无非空块；-1 = 参数不合法）。
func bake_to(target: VoxelStream) -> int:
	if generator == null or target == null:
		push_error("[VoxelData] bake_to 需要 generator 与 target stream")
		return -1
	if grid_size == Vector3i.ZERO:
		push_error("[VoxelData] bake_to 需要有限 grid_size（无限世界无范围可烘焙）")
		return -1
	generator.set_grid_size(grid_size)
	var qs := target as QVoxelStream
	if qs != null:
		qs.set_materials(materials)
	var last := VoxelChunk.chunk_of(grid_size - Vector3i.ONE)
	var written := 0
	for cz in range(last.z + 1):
		for cy in range(last.y + 1):
			for cx in range(last.x + 1):
				var ck := Vector3i(cx, cy, cz)
				var buf := generator.generate(ck)
				if buf.size() != CHUNK_VOLUME or _count_voxels(buf) == 0:
					continue
				target.save_chunk(ck, buf)
				written += 1
	target.flush()
	return written


## 构建期/读档批量填充 {pos: mat_id}，不标记脏 chunk、不触发信号。
## 适合一次性生成大量静态体素（demo 场景构建、外部数据导入）。
func load_voxels_dict(dict: Dictionary) -> void:
	for pos_key in dict:
		_write_buffer_impl(pos_key, dict[pos_key], false)


## 获取所有有数据的 chunk key（内存 + 流中已存的）
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
		seen[ck] = true
	if stream != null:
		for ck in stream.get_all_chunk_keys(0):
			if not seen.has(ck):
				keys.append(ck)
				seen[ck] = true
	return keys


## 平移所有 chunk key（origin shift 用）：数据层坐标整体偏移，保持世界连续。
## 相机远离时调用，使相机附近 chunk 回到小坐标，避免 float 精度损失。
## offset = 平移的 chunk 数（世界体素 = chunk × VoxelChunk.CHUNK_SIZE）。
func shift_origin(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	_chunk_buffers = VoxelChunk.shift_key_dict(_chunk_buffers, offset)
	_chunk_voxel_counts = VoxelChunk.shift_key_dict(_chunk_voxel_counts, offset)
	# 脏账本（写盘 / 网格重建 / LOD 失效 / 粗层回退 / 脏区域）各层一起平移：
	# 漏平移会让它与数据基准脱节（残留旧坐标条目）。
	_dirty.shift(offset)
	# 伤害账同样以 chunk 为键，漏平移会让它与数据基准脱节（残留旧坐标条目）
	_damage.shift(offset)
	for i in _coarse_buffers.size():
		_coarse_buffers[i] = VoxelChunk.shift_key_dict(_coarse_buffers[i], offset)
	# 降采样去重 / 重试计数已收归编排器，随下面的 _async.shift_keys() 一起平移。
	# 生成器的"可生成范围"也要跟着平移，否则无限世界平移后范围判定仍指向旧坐标。
	if generator != null:
		generator.shift_bounds(offset)
	# 在途 / 就绪登记的 key 同样要平移，否则回填会写到旧坐标（数据落在错误的 chunk 上）。
	_async.shift_keys(offset)



## 【内部】获取 chunk 的 34³ 密集"光环缓冲"（值 = 材质ID，0 = 空）。
## 覆盖 chunk 内部 + 1 体素外缘，供网格生成在子线程中只读使用（独立缓冲，无数据竞态）。
## 流式模式下先确保 chunk 及其 27 邻居已加载（跨界面的面可见性需要邻居）。
func _chunk_halo(chunk: Vector3i) -> PackedInt32Array:
	if stream != null:
		for nz in 3:
			for ny in 3:
				for nx in 3:
					preload_chunk(chunk + Vector3i(nx - HALO, ny - HALO, nz - HALO))
	return VoxelChunkGenerator.build_halo_from_buffers(_chunk_buffers, chunk)


## 【内部】生成"受影响区域"的 chunk 缓冲深拷贝快照（chunk key → PackedInt32Array 独立副本）。
## 只快照 rebuild_chunks 及其 27 邻居（构建 halo 需要），避免整世界深拷贝。
## 主线程一次性调用，随后供各子线程 worker 从快照构建自己的 halo（线程安全只读）。
## 流式模式下先把相关 chunk 从磁盘载入内存，确保快照包含磁盘上的数据。
## 快照本身由原生 C++ 完成：COW 共享 PackedInt32Array（原子 refcount，worker 只读，
## 主线程后续写 buffers 触发写时拷贝）→ 省去逐 chunk 64KB 深拷贝（大场景快照提速）。
func _snapshot_chunks_halo(rebuild_chunks: Array[Vector3i]) -> Dictionary:
	if stream != null:
		for ck in rebuild_chunks:
			for nz in 3:
				for ny in 3:
					for nx in 3:
						preload_chunk(ck + Vector3i(nx - HALO, ny - HALO, nz - HALO))
	return NativeLoader.snapshot_chunks_halo(_chunk_buffers, rebuild_chunks)


## 【内部】LOD 大块（LOD_GRID³ 大格 = 每格 2^lod 体素，覆盖 2^lod³ 个 chunk）异步生成快照：
## 大块覆盖的 2^lod³ 个 chunk + 外扩 ±2^lod 层 chunk（halo 边界大格降采样需要），COW 共享。
## 仅 preload 大块自身 chunk（必须）；外部从内存快照（LOD 区数据保留，磁盘不 preload）。
## lod=1 即原 LOD1（2×2×2 chunk）。
func _snapshot_lod_block_chunks(block_key: Vector3i, lod: int) -> Dictionary:
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


## 【内部】纯只读 chunk halo 快照：不 preload / 不写任何状态，仅快照 _chunk_buffers 中已存在的数据
## （缺失 chunk 视为空——真空区域正常）。与 _snapshot_lod_block_chunks 一致地外扩 ±2^lod 层
## 收集 halo 邻居 chunk：LOD halo 构建需要边界邻居数据（6 外缘面），否则 block 边界缺面 → 空洞。
## 调用方在**主线程**构造好后交给 worker 只读（worker 不得触碰活动字典）。
func _snapshot_lod_block_chunks_readonly(block_key: Vector3i, lod: int) -> Dictionary:
	var chunks_per_axis := 1 << lod
	var cks: Array[Vector3i] = []
	var seen := {}
	var base := block_key * chunks_per_axis
	for cz in chunks_per_axis:
		for cy in chunks_per_axis:
			for cx in chunks_per_axis:
				var ck := base + Vector3i(cx, cy, cz)
				if _chunk_buffers.has(ck):
					seen[ck] = true
					cks.append(ck)
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
	_layer(_coarse_buffers, level - 1)
	_dirty.ensure_level(level)


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
		_mark_neighbors_dirty(key)
		return
	_ensure_coarse_arrays(level)
	_coarse_buffers[level - 1][key] = buf
	# 数据已同步（全量降采样 或 金字塔增量 patch 写入）→ 清除 modified，
	# worker 据此走独立数据路径（从 coarse 生成 mesh），不再全量从 L0 降采样覆盖。
	_dirty.clear_flag(level, key, VoxelDirtyLedger.COARSE_MODIFIED)


## 粗层降采样结果落地（**唯一入口**）：写入内存权威 + 按需持久化。
##
## 【为什么归数据层】粗层数据的权威在 VoxelData，"下来源是否支持 LOD 层 / 何时该落盘"
## 这条规则此前在三个地方各写了一遍（本类的降采样回填 + 渲染器的两个结果回调），
## 且渲染器为了落盘直接伸手去拿 `data.stream`，绕过数据层。现在渲染器只报告
## "降采样结果就绪"，落盘判断与写入统一由本层负责；规则要变只改这一处。
func store_lod_block(level: int, block_key: Vector3i, buf: PackedInt32Array) -> void:
	if buf.is_empty():
		return
	set_lod_block(level, block_key, buf)
	if stream != null and stream.supports_lod_layer():
		stream.save_chunk(block_key, buf, level)


## 擦除一个 LOD block 的**数据**，并同步清掉只对"该块数据"才有意义的附属账本。
##
## 【为什么必须一起清】COARSE_MODIFIED / 脏大格区域都以 block key 为键，
## 块数据被擦除后它们不会自动消失 → 随探索/编辑**无界增长**（origin shift 还会把它们整表平移）。
## 更隐蔽的是残留 `modified=true` 会让 `_can_mesh_lod_block_standalone()` 永久返回 false，
## 使该 block 此后**永远只能走全量 LOD0 降采样**（金字塔增量失效）。
##
## 【为什么清 modified 是安全的】粗层数据的**唯一**生产者是 `_start_lod_downsample`，
## 它严格从 LOD0 chunk 缓冲（含用户编辑）降采样；本工程不存在"纯生成器输出粗层"的写入路径。
## 块数据既已擦除，该标记没有指代对象；重新创建必经 LOD0 降采样 → 编辑不会丢。
##
## 【为什么不连 LOD_MESH 一起清】它是"网格重建"账，与"该块数据"无关：块擦除后仍有在途
## 网格任务要收尾，由 get_invalidated_lod 消费时自清。历史行为，原样保留。
func erase_lod_block(level: int, key: Vector3i) -> void:
	if level == 0:
		_chunk_buffers.erase(key)
		return
	var idx := level - 1
	if idx < _coarse_buffers.size():
		_coarse_buffers[idx].erase(key)
	_dirty.clear_flag(level, key, VoxelDirtyLedger.COARSE_MODIFIED)
	_dirty.erase_region(level, key)


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
	return _dirty.has(level, key, VoxelDirtyLedger.COARSE_MODIFIED)


## 【金字塔增量】重算该粗层 block 的脏大格并就地更新其数据（消费脏区域）。
## level==1 从 LOD0 chunk 降采样；level>=2 从上一层粗层降采样（省 64 倍 LOD0 读取）。
## 返回 true = 确实 patch 了（调用方随后应重建该 block 的 mesh）；false = 无脏区域或 block 不存在。
##
## 【为何收进数据层】源缓冲（_chunk_buffers / _coarse_buffers）是内部存储，内核外不该拿整表；
## 把"取源 → 重算 → 写回"绑成一个动作，无限层不再触碰 get_chunk_buffers / get_lod_buffers。
func patch_lod_block(level: int, block_key: Vector3i) -> bool:
	if level < 1:
		return false
	var region := get_lod_dirty_region(level, block_key)
	if region.is_empty() or not has_lod_block(level, block_key):
		return false
	var coarse := get_lod_block(level, block_key)
	var patched: PackedInt32Array
	if level == 1:
		patched = VoxelChunkGenerator.patch_lod_block(
			_chunk_buffers, block_key, level, coarse, region[0], region[1])
	else:
		patched = VoxelChunkGenerator.patch_lod_block_from_lod(
			_lod_buffers_view(level - 1), block_key, level, coarse, region[0], region[1])
	set_lod_block(level, block_key, patched)
	return true


## 【内部】该粗层 block 能否**只靠自身与 6 邻居的大格数据**网格化（无需回退 LOD0 降采样）。
## 供渲染器在派发 worker 前判定数据来源，从而把快照构造留在主线程（线程安全）。
func _can_mesh_lod_block_standalone(level: int, key: Vector3i) -> bool:
	if is_lod_block_modified(level, key) or not has_lod_block(level, key):
		return false
	for d in NEIGHBORS_6:
		if not has_lod_block(level, key + d):
			return false
	return true


## 请求异步生成/加载 chunk/block 数据（后台线程：程序化走生成器，文件流走 region 读盘）。
## 统一带 lod 参数（0 = LOD0 chunk，>=1 = 粗层 block）。数据就绪后经 poll_all_ready 回填。
func request_chunk_async(chunk_key: Vector3i, lod: int = 0) -> void:
	if has_lod_block(lod, chunk_key):
		return
	# 统一编排：流里已存（含 QVX 的粗层 CACH 缓存）→ 主线程直读；否则生成器可生成 → 后台生成。
	_async.request(chunk_key, lod)
	# 粗层再兜底：两个数据源都没有（如纯文件流且没存过粗层缓存）→ 从 LOD0 降采样得到。
	# 粗层本就是 LOD0 的派生数据，降采样是最保底的来源（结果同样落 CACH 缓存）。
	if lod >= 1 and not has_lod_block(lod, chunk_key) and not _async.is_pending(chunk_key, lod):
		_start_lod_downsample(chunk_key, lod)


## 文件流粗层降采样：数据在主线程构造快照（preload 磁盘回读 + 内存读取）。
## 在途去重交给编排器（账本唯一）；快照构造前声明只读快照，使主线程在此期间的
## 单点写先分叉（否则 worker 读到的可能是被 set_voxel 改过的缓冲）。
func _start_lod_downsample(block_key: Vector3i, lod: int) -> void:
	if not _async.begin_derived(block_key, lod):
		return
	# 句柄随任务走到底、由回填方释放：不再依赖"另一个调用点的 end"来配对，
	# 故本路径与渲染批次的快照并发时也不会互相释放错。
	var snapshot := begin_readonly_snapshot()
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
		call_deferred("_on_lod_downsample_ready", block_key, lod, PackedInt32Array(), snapshot)
		return
	WorkerThreadPool.add_task(_lod_downsample_worker.bind(block_key, lod, buffers, snapshot))


## 后台线程：从 LOD0 chunk 数据降采样生成粗层 block 数据（32³ 大格，每格 = 2^lod 体素）。
## buffers 为主线程快照（只读，配合 begin_readonly_snapshot 保证不被主线程改写），
## 结果经 call_deferred 回主线程。snapshot 句柄随参数带过去，保证释放方唯一。
func _lod_downsample_worker(block_key: Vector3i, lod: int, buffers: Dictionary,
		snapshot: ReadonlySnapshot) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, block_key, lod)
	var buf := VoxelChunk.extract_center_from_halo(halo)
	call_deferred("_on_lod_downsample_ready", block_key, lod, buf, snapshot)


## 主线程：粗层降采样完成 → 缓存 _coarse_buffers + 持久化文件流（重启保留），供渲染器复用
func _on_lod_downsample_ready(block_key: Vector3i, lod: int, buf: PackedInt32Array,
		snapshot: ReadonlySnapshot) -> void:
	snapshot.release()
	if buf.is_empty():
		# LOD0 chunk 可能尚未加载（自动 request 早于 LOD0 就绪，或覆盖 chunk 仅存磁盘）→
		# 结束在途登记但保留重试计数，交给 _retry_lod_downsample 决定是否再试
		_async.end_derived(block_key, lod, true)
		_retry_lod_downsample(block_key, lod)
		return
	_async.end_derived(block_key, lod)
	store_lod_block(lod, block_key, buf)


## 粗层降采样空结果延迟重试：LOD0 chunk 常晚于粗层 request 就绪（流式加载），
## 延迟 0.5s 跨帧重试（preload 会在 _start_lod_downsample 内执行），上限防空区域死循环。
## 重试计数由编排器持有（账本唯一）。
func _retry_lod_downsample(block_key: Vector3i, lod: int) -> void:
	if not _async.note_derived_retry(block_key, lod):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(0.5).timeout.connect(
			func() -> void: _start_lod_downsample(block_key, lod))
	else:
		_start_lod_downsample(block_key, lod)


## 该 chunk/block 是否已有后台任务进行中或结果就绪（渲染器每帧预算限流用，避免重复提交）。
func is_chunk_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	if has_lod_block(lod, chunk_key):
		return true
	if _async.is_pending(chunk_key, lod):
		return true
	# 粗层降采样任务进行中（防重复降采样；账本在编排器）
	if lod >= 1 and _async.is_derived(chunk_key, lod):
		return true
	return false


## 【内部】粗 LOD 数据块快照（block 自身 + 27 邻居大格，COW 共享）：供独立数据层网格生成 worker 使用。
func _snapshot_lod_block_data(block_key: Vector3i, level: int) -> Dictionary:
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
	return _async.poll_ready(max_count)


## 主线程批量取回异步结果并**直接回填**（poll + accept 的封装），返回回填条数。
##
## 这是内核外驱动数据供给的**唯一公开入口**：缓冲格式校验、体素计数、网格脏标记、
## 粗层失效全在数据层内部完成，调用方不必也不该持有 accept 那一半协议。
## 典型用法（无限层每帧）：`data.apply_ready_results(load_per_frame * 2)`。
func apply_ready_results(max_count: int) -> int:
	var applied := 0
	for r in _async.poll_ready(max_count):
		_accept_chunk_buffer(r[1], r[2], r[0])
		applied += 1
	return applied


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
	var out: Dictionary[Vector3i, int] = {}
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		seen[ck] = true
	_for_each_non_empty_voxel(func(pos: Vector3i, mat_id: int): out[pos] = mat_id)
	if stream != null:
		for ck in stream.get_all_chunk_keys(0):
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
		if is_stored(ck):
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
		if is_stored(ck):
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			return false
	return buf[_buf_index(pos - ck * CHUNK_SIZE)] > 0


## 获取所有体素位置（内存 + 磁盘流中已持久化的，磁盘部分临时加载不缓存）
func get_positions() -> Array:
	# 内存部分整体下沉原生（逐体素枚举 + 逐体素 append 装箱 → 一次调用）：
	# GDScript 版实测约 1.28s / 200 万体素（≈20ms/chunk），原生化后约十分之一。
	var out: Array = NativeLoader.collect_all_positions(_chunk_buffers)
	if stream == null:
		return out
	# 合并"磁盘已存但不在内存"的 chunk（临时加载，不污染内存缓存）；这部分通常只有少数块
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		seen[ck] = true
	for ck in stream.get_all_chunk_keys(0):
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


## 获取体素数量。**派生查询**：由唯一权威 _chunk_voxel_counts 求和，无第二份存储可漂移。
## 注：流式模式下仅统计"内存中已加载"的体素，磁盘上的数据不计入。
## 热路径判空请用 is_empty()（不变式保证二者等价且 O(1)），不要调用本函数。
func get_voxel_count() -> int:
	var total := 0
	for n in _chunk_voxel_counts.values():
		total += n
	return total


## 是否完全没有体素
func is_empty() -> bool:
	return _chunk_buffers.is_empty()


## 设置指定位置的体素 (material_id <= 0 时移除；0 = 空)
func set_voxel(pos: Vector3i, material_id: int, notify: bool = true) -> void:
	if material_id <= 0:
		remove_voxel(pos, notify)
		return
	_write_buffer_impl(pos, material_id, false)
	_mark_voxel_dirty(pos)
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	_remove_voxels([pos], notify)


## 清空所有体素（同时清除磁盘流中的持久化数据）
func clear(notify: bool = true) -> void:
	_chunk_buffers.clear()
	# 世界级重置：泄漏的句柄必须在此断链，否则 _snapshot_readers 永久 >0，
	# 此后每一次单点写都要复制一整块 32³ 缓冲。调用方（渲染器）须已先取消其批次。
	_force_release_snapshots()
	_damage.clear_all()
	_chunk_voxel_counts.clear()
	# 脏账本一并归零（写盘 / 渲染增量重建 / 失效块 / 粗层回退 / 脏区域）。
	# 漏清会让旧坐标的脏 chunk / 失效块 / 脏区域在换世界后继续驱动渲染器重建
	# （而它们的体素早已不存在）。
	_dirty.clear_all()
	for d in _coarse_buffers:
		d.clear()
	if stream != null:
		for ck in stream.get_all_chunk_keys(0):
			stream.erase_chunk(ck)
	_async.clear()
	if notify:
		emit_changed()


## 计算全部体素的包围盒 (AABB)，用于场景摆放/居中；空体素返回零 AABB
## 注：min/max 为值类型，lambda 按值捕获无法回写 → 保持内联循环（_for_each_non_empty_voxel
## 只适合"向引用容器追加"的消费模式）。
func get_voxels_aabb() -> AABB:
	if _chunk_voxel_counts.is_empty():
		return AABB()
	# 包围盒一次原生遍历（GDScript 逐体素扫描实测 1.4ms/chunk，1400 chunk 世界约 2 秒；
	# 破坏 demo 的 1416ms 初始化里有约 275ms 来自这里）
	var bounds: Array = NativeLoader.collect_bounds(_chunk_buffers)
	if bounds.is_empty():
		return AABB()
	return _bounds_to_aabb(bounds)


## 计算一组体素的包围盒 (AABB)，空集合返回 null
static func _bounds_to_aabb(bounds: Array) -> AABB:
	if bounds.is_empty():
		return AABB()
	var min_pos: Vector3i = bounds[0]
	var max_pos: Vector3i = bounds[1]
	var extents := (max_pos - min_pos + Vector3i(1, 1, 1))
	return AABB(Vector3(min_pos), Vector3(extents))


## 体素字典 `{Vector3i: 材质ID}` 的精确包围盒 `{"min": Vector3i, "max": Vector3i}`（含端点）；
## 空集合返回 `{}`。
##
## **全项目唯一的"体素字典求界"实现**：`.vox`/`.qvx` 导入、原点偏移、网格生成都调它——
## 同类公式各写一份必然漂移（本仓库已经因为"两条路径各有一套原点"出过一次 bug）。
static func voxel_bounds(voxels: Dictionary) -> Dictionary:
	if voxels.is_empty():
		return {}
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
	return {"min": min_pos, "max": max_pos}


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
## 把该球形范围内"磁盘上有、内存里没有"的 chunk 先载入（流式下范围查询 / 破坏的前置步骤）。
## 原生只读内存缓冲，不先载入就会漏掉已持久化但未加载的数据。
func ensure_sphere_loaded(center: Vector3, radius: float) -> void:
	if stream == null:
		return
	for ck in _get_chunks_in_sphere(center, radius):
		if not _chunk_buffers.has(ck) and is_stored(ck):
			preload_chunk(ck)


## 盒形版本（同 ensure_sphere_loaded）。
func ensure_box_loaded(aabb: AABB) -> void:
	if stream == null:
		return
	for ck in _get_chunks_in_box(aabb):
		if not _chunk_buffers.has(ck) and is_stored(ck):
			preload_chunk(ck)


func get_voxels_in_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if _chunk_buffers.is_empty():
		return result
	ensure_sphere_loaded(center, radius)
	result.assign(NativeLoader.collect_sphere_positions(_chunk_buffers, center, radius))
	return result


## 查询盒形范围内的所有体素位置 (只读，不修改)
## 先找出与盒体重叠的 chunk，再只扫描这些 chunk 的密集缓冲
func get_voxels_in_box(aabb: AABB) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if _chunk_buffers.is_empty():
		return result
	# 闭区间与 GDScript 版一致：min = floori(aabb.position)，max = floori(aabb.end - 1)
	var mn := Vector3i(floori(aabb.position.x), floori(aabb.position.y), floori(aabb.position.z))
	var mx := Vector3i(floori(aabb.end.x - 1.0), floori(aabb.end.y - 1.0), floori(aabb.end.z - 1.0))
	ensure_box_loaded(aabb)
	result.assign(NativeLoader.collect_box_positions(_chunk_buffers, mn, mx))
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
## 替代旧的逐体素 GDScript 字典写（每体素 5~8 次哈希）。
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
		for ck in ck_list:
			if not _chunk_buffers.has(ck) and is_stored(ck):
				preload_chunk(ck)
	var res: Dictionary = NativeLoader.set_voxels_bulk(_chunk_buffers, positions, material_id)
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_set: Dictionary = res["chunk_set"]
	for ck in chunk_set:
		_chunk_buffers[ck] = modified_buffers[ck]
		_count_delta(ck, int(chunk_set[ck]))
		# 流式：批量写入标记写盘（否则 chunk 被流式卸载时未 dirty → 存储里旧数据残留）
		_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
	# 标记脏 chunk + 跨界面的边界邻居（用 C++ 返回的边界掩码，按 chunk 标记，
	# 避免逐体素 _mark_voxel_dirty 的多词条 dict 写入瓶颈）
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		var b: int = boundary[ck]
		if b & 1:
			_dirty.mark(0, ck + Vector3i(1, 0, 0), VoxelDirtyLedger.MESH)
		if b & 2:
			_dirty.mark(0, ck + Vector3i(-1, 0, 0), VoxelDirtyLedger.MESH)
		if b & 4:
			_dirty.mark(0, ck + Vector3i(0, 1, 0), VoxelDirtyLedger.MESH)
		if b & 8:
			_dirty.mark(0, ck + Vector3i(0, -1, 0), VoxelDirtyLedger.MESH)
		if b & 16:
			_dirty.mark(0, ck + Vector3i(0, 0, 1), VoxelDirtyLedger.MESH)
		if b & 32:
			_dirty.mark(0, ck + Vector3i(0, 0, -1), VoxelDirtyLedger.MESH)
	if notify:
		emit_changed()


## 批量移除指定位置的体素 (内部统一实现，供各 remove_* 复用)
## 写 buffer 由原生 C++ 完成（remove_voxels_bulk，按 chunk 分组直接改 PackedInt32Array），
## 替代 GDScript 逐体素循环——大崩塌（每帧 4096+ 体素）主线程大幅提速。
## GDScript 只做计数维护 + 标记脏 chunk（chunk 级 _mark_voxel_dirty，避免逐体素 dict
## 写入瓶颈；边界邻居由 _mark_voxel_dirty 一并标记）。
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
	# 原生批量移除（C++ 按 chunk 分组改 buffer，返回修改后的 buffer + 每 chunk 移除数 + 边界掩码）
	var res: Dictionary = NativeLoader.remove_voxels_bulk(_chunk_buffers, positions)
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_removed: Dictionary = res["chunk_removed"]
	var touched: Dictionary = {}
	for ck in chunk_removed:
		_chunk_buffers[ck] = modified_buffers[ck]  # 覆盖为修改后的 buffer
		_count_delta(ck, -int(chunk_removed[ck]))
		# 流式：批量删除同样标记写盘（否则 chunk 被流式卸载时未 dirty → 直接丢弃，
		# 存储里旧数据残留导致重载后体素"复活"）
		_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
		touched[ck] = true
	# 标记脏 chunk + 跨界面的边界邻居（用 C++ 返回的边界掩码，按 chunk 标记，
	# 避免逐体素 7 次 dict 写入的大崩塌瓶颈）
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		var b: int = boundary[ck]
		if b & 1:
			_dirty.mark(0, ck + Vector3i(1, 0, 0), VoxelDirtyLedger.MESH)
		if b & 2:
			_dirty.mark(0, ck + Vector3i(-1, 0, 0), VoxelDirtyLedger.MESH)
		if b & 4:
			_dirty.mark(0, ck + Vector3i(0, 1, 0), VoxelDirtyLedger.MESH)
		if b & 8:
			_dirty.mark(0, ck + Vector3i(0, -1, 0), VoxelDirtyLedger.MESH)
		if b & 16:
			_dirty.mark(0, ck + Vector3i(0, 0, 1), VoxelDirtyLedger.MESH)
		if b & 32:
			_dirty.mark(0, ck + Vector3i(0, 0, -1), VoxelDirtyLedger.MESH)
	# 移除后清零这些位置的累计伤害。用**请求列表**而非原生返回的 removed ——
	# 后者是"实际移除的体素数"（int），不是位置数组。对本来就没有体素的位置清零也无害
	# （那些位置按契约不应有伤害）。
	clear_damage_bulk(positions)
	# 批量移除后统一回收被清空的 chunk 键（O(1) 计数判断）
	for ck in touched:
		_maybe_erase_empty_chunk(ck)
	if notify:
		emit_changed()
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
## 全部非空体素，扁平 (x, y, z, mat) 四元组（原生一次收集）。
## 不用"每体素一个 4 元素 Array"：200 万体素会变成 200 万个小对象（实测 1.97s / ~300MB，
## 扁平形式 14ms / 32MB）。
func _serialize_voxels() -> PackedInt32Array:
	return NativeLoader.collect_all_flat(_chunk_buffers)


## 从一组 chunk key 收集体素为扁平 (x, y, z, mat) 四元组。
## 每 chunk 取缓冲：内存优先，否则从流读取（程序化修改块存于 stream._modified /
## 文件流存于 region 文件）。供 _serialize_voxels_for_storage（修改块集）与
## _serialize_all_voxels（磁盘合并）复用同一收集入口。
func _serialize_chunks_to_list(chunk_keys: Array) -> PackedInt32Array:
	var sub := {}
	for ck in chunk_keys:
		var buf := _get_chunk_buffer_for_storage(ck)
		if not buf.is_empty():
			sub[ck] = buf
	if sub.is_empty():
		return PackedInt32Array()
	return NativeLoader.collect_all_flat(sub)


## 收集"需随资源持久化"的 chunk key（有生成器的世界：用户修改过的 = 内存未写盘的 PERSIST 账 +
## 流中已存的覆盖层）。无生成器返回空（由 _serialize_voxels 全量覆盖）。
func _collect_modified_chunk_keys() -> Array:
	var keys := {}
	if generator != null:
		for ck in _dirty.keys(0, VoxelDirtyLedger.PERSIST):
			keys[ck] = true
		if stream != null:
			for ck in stream.get_all_chunk_keys(0):
				keys[ck] = true
	var out: Array = []
	for ck in keys:
		out.append(ck)
	return out


## 序列化"需要随资源持久化"的体素（_get 存储专用）。
## 有生成器：只序列化用户修改过的 chunk（未修改的由生成器确定性重算、无需存储——
##   全部序列化会把 .tscn 撑成上百 MB（历史上 734 万体素 → 137MB 的灾难即由此而来））。
## 无生成器（纯静态数据 / 文件流）：数据只存在于内存与流中，序列化全部体素。
func _serialize_voxels_for_storage() -> PackedInt32Array:
	if generator != null:
		var keys := _collect_modified_chunk_keys()
		if keys.is_empty():
			return PackedInt32Array()
		return _serialize_chunks_to_list(keys)
	return _serialize_voxels()


## 取 chunk 缓冲（内存优先；未加载则从流读取）
func _get_chunk_buffer_for_storage(chunk_key: Vector3i) -> PackedInt32Array:
	var buf = _chunk_buffers.get(chunk_key)
	if buf != null:
		return buf
	if stream != null:
		return _load_chunk_from_stream(chunk_key)
	return PackedInt32Array()


## 序列化所有体素（内存 + 流中已存的数据）。
## 流式模式下存储数据由 stream 管理，一次性全量存档时需合并；
## 存储部分临时加载，不污染内存缓存。
## 有生成器：未修改 chunk 可确定性重新生成，只序列化修改过的。
## save_data()（显式存档）使用此完整版；资源持久化（_get/_encode_payload）走
## _collect_persist_blocks（块表 {chunk: buffer}），不经过逐体素序列化。
func _serialize_all_voxels() -> PackedInt32Array:
	if generator != null:
		return _serialize_voxels_for_storage()
	var flat := _serialize_voxels()
	if stream == null:
		return flat
	# 存储流（QVoxelStream）：合并已存但不在内存的 chunk（临时加载，不污染内存缓存）
	var extra: Array = []
	for ck in stream.get_all_chunk_keys(0):
		if not _chunk_buffers.has(ck):
			extra.append(ck)
	if not extra.is_empty():
		flat.append_array(_serialize_chunks_to_list(extra))
	return flat


## origin_mode 见 OriginMode（与 from_voxel_data 同一套语义与同一个默认值）。
## QVX 的体素坐标就是文件里的块坐标（**不重映射**），因此这里只需写对 center_offset——
## 渲染顶点 = (块坐标 + center_offset) * voxel_scale，结果与 .vox 路径逐体素一致。
static func from_qvx(qvx: QVoxelAsset, origin_mode: int = OriginMode.WORLD_ORIGIN) -> VoxelData:
	var res := VoxelData.new()
	res.materials = qvx.materials
	if qvx.is_block_importable():
		var blocks: Dictionary = qvx.block_buffers()
		for key in blocks:
			# duplicate：本资源随后会就地修改缓冲，不得与 QVoxelAsset 共享
			res._install_block_buffer(key, (blocks[key] as PackedInt32Array).duplicate())
	else:
		var voxels: Dictionary = qvx.fused_voxels()
		for pos in voxels:
			res._write_buffer_impl(pos, voxels[pos], false)
	res.grid_size = qvx.grid_size()
	res.center_offset = qvx.origin_offset(origin_mode)
	return res


## 反序列化体素。接受两种载荷：
##   · 扁平 PackedInt32Array（当前格式）：(x, y, z, mat) × N，原生整块装回
##   · Array of [x, y, z, mat]（旧格式）：保留读取分支，旧存档仍可载入
## 调用前应已 clear()（load_data 会先清），故这里按"新缓冲"直接装入，不合并旧数据。
func _deserialize_voxels(voxel_list: Variant) -> void:
	if voxel_list == null:
		return
	if voxel_list is PackedInt32Array:
		var bufs := NativeLoader.install_flat_voxels(voxel_list)
		for ck in bufs:
			_install_block_buffer(ck, bufs[ck])
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
#   2. 载荷整体 GZIP 压缩后 base64 存储（"GZIP" 头，与 SaveTool 同款约定），
#      即使静态大模型数据也压缩到可接受体积。
# 帧格式（魔数 / GZIP / base64）与版本校验的唯一实现在 VoxelPayloadCodec；
# 本类只负责内容组装（_encode_payload）与回填（_load_payload_blocks / _set）。

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


## 编码资源载荷：组装 {v, grid_size, blocks} 后交给 VoxelPayloadCodec 过帧。
##
## 【为什么是"块表"而不是逐体素列表】体素本来就按 chunk 对齐存在 `_chunk_buffers`
## （PackedInt32Array），直接搬运是零转换；逐体素列表则要先构造一个百万级
## Array of Arrays 再序列化，峰值内存与耗时都是它的数倍。
func _encode_payload() -> String:
	return VoxelPayloadCodec.encode({
		"v": VoxelPayloadCodec.VERSION,
		"grid_size": [grid_size.x, grid_size.y, grid_size.z],
		"blocks": _collect_persist_blocks(),
	})


## 收集"需随资源持久化"的块缓冲 {chunk_key: PackedInt32Array}。
## 取舍与 _serialize_voxels_for_storage 一致：
##   有生成器 → 只存用户改过的块（未改的由生成器确定性重算，全量存会把 .tscn 撑爆）；
##   无生成器 → 存内存中全部块（磁盘流中的部分由 stream 自己负责，不进资源载荷）。
func _collect_persist_blocks() -> Dictionary:
	var out := {}
	if generator != null:
		for ck in _collect_modified_chunk_keys():
			var buf := _get_chunk_buffer_for_storage(ck)
			if not buf.is_empty():
				out[ck] = buf
		return out
	for ck in _chunk_buffers:
		out[ck] = _chunk_buffers[ck]
	return out


## 从载荷恢复块缓冲（块表：chunk_key → PackedInt32Array）。缺字段即视为空载荷。
func _load_payload_blocks(payload: Dictionary) -> void:
	var blocks: Variant = payload.get("blocks")
	if not (blocks is Dictionary):
		return
	for key in (blocks as Dictionary):
		_install_block_buffer(key, (blocks as Dictionary)[key])


## 解码资源载荷：帧格式（魔数 / GZIP / base64）与版本校验见 VoxelPayloadCodec，
## 返回 null 即载荷无效（调用方按空载荷处理，不猜着读）。
func _decode_payload(value: String) -> Variant:
	return VoxelPayloadCodec.decode(value)


func _set(property: StringName, value: Variant) -> bool:
	if property == &"voxel_data_payload":
		# 只清内存缓冲，不动 stream 的磁盘持久化数据——场景加载时 stream 已先赋值，
		# 若调 clear() 会走 stream.erase_chunk 误删磁盘上已持久化的修改 chunk。
		_chunk_buffers.clear()
		_force_release_snapshots()
		_damage.clear_all()
		_chunk_voxel_counts.clear()
		_dirty.clear_all()
		for d in _coarse_buffers:
			d.clear()
		var payload: Variant = _decode_payload(str(value))
		if payload is Dictionary:
			var gs: Variant = payload.get("grid_size", [0, 0, 0])
			if gs is Array and gs.size() >= 3:
				grid_size = Vector3i(int(gs[0]), int(gs[1]), int(gs[2]))
			_load_payload_blocks(payload)
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
	if not _chunk_buffers.has(chunk_key) and is_stored(chunk_key):
		# 流式：存储里的 chunk 载入内存再遍历（保证结果完整）
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


## O(1) 判断指定 chunk 数据是否已就绪（内存已加载 / 流中已存）。
## 生成器可生成但尚未生成的 chunk 返回 false（需统一流式 VoxelInfiniteLayer.process_streaming 生成后才有数据）。
func has_chunk(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key) or is_stored(chunk_key)


# ----------------------------------------------------------------------------
# 连通性检测（崩塌支撑判定）—— 算法已抽到 VoxelConnectivity
# ----------------------------------------------------------------------------
# 泛洪 / 连通分组 / 支撑失稳的实现与 NEIGHBORS_6 真值都在 VoxelConnectivity；
# 本类只保留公开 API 的薄转发，判据以 Callable 传入（has_voxel / get_positions）。
# 保留转发是为了不破坏既有调用方（VoxelDestructible / 测试 / demo）；
# 这些壳是否移除由 P4 的"API 面收口"决定。

## 泛洪标记与 seeds 连通的体素集合（Dictionary 作 Set）。见 VoxelConnectivity.flood_fill
func flood_fill(seeds, restrict: Dictionary = {}) -> Dictionary:
	return VoxelConnectivity.flood_fill(seeds, has_voxel, restrict)


## 某体素所在的整个连通块。见 VoxelConnectivity.find_connected
func find_connected(pos: Vector3i) -> Dictionary:
	return VoxelConnectivity.find_connected(pos, has_voxel)


## 某体素的连接度（相邻实体素数 0-6）。见 VoxelConnectivity.connectivity
func connectivity(pos: Vector3i) -> int:
	return VoxelConnectivity.connectivity(pos, has_voxel)


## 某体素的相邻实体素位置数组 (6 方向)。见 VoxelConnectivity.neighbors
func neighbors(pos: Vector3i) -> Array[Vector3i]:
	return VoxelConnectivity.neighbors(pos, has_voxel)


## 按 6 方向连通性分组，返回 Array[Array[Vector3i]]。见 VoxelConnectivity.partition_connected
static func partition_connected(positions: Array) -> Array:
	return VoxelConnectivity.partition_connected(positions)


## 找出"悬空"体素（与地面断开的连通分量）。见 VoxelConnectivity.find_unsupported
## 空世界守卫留在本类：它读的是存储侧权威 _chunk_voxel_counts，不属于连通性算法。
func find_unsupported(voxels_set: Dictionary = {}) -> Dictionary:
	if voxels_set.is_empty() and _chunk_voxel_counts.is_empty():
		return {}
	return VoxelConnectivity.find_unsupported(voxels_set, get_positions, has_voxel)


## 找出"悬空"体素（局部检测，原生列支撑）。见 VoxelConnectivity.find_unsupported_around
func find_unsupported_around(removed: Array) -> Dictionary:
	return VoxelConnectivity.find_unsupported_around(_chunk_buffers, removed)
