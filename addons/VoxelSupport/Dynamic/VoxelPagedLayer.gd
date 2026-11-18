class_name VoxelPagedLayer
extends Node3D

## 视点分页层（视点调度）：视锥 / 距离过滤 + 延迟补建 + 流式加载卸载 + origin shift + LOD 分带。
## 这是 `VoxelInfiniteLayer` 的**继任者**，并存期两者互不接管（见 `enabled`）。
## 【为什么是 Node3D 子节点而不是 RefCounted】
##   · `@export` 只挂得住 Node / Resource：旋钮必须 Inspector 可调、能存进 .tscn（旧层把配置
##     反向留在宿主节点上，正是双向耦合的来源之一）；
##   · `_process` / deferred 由引擎托管：旧层"退出前等 worker、deferred 只能借宿主节点"
##     这类补丁都源于它没有自己的生命周期；删节点即停调度，无需 abort/clear_* 收尾。
## 【依赖方向】本组件 → renderer，单向，renderer 永不调用本组件：
##   · 读 `data` / `voxel_scale` / `global_position` / `current_camera()` / `is_inside_tree()`；
##   · 命令 `request_update` / `remove_chunk_mesh` / `has_chunk_mesh` / `lod_*` / `shift_render`；
##   · 数据层只用 `QVoxelSource` 公开方法。
##   **绝不读写 renderer 的 `_` 前缀成员**：旧层读 7 个私有 `@export` 是耦合症结，本组件把
##   那些旋钮收成自己的 `@export`，耦合面因此只剩公开方法；缺能力只记文件尾 TODO，不绕封装。
## 【并存期】`enabled` 默认 false（旧层仍由 renderer 的 `_process` 驱动，同时驱动会互抢账本）；
##   接管：`attach(renderer)` → `enable()`，并停用旧层。

# ── 配置（接管后旧宿主上的同名旋钮删除，避免第二套真值）────────────────────────

## 视点加载距离（世界单位）：LOD0 数据加载半径 / 网格过滤上界。
@export_range(0.0, 10000.0, 0.5) var view_distance: float = 40.0
## 网格卸载距离；0 或小于 view_distance 时回退 view_distance * 1.2（见 unload_d）。
@export_range(0.0, 10000.0, 0.5) var unload_distance: float = 0.0
## LOD 层数（含 LOD0）：1 = 仅全精度；分带由 VoxelLodGrid.bands 按 ×2 等比给出。
@export_range(1, 8, 1) var lod_count: int = 1
## 调度降频：每 N 个 tick 跑一轮（相机不动时扫描结果不变）。
@export_range(1, 120) var visibility_check_interval: int = 8
## 每轮最多提交多少个 chunk 数据请求。
@export_range(1, 400, 1) var _stream_load_per_frame: int = 32
## 每轮最多卸载多少个超范围 chunk（网格与数据各自计数）。
@export_range(1, 400, 1) var _stream_unload_per_frame: int = 24
## 每轮最多派发多少个粗层 block。
@export_range(1, 400, 1) var _lod_build_per_frame: int = 128
## 粗层预生成提前量（block 数）：跨带前备好，消除切换瞬间空白。
@export_range(0, 6, 1) var _lod_preload_blocks: int = 1
## 每轮跨层共享的后台数据生成提交预算（防单帧洪峰打爆 WorkerThreadPool）。
@export_range(1, 500, 1) var _lod_submit_per_frame: int = 200

# ── 状态（本组件自己的账本）──────────────────────────────────────────────────

## origin shift 阈值（chunk）：256 chunk ≈ 820 世界单位，远小于 float32 精度上限。
const ORIGIN_SHIFT_THRESHOLD := 256

## 宿主渲染器（只读公开面）。为 null 时全部方法安全空转。
var renderer: VoxelRenderer = null
## 调度开关（并存期默认关闭，避免与旧层同时改同一批账本）。
var enabled := false
## 最近一轮 LOD 分带统计（只读诊断：{level: {in_band, data_ready, missing, budget}}）。
var last_lod_band_stats: Dictionary = {}

## 延迟补建队列：视锥外被过滤掉的 chunk（chunk_key → true），进视锥 / 靠近后补建。
var _deferred_chunks: Dictionary = {}
## 强制构建标记：距离驱动的补建不被视锥剔除再次拦回延迟队列。
var _stream_force_build: Dictionary = {}
## 上次调度时的相机位置（不动 = 扫描结果不变；移动 = 提高加载吞吐）。
var _last_streaming_cam_pos := Vector3(INF, INF, INF)
## 扫描降频计数（相机不动时不必每轮枚举相机周围的 r³ 个 chunk）。
var _streaming_check_tick := 0
## 数据基准 chunk（origin shift 后）：相机 chunk 距它超阈值即平移。
var _origin_chunk: Vector3i = Vector3i.ZERO
## 各层外半径（世界单位），index 0 = LOD0 显示区外边界；由 _ensure_bands 重算。
var _lod_outer: Array[float] = []
## 分带表缓存参数（view_distance / lod_count 变了就重算）。
var _bands_view_distance := -1.0
var _bands_lod_count := -1
## 调度降频计数。
var _cull_check_counter := 0

## 宿主可见性模式缓存（FULL 下整层不裁剪）。
## 【为什么缓存而不是每次问 renderer】`filter_chunks` 每帧被脏列表调用，读一次成员比
## 走一次 getter 便宜；而且 FULL 判定必须在**过滤入口的第一行**就能短路，不能等进函数中段。
## 初值取 FRUSTUM 与宿主默认值一致；`enable()` 与宿主的 setter 会推最新值进来。
var _visibility_mode: int = 1   # VoxelRenderer.VisibilityMode.FRUSTUM

