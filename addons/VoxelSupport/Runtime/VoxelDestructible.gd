@tool
class_name VoxelDestructible
extends Node3D

## 动态体素破坏系统 —— **组件形态**：挂在 [VoxelRenderer] 下当子节点，而不是继承它。

## 破坏反馈信号：具体表现（粒子/音效/震动）由游戏自行连接实现
signal voxel_damaged(positions: Array, spawn_debris: bool)      ## 体素被移除时 (含崩塌)
signal voxel_hardened_batch(positions: Array, remaining: Dictionary) ## 批量硬化（帧尾合并发射，避免逐体素高频信号）
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

# ── 宿主绑定（组件形态的核心）────────────────────────────────────────────

## 宿主渲染器（只读）。
var host: VoxelRenderer = null

## 绑定宿主渲染器。
func configure(host_ref: VoxelRenderer) -> void:
	host = host_ref
	# 表现层也要换宿主：它本身是本组件的子节点，但它的 host 是**渲染器**（要读 voxel_scale /
	if _presenter_impl != null:
		_presenter_impl.host = host_ref
	# 记录当前的数据基准，避免把"绑定前就已发生的 origin shift"误判成一次新平移
	_last_origin_chunk = _host_origin_chunk()
	if host != null and host.draw_mode != VoxelRenderer.DrawMode.DYNAMIC:
		push_warning("[VoxelDestructible] 宿主 draw_mode 不是 DYNAMIC：破坏将触发整份模型重建"
				+ "（STATIC 下改一个体素实测 22.7~85ms）。请设 host.draw_mode = VoxelRenderer.DrawMode.DYNAMIC。")

# ── 宿主属性的只读镜像 ─────────────────────────────────────────────────

## 体素数据（只读镜像 host.data）。
var data: QVoxelSource:
	get:
		return host.data if host != null else null

## 诊断开关（只读镜像 host.diag_enabled）。
var diag_enabled: bool:
	get:
		return host.diag_enabled if host != null else false

## 宿主的数据基准 chunk（视点层持有；没挂视点层时基准恒为 ZERO）。
func _host_origin_chunk() -> Vector3i:
	if host == null or host.view_layer == null:
		return Vector3i.ZERO
	return host.view_layer.origin_chunk()

## 硬化反馈缓冲：pos -> remaining，_process 帧尾合并发 voxel_hardened_batch
var _hardened_buffer: Dictionary = {}
var _hardened_dirty: bool = false

## 编辑内核：伤害结算 / 应力传播 / 失稳检测的**纯编辑数学**。
var _edit := VoxelEditKernel.new()

## 破坏表现层：粒子碎片 / 掉落物理由它演出，宿主只产出数据并委托。
var _presenter_impl: VoxelDestructionPresenter

var _presenter: VoxelDestructionPresenter:
	get:
		if _presenter_impl == null:
			_presenter_impl = VoxelDestructionPresenter.new(host)
			_presenter_impl.name = "_VoxelDestructionPresenter"
			add_child(_presenter_impl, false, Node.INTERNAL_MODE_BACK)
		elif _presenter_impl.host != host:
			# 宿主在表现层创建之后才绑定（先 new 表现层再 configure）→ 就地补上，不必重建节点
			_presenter_impl.host = host
		return _presenter_impl

## 崩塌掉落模式枚举
enum CollapseMode {
	COLLAPSE_NONE,   ## 不启用悬空崩塌
	COLLAPSE_DEBRIS, ## 悬空体素转成粒子碎片掉落
}

## 破坏时是否生成碎片
@export var spawn_debris_on_damage: bool = true:
	set(v):
		spawn_debris_on_damage = v
		# 影响 debris 系列属性有效性 → 刷新 Inspector 隐藏/显示
		notify_property_list_changed()

## Inspector 动态可见性：条件不生效时隐藏对应属性。
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property["name"]
	if not spawn_debris_on_damage:
		match name:
			&"max_debris_per_hit", &"debris_speed_range", &"debris_lifetime", &"debris_gravity_scale":
				# 碎片关闭时碎片数量/速度/寿命/重力参数无效
				property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR

