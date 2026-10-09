class_name VoxelInfiniteLayer
extends RefCounted

## 无限层（视点调度）：视锥剔除 / 延迟补建队列 / 流式加载与卸载 / 卸载半径 / 原点漂移 /
## LOD 分带调度（各粗层的枚举、生成、移除、可见性兜底与异步供需）。
##
## 【为什么单独成层】这些逻辑全部以"相机在哪"为前提，与"体素怎么存、网格怎么组装"正交。
## 内核（VoxelRenderer）不该知道相机、视锥、流式距离、LOD 分带的存在 ——
## 它只该回答"按 chunk / 按 block 建 / 删网格"。
## 本层把视点决策集中到一处，内核只留存储、网格组装、材质、碰撞与脏区域账本。
##
## 【依赖方向】本层 → 内核（单向）：
##   · 读内核的存储与变换：`data` / `voxel_scale` / `global_position` / `current_camera()`
##   · 读/写内核的网格账本（见下）：`has_lod_mesh` / `lod_mesh` / `lod_mesh_keys` /
##     `mount_lod_mesh` / `clear_lod_mesh` / `mark_lod_block_empty` / `lod_materials` /
##     `is_mesh_build_queued`，以及层数操作 `lod_level_count` / `set_lod_level_count` /
##     `clear_lod_level`
##   · 命令内核：`remove_chunk_mesh` / `request_update` / `has_chunk_mesh` / `shift_render`，
##     以及经 data 的标脏
## 反向只有一处：内核的网格管线在派发前问"哪些 chunk 可见"（`filter_visible_chunks`）。
## 那是**查询**而非依赖。
##
## 【为什么网格账本 `_lod_meshes` 留在内核、而调度账本在本层】二者看似同类，实则依赖方向相反：
##   · `_lod_meshes` 是**渲染节点账本**，与 `_chunk_collisions` 同一族 —— 内核的
##     `remove_chunk_mesh`（数据变空时清残留网格）、`_update_chunk_collision`（取 mesh 提面）、
##     `has_chunk_mesh`、`shift_render` 都要读它，demo/测试的 HUD 也直接读它统计 chunk 数。
##     若把它搬进本层，内核就得反过来问本层要节点 —— 那是架构禁止的反向依赖。
##   · 调度账本（待办 / 重建 / 重试 / 代次 / 分带 / 预算）只有本层读，故整体迁入。
## 于是内核只多开 8 个针对网格账本的按键窄访问器（比"暴露整个表"更窄，也与既有的
## `has_chunk_mesh` 同一风格），本层不碰内核任何私有成员。
##
## 【为什么 `_lod_outer` 与 LOD 调度一起在本层】分带表（各层外半径）是纯视点几何，
## 期 1 已把公式收进 `VoxelLodGrid.bands`；本层的 `filter_visible_chunks` / `process_streaming`
## 也一直在读它（此前经 `kernel.lod_outer()`），迁入后直接读自己的字段。
##
## 【原点漂移为何"决策在本层、平移在内核"】何时平移（阈值判定）与相机反向补偿是纯视点逻辑，
## 归本层；而"平移哪些账本"全是内核的渲染层私有状态（网格节点 / 碰撞体 / 各类队列），
## 内核只暴露一个 `shift_render(shift, chunk_size_world)` 整体平移，本层不逐个去摸内核私有成员。
##
## 【为什么配置仍挂在节点上】`visibility_mode` / `view_distance` / `unload_distance` /
## `lod_count` / `visibility_check_interval` / 各 LOD 预算与预生成提前量仍是 `VoxelRenderer`
## 的 `@export`，本层每帧经 `kernel` 读取。
## 有意如此：`@export` 只能挂在 Node / Resource 上，而本层是 `RefCounted`（不需要进场景树，
## 也不该被序列化）。把这些旋钮搬到本层 = 用户从此在 Inspector 里看不到、也存不进场景 ——
## 对一个插件来说是把"可调"变成"要改代码"，得不偿失。所以**只搬状态与逻辑，配置留在节点**，
## 与本层既有的 `unload_d()` 读 `kernel.unload_distance` 是同一处理。
##
## 【无相机时的行为】未入树 / 无相机 / FULL 模式一律"不裁剪"（保守放行），与旧实现一致。

## 超范围粗层数据的清理降频（每 N 个扫描 tick 一次）。卸载扫描较重，不宜每 tick 全量跑。
const STREAM_UNLOAD_INTERVAL := 8

## 内核引用（唯一依赖）。为 null 时本层全部方法安全空转。
var kernel: VoxelRenderer = null

## 流式启用（由内核的 visibility_mode 推导后推入；运行时切换模式立即生效）。
## 有意做成"推入"而非每帧从内核读：模式切换要立刻生效，且这是本层唯一的开关状态。
var streaming_enabled := false

## 延迟补建队列：视锥外的 chunk（chunk_key → true）。进视锥 / 靠近后由 process_deferred_chunks 补建。
var _deferred_chunks: Dictionary = {}

## 强制构建标记：距离驱动的补建（延迟队列晋升 / 已存数据同步预载），
## 使增量重建时不被视锥剔除再次拦回延迟队列。
var _stream_force_build: Dictionary = {}

## 流式扫描降频计数与上次相机位置（相机不动时扫描结果不变，无需重复全量遍历）。
var _streaming_check_tick := 0
var _last_streaming_cam_pos := Vector3(INF, INF, INF)

## 数据基准 chunk（origin shift 后）：相机 chunk 距基准超阈值时平移世界，保持 float 精度。
var _origin_chunk: Vector3i = Vector3i.ZERO

## origin shift 阈值（chunk）：相机 chunk 距基准超此值触发平移。chunk 16³ × 0.1 = 1.6 世界单位，
## 256 chunk ≈ 410 世界单位，远小于 float32 精度上限（~1677 万），安全。
const ORIGIN_SHIFT_THRESHOLD := 256

# ── LOD 调度状态────────────────────────────────────────
# 分带 / 待办 / 重建 / 重试 / 代次五张表按 LOD 层级平行（index 0 = LOD0，占位不用）；
# 长度唯一维护点是 configure_lod（由内核 _configure_lod 调用）。

## 各层外半径（世界单位）：_lod_outer[i] = LOD_i 显示区外边界（LOD0 区 = [0, _lod_outer[0]]）。
## 分带：LOD0 外半径 = view_distance / 2^lod_count；LOD_i(i≥1) 外半径 = view_distance / 2^(lod_count-1-i)。
var _lod_outer: Array[float] = []

## 各层已派发待结果的 block（去重）
var _lod_pending_tasks: Array[Dictionary] = []
## 失效重建标记：破坏/编辑后 block 数据变化，保留旧 mesh 直到新 mesh 就绪替换（防重建闪烁）
var _lod_rebuild: Array[Dictionary] = []
## 粗层降采样空结果重试计数（内层 = block key → n）。降采样空多为 LOD0 数据未就绪，
## 不设空标记（否则跳过导致洞永远），重试上限后设空标记防真空 block 循环。
## 【为什么用分层 Array 而不是 "level_bk" 字符串复合键】字符串键无法随 origin shift 平移
## （要解析回来得拆串），于是平移时只能整表丢弃、重试计数错位。分层后可复用
## VoxelChunk.shift_key_dict，与其它 block 级集合一致。
var _lod_null_retries: Array[Dictionary] = []
## 各层 block 级代次（block key → int）：失效 block 各自递增（仅作废该 block 在途任务），
## 避免"任一失效就整体 +1 → 该层所有在途任务作废重派"的连续破坏任务洪峰。
var _lod_block_gen: Array[Dictionary] = []

## 数据 chunk 范围（needed 枚举剪枝：球体全高大部分是空气层，
## 跳过空 block 的降采样派发——否则高层空块反复派发占满 worker，lod_count>1 帧率骤降）
var _data_chunk_min := Vector3i(0, 0, 0)
var _data_chunk_max := Vector3i(0, 0, 0)

## 本帧跨层共享的构建数 / 提交数（每轮 process_lod 开头归零）
var _lod_build_this_frame: int = 0
var _lod_submit_this_frame: int = 0

## 粗层降频计数：每 visibility_check_interval 帧跑一次 LOD 调度（数据失效时立即跑）
var _cull_check_counter := 0

## 粗 LOD 大块 mesh 挂载队列：[[level, block_key, mesh]]，帧尾限量挂载（GPU 上传摊平）。
## 粗块 mesh 覆盖数十万体素，多个后台结果同时到达时直接同步挂载会卡主线程。
var _lod_mesh_apply_queue: Array = []
var _lod_mesh_apply_scheduled := false

## 粗 LOD worker 任务 ID（退出时等待，防 call_deferred 打到已释放实例）
var _coarse_task_ids: Array[int] = []
## 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据
var _exiting := false
## 任务 ID 集合的常驻上限（超出即 wait 最旧一批，见 trim_tasks）
const COARSE_TASK_ID_BUDGET := 256


func _init(k: VoxelRenderer = null) -> void:
	kernel = k


## 运行时切换可见性模式时同步（FULL 下延迟队列失去意义，必须清空）。
func set_visibility_mode(mode: int) -> void:
	streaming_enabled = mode == VoxelRenderer.VisibilityMode.STREAMING
	if mode == VoxelRenderer.VisibilityMode.FULL:
		_deferred_chunks.clear()