# ── LOD 粗层调度账本（从 VoxelInfiniteLayer 迁入）──────────────────────────────
# 分带 / 待办 / 重建 / 重试 / 代次五张表按 LOD 层级平行（index 0 = LOD0，占位不用）；
# 长度唯一维护点是 `_ensure_bands`。
#
# 各层已派发待结果的 block（去重）
var _lod_pending_tasks: Array[Dictionary] = []
## 失效重建标记：破坏/编辑后 block 数据变化，保留旧 mesh 直到新 mesh 就绪替换（防重建闪烁）
var _lod_rebuild: Array[Dictionary] = []
## 粗层降采样空结果重试计数（内层 = block key → n）。降采样空多为 LOD0 数据未就绪，
## 不设空标记（否则跳过导致洞永远），重试上限后设空标记防真空 block 循环。
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


func _ready() -> void:
	if renderer == null:
		# 约定：作为 VoxelRenderer 的子节点挂载时自动认父（也支持显式 attach）。
		renderer = get_parent() as VoxelRenderer
	set_process(enabled)


## 显式绑定宿主（接管时由装配方调用）。
## 【会顺手把宿主指向自己】这样装配方只需 `add_child(layer); layer.enable()` 两步，
## 不必再记得 `renderer.paged_layer = layer`——那个赋值漏了会表现为"组件跑了但渲染器
## 还在问旧层"，是典型的静默错配。
func attach(host: VoxelRenderer) -> void:
	renderer = host
	if host != null and host.paged_layer != self:
		host.paged_layer = self


## 开启 / 关闭调度（接管时由装配方调用）。
##
## 【为什么不自己 set_process(true)】接管的宿主是 `VoxelRenderer`，它的 `_process` 已经
## 在每帧显式调本组件的 `process_streaming` / `process_deferred_chunks` / `process_lod`。
## 若本组件的 `_process` 也跑一遍，同一轮调度会被驱动两次：
##   · `_cull_check_counter` 每帧 +2 → 实际调度间隔只有 `visibility_check_interval / 2`；
##   · 更糟的是两侧各自独立判断"该不该跑"，降频语义直接失效，LOD 派发变成双倍洪峰。
## 实测在 destruction_demo（181 chunk / lod_count=3）上把帧率从 51 打到 9。
## 故：**有宿主时由宿主驱动，本组件只做被动执行**；没有宿主（独立使用）才自驱动。
func enable() -> void:
	enabled = true
	if renderer == null:
		renderer = get_parent() as VoxelRenderer
	if renderer != null:
		renderer.paged_layer = self
		_sync_config_to_self_from_host()
		set_process(false)      # 宿主驱动（见上面注释）
		renderer.request_update()
	else:
		set_process(true)       # 独立使用：自己驱动


func disable() -> void:
	enabled = false
	set_process(false)
	if renderer != null and renderer.paged_layer == self:
		# 交还调度权给旧层：必须解除引用，否则 renderer 会继续"问本组件要可见性"
		# 而本组件已停止调度 → 脏列表被过滤成空，画面停止更新。
		renderer.paged_layer = null
		renderer.request_update()


## 从宿主拉取一次配置（老调用方只在宿主上设 view_distance / lod_count 等）。
## 【为什么是"拉"而不是让宿主"推"】宿主那套 @export 是历史存量，不能删（改了所有 demo
## 和场景都要动）；但接管后它们必须成为本组件的初值，否则用户设了 view_distance=200
## 而组件还是默认 40，表现为"接管后视野突然变小"。故 enable 时拉一次对齐。
func _sync_config_to_self_from_host() -> void:
	if renderer == null:
		return
	view_distance = renderer.view_distance
	unload_distance = renderer.unload_distance
	lod_count = maxi(renderer.lod_count, 1)
	visibility_check_interval = renderer.visibility_check_interval


## 宿主可见性模式变化时同步（FULL 下不裁剪）。
func on_visibility_mode_changed(mode: int) -> void:
	_visibility_mode = mode


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


## 清空全部粗层调度账本（数据 / 缩放 / 层数变化导致所有网格作废时调用）。
## 网格节点由 renderer 自己释放，本组件只清自己的表 + 延迟队列 + 挂载队列。
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


## 退出：置停止标记并等待所有粗层 worker 结束。必须在 renderer 释放节点前调用——
## worker 完成时 call_deferred 会打到已释放实例。
## 【为什么不再需要像旧层那样由 renderer 显式调】本组件是 Node，`_exit_tree` 时会自动调它，
## 不再依赖宿主记得清理（那正是旧 RefCounted 层需要 abort() 补丁的原因）。
func abort() -> void:
	_exiting = true
	trim_tasks(true)


func _exit_tree() -> void:
	abort()


## 同步相机缓存位置（origin shift 反向补偿相机后必须调用，否则下一轮读到一次伪"相机移动"）。
func sync_cam_pos(p: Vector3) -> void:
	_last_streaming_cam_pos = p


## 独立使用时的自驱动（有宿主时宿主每帧调三个 process_*，见 enable 注释）。
##
## 【降频放在各子步骤内部，不放在这里】`process_lod` 已自带 `_cull_check_counter`
## （与旧层同一套语义：每 `visibility_check_interval` 帧一次，数据失效时直通），
## `process_streaming` 自带 `_streaming_check_tick`。若这里再套一层降频，
## 两级乘起来等于"每 interval² 帧才跑一次"，LOD 与流式会慢到不可用（实测第一版就是这么错的）。
func _process(_delta: float) -> void:
	if not enabled or renderer == null:
		return
	if not _can_schedule() or renderer.current_camera() == null:
		return
	_ensure_bands()
	process_streaming()
	process_deferred_chunks()
	process_lod()


