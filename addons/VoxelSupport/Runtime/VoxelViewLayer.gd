@tool
class_name VoxelViewLayer
extends Node3D

## 视点层：把"相机在哪"翻译成"哪些网格该存在"。
##
## 负责五件事，全部以相机为前提，与"体素怎么存 / 网格怎么组装"正交：
##   ① 可见性过滤：流式距离 + LOD 分带 + 视锥剔除（视锥外交给延迟队列）
##   ② 延迟补建：进视锥 / 走近后把沉睡的 chunk 唤醒标脏
##   ③ 流式供需：按距离限量请求数据、卸载超范围网格与数据、撤销在途请求
##   ④ 原点漂移：相机跑远时整体平移数据层 + 渲染层 + 相机，保住 float32 精度
##   ⑤ LOD 粗层调度：按分带枚举 block、派发 worker、帧尾限量挂载、可见性兜底
##
## 【为什么是独立节点而不是渲染器里的一段代码】
## 这五件事都只读"相机 + 配置"，只写"内核的网格账本"。放进内核会让内核必须知道相机、
## 视锥、流式距离、LOD 分带 —— 而这正是它最该保持无知的东西。独立成节点后生命周期归引擎
## （删节点即停调度，不需要 abort/clear 收尾），@export 也能被 Inspector 看到并存进场景。
##
## 【依赖方向：单向 本层 → 内核】
##   · 读内核公开面：data / voxel_scale / global_position / current_camera()
##     / view_distance / unload_distance / lod_count / visibility_mode / visibility_check_interval
##     / diag_enabled
##   · 命令内核：request_update / remove_chunk_mesh / has_chunk_mesh / is_mesh_build_queued
##     / lod_mesh / has_lod_mesh / lod_mesh_keys / mount_lod_mesh / clear_lod_mesh
##     / mark_lod_block_empty / lod_materials / lod_level_count / set_lod_level_count / shift_render
##   · 数据层只用 QVoxelSource 公开方法（含为本层开放的三个粗层快照壳）。
##   **绝不读写内核的 `_` 前缀成员** —— 否则就是双向耦合。
## 反向只有两件事，都是查询/转发而非依赖：内核问"这些 chunk 可见吗"（filter_chunks），
## 内核转发"该调度了"（process_streaming / process_deferred_chunks / process_lod）。
##
## 【只有这一层】视点调度（流式卸载 / LOD 分带 / 延迟构建）全部归本类，**没有第二个平行实现**：
## 两个各写一半的视点层会带来 2655 行 / 44 个同名函数 / 500~800 行逐字重复，
## 而"默认跑哪一个"永远说不清。
##
## 【配置为什么一半在这里、一半在渲染器】距离/层数/模式旋钮（view_distance /
## unload_distance / lod_count / visibility_mode / visibility_check_interval）已被场景文件引用，
## 保持在内核上、本层单向读取；而流式与 LOD 的限量旋钮（stream_* / lod_*）原本就是内核的
## 私有 @export、无人引用，搬到这里与逻辑同居 —— 这样**不存在两份同名真值**，
## 也就不会出现"改了一处、另一处还是旧值"的镜像失效。

# ── 本组件自持的旋钮 ────────────────────────────────────────────────────────

## 每轮最多推送多少个 chunk 数据请求。
@export_range(1, 400, 1) var stream_load_per_frame: int = 32

## 每轮最多卸载多少个超范围 chunk（网格与数据各自计一次限额）。
@export_range(1, 400, 1) var stream_unload_per_frame: int = 24

## 每轮最多派发多少个粗层 block。
@export_range(1, 400, 1) var lod_build_per_frame: int = 128

## 粗层预生成提前量（block 数）：跨带前备好，消除切换瞬间的空白窗口。
@export_range(0, 6, 1) var lod_preload_blocks: int = 1

## 每轮跨层共享的后台数据生成提交预算（防单帧洪峰打爆 WorkerThreadPool）。
@export_range(1, 500, 1) var lod_submit_per_frame: int = 200

## 粗层 mesh 挂载的每帧时间预算（毫秒）。粗块 mesh 覆盖数十万体素，
## 多个后台结果同时到达时直接同步挂载会卡主线程，故帧尾限量挂载。
@export_range(0.5, 50.0, 0.5) var lod_apply_budget_ms: float = 3.0

# ── 常量 ────────────────────────────────────────────────────────────────────

## 超范围数据的清理降频（每 N 个扫描 tick 一次）。卸载扫描较重，不宜每 tick 全量跑。
const STREAM_UNLOAD_INTERVAL := 8

## origin shift 阈值（chunk）：相机 chunk 距基准超此值触发平移。
## chunk 32³ × 0.1 = 3.2 世界单位，256 chunk ≈ 820 世界单位，远小于 float32 精度上限。
const ORIGIN_SHIFT_THRESHOLD := 256

## 粗层 worker 任务 ID 常驻上限（超出即 wait 最旧一批，见 trim_tasks）。
const COARSE_TASK_ID_BUDGET := 256

## 粗层降采样空结果的重试上限（防空 block 无限重派）。
const LOD_NULL_RETRY_LIMIT := 3

## 块级状态记录的键名（见 `_levels`）。
const _K_GEN := "gen"
const _K_PENDING := "pending"
const _K_REBUILD := "rebuild"
const _K_RETRY := "retry"

# ── 依赖与生命周期 ──────────────────────────────────────────────────────────

## 宿主渲染器（唯一依赖）。为 null 时全部调度安全空转。
var renderer: VoxelRenderer = null


func _ready() -> void:
	if renderer == null:
		renderer = get_parent() as VoxelRenderer
	# 有宿主时由宿主每帧驱动（宿主 _process 依次调 process_streaming / process_deferred_chunks
	# / process_lod）；没有宿主（独立使用）才自驱动。两侧同时驱动会让降频语义失效。
	set_process(renderer == null)
	if renderer != null:
		sync_lod_levels()


func _process(_delta: float) -> void:
	if renderer == null or not _can_schedule():
		return
	process_streaming()
	process_deferred_chunks()
	process_lod()


## 显式绑定宿主（代码装配用；作为子节点挂载时 _ready 自动认父）。
func attach(host: VoxelRenderer) -> void:
	renderer = host
	if host != null and host.view_layer != self:
		host.view_layer = self
	set_process(false)   # 宿主驱动
	sync_lod_levels()
	if host != null and host.data != null:
		host.request_update()


func _exit_tree() -> void:
	# 置停止标记并等所有粗层 worker 结束：worker 完成时 call_deferred 会打到已释放实例。
	abort()


## 停止调度并等待在途 worker。
## 【何时必须调用】宿主节点释放之前（见 VoxelRenderer._exit_tree）。节点被移出树的常规
## 路径由本类自己 _exit_tree 触发，故外部通常不必手动调。
func abort() -> void:
	_exiting = true
	trim_tasks(true)


## 调度前置条件：有宿主、在树里、有数据。
func _can_schedule() -> bool:
	return renderer != null and renderer.is_inside_tree() and renderer.data != null

# ── 状态：可见性 / 流式 ────────────────────────────────────────────────────

## 延迟补建队列：视锥外被过滤掉的 chunk（chunk_key → true）。进视锥 / 靠近后补建。
var _deferred_chunks: Dictionary = {}

## 强制构建标记：距离驱动的补建（延迟队列晋升 / 已存数据同步预载），
## 使增量重建时不被视锥剔除再次拦回延迟队列。
var _stream_force_build: Dictionary = {}

## 流式扫描降频计数与上次相机位置（相机不动时扫描结果不变）。
## 流式调度的两个独立帧计数。
## 【为什么不是一个 _streaming_check_tick】从前扫描与卸载共用一个计数器，而"相机移动时提速"
## 靠把计数器**提前清零**实现：清零后既让扫描立刻跑（0 % interval == 0），也让卸载立刻跑。
## 于是两个周期被绑死在一起 —— 卸载实际变成"跟着扫描提速"，而 check_interval 调大时
## 卸载频率却不变（它用另一个常量取模），改一个参数会意外改变另一个的节奏。
## 现在各自累计、各自到期清零：谁也不再影响谁。
var _frames_since_scan := 0
var _frames_since_unload := 0
var _last_streaming_cam_pos := Vector3(INF, INF, INF)

## 数据基准 chunk（origin shift 后）。
var _origin_chunk: Vector3i = Vector3i.ZERO

# ── 状态：LOD 分带调度 ─────────────────────────────────────────────────────

## 各层外半径（世界单位）：_lod_outer[i] = LOD_i 显示区外边界。
## 唯一写入点 sync_lod_levels（由内核的 lod_count / view_distance 变化驱动）。
var _lod_outer: Array[float] = []