## 卸载距离：unload_distance 未显式设置（<= view_distance）时回退为 view_distance * 1.2。
## 所有距离判定（网格过滤 / 数据卸载 / LOD 挂载 / 过期结果丢弃）共用此值，避免各处分歧。
## 惰性计算：不 mutate unload_distance 字段，规避属性加载顺序导致的错误固化值。
func unload_d() -> float:
	if kernel == null:
		return 0.0
	return kernel.unload_distance if kernel.unload_distance > kernel.view_distance else kernel.view_distance * 1.2


## LOD0 **数据**卸载半径：比网格卸载半径再外扩"最粗层 block 的覆盖范围"。
## 为什么外扩：粗层 block 在 unload_d 附近仍可能被构建 / 降采样，而降采样要读它覆盖的
## 2^level³ 个 LOD0 chunk（还要 +1 chunk 光环）。若 LOD0 数据在 block 覆盖范围内被卸掉，
## 降采样会读到"假空块" → 粗层缺格 / 空洞。外扩 2 个 block 边长足以覆盖"block 中心仍在
## unload_d 内 + 覆盖 chunk 继续向外延伸"的最坏情形。
func lod0_data_unload_d() -> float:
	if kernel == null:
		return 0.0
	var coarse_level := maxi(kernel.lod_count - 1, 1)
	return unload_d() + 2.0 * VoxelLodGrid.block_edge_world(coarse_level, kernel.voxel_scale) \
			+ kernel.voxel_scale * VoxelChunk.CHUNK_SIZE


## 统一视锥可见性判定（对外统一接口）：世界坐标是否在当前相机视锥内。
## 供粒子 / 破碎 / 掉落体等"视锥外跳过"优化使用（相机看不到的位置跳过昂贵效果）。
## 无相机 / 未入树时返回 true（保守：不裁剪）。
func is_world_visible(world_pos: Vector3) -> bool:
	var cam := kernel.current_camera() if kernel != null else null
	if cam == null:
		return true
	return cam.is_position_in_frustum(world_pos)


## 延迟补建队列成员查询（内核的网格管线在派发前用来剔除"重建权已归延迟队列"的脏 chunk，
## 见 VoxelRenderer._update_mesh_async 的流式防抖注释）。
func is_deferred(ck: Vector3i) -> bool:
	return _deferred_chunks.has(ck)


## 网格被内核移除时同步（该 chunk 的重建权随之作废，否则会残留"幽灵补建"条目）。
func on_mesh_removed(ck: Vector3i) -> void:
	_stream_force_build.erase(ck)
	_deferred_chunks.erase(ck)


## 延迟队列是否为空（内核的增量重建防抖先问这一句，非流式场景下可直接跳过整轮脏列表遍历）。
func deferred_is_empty() -> bool:
	return _deferred_chunks.is_empty()


## origin shift 后平移本层的坐标键账本（延迟队列 + 强制构建标记）。
## 漏平移会让在途补建拿旧键比对 → 结果被误判过期丢弃，且标记永久停留在旧坐标系（无界增长）。
func shift_keys(shift: Vector3i) -> void:
	var ndf: Dictionary[Vector3i, bool] = {}
	for k in _deferred_chunks:
		ndf[Vector3i(k) + shift] = true
	_deferred_chunks = ndf
	_stream_force_build = VoxelChunk.shift_key_dict(_stream_force_build, shift)
	# 粗层 block 级账本：不平移会让在途任务拿旧键去比对 _lod_block_gen → 结果被误判过期丢弃，
	# 且 _lod_null_retries 的键永久停在旧坐标系（只增不减）。
	for level in range(1, _lod_pending_tasks.size()):
		_lod_pending_tasks[level] = VoxelChunk.shift_key_dict(_lod_pending_tasks[level], shift)
	for level in range(1, _lod_rebuild.size()):
		_lod_rebuild[level] = VoxelChunk.shift_key_dict(_lod_rebuild[level], shift)
	for level in range(1, _lod_block_gen.size()):
		_lod_block_gen[level] = VoxelChunk.shift_key_dict(_lod_block_gen[level], shift)
	for level in range(1, _lod_null_retries.size()):
		_lod_null_retries[level] = VoxelChunk.shift_key_dict(_lod_null_retries[level], shift)
	# 挂载队列里的 mesh 数组是旧坐标系下生成的（顶点已烘焙世界位置），平移会整体错位 →
	# 直接丢弃重算。代价只是一次多余重建，且 origin shift 极少触发（相机跨越 256 chunk）。
	_lod_mesh_apply_queue.clear()
	_lod_mesh_apply_scheduled = false


## 清空延迟队列与强制标记（数据 / 缩放变化导致全部网格作废时，随内核 _clear_lod_meshes 一起清）。
func clear_deferred() -> void:
	_deferred_chunks.clear()
	_stream_force_build.clear()


## 同步相机缓存位置（origin shift 反向补偿相机后必须调用，否则下一帧读到一次伪"相机移动"）。
func sync_cam_pos(p: Vector3) -> void:
	_last_streaming_cam_pos = p


## 当前数据基准 chunk（origin shift 后）。供 HUD / 调试读取。
func origin_chunk() -> Vector3i:
	return _origin_chunk


## 动态原点重定位：相机 chunk 距数据基准超阈值时，平移数据层 + 渲染层 + 相机，
## 使相机附近 chunk 回到小坐标，避免 float32 精度损失（无限移动世界）。
## 调用方：process_streaming（仅无限世界 data.infinite 时）。
func check_origin_shift(cam: Camera3D) -> void:
	if kernel == null or cam == null:
		return
	var chunk_size_world := kernel.voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam.global_position, chunk_size_world, kernel.global_position)
	var delta := cam_ck - _origin_chunk
	var shift := Vector3i.ZERO
	if delta.x >= ORIGIN_SHIFT_THRESHOLD:
		shift.x = delta.x - ORIGIN_SHIFT_THRESHOLD
	elif delta.x <= -ORIGIN_SHIFT_THRESHOLD:
		shift.x = delta.x + ORIGIN_SHIFT_THRESHOLD
	if delta.y >= ORIGIN_SHIFT_THRESHOLD:
		shift.y = delta.y - ORIGIN_SHIFT_THRESHOLD
	elif delta.y <= -ORIGIN_SHIFT_THRESHOLD:
		shift.y = delta.y + ORIGIN_SHIFT_THRESHOLD
	if delta.z >= ORIGIN_SHIFT_THRESHOLD:
		shift.z = delta.z - ORIGIN_SHIFT_THRESHOLD
	elif delta.z <= -ORIGIN_SHIFT_THRESHOLD:
		shift.z = delta.z + ORIGIN_SHIFT_THRESHOLD
	if shift == Vector3i.ZERO:
		return
	# 三方必须同步：数据层键 / 渲染层键与节点位置 / 相机位置。漏任一方都会留下幽灵数据或幽灵网格。
	kernel.data.shift_origin(shift)
	_origin_chunk += shift
	kernel.shift_render(shift, chunk_size_world)
	shift_keys(shift)
	cam.global_position -= Vector3(shift) * chunk_size_world
	sync_cam_pos(cam.global_position)


## 统一可见性决策：流式距离过滤（超 unload 不建网格）+ LOD 层级过滤 + 视锥 / 近处全向过滤
## （近处 LOD0 区无条件构建、视锥内构建、视锥外进延迟队列待补建）。
## 由内核的网格管线在派发任务前调用（全量构建与增量重建共用同一判定，消除分歧）。
func filter_visible_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if kernel == null:
		return chunks
	if kernel.visibility_mode == VoxelRenderer.VisibilityMode.FULL:
		return chunks
	var cam := kernel.current_camera()
	if cam == null:
		return chunks
	var data := kernel.data
	var voxel_scale := kernel.voxel_scale
	var world_offset := kernel.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	# LOD0 显示区外边界。count=1 时 bands 会给出 view_distance
	# （lod0 带 = [0, D]，全 lod0），此处必须取 lod_outer[0] 而非"count>1 否则 0"——
	# 否则 count=1 时"近处 LOD0 区无条件构建"失效，所有 chunk 走视锥剔除，
	# 视锥外 chunk 被 deferred 不建 mesh → lod0 只覆盖视锥内而非 [0, D]（"越改越近"）。
	var lod_outer := _lod_outer
	var lod0_d := lod_outer[0]
	var lod0_margin := VoxelLodGrid.margin(0, voxel_scale)
	var unload_d := unload_d()
	var lod_count: int = kernel.lod_count
	var visible: Array[Vector3i] = []
	for ck in chunks:
		# 无数据的空 chunk：不纳入网格管理（无体素无需构建 / 补建，避免补建空 chunk 死循环）
		if data and not data.has_chunk(ck):
			continue
		# 流式距离层（仅 STREAMING）：超 unload 不建网格（数据由统一流式卸载，重进范围再按需重载）
		if streaming_enabled and unload_d > 0.0:
			if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > unload_d:
				continue
		# 【关键】LOD 层级过滤：与流式模式无关（LOD 按距离用不同分辨率，正交于流式加载）。
		# 超出 LOD0 带的 chunk 由对应粗层 block 覆盖——从一开始就决定显示哪个层级，
		# 否则 FRUSTUM 等非流式模式下远处 chunk 也会构建 LOD0 网格 → "先细后粗"闪烁。
		if lod0_d > 0.0:
			var level := VoxelLodGrid.chunk_render_level(ck, cam_pos, world_offset, voxel_scale, lod_outer, lod_count)
			if level > 0:
				_stream_force_build.erase(ck)
				continue
		# 流式补建强制的 chunk：距离驱动，无条件构建（清除标记避免重复）
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		# 近处 LOD0 区（chunk 中心 < lod0+margin）不视锥剔除：快速转向 / 后退近处不空
		if lod0_d > 0.0:
			if VoxelLodGrid.block_dist(ck, 0, cam_pos, world_offset, voxel_scale) <= lod0_d + lod0_margin:
				visible.append(ck)
				continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