## 单次破坏生成的最大碎片数量 (性能保护)
@export var max_debris_per_hit: int = 16

## 崩塌掉落模式
@export var collapse_mode: CollapseMode = CollapseMode.COLLAPSE_DEBRIS

## 局部增量崩塌检测：只检查破坏位置 6 邻附近可能失稳的体素
@export var local_collapse: bool = true

## 逐体素健康度系统开关：关闭时忽略材质硬度，一击即碎
@export var use_voxel_health: bool = true

## 单次破坏对每个体素造成的伤害 (逐体素健康度用)
@export var damage_per_voxel: float = 1.0

## 碎片粒子初始速度范围（Vector2 = [最小, 最大]，基准值，受材质 mass 影响）
@export var debris_speed_range: Vector2 = Vector2(2.0, 6.0)

## 碎片粒子生命周期 (秒)（基准值，受材质 mass 影响）
@export var debris_lifetime: float = 3.0

## 碎片粒子重力倍数（基准值，受材质 mass 影响）
@export var debris_gravity_scale: float = 1.0

## 【不要加整体健康度】`@export var health`（-1 = 不启用）会是第二套耐久模型：每移除

## 应力传播（裂纹扩散）距离（步数），即裂纹最多扩散多少层
@export_range(1, 10) var stress_max_steps: int = 3

## 每次破坏产生的应力大小（与材质 connection_strength 比较决定是否断裂）
@export var stress_force: float = 15.0

## 应力衰减系数（每传播一步应力的衰减比例）
@export_range(0.0, 1.0) var stress_decay: float = 0.5

## 监控统计
var last_damage_count: int = 0     ## 最近一次破坏实际移除的体素数
var last_collapse_count: int = 0   ## 最近一次崩塌的悬空体素数

## 逐体素累计伤害账**不在这里**：它归 QVoxelSource（体素相邻状态，必须与 chunk 缓冲同生共死——

## 破坏形状常量（对应原生 damage_shape 的 shape 参数）
const SHAPE_SPHERE: int = 0
const SHAPE_BOX: int = 1

## 延迟移除状态：同一帧内多次伤害的位置合并去重，下一帧统一处理
var _pending_removed: Dictionary = {}  # key: Vector3i(pos), value: bool(spawn_debris)
var _pending_spawn_debris: bool = false

## 粒子对象池 / 淡出渐变 / 碎片根节点 / 掉落物理（对象池、在途队列、生命周期账本）

## 级联崩塌状态：逐帧处理，每帧只处理一个级联层级
var _cascade_check_positions: Array = []  # 待检查的体素位置（下一级联层级）
var _cascade_total: Array = []            # 所有级联累积的失稳体素

## 级联分帧化：大面积崩塌（数万体素）时，单帧处理全部体素会造成主线程
const MAX_CASCADE_VOXELS_PER_FRAME: int = 4096
## 分帧处理剩余待移除体素（尚未分组/移除的失稳体素）
var _cascade_pending_voxels: Array = []

## 掉落物生成模式（统一"小块粒子/大块物理体"的分档策略）
enum FallingMode {
	AUTO,     ## 自动按体素数分档：小碎块转粒子，中块 Box 碰撞，大块凸包碰撞（推荐）
	PARTICLE, ## 全部转 GPU 粒子（零物理开销，视觉最轻量）
	PHYSICS,  ## 全部物理体（Box/凸包碰撞，保留整块碎裂的物理感）
}

## 掉落物生成模式（见 FallingMode）
@export var falling_mode: FallingMode = FallingMode.AUTO

## 物理掉落体对象池大小：同时最多存在的活动 RigidBody3D 数量。
@export_range(8, 512) var falling_chunk_pool_size: int = 64

## 掉落块最大存活数量（超出后最早冻结的块被移除，防止长时间破坏后物理体无限堆积拖慢帧率）
@export_range(20, 2000) var max_falling_chunks: int = 200

## 掉落块冻结后的最长保留时间（秒），到期后自动移除（已经落地静止，视觉任务完成）
@export_range(1.0, 60.0) var falling_chunk_cleanup_time: float = 6.0

## 掉落块落地静置检测时间累计 (秒)
var _sleep_check_counter: float = 0.0