# ── 公开查询（渲染管线 / HUD / 其它组件只读）──────────────────────────────────

## 网格卸载半径：未显式设置时回退 view_distance * 1.2。惰性计算、不改字段，
## 让所有距离判定共用同一出处。
func unload_d() -> float:
	return unload_distance if unload_distance > view_distance else view_distance * 1.2


## LOD0 **数据**卸载半径：比网格卸载半径再外扩"最粗层 block 的覆盖范围"。
## 粗层降采样要读 block 覆盖的 2^level³ 个 LOD0 chunk（带光环），卸早了会读到假空块 → 空洞。
func lod0_data_unload_d() -> float:
	var coarse_level := maxi(lod_count - 1, 1)
	return unload_d() + 2.0 * VoxelLodGrid.block_edge_world(coarse_level, renderer.voxel_scale) \
			+ renderer.voxel_scale * VoxelChunk.CHUNK_SIZE


## 当前数据基准 chunk（origin shift 后）。供 HUD / 调试读取。
func origin_chunk() -> Vector3i:
	return _origin_chunk


## 各层外半径（分带表）。调用时保证与 view_distance / lod_count 同步。
func lod_outer() -> Array[float]:
	_ensure_bands()
	return _lod_outer


## LOD 层数（含 LOD0）：权威长度在 renderer 的网格账本，本组件不主动改它（见 TODO）。
func lod_level_count() -> int:
	return renderer.lod_level_count() if renderer != null else 0


## 世界坐标是否在当前相机视锥内（无相机 / 未入树时保守返回 true）。
## 供破坏 / 掉落体等"视锥外跳过昂贵效果"的组件复用。
func is_world_visible(world_pos: Vector3) -> bool:
	if renderer == null:
		return true
	var cam := renderer.current_camera()
	if cam == null:
		return true
	return cam.is_position_in_frustum(world_pos)


## 该 chunk 是否把重建权交给了延迟队列（渲染管线派发脏列表前可据此防抖）。
func is_deferred(ck: Vector3i) -> bool:
	return _deferred_chunks.has(ck)


func deferred_is_empty() -> bool:
	return _deferred_chunks.is_empty()


## 网格被 renderer 移除时同步：重建权随之作废，否则残留"幽灵补建"条目。
func on_mesh_removed(ck: Vector3i) -> void:
	_stream_force_build.erase(ck)
	_deferred_chunks.erase(ck)


## 清空延迟队列与强制标记（数据 / 缩放整体作废时随网格清理一起调用）。
func clear_deferred() -> void:
	_deferred_chunks.clear()
	_stream_force_build.clear()


# ── 能力 1：视锥 / 距离过滤 ──────────────────────────────────────────────────

## 判定哪些 chunk 该建网格：流式距离内 + 该由 LOD0 显示 + (近处全向 | 视锥内)。
## 视锥外但仍在范围内的进延迟队列，等走近 / 转向再补建。无相机 / 无数据时保守放行。
func filter_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	if renderer == null:
		return chunks
	# FULL 模式：用户明确要"全量"，任何裁剪都是错的（且 FULL 下延迟队列无意义）。
	# 旧层同样的判定在 filter_visible_chunks 第一行，这里必须等价。
	if _visibility_mode == VoxelRenderer.VisibilityMode.FULL:
		return chunks
	var data := renderer.data
	var cam := renderer.current_camera()
	if data == null or cam == null:
		return chunks
	_ensure_bands()
	var voxel_scale := renderer.voxel_scale
	var world_offset := renderer.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var n_levels := maxi(lod_count, 1)
	var lod0_d := _lod_outer[0]
	var lod0_margin := VoxelLodGrid.margin(0, voxel_scale)
	var unload_limit := unload_d()
	# 流式启用读数据层能力（renderer 的 visibility_mode 不在允许的公开面内）。
	var streaming := data.is_streaming()
	var visible: Array[Vector3i] = []
	for ck in chunks:
		# 无数据的空 chunk 不纳入网格管理（补建空 chunk 会形成死循环）
		if not data.has_chunk(ck):
			continue
		# 超卸载半径不建网格（数据由流式卸载回收，重进范围再按需加载）
		if streaming and unload_limit > 0.0:
			if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > unload_limit:
				continue
		# 超出 LOD0 带的 chunk 由对应粗层 block 覆盖，不建 LOD0 网格
		if VoxelLodGrid.chunk_render_level(
				ck, cam_pos, world_offset, voxel_scale, _lod_outer, n_levels) > 0:
			_stream_force_build.erase(ck)
			continue
		# 距离驱动的补建：无条件构建（清标记避免重复消费）
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		# 近处（LOD0 带 + 滞回）不视锥剔除：快速转向 / 后退时近处不出现空洞
		if VoxelLodGrid.block_dist(ck, 0, cam_pos, world_offset, voxel_scale) <= lod0_d + lod0_margin:
			visible.append(ck)
			continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


# ── 能力 2：延迟补建 ────────────────────────────────────────────────────────