## 周期性检查延迟补建队列：视锥外的 chunk 进入视锥（或相机靠近）后触发补建。
## 【限量补建】每帧最多 load_per_frame 个（与流式加载限量一致），
## 走近 / 转向时避免一次把大量待建 chunk 全部标脏 → 主线程快照 + 生成 + GPU 上传掉帧。
## 视锥内优先，其次 view_distance 半径内。由内核 _process 每帧调用。
func process_deferred_chunks() -> void:
	if kernel == null or _deferred_chunks.is_empty():
		return
	var cam := kernel.current_camera()
	if cam == null:
		return
	var data := kernel.data
	var voxel_scale := kernel.voxel_scale
	var world_offset := kernel.global_position
	var load_per_frame: int = kernel._stream_load_per_frame
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var margin := kernel.view_distance
	var cam_pos := cam.global_position
	var _iter := 0
	var to_build: Array = []
	var to_drop: Array = []
	# 【先收集、后修改】Godot 的 Dictionary 在迭代期间增删会导致漏掉元素（旧实现在循环体里
	# 直接 `erase(ck)`）。仍按限量扫描，避免视锥外大量待建 chunk 每帧全遍历。
	for ck in _deferred_chunks:
		_iter += 1
		if _iter > load_per_frame * 8:
			break
		if to_build.size() >= load_per_frame:
			break
		# 已构建网格的 chunk 无需补建（从待建队列移除，避免重复重建）；
		# 无数据的空 chunk 也无需补建（否则空重建死循环，三角=0 刷日志）
		if kernel.has_chunk_mesh(ck) or (data and not data.has_chunk(ck)):
			to_drop.append(ck)
			continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if not VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			if not (margin > 0.0 and VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) <= margin):
				continue
		to_drop.append(ck)
		to_build.append(ck)
	for ck in to_drop:
		_deferred_chunks.erase(ck)
	for ck in to_build:
		if data:
			# 强制构建标记：确保增量重建时不被视锥剔除拦截回延迟队列
			# （该 chunk 在视锥外但已在加载范围，必须真正构建）
			_stream_force_build[ck] = true
			data.mark_chunk_dirty(ck)
	if to_build.size() > 0:
		kernel.request_update()


## 统一流式 / 程序化驱动（合并原 _process_streaming / _process_procedural）：
## 按相机距离管理 chunk 数据与网格。数据源分成两个**并列**的抽象，差异不再靠类型分支猜：
##   - 数据层（QVoxelSource 及其扩展）：未存过的 chunk 后台确定性产出（can_generate_chunk）。
##     存过的（= 用户改过）必须优先从流取，否则重新生成会覆盖用户修改。
##   - stream（VoxelStream）：已存的数据（QVoxelStream 常驻内存索引 → 直读）。
## 统一流程：① poll 回填异步结果 → ② 距离内扫描缺失 chunk 提交（限量 / 降频）→
## ③ 卸载超范围网格与粗层数据块。
## "想要集合"统一 = 相机加载半径内缺失 chunk；存在性判定统一走 QVoxelSource.can_supply_chunk
## （流里已存 或 本层造得出），不再维护 _streamed_out_chunks 渲染层注册表。
func process_streaming() -> void:
	if kernel == null or not kernel.is_inside_tree():
		return
	var data := kernel.data
	if data == null:
		return
	var cam := kernel.current_camera()
	if cam == null:
		return
	if not data.is_streaming():
		return
	var voxel_scale := kernel.voxel_scale
	var world_offset := kernel.global_position
	var cam_pos := cam.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var load_per_frame: int = kernel._stream_load_per_frame
	var unload_per_frame: int = kernel._stream_unload_per_frame
	var check_interval: int = kernel.visibility_check_interval
	var lod_count: int = kernel.lod_count
	var lod_outer := _lod_outer
	# 加载半径 = view_distance（LOD0 数据需要半径）；卸载半径 = unload_distance（保留半径）
	var load_d := kernel.view_distance
	var unload_d := unload_d()
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, chunk_size_world, world_offset)

	# 程序化无限世界：origin shift（相机 chunk 距基准超阈值 → 平移数据 + 渲染 + 相机）
	if data.infinite:
		check_origin_shift(cam)

	# 1) 回填后台异步结果（生成器产出 / 流里直读），poll → 回填一步到位（数据层封装）
	# 限量 = 加载预算的 2 倍：避免来回移动时每帧回填过多（主线程写入 + 失效开销大 → 掉帧）
	# lod=0 的在途登记由 VoxelAsyncLoader 在回填时自动清除，此处无需本地清理
	var applied := data.apply_ready_results(maxi(load_per_frame * 2, 32))

	# 2) 距离内扫描缺失 chunk 并提交（限量每帧；降频扫描，相机不动时结果不变）
	_streaming_check_tick += 1
	# 相机移动：用更快的扫描间隔（interval/2，默认 4 帧）而非每帧全量扫描——
	# 保证移动响应及时，同时避免连续移动时每帧全量遍历拖慢帧率
	var cam_moved := cam_pos != _last_streaming_cam_pos
	if cam_moved:
		_last_streaming_cam_pos = cam_pos
		if _streaming_check_tick >= maxi(check_interval >> 1, 1):
			_streaming_check_tick = 0
	var submitted := 0
	# 相机移动中 → 提高本帧加载吞吐（移动时更快补建，减少前方空白）
	var load_budget := load_per_frame
	if cam_moved:
		load_budget = load_per_frame * 2
	if _streaming_check_tick % check_interval == 0:
		var r := ceili(load_d / chunk_size_world) + 1
		var yspan := data.get_vertical_half_span()
		var exhausted := false
		for dz in range(-r, r + 1):
			if exhausted:
				break
			for dy in range(-yspan, yspan + 1):
				if exhausted:
					break
				for dx in range(-r, r + 1):
					if submitted >= load_budget:
						exhausted = true
						break
					var ck := cam_ck + Vector3i(dx, dy, dz)
					# 【统一距离→LOD 决策】近处（LOD0 带）加载全精度 chunk 数据；
					# 远处（粗层带）跳过——LOD0 chunk 不加载，粗层 block 数据由 _process_lod_level
					# 按带请求独立数据（生成器 _generate_chunk_lod 直接生成，省内存 / 生成量）。
					if VoxelLodGrid.chunk_render_level(ck, cam_pos, world_offset, voxel_scale, lod_outer, lod_count) > 0:
						continue
					# 存在性统一判定（廉价，无 IO）：流里已存 或 本层造得出。
					# 两个抽象各表达一个含义，不再靠类型分支猜（见 QVoxelSource.can_supply_chunk）。
					if not data.can_supply_chunk(ck):
						continue
					if data.is_chunk_loaded(ck):
						continue
					if data.is_chunk_pending(ck, 0):
						continue
					if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > load_d:
						continue
					# 无限世界里已存过的 chunk（= 用户改过）：重新生成会覆盖修改 → 同步预载已存数据
					if data.infinite and data.is_stored(ck):
						if data.preload_chunk(ck):
							# 只登记给"会消费它的可见性模式"：该表的唯一消费 / 擦除点是
							# filter_visible_chunks，而它在 FULL 下直接全量返回（早退）——
							# FULL 下登记进去就是永久泄漏（只增不减，直到 origin shift / 退出）。
							if kernel.visibility_mode != VoxelRenderer.VisibilityMode.FULL:
								_stream_force_build[ck] = true
							data.mark_chunk_dirty(ck)
							submitted += 1
						continue
					# 未修改（程序化可重生成）或文件流（磁盘读）：统一异步请求。
					# 在途登记由 VoxelAsyncLoader 自己完成，此处不再另记一份（账本唯一）。
					data.request_chunk_async(ck, 0)
					submitted += 1

	# 3) 卸载超范围网格 + LOD0 数据 + 粗层数据块（未修改的粗层可重算直接丢，修改过的写盘）。
	#    LOD0 数据卸载是"无限世界能长期跑下去"的前提：否则 _chunk_buffers 会随走过的区域无界增长。
	#    但卸载半径要比网格卸载半径外扩"最粗层 block 的覆盖范围"——粗层降采样要读它覆盖的
	#    LOD0 chunk，卸早了降采样会读到假空块（见 lod0_data_unload_d）。
	if _streaming_check_tick % STREAM_UNLOAD_INTERVAL == 0:
		var coarse_level := maxi(lod_count - 1, 1)
		var block_edge_world := VoxelLodGrid.block_edge_world(coarse_level, voxel_scale)
		var unload_margin := VoxelLodGrid.margin(coarse_level, voxel_scale)
		var unload_block_extent := block_edge_world * 0.5
		var candidates: Array = []
		for ck in data.get_loaded_chunk_keys():
			var bk := VoxelLodGrid.block_of_chunk(ck, coarse_level)
			if VoxelLodGrid.block_dist(bk, coarse_level, cam_pos, world_offset, voxel_scale) <= unload_d + unload_margin + unload_block_extent:
				continue
			var dist: float = VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)
			if dist > unload_d:
				candidates.append([dist, ck])
		# 从远到近（距离降序）：最远的先卸载
		candidates.sort_custom(func(a, b): return a[0] > b[0])
		var unloaded := 0
		for item in candidates:
			if unloaded >= unload_per_frame:
				break
			kernel.remove_chunk_mesh(item[1])
			unloaded += 1
		# 3b) LOD0 数据卸载：网格卸载后，超外扩半径的 chunk 数据交还数据层
		#     （修改过的写盘、变空的清盘、未修改且流里已有的直接丢弃）。
		#     只在网格已卸掉时卸数据，避免"有网格没数据"的错配。
		var data_unload_d := lod0_data_unload_d()
		var data_unloaded := 0
		for item in candidates:
			if data_unloaded >= unload_per_frame:
				break
			var ck_d: Vector3i = item[1]
			if kernel.has_chunk_mesh(ck_d):
				continue
			if VoxelWorldUtil.chunk_center_dist(ck_d, cam_pos, chunk_size_world, world_offset) <= data_unload_d:
				continue
			if data.unload_chunk(ck_d):
				data_unloaded += 1
		# 取消超范围仍未完成的异步请求：编排器撤销登记后晚到的结果会被直接丢弃
		# （旧实现只删本地标记，结果回来仍可能被 accept → 卸载后数据"复活"）
		for ck_p in data.get_unready_chunk_keys(0):
			if VoxelWorldUtil.chunk_center_dist(ck_p, cam_pos, chunk_size_world, world_offset) > unload_d:
				data.cancel_chunk_request(ck_p, 0)
		# 清理超范围的粗 LOD 独立数据块（未修改可重新生成，修改的写盘）
		for lev in range(1, lod_level_count()):
			var edge_w := VoxelLodGrid.block_edge_world(lev, voxel_scale)
			for bk in data.get_lod_block_keys(lev):
				if VoxelLodGrid.block_dist(bk, lev, cam_pos, world_offset, voxel_scale) > unload_d + edge_w * 0.5:
					if data.is_lod_block_modified(lev, bk):
						data.flush_lod_block(lev, bk)
					else:
						data.erase_lod_block(lev, bk)

	if applied > 0 or submitted > 0:
		kernel.request_update()