## 块级调度账本，按 LOD 层级平行；index 0 = LOD0（chunk 层不记账），>=1 才有内容。
## `_levels[level][block_key] = {gen:int, pending:bool, rebuild:bool, retry:int}`
##
## 【一张表而不是四张】pending / rebuild / null-retry / gen 若各用一张平行表，每个 block 的
## 状态就散在四处：clear/erase 要记得四张都清（漏一张就随探索范围无界增长），shift 要平移
## 四次。合并成一条记录后，这些操作全部退化为"一次 erase / 一次遍历"。
var _levels: Array[Dictionary] = []

## 数据 chunk 范围（needed 枚举剪枝：球体全高大部分是空气层，跳过空 block 的降采样派发 ——
## 否则高层空块反复派发占满 worker，lod_count > 1 时帧率骤降）。
var _data_chunk_min := Vector3i.ZERO
var _data_chunk_max := Vector3i.ZERO
## 数据范围是否已测得（首帧 loaded_chunks 为空时不测，避免把范围钉成单点导致枚举被剪光）。
var _data_range_valid := false

## 本帧跨层共享的构建数 / 提交数（每轮 process_lod 开头归零）。
var _lod_build_this_frame := 0
var _lod_submit_this_frame := 0
## LOD 调度降频计数。
var _cull_check_counter := 0

## 粗 LOD 大块 mesh 挂载队列：[{level, key, mesh}]，帧尾限量挂载（GPU 上传摊平）。
var _lod_mesh_apply_queue: Array[Dictionary] = []
var _lod_mesh_apply_scheduled := false

## 粗 LOD worker 任务 ID（退出时等待，防 call_deferred 打到已释放实例）。
var _coarse_task_ids: Array[int] = []
## 退出中：worker 结果回调据此直接丢弃，避免访问已清理数据。
var _exiting := false

# ── 公开查询（宿主 / 破坏系统 / HUD 用）────────────────────────────────────

## 网格卸载距离：unload_distance 未显式设置（<= view_distance）时回退 view_distance * 1.2。
## 所有距离判定（网格过滤 / 数据卸载 / LOD 挂载 / 过期结果丢弃）共用此值，避免各处分歧。
## 惰性计算而不回写字段：规避属性加载顺序导致的错误固化值。
func unload_d() -> float:
	if renderer == null:
		return 0.0
	var vd := renderer.view_distance
	return renderer.unload_distance if renderer.unload_distance > vd else vd * 1.2


## LOD0 **数据**卸载半径：比网格卸载半径再外扩"最粗层 block 的覆盖范围"。
## 【为什么外扩】粗层 block 在 unload_d 附近仍可能被构建 / 降采样，而降采样要读它覆盖的
## 2^level³ 个 LOD0 chunk（还要 +1 chunk 光环）。若 LOD0 数据在 block 覆盖范围内被卸掉，
## 降采样会读到"假空块" → 粗层缺格 / 空洞。外扩 2 个 block 边长足以覆盖最坏情形。
func lod0_data_unload_d() -> float:
	if renderer == null:
		return 0.0
	var coarse_level := maxi(renderer.lod_count - 1, 1)
	return unload_d() + 2.0 * _lod_block_edge_world(coarse_level) \
			+ renderer.voxel_scale * VoxelChunk.CHUNK_SIZE


## 世界坐标是否在当前相机视锥内。
## 供粒子 / 破碎 / 掉落体等"视锥外跳过"优化使用。无相机 / 未入树时返回 true（保守不裁剪）。
func is_world_visible(world_pos: Vector3) -> bool:
	var cam := renderer.current_camera() if renderer != null else null
	return cam == null or cam.is_position_in_frustum(world_pos)


## 当前数据基准 chunk（origin shift 后）。供 HUD / 调试读取。
func origin_chunk() -> Vector3i:
	return _origin_chunk


## 各层 LOD 外半径（分带表）。
func lod_outer() -> Array[float]:
	return _lod_outer


## LOD 层数（含 LOD0）。权威长度在内核网格账本，本层的调度表由 sync_lod_levels 与之对齐。
func lod_level_count() -> int:
	return renderer.lod_level_count() if renderer != null else 0


## 延迟队列是否为空（内核增量重建的防抖先问这一句，非流式场景可直接跳过整轮脏列表遍历）。
func deferred_is_empty() -> bool:
	return _deferred_chunks.is_empty()


## 延迟队列成员查询（内核派发前据此剔除"重建权已归延迟队列"的脏 chunk）。
func is_deferred(ck: Vector3i) -> bool:
	return _deferred_chunks.has(ck)


## 网格被内核移除时同步（该 chunk 的重建权随之作废，否则会残留"幽灵补建"条目）。
func on_mesh_removed(ck: Vector3i) -> void:
	_stream_force_build.erase(ck)
	_deferred_chunks.erase(ck)


## 清空延迟队列与强制标记。
func clear_deferred() -> void:
	_deferred_chunks.clear()
	_stream_force_build.clear()


## 同步相机缓存位置（origin shift 反向补偿相机后必须调用，否则下一帧读到一次伪"相机移动"）。
func sync_cam_pos(p: Vector3) -> void:
	_last_streaming_cam_pos = p


## 清空全部调度账本（数据 / 缩放 / 层数变化导致所有网格作废时，随内核 _clear_lod_meshes 调用）。
## 网格节点由内核自己释放，本层只清自己的表 + 延迟队列 + 挂载队列。
func clear_lod_state() -> void:
	clear_deferred()
	for lv in _levels.size():
		_levels[lv].clear()
	_lod_mesh_apply_queue.clear()
	_lod_mesh_apply_scheduled = false


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

# ── 配置变化入口（由内核 setter 单点转发）────────────────────────────────────

## 分带与调度表长度重算。内核的 lod_count / view_distance 变化时调用（唯一入口）。
## 【为什么长度维护收在这里】调度表归本层、`_lod_meshes` 归内核，两边各自 resize 迟早
## 悄悄错位；统一由本方法驱动，内核的 set_lod_level_count 只做被动的长度对齐。
func sync_lod_levels() -> void:
	if renderer == null:
		_levels.clear()
		_lod_outer.clear()
		return
	var n := maxi(renderer.lod_count, 1)
	_lod_outer = VoxelLodGrid.bands(renderer.view_distance, n)
	while _levels.size() > n:
		_levels.pop_back()
	while _levels.size() < n:
		_levels.append({})
	# 被裁层的在途 worker 结果回来时 level 已越界 → _on_lod_worker_done 早退丢弃。
	renderer.set_lod_level_count(n)


## 可见性模式变化（FULL 下延迟队列失去意义，必须清空）。
func on_visibility_mode_changed(mode: int) -> void:
	if mode == VoxelRenderer.VisibilityMode.FULL:
		_deferred_chunks.clear()


# ── ③ 流式供需与 origin shift ──────────────────────────────────────────────

## 统一流式 / 程序化驱动：按相机距离管理 chunk 数据与网格。数据源是两个**并列**的抽象，
## 差异不靠类型分支猜：
##   · 数据层（QVoxelSource 及其扩展）：未存过的 chunk 后台确定性产出。
##     存过的（= 用户改过）必须优先从流取，否则重新生成会覆盖用户修改。
##   · stream（VoxelStream）：已存的数据（QVoxelStream 常驻内存索引 → 直读）。
## 流程：① 回填异步结果 → ② 距离内扫描缺失 chunk 提交（限量 / 降频）→ ③ 卸载超范围
## 网格、LOD0 数据与粗层数据块，并撤销超范围在途请求。
func process_streaming() -> void:
	var r := renderer
	if r == null or not r.is_inside_tree():
		return
	var data := r.data
	if data == null or not data.is_streaming():
		return
	var cam := r.current_camera()
	if cam == null:
		return
	var voxel_scale := r.voxel_scale
	var world_offset := r.global_position
	var cam_pos := cam.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var check_interval := r.visibility_check_interval
	var lod_count := r.lod_count
	var load_d := r.view_distance
	var unload_d := unload_d()
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, chunk_size_world, world_offset)

	# 程序化无限世界：origin shift（相机 chunk 距基准超阈值 → 平移数据 + 渲染 + 相机）
	if data.infinite:
		check_origin_shift(cam)

	# 1) 回填后台异步结果（生成器产出 / 流里直读），poll → 回填一步到位（数据层封装）。
	# 限量 = 加载预算的 2 倍：避免来回移动时每帧回填过多（主线程写入 + 失效开销大 → 掉帧）。
	var applied := data.apply_ready_results(maxi(stream_load_per_frame * 2, 32))

	# 2) 距离内扫描缺失 chunk 并提交（限量；降频，相机不动时结果不变）。
	# 相机移动时用更短的间隔（interval/2）：保证响应及时又不每帧全量遍历。
	var cam_moved := cam_pos != _last_streaming_cam_pos
	_last_streaming_cam_pos = cam_pos
	_frames_since_scan += 1
	_frames_since_unload += 1
	var scan_interval := maxi(check_interval >> 1, 1) if cam_moved else check_interval
	# 粗层分带表为空时无从判断"该不该加载"，扫描本身就没有意义（也不必累到溢出）。
	var do_scan := _frames_since_scan >= scan_interval and not _lod_outer.is_empty()
	if do_scan:
		_frames_since_scan = 0
	var submitted := 0
	# 移动中提高本帧加载吞吐（更快补建，减少前方空白）。
	var load_budget := stream_load_per_frame * 2 if cam_moved else stream_load_per_frame
	if do_scan:
		var rad := ceili(load_d / chunk_size_world) + 1
		var yspan := data.get_vertical_half_span()
		for dz in range(-rad, rad + 1):
			if submitted >= load_budget:
				break
			for dy in range(-yspan, yspan + 1):
				if submitted >= load_budget:
					break
				for dx in range(-rad, rad + 1):
					if submitted >= load_budget:
						break
					var ck := cam_ck + Vector3i(dx, dy, dz)
					# 统一距离→LOD 决策：近处（LOD0 带）加载全精度 chunk 数据；
					# 远处（粗层带）跳过 —— 那里的数据由 _process_lod_level 按带独立请求。
					if VoxelLodGrid.chunk_render_level(
							ck, cam_pos, world_offset, voxel_scale, _lod_outer, lod_count) > 0:
						continue
					# 存在性判定（廉价、无 IO）：流里已存 或 本层造得出
					if not data.can_supply_chunk(ck) or data.is_chunk_loaded(ck) or data.is_chunk_pending(ck, 0):
						continue
					if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > load_d:
						continue
					# 无限世界里已存过的 chunk（= 用户改过）：重新生成会覆盖修改 → 同步预载已存数据
					if data.infinite and data.is_stored(ck):
						if data.preload_chunk(ck):
							# 只登记给"会消费它的可见性模式"：该表的唯一消费 / 擦除点是
							# filter_chunks，而它在 FULL 下直接全量返回 —— 登记进去就是永久泄漏。
							if r.visibility_mode != VoxelRenderer.VisibilityMode.FULL:
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
	#    但卸载半径要比网格卸载半径外扩最粗层 block 的覆盖范围 —— 粗层降采样要读它覆盖的
	#    LOD0 chunk，卸早了降采样会读到假空块（见 lod0_data_unload_d）。
	if _frames_since_unload >= STREAM_UNLOAD_INTERVAL:
		_frames_since_unload = 0
		_apply_streaming_unload(data, cam_pos, chunk_size_world, world_offset, voxel_scale, lod_count, unload_d)

	if applied > 0 or submitted > 0:
		r.request_update()