## 消化延迟队列：进视锥（或已在 view_distance 内）的 chunk 标脏交给 renderer 重建。
## 每轮限量；【先收集后修改】迭代中增删 Dictionary 会漏元素。
func process_deferred_chunks() -> void:
	if not _can_schedule() or _deferred_chunks.is_empty():
		return
	var data := renderer.data
	var cam := renderer.current_camera()
	if data == null or cam == null:
		return
	var world_offset := renderer.global_position
	var chunk_size_world := renderer.voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var limit := _stream_load_per_frame
	var to_build: Array[Vector3i] = []
	var to_drop: Array[Vector3i] = []
	var scanned := 0
	for key in _deferred_chunks:
		scanned += 1
		if scanned > limit * 8 or to_build.size() >= limit:
			break
		var ck: Vector3i = key
		# 已有网格 / 已无数据：无需补建，直接移出队列
		if renderer.has_chunk_mesh(ck) or not data.has_chunk(ck):
			to_drop.append(ck)
			continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if not VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			if view_distance <= 0.0:
				continue
			if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > view_distance:
				continue
		to_drop.append(ck)
		to_build.append(ck)
	for ck in to_drop:
		_deferred_chunks.erase(ck)
	if to_build.is_empty():
		return
	for ck in to_build:
		# 强制标记：确保 renderer 的增量重建不会把该 chunk 再次拦回延迟队列
		_stream_force_build[ck] = true
		data.mark_chunk_dirty(ck)
	renderer.request_update()


# ── 能力 3：流式加载 / 卸载 ─────────────────────────────────────────────────

## 按相机距离管理 chunk 数据与网格：① 回填异步结果 → ② 距离内缺失 chunk 限量提交 →
## ③ 超范围网格与数据限量卸载、撤销超范围在途请求。
## 数据源差异（生成器 / 磁盘流）由数据层 can_supply_chunk 表达，本组件不做类型分支。
func process_streaming() -> void:
	if not _can_schedule():
		return
	var data := renderer.data
	if data == null or not data.is_streaming():
		return
	var cam := renderer.current_camera()
	if cam == null:
		return
	var voxel_scale := renderer.voxel_scale
	var world_offset := renderer.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	# 程序化无限世界先 origin shift（会平移数据 / 渲染账本 / 相机，之后必须重取相机位置）
	if data.infinite:
		check_origin_shift(cam)
	if view_distance <= 0.0:
		return
	var cam_pos := cam.global_position
	var unload_limit := unload_d()
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, chunk_size_world, world_offset)
	var n_levels := maxi(lod_count, 1)

	# 1) 回填后台异步结果。限量 = 加载预算 2 倍：来回移动时避免主线程写入尖峰。
	var applied := data.apply_ready_results(maxi(_stream_load_per_frame * 2, 32))

	# 2) 距离内扫描缺失 chunk 并提交（限量每轮；**降频扫描**，相机不动时结果不变）
	#
	# 【为什么降频在这里、不在 _process】有宿主时 `_process` 由宿主每帧调（它不做降频，
	# 见 enable 注释）。而"枚举相机周围 r³ 个 chunk"是 O(r³) 的，每帧全量跑在
	# view_distance 大 / 有竖直跨度时非常贵。故用与旧层同一套语义：
	#   · 相机移动 → 每 interval/2 帧扫一次（响应及时）
	#   · 相机不动 → 每 interval 帧扫一次（省 CPU）
	_streaming_check_tick += 1
	var cam_moved := cam_pos != _last_streaming_cam_pos
	if cam_moved:
		_last_streaming_cam_pos = cam_pos
		if _streaming_check_tick >= maxi(visibility_check_interval >> 1, 1):
			_streaming_check_tick = 0
	var load_budget := _stream_load_per_frame
	if cam_moved:
		load_budget *= 2
	if _streaming_check_tick % maxi(visibility_check_interval, 1) != 0:
		# 本轮不扫描：仍要往下走卸载段（卸载有自己的降频与限量）
		_apply_streaming_unload(cam_pos, unload_limit, cam_ck, chunk_size_world, world_offset)
		return
	var submitted := 0
	var r := ceili(view_distance / chunk_size_world) + 1
	var yspan := data.get_vertical_half_span()
	for dz in range(-r, r + 1):
		if submitted >= load_budget:
			break
		for dy in range(-yspan, yspan + 1):
			if submitted >= load_budget:
				break
			for dx in range(-r, r + 1):
				if submitted >= load_budget:
					break
				var ck: Vector3i = cam_ck + Vector3i(dx, dy, dz)
				# 粗层带不加载 LOD0 数据：由粗层 block 独立请求（见 process_lod / TODO）
				if VoxelLodGrid.chunk_render_level(
						ck, cam_pos, world_offset, voxel_scale, _lod_outer, n_levels) > 0:
					continue
				if not data.can_supply_chunk(ck):
					continue
				if data.is_chunk_loaded(ck) or data.is_chunk_pending(ck, 0):
					continue
				if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > view_distance:
					continue
				data.request_chunk_async(ck, 0)
				submitted += 1

	# 3) 卸载超范围（先网格、后数据，避免"有网格没数据"的错配，各自限量）
	_apply_streaming_unload(cam_pos, unload_limit, cam_ck, chunk_size_world, world_offset)
	if applied > 0 or submitted > 0:
		renderer.request_update()