# ── LOD 分带调度────────────────────────────────────────
# 各层严格在自身 band 内生成/保留：level 0 = 全精度 chunk 网格；level >=1 = 粗层 block
# （覆盖 32×2^level 体素），band = (inner-margin, upper]（最粗层延伸至 unload），
# 避免多层重叠 z-fight。粗层 mesh 由工作线程构建，本层只做派发与帧尾限量挂载；
# 网格节点的创建 / 释放 / 查询全在内核（见类注释"为什么网格账本留在内核"）。

## 各层 LOD 外半径（分带表）。内核 / demo / 测试需要分带时都走这里。
func lod_outer() -> Array[float]:
	return _lod_outer


## LOD 层数（含 LOD0）。权威长度在内核网格账本，本层 4 张平行表由 configure_lod 与之对齐。
func lod_level_count() -> int:
	return kernel.lod_level_count() if kernel != null else 0


## 重算分带并同步各层容器长度（lod_count / view_distance 变化时由内核 _configure_lod 调用）。
## 【为什么长度维护收在这里】4 张调度表归本层、`_lod_meshes` 归内核，两边各自 resize 迟早
## 悄悄错位；统一由本方法驱动，内核的 set_lod_level_count 只做被动的长度对齐。
func configure_lod(count: int, view_distance: float) -> void:
	_lod_outer = VoxelLodGrid.bands(view_distance, count)
	var n := maxi(count, 1)
	while _lod_pending_tasks.size() > n:
		_lod_pending_tasks.pop_back()
		_lod_rebuild.pop_back()
		_lod_null_retries.pop_back()
		_lod_block_gen.pop_back()
	while _lod_pending_tasks.size() < n:
		_lod_pending_tasks.append({})
		_lod_rebuild.append({})
		_lod_null_retries.append({})
		_lod_block_gen.append({})
	# 被裁层的在途 worker 结果回来时 level 已越界 → _on_lod_thread_result 早退丢弃。
	kernel.set_lod_level_count(n)


## 清空全部粗层调度账本（数据 / 缩放 / 层数变化导致所有网格作废时，随内核 _clear_lod_meshes 调用）。
## 网格节点由内核自己释放，本层只清自己的表 + 延迟队列 + 挂载队列。
func clear_lod_state() -> void:
	clear_deferred()
	for lv in _lod_pending_tasks.size():
		_lod_pending_tasks[lv].clear()
	for lv in _lod_rebuild.size():
		_lod_rebuild[lv].clear()
	for lv in _lod_null_retries.size():
		_lod_null_retries[lv].clear()
	for lv in _lod_block_gen.size():
		_lod_block_gen[lv].clear()
	_lod_mesh_apply_queue.clear()
	_lod_mesh_apply_scheduled = false


## 退出：置停止标记并等待所有粗层 worker 结束。必须在内核释放节点前调用——
## worker 完成时 call_deferred 会打到已释放实例。
func abort() -> void:
	_exiting = true
	trim_tasks(true)


## 限制粗层任务 ID 集合大小：任务完成后 ID 无回调可移除，长期运行会无限累积。
## 定期 wait 最旧的一批（已完成的任务立即返回，在跑的最多阻塞其完成时间），
## 保证集合维持在 COARSE_TASK_ID_BUDGET 内（内存小 + 退出 wait 不卡）。
func trim_tasks(all: bool = false) -> void:
	var budget := 0 if all else COARSE_TASK_ID_BUDGET
	if _coarse_task_ids.size() <= budget:
		return
	var n_remove := _coarse_task_ids.size() - budget
	for i in range(n_remove):
		WorkerThreadPool.wait_for_task_completion(_coarse_task_ids[i])
	if budget == 0:
		_coarse_task_ids.clear()
	else:
		_coarse_task_ids = _coarse_task_ids.slice(n_remove)