## 卸载阶段（从 process_streaming 拆出，避免单个函数过长）。
## 顺序固定：先卸网格（半边依赖 has_chunk_mesh 判定），再卸数据，最后清粗层块与在途请求。
func _apply_streaming_unload(data: QVoxelSource, cam_pos: Vector3, chunk_size_world: float,
		world_offset: Vector3, voxel_scale: float, lod_count: int, unload_d: float) -> void:
	var coarse_level := maxi(lod_count - 1, 1)
	var block_edge_world := VoxelLodGrid.block_edge_world(coarse_level, voxel_scale)
	var unload_margin := VoxelLodGrid.margin(coarse_level, voxel_scale)
	var unload_block_extent := block_edge_world * 0.5
	var candidates: Array = []
	for ck in data.get_loaded_chunk_keys():
		var bk := VoxelLodGrid.block_of_chunk(ck, coarse_level)
		if VoxelLodGrid.block_dist(bk, coarse_level, cam_pos, world_offset, voxel_scale) \
				<= unload_d + unload_margin + unload_block_extent:
			continue
		var dist := VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset)
		if dist > unload_d:
			candidates.append([dist, ck])
	# 从远到近卸载：视觉上先消失的是最远处
	candidates.sort_custom(func(a, b): return a[0] > b[0])
	var unloaded := 0
	for item in candidates:
		if unloaded >= stream_unload_per_frame:
			break
		renderer.remove_chunk_mesh(item[1])
		unloaded += 1
	# LOD0 数据卸载：网格已卸掉、且超出外扩半径的 chunk 数据交还数据层
	# （修改过的写盘、变空的清盘、未修改且流里已有的直接丢弃）。
	var data_unload_d := lod0_data_unload_d()
	var data_unloaded := 0
	for item in candidates:
		if data_unloaded >= stream_unload_per_frame:
			break
		var ck: Vector3i = item[1]
		if renderer.has_chunk_mesh(ck):
			continue
		if VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) <= data_unload_d:
			continue
		if data.unload_chunk(ck):
			data_unloaded += 1
	# 取消超范围仍未完成的异步请求：编排器撤销登记后晚到的结果会被直接丢弃
	# （只删本地标记不够 —— 结果回来仍可能被 accept → 卸载后数据"复活"）。
	for ck_p in data.get_unready_chunk_keys(0):
		if VoxelWorldUtil.chunk_center_dist(ck_p, cam_pos, chunk_size_world, world_offset) > unload_d:
			data.cancel_chunk_request(ck_p, 0)
	# 清理超范围的粗层独立数据块（未修改可重新生成，修改的写盘）
	for lev in range(1, renderer.lod_level_count()):
		var edge_w := VoxelLodGrid.block_edge_world(lev, voxel_scale)
		for bk in data.get_lod_block_keys(lev):
			if VoxelLodGrid.block_dist(bk, lev, cam_pos, world_offset, voxel_scale) <= unload_d + edge_w * 0.5:
				continue
			if data.is_lod_block_modified(lev, bk):
				data.flush_lod_block(lev, bk)
			else:
				data.erase_lod_block(lev, bk)


## 动态原点重定位：相机 chunk 距数据基准超阈值时，平移数据层 + 渲染层 + 相机，
## 使相机附近 chunk 回到小坐标，避免 float32 精度损失（无限移动世界）。
func check_origin_shift(cam: Camera3D) -> void:
	var r := renderer
	if r == null or cam == null or r.data == null:
		return
	var chunk_size_world := r.voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam.global_position, chunk_size_world, r.global_position)
	var delta := cam_ck - _origin_chunk
	var shift := Vector3i.ZERO
	shift.x = delta.x - ORIGIN_SHIFT_THRESHOLD if delta.x >= ORIGIN_SHIFT_THRESHOLD \
			else (delta.x + ORIGIN_SHIFT_THRESHOLD if delta.x <= -ORIGIN_SHIFT_THRESHOLD else 0)
	shift.y = delta.y - ORIGIN_SHIFT_THRESHOLD if delta.y >= ORIGIN_SHIFT_THRESHOLD \
			else (delta.y + ORIGIN_SHIFT_THRESHOLD if delta.y <= -ORIGIN_SHIFT_THRESHOLD else 0)
	shift.z = delta.z - ORIGIN_SHIFT_THRESHOLD if delta.z >= ORIGIN_SHIFT_THRESHOLD \
			else (delta.z + ORIGIN_SHIFT_THRESHOLD if delta.z <= -ORIGIN_SHIFT_THRESHOLD else 0)
	if shift == Vector3i.ZERO:
		return
	# 三方必须同步：数据层键 / 渲染层键与节点位置 / 相机位置。漏任一方都会留下幽灵数据或幽灵网格。
	r.data.shift_origin(shift)
	_origin_chunk += shift
	r.shift_render(shift, chunk_size_world)
	shift_keys(shift)
	cam.global_position -= Vector3(shift) * chunk_size_world
	sync_cam_pos(cam.global_position)


## origin shift 后平移本层的坐标键账本（延迟队列 + 强制标记 + 块级调度账本）。
## 漏平移会让在途补建拿旧键比对 → 结果被误判过期丢弃，且标记永久停留在旧坐标系（无界增长）。
func shift_keys(shift: Vector3i) -> void:
	var ndf: Dictionary = {}
	for k in _deferred_chunks:
		ndf[Vector3i(k) + shift] = true
	_deferred_chunks = ndf
	_stream_force_build = VoxelChunk.shift_key_dict(_stream_force_build, shift)
	# 块级账本：整表按键平移（合并成一张表后只需一处）。index 0 是 chunk 层不记账。
	for level in range(1, _levels.size()):
		_levels[level] = VoxelChunk.shift_key_dict(_levels[level], shift)
	# 挂载队列里的 mesh 顶点已烘焙世界位置，平移会整体错位 → 直接丢弃重算。
	# 代价只是一次多余重建，且 origin shift 极少触发（相机跨越 256 chunk）。
	_lod_mesh_apply_queue.clear()
	_lod_mesh_apply_scheduled = false


# ── ④ LOD 分带调度 ──────────────────────────────────────────────────────────
# 各层严格在自身 band 内生成 / 保留：level 0 = 全精度 chunk 网格；level >= 1 = 粗层 block
# （覆盖 32×2^level 体素），band = (inner-margin, upper]（最粗层延伸至 unload），避免多层
# 重叠 z-fight。粗层 mesh 由工作线程构建，本层只做派发与帧尾限量挂载；网格节点的创建 /
# 释放 / 查询全在内核（见 VoxelRenderer 的 LOD 网格账本 API）。