## 就绪：惰性绑定父节点宿主 + 让表现层准备好碎片根节点。
func _ready() -> void:
	if host == null and get_parent() is VoxelRenderer:
		configure(get_parent() as VoxelRenderer)
	if not Engine.is_editor_hint():
		_presenter.ensure_debris_root()
		# 不再做初始全量稳定性校验：浮空结构默认保持稳定，失稳只由破坏逻辑

func _exit_tree() -> void:
	# 直接用 _presenter_impl（不触发惰性创建）：退出期不该再新建节点。
	if _presenter_impl != null:
		_presenter_impl.shutdown()
	# 【改造前这里是 super._exit_tree()】那部分归渲染器了：等待在途 mesh worker、置 _exiting、

## origin shift 钩子：把本组件持有的**体素坐标**在途队列一起平移。
func on_origin_shift(shift: Vector3i) -> void:
	_pending_removed = VoxelChunk.shift_key_dict(_pending_removed, shift)
	_hardened_buffer = VoxelChunk.shift_key_dict(_hardened_buffer, shift)
	_cascade_check_positions = VoxelChunk.shift_positions(_cascade_check_positions, shift)
	_cascade_pending_voxels = VoxelChunk.shift_positions(_cascade_pending_voxels, shift)
	_cascade_total = VoxelChunk.shift_positions(_cascade_total, shift)
	if _presenter_impl != null:
		_presenter_impl.on_origin_shift(shift)

## 上次看到的宿主数据基准 chunk（见 on_origin_shift 的"为什么改由本组件自己发现"）。
var _last_origin_chunk: Vector3i = Vector3i.ZERO

## 轮询宿主的数据基准 chunk，若发生 origin shift 就平移本组件的在途队列。
func _sync_origin_shift() -> void:
	if host == null:
		return
	var cur: Vector3i = _host_origin_chunk()
	if cur == _last_origin_chunk:
		return
	var shift := cur - _last_origin_chunk
	_last_origin_chunk = cur
	on_origin_shift(shift)

# 破坏入口

## 球形破坏: 对中心点半径内的体素造成伤害
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	# 一趟原生内核完成：范围 → 材质 → 硬度比较 → 累伤 / 判移除（伤害结算下沉原生，语义不变）
	var removed := _apply_damage_native(SHAPE_SPHERE, center, radius, Vector3i.ZERO, Vector3i.ZERO)
	# 2. 合并去重：同一帧内多次伤害相同位置只处理一次
	if not removed.is_empty():
		for pos in removed:
			_pending_removed[pos] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return removed

## 盒形破坏
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mn := Vector3i(floori(aabb.position.x), floori(aabb.position.y), floori(aabb.position.z))
	var mx := Vector3i(floori(aabb.end.x - 1.0), floori(aabb.end.y - 1.0), floori(aabb.end.z - 1.0))
	var removed := _apply_damage_native(SHAPE_BOX, Vector3.ZERO, 0.0, mn, mx)
	if not removed.is_empty():
		for pos in removed:
			_pending_removed[pos] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return removed

## 单体素破坏
func damage_voxel(pos: Vector3i, spawn_debris: Variant = null) -> bool:
	if not data or not data.has_voxel(pos):
		return false
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var removed := _apply_damage_native(SHAPE_BOX, Vector3.ZERO, 0.0, pos, pos)
	if not removed.is_empty():
		for p in removed:
			_pending_removed[p] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return not removed.is_empty()

## 射线破坏 (DDA)，朝指定方向破坏命中的第一个体素
func damage_ray(origin: Vector3, direction: Vector3, max_distance: float = 100.0, spawn_debris: Variant = null) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var hit := raycast_voxel(origin, direction, max_distance)
	if hit != Vector3i.MIN:
		damage_voxel(hit, spawn_debris)
	return hit