## LOD 调度入口（内核 _process 每帧调用；降频与失效直通在本方法内判定）。
## 降频：每 visibility_check_interval 帧跑一次；数据失效（破坏/编辑）时立即跑，
## 不等降频周期 → 破坏重建更及时。
## 【为什么 lod_count=1 也必须跑】LOD0 chunk mesh 的补建只在这里，跳过则画面空白。
func process_lod() -> void:
	if kernel == null:
		return
	var data := kernel.data
	_cull_check_counter += 1
	if data == null:
		return
	if _cull_check_counter < kernel.visibility_check_interval and not data.has_lod_invalidated():
		return
	_cull_check_counter = 0
	if not kernel.is_inside_tree():
		return
	var cam := kernel.current_camera()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var world_offset := kernel.global_position
	var unload_d := unload_d()
	var n_levels := maxi(kernel.lod_count, 1)
	# 内存 chunk 键快照：多步骤同帧复用（一次分配），并在同一趟里算出数据范围
	var loaded_chunks := data.get_loaded_chunk_keys()
	var cam_dir: Vector3 = -cam.global_transform.basis.z
	# 数据 chunk 范围（needed 枚举剪枝）：只枚举数据实际占用的 x/y/z 层，
	# 跳过空气层/模型外空 block 的降采样派发（lod_count>1 帧率骤降的主因）。
	# 与上面的键快照合并为一趟——此前是"再取一次 get_loaded_chunk_keys() 再全量遍历一次"，
	# 数千 chunk 时每帧白付一次数组分配 + 一次遍历。
	if not loaded_chunks.is_empty():
		var _bmin: Vector3i = loaded_chunks[0]
		var _bmax: Vector3i = loaded_chunks[0]
		for ck in loaded_chunks:
			_bmin = Vector3i(mini(_bmin.x, ck.x), mini(_bmin.y, ck.y), mini(_bmin.z, ck.z))
			_bmax = Vector3i(maxi(_bmax.x, ck.x), maxi(_bmax.y, ck.y), maxi(_bmax.z, ck.z))
		_data_chunk_min = _bmin
		_data_chunk_max = _bmax

	# 0. 数据变化 → 各粗层 block 失效重建（编辑/破坏触发）。
	#    不立即移除旧 mesh（防重建期间可见性振荡 → 闪烁）：标记重建并立即派发降采样，
	#    新 mesh 就绪后复用节点替换（内带区 mesh 应用由 _should_apply 丢弃，但数据仍同步更新）。
	for level in range(1, n_levels):
		var invalidated := data.get_invalidated_lod(level)
		if invalidated.is_empty():
			continue
		_ensure_levels(level)
		# 不再"任一失效就 _lod_generation_id[level] += 1"（会把该层所有在途任务作废重派，
		# 连续破坏时反复丢弃/重派 → 空转洪峰）。改为失效 block 各自递增 block 级代次。
		kernel.lod_materials(level, true)
		for bk in invalidated:
			_lod_block_gen[level][bk] = _lod_block_gen[level].get(bk, 0) + 1
			_lod_rebuild[level][bk] = true
			_lod_pending_tasks[level].erase(bk)
			# 内带（LOD0 显示区）：mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被丢弃——
			# 只降采样同步数据（拆两阶段，避免内带生成完整粗层 mesh 的 worker 浪费）；
			# 粗层带：完整重建（数据 + mesh 替换反映破坏）。
			# 超出本层显示带+margin 的失效 block：延迟重建（数据已失效擦除缓存，
			# 等相机进入该层带时由 _process_lod_level 补建），避免远层破坏白占重建预算。
			var bdist := _block_dist(bk, level, cam_pos)
			var _inner := _lod_outer[level - 1] if level > 0 else 0.0
			var _margin := _lod_margin(level)
			if bdist > _lod_outer[level] + _margin + _lod_preload_extent(level):
				# 超出预生成范围：数据与渲染侧状态一并清掉（否则该 block 的账本条目永久残留）
				data.erase_lod_block(level, bk)
				remove_lod_block(level, bk)
				continue
			# 【金字塔增量】coarse 已有缓存：数据层 patch 只重算脏大格（未脏复用），
			# 再派发 mesh worker 从 coarse 生成（set_lod_block 已清 modified → 不走全量降采样）。
			# L1 从 L0 chunk 降采样；L2+ 逐级上推从上一层 coarse 降采样（省 64 倍 L0 读取）。
			# 源缓冲是数据层内部存储，故"取源 → 重算 → 写回"收在 data.patch_lod_block 里。
			if data.patch_lod_block(level, bk):
				if bdist >= _inner - _margin:
					_build_lod_block(level, bk)
				continue
			if bdist < _inner - _margin:
				_build_lod_data_only(level, bk)
			else:
				_build_lod_block(level, bk)

	# 1. 各层：移除超出区间 / 生成带内缺失 / 可见性兜底（跨层共享构建预算）
	_lod_build_this_frame = 0
	_lod_submit_this_frame = 0
	# 程序化生成：粗层独立数据生成较慢（噪声），收紧每帧粗层 request 预算，
	# 让出 WorkerThreadPool 给 LOD0 chunk 生成（切换后快速看到地形，粗层随后补充）。
	var submit_budget: int = kernel._lod_submit_per_frame
	if data.infinite:
		submit_budget = 40
	# 每层独立构建预算 = 总数均分（保证近层建完前更粗层也能推进，不被近层 in-flight
	# 队列饿死——否则 LOD1 海量候选每帧占满共享配额，LOD2 永远 0 个 → 远处空洞）。
	var per_level_build := maxi(kernel._lod_build_per_frame / maxi(n_levels, 1), 4)
	for level in range(n_levels):
		_process_lod_level(level, cam, cam_pos, cam_dir, unload_d, world_offset, loaded_chunks, submit_budget, per_level_build)
	# 清理已完成粗层任务的 ID 累积（防 _coarse_task_ids 无限增长）
	trim_tasks()


## 兜底补层：正常路径由 configure_lod 统一维护 4 张表的长度，此处仅防
## "配置尚未跑就有失效块"导致的越界（内核 _ready 前不可能进本方法，纯防御）。
func _ensure_levels(level: int) -> void:
	while _lod_pending_tasks.size() <= level:
		_lod_pending_tasks.append({})
		_lod_rebuild.append({})
		_lod_null_retries.append({})
		_lod_block_gen.append({})


## 单个 LOD 层级管理：按 level 参数自动分流——
##   level 0 = 全精度 chunk 网格（移除超出 LOD0 带、补建带内缺失）
##   level >=1 = 粗层 block（覆盖 32×2^level 体素），每层严格在自身 band
##   （inner-margin, upper] 内生成/保留（最粗层延伸至 unload），避免多层重叠 z-fight。
func _process_lod_level(level: int, cam: Camera3D, cam_pos: Vector3, cam_dir: Vector3, unload_d: float, world_offset: Vector3, loaded_chunks: Array, submit_budget: int, build_quota: int) -> void:
	var data := kernel.data
	if level == 0:
		_process_chunk_level(loaded_chunks, cam, cam_pos, world_offset, unload_d)
		return
	if level >= lod_level_count():
		return
	var inner := _lod_outer[level - 1]
	var outer := _lod_outer[level]
	var edge_world := _lod_block_edge_world(level)
	var margin := _lod_margin(level)
	var is_coarsest := level >= lod_level_count() - 1
	# 本层生成/保留上界：非最粗层 = outer+margin（之外由更粗层覆盖）；最粗层 = unload+half-edge
	var upper := (unload_d + edge_world * 0.5) if is_coarsest else (outer + margin)
	# 1a. 推导需要：按本层 band 直接枚举 block（Voxel Tools 式——粗层数据独立，无需从 LOD0 chunk 推导）
	#   needed 存 block 中心距离（float），1c 复用，避免同一 block 重复算 distance_to。
	#   预生成提前量：生成范围向外扩 _lod_preload_extent，让粗层 block 在进入带前就生成好——
	#   相机跨带时新层级已就绪，消除"旧层移除/新层异步生成"的真空窗口（移动中闪现空洞）。
	var preload_d := _lod_preload_extent(level)
	var needed := {}
	var r_bk := ceili((outer + margin + preload_d) / edge_world) + 1
	var cam_bk := VoxelLodGrid.block_of_chunk(
		VoxelWorldUtil.chunk_from_world(cam_pos, kernel.voxel_scale * VoxelChunk.CHUNK_SIZE, world_offset), level)
	# 三维剪枝：只枚举数据实际占用的 block 范围（球体全高大部分是空气层/模型外空区，
	# 空 block 降采样空还反复派发 → worker 满载 → lod_count>1 帧率骤降）。
	var dx_lo: int = -r_bk
	var dx_hi: int = r_bk
	var dy_lo: int = -r_bk
	var dy_hi: int = r_bk
	var dz_lo: int = -r_bk
	var dz_hi: int = r_bk
	dx_lo = maxi(dx_lo, (_data_chunk_min.x >> level) - cam_bk.x)
	dx_hi = mini(dx_hi, (_data_chunk_max.x >> level) - cam_bk.x)
	dy_lo = maxi(dy_lo, (_data_chunk_min.y >> level) - cam_bk.y)
	dy_hi = mini(dy_hi, (_data_chunk_max.y >> level) - cam_bk.y)
	dz_lo = maxi(dz_lo, (_data_chunk_min.z >> level) - cam_bk.z)
	dz_hi = mini(dz_hi, (_data_chunk_max.z >> level) - cam_bk.z)
	# 平方距离判定（避免 distance_to 的 sqrt）。先用整数 block 距离做球内预筛，
	# 大幅减少候选（立方体角部 block 直接跳过，大半径时省一半以上循环），
	# 通过时再算一次实际欧氏距离缓存，供 1c 精确判定 / 排序复用。
	var radius := outer + margin + preload_d
	var radius_sq := radius * radius
	var r_blocks := ceili(radius / edge_world) + 2
	var r2 := r_blocks * r_blocks
	for dz in range(dz_lo, dz_hi + 1):
		var dzz := dz * dz
		for dy in range(dy_lo, dy_hi + 1):
			var dyz := dzz + dy * dy
			if dyz > r2:
				continue
			for dx in range(dx_lo, dx_hi + 1):
				if dyz + dx * dx > r2:
					continue
				var bk := cam_bk + Vector3i(dx, dy, dz)
				var to_cam := VoxelLodGrid.block_center(bk, world_offset, edge_world) - cam_pos
				var dsq := to_cam.length_squared()
				if dsq <= radius_sq:
					needed[bk] = sqrt(dsq)
	# 1b. 移除超出区间的：>unload 卸载；<inner-margin 进入内层带（内层就绪才移除）；
	#     >upper 进入更粗层带（更粗层就绪才移除，否则保留兜底防空洞）。
	#     预生成范围（<= upper+preload_d）内的 block 即使更粗层就绪也保留——
	#     它们作为预加载常驻（1d 隐藏），进入带内时直接显示，消除切换真空。
	var remove_keys: Array = []
	for bk in kernel.lod_mesh_keys(level):
		var dist := _block_dist(bk, level, cam_pos)
		if dist > unload_d + edge_world * 0.5:
			remove_keys.append(bk)
		elif dist < inner - margin and _level_finer_ready(level, bk, cam):
			remove_keys.append(bk)
		elif dist > upper + preload_d and kernel.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			remove_keys.append(bk)
	for bk in remove_keys:
		remove_lod_block(level, bk)
	# 1c. 带内缺失：数据未就绪 → 请求独立数据（生成器 _generate_chunk_lod）；就绪 → 派发 mesh
	var to_build: Array = []
	for bk in needed:
		if kernel.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
			# 空标记（null mesh）但粗层数据已就绪 → 重建 mesh（数据生成晚于首次 mesh 尝试——
			# 否则粗层一直空标记，LOD0 移除后出现过渡空洞）。
			if kernel.lod_mesh(level, bk) != null or not data.has_lod_block(level, bk):
				continue
		var dist: float = needed[bk]
		# 近处（LOD0 带内，dist<inner-margin）的 block 由 LOD0 chunk 显示，不生成 L1 mesh——
		# 否则与 1b 移除（近处内层就绪→移除 L1）形成"生成→移除→再生成"循环 → L0/L1 交替闪烁。
		# 带内及带外预生成范围（upper+preload_d 内）正常生成：进入带前就绪，消除切换真空。
		if dist < inner - margin or (not data.has_lod_block(level, bk) and dist > upper + preload_d):
			continue
		# 修改过的 block 由降采样回退（_build_lod_block 处理，数据来自 LOD0）；未修改优先独立数据。
		# 流若无粗层独立数据能力（程序化流会生成；文件流/自定义流仅实现 lod=0 → request 无效果）：
		# request 后 is_chunk_pending 仍 false → 走 to_build 由 _build_lod_block 降采样回退（保证任意流都出 LOD）。
		if not data.is_lod_block_modified(level, bk) and not data.has_lod_block(level, bk):
			# 文件流：直接降采样生成（一次完成——mesh + 数据缓存同步），不等异步 request 两阶段。
			# 异步降采样（request → 数据 → 下次帧 mesh）完成时机晚，近处粗层块长期无 mesh → 固定空洞。
			if data.stream != null and data.stream.supports_lod_layer():
				to_build.append([dist, bk])
				continue
			var _pending := data.is_chunk_pending(bk, level)
			if not _pending and _lod_submit_this_frame < submit_budget:
				_lod_submit_this_frame += 1
				data.request_chunk_async(bk, level)
				_pending = data.is_chunk_pending(bk, level)
				if not _pending:
					_lod_submit_this_frame -= 1  # 流无粗层能力，request 无效果 → 回滚预算
			if _pending:
				continue  # 独立数据生成中（程序化流），等待回填
			# 无粗层独立数据能力 → 降采样（_build_lod_block 快照空时回退降采样）
		# 装饰排序：优先级在这里算一次并随元素携带，比较器只比数值
		to_build.append([_lod_load_priority(bk, level, cam_pos, cam_dir), bk])
	# 按加载优先级排序（元素首项已算好）。
	# 不再需要"先按距离粗排 + 截断候选"那套技巧——它存在只是因为旧比较器每次比较都要重算
	# 两次 _lod_load_priority（数百 block ≈ 数千次方法调用 + 三角运算，每层每帧一次）。
	to_build.sort_custom(func(a, b): return a[0] < b[0])
	if not to_build.is_empty():
		kernel.lod_materials(level, true)
	# 每层构建数独立计数（上限 build_quota），互不抢占——近层在途任务多时
	# 不拖垮更粗层（否则 LOD1 海量 in-flight 占满共享配额 → LOD2 饿死 → 远处空洞）。
	# 只在真正派发（_build_lod_block 返回 true）时计数：已 pending 的跳过调用不再耗配额。
	var _built_this := 0
	for item in to_build:
		if _built_this >= build_quota:
			break
		if _build_lod_block(level, item[1]):
			_built_this += 1
	# 1d. 可见性兜底：进入内层带且内层未就绪 → 本层显示（防切换空洞）；
	#     超出本层带且更粗层已就绪 → 隐藏本层（防远处多层重叠 z-fight）
	for bk in kernel.lod_mesh_keys(level):
		var mi: MeshInstance3D = kernel.lod_mesh(level, bk)
		if mi == null:
			continue  # 空大块（无体素）
		# 失效重建中：冻结可见性——破坏瞬间不因重建切换 LOD 层级（避免"不同层级闪烁"），
		# 新 mesh 就绪替换并清除重建标记后，下一帧按当前状态恢复正常可见性判定。
		if _lod_rebuilding(level, bk):
			continue
		var dist := _block_dist(bk, level, cam_pos)
		if dist < inner + margin:
			mi.visible = not _level_finer_ready(level, bk, cam)
		elif dist > outer + margin and kernel.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			mi.visible = false
		else:
			mi.visible = true