## LOD 调度入口（宿主 _process 每帧调用；降频与失效直通在本方法内判定）。
## 降频：每 visibility_check_interval 帧跑一次；数据失效（破坏 / 编辑）时立即跑，
## 不等降频周期 → 破坏重建更及时。
## 【为什么 lod_count == 1 也必须跑】LOD0 chunk 网格的补建只在这里，跳过则画面空白。
func process_lod() -> void:
	var r := renderer
	_cull_check_counter += 1
	if r == null:
		return
	var data := r.data
	if data == null:
		return
	if _cull_check_counter < r.visibility_check_interval and not data.has_lod_invalidated():
		return
	_cull_check_counter = 0
	if not r.is_inside_tree():
		return
	var cam := r.current_camera()
	if cam == null or _lod_outer.is_empty():
		return
	var cam_pos := cam.global_position
	var world_offset := r.global_position
	var unload_d := unload_d()
	var n_levels := maxi(r.lod_count, 1)
	var cam_dir: Vector3 = -cam.global_transform.basis.z
	# 内存 chunk 键快照：多步骤同帧复用（一次分配），并在同一趟里算出数据范围。
	var loaded_chunks := data.get_loaded_chunk_keys()
	if not loaded_chunks.is_empty():
		_update_data_range(loaded_chunks)

	# 0. 数据变化 → 各粗层 block 失效重建（编辑 / 破坏触发）。
	#    不立即移除旧 mesh（防重建期间可见性振荡 → 闪烁）：标记重建并立即派发，
	#    新 mesh 就绪后复用节点替换（内带区 mesh 应用由 _should_apply_lod_mesh 丢弃，
	#    但数据仍同步更新）。
	for level in range(1, n_levels):
		var invalidated := data.get_invalidated_lod(level)
		if invalidated.is_empty():
			continue
		r.lod_materials(level, true)
		for bk in invalidated:
			_on_block_invalidated(data, level, bk, cam_pos)

	# 1. 各层：移除超出区间 / 生成带内缺失 / 可见性兜底（跨层共享构建预算）
	_lod_build_this_frame = 0
	_lod_submit_this_frame = 0
	# 程序化生成：粗层独立数据生成较慢（噪声），收紧每轮粗层 request 预算，
	# 让出 WorkerThreadPool 给 LOD0 chunk 生成（切换后快速看到地形，粗层随后补充）。
	var submit_budget := 40 if data.infinite else lod_submit_per_frame
	# 每层独立构建预算 = 总数均分（保证近层建完前更粗层也能推进，不被近层 in-flight
	# 队列饿死 —— 否则 LOD1 海量候选每轮占满共享配额，LOD2 永远 0 个 → 远处空洞）。
	var per_level_build := maxi(lod_build_per_frame / maxi(n_levels, 1), 4)
	for level in range(n_levels):
		if level == 0:
			_process_chunk_level(loaded_chunks, cam, cam_pos, world_offset, unload_d)
		elif level < lod_level_count():
			_process_coarse_level(level, cam, cam_pos, cam_dir, unload_d, world_offset,
					submit_budget, per_level_build)
	# 清理已完成粗层任务的 ID 累积（防 _coarse_task_ids 无限增长）
	trim_tasks()


## 数据 chunk 包围盒（needed 枚举剪枝用）。只枚举数据实际占用的 x/y/z 层，
## 跳过空气层 / 模型外空 block 的降采样派发 —— 这是 lod_count > 1 帧率骤降的主因。
func _update_data_range(loaded_chunks: Array) -> void:
	var bmin: Vector3i = loaded_chunks[0]
	var bmax: Vector3i = loaded_chunks[0]
	for ck in loaded_chunks:
		bmin = Vector3i(mini(bmin.x, ck.x), mini(bmin.y, ck.y), mini(bmin.z, ck.z))
		bmax = Vector3i(maxi(bmax.x, ck.x), maxi(bmax.y, ck.y), maxi(bmax.z, ck.z))
	_data_chunk_min = bmin
	_data_chunk_max = bmax
	_data_range_valid = true


## 单个失效 block 的重建派发（从 process_lod 的失效循环拆出）。
func _on_block_invalidated(data: QVoxelSource, level: int, bk: Vector3i, cam_pos: Vector3) -> void:
	# 失效 block 各自递增 block 级代次：只作废该 block 的在途任务，避免"任一失效就整层
	# 作废重派 → 该层所有在途任务丢弃重派"的连续破坏任务洪峰。
	var rec := _block_state(level, bk)
	rec[_K_GEN] = int(rec.get(_K_GEN, 0)) + 1
	rec[_K_REBUILD] = true
	rec.erase(_K_PENDING)
	var bdist := _block_dist(bk, level, cam_pos)
	var inner := _lod_outer[level - 1]
	var margin := _lod_margin(level)
	# 超出预生成范围：数据与渲染侧状态一并清掉（否则该 block 的账本条目永久残留）
	if bdist > _lod_outer[level] + margin + _lod_preload_extent(level):
		data.erase_lod_block(level, bk)
		remove_lod_block(level, bk)
		return
	# 【金字塔增量】coarse 已有缓存：数据层 patch 只重算脏大格（未脏复用），再派发 mesh
	# worker 从 coarse 生成（set_lod_block 已清 modified → 不走全量降采样）。
	# L1 从 L0 chunk 降采样；L2+ 逐级上推从上一层 coarse 降采样（省 64 倍 L0 读取）。
	if data.patch_lod_block(level, bk):
		if bdist >= inner - margin:
			_build_lod_block(level, bk)
		return
	if bdist < inner - margin:
		_build_lod_data_only(level, bk)
	else:
		_build_lod_block(level, bk)


## 取（必要时新建）某层某 block 的调度记录。合并表的唯一写入入口。
func _block_state(level: int, bk: Vector3i, create: bool = true) -> Dictionary:
	if level < 0 or level >= _levels.size():
		return {}
	var layer: Dictionary = _levels[level]
	var rec: Dictionary = layer.get(bk, {})
	if rec.is_empty() and create:
		rec = {}
		layer[bk] = rec
	return rec


## 粗层 block 是否处于失效重建中（破坏 / 编辑触发，保留旧 mesh 等待新 mesh 替换）。
func _lod_rebuilding(level: int, bk: Vector3i) -> bool:
	if level < 0 or level >= _levels.size():
		return false
	var rec: Dictionary = _levels[level].get(bk, {})
	return bool(rec.get(_K_REBUILD, false))