## 卸载阶段的独立实现（被 process_streaming 与"本轮跳过扫描"分支共用）。
## 【为什么拆出来】扫描是 O(r³) 且要降频，卸载是 O(已加载 chunk 数) 且自带限量 ——
## 两者节奏不同。拆开后"本轮不扫描"时卸载仍然跑，不会让远处网格多留一整个降频周期。
func _apply_streaming_unload(cam_pos: Vector3, unload_limit: float, _cam_ck: Vector3i,
		chunk_size_world: float, world_offset: Vector3) -> void:
	var data := renderer.data
	if data == null:
		return
	if unload_limit <= 0.0:
		return
	var voxel_scale := renderer.voxel_scale
	var coarse_level := maxi(lod_count - 1, 1)
	var coarse_edge := VoxelLodGrid.block_edge_world(coarse_level, voxel_scale)
	var coarse_margin := VoxelLodGrid.margin(coarse_level, voxel_scale)
	var data_unload_limit := lod0_data_unload_d()
	var candidates: Array = []
	for ck in data.get_loaded_chunk_keys():
		var dist := VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)
		if dist > unload_limit:
			candidates.append([dist, ck])
	# 距离降序：最远的先卸载
	candidates.sort_custom(func(a, b): return a[0] > b[0])
	var unloaded_mesh := 0
	for item in candidates:
		if unloaded_mesh >= _stream_unload_per_frame:
			break
		var ck_mesh: Vector3i = item[1]
		# 粗层 block 仍覆盖该 chunk（远处降采样还要读它）→ 保留网格兜底
		var bk := VoxelLodGrid.block_of_chunk(ck_mesh, coarse_level)
		if VoxelLodGrid.block_dist(bk, coarse_level, cam_pos, world_offset, voxel_scale) \
				<= unload_limit + coarse_margin + coarse_edge * 0.5:
			continue
		renderer.remove_chunk_mesh(ck_mesh)
		unloaded_mesh += 1
	var unloaded_data := 0
	for item in candidates:
		if unloaded_data >= _stream_unload_per_frame:
			break
		var ck_data: Vector3i = item[1]
		if renderer.has_chunk_mesh(ck_data):
			continue
		if VoxelWorldUtil.chunk_center_dist(ck_data, cam_pos, chunk_size_world, world_offset) <= data_unload_limit:
			continue
		if data.unload_chunk(ck_data):
			unloaded_data += 1
	# 撤销超范围仍未完成的异步请求：晚到的结果会被数据层丢弃，不会"卸载后复活"
	for ck_p in data.get_unready_chunk_keys(0):
		var ckp: Vector3i = ck_p
		if VoxelWorldUtil.chunk_center_dist(ckp, cam_pos, chunk_size_world, world_offset) > unload_limit:
			data.cancel_chunk_request(ckp, 0)
	if unloaded_mesh > 0 or unloaded_data > 0:
		renderer.request_update()


# ── 能力 4：origin shift ───────────────────────────────────────────────────

## 相机 chunk 距数据基准超阈值时平移数据层 + 渲染层 + 本组件键账本 + 相机，
## 使相机附近 chunk 回到小坐标，避免 float32 精度损失（无限移动世界的前提）。
## 【为什么"决策在这里、平移在 renderer"】何时平移是纯视点逻辑；而"平移哪些账本"是
## renderer 的渲染层私有状态，它只暴露一个整体入口 shift_render。
func check_origin_shift(cam: Camera3D) -> void:
	if renderer == null or cam == null or renderer.data == null:
		return
	var chunk_size_world := renderer.voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam.global_position, chunk_size_world, renderer.global_position)
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
	# 四方必须同步：数据层键 / 渲染层键与节点位置 / 本组件键账本 / 相机位置。
	# 漏任一方都会留下幽灵数据或幽灵网格（相机不补偿则下一轮又判一次"移动"）。
	renderer.data.shift_origin(shift)
	_origin_chunk += shift
	renderer.shift_render(shift, chunk_size_world)
	shift_keys(shift)
	cam.global_position -= Vector3(shift) * chunk_size_world
	_last_streaming_cam_pos = cam.global_position


## origin shift 后平移本组件的坐标键账本。漏平移会让在途补建拿旧键比对 → 被误判过期，
## 且标记永久停在旧坐标系（无界增长）。
func shift_keys(shift: Vector3i) -> void:
	_deferred_chunks = VoxelChunk.shift_key_dict(_deferred_chunks, shift)
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
	# 挂载队列里的 mesh 是旧坐标系下生成的（顶点已烘焙世界位置），平移会整体错位 → 直接丢弃重算。
	# 代价只是一次多余重建，且 origin shift 极少触发（相机跨越 256 chunk）。
	_lod_mesh_apply_queue.clear()
	_lod_mesh_apply_scheduled = false



# ── LOD 分带调度（完整实现，从 VoxelInfiniteLayer 迁入）──────────────────