## 射线检测体素（DDA）。
func raycast_voxel(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Vector3i:
	return VoxelRay.hit_voxel(data, origin, direction, max_distance)

## 完全破坏: 移除所有体素
func destroy_all(spawn_debris: Variant = null) -> void:
	if not data:
		return
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions: Array = data.get_positions()
	var mat_map := _collect_voxel_materials(positions)
	if do_spawn and not Engine.is_editor_hint():
		_presenter.spawn_debris_with_materials(positions, mat_map)
	data.clear()
	voxel_damaged.emit(positions, do_spawn)

# 逐体素健康度 + 伤害应用

## 即时伤害应用：委托编辑内核做数学，本节点只做"表现层收尾"。
func _apply_damage_native(shape: int, center: Vector3, radius: float, vmin: Vector3i, vmax: Vector3i) -> Array:
	var res := _edit.apply_damage(data, shape, center, radius, vmin, vmax,
		damage_per_voxel, use_voxel_health)
	# 硬化反馈 → 与基线同一套缓冲与帧尾合并信号（表现层）
	var hardened: Dictionary = res["hardened"]
	for pos in hardened:
		_hardened_buffer[pos] = hardened[pos]
	if res["hardened_dirty"]:
		_hardened_dirty = true
	var removed: Array = res["removed"]
	last_damage_count = removed.size()
	return removed

## 「消费一批体素」的表现开关（见 _consume_voxels 的 opts["spawn_mode"]）
enum ConsumeSpawn {
	CONSUME_SPAWN_NONE,   ## 只移除，不生成任何表现（当前无调用点，留给纯编辑场景）
	CONSUME_SPAWN_DEBRIS, ## 粒子碎片：presenter.spawn_debris_with_materials（主破坏管道的碎屑路径）
	CONSUME_SPAWN_GROUPS, ## 掉落体：presenter.spawn_falling_chunks_from_groups（级联崩塌 / 应力断裂）
}

## 【统一破坏流水线】分组 → 取材质 → 移除体素 → 生成表现 → 发信号 → 更新计数。
func _consume_voxels(positions: Array, opts: Dictionary = {}) -> Dictionary:
	var stats := {"groups": 0, "group_ms": 0.0, "collect_ms": 0.0, "remove_ms": 0.0, "after_ms": 0.0, "spawn_ms": 0.0, "total_ms": 0.0}
	if positions.is_empty() or data == null:
		return stats
	var spawn_mode: int = opts.get("spawn_mode", ConsumeSpawn.CONSUME_SPAWN_NONE)
	var mat_default: int = opts.get("mat_default", 0)
	# 编辑器里不产出任何表现（与改造前各处的 `not Engine.is_editor_hint()` 守卫一致）
	var allow_spawn: bool = spawn_mode != ConsumeSpawn.CONSUME_SPAWN_NONE and not Engine.is_editor_hint()
	var _t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 1. 分组（只有"掉落体"模式需要；连通分组是掉落的物理单位）
	var groups: Array = []
	if spawn_mode == ConsumeSpawn.CONSUME_SPAWN_GROUPS:
		groups = VoxelConnectivity.partition_connected(positions)
		stats["groups"] = groups.size()
	var _t1 := Time.get_ticks_usec() if diag_enabled else 0

	# 2. 取材质快照（必须在移除前：移除后这些位置就查不到材质了）
	var mat_map: Dictionary = {}
	var group_materials: Array[Dictionary] = []
	if allow_spawn:
		if spawn_mode == ConsumeSpawn.CONSUME_SPAWN_GROUPS:
			group_materials = _collect_group_materials(groups, positions, mat_default)
		else:
			mat_map = _collect_voxel_materials(positions)
	var _t2 := Time.get_ticks_usec() if diag_enabled else 0

	# 3. 移除体素（一次批量；标记 chunk 脏 → 宿主下一帧重建网格）
	data.remove_voxels(positions)
	var _t3 := Time.get_ticks_usec() if diag_enabled else 0

	# 4. 移除后钩子（应力传播 / 崩塌排队；可原地增补 positions）
	var after_remove: Callable = opts.get("after_remove", Callable())
	if after_remove.is_valid():
		after_remove.call(positions)
	var _t4 := Time.get_ticks_usec() if diag_enabled else 0

	# 5. 生成表现（掉落体按连通组 → 一物理块一组；粒子按质心发射）
	if allow_spawn:
		if spawn_mode == ConsumeSpawn.CONSUME_SPAWN_GROUPS:
			_presenter.spawn_falling_chunks_from_groups(groups, group_materials)
		elif not mat_map.is_empty():
			# 粒子碎片：mat_map 为空（例如位置本就没有体素）时不发射（与改造前一致）
			_presenter.spawn_debris_with_materials(positions, mat_map)
	var _t5 := Time.get_ticks_usec() if diag_enabled else 0

	# 6. 信号 + 计数
	if opts.get("emit_collapse", false):
		voxels_about_to_collapse.emit(positions)
	if opts.get("emit_damaged", false):
		voxel_damaged.emit(positions, bool(opts.get("damaged_spawn", true)))
	if opts.get("update_collapse_count", false):
		last_collapse_count = positions.size()

	if diag_enabled:
		stats["group_ms"] = (_t1 - _t0) / 1000.0
		stats["collect_ms"] = (_t2 - _t1) / 1000.0
		stats["remove_ms"] = (_t3 - _t2) / 1000.0
		stats["after_ms"] = (_t4 - _t3) / 1000.0
		stats["spawn_ms"] = (_t5 - _t4) / 1000.0
		stats["total_ms"] = (_t5 - _t0) / 1000.0
	return stats

## 破坏后的统一处理：应力传播 + 崩塌检测排队
func _after_removal(removed: Array) -> void:
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	var _stress_count := 0

	# 应力传播：裂纹扩散（始终启用）
	if not removed.is_empty():
		var stress_removed := _propagate_stress(removed)
		_stress_count = stress_removed.size()
		if not stress_removed.is_empty():
			# 应力断裂体素走统一流水线（分组 → 取材质 → 移除 → 生成掉落体）。
			var _stress_stats := _consume_voxels(stress_removed, {
				"spawn_mode": ConsumeSpawn.CONSUME_SPAWN_GROUPS,
				"mat_default": 0,
			})
			if diag_enabled:
				print("[诊断] 应力传播掉落: %d组, 生成耗时%.2f ms" % [_stress_stats["groups"], _stress_stats["spawn_ms"]])
			removed.append_array(stress_removed)
			if diag_enabled:
				print("[诊断] 应力传播: 移除%d体素, 移除耗时%.2f ms, 分组%d" % [stress_removed.size(), _stress_stats["remove_ms"], _stress_stats["groups"]])

	_trigger_collapse(removed)

	if diag_enabled:
		var _t_total := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _t_total > 1.0:
			print("[诊断] _after_removal: 总%d体素(应力%d), 总耗时%.2f ms" % [removed.size(), _stress_count, _t_total])

# 应力传播（裂纹扩散）

## 应力传播：从被移除的体素出发，向邻居传播应力，材质 `connection_strength` 不足则断裂。
func _propagate_stress(removed: Array) -> Array:
	return _edit.propagate_stress(data, removed, stress_max_steps, stress_force, stress_decay)

# 悬空检测 + 崩塌掉落

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成粒子碎片
func _trigger_collapse(around_positions: Array = []) -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	if around_positions.is_empty():
		return

	# 局部检测：合并到待处理队列（不覆盖已有级联，避免新破坏导致正在进行的级联丢失）
	if _cascade_check_positions.is_empty():
		_cascade_check_positions = around_positions.duplicate()
	else:
		# 已有级联正在处理，合并新位置
		var existing: Dictionary = {}
		for pos in _cascade_check_positions:
			existing[pos] = true
		for pos in around_positions:
			if not existing.has(pos):
				_cascade_check_positions.append(pos)
				existing[pos] = true

## 处理级联崩塌（分帧处理，大面积崩塌时把主线程阻塞摊平到多帧）
func _process_cascade_level() -> void:
	# 优先处理上帧遗留的待移除体素（已判定失稳，直接走分组/移除/生成）
	if not _cascade_pending_voxels.is_empty():
		if _cascade_pending_voxels.size() > MAX_CASCADE_VOXELS_PER_FRAME:
			var batch: Array = _cascade_pending_voxels.slice(0, MAX_CASCADE_VOXELS_PER_FRAME)
			_cascade_pending_voxels = _cascade_pending_voxels.slice(MAX_CASCADE_VOXELS_PER_FRAME)
			_process_cascade_batch(batch)
			if diag_enabled:
				print("[诊断] 级联分帧(遗留): 本帧%d体素, 剩余%d" % [batch.size(), _cascade_pending_voxels.size()])
			return
		var pending: Array = _cascade_pending_voxels
		_cascade_pending_voxels = []
		_process_cascade_batch(pending)
		return

	if _cascade_check_positions.is_empty():
		return

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 取出当前待检查位置，清空队列（处理完即终结本次级联）
	var queue: Array = _cascade_check_positions
	_cascade_check_positions = []

	var unstable := _find_unstable_voxels(queue)
	if diag_enabled:
		print("[诊断] 级联检测: queue=%d, 检测出unstable=%d" % [queue.size(), unstable.size()])
	if unstable.is_empty():
		_finalize_cascade()
		return

	# 超大崩塌分帧：超过单帧上限时只处理前 MAX_CASCADE_VOXELS_PER_FRAME 个，
	if unstable.size() > MAX_CASCADE_VOXELS_PER_FRAME:
		var batch: Array = unstable.slice(0, MAX_CASCADE_VOXELS_PER_FRAME)
		_cascade_pending_voxels = unstable.slice(MAX_CASCADE_VOXELS_PER_FRAME)
		_process_cascade_batch(batch)
		if diag_enabled:
			print("[诊断] 级联分帧: 本帧%d体素, 剩余%d" % [batch.size(), _cascade_pending_voxels.size()])
		return

	_process_cascade_batch(unstable)

## 处理一批失稳体素：走统一流水线（分组 → 取材质 → 移除 → 生成掉落体）。
func _process_cascade_batch(unstable: Array) -> void:
	if unstable.is_empty():
		return
	var stats := _consume_voxels(unstable, {
		"spawn_mode": ConsumeSpawn.CONSUME_SPAWN_GROUPS,
		"after_remove": func(positions: Array) -> void: _cascade_total.append_array(positions),
	})

	# 本批处理完且无遗留 → 终结（单轮级联：find_unsupported_around 内部已沿支撑链传播完整
	if _cascade_pending_voxels.is_empty():
		_finalize_cascade()

	if diag_enabled and stats["total_ms"] > 1.0:
		print("[诊断] 级联批处理: %d体素, %d组, 总%.2fms | 分组%.2f | 材质%.2f | 移除%.2f | 生成%.2f" % [unstable.size(), stats["groups"], stats["total_ms"], stats["group_ms"], stats["collect_ms"], stats["remove_ms"], stats["spawn_ms"]])

## 完成级联、发信号
func _finalize_cascade() -> void:
	if _cascade_total.is_empty():
		return
	voxels_about_to_collapse.emit(_cascade_total)
	last_collapse_count = _cascade_total.size()
	voxel_damaged.emit(_cascade_total, true)
	_cascade_total = []
	_cascade_check_positions = []

## 找出所有"失稳"体素，返回这些体素位置的并集
func _find_unstable_voxels(around_positions: Array = []) -> Array:
	var use_local: bool = local_collapse and not around_positions.is_empty()
	var unstable := _edit.find_unstable(data, local_collapse, around_positions)
	if diag_enabled:
		print("[诊断] _find_unstable_voxels: around=%d, 局部=%s, 结果=%d" % [around_positions.size(), use_local, unstable.size()])
	return unstable

## 全量校验当前场景的悬空体素并触发崩塌（局部检测的初始化）
func validate_stability() -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var unstable := _find_unstable_voxels([])  # 空 around → 全量检测
	if unstable.is_empty():
		return
	# 初始化校验是"一次性定型"：整批失稳体素同步走完统一流水线并立刻发信号 + 记计数
	_consume_voxels(unstable, {
		"spawn_mode": ConsumeSpawn.CONSUME_SPAWN_GROUPS,
		"emit_collapse": true,
		"emit_damaged": true,
		"damaged_spawn": true,
		"update_collapse_count": true,
	})

## 批量取一组位置的材质 ID（原生一次过，替代逐体素 get_voxel 字典查询）。
func _collect_voxel_materials(positions: Array) -> Dictionary:
	return data.collect_materials_at(positions) if data else {}

## 按连通分组逐组建立 pos→材质ID 映射（移除前调用，供掉落体使用）。
func _collect_group_materials(groups: Array, positions: Array, mat_default: int = -1) -> Array[Dictionary]:
	var all_mats := _collect_voxel_materials(positions)
	var out: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = all_mats.get(pos, mat_default)
		out.append(mat_map)
	return out

# 主循环

## 帧尾合并发射硬化反馈信号：一次破坏几百个体素未摧毁时，
func _flush_hardened_signals() -> void:
	if not _hardened_dirty:
		return
	_hardened_dirty = false
	var positions: Array = _hardened_buffer.keys()
	if positions.is_empty():
		return
	voxel_hardened_batch.emit(positions, _hardened_buffer)
	_hardened_buffer.clear()

func _process(_delta: float) -> void:
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	# 【改造前这里是 super._process(_delta)】渲染每帧驱动归宿主：它就是本组件的**父节点**，
	if Engine.is_editor_hint():
		return

	# 宿主发生 origin shift（无限世界走远）时，本组件的体素坐标队列必须同步平移（见 on_origin_shift）。
	_sync_origin_shift()

	# 把碎片手感 / 掉落旋钮同步给表现层（@export 是本节点唯一真值；
	_presenter.configure(max_debris_per_hit, debris_speed_range, debris_lifetime, debris_gravity_scale,
			falling_mode, falling_chunk_pool_size, max_falling_chunks, falling_chunk_cleanup_time)

	# 处理级联崩塌（分帧：单帧处理一批，大面积崩塌摊平到多帧避免主线程卡顿）
	if not _cascade_check_positions.is_empty() or not _cascade_pending_voxels.is_empty():
		var _t1 := Time.get_ticks_usec() if diag_enabled else 0
		_process_cascade_level()
		if diag_enabled:
			var _dt := (Time.get_ticks_usec() - _t1) / 1000.0
			if _dt > 1.0:
				print("[诊断] _process_cascade_level 耗时: %.2f ms, 队列大小: %d" % [_dt, _cascade_check_positions.size()])

	# 处理普通破坏批次（每帧一个）
	_process_destruction_pipeline()

	# 帧尾：从待生成队列限量生成掉落体（摊平大面积崩塌的 GPU/物理负载）
	_presenter.process_pending_falling_groups()
	# 帧尾：GPU 忙时积压的掉落体 mesh 限量组装（add_surface_from_arrays 同步 GPU 上传）
	_presenter.process_pending_mesh_results()

	# 帧尾：合并发射硬化反馈（一次破坏几百个体素未摧毁时，避免逐体素高频信号）
	_flush_hardened_signals()

	# 定期检测掉落块：按时间间隔（约 1 秒）冻结静止块 + 生命周期清理（上限/超时）。
	_sleep_check_counter += _delta
	if _sleep_check_counter >= 1.0:
		_sleep_check_counter = 0.0
		_presenter.freeze_sleeping_chunks()

	if diag_enabled:
		var _total_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _total_ms > 3.0:
			print("[诊断] VoxelDestructible._process 总耗时: %.2f ms" % _total_ms)

## 延迟破坏管道：每帧处理所有累积的待移除体素（去重合并后）
func _process_destruction_pipeline() -> void:
	if _pending_removed.is_empty():
		return

	# 提取所有待移除位置（去重后的唯一键）
	var removed: Array = _pending_removed.keys()
	var do_spawn: bool = _pending_spawn_debris
	_pending_removed.clear()
	_pending_spawn_debris = false

	if removed.is_empty():
		return

	# 只用 do_spawn 决定"要不要粒子"，编辑器内由流水线的 allow_spawn 统一拦掉（生成部分），
	var stats := _consume_voxels(removed, {
		"spawn_mode": ConsumeSpawn.CONSUME_SPAWN_DEBRIS if do_spawn else ConsumeSpawn.CONSUME_SPAWN_NONE,
		"after_remove": func(positions: Array) -> void: _after_removal(positions),
		"emit_damaged": true,
		"damaged_spawn": do_spawn,
	})