## 单个 LOD 层级管理：按 level 参数自动分流 ——
##   level 0 = 全精度 chunk 网格（见 _process_chunk_level）
##   level >= 1 = 粗层 block（覆盖 32×2^level 体素），每层严格在自身 band
##   （inner-margin, upper] 内生成 / 保留（最粗层延伸至 unload），避免多层重叠 z-fight。
func _process_coarse_level(level: int, cam: Camera3D, cam_pos: Vector3, cam_dir: Vector3,
		unload_d: float, world_offset: Vector3, submit_budget: int, build_quota: int) -> void:
	var r := renderer
	var data := r.data
	var inner := _lod_outer[level - 1]
	var outer := _lod_outer[level]
	var edge_world := _lod_block_edge_world(level)
	var margin := _lod_margin(level)
	var is_coarsest := level >= lod_level_count() - 1
	# 本层生成 / 保留上界：非最粗层 = outer+margin（之外由更粗层覆盖）；最粗层 = unload+半边
	var upper := (unload_d + edge_world * 0.5) if is_coarsest else (outer + margin)

	# 1a. 推导需要：按本层 band 直接枚举 block（粗层数据独立，无需从 LOD0 chunk 推导）。
	#   needed 存 block 中心的**平方**距离，1c 复用（只需要比较，故全程不开方）。
	var preload_d := _lod_preload_extent(level)
	var needed := {}
	var radius := outer + margin + preload_d
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, r.voxel_scale * VoxelChunk.CHUNK_SIZE, world_offset)
	var cam_bk := VoxelLodGrid.block_of_chunk(cam_ck, level)
	var r_bk := ceili(radius / edge_world) + 2
	var r2 := r_bk * r_bk
	var radius_sq := radius * radius
	# 三维剪枝：只枚举数据实际占用的 block 范围（球体全高大部分是空气层）。
	var lo := Vector3i(-r_bk, -r_bk, -r_bk)
	var hi := Vector3i(r_bk, r_bk, r_bk)
	if _data_range_valid:
		lo = Vector3i(maxi(lo.x, (_data_chunk_min.x >> level) - cam_bk.x),
				maxi(lo.y, (_data_chunk_min.y >> level) - cam_bk.y),
				maxi(lo.z, (_data_chunk_min.z >> level) - cam_bk.z))
		hi = Vector3i(mini(hi.x, (_data_chunk_max.x >> level) - cam_bk.x),
				mini(hi.y, (_data_chunk_max.y >> level) - cam_bk.y),
				mini(hi.z, (_data_chunk_max.z >> level) - cam_bk.z))
	# 平方距离预筛（避免 distance_to 的 sqrt）：先用整数 block 距离裁掉立方体角部，
	# 通过后再算一次实际欧氏距离缓存，供 1c 精确判定 / 排序复用。
	for dz in range(lo.z, hi.z + 1):
		var dzz := dz * dz
		for dy in range(lo.y, hi.y + 1):
			var dyz := dzz + dy * dy
			if dyz > r2:
				continue
			for dx in range(lo.x, hi.x + 1):
				if dyz + dx * dx > r2:
					continue
				var bk := cam_bk + Vector3i(dx, dy, dz)
				var dsq := (VoxelLodGrid.block_center(bk, world_offset, edge_world) - cam_pos).length_squared()
				if dsq <= radius_sq:
					needed[bk] = dsq

	# 1b. 移除 / 可见性（一趟）：遍历"已有 mesh 的 block"，同时决定"删不删"与"显不显"。
	# 【为什么合并】拆成两趟（先收集移除、再做可见性）会用 block_dist 重算一次开方距离
	# （本层每帧上千个 block × 两次 sqrt）。距离直接复用 1a 缓存的平方值，
	# 只有不在 needed 里的预加载常驻块才现算一次，全程不开方。
	# 移除条件：>unload 卸载；<inner-margin 进入内层带（内层就绪才移除）；
	# >upper+preload 且更粗层已就绪（预生成范围外不再常驻）。
	# 预生成范围（<= upper+preload_d）内的 block 即使更粗层就绪也保留 —— 它们作为
	# 预加载常驻（下面隐藏，进入带内时直接显示），消除切换真空。
	var unload_lim := unload_d + edge_world * 0.5
	var unload_sq := unload_lim * unload_lim
	var inner_lim_sq := _sq_limit(inner - margin)
	var upper_lim_sq := _sq_limit(upper + preload_d)
	var vis_inner_sq := _sq_limit(inner + margin)
	var vis_outer_sq := _sq_limit(outer + margin)
	for bk in r.lod_mesh_keys(level):
		# needed.get 而非 needed[bk]：不在 1a 枚举范围内的（远处/数据范围外的）块现算一次。
		var dsq: float = needed.get(bk, -1.0)
		if dsq < 0.0:
			dsq = _block_dist_sq(bk, level, cam_pos)
		if dsq > unload_sq \
				or (dsq < inner_lim_sq and _level_finer_ready(level, bk, cam)) \
				or (dsq > upper_lim_sq \
						and r.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1))):
			remove_lod_block(level, bk)
			continue
		var mi: MeshInstance3D = r.lod_mesh(level, bk)
		if mi == null:
			continue   # 空大块（无体素）
		# 失效重建中：冻结可见性 —— 破坏瞬间不因重建切换 LOD 层级（避免"不同层级闪烁"），
		# 新 mesh 就绪替换并清除重建标记后，下一轮按当前状态恢复正常可见性判定。
		if _lod_rebuilding(level, bk):
			continue
		if dsq < vis_inner_sq:
			mi.visible = not _level_finer_ready(level, bk, cam)
		elif dsq > vis_outer_sq \
				and r.has_lod_mesh(level + 1, Vector3i(bk.x >> 1, bk.y >> 1, bk.z >> 1)):
			mi.visible = false
		else:
			mi.visible = true

	# 1c. 带内缺失：数据未就绪 → 请求独立数据；就绪 → 派发 mesh（距离仍是 1a 的平方值）
	var to_build: Array = []
	for bk in needed:
		if r.has_lod_mesh(level, bk) and not _lod_rebuilding(level, bk):
			# 空标记（null mesh）但粗层数据已就绪 → 重建 mesh（数据生成晚于首次 mesh 尝试 ——
			# 否则粗层一直空标记，LOD0 移除后出现过渡空洞）。
			if r.lod_mesh(level, bk) != null or not data.has_lod_block(level, bk):
				continue
		var dsq: float = needed[bk]
		# 近处（LOD0 带内）的 block 由 LOD0 chunk 显示，不生成粗层 mesh ——
		# 否则与 1b 的"近处内层就绪→移除"形成"生成→移除→再生成"循环 → L0/L1 交替闪烁。
		if dsq < inner_lim_sq or (not data.has_lod_block(level, bk) and dsq > upper_lim_sq):
			continue
		# 修改过的 block 由降采样回退；未修改优先独立数据。
		# 流若无粗层独立数据能力（文件流 / 自定义流仅实现 lod=0 → request 无效果），
		# 则 request 后 is_chunk_pending 仍 false → 走降采样回退（保证任意流都出 LOD）。
		if not data.is_lod_block_modified(level, bk) and not data.has_lod_block(level, bk):
			# 文件流：直接降采样生成（一次完成，mesh + 数据缓存同步），不等异步两阶段 ——
			# 异步完成时机晚，近处粗层块长期无 mesh → 固定空洞。
			if data.stream != null and data.stream.supports_lod_layer():
				to_build.append([sqrt(dsq), bk])   # 排序键要真实距离，故此处开方一次
				continue
			if not data.is_chunk_pending(bk, level) and _lod_submit_this_frame < submit_budget:
				_lod_submit_this_frame += 1
				data.request_chunk_async(bk, level)
				if not data.is_chunk_pending(bk, level):
					_lod_submit_this_frame -= 1   # 流无粗层能力，request 无效果 → 回滚预算
			if data.is_chunk_pending(bk, level):
				continue   # 独立数据生成中，等待回填
		# 优先级在这里算一次并随元素携带，比较器只比数值（避免排序时重算三角运算）
		to_build.append([_lod_load_priority(bk, level, cam_pos, cam_dir), bk])
	to_build.sort_custom(func(a, b): return a[0] < b[0])
	if not to_build.is_empty():
		r.lod_materials(level, true)
	var built_this := 0
	for item in to_build:
		if built_this >= build_quota:
			break
		if _build_lod_block(level, item[1]):
			built_this += 1


# ── ④-b LOD0 chunk 层 ───────────────────────────────────────────────────────

## 可见性过滤：决定"这批 chunk 里哪些真的该建网格"（内核在全量构建与增量重建两条路径上
## 都先过这一关）。这是本层对内唯一被内核主动调用的查询，故语义必须与调度保持一致。
##
## 判据按顺序短路，顺序本身带含义：
##   · 无数据 → 剔除（否则会陷入"补建空 chunk → 三角 0 → 再标脏"的空转）
##   · STREAMING 且超卸载距离 → 剔除（数据由流式卸掉，走近再重载）
##   · 落在粗层带 → 剔除（该区域由粗层 mesh 覆盖；这里不清 _stream_force_build 之外
##     还要强行删标记，否则延迟队列的强制补建会在粗层带里反复唤醒 LOD0）
##   · 强制补建 → 保留（距离驱动，不再受视锥约束）
##   · LOD0 带内 → 保留（近处快速转向/后退不能出现空洞）
##   · 其余 → 视锥判定；视锥外进延迟队列等相机转向再补。
func filter_chunks(chunks: Array[Vector3i]) -> Array[Vector3i]:
	var r := renderer
	if r == null or r.visibility_mode == VoxelRenderer.VisibilityMode.FULL:
		return chunks
	var cam := r.current_camera()
	if cam == null:
		return chunks
	var data := r.data
	var voxel_scale := r.voxel_scale
	var world_offset := r.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var cam_pos := cam.global_position
	var unload_d := unload_d()
	var lod_count := r.lod_count
	var streaming := r.visibility_mode == VoxelRenderer.VisibilityMode.STREAMING
	# LOD0 显示区外边界。count=1 时 bands 给出 view_distance（LOD0 带 = [0, D]），
	# 故取 _lod_outer[0] 而非"count>1 否则 0"——否则 count=1 时"近处无条件构建"失效，
	# 视锥外 chunk 全被延迟，LOD0 只覆盖视锥内（表现为"越改视野越窄"）。
	if _lod_outer.is_empty():
		return chunks
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	var visible: Array[Vector3i] = []
	for ck in chunks:
		if data != null and not data.has_chunk(ck):
			continue
		if streaming and unload_d > 0.0 \
				and VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) > unload_d:
			continue
		if lod0_d > 0.0:
			if VoxelLodGrid.chunk_render_level(
					ck, cam_pos, world_offset, voxel_scale, _lod_outer, lod_count) > 0:
				_stream_force_build.erase(ck)
				continue
		if _stream_force_build.has(ck):
			_stream_force_build.erase(ck)
			visible.append(ck)
			continue
		if lod0_d > 0.0 \
				and VoxelLodGrid.block_dist(ck, 0, cam_pos, world_offset, voxel_scale) <= lod0_d + lod0_margin:
			visible.append(ck)
			continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			visible.append(ck)
		else:
			_deferred_chunks[ck] = true
	return visible