## LOD 调度入口（内核 _process 每帧调用；降频与失效直通在本方法内判定）。
## 降频：每 visibility_check_interval 帧跑一次；数据失效（破坏/编辑）时立即跑，
## 不等降频周期 → 破坏重建更及时。
## 【为什么 lod_count=1 也必须跑】LOD0 chunk mesh 的补建只在这里，跳过则画面空白。
func process_lod() -> void:
	if renderer == null:
		return
	var data := renderer.data
	_cull_check_counter += 1
	if data == null:
		return
	if _cull_check_counter < visibility_check_interval and not data.has_lod_invalidated():
		return
	_cull_check_counter = 0
	if not renderer.is_inside_tree():
		return
	var cam := renderer.current_camera()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var world_offset := renderer.global_position
	var unload_d := unload_d()
	var n_levels := maxi(lod_count, 1)
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
		renderer.lod_materials(level, true)
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
	var submit_budget: int = _lod_submit_per_frame
	if data.infinite:
		submit_budget = 40
	# 每层独立构建预算 = 总数均分（保证近层建完前更粗层也能推进，不被近层 in-flight
	# 队列饿死——否则 LOD1 海量候选每帧占满共享配额，LOD2 永远 0 个 → 远处空洞）。
	var per_level_build := maxi(_lod_build_per_frame / maxi(n_levels, 1), 4)
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
	var data := renderer.data
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
		VoxelWorldUtil.chunk_from_world(cam_pos, renderer.voxel_scale * VoxelChunk.CHUNK_SIZE, world_offset), level)
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
	for bk in renderer.lod_mesh_keys(level):
		var dist := _block_dist(bk, level, cam_pos)
		if dist > unload_d + edge_world * 0.5:
			remove_keys.append(bk)
		elif dist < inner - margin and _level_finer_ready(level, bk, cam):
			remove_keys.append(bk)
		elif dist > upper + preload_d and renderer.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			remove_keys.append(bk)
	for bk in remove_keys:
		remove_lod_block(level, bk)
	# 1c. 带内缺失：数据未就绪 → 请求独立数据（生成器 _generate_chunk_lod）；就绪 → 派发 mesh
	var to_build: Array = []
	for bk in needed:
		if renderer.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
			# 空标记（null mesh）但粗层数据已就绪 → 重建 mesh（数据生成晚于首次 mesh 尝试——
			# 否则粗层一直空标记，LOD0 移除后出现过渡空洞）。
			if renderer.lod_mesh(level, bk) != null or not data.has_lod_block(level, bk):
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
		renderer.lod_materials(level, true)
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
	for bk in renderer.lod_mesh_keys(level):
		var mi: MeshInstance3D = renderer.lod_mesh(level, bk)
		if mi == null:
			continue  # 空大块（无体素）
		# 失效重建中：冻结可见性——破坏瞬间不因重建切换 LOD 层级（避免"不同层级闪烁"），
		# 新 mesh 就绪替换并清除重建标记后，下一帧按当前状态恢复正常可见性判定。
		if _lod_rebuilding(level, bk):
			continue
		var dist := _block_dist(bk, level, cam_pos)
		if dist < inner + margin:
			mi.visible = not _level_finer_ready(level, bk, cam)
		elif dist > outer + margin and renderer.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			mi.visible = false
		else:
			mi.visible = true


## LOD0（chunk 层）网格管理：移除超出 LOD0 带的（粗层已就绪），补建带内缺失
func _process_chunk_level(loaded_chunks: Array, cam: Camera3D, cam_pos: Vector3, world_offset: Vector3, unload_d: float) -> void:
	var data := renderer.data
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	# 移除超出 LOD0 带的 chunk 网格：
	#   - 对应粗层已就绪 → 移除（避免"先细后粗"残留）
	#   - 超出最粗层覆盖带（block 中心 > outer[coarsest]+margin）→ 直接移除
	#     （该区域超出可视范围，粗层不再覆盖；视锥外空洞不可见，安全）
	var remove_lod0: Array = []
	var coarsest := maxi(lod_count, 1) - 1
	for ck in renderer.lod_mesh_keys(0):
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
			var coarse_mesh: MeshInstance3D = renderer.lod_mesh(level, bk)
			if coarse_mesh != null or _block_dist(bk, level, cam_pos) > _lod_outer[level] + _lod_margin(level):
				remove_lod0.append(ck)
		else:
			# lod_count=1 无更粗层 → 超出 LOD0 显示区直接移除，否则残留旧网格
			remove_lod0.append(ck)
	for ck in remove_lod0:
		renderer.remove_chunk_mesh(ck)
	# 补建视锥内 LOD0 区未建的 chunk（相机移动不产生 dirty，需主动补建）
	var need_lod0_update := false
	if cam != null:
		var _chunk_world := renderer.voxel_scale * VoxelChunk.CHUNK_SIZE
		var _r_ck := ceili((lod0_d + lod0_margin) / _chunk_world) + 1
		var _cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, _chunk_world, world_offset)
		if loaded_chunks.is_empty():
			# 移动后新区域：loaded_chunks 为空（LOD0 数据未加载）→ 从相机位置推导补建。
			# 否则 LOD0 chunk 永不被 request/加载 → 近处 LOD0 空洞固定存在。
			for dx in range(-_r_ck, _r_ck + 1):
				for dy in range(-_r_ck, _r_ck + 1):
					for dz in range(-_r_ck, _r_ck + 1):
						var ck: Vector3i = _cam_ck + Vector3i(dx, dy, dz)
						if renderer.has_lod_mesh(0, ck):
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
				if renderer.has_lod_mesh(0, ck):
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
		renderer.request_update()


## 见 VoxelLodGrid.chunk_render_level
func _chunk_render_level(ck: Vector3i, cam_pos: Vector3) -> int:
	return VoxelLodGrid.chunk_render_level(ck, cam_pos, renderer.global_position, renderer.voxel_scale, _lod_outer, lod_count)