## LOD0（chunk 层）网格管理：移除超出 LOD0 带的（粗层已就绪），补建带内缺失
func _process_chunk_level(loaded_chunks: Array, cam: Camera3D, cam_pos: Vector3, world_offset: Vector3, unload_d: float) -> void:
	var data := kernel.data
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	# 移除超出 LOD0 带的 chunk 网格：
	#   - 对应粗层已就绪 → 移除（避免"先细后粗"残留）
	#   - 超出最粗层覆盖带（block 中心 > outer[coarsest]+margin）→ 直接移除
	#     （该区域超出可视范围，粗层不再覆盖；视锥外空洞不可见，安全）
	var remove_lod0: Array = []
	var coarsest := maxi(kernel.lod_count, 1) - 1
	for ck in kernel.lod_mesh_keys(0):
		# 移除阈值统一用 lod0_d + margin（与下方补建阈值一致），消除 (lod0_d, lod0_d+margin]
		# 重叠区间——否则该区间内 chunk 每帧"移除→补建"来回抖动，_level_finer_ready
		# 随之在就绪/未就绪间跳变，LOD1 块可见性闪烁（lod_count=2 严重）。
		if _block_dist(ck, 0, cam_pos) <= lod0_d + lod0_margin:
			continue  # 仍在 LOD0 带（含滞回 margin），保留
		var level := _chunk_render_level(ck, cam_pos)
		if level > 0:
			var bk := VoxelLodGrid.block_of_chunk(ck, level)
			# 粗层 mesh 已实际就绪（非空标记）才移除 LOD0：空标记（null）表示粗层数据未就绪/生成晚，
			# 此时保留 LOD0 兜底显示，避免移动时 LOD0/LOD1 边界出现过渡空洞。
			var coarse_mesh: MeshInstance3D = kernel.lod_mesh(level, bk)
			if coarse_mesh != null or _block_dist(bk, level, cam_pos) > _lod_outer[level] + _lod_margin(level):
				remove_lod0.append(ck)
		else:
			# lod_count=1 无更粗层 → 超出 LOD0 显示区直接移除，否则残留旧网格
			remove_lod0.append(ck)
	for ck in remove_lod0:
		kernel.remove_chunk_mesh(ck)
	# 补建视锥内 LOD0 区未建的 chunk（相机移动不产生 dirty，需主动补建）
	var need_lod0_update := false
	if cam != null:
		var _chunk_world := kernel.voxel_scale * VoxelChunk.CHUNK_SIZE
		var _r_ck := ceili((lod0_d + lod0_margin) / _chunk_world) + 1
		var _cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, _chunk_world, world_offset)
		if loaded_chunks.is_empty():
			# 移动后新区域：loaded_chunks 为空（LOD0 数据未加载）→ 从相机位置推导补建。
			# 否则 LOD0 chunk 永不被 request/加载 → 近处 LOD0 空洞固定存在。
			for dx in range(-_r_ck, _r_ck + 1):
				for dy in range(-_r_ck, _r_ck + 1):
					for dz in range(-_r_ck, _r_ck + 1):
						var ck: Vector3i = _cam_ck + Vector3i(dx, dy, dz)
						if kernel.has_lod_mesh(0, ck):
							continue
						if _block_dist(ck, 0, cam_pos) > lod0_d + lod0_margin:
							continue
						# 该 cube 是以**相机**为心枚举的，与数据实际范围无关。有界程序化模型
						# （如 PCG 场景里 32³ 的单个模型）只有 1 个 chunk 在生成范围内，其余
						# 上万键都是"取不到数据"的幻影：若照标脏，它们会永久滞留
						# 数据层的脏 chunk 账（_update_mesh_async 超批次上限就把余量放回 dirty，
						# 每帧只消费固定个数）→ 每帧白转 2 万+ 键（实测 25 个渲染器 308ms/帧），
						# 且真正有几何的 chunk 淹没在幻影里永不建网格。用与 process_streaming
						# 同款的"存在性判定"（廉价无 IO）先剪枝。
						if not data.can_supply_chunk(ck):
							continue
						if not data.has_chunk(ck):
							data.request_chunk_async(ck, 0)  # LOD0 数据加载（文件流读盘/程序化生成）
						data.mark_chunk_dirty(ck)
						need_lod0_update = true
		else:
			for ck in loaded_chunks:
				if absi(ck.x - _cam_ck.x) > _r_ck or absi(ck.y - _cam_ck.y) > _r_ck or absi(ck.z - _cam_ck.z) > _r_ck:
					continue
				if kernel.has_lod_mesh(0, ck):
					continue
				var bdist := _block_dist(ck, 0, cam_pos)
				if bdist > lod0_d + lod0_margin:
					continue  # 粗 LOD 区
				# 粗层带（render_level>0）的 chunk 由对应粗层 block 覆盖，
				# 不标记 LOD0 dirty——否则补建→转交粗层→无 L0 mesh→再补建死循环，
				# 且 _level_finer_ready 会把它当"重建中就绪"→ L1 隐藏 → LOD0/LOD1 交界空洞。
				if _chunk_render_level(ck, cam_pos) > 0:
					continue
				data.mark_chunk_dirty(ck)
				need_lod0_update = true
	if need_lod0_update:
		kernel.request_update()