## 延迟队列晋升：视锥外的 chunk 在相机转向或走近后补建。
## 【限量】每轮最多晋升 stream_load_per_frame 个：走近时一次唤醒上千个待建 chunk 会让
## 主线程快照 + 生成 + GPU 上传同时爆发（实测 25 个渲染器 308ms/帧），必须摊平。
## 【先收集后修改】字典迭代期间增删会漏元素（别在循环体里直接 erase）。
## 【FULL 下直接返回】FULL 语义是全量构建，延迟队列不该有内容（on_visibility_mode_changed 已清）。
func process_deferred_chunks() -> void:
	var r := renderer
	if r == null or _deferred_chunks.is_empty():
		return
	if r.visibility_mode == VoxelRenderer.VisibilityMode.FULL:
		return
	var cam := r.current_camera()
	if cam == null:
		return
	var data := r.data
	var voxel_scale := r.voxel_scale
	var world_offset := r.global_position
	var cam_pos := cam.global_position
	var chunk_size_world := voxel_scale * VoxelChunk.CHUNK_SIZE
	var margin := r.view_distance
	var load_per_frame := stream_load_per_frame
	var iter := 0
	var to_build: Array = []
	var to_drop: Array = []
	for ck in _deferred_chunks:
		iter += 1
		if iter > load_per_frame * 8:
			break
		if to_build.size() >= load_per_frame:
			break
		# 已有网格（重复入队）或无数据的空 chunk（会空转重建）都不必补建，只清队列。
		if r.has_chunk_mesh(ck) or (data != null and not data.has_chunk(ck)):
			to_drop.append(ck)
			continue
		var aabb := VoxelWorldUtil.chunk_world_aabb(ck, chunk_size_world, world_offset)
		if not VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
			if not (margin > 0.0 \
					and VoxelWorldUtil.chunk_center_dist(ck, cam_pos, chunk_size_world, world_offset) <= margin):
				continue
		to_drop.append(ck)
		to_build.append(ck)
	for ck in to_drop:
		_deferred_chunks.erase(ck)
	if to_build.is_empty() or data == null:
		return
	for ck in to_build:
		# 强制构建标记：确保增量重建时不被视锥剔除再拦回延迟队列。
		_stream_force_build[ck] = true
		data.mark_chunk_dirty(ck)
	r.request_update()


## LOD0 chunk 层：按视距移除与补建全精度 chunk 网格。
## 补建分两支 —— 有已加载 chunk 键时遍历它（流式 / 有限世界），否则按相机半径枚举
## （程序化无限世界首次进入时数据层还没有任何 chunk，必须主动枚举才有东西可建）。
func _process_chunk_level(loaded_chunks: Array, cam: Camera3D, cam_pos: Vector3,
		world_offset: Vector3, unload_d: float) -> void:
	var r := renderer
	var data := r.data
	var lod0_d := _lod_outer[0]
	var lod0_margin := _lod_margin(0)
	# 移除超出 LOD0 带的 chunk 网格：
	#   · 对应粗层已就绪 → 移除（避免"先细后粗"残留）
	#   · 超出最粗层覆盖带 → 直接移除（该区域连粗层都不覆盖，视锥外不可见）
	# 阈值统一用 lod0_d + margin（与补建阈值一致），消除 (lod0_d, lod0_d+margin] 这段
	# 重叠区间的"移除→补建"每帧抖动 —— 那会让 _level_finer_ready 在就绪/未就绪间跳变，
	# 表现为 LOD1 块可见性闪烁（lod_count=2 时严重）。
	var remove_lod0: Array = []
	for ck in r.lod_mesh_keys(0):
		if _block_dist(ck, 0, cam_pos) <= lod0_d + lod0_margin:
			continue
		var level := _chunk_render_level(ck, cam_pos)
		if level > 0:
			var bk := VoxelLodGrid.block_of_chunk(ck, level)
			# 粗层 mesh 实际就绪（非空标记）才移除 LOD0：空标记表示粗层数据未就绪，
			# 此时保留 LOD0 兜底，避免边界出现过渡空洞。
			var coarse_mesh: MeshInstance3D = r.lod_mesh(level, bk)
			if coarse_mesh != null or _block_dist(bk, level, cam_pos) > _lod_outer[level] + _lod_margin(level):
				remove_lod0.append(ck)
		else:
			# 无更粗层覆盖（lod_count=1）：超出 LOD0 显示区即移除，否则残留旧网格。
			remove_lod0.append(ck)
	for ck in remove_lod0:
		r.remove_chunk_mesh(ck)
	if cam == null or data == null:
		return
	var chunk_world := r.voxel_scale * VoxelChunk.CHUNK_SIZE
	var radius_ck := ceili((lod0_d + lod0_margin) / chunk_world) + 1
	var cam_ck := VoxelWorldUtil.chunk_from_world(cam_pos, chunk_world, world_offset)
	var need_lod0_update := false
	if loaded_chunks.is_empty():
		# 移动后新区域：数据层尚未加载任何 chunk → 从相机位置枚举。
		# 否则 LOD0 chunk 永不 request → 近处空洞固定存在。
		for dx in range(-radius_ck, radius_ck + 1):
			for dy in range(-radius_ck, radius_ck + 1):
				for dz in range(-radius_ck, radius_ck + 1):
					var ck: Vector3i = cam_ck + Vector3i(dx, dy, dz)
					if r.has_lod_mesh(0, ck):
						continue
					if _block_dist(ck, 0, cam_pos) > lod0_d + lod0_margin:
						continue
					# 该立方体以**相机**为心枚举，与数据实际范围无关。有界模型（PCG 场景里
					# 单个 32³ 模型）只有 1 个 chunk 在生成范围内，其余上万键都是"取不到数据"的
					# 幻影：照标脏会永久滞留数据层脏账，真正有几何的 chunk 淹没其中永不建网格
					# （实测 25 个渲染器 308ms/帧）。用存在性判定（廉价无 IO）先剪枝。
					if not data.can_supply_chunk(ck):
						continue
					if not data.has_chunk(ck):
						data.request_chunk_async(ck, 0)
					data.mark_chunk_dirty(ck)
					need_lod0_update = true
	else:
		for ck in loaded_chunks:
			if absi(ck.x - cam_ck.x) > radius_ck or absi(ck.y - cam_ck.y) > radius_ck \
					or absi(ck.z - cam_ck.z) > radius_ck:
				continue
			if r.has_lod_mesh(0, ck):
				continue
			if _block_dist(ck, 0, cam_pos) > lod0_d + lod0_margin:
				continue
			# 粗层带的 chunk 由对应粗层 block 覆盖，不标 LOD0 脏 ——
			# 否则补建→转交粗层→无 L0 mesh→再补建死循环，且 _level_finer_ready
			# 会把它当"重建中就绪"→ L1 隐藏 → LOD0/LOD1 交界空洞。
			if _chunk_render_level(ck, cam_pos) > 0:
				continue
			data.mark_chunk_dirty(ck)
			need_lod0_update = true
	if need_lod0_update:
		r.request_update()


## 见 VoxelLodGrid.chunk_render_level（几何数学归 VoxelLodGrid，此处只补本层持有的内核参数）。
func _chunk_render_level(ck: Vector3i, cam_pos: Vector3) -> int:
	return VoxelLodGrid.chunk_render_level(ck, cam_pos, renderer.global_position,
			renderer.voxel_scale, _lod_outer, renderer.lod_count)


## 本层 block 的覆盖区域在内层（level-1）是否已全部就绪（有网格或为空）。
## level 1 的内层 = chunk（level 0）；只统计视锥内的（视锥外不显示，不该阻塞）。
## 【为什么这么绕】内层 chunk 若"正在重建"（在构建队列 / 数据层标脏）且确实属于 LOD0 带，
## 应视为就绪 —— 否则破坏瞬间内层短暂未就绪会让粗层临时顶上来，LOD 边界来回移动 → 闪烁。
## 但属粗层带的 chunk（L0 永不构建）不能当成就绪，否则粗层被隐藏 → 交界处背景透出空洞。
func _level_finer_ready(level: int, bk: Vector3i, cam: Camera3D) -> bool:
	if level <= 0:
		return true
	var r := renderer
	var data := r.data
	var fine := level - 1
	var chunk_world := r.voxel_scale * VoxelChunk.CHUNK_SIZE
	for k in 2:
		for j in 2:
			for i in 2:
				var sbk := Vector3i(bk.x * 2 + i, bk.y * 2 + j, bk.z * 2 + k)
				# 粗层 block 的空标记（null，数据/网格未就绪）不算就绪 → 更粗层兜底显示。
				if fine == 0:
					if r.has_lod_mesh(fine, sbk):
						continue
					if data == null:
						continue
					if data.has_chunk(sbk):
						if r.is_mesh_build_queued(sbk) or data.is_chunk_mesh_dirty(sbk):
							if _chunk_render_level(sbk, cam.global_position) == 0:
								continue
						var aabb := VoxelWorldUtil.chunk_world_aabb(sbk, chunk_world, r.global_position)
						if VoxelWorldUtil.aabb_has_vertex_in_frustum(aabb, cam):
							return false
				else:
					if r.lod_mesh(fine, sbk) == null:
						return false
	return true