## 本层 block 的覆盖区域在内层（level-1）是否已全部就绪（有网格或为空）。
## level 1 的内层 = chunk（level 0）；仅统计视锥内的（视锥外不显示、无需网格不阻塞）。
func _level_finer_ready(level: int, bk: Vector3i, cam: Camera3D) -> bool:
	if level <= 0:
		return true
	var data := renderer.data
	var fine := level - 1
	for k in 2:
		for j in 2:
			for i in 2:
				var sbk := Vector3i(bk.x * 2 + i, bk.y * 2 + j, bk.z * 2 + k)
				# 内层就绪判定：LOD0 chunk 无空标记（有 mesh 即就绪）；
				# 粗层 block 的空标记（null，数据/网格未就绪）不算就绪 → 更粗层兜底显示，防过渡空洞。
				var fine_ready: bool = renderer.has_lod_mesh(fine, sbk) if fine == 0 else (renderer.lod_mesh(fine, sbk) != null)
				if fine_ready:
					continue
				if fine == 0:
					if data.has_chunk(sbk):
						# 重建中（mesh 在构建队列或数据层标脏）→ 仅当该 chunk 实际属于
						# LOD0 带（render_level==0，会被 L0 构建）才视为就绪：
						# 破坏瞬间内层未就绪会导致粗层临时替代（LOD 边界来回移动 → 闪烁）。
						# 而 LOD1 带的 chunk 由粗层覆盖、L0 永不构建，若当成就绪会让
						# _process_lod_level 隐藏粗层 → LOD0/LOD1 交界处背景透出空洞。
						if renderer.is_mesh_build_queued(sbk) or data.is_chunk_mesh_dirty(sbk):
							if _chunk_render_level(sbk, cam.global_position) == 0:
								continue
						var aabb := VoxelWorldUtil.chunk_world_aabb(
							sbk, renderer.voxel_scale * VoxelChunk.CHUNK_SIZE, renderer.global_position)
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
	var center := VoxelLodGrid.block_center(bk, renderer.global_position, _lod_block_edge_world(level))
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
	var data := renderer.data
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
	var standalone: bool = data.can_mesh_lod_block_standalone(level, bk)
	var snapshot := data.read_lod_block_data_snapshot(bk, level) if standalone \
			else data.read_lod_block_chunk_snapshot(bk, level)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_build.bind(
		snapshot, standalone, bk, level, _lod_block_gen[level].get(bk, 0), renderer.voxel_scale,
		data.center_offset, renderer.lod_materials(level).duplicate(), handle)))
	return true


## 内带失效 block（LOD0 显示区）：只降采样同步粗层数据（粗层缓存 + 持久化）。
## mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被丢弃——拆分两阶段，避免内带生成完整粗层 mesh 的 worker 浪费。
func _build_lod_data_only(level: int, bk: Vector3i) -> void:
	var data := renderer.data
	if data == null:
		return
	if level < 1 or level >= _lod_pending_tasks.size():
		return
	if _lod_pending_tasks[level].has(bk):
		return
	_lod_pending_tasks[level][bk] = true
	# 同上：句柄由 _on_lod_data_ready 释放。
	var handle := data.begin_readonly_snapshot()
	var snapshot := data.read_lod_block_chunk_snapshot(bk, level, false)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_data_only.bind(
		snapshot, bk, level, _lod_block_gen[level].get(bk, 0), handle)))


## 工作线程：粗 LOD 大块 mesh 生成。只读主线程构造好的数据快照（线程安全，不触碰 QVoxelSource）。
##   standalone=true：快照是独立粗层大格数据（直接拷大格，无降采样）；
##   false：快照是 LOD0 chunk 缓冲（降采样），顺带回传大格数据供粗层缓存复用。
func _lod_worker_build(snapshot: Dictionary, standalone: bool, bk: Vector3i, level: int,
		gen_id: int, scale: float, offset: Vector3, aligned_materials: Array,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	# 【必须防空快照】快照为空是**正常情况**（LOD0 数据尚未加载/生成完，降采样源还没到），
	# 不是错误。原生在这种情况下返回空 halo，而 `extract_center_from_halo` 会越界崩溃。
	# 直接按"本次产出空"回报，让主线程走重试计数（见 _lod_mark_null_or_retry）。
	if snapshot.is_empty():
		call_deferred("_on_lod_thread_result", bk, level, null, gen_id, PackedInt32Array(), handle)
		return
	var halo: PackedInt32Array
	var buf := PackedInt32Array()
	if standalone:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(snapshot, bk)
	else:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_buffers(snapshot, bk, level)
	if halo.size() != VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		call_deferred("_on_lod_thread_result", bk, level, null, gen_id, PackedInt32Array(), handle)
		return
	if not standalone:
		buf = VoxelChunk.extract_center_from_halo(halo)
	var arr := VoxelChunkGenerator.generate_lod_block_arrays(halo, aligned_materials, scale, bk, offset, level)
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arr)
	call_deferred("_on_lod_thread_result", bk, level, mesh, gen_id, buf, handle)