## 见 VoxelLodGrid.chunk_render_level
func _chunk_render_level(ck: Vector3i, cam_pos: Vector3) -> int:
	return VoxelLodGrid.chunk_render_level(ck, cam_pos, kernel.global_position, kernel.voxel_scale, _lod_outer, kernel.lod_count)


## 本层 block 的覆盖区域在内层（level-1）是否已全部就绪（有网格或为空）。
## level 1 的内层 = chunk（level 0）；仅统计视锥内的（视锥外不显示、无需网格不阻塞）。
func _level_finer_ready(level: int, bk: Vector3i, cam: Camera3D) -> bool:
	if level <= 0:
		return true
	var data := kernel.data
	var fine := level - 1
	for k in 2:
		for j in 2:
			for i in 2:
				var sbk := Vector3i(bk.x * 2 + i, bk.y * 2 + j, bk.z * 2 + k)
				# 内层就绪判定：LOD0 chunk 无空标记（有 mesh 即就绪）；
				# 粗层 block 的空标记（null，数据/网格未就绪）不算就绪 → 更粗层兜底显示，防过渡空洞。
				var fine_ready: bool = kernel.has_lod_mesh(fine, sbk) if fine == 0 else (kernel.lod_mesh(fine, sbk) != null)
				if fine_ready:
					continue
				if fine == 0:
					if data.has_chunk(sbk):
						# 重建中（mesh 在构建队列或数据层标脏）→ 仅当该 chunk 实际属于
						# LOD0 带（render_level==0，会被 L0 构建）才视为就绪：
						# 破坏瞬间内层未就绪会导致粗层临时替代（LOD 边界来回移动 → 闪烁）。
						# 而 LOD1 带的 chunk 由粗层覆盖、L0 永不构建，若当成就绪会让
						# _process_lod_level 隐藏粗层 → LOD0/LOD1 交界处背景透出空洞。
						if kernel.is_mesh_build_queued(sbk) or data.is_chunk_mesh_dirty(sbk):
							if _chunk_render_level(sbk, cam.global_position) == 0:
								continue
						var aabb := VoxelWorldUtil.chunk_world_aabb(
							sbk, kernel.voxel_scale * VoxelChunk.CHUNK_SIZE, kernel.global_position)
						if VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
							return false
				else:
					return false
	return true


## 该粗层 block 是否处于失效重建中（破坏/编辑触发，保留旧 mesh 等待新 mesh 替换）
func _lod_rebuilding(level: int, bk: Vector3i) -> bool:
	return level < _lod_rebuild.size() and _lod_rebuild[level].get(bk, false)


## LOD 生成优先级：距离 + 视线方向加权（前方 block 先生成）。返回值越小越优先。
func _lod_load_priority(bk: Vector3i, level: int, cam_pos: Vector3, cam_dir: Vector3) -> float:
	var center := VoxelLodGrid.block_center(bk, kernel.global_position, _lod_block_edge_world(level))
	var to_center := center - cam_pos
	var dist := to_center.length()
	if dist < 0.001:
		return 0.0
	var forward := to_center.normalized().dot(cam_dir)
	return dist - forward * dist * 0.5


## 派发粗 LOD 大块异步生成。**数据快照在主线程构造**后交给 worker（与 _build_lod_data_only 同一模式）：
##   · worker 只读快照，不触碰 QVoxelSource 的活动字典/缓冲 → 无跨线程读取（线程安全）；
##   · 数据来源由主线程判定：独立粗层大格数据自足则直接网格化，否则回退 LOD0 降采样。
## 返回是否真正派发（已 pending / 无效 level 时 false——调用方据此决定是否消耗构建预算）。
func _build_lod_block(level: int, bk: Vector3i) -> bool:
	var data := kernel.data
	if data == null:
		return false
	if level < 1 or level >= _lod_pending_tasks.size():
		return false
	if _lod_pending_tasks[level].has(bk):
		return false
	_lod_pending_tasks[level][bk] = true
	# 快照句柄随任务走到底、由 _on_lod_thread_result 释放：不依赖 LIFO 配对，
	# 故与渲染批次的快照并发时也不会互相释放错。
	var handle := data.begin_readonly_snapshot()
	var standalone: bool = data._can_mesh_lod_block_standalone(level, bk)
	var snapshot := data._snapshot_lod_block_data(bk, level) if standalone \
			else data._snapshot_lod_block_chunks_readonly(bk, level)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_build.bind(
		snapshot, standalone, bk, level, _lod_block_gen[level].get(bk, 0), kernel.voxel_scale,
		data.center_offset, kernel.lod_materials(level).duplicate(), handle)))
	return true


## 内带失效 block（LOD0 显示区）：只降采样同步粗层数据（粗层缓存 + 持久化）。
## mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被丢弃——拆分两阶段，避免内带生成完整粗层 mesh 的 worker 浪费。
func _build_lod_data_only(level: int, bk: Vector3i) -> void:
	var data := kernel.data
	if data == null:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	if _lod_pending_tasks[level].has(bk):
		return
	_lod_pending_tasks[level][bk] = true
	# 同上：句柄由 _on_lod_data_ready 释放。
	var handle := data.begin_readonly_snapshot()
	var snapshot := data._snapshot_lod_block_chunks(bk, level)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_data_only.bind(
		snapshot, bk, level, _lod_block_gen[level].get(bk, 0), handle)))