## 粗层生成优先级：距离 + 视线方向加权（前方先生成）。返回值越小越优先。
func _lod_load_priority(bk: Vector3i, level: int, cam_pos: Vector3, cam_dir: Vector3) -> float:
	var center := VoxelLodGrid.block_center(bk, renderer.global_position, _lod_block_edge_world(level))
	var to_center := center - cam_pos
	var dist := to_center.length()
	if dist < 0.001:
		return 0.0
	return dist - to_center.normalized().dot(cam_dir) * dist * 0.5


## 派发粗层 block 的完整生成（数据 + mesh）。
## 数据快照**在主线程构造**后交给 worker：worker 只读快照，绝不触碰 QVoxelSource 的活动
## 字典/缓冲（无跨线程读取）；数据来源也由主线程判定 —— 独立粗层大格自足就直接网格化，
## 否则回退 LOD0 降采样。
## 返回是否真的派发（已 pending / level 越界时 false，调用方据此决定是否消耗构建预算）。
func _build_lod_block(level: int, bk: Vector3i) -> bool:
	var data := renderer.data if renderer != null else null
	if data == null:
		return false
	if level < 1 or level >= _levels.size():
		return false
	var rec := _block_state(level, bk)
	if rec.get(_K_PENDING, false):
		return false
	rec[_K_PENDING] = true
	# 快照句柄随任务走到底、由回调释放：不依赖 LIFO 配对，故与渲染批次的快照并发也安全。
	var handle := data.begin_readonly_snapshot()
	var standalone := data.can_mesh_lod_block_standalone(level, bk)
	var snapshot := data.read_lod_block_data_snapshot(bk, level) if standalone \
			else data.read_lod_block_chunk_snapshot(bk, level, true)
	# 【材质数组不拷贝】duplicate() 一轮可派 200 个粗层任务，就是 200 份整数组拷贝，只为让
	# worker 读到"派发那一刻的值"。而副本能提供的保证（在途期间内容不被改写）已由
	# VoxelMaterialCache 的"重建即换数组对象"提供（见 aligned_shared 的契约）。
	# 故直接传共享引用：worker 只读，零分配。
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_build.bind(
		snapshot, standalone, bk, level, int(rec.get(_K_GEN, 0)), renderer.voxel_scale,
		data.center_offset, renderer.lod_materials(level), renderer.surface_materials(), handle)))
	return true


## 内带失效 block（LOD0 显示区）：只降采样同步粗层数据（缓存 + 持久化）。
## mesh 由 LOD0 chunk 反映，粗层 mesh 应用会被 _should_apply_lod_mesh 丢弃 ——
## 拆两阶段就是为了不白跑一个生成完整粗层 mesh 的 worker。
func _build_lod_data_only(level: int, bk: Vector3i) -> void:
	var data := renderer.data if renderer != null else null
	if data == null or level < 1 or level >= _levels.size():
		return
	var rec := _block_state(level, bk)
	if rec.get(_K_PENDING, false):
		return
	rec[_K_PENDING] = true
	var handle := data.begin_readonly_snapshot()
	var snapshot := data.read_lod_block_chunk_snapshot(bk, level, false)
	_coarse_task_ids.append(WorkerThreadPool.add_task(_lod_worker_data_only.bind(
		snapshot, bk, level, int(rec.get(_K_GEN, 0)), handle)))


## 工作线程：粗层大块 mesh 生成。只读主线程构造好的数据快照，不触碰 QVoxelSource。
##   standalone=true ：快照是独立粗层大格数据（直接网格化，无降采样）
##   standalone=false：快照是 LOD0 chunk 缓冲（降采样），顺带回传大格数据供粗层缓存复用
## 【必须防空 halo】空快照 / 边界数据不全是**正常情况**（LOD0 还没加载完）。
## 原生那时返回空 halo，直接 extract_center_from_halo 会越界崩溃 —— 按空结果回报，
## 让主线程走重试计数（_lod_mark_null_or_retry）。
func _lod_worker_build(snapshot: Dictionary, standalone: bool, bk: Vector3i, level: int,
		gen_id: int, scale: float, offset: Vector3, aligned_materials: Array,
		surface_materials: Array, handle: QVoxelSource.ReadonlySnapshot) -> void:
	var halo: PackedInt32Array
	var buf := PackedInt32Array()
	if standalone:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(snapshot, bk)
	else:
		halo = VoxelChunkGenerator.build_lod_block_halo_from_buffers(snapshot, bk, level)
	if halo.size() != VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		call_deferred("_on_lod_worker_done", bk, level, null, gen_id, PackedInt32Array(), handle)
		return
	if not standalone:
		buf = VoxelChunk.extract_center_from_halo(halo)
	var arrays := VoxelChunkGenerator.generate_lod_block_arrays(
		halo, aligned_materials, scale, bk, offset, level)
	# 【材质必须在建 mesh 的同一处一起绑，不能回主线程按桶序号补】append_arrays_to_mesh 会
	# **跳过空桶**，故"只有透明体素"的大块（玻璃/水面）唯一 surface 是 trans；挂载点若按
	# "surface 0=实心、surface 1=透明"补绑，它会被绑成实心材质 → 整块不透光且不报错。
	# 这里传 surface_materials 由 append_arrays_to_mesh 按**实际 surface 序号**绑，与
	# per-chunk 路径（VoxelRenderer._apply_built_chunk）同一条不变式。
	# 与 aligned_materials 的区别：aligned 是"索引==材质ID"（生成几何用），surface 是运行期
	# Material 对象（绑定用），两者不能互换。
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arrays, surface_materials)
	call_deferred("_on_lod_worker_done", bk, level, mesh, gen_id, buf, handle)


## 工作线程：内带失效 block 只降采样大格数据（不生成 mesh —— mesh 由 LOD0 chunk 反映）。
func _lod_worker_data_only(buffers: Dictionary, bk: Vector3i, level: int, gen_id: int,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, bk, level)
	if halo.size() != VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		call_deferred("_on_lod_data_ready", bk, level, gen_id, PackedInt32Array(), handle)
		return
	var buf := VoxelChunk.extract_center_from_halo(halo)
	call_deferred("_on_lod_data_ready", bk, level, gen_id, buf, handle)


## 清除某层某 block 的空结果重试计数。
func _clear_null_retry(level: int, bk: Vector3i) -> void:
	if level > 0 and level < _levels.size():
		_levels[level].get(bk, {}).erase(_K_RETRY)


## 降采样结果为空时的善后：确定空 → 一次设空标记（防重复派发）；数据未就绪 → 重试计数。
## 【为什么必须区分】确定空（区域外 / 空气层）若不设标记，会反复派发降采样占满 worker，
## lod_count>1 时帧率骤降；而"数据未就绪"若是设了标记，LOD0 数据到位后也不会重建 →
## 洞永远在。故前者设标记、后者有限重试，超限才设标记兜底。
func _lod_mark_null_or_retry(level: int, bk: Vector3i) -> void:
	var r := renderer
	var data := r.data if r != null else null
	var definitely_empty := true
	var base := bk * (1 << level)
	var span := 1 << level
	for cz in span:
		for cy in span:
			for cx in span:
				if data != null and data.is_chunk_loaded(base + Vector3i(cx, cy, cz)):
					definitely_empty = false
					break
			if not definitely_empty:
				break
		if not definitely_empty:
			break
	if r == null:
		return
	var rec := _block_state(level, bk)
	if data == null or definitely_empty:
		rec.erase(_K_RETRY)
		r.mark_lod_block_empty(level, bk)
		return
	var retries := int(rec.get(_K_RETRY, 0))
	if retries >= LOD_NULL_RETRY_LIMIT:
		rec.erase(_K_RETRY)
		r.mark_lod_block_empty(level, bk)
	else:
		rec[_K_RETRY] = retries + 1


## 主线程：内带失效 block 的降采样数据回填（mesh 由 LOD0 chunk 反映，不挂载）。
func _on_lod_data_ready(bk: Vector3i, level: int, gen_id: int, buf: PackedInt32Array,
		handle: QVoxelSource.ReadonlySnapshot) -> void:
	# 释放本任务自己的快照句柄（必须在任何早退之前）。
	if handle != null:
		handle.release()
	if _exiting or level < 1 or level >= _levels.size():
		return
	var r := renderer
	var rec := _block_state(level, bk)
	rec.erase(_K_PENDING)
	if r == null or int(rec.get(_K_GEN, 0)) != gen_id:
		return
	if buf.size() > 0 and r.data != null:
		r.data.store_lod_block(level, bk, buf)
	else:
		_lod_mark_null_or_retry(level, bk)
	# 数据已同步（mesh 由 LOD0 chunk 反映），解除重建标记防重复派发。
	rec.erase(_K_REBUILD)