## 工作线程：内带失效 block 只降采样大格数据（不生成 mesh——mesh 由 LOD0 chunk 反映）。
## 拆分两阶段：内带 block 的粗层 mesh 应用会被 _should_apply 丢弃，省去 arrays/mesh 构建。
func _lod_worker_data_only(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	# 同上：空快照是正常的（数据还没到），按空结果回报走重试，不要越界崩。
	if buffers.is_empty():
		call_deferred("_on_lod_data_ready", bk, level, gen_id, PackedInt32Array(), handle)
		return
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
	if halo.size() != VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		call_deferred("_on_lod_data_ready", bk, level, gen_id, PackedInt32Array(), handle)
		return
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
	var data := renderer.data
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
		renderer.mark_lod_block_empty(level, bk)
		return
	var layer := _null_retry_layer(level)
	var _rn: int = layer.get(bk, 0)
	if _rn >= 3:
		layer.erase(bk)
		renderer.mark_lod_block_empty(level, bk)
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
	if buf.size() > 0 and renderer.data != null:
		renderer.data.store_lod_block(level, bk, buf)
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
	var data := renderer.data
	# 同步粗层缓存（降采样回退的数据与 mesh 一致，供后续复用/持久化）。
	# 仅 mesh 非空（有实际体素）才写缓存：真空 block 若写全 0 buffer，
	# has_lod_block=true → _process_lod_level 判"数据就绪但 mesh 空"→ 每帧重新派发
	# → 死循环占满跨层构建预算，更粗层永远分不到（远处空洞）。
	if buf.size() > 0 and data != null and mesh != null and mesh.get_surface_count() > 0:
		data.store_lod_block(level, bk, buf)
	if renderer.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
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
		if renderer.has_lod_mesh(level, bk) and renderer.lod_mesh(level, bk) == null:
			return  # 已设真空标记 → 停止派发
		renderer.clear_lod_mesh(level, bk)  # 重试中 → 移除条目，下次 _process_lod_level 重新派发降采样
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
		if built >= _lod_build_per_frame:
			break
		if (Time.get_ticks_usec() - t0) / 1000.0 > 3.0:
			break
		var item: Array = _lod_mesh_apply_queue[i]
		var level: int = item[0]
		var bk: Vector3i = item[1]
		var mesh: ArrayMesh = item[2]
		# 重新校验区间（结果排队期间相机可能移动）
		if _should_apply_lod_mesh(level, bk):
			renderer.mount_lod_mesh(level, bk, mesh)
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
	if renderer.diag_enabled and built > 0:
		print("[诊断] LOD大块挂载批处理: %d 个, 剩余%d" % [built, _lod_mesh_apply_queue.size()])


## 粗 LOD 大块是否仍在显示区间（挂载前校验，相机移动后过期结果丢弃）。
## 失效重建的 block：强制应用（替换旧 mesh 反映破坏）——近处内带由 _level_finer_ready
## （重建中视为就绪）隐藏本层，不产生 LOD 层级切换；远处粗层区替换后显示含洞网格。
func _should_apply_lod_mesh(level: int, bk: Vector3i) -> bool:
	if level < 1 or level >= lod_level_count():
		return false
	if renderer.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
		return false
	var cam := renderer.current_camera()
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
	if renderer.data != null and renderer.data.has_lod_block(level, bk):
		return dist <= unload_d + edge_world * 0.5
	return not (dist < inner - margin or dist > unload_d + edge_world * 0.5)


## 移除指定粗层的 block（网格节点由内核释放，本层只清自己的调度账本）。
## level 0（chunk）不走这里——LOD0 的移除是内核 remove_chunk_mesh，语义不同（含碰撞与延迟队列）。
func remove_lod_block(level: int, bk: Vector3i) -> void:
	renderer.clear_lod_mesh(level, bk)
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
	return VoxelLodGrid.block_dist(bk, level, cam_pos, renderer.global_position, renderer.voxel_scale)


## 见 VoxelLodGrid.margin
func _lod_margin(level: int) -> float:
	return VoxelLodGrid.margin(level, renderer.voxel_scale)


## 见 VoxelLodGrid.block_edge_world
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, renderer.voxel_scale)


## 见 VoxelLodGrid.preload_extent（提前量旋钮仍是内核 @export，见类注释"配置仍挂在节点上"）
func _lod_preload_extent(level: int) -> float:
	return VoxelLodGrid.preload_extent(level, renderer.voxel_scale, _lod_preload_blocks)


# ── 内部 ──────────────────────────────────────────────────────────────────

## 重算分带表（view_distance / lod_count 变化时惰性触发），并同步宿主粗层账本长度。
## 【为什么长度在这里维护】4 张调度表归本组件、`_lod_meshes` 归 renderer，两边各自 resize
## 迟早悄悄错位。由本方法单点驱动：分带表算完就把 renderer 的网格层数对齐过来。
func _ensure_bands() -> void:
	var n := maxi(lod_count, 1)
	if _lod_outer.size() == n and _bands_lod_count == n \
			and is_equal_approx(_bands_view_distance, view_distance):
		return
	_lod_outer = VoxelLodGrid.bands(view_distance, n)
	_bands_view_distance = view_distance
	_bands_lod_count = n
	if renderer != null:
		# 粗层网格账本跟着本组件的层数走（接管后本组件是唯一真值，见类头说明）
		renderer.set_lod_level_count(n)
	# 4 张调度表的长度同样单点维护（与 renderer 的 _lod_meshes 同长）
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


## 调度前置条件：开关打开、已绑定渲染器、两者都在树内、数据层就位。
func _can_schedule() -> bool:
	if not enabled or renderer == null:
		return false
	if not is_inside_tree() or not renderer.is_inside_tree():
		return false
	return renderer.data != null


# ── 接管状态 ───────────────────────────────────────────────────────────────
#
# 本组件现已具备 `VoxelInfiniteLayer` 的**全部**能力（视锥 / 延迟补建 / 流式加载卸载 /
# origin shift / LOD 粗层调度）。原本的 TODO 清单已逐条落实：
#
#  1. 粗层派发与挂载 → `_build_lod_block` / `_lod_worker_build` / `_on_lod_thread_result` /
#     `process_lod_mesh_apply_queue`（块级代次 + 帧尾限量挂载）。
#  2. 粗层数据清理 → `remove_lod_block` / `_clear_block_state`；"超出 LOD0 带且粗层就绪"
#     的 LOD0 网格移除在 `_process_chunk_level`。
#  3. 与 renderer 网格管线的接口 → renderer 持一个**可空**的 `paged_layer` 引用；
#     `paged_layer != null` 时改调本组件的 `filter_chunks`（否则仍走旧层）。这是唯一的
#     反向调用，契约只有两句话：renderer 只问"这些 chunk 可见吗"，本组件只读公开面。
#  4. `renderer.set_lod_level_count(n)` → 由 `_ensure_bands` 在层数变化时同步。
#  5. 延迟队列"重建权"回传 → `on_mesh_removed` / `is_deferred` 已由 renderer 接入。
#
# 【并存期】`enabled` 默认 false。renderer 在 `_process` 里按"是否已挂本组件"决定谁驱动
# 调度：挂了就只调本组件、不调旧层；没挂就走旧层。两者绝不并行（会互相抢同一批账本）。