## 工作线程：粗 LOD 大块 mesh 生成。只读主线程构造好的数据快照（线程安全，不触碰 QVoxelSource）。
##   standalone=true：快照是独立粗层大格数据（直接拷大格，无降采样）；
##   false：快照是 LOD0 chunk 缓冲（降采样），顺带回传大格数据供粗层缓存复用。
func _lod_worker_build(snapshot: Dictionary, standalone: bool, bk: Vector3i, level: int,
		gen_id: int, scale: float, offset: Vector3, aligned_materials: Array,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	var halo: PackedInt32Array
	var buf := PackedInt32Array()
	if standalone:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(snapshot, bk)
	else:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_buffers(snapshot, bk, level)
		buf = VoxelChunk.extract_center_from_halo(halo)
	var arr := VoxelChunkGenerator.generate_lod_block_arrays(halo, aligned_materials, scale, bk, offset, level)
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
	call_deferred("_on_lod_thread_result", bk, level, mesh, gen_id, buf, handle)


## 工作线程：内带失效 block 只降采样大格数据（不生成 mesh——mesh 由 LOD0 chunk 反映）。
## 拆分两阶段：内带 block 的粗层 mesh 应用会被 _should_apply 丢弃，省去 arrays/mesh 构建。
func _lod_worker_data_only(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
	var buf := VoxelChunk.extract_center_from_halo(halo)
	call_deferred("_on_lod_data_ready", bk, level, gen_id, buf, handle)


## 取（必要时补建）某层的空结果重试计数表。与 _lod_rebuild / _lod_block_gen 的补层方式一致。
func _null_retry_layer(level: int) -> Dictionary:
	while _lod_null_retries.size() <= level:
		_lod_null_retries.append({})
	return _lod_null_retries[level]


## 清除某个 block 的空结果重试计数（带层级守卫，外部改层数时不越界）。
func _clear_null_retry(level: int, bk: Vector3i) -> void:
	if level < _lod_null_retries.size():
		_lod_null_retries[level].erase(bk)


## 主线程：内带失效 block 降采样数据同步（粗层缓存 + 持久化），mesh 由 LOD0 反映。
## 粗层降采样空的处理：确定空（block 覆盖的 L0 chunk 全不存在——区域外/空气层）
## → 一次设 null 防重复派发（否则空块反复降采样占满 worker，lod_count>1 帧率骤降）；
## 数据未就绪（L0 chunk 存在但降采样空）→ 重试计数，上限后设 null 防真空循环。
func _lod_mark_null_or_retry(level: int, bk: Vector3i) -> void:
	var data := kernel.data
	var definitely_empty := true
	var base := bk * (1 << level)
	var span := 1 << level
	for cz in span:
		for cy in span:
			for cx in span:
				var ck := base + Vector3i(cx, cy, cz)
				if data != null and data.is_chunk_loaded(ck):
					definitely_empty = false
					break
			if not definitely_empty:
				break
		if not definitely_empty:
			break
	if definitely_empty:
		# 区域外/空气层：无任何 L0 数据 → 确定空，一次设 null（不重试，省 worker）
		_clear_null_retry(level, bk)
		kernel.mark_lod_block_empty(level, bk)
		return
	var layer := _null_retry_layer(level)
	var _rn: int = layer.get(bk, 0)
	if _rn >= 3:
		layer.erase(bk)
		kernel.mark_lod_block_empty(level, bk)
	else:
		layer[bk] = _rn + 1


## 主线程：内带失效 block 的降采样数据回填（mesh 由 LOD0 chunk 反映，不挂载）。
func _on_lod_data_ready(bk: Vector3i, level: int, gen_id: int, buf: PackedInt32Array,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	# 释放本任务自己的快照句柄（必须在任何早退之前）
	handle.release()
	if _exiting:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	_lod_pending_tasks[level].erase(bk)
	if level >= _lod_block_gen.size() or gen_id != _lod_block_gen[level].get(bk, 0):
		return
	if buf.size() > 0 and kernel.data != null:
		kernel.data.store_lod_block(level, bk, buf)
	else:
		# 降采样空（LOD0 数据未就绪 或 区域外/空气层）：确定空一次设 null，其余重试计数
		_lod_mark_null_or_retry(level, bk)
	# 数据已同步（mesh 由 LOD0 chunk 反映），解除重建标记防重复派发
	if level < _lod_rebuild.size():
		_lod_rebuild[level].erase(bk)


## 主线程粗 LOD 结果处理：校验 gen_id，然后入队帧尾限量挂载。
## mesh 已在工作线程构建（ArrayMesh），此处仅轻量挂载——避免主线程同步构建大 mesh 卡顿。
## 降采样回退路径会顺带返回大格数据 buf，同步粗层缓存（+ 持久化），避免缓存缺口。
func _on_lod_thread_result(bk: Vector3i, level: int, mesh: ArrayMesh, gen_id: int,
		buf := PackedInt32Array(), handle: QVoxelSource.ReadonlySnapshot = null) -> void:
	# 释放本任务自己的快照句柄（必须在任何早退之前）
	if handle != null:
		handle.release()
	if _exiting:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	_lod_pending_tasks[level].erase(bk)
	if level >= _lod_block_gen.size() or gen_id != _lod_block_gen[level].get(bk, 0):
		return
	var data := kernel.data
	# 同步粗层缓存（降采样回退的数据与 mesh 一致，供后续复用/持久化）。
	# 仅 mesh 非空（有实际体素）才写缓存：真空 block 若写全 0 buffer，
	# has_lod_block=true → _process_lod_level 判"数据就绪但 mesh 空"→ 每帧重新派发
	# → 死循环占满跨层构建预算，更粗层永远分不到（远处空洞）。
	if buf.size() > 0 and data != null and mesh != null and mesh.get_surface_count() > 0:
		data.store_lod_block(level, bk, buf)
	if kernel.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
		return
	if mesh == null or mesh.get_surface_count() == 0:
		# 降采样结果为空：多为 LOD0 数据未就绪（快照空）→ 不设空标记，移除条目让后续重试。
		# 否则空标记会让 _process_lod_level 跳过该 block，LOD0 数据就绪后也不会重建 → 洞永远。
		# 真空 block 防循环：确定空（区域外/空气层）一次设 null，数据未就绪重试上限后设 null。
		if _lod_rebuilding(level, bk):
			remove_lod_block(level, bk)
		if level < _lod_rebuild.size():
			_lod_rebuild[level].erase(bk)
		_lod_mark_null_or_retry(level, bk)
		if kernel.has_lod_mesh(level, bk) and kernel.lod_mesh(level, bk) == null:
			return  # 已设真空标记 → 停止派发
		kernel.clear_lod_mesh(level, bk)  # 重试中 → 移除条目，下次 _process_lod_level 重新派发降采样
		return
	_lod_mesh_apply_queue.append([level, bk, mesh])


## 帧尾挂载排期：有排队结果且未排期时置位并返回 true（内核据此 call_deferred 转发）。
## 【为什么排期标记在本层、而 deferred 目标在内核节点】标记必须与队列同处一地才不会重复排期；
## 但 deferred 只能挂在 Node 上——节点被释放时引擎会自动丢弃排期，RefCounted 的本层没有这层保护。
func take_lod_mesh_flush_request() -> bool:
	if _lod_mesh_apply_queue.is_empty() or _lod_mesh_apply_scheduled:
		return false
	_lod_mesh_apply_scheduled = true
	return true


## 帧尾限量挂载粗 LOD 大块 mesh（GPU 上传摊平到多帧）。
## 复用 _lod_build_per_frame 数量 + 3ms 时间预算；已移出区间的结果丢弃。
func process_lod_mesh_apply_queue() -> void:
	_lod_mesh_apply_scheduled = false
	if _lod_mesh_apply_queue.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var built := 0
	var i := 0
	while i < _lod_mesh_apply_queue.size():
		if built >= kernel._lod_build_per_frame:
			break
		if (Time.get_ticks_usec() - t0) / 1000.0 > 3.0:
			break
		var item: Array = _lod_mesh_apply_queue[i]
		var level: int = item[0]
		var bk: Vector3i = item[1]
		var mesh: ArrayMesh = item[2]
		# 重新校验区间（结果排队期间相机可能移动）
		if _should_apply_lod_mesh(level, bk):
			kernel.mount_lod_mesh(level, bk, mesh)
			# 挂载成功：解除重建标记与空结果重试计数（新 mesh 已就位，旧状态作废）
			if level < _lod_rebuild.size():
				_lod_rebuild[level].erase(bk)
			_clear_null_retry(level, bk)
			built += 1
		elif level < _lod_rebuild.size() and _lod_rebuild[level].has(bk):
			# 内带丢弃（LOD0 区由 LOD0 chunk 反映洞）：数据已同步，解除重建标记防重复派发
			_lod_rebuild[level].erase(bk)
		_lod_mesh_apply_queue.remove_at(i)
	# 剩余留待下帧（内核 _process 每帧调度一次）。不能 call_deferred 自续：同帧 flush 内会
	# 反复进本函数直至清空，帧预算失效（同 _process_mesh_build_queue 的教训）。
	if kernel.diag_enabled and built > 0:
		print("[诊断] LOD大块挂载批处理: %d 个, 剩余%d" % [built, _lod_mesh_apply_queue.size()])


## 粗 LOD 大块是否仍在显示区间（挂载前校验，相机移动后过期结果丢弃）。
## 失效重建的 block：强制应用（替换旧 mesh 反映破坏）——近处内带由 _level_finer_ready
## （重建中视为就绪）隐藏本层，不产生 LOD 层级切换；远处粗层区替换后显示含洞网格。
func _should_apply_lod_mesh(level: int, bk: Vector3i) -> bool:
	if level < 1 or level >= lod_level_count():
		return false
	if kernel.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
		return false
	var cam := kernel.current_camera()
	if cam == null:
		return false
	var edge_world := _lod_block_edge_world(level)
	var dist := _block_dist(bk, level, cam.global_position)
	var unload_d := unload_d()
	var inner := _lod_outer[level - 1] if level > 0 else 0.0
	var margin := _lod_margin(level)
	if _lod_rebuilding(level, bk):
		# 失效重建的粗层 mesh：只在粗层带内替换（反映破坏）；
		# LOD0 区内带不替换（粗层隐藏、由 LOD0 chunk mesh 反映洞），
		# 避免"LOD0 细洞先出现 → 粗层粗洞后替换"的先后交替闪烁。
		return dist > inner - margin and dist <= unload_d + edge_world * 0.5
	# 粗层数据已就绪：内带也挂载（mesh 预生成——LOD0 移除后粗层直接显示，防块状空洞；
	# 可见性由 _process_lod_level 的 _level_finer_ready 控制——LOD0 就绪则隐藏本层，无重叠）
	if kernel.data != null and kernel.data.has_lod_block(level, bk):
		return dist <= unload_d + edge_world * 0.5
	return not (dist < inner - margin or dist > unload_d + edge_world * 0.5)


## 移除指定粗层的 block（网格节点由内核释放，本层只清自己的调度账本）。
## level 0（chunk）不走这里——LOD0 的移除是内核 remove_chunk_mesh，语义不同（含碰撞与延迟队列）。
func remove_lod_block(level: int, bk: Vector3i) -> void:
	kernel.clear_lod_mesh(level, bk)
	_clear_block_state(level, bk)


## 清除某层 block 的调度账本（待办 / 重建 / 代次 / 重试）。
## 单点维护：这些表都以 block key 为键，漏清一个就会随探索范围无界增长。
func _clear_block_state(level: int, bk: Vector3i) -> void:
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	_lod_pending_tasks[level].erase(bk)
	if level < _lod_rebuild.size():
		_lod_rebuild[level].erase(bk)
	if level < _lod_block_gen.size():
		_lod_block_gen[level].erase(bk)
	_clear_null_retry(level, bk)


## 见 VoxelLodGrid.block_dist（几何数学归 VoxelLodGrid，此处只补上本层持有的内核参数）
func _block_dist(bk: Vector3i, level: int, cam_pos: Vector3) -> float:
	return VoxelLodGrid.block_dist(bk, level, cam_pos, kernel.global_position, kernel.voxel_scale)


## 见 VoxelLodGrid.margin
func _lod_margin(level: int) -> float:
	return VoxelLodGrid.margin(level, kernel.voxel_scale)


## 见 VoxelLodGrid.block_edge_world
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, kernel.voxel_scale)


## 见 VoxelLodGrid.preload_extent（提前量旋钮仍是内核 @export，见类注释"配置仍挂在节点上"）
func _lod_preload_extent(level: int) -> float:
	return VoxelLodGrid.preload_extent(level, kernel.voxel_scale, kernel._lod_preload_blocks)