## 主线程：粗层 mesh 结果。校验代次后入队，由帧尾限量挂载 ——
## mesh 已在 worker 构建成 ArrayMesh，这里只做轻量挂载，避免主线程同步构建大 mesh 卡顿。
## 降采样回退路径会顺带返回大格数据 buf，同步粗层缓存（+ 持久化），避免缓存缺口。
func _on_lod_worker_done(bk: Vector3i, level: int, mesh: ArrayMesh, gen_id: int,
		buf: PackedInt32Array = PackedInt32Array(),
		handle: QVoxelSource.ReadonlySnapshot = null) -> void:
	if handle != null:
		handle.release()
	if _exiting or level < 1 or level >= _levels.size():
		return
	var r := renderer
	if r == null:
		return
	var data := r.data
	var rec := _block_state(level, bk)
	rec.erase(_K_PENDING)
	if int(rec.get(_K_GEN, 0)) != gen_id:
		return
	# 仅 mesh 非空（真有体素）才写缓存：真空 block 写全 0 buffer 会让 has_lod_block=true，
	# 于是"数据就绪但 mesh 空"→ 每帧重新派发 → 死循环占满跨层构建预算，更粗层永远
	# 分不到（远处空洞）。
	if buf.size() > 0 and data != null and mesh != null and mesh.get_surface_count() > 0:
		data.store_lod_block(level, bk, buf)
	if r.has_lod_mesh(level, bk) and not bool(rec.get(_K_REBUILD, false)):
		return
	if mesh == null or mesh.get_surface_count() == 0:
		# 降采样为空：多为 LOD0 数据未就绪（快照空）→ 不设空标记，移除条目让后续重试。
		# 否则空标记会让 _process_coarse_level 跳过该 block，LOD0 数据就绪后也不重建 → 洞永远。
		if bool(rec.get(_K_REBUILD, false)):
			remove_lod_block(level, bk)
		rec.erase(_K_REBUILD)
		_lod_mark_null_or_retry(level, bk)
		if r.has_lod_mesh(level, bk) and r.lod_mesh(level, bk) == null:
			return   # 已设真空标记 → 停止派发
		r.clear_lod_mesh(level, bk)   # 重试中 → 移除条目，下一轮重新派发降采样
		return
	_lod_mesh_apply_queue.append({"level": level, "key": bk, "mesh": mesh})


## 帧尾挂载排期：有排队结果且未排期时置位并返回 true（内核据此 call_deferred 转发）。
## 【为什么排期标记在本层而 deferred 目标在内核节点】标记必须与队列同处一地才不会重复排期；
## 而 call_deferred 只能挂在 Node 上 —— 由内核转发即借用了它的生命周期（节点释放时
## 引擎自动丢弃排期）。本类也是 Node3D，本可直接 call_deferred，但把"何时调度"统一
## 留在内核一处，是为了让所有帧尾预算（网格上传 / 粗层挂载）只有一个发起者。
func take_lod_mesh_flush_request() -> bool:
	if _lod_mesh_apply_queue.is_empty() or _lod_mesh_apply_scheduled:
		return false
	_lod_mesh_apply_scheduled = true
	return true


## 帧尾限量挂载粗层 mesh（GPU 上传摊平到多帧）。
## 【为什么用写指针压缩而不是 remove_at】remove_at(i) 每次都搬尾部元素，队列几十上百项时
## 是 O(n²) 的搬移；写指针压缩一遍过，且保留未处理项的相对顺序。
## 【不能 call_deferred 自续】MessageQueue.flush 会把 flush 期间新推入的调用在同帧继续
## 执行 —— 自续等于同帧反复进本函数直至清空，数量与毫秒预算双双失效（网格上传队列
## 有过同一个教训）。
func process_lod_mesh_apply_queue() -> void:
	_lod_mesh_apply_scheduled = false
	if _lod_mesh_apply_queue.is_empty():
		return
	var r := renderer
	if r == null:
		_lod_mesh_apply_queue.clear()
		return
	var t0 := Time.get_ticks_usec()
	var built := 0
	var write := 0
	var total := _lod_mesh_apply_queue.size()
	var exhausted := false
	for read in total:
		var item: Dictionary = _lod_mesh_apply_queue[read]
		if not exhausted and (built < lod_build_per_frame \
				and (Time.get_ticks_usec() - t0) / 1000.0 <= lod_apply_budget_ms):
			var level: int = item["level"]
			var bk: Vector3i = item["key"]
		# 重新校验区间（结果排队期间相机可能移动）。
			if _should_apply_lod_mesh(level, bk):
				r.mount_lod_mesh(level, bk, item["mesh"])
				# 挂载成功：解除重建标记与空结果重试计数（新 mesh 已就位，旧状态作废）。
				var rec := _block_state(level, bk)
				rec.erase(_K_REBUILD)
				rec.erase(_K_RETRY)
				built += 1
			elif _lod_rebuilding(level, bk):
				# 内带丢弃（该区域由 LOD0 反映）：数据已同步，解除重建标记防重复派发。
				_block_state(level, bk).erase(_K_REBUILD)
			continue
		# 保留未处理项（预算用尽或已越界），下帧继续。
		_lod_mesh_apply_queue[write] = item
		write += 1
	if write < total:
		_lod_mesh_apply_queue.resize(write)
	if r.diag_enabled and built > 0:
		print("[诊断] LOD大块挂载批处理: %d 个, 剩余%d" % [built, _lod_mesh_apply_queue.size()])


## 粗层 block 是否仍在显示区间（挂载前校验，相机移动后过期结果丢弃）。
## 失效重建的 block 强制应用（替换旧 mesh 才能反映破坏）：近处内带由 _level_finer_ready
## （重建中视为就绪）隐藏本层，故不产生层级切换；远处粗层区替换后显示含洞网格。
func _should_apply_lod_mesh(level: int, bk: Vector3i) -> bool:
	var r := renderer
	if r == null or level < 1 or level >= lod_level_count():
		return false
	var rebuilding := _lod_rebuilding(level, bk)
	if r.has_lod_mesh(level, bk) and not rebuilding:
		return false
	var cam := r.current_camera()
	if cam == null:
		return false
	var edge_world := _lod_block_edge_world(level)
	var dist := _block_dist(bk, level, cam.global_position)
	var inner := _lod_outer[level - 1]
	var margin := _lod_margin(level)
	if rebuilding:
		# 只替换粗层带内的块；内带不替换（粗层在那里隐藏，由 LOD0 反映洞），
		# 避免"LOD0 细洞先出现 → 粗层粗洞后替换"的先后交替闪烁。
		return dist > inner - margin and dist <= unload_d() + edge_world * 0.5
	# 粗层数据已就绪：内带也挂载（mesh 预生成 —— LOD0 移除后粗层直接顶上，防块状空洞；
	# 可见性由 _process_coarse_level 的 _level_finer_ready 控制，LOD0 就绪即隐藏本层，无重叠）。
	if r.data != null and r.data.has_lod_block(level, bk):
		return dist <= unload_d() + edge_world * 0.5
	return not (dist < inner - margin or dist > unload_d() + edge_world * 0.5)


## 移除指定粗层的 block（网格节点由内核释放，本层只清自己的调度账本）。
## level 0 不走这里 —— LOD0 的移除是内核 remove_chunk_mesh，语义不同（含碰撞与延迟队列）。
func remove_lod_block(level: int, bk: Vector3i) -> void:
	if level < 1:
		return
	if renderer != null:
		renderer.clear_lod_mesh(level, bk)
	_clear_block_state(level, bk)


## 清除某层 block 的调度账本。一张表下清账只需一次 erase ——
## 四张平行表时漏清一张就随探索范围无界增长。
func _clear_block_state(level: int, bk: Vector3i) -> void:
	if level < 1 or level >= _levels.size():
		return
	_levels[level].erase(bk)


## 见 VoxelLodGrid.block_dist。
func _block_dist(bk: Vector3i, level: int, cam_pos: Vector3) -> float:
	return VoxelLodGrid.block_dist(bk, level, cam_pos, renderer.global_position, renderer.voxel_scale)


## 见 VoxelLodGrid.block_dist_sq。
func _block_dist_sq(bk: Vector3i, level: int, cam_pos: Vector3) -> float:
	return VoxelLodGrid.block_dist_sq(bk, level, cam_pos, renderer.global_position, renderer.voxel_scale)


## 半径平方，负数夹到 0（LOD 分带里 inner-margin / upper+preload 理论上可能为负，
## 平方后会变成一个大正数，把"永不满足"变成"总是满足" —— 夹到 0 保持语义）。
static func _sq_limit(radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	return radius * radius


## 见 VoxelLodGrid.margin。
func _lod_margin(level: int) -> float:
	return VoxelLodGrid.margin(level, renderer.voxel_scale)


## 见 VoxelLodGrid.block_edge_world。
func _lod_block_edge_world(level: int) -> float:
	return VoxelLodGrid.block_edge_world(level, renderer.voxel_scale)


## 见 VoxelLodGrid.preload_extent（提前量旋钮由本层自持）。
func _lod_preload_extent(level: int) -> float:
	return VoxelLodGrid.preload_extent(level, renderer.voxel_scale, lod_preload_blocks)
