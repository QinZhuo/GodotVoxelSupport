@tool
class_name VoxelDestructible
extends VoxelRenderer

## 动态体素破坏系统
## 继承 VoxelRenderer，在渲染基础上提供体素破坏能力
## 支持球形/盒形/单体素/射线破坏 + 逐体素健康度 + 悬空崩塌 + 粒子碎片
## 破坏直接修改 VoxelData，自动触发 mesh 重新生成
## 碎片使用 GPU 粒子系统，无物理碰撞体，高性能

## 破坏反馈信号：具体表现（粒子/音效/震动）由游戏自行连接实现
signal voxel_damaged(positions: Array, spawn_debris: bool)      ## 体素被移除时 (含崩塌)
signal voxel_hardened(pos: Vector3i, remaining: float)          ## 体素受伤但未摧毁 (材质硬度未达)（单发，兼容旧用法）
signal voxel_hardened_batch(positions: Array, remaining: Dictionary) ## 批量硬化（帧尾合并发射，避免逐体素高频信号）
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

## 硬化反馈缓冲：pos -> remaining，_process 帧尾合并发 voxel_hardened_batch
var _hardened_buffer: Dictionary = {}
var _hardened_dirty: bool = false

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
	super._validate_property(property)
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
## 开启后破坏调用传入破坏位置，大幅减少每次崩塌检测的 BFS 范围（适合中频破坏+中型场景）
## 关闭则每次全量遍历所有体素判定（结果最精确，适合小型场景/低频）
@export var local_collapse: bool = true

## 逐体素健康度系统开关：关闭时忽略材质硬度，一击即碎
@export var use_voxel_health: bool = true

## 单次破坏对每个体素造成的伤害 (逐体素健康度用)
## 结合材质 hardness，伤害累积达到 hardness 才真正移除体素
@export var damage_per_voxel: float = 1.0

## AUTO 模式分档阈值（内部常量，不暴露配置）：按体素数自动选择表现方式
##   <= 粒子阈值        → GPU 粒子破碎（零物理开销，视觉自然）
##   <= Box 阈值        → BoxShape3D 包围盒碰撞（物理开销低，中小块够用）
##   >  Box 阈值        → ConvexPolygonShape3D 凸包碰撞（贴合大块轮廓）
const AUTO_PARTICLE_VOXELS: int = 32
const AUTO_BOX_VOXELS: int = 256

## 碎片粒子初始速度范围（Vector2 = [最小, 最大]，基准值，受材质 mass 影响）
## 最终速度 = 基准速度 / sqrt(mass) ，重物飞得近，轻物飞得远
@export var debris_speed_range: Vector2 = Vector2(2.0, 6.0)

## 碎片粒子生命周期 (秒)（基准值，受材质 mass 影响）
## 最终生命周期 = 基准生命周期 * (1.0 + 0.5 / mass) ，重物落地快消失快
@export var debris_lifetime: float = 3.0

## 碎片粒子重力倍数（基准值，受材质 mass 影响）
## 最终重力 = 基准重力 * mass ，重物受重力影响更大
@export var debris_gravity_scale: float = 1.0

## 整体健康度 (<=0 时触发完全破坏，-1 表示不启用健康度系统)
@export var health: float = -1.0

## 应力传播（裂纹扩散）距离（步数），即裂纹最多扩散多少层
## 破坏体素时，应力向邻居传播，当应力超过材质的 connection_strength 时，邻居也会断裂
## 产生更真实的渐进裂纹扩散效果
@export_range(1, 10) var stress_max_steps: int = 3

## 每次破坏产生的应力大小（与材质 connection_strength 比较决定是否断裂）
@export var stress_force: float = 15.0

## 应力衰减系数（每传播一步应力的衰减比例）
@export_range(0.0, 1.0) var stress_decay: float = 0.5

## 监控统计
var last_damage_count: int = 0     ## 最近一次破坏实际移除的体素数
var last_damage_time_ms: float = 0 ## 最近一次破坏耗时 (ms)
var last_collapse_count: int = 0   ## 最近一次崩塌的悬空体素数

## 逐体素累计伤害 (位置 -> 累计伤害)
var damage_map: Dictionary[Vector3i, float] = {}

## 延迟移除状态：同一帧内多次伤害的位置合并去重，下一帧统一处理
## key: Vector3i 体素位置，value: 是否生成碎片（任意一次伤害要求生成则生成）
var _pending_removed: Dictionary = {}  # key: Vector3i(pos), value: bool(spawn_debris)
var _pending_spawn_debris: bool = false

var _debris_root: Node3D = null
var _falling_chunk_root: Node3D = null
var _falling_chunk_id: int = 0
var _particle_mesh_cache: Dictionary = {}  # "mat_id" -> BoxMesh

## 粒子对象池：空闲的 GPUParticles3D 集合（复用，避免每次破坏新建节点）。
## 池上限防无限膨胀：池满时新粒子仍新建（超出直接丢，靠池上限自然限流）。
var _particle_pool: Array[GPUParticles3D] = []
## 粒子池上限（超过此数量不再缓存空闲节点，直接销毁）
const PARTICLE_POOL_MAX: int = 64
## 当前存活粒子系统数（用于调试/诊断）
var _active_particle_count: int = 0

## 粒子淡出渐变共用资源（生命周期末渐隐）。所有粒子共用同一份，破坏瞬间省 Gradient/GradientTexture1D 创建。
var _particle_fade_gradient: GradientTexture1D = null

## 掉落块材质缓存：同一份 data.materials 只需生成一次材质，避免每个掉落块重复生成
var _chunk_materials_cache: Array = []
var _chunk_materials_cache_src: Array = []

## 级联崩塌状态：逐帧处理，每帧只处理一个级联层级
## 存放当前层级的待检查体素位置，处理完后自动设置为下一级的位置
## 为空时表示没有待处理的级联
var _cascade_check_positions: Array = []  # 待检查的体素位置（下一级联层级）
var _cascade_total: Array = []            # 所有级联累积的失稳体素

## 级联分帧化：大面积崩塌（数万体素）时，单帧处理全部体素会造成主线程
## 数百毫秒卡顿（检测+分组+材质+移除+生成 全同步）。按体素数量切块，
## 每帧只处理 MAX_CASCADE_VOXELS_PER_FRAME 个，剩余存入待处理队列，
## 把 1174ms 级联阻塞摊平到多帧（检测每帧重跑，天然支持传播链继续）。
## 注意：分块检测的代价是每次 _find_unstable_voxels 都基于当前数据状态，
## 分批处理保证正确性（移除前体素已判定失稳），只是时序上分多帧。
const MAX_CASCADE_VOXELS_PER_FRAME: int = 4096
## 分帧处理剩余待移除体素（尚未分组/移除的失稳体素）
var _cascade_pending_voxels: Array = []

## 单帧最大物理体生成数量（防止大规模级联时一帧创建过多 RigidBody3D）
const MAX_FALLING_CHUNKS_PER_FRAME: int = 10

## 单个掉落体最大体素数：超大崩塌（数万体素）会被拆分为多个掉落体，
## 避免单块 ArrayMesh 一次性上传超大 buffer → Metal fence wait() 超时
const MAX_FALLING_GROUP_VOXELS: int = 4096

## 掉落物生成模式（统一"小块粒子/大块物理体"的分档策略）
enum FallingMode {
	AUTO,     ## 自动按体素数分档：小碎块转粒子，中块 Box 碰撞，大块凸包碰撞（推荐）
	PARTICLE, ## 全部转 GPU 粒子（零物理开销，视觉最轻量）
	PHYSICS,  ## 全部物理体（Box/凸包碰撞，保留整块碎裂的物理感）
}

## 掉落物生成模式（见 FallingMode）
@export var falling_mode: FallingMode = FallingMode.AUTO

## 物理掉落体对象池大小：同时最多存在的活动 RigidBody3D 数量。
## 池复用消除创建/销毁开销，同时作为物理体数量的软上限（池满的新块转粒子，优雅降级）。
## 设大些避免大崩塌时过早降级（大块转粒子会损失"整块碎裂"的物理感）。
@export_range(8, 512) var falling_chunk_pool_size: int = 64

## 掉落块最大存活数量（超出后最早冻结的块被移除，防止长时间破坏后物理体无限堆积拖慢帧率）
@export_range(20, 2000) var max_falling_chunks: int = 200

## 掉落块冻结后的最长保留时间（秒），到期后自动移除（已经落地静止，视觉任务完成）
@export_range(1.0, 60.0) var falling_chunk_cleanup_time: float = 6.0

## 掉落块落地静置检测时间累计 (秒)
var _sleep_check_counter: float = 0.0

## 所有掉落块 -> 生成时刻 (msec)，用于生命周期上限/超时清理（含未冻结仍在掉落的块）
var _chunk_spawn_times: Dictionary = {}

## 物理掉落体对象池：空闲的 RigidBody3D 集合（复用，避免反复创建/销毁）
var _body_pool: Array[RigidBody3D] = []
## 池中所有已创建的 RigidBody3D（含使用中），用于池容量管理
var _body_pool_total: Array[RigidBody3D] = []

## 大块掉落交替策略：相邻中块连续快速生成时，物理体与粒子破碎交替出现，
## 防止多个中块同帧物理落地互相碰撞被推飞，同时画面表现更多样。
## 交替条件（仅中块 + 双条件）：组体素 > 粒子阈值 且 ≤ Box阈值 且 距上次物理块
## 中心距离 < 阈值 且 间隔 < 时间窗口。大块（>Box阈值）始终物理体，不参与交替。
var _last_physics_chunk_time: int = 0
var _last_physics_chunk_pos: Vector3 = Vector3.INF
const _chunk_alternate_ms: int = 300      # 连续生成时间窗口（毫秒）
const _chunk_alternate_dist: float = 5.0  # 相邻判定距离（世界单位，≈1-2块宽）

## 待生成掉落体队列：大面积崩塌时超出单帧上限的物理组暂存于此，
## 由 _process 每帧限量生成，把 GPU/物理负载摊平到多帧（消除 Metal fence 洪峰）
var _pending_falling_groups: Array = []
var _pending_falling_materials: Array[Dictionary] = []
## 每帧最多从待生成队列生成多少个掉落体（与 MAX_FALLING_CHUNKS_PER_FRAME 一致）
var _pending_build_per_frame: int = 10

## 掉落体 mesh 结果队列：后台线程生成完 arrays 后，若 GPU 忙则暂存于此，
## 由 _process 帧尾限量组装 ArrayMesh（add_surface_from_arrays 同步 GPU 上传，
## 避免 GPU 满载时 Metal fence wait() 超时）。元素: {body, arrays, local_voxels}
var _pending_mesh_results: Array[Dictionary] = []
## 每帧最多组装的掉落体 mesh 数
var _mesh_apply_per_frame: int = 2
## GPU 忙检测与阈值继承自父类 VoxelRenderer（_measure_render_time_enabled / _gpu_busy_threshold_ms）

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()
		# 不再做初始全量稳定性校验：浮空结构默认保持稳定，失稳只由破坏逻辑
		# （局部检测）触发，避免打开场景时主线程全量遍历体素（百万级体素可卡数秒）。
		# 需要主动校验时调用方手动调 validate_stability()
		# 支撑检测采用实时局部查询（LOWER_5 邻居统计），无需预热任何缓存——
		# 失稳传播只访问破坏点附近体素（微秒级），零初始化开销。


func _exit_tree() -> void:
	_clear_debris()


# ----------------------------------------------------------------------------
# 破坏入口
# ----------------------------------------------------------------------------

## 球形破坏: 对中心点半径内的体素造成伤害
## center 为体素空间坐标 (1单位 = 1体素)，radius 单位同上
## 仅更新 damage_map（即时），实际移除在下一帧统一处理
## 返回被判定为应移除的体素位置数组（基于累计伤害）
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions := data.get_voxels_in_sphere(center, radius)
	var mat_map := _collect_voxel_materials(positions)
	# 1. 即时：更新 damage_map
	var removed := _apply_damage_immediate(positions, mat_map, damage_per_voxel)
	# 2. 合并去重：同一帧内多次伤害相同位置只处理一次
	if not removed.is_empty():
		for pos in removed:
			_pending_removed[pos] = true
		_pending_spawn_debris = _pending_spawn_debris or do_spawn
	return removed


## 盒形破坏
## 仅更新 damage_map（即时），实际移除在下一帧统一处理
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions := data.get_voxels_in_box(aabb)
	var mat_map := _collect_voxel_materials(positions)
	var removed := _apply_damage_immediate(positions, mat_map, damage_per_voxel)
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
	var mat_map := _collect_voxel_materials([pos])
	var removed := _apply_damage_immediate([pos], mat_map, damage_per_voxel)
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


## 射线检测体素 (DDA 算法)
func raycast_voxel(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Vector3i:
	if not data:
		return Vector3i.MIN
	var dir := direction.normalized()
	var pos := Vector3i(floor(origin.x), floor(origin.y), floor(origin.z))
	var step := Vector3i(
		1 if dir.x > 0 else -1,
		1 if dir.y > 0 else -1,
		1 if dir.z > 0 else -1
	)
	var t_delta := Vector3(
		abs(1.0 / dir.x) if dir.x != 0 else INF,
		abs(1.0 / dir.y) if dir.y != 0 else INF,
		abs(1.0 / dir.z) if dir.z != 0 else INF
	)
	var t_max := Vector3(
		(float(pos.x + (1 if step.x > 0 else 0)) - origin.x) / dir.x if dir.x != 0 else INF,
		(float(pos.y + (1 if step.y > 0 else 0)) - origin.y) / dir.y if dir.y != 0 else INF,
		(float(pos.z + (1 if step.z > 0 else 0)) - origin.z) / dir.z if dir.z != 0 else INF
	)
	var traveled := 0.0
	while traveled < max_distance:
		if data.has_voxel(pos):
			return pos
		if t_max.x < t_max.y and t_max.x < t_max.z:
			pos.x += step.x
			traveled = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			pos.y += step.y
			traveled = t_max.y
			t_max.y += t_delta.y
		else:
			pos.z += step.z
			traveled = t_max.z
			t_max.z += t_delta.z
	return Vector3i.MIN


## 完全破坏: 移除所有体素
func destroy_all(spawn_debris: Variant = null) -> void:
	if not data:
		return
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var positions: Array = data.get_positions()
	var mat_map := _collect_voxel_materials(positions)
	if do_spawn and not Engine.is_editor_hint():
		_spawn_debris_with_materials(positions, mat_map)
	data.clear()
	voxel_damaged.emit(positions, do_spawn)


## 修复整体健康度
func repair(amount: float) -> void:
	if health >= 0:
		health = max(health + amount, 0.0)


# ----------------------------------------------------------------------------
# 逐体素健康度 + 伤害应用
# ----------------------------------------------------------------------------

## 即时伤害应用：只更新 damage_map，不实际移除体素
## 返回应被移除的体素位置（基于累计伤害判断）
## 实际移除在 _process 中逐帧处理
func _apply_damage_immediate(positions: Array, mat_map: Dictionary, damage: float) -> Array:
	var removed: Array = []
	for pos in positions:
		var mat_id: int = mat_map.get(pos, -1)
		if not use_voxel_health:
			removed.append(pos)
			continue
		var hardness := _get_material_hardness(mat_id)
		if hardness <= 0.0:
			removed.append(pos)
			continue
		var cur: float = float(damage_map.get(pos, 0.0)) + damage
		if cur >= hardness:
			damage_map.erase(pos)
			removed.append(pos)
		else:
			damage_map[pos] = cur
			# 硬化反馈累积到缓冲，_process 帧尾统一发 voxel_hardened_batch
			# （逐体素 emit 在大破坏时一次几百次信号 → 高频，合并后一次）
			_hardened_buffer[pos] = hardness - cur
			_hardened_dirty = true
	last_damage_count = removed.size()
	return removed


func _get_material_hardness(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id] as VoxelMaterial
		if m:
			return m.hardness
	return 1.0


## 破坏后的统一处理：崩塌检测 + 应力传播 + 整体健康度扣减
## 在 _process 延迟处理中调用（每帧一个批次）
## 应力传播是轻量 BFS（邻域检查），直接同步执行，无需异步
func _after_removal(removed: Array) -> void:
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	var _stress_count := 0

	# 应力传播：裂纹扩散（始终启用）
	if not removed.is_empty():
		var stress_removed := _propagate_stress(removed)
		_stress_count = stress_removed.size()
		if not stress_removed.is_empty():
			# 应力传播移除的体素先移除，再触发崩塌
			var stress_mat_map := _collect_voxel_materials(stress_removed)
			var _diag_t1 := Time.get_ticks_usec() if diag_enabled else 0
			data.remove_voxels(stress_removed)
			var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0
			# 应力传播的断裂体素：连通的转为物理体掉落，散落的用粒子
			var stress_groups := []
			if not Engine.is_editor_hint():
				# 按连通性分组，每组生成一个物理体掉落
				stress_groups = VoxelData.partition_connected(stress_removed)
				# 为每组构建材质映射
				var stress_group_materials: Array[Dictionary] = []
				for sgroup in stress_groups:
					var sgroup_mat_map: Dictionary = {}
					for pos in sgroup:
						sgroup_mat_map[pos] = stress_mat_map.get(pos, 0)
					stress_group_materials.append(sgroup_mat_map)
				var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0
				_spawn_falling_chunks_from_groups(stress_groups, stress_group_materials)
				if diag_enabled:
					var _t_spawn := (Time.get_ticks_usec() - _diag_t3) / 1000.0
					print("[诊断] 应力传播掉落: %d组, 生成耗时%.2f ms" % [stress_groups.size(), _t_spawn])
			removed.append_array(stress_removed)
			if diag_enabled:
				var _t_remove_stress := (_diag_t2 - _diag_t1) / 1000.0
				print("[诊断] 应力传播: 移除%d体素, 移除耗时%.2f ms, 分组%d" % [stress_removed.size(), _t_remove_stress, stress_groups.size() if not Engine.is_editor_hint() else 0])

	_trigger_collapse(removed)
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()

	if diag_enabled:
		var _t_total := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _t_total > 1.0:
			print("[诊断] _after_removal: 总%d体素(应力%d), 总耗时%.2f ms" % [removed.size(), _stress_count, _t_total])


# ----------------------------------------------------------------------------
# 应力传播（裂纹扩散）
# ----------------------------------------------------------------------------

## 应力传播：从被移除的体素出发，向邻居传播应力
## 若邻居体素材质的 connection_strength 不足以承受应力，则断裂
## 轻量 BFS，直接同步执行，无需异步（邻域检查量级远小于数据快照开销）
## 返回所有因应力传播而断裂的体素位置
func _propagate_stress(removed: Array) -> Array:
	if not data or removed.is_empty():
		return []

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0
	var all_removed: Dictionary = {}
	for p in removed:
		all_removed[p] = true

	var stress_removed: Array = []
	var current_layer: Array = removed
	var current_force: float = stress_force

	for step in range(stress_max_steps):
		if current_layer.is_empty():
			break
		var next_layer: Array = []
		current_force *= (1.0 - stress_decay)
		if current_force <= 0.0:
			break

		for p in current_layer:
			var pos: Vector3i = p
			for d in data.NEIGHBORS_6:
				var nb := pos + d
				if nb in all_removed:
					continue
				if not data.has_voxel(nb):
					continue
				var mat_id := data.get_voxel(nb)
				var conn_strength := _get_connection_strength(mat_id)
				if current_force > conn_strength:
					# 应力超过连接强度 → 断裂
					all_removed[nb] = true
					stress_removed.append(nb)
					next_layer.append(nb)
		current_layer = next_layer

	if diag_enabled:
		var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _t_ms > 0.5:
			print("[诊断] _propagate_stress: 起点%d, 结果%d, 耗时%.2f ms" % [removed.size(), stress_removed.size(), _t_ms])

	return stress_removed


## 获取材质的连接强度
## connection_strength 是 VoxelMaterial 的 @export 属性，一定存在
func _get_connection_strength(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id] as VoxelMaterial
		if m:
			return m.connection_strength
	return 10.0


# ----------------------------------------------------------------------------
# 悬空检测 + 崩塌掉落
# ----------------------------------------------------------------------------

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成粒子碎片
## 局部支撑检测：只检查"破坏位置附近"的悬空，避免每次破坏都全场景 BFS
## around_positions 为本次破坏移除的体素位置；为空则做全场景检测
## 级联崩塌：崩塌掉落的体素也是"被移除"，会再次触发局部检测，连锁反应直到无更多失稳
## 每次调用只处理一个级联层级，剩余工作由 _process 在后续帧继续处理
func _trigger_collapse(around_positions: Array = []) -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return

	# 全场景检测（around_positions 为空）：同步完成所有级联层级
	# 仅在 validate_stability 等初始化场景调用
	if around_positions.is_empty():
		_process_full_cascade()
		return

	# 局部检测：合并到待处理队列（不覆盖已有级联，避免新破坏导致正在进行的级联丢失）
	# 去重：避免同一位置被多次检查
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


## 从连通分组中生成掉落体（统一入口，消除代码重复）
## group_materials: Array[Dictionary]，每个元素是 {pos: mat_id} 映射
## 分流规则（按 falling_mode）：
##   - AUTO + 组体素数 <= AUTO_PARTICLE_VOXELS → GPU 粒子破碎（零物理开销，视觉自然）
##   - 其余 → 物理体（Box 或凸包，见 _on_falling_chunk_mesh_result）
## 返回实际生成的物理掉落体数量
func _spawn_falling_chunks_from_groups(groups: Array, group_materials: Array[Dictionary]) -> int:
	var spawned_count := 0
	# 先处理小块（粒子）和大块（物理体）分流
	# 按 falling_mode 决定：AUTO 按体素数分档，PARTICLE 全转粒子，PHYSICS 全物理体
	var physics_groups: Array = []
	var physics_materials: Array[Dictionary] = []
	for i in range(groups.size()):
		var group: Array = groups[i]
		var to_particle := falling_mode == FallingMode.PARTICLE \
				or (falling_mode == FallingMode.AUTO and group.size() <= AUTO_PARTICLE_VOXELS)
		if to_particle:
			# 小块：直接转粒子破碎
			var mat_map: Dictionary = group_materials[i]
			if not group.is_empty():
				_spawn_debris_with_materials(group, mat_map, true)
		else:
			physics_groups.append(group)
			physics_materials.append(group_materials[i])

	# 大块：物理体（受单帧上限和池容量约束）
	# 超大组先按空间拆分（避免单个 ArrayMesh 上传超大 buffer → Metal fence 超时），
	# 超出单帧上限的组**跨帧排队**生成（而非同帧转粒子 → 避免 GPU/物理洪峰）
	var physics_groups_split: Array = []
	var physics_materials_split: Array[Dictionary] = []
	for i in range(physics_groups.size()):
		var split_groups := _split_oversized_group(physics_groups[i])
		if split_groups.size() == 1:
			physics_groups_split.append(split_groups[0])
			physics_materials_split.append(physics_materials[i])
		else:
			# 按子组切分材质映射
			for sg in split_groups:
				var sub_mat: Dictionary = {}
				for pos in sg:
					sub_mat[pos] = physics_materials[i].get(pos, 0)
				physics_groups_split.append(sg)
				physics_materials_split.append(sub_mat)

	var leftover: Array = []
	var leftover_mats: Array[Dictionary] = []
	for i in range(physics_groups_split.size()):
		if spawned_count >= MAX_FALLING_CHUNKS_PER_FRAME:
			# 排到待生成队列，由 _process 每帧限量继续生成
			leftover.append(physics_groups_split[i])
			leftover_mats.append(physics_materials_split[i])
		else:
			_spawn_falling_chunk(physics_groups_split[i], physics_materials_split[i])
			spawned_count += 1
	if not leftover.is_empty():
		_pending_falling_groups.append_array(leftover)
		_pending_falling_materials.append_array(leftover_mats)
	return spawned_count


## 超大掉落体组分拆：单组体素数超过 MAX_FALLING_GROUP_VOXELS 时按空间切片拆为多个子组，
## 每个子组生成独立掉落体（mesh 上传量受控，物理分布更自然）。
## 返回子组数组；未超限时返回含原组的单元素数组。
func _split_oversized_group(group: Array) -> Array:
	if group.size() <= MAX_FALLING_GROUP_VOXELS:
		return [group]
	# 计算包围盒，选择最长轴做切片，尽量保持子组空间紧凑
	var min_p := Vector3i(group[0])
	var max_p := min_p
	for pos in group:
		var p: Vector3i = pos
		min_p = Vector3i(mini(min_p.x, p.x), mini(min_p.y, p.y), mini(min_p.z, p.z))
		max_p = Vector3i(maxi(max_p.x, p.x), maxi(max_p.y, p.y), maxi(max_p.z, p.z))
	# 找到最长轴
	var ext := max_p - min_p
	var axis := 0
	if ext.y > ext.x:
		axis = 1
	if ext.z > ext[axis]:
		axis = 2
	# 沿最长轴切成 ceil(size/MAX) 段，体素按坐标分桶
	var range_len := maxf(ext[axis] + 1, 1.0)
	var segments := ceili(group.size() / float(MAX_FALLING_GROUP_VOXELS))
	var buckets: Array = []
	buckets.resize(segments)
	for i in segments:
		buckets[i] = []
	for pos in group:
		var p: Vector3i = pos
		var t := (p[axis] - min_p[axis]) / range_len
		var idx := mini(int(t * segments), segments - 1)
		buckets[idx].append(pos)
	# 去掉空桶
	var result: Array = []
	for b in buckets:
		if not (b as Array).is_empty():
			result.append(b)
	return result


## 每帧从待生成队列限量生成掉落体（把大面积崩塌的 GPU/物理负载摊平到多帧）
## 由 VoxelDestructible._process 帧尾调用
func _process_pending_falling_groups() -> void:
	if _pending_falling_groups.is_empty():
		return
	var count := 0
	while not _pending_falling_groups.is_empty() and count < _pending_build_per_frame:
		var group: Array = _pending_falling_groups.pop_front() as Array
		var mat_map: Dictionary = _pending_falling_materials.pop_front() as Dictionary
		_spawn_falling_chunk(group, mat_map)
		count += 1
	if diag_enabled and count > 0:
		print("[诊断] 待生成掉落体: 本帧生成%d, 剩余%d" % [count, _pending_falling_groups.size()])


## 全场景级联崩塌检测（同步完成所有层级）
## 统一使用整块物理体掉落（FallingChunk），而非粒子碎片
func _process_full_cascade() -> void:
	var check_positions: Array = []
	var total_unstable: Array = []
	var guard := 64
	while guard > 0:
		guard -= 1
		var unstable := _find_unstable_voxels(check_positions)
		if unstable.is_empty():
			break
		total_unstable.append_array(unstable)
		check_positions = unstable
	if total_unstable.is_empty():
		return

	# 按连通性分组，每组生成一个 FallingChunk
	var groups := VoxelData.partition_connected(total_unstable)
	# 收集每组体素的材质ID（在移除前）
	var group_materials: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = data.get_voxel(pos)
		group_materials.append(mat_map)
	data.remove_voxels(total_unstable)
	if not Engine.is_editor_hint():
		_spawn_falling_chunks_from_groups(groups, group_materials)

	voxels_about_to_collapse.emit(total_unstable)
	last_collapse_count = total_unstable.size()
	voxel_damaged.emit(total_unstable, true)


## 处理级联崩塌（分帧处理，大面积崩塌时把主线程阻塞摊平到多帧）
## 从 _cascade_check_positions 出发，单轮找出级联失稳体素并统一移除
##
## 性能优化（合并级联层级 + 分帧切块）：
##   - 旧实现每帧只处理一个级联层级，BFS 多轮重复扫描（每轮 10-13ms），
##     5 级级联 = 50-65ms 链式阻塞。find_unsupported_around() 内部已用支撑图
##     把连锁失稳"单轮递归传播"到终结，一次调用获得全部失稳体素。
##   - 超大崩塌（数万体素）时单帧全处理仍会主线程卡顿数百 ms（检测+分组+
##     材质+移除+生成全同步）。因此按 MAX_CASCADE_VOXELS_PER_FRAME 切块：
##     每帧只处理一批，剩余体素存 _cascade_pending_voxels，下帧继续检测。
func _process_cascade_level() -> void:
	# 优先处理上帧遗留的待移除体素（已判定失稳，直接走分组/移除/生成）
	# 注意：遗留体素可能仍超单帧上限（上一帧一次性全量放入），需再次分帧
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
	# 剩余存入待处理队列，由 _process 下一帧继续（避免单帧 1 秒级主线程卡顿）
	if unstable.size() > MAX_CASCADE_VOXELS_PER_FRAME:
		var batch: Array = unstable.slice(0, MAX_CASCADE_VOXELS_PER_FRAME)
		_cascade_pending_voxels = unstable.slice(MAX_CASCADE_VOXELS_PER_FRAME)
		_process_cascade_batch(batch)
		if diag_enabled:
			print("[诊断] 级联分帧: 本帧%d体素, 剩余%d" % [batch.size(), _cascade_pending_voxels.size()])
		return

	_process_cascade_batch(unstable)


## 处理一批失稳体素：分组 → 收集材质 → 移除 → 生成掉落体
## 供 _process_cascade_level 单帧批处理与分帧待处理队列共用
func _process_cascade_batch(unstable: Array) -> void:
	if unstable.is_empty():
		return
	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 按连通性分组
	var groups := VoxelData.partition_connected(unstable)
	var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0

	# 收集材质快照（在移除前）
	var group_materials: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = data.get_voxel(pos)
		group_materials.append(mat_map)
	var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0

	# 移除失稳体素
	data.remove_voxels(unstable)
	var _diag_t4 := Time.get_ticks_usec() if diag_enabled else 0

	# 生成物理体（每帧限制数量，使用统一入口）
	if not Engine.is_editor_hint():
		_spawn_falling_chunks_from_groups(groups, group_materials)
	var _diag_t5 := Time.get_ticks_usec() if diag_enabled else 0

	# 累积级联结果
	_cascade_total.append_array(unstable)

	# 本批处理完且无遗留 → 终结。
	# 单轮级联：find_unsupported_around 内部已沿支撑链传播完整级联，
	# 无需把 unstable 再次作为 removed 继续检测（否则配合较宽松的支撑判定
	# 会连锁放大 → 破坏一点整楼/整行塌）。
	if _cascade_pending_voxels.is_empty():
		_finalize_cascade()

	if diag_enabled:
		var _t_total := (_diag_t5 - _diag_t0) / 1000.0
		var _t_group := (_diag_t2 - _diag_t0) / 1000.0
		var _t_mat := (_diag_t3 - _diag_t2) / 1000.0
		var _t_remove := (_diag_t4 - _diag_t3) / 1000.0
		var _t_spawn := (_diag_t5 - _diag_t4) / 1000.0
		if _t_total > 1.0:
			print("[诊断] 级联批处理: %d体素, %d组, 总%.2fms | 分组%.2f | 材质%.2f | 移除%.2f | 生成%.2f" % [unstable.size(), groups.size(), _t_total, _t_group, _t_mat, _t_remove, _t_spawn])


## 完成级联、发信号
func _finalize_cascade() -> void:
	if _cascade_total.is_empty():
		return
	voxels_about_to_collapse.emit(_cascade_total)
	last_collapse_count = _cascade_total.size()
	voxel_damaged.emit(_cascade_total, true)
	_cascade_total = []
	_cascade_check_positions = []


## 确保崩塌掉落块根节点存在
func _ensure_falling_chunk_root() -> void:
	if not _falling_chunk_root:
		_falling_chunk_root = Node3D.new()
		_falling_chunk_root.name = "_FallingChunks"
		add_child(_falling_chunk_root, false, Node.INTERNAL_MODE_BACK)


## 生成一个崩塌掉落块（整块物理体）
## 将一组连通体素创建为一个"轻量静态 MeshInstance3D" + RigidBody3D 掉落
## 体素位置偏移到居中，使 RigidBody3D 位于块的中心
## mat_map: 体素位置 -> 材质ID 的映射（在调用前已从 data 中收集，因为 data 可能在调用前已移除体素）
##
## 轻量化说明：掉落块只需静态渲染 + 刚体物理，不需要任何后期破坏/修改能力。
## 因此用"一次性生成的 ArrayMesh + MeshInstance3D"替代完整的 VoxelDestructible
## （后者携带异步网格生成管线、材质缓存、级联崩塌逻辑等重资产），大幅降低每个
## 掉落块的创建开销，减轻大规模级联时的主线程压力。
func _spawn_falling_chunk(group: Array, mat_map: Dictionary) -> void:
	if group.is_empty():
		return

	# 【改进2】池满守卫：优先回收最旧物理体回池（腾出名额），而非直接转粒子。
	# 回收成功则本块正常生成；实在无法回收（无块可逐出）才转粒子兜底。
	if _body_pool_total.size() >= int(falling_chunk_pool_size) and _body_pool.is_empty():
		var evicted := _evict_oldest_falling_chunks(1)
		if evicted <= 0:
			_spawn_chunk_break_debris(group, mat_map)
			return

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	_ensure_falling_chunk_root()

	# 1. 计算体素边界和中心
	var voxel_min := Vector3i(group[0])
	var voxel_max := Vector3i(group[0])
	for pos in group:
		var p: Vector3i = pos
		voxel_min = Vector3i(min(voxel_min.x, p.x), min(voxel_min.y, p.y), min(voxel_min.z, p.z))
		voxel_max = Vector3i(max(voxel_max.x, p.x), max(voxel_max.y, p.y), max(voxel_max.z, p.z))

	var voxel_center := (Vector3(voxel_min) + Vector3(voxel_max)) * 0.5 + Vector3(0.5, 0.5, 0.5)
	var world_center := voxel_center * voxel_scale

	# 【改进1】相邻中块交替：距上次物理块中心 < 阈值距离 且 连续生成（间隔 < 窗口）时，
	# 本块转粒子破碎（交替）。**仅中块参与交替**（>粒子阈值 且 ≤Box阈值）：
	# - 中块（32~256）：物理感弱、视觉差异小，交替表现多样且防碰撞推飞
	# - 大块（>256）：始终物理体（重量感、整块碎裂的物理真实感），只在池满时降级
	var now_ms := Time.get_ticks_msec()
	var is_medium := group.size() > AUTO_PARTICLE_VOXELS and group.size() <= AUTO_BOX_VOXELS
	var dist_to_last := world_center.distance_to(_last_physics_chunk_pos)
	var alternate := is_medium \
			and _last_physics_chunk_pos != Vector3.INF \
			and dist_to_last < _chunk_alternate_dist \
			and (now_ms - _last_physics_chunk_time) < _chunk_alternate_ms
	if alternate:
		# 视锥外不生成粒子（相机看不到，跳过昂贵效果）
		# world_center 为体素世界坐标（含 target 偏移），转全局坐标判定
		if is_world_visible(world_center + global_position):
			_spawn_chunk_break_debris(group, mat_map)
		return

	# 2. 构建偏移到居中的体素字典（供一次性生成静态 mesh）
	# 使用提前收集的 mat_map 而非 data.voxels（体素可能已被移除）
	var local_voxels: Dictionary[Vector3i, int] = {}
	for pos in group:
		var p: Vector3i = pos
		local_voxels[p - Vector3i(voxel_center)] = int(mat_map.get(p, 0))

	# 3. 从对象池取 RigidBody3D（复用，避免反复创建/销毁）
	var body := _acquire_body()
	body.position = world_center
	body.mass = maxf(group.size() * 0.5, 1.0)
	body.continuous_cd = true
	body.freeze = false
	body.gravity_scale = 1.0
	body.sleeping = false

	# 4. 添加到场景（先于 mesh：mesh 由后台线程生成后异步挂载）
	_falling_chunk_root.add_child(body)
	body.owner = _falling_chunk_root
	# 记录生成时刻，供生命周期上限/超时清理（覆盖所有掉落块，含未冻结的）
	_chunk_spawn_times[body] = Time.get_ticks_msec()
	# 记录块体素信息（供回收时粒子破碎），并更新交替时间戳
	body.set_meta("local_voxels", local_voxels)
	_last_physics_chunk_time = now_ms
	_last_physics_chunk_pos = world_center

	if diag_enabled:
		var _t_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _t_ms > 1.0:
			print("[诊断] _spawn_falling_chunk: %d体素(物理体), 耗时%.2f ms" % [group.size(), _t_ms])

	# 5. 连接落地检测：落地后静置一段时间自动冻结（节省物理开销，不掉落块不消失）
	# 对象池复用：连接前先断开旧连接，避免重复连接
	for conn in body.body_entered.get_connections():
		body.body_entered.disconnect(conn["callable"])
	body.body_entered.connect(_on_chunk_landed.bind(body))

	# 6. 异步生成静态网格：后台线程生成数组，主线程组装 ArrayMesh + 碰撞后挂载
	# 避免级联破坏时在主线程同步生成大量掉落块 mesh（最大主线程阻塞点）
	var materials_snapshot: Array = data.materials.duplicate(false) if data else []
	var spawn_scale := voxel_scale
	WorkerThreadPool.add_task(_falling_chunk_mesh_worker.bind(local_voxels, materials_snapshot, spawn_scale, body))


## 后台线程入口：为掉落块生成网格数组（线程安全，不触碰 ArrayMesh/节点）
## 完成后 call_deferred 回主线程 _on_falling_chunk_mesh_result 组装 ArrayMesh
## 优先走原生 dense 路径（generate_single_chunk_dense → GDExtension C++，
## 顶点复用 + 网格生成主循环 ~10 倍提速）；块体超 HALO_SIZE 时回退 generate_arrays_runtime
func _falling_chunk_mesh_worker(local_voxels: Dictionary, materials: Array, scale: float, body: RigidBody3D) -> void:
	var arrays: Variant = _generate_falling_chunk_arrays(local_voxels, materials, scale)
	# 【凸包后台化】在后台线程计算碰撞外壳点集（体素包围盒 8 角点，O(1) 无凸包算法），
	# 替代主线程 create_convex_shape（实测 4096 体素块 69ms 主线程卡顿）。
	# 传回主线程 set_points 秒完成。
	var hull_points := _compute_hull_points(local_voxels, scale)
	call_deferred("_on_falling_chunk_mesh_result", body, arrays, local_voxels, hull_points)


## 计算掉落块碰撞外壳点集：体素包围盒的 8 个角点（简化凸包）。
## 贴合块形状（比 Box 精确），O(1) 无凸包算法开销，后台线程安全（纯数据）。
## 返回 PackedVector3Array（世界单位，相对块中心的局部坐标）
static func _compute_hull_points(local_voxels: Dictionary, scale: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	if local_voxels.is_empty():
		return pts
	var min_p := Vector3i(local_voxels.keys()[0])
	var max_p := min_p
	for pos_key in local_voxels:
		var p: Vector3i = pos_key
		min_p = Vector3i(mini(min_p.x, p.x), mini(min_p.y, p.y), mini(min_p.z, p.z))
		max_p = Vector3i(maxi(max_p.x, p.x), maxi(max_p.y, p.y), maxi(max_p.z, p.z))
	# 8 个角点（含块体素范围，贴合实际形状）
	for i in 8:
		var corner := Vector3(
			min_p.x if (i & 1) == 0 else max_p.x + 1,
			min_p.y if (i & 2) == 0 else max_p.y + 1,
			min_p.z if (i & 4) == 0 else max_p.z + 1)
		pts.append((corner - Vector3(0.5, 0.5, 0.5)) * scale)
	return pts


## 生成掉落块网格数组：优先原生 dense 单 chunk 路径，超大块回退 GDScript 合并路径
func _generate_falling_chunk_arrays(local_voxels: Dictionary, materials: Array, scale: float) -> Variant:
	if local_voxels.is_empty():
		return null
	# 判断掉落体是否超出单 chunk dense 范围（local_voxels 以 center 为中心，检查最大偏移）
	var max_abs := 0
	for pos_key in local_voxels:
		var p: Vector3i = pos_key
		max_abs = maxi(max_abs, maxi(maxi(absi(p.x), absi(p.y)), absi(p.z)))
	# HALO_SIZE=18：可容纳 local 坐标 [-HALO, HALO_SIZE-HALO-1] = [-1, 16]，即中心±16
	if max_abs <= VoxelChunk.HALO_SIZE - VoxelChunk.HALO - 1:
		# 构造 18³ 密集 halo：以 center 为 chunk 原点（chunk_key=0），local 坐标 + HALO 偏移
		var halo := PackedInt32Array()
		halo.resize(VoxelChunk.HALO_VOLUME)
		for pos_key in local_voxels:
			var p: Vector3i = pos_key
			var lx := p.x + VoxelChunk.HALO
			var ly := p.y + VoxelChunk.HALO
			var lz := p.z + VoxelChunk.HALO
			if lx < 0 or ly < 0 or lz < 0 or lx >= VoxelChunk.HALO_SIZE or ly >= VoxelChunk.HALO_SIZE or lz >= VoxelChunk.HALO_SIZE:
				return VoxelChunkGenerator.generate_arrays_runtime(local_voxels, materials, {"scale": scale, "offset": Vector3.ZERO})
			halo[lx + ly * VoxelChunk.HALO_SIZE + lz * VoxelChunk.HALO_SIZE * VoxelChunk.HALO_SIZE] = int(local_voxels[pos_key])
		var aligned := VoxelMaterial.align_by_id(materials)
		var result := VoxelChunkGenerator.generate_single_chunk_dense(
			halo, aligned, scale, Vector3i.ZERO, Vector3.ZERO)
		if result != null and not result.is_empty():
			return result
	return VoxelChunkGenerator.generate_arrays_runtime(local_voxels, materials, {"scale": scale, "offset": Vector3.ZERO})


## 掉落体 mesh 组装入口（GPU 忙感知）：
## GPU 空闲时立即组装 ArrayMesh；GPU 满载时结果入队，由 _process 帧尾限量组装，
## 避免 add_surface_from_arrays 的同步 GPU 上传在 Metal 满载时 fence wait() 超时
func _on_falling_chunk_mesh_result(body: RigidBody3D, arrays: Variant, local_voxels: Dictionary = {}, hull_points: PackedVector3Array = PackedVector3Array()) -> void:
	if body == null or not is_instance_valid(body) or body.is_queued_for_deletion():
		return
	if arrays == null or not arrays is Dictionary or (arrays as Dictionary).is_empty():
		return
	if _is_gpu_busy():
		_pending_mesh_results.append({
			"body": body, "arrays": arrays as Dictionary, "local_voxels": local_voxels,
			"hull_points": hull_points,
		})
		return
	_apply_falling_chunk_mesh(body, arrays as Dictionary, local_voxels, hull_points)


## GPU 忙检测：上一帧渲染耗时（_delta）是否超过阈值
## 用帧时长而非 RenderingServer 测量 API（部分驱动返回 0 不可靠）
func _is_gpu_busy() -> bool:
	return _last_frame_delta > _gpu_busy_threshold_ms / 1000.0


## 每帧从队列限量组装掉落体 mesh（GPU 忙时积压的结果）
## 由 VoxelDestructible._process 帧尾调用
func _process_pending_mesh_results() -> void:
	if _pending_mesh_results.is_empty():
		return
	# 组装前先确认 GPU 已恢复：仍忙则继续等（积压不丢数据）
	if _is_gpu_busy():
		return
	var count := 0
	while not _pending_mesh_results.is_empty() and count < _mesh_apply_per_frame:
		var entry: Dictionary = _pending_mesh_results.pop_front()
		var body: RigidBody3D = entry.get("body")
		if body != null and is_instance_valid(body) and not body.is_queued_for_deletion():
			_apply_falling_chunk_mesh(body, entry.get("arrays"), entry.get("local_voxels", {}), entry.get("hull_points", PackedVector3Array()))
			count += 1
	if diag_enabled and count > 0:
		print("[诊断] 掉落体mesh组装: 本帧%d, 剩余%d" % [count, _pending_mesh_results.size()])


## 主线程：把后台生成的数组组装为 ArrayMesh 并挂载到掉落块
## 碰撞方案按块体素数自动选择：
##   <= AUTO_BOX_VOXELS → BoxShape3D 包围盒（物理开销低，中小块够用）
##   >  AUTO_BOX_VOXELS → ConvexPolygonShape3D 凸包（贴合大块轮廓）
func _apply_falling_chunk_mesh(body: RigidBody3D, arrays: Dictionary, local_voxels: Dictionary = {}, hull_points: PackedVector3Array = PackedVector3Array()) -> void:
	if body == null or not is_instance_valid(body) or body.is_queued_for_deletion():
		return
	if arrays == null or arrays.is_empty():
		return
	var mesh := VoxelChunkGenerator.build_mesh_from_arrays(arrays)
	if mesh == null:
		return
	var chunk_materials := _get_cached_chunk_materials()
	if chunk_materials.size() >= 2:
		if mesh.get_surface_count() > 0 and chunk_materials[0]:
			mesh.surface_set_material(0, chunk_materials[0])
		if mesh.get_surface_count() > 1 and chunk_materials[1]:
			mesh.surface_set_material(1, chunk_materials[1])
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	body.add_child(mi)
	mi.owner = body

	# 按体素数自动选碰撞方案：大块（>AUTO_BOX_VOXELS）用凸包贴合轮廓，中小块用 Box 降低物理开销
	if local_voxels.size() > AUTO_BOX_VOXELS:
		# 【凸包后台化】碰撞外壳点集由后台线程预计算（_compute_hull_points，O(1)），
		# 此处 set_points 秒完成——替代 create_convex_shape（4096体素块实测69ms主线程卡顿）。
		# hull_points 为空（旧路径/兼容）时回退 create_convex_shape。
		if hull_points.is_empty():
			var shape := mesh.create_convex_shape(true, true)
			if shape:
				var col := CollisionShape3D.new()
				col.name = "CollisionShape3D"
				col.shape = shape
				body.add_child(col)
				col.owner = body
		else:
			var convex := ConvexPolygonShape3D.new()
			convex.set_points(hull_points)
			var col := CollisionShape3D.new()
			col.name = "CollisionShape3D"
			col.shape = convex
			body.add_child(col)
			col.owner = body
	else:
		# Box 包围盒：用体素位置计算包围盒（最简、最快）
		_add_box_collision(body, local_voxels)


## Box 包围盒碰撞体：local_voxels 键为相对块中心的整数坐标，计算包围盒作为单一 Box
## （最简碰撞方案，物理开销最低；空心块会被填满，贴合度差）
func _add_box_collision(body: RigidBody3D, local_voxels: Dictionary) -> void:
	var scale := voxel_scale
	if local_voxels.is_empty():
		return
	var min_p := Vector3i(local_voxels.keys()[0])
	var max_p := min_p
	for pos_key in local_voxels:
		var p: Vector3i = pos_key
		min_p = Vector3i(mini(min_p.x, p.x), mini(min_p.y, p.y), mini(min_p.z, p.z))
		max_p = Vector3i(maxi(max_p.x, p.x), maxi(max_p.y, p.y), maxi(max_p.z, p.z))
	var size := Vector3(max_p - min_p) + Vector3.ONE
	var shape := BoxShape3D.new()
	shape.size = size * scale
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape
	col.position = (Vector3(min_p) + Vector3(size) * 0.5) * scale
	body.add_child(col)
	col.owner = body


## 获取（并缓存）掉落块共用材质。同一 data.materials 实例在生命周期内稳定，只需生成一次。
func _get_cached_chunk_materials() -> Array:
	if _chunk_materials_cache_src == data.materials and not _chunk_materials_cache.is_empty():
		return _chunk_materials_cache
	_chunk_materials_cache = VoxelMeshGenerator.generate_textured_materials_runtime(data.materials)
	_chunk_materials_cache_src = data.materials
	return _chunk_materials_cache


## 从对象池获取一个空闲 RigidBody3D（池满时新建，但受池总容量约束）
func _acquire_body() -> RigidBody3D:
	if not _body_pool.is_empty():
		var body: RigidBody3D = _body_pool.pop_back()
		# 复位：清除旧子节点（mesh/碰撞），解除冻结，复位旋转/位置
		for child in body.get_children():
			body.remove_child(child)
			child.queue_free()
		body.freeze = false
		body.rotation = Vector3.ZERO
		body.position = Vector3.ZERO
		return body
	# 池空：新建（若已达总容量上限则仍新建，由 _spawn_falling_chunk 的守卫控制降级）
	var new_body := RigidBody3D.new()
	new_body.name = "FallingChunk_%d_Body" % _falling_chunk_id
	_falling_chunk_id += 1
	new_body.gravity_scale = 1.0
	_body_pool_total.append(new_body)
	return new_body


## 释放物理体回池（复用，避免反复创建/销毁）
## 先从场景移除，复位状态后入空闲池
func _release_body(body: RigidBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	# 【改进3】回收前播放粒子破碎效果：块从场景消失时"哗啦碎成粒子"，
	# 而非凭空消失。用块自身的位置 + 记录的体素信息生成整块碎裂粒子。
	_spawn_chunk_break_at_body(body)
	# 断开落地检测连接（池复用：避免下次连接重复/旧引用泄漏）
	for conn in body.body_entered.get_connections():
		body.body_entered.disconnect(conn["callable"])
	_chunk_spawn_times.erase(body)
	if body.get_parent():
		body.get_parent().remove_child(body)
	# 复位（mesh/碰撞子节点在下次 _acquire_body 时清理）
	body.freeze = true
	body.sleeping = true
	body.position = Vector3.ZERO
	# 关键：复位旋转（落地翻滚过的 body 带着旧角度，不复位会导致下次复用角度怪异）
	body.rotation = Vector3.ZERO
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.remove_meta("local_voxels")
	_body_pool.append(body)


## 在掉落块当前位置播放"整块碎裂"粒子（回收时视觉过渡）
## 从 body 记录的体素信息重建破碎粒子，用块中心作为发射中心
## 视锥外不执行（相机看不到，跳过昂贵粒子效果）
func _spawn_chunk_break_at_body(body: RigidBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var local_voxels: Dictionary = body.get_meta("local_voxels", {})
	if local_voxels.is_empty():
		return
	# 发射中心 = 块中心（body 仍在场景中时的全局位置）
	var center := body.global_position
	# 视锥外跳过（看不到的破碎不需要粒子）
	if not is_world_visible(center):
		return
	var emission_size := Vector3(2.0, 2.0, 2.0) * voxel_scale
	# 按材质分组发射破碎粒子
	var by_mat := {}
	for pos_key in local_voxels:
		var mat_id: int = int(local_voxels[pos_key])
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos_key)
	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		var mat_mass: float = _get_material_mass(mat_id)
		var amount := mini(list.size(), 200)
		_spawn_debris_particles(center, mat_id, amount, mat_mass, true, emission_size)


## 清理已停稳或超时的掉落块（回池复用，而非销毁）
func _cleanup_falling_chunk(body: RigidBody3D) -> void:
	if body and is_instance_valid(body):
		_release_body(body)


## 数量上限时剔除最老的掉落块，腾出名额给新块（保证新块必生成）。
## 只移除 count 个，避免一次性清空导致大规模级联时块突然全部消失。
## 返回实际逐出的数量（供调用方判断是否腾出名额成功）
func _evict_oldest_falling_chunks(count: int) -> int:
	if count <= 0 or not _falling_chunk_root:
		return 0
	var alive: Array = []
	for child in _falling_chunk_root.get_children():
		if child is RigidBody3D and is_instance_valid(child):
			alive.append(child)
	if alive.is_empty():
		return 0
	alive.sort_custom(func(a, b): return _chunk_spawn_times.get(a, 0) < _chunk_spawn_times.get(b, 0))
	var evicted := 0
	for body in alive:
		if count <= 0:
			break
		if is_instance_valid(body):
			_cleanup_falling_chunk(body)
			count -= 1
			evicted += 1
	# 清理已失效引用，避免字典残留
	for body in _chunk_spawn_times.keys():
		if not is_instance_valid(body):
			_chunk_spawn_times.erase(body)
	return evicted


## 落地检测：掉落块碰触地面/其他物体时触发
## 启动一个短延迟后检测物理体是否已静止，静止则冻结以节省物理开销
func _on_chunk_landed(_body: Node, chunk_body: RigidBody3D) -> void:
	if not chunk_body or not is_instance_valid(chunk_body):
		return
	# 延迟 0.5 秒后检测是否静止
	var tree := get_tree()
	if not tree:
		return
	var timer := tree.create_timer(0.5)
	timer.timeout.connect(_try_freeze_chunk.bind(chunk_body))


## 尝试冻结已静止的掉落块（不消失，只冻结物理模拟节省性能）
func _try_freeze_chunk(body: RigidBody3D) -> void:
	if not body or not is_instance_valid(body):
		return
	if body.sleeping:
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC


## 定期检测所有掉落块，将长时间静止的块冻结
## 同时做生命周期清理（作用于所有掉落块，含未冻结仍在掉落的）：
##   - 超时：生成超过 falling_chunk_cleanup_time 的块移除
##   - 数量上限：超出 max_falling_chunks 时按生成先后移除最老的（复用 _evict_oldest_falling_chunks）
## 防止大量破坏后物理体+网格无限堆积拖慢帧率（用户反馈的帧率下降问题）
func _freeze_sleeping_chunks() -> void:
	if not _falling_chunk_root:
		return
	var now := Time.get_ticks_msec()

	# 1. 单次遍历：冻结静止块 + 收集存活块（按生成时刻排序）
	var alive: Array = []
	for child in _falling_chunk_root.get_children():
		var body := child as RigidBody3D
		if not body:
			continue
		if not body.freeze and body.sleeping:
			body.freeze = true
			body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		alive.append(body)
	if alive.is_empty():
		return
	alive.sort_custom(func(a, b): return _chunk_spawn_times.get(a, 0) < _chunk_spawn_times.get(b, 0))

	# 2. 超时清理：生成超过 falling_chunk_cleanup_time 的块移除（含未冻结的）
	var cleanup_ms := int(falling_chunk_cleanup_time * 1000.0)
	for body in alive:
		if not is_instance_valid(body):
			continue
		if now - _chunk_spawn_times.get(body, 0) >= cleanup_ms:
			_cleanup_falling_chunk(body)

	# 3. 数量上限清理：超出 max_falling_chunks 时移除最老的（复用统一逐出逻辑）
	var overflow := alive.size() - int(max_falling_chunks)
	if overflow > 0:
		_evict_oldest_falling_chunks(overflow)

	# 4. 清理已失效引用（queue_free 是延迟的，这里只清记录，避免字典残留）
	for body in _chunk_spawn_times.keys():
		if not is_instance_valid(body):
			_chunk_spawn_times.erase(body)


## 找出所有"失稳"体素，返回这些体素位置的并集
## 连通性支撑判断：从贴地(y==0)体素 6 方向 BFS 标记所有"与地面连通"的体素，
## 与地面断开（完全悬空）的体素才会脱落
## around_positions 为本次破坏移除的体素位置：
##   - 局部增量(local_collapse=true)：只检查破坏位置 6 邻附近可能失稳的体素，
##     避免每次破坏都全量 BFS，适合中频破坏 + 中型场景
##   - 全量检测(local_collapse=false)：全局遍历，结果最精确，适合小型场景/低频
## around_positions 为空时回退全量检测
func _find_unstable_voxels(around_positions: Array = []) -> Array:
	if data.is_empty():
		return []

	var unstable_set: Dictionary
	if local_collapse and not around_positions.is_empty():
		unstable_set = data.find_unsupported_around(around_positions)
	else:
		unstable_set = data.find_unsupported()
	if diag_enabled:
		print("[诊断] _find_unstable_voxels: around=%d, 局部=%s, 结果=%d" % [around_positions.size(), (local_collapse and not around_positions.is_empty()), unstable_set.size()])

	var unstable: Array = []
	for key in unstable_set:
		unstable.append(key)
	return unstable


## 全量校验当前场景的悬空体素并触发崩塌（局部检测的初始化）
## 局部检测只关注破坏点附近，无法发现"初始就悬空"的结构（如浮岛装饰）
## 在加载关卡/读取存档后调用一次，确保场景进入静态稳定状态
## 之后破坏导致的失稳由局部检测负责
## 统一使用整块物理体掉落（FallingChunk），而非粒子碎片
func validate_stability() -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var unstable := _find_unstable_voxels([])  # 空 around → 全量检测
	if unstable.is_empty():
		return
	# 按连通性分组，每组生成一个 FallingChunk
	var groups := VoxelData.partition_connected(unstable)
	# 收集每组体素的材质ID（在移除前）
	var group_materials: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = data.get_voxel(pos)
		group_materials.append(mat_map)
	data.remove_voxels(unstable)
	if not Engine.is_editor_hint():
		_spawn_falling_chunks_from_groups(groups, group_materials)
	voxels_about_to_collapse.emit(unstable)
	voxel_damaged.emit(unstable, true)
	last_collapse_count = unstable.size()


# ----------------------------------------------------------------------------
# 碎片系统：粒子系统（无物理碰撞体）
# ----------------------------------------------------------------------------

func _ensure_debris_root() -> void:
	if not _debris_root:
		_debris_root = Node3D.new()
		_debris_root.name = _DEBRIS_ROOT_NAME
		add_child(_debris_root, false, Node.INTERNAL_MODE_BACK)


func _collect_voxel_materials(positions: Array) -> Dictionary:
	var mat_map := {}
	if not data:
		return mat_map
	for pos in positions:
		# 使用 get_voxel 安全访问，不存在时返回 -1（类型化字典直接 [] 访问缺失键会抛异常）
		mat_map[pos] = data.get_voxel(pos)
	return mat_map


## 整块碎裂粒子：当物理体池已满、大块无法生成物理体时，
## 把整块转成"从块包围盒范围发射"的粒子，保留"整块碎裂散开"的视觉，
## 而非从质心一点发射导致"大块突然消失"。
## 粒子数量按块大小比例（不受 max_debris_per_hit 限制，避免大块只剩几个粒子）
func _spawn_chunk_break_debris(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()

	# 计算块包围盒（世界单位）
	var min_v := Vector3(positions[0]) * voxel_scale
	var max_v := min_v
	for pos in positions:
		var p: Vector3 = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	var center := (min_v + max_v) * 0.5
	var emission_size := max_v - min_v

	# 视锥外跳过（相机看不到的整块碎裂，不生成粒子）
	# center 为体素世界坐标（相对 target），转全局坐标判定
	if not is_world_visible(center + global_position):
		return

	# 按材质分组（大块不再截断粒子数，按块大小比例）
	var by_mat := {}
	for pos in positions:
		var mat_id: int = mat_map.get(pos, -1)
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos)

	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		var mat_mass: float = _get_material_mass(mat_id)
		# 粒子数量 = 该材质体素数（上限保护，避免超大块粒子爆炸）
		var amount := mini(list.size(), 600)
		_spawn_debris_particles(center, mat_id, amount, mat_mass, true, emission_size)


## 生成碎片粒子（全部使用 GPU 粒子系统，无物理碰撞体）
## 在指定位置发射碎片粒子
## is_collapse=true 时，粒子向下坠落（崩塌效果），否则向上喷发（爆炸效果）
func _spawn_debris_with_materials(positions: Array, mat_map: Dictionary, is_collapse: bool = false) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	# 按材质分组，每组发射一个粒子系统
	var by_mat := {}
	for i in range(count):
		var pos: Vector3i = positions[i]
		var mat_id: int = mat_map.get(pos, -1)
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos)

	# 粒子发射中心：所有碎片位置的质心
	var center := Vector3.ZERO
	var n := 0
	for pos in positions:
		center += (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
		n += 1
	if n > 0:
		center /= float(n)

	# 视锥外跳过（相机看不到的破坏，不生成粒子，省 GPU）
	# 注意：center 是局部坐标，需加 global_position 转世界坐标再判定
	if not is_world_visible(center + global_position):
		return

	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		# 获取材质的 mass，用于调整粒子运动表现
		var mat_mass: float = _get_material_mass(mat_id)
		_spawn_debris_particles(center, mat_id, list.size(), mat_mass, is_collapse)


## 获取材质的质量
func _get_material_mass(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id] as VoxelMaterial
		if m:
			return maxf(m.mass, 0.1)
	return 1.0


## 在指定位置发射一批碎片粒子（GPUParticles3D）
## 粒子碰撞自然落地，无 RigidBody 物理开销
## 粒子运动受材质 mass 影响：重物飞得近/落得快，轻物飞得远/飘得久
## is_collapse=true 时粒子向下坠落（崩塌效果），false 时向上喷发（爆炸效果）
## emission_size: 若提供，粒子从该尺寸的盒形范围发射（模拟"整块碎裂散开"而非质心一点）
func _spawn_debris_particles(center: Vector3, mat_id: int, amount: int, mat_mass: float = 1.0, is_collapse: bool = false, emission_size: Vector3 = Vector3.ZERO) -> void:
	if amount <= 0:
		return
	# mass 影响因子：质量越大，速度越慢、重力越大、喷发角度越小
	# 用 1/sqrt(mass) 使效果平滑：mass=0.5→速度×1.41, mass=2.0→速度×0.71
	var mass_factor := 1.0 / sqrt(mat_mass)

	# 【粒子池化】优先复用空闲粒子节点，避免每次破坏新建 GPUParticles3D 节点
	# （大崩塌一帧创建几十个粒子系统的开销来源）
	var particles: GPUParticles3D
	if not _particle_pool.is_empty():
		particles = _particle_pool.pop_back()
	else:
		particles = GPUParticles3D.new()
		particles.name = "DebrisParticles"
	# 池中节点回池时已移除父节点，取出后统一挂载（避免重复 add_child）
	if not particles.is_inside_tree():
		_ensure_debris_root()
		_debris_root.add_child(particles)
	particles.visible = true
	_active_particle_count += 1

	particles.position = center
	particles.amount = amount
	# 粒子停留时间：重物落地快，生命周期缩短；轻物飘得久
	particles.lifetime = maxf(debris_lifetime / maxf(mass_factor, 0.3), 2.0)
	particles.explosiveness = 1.0
	particles.one_shot = true
	particles.local_coords = true
	particles.restart()
	# 碰撞仅在 visibility_aabb 区域内发生，扩大以覆盖粒子运动范围
	var half_extent := maxf(emission_size.length(), 8.0)
	particles.visibility_aabb = AABB(Vector3(-half_extent, -4, -half_extent), Vector3(half_extent * 2, 16 + half_extent, half_extent * 2))

	# 粒子材质：碰撞(刚体) + 高摩擦(落地停住) + 无弹性(不反弹)
	var pm := ParticleProcessMaterial.new()
	pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	pm.collision_friction = 1.0  # 最大摩擦：粒子落地后原地停住
	pm.collision_bounce = 0.0    # 无弹性：落地不反弹

	# 粒子运动受 mass 影响：
	# - 重物 (mass 大)：速度慢、重力大、喷发角度小（向下坠）
	# - 轻物 (mass 小)：速度快、重力小、喷发角度大（四处飞散）
	# 方向模式：
	# - 崩塌 (is_collapse=true)：向下坠落，窄扩散，像石块塌落
	# - 爆炸 (is_collapse=false)：向上喷发，宽扩散，像爆炸碎片
	if is_collapse:
		# 崩塌模式：粒子向下坠落，窄扩散，低速度
		pm.direction = Vector3(0, -1, 0)
		pm.spread = 15.0
		pm.initial_velocity_min = 1.0
		pm.initial_velocity_max = 3.0
		pm.gravity = Vector3(0, -9.8 * mass_factor, 0)
		pm.angular_velocity_min = -3.0
		pm.angular_velocity_max = 3.0
	else:
		# 爆炸模式：粒子向上喷发，宽扩散，高速度
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 45.0 * (1.0 + 0.3 / mass_factor)
		pm.initial_velocity_min = debris_speed_range.x * 0.8 * mass_factor
		pm.initial_velocity_max = debris_speed_range.y * 0.8 * mass_factor
		pm.gravity = Vector3(0, -20.0 * debris_gravity_scale * mass_factor, 0)
		pm.angular_velocity_min = -6.0 * mass_factor
		pm.angular_velocity_max = 6.0 * mass_factor
	pm.scale_min = 1.0
	pm.scale_max = 1.0

	# 发射范围：若提供 emission_size，粒子从盒形范围发射（模拟整块碎裂散开）
	if emission_size.length() > 0.001:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = emission_size * 0.5

	# 淡出：从生命周期 50% 开始慢慢渐变到透明（共用缓存资源，避免每次破坏都新建 Gradient/GradientTexture1D）
	pm.alpha_curve = _get_particle_fade_gradient()
	particles.process_material = pm

	# 碎片用立方体 mesh，尺寸 = 原体素大小
	var mesh := _get_particle_mesh(mat_id)
	particles.draw_pass_1 = mesh

	# one_shot 粒子发射完自动触发 finished → 回池复用
	# 复用前先断开旧连接，避免迟到信号重复回池
	if particles.finished.is_connected(_on_particle_finished):
		particles.finished.disconnect(_on_particle_finished)
	particles.finished.connect(_on_particle_finished.bind(particles))


## one_shot 粒子发射完成回调：回池复用
func _on_particle_finished(gp: GPUParticles3D) -> void:
	_cleanup_particles(gp)


## 获取粒子淡出渐变（按需创建一次并缓存复用）
func _get_particle_fade_gradient() -> GradientTexture1D:
	if _particle_fade_gradient:
		return _particle_fade_gradient
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	fade.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0),
	])
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = fade
	_particle_fade_gradient = alpha_tex
	return alpha_tex


## 获取粒子的立方体 mesh（缓存按材质 ID 复用）
func _get_particle_mesh(mat_id: int) -> Mesh:
	var key := str(mat_id)
	if _particle_mesh_cache.has(key):
		return _particle_mesh_cache[key]
	var box := BoxMesh.new()
	box.size = Vector3(voxel_scale, voxel_scale, voxel_scale)
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var mat_res = data.materials[mat_id]
		if mat_res:
			var m := StandardMaterial3D.new()
			m.albedo_color = VoxelMaterial.albedo_color(mat_res)
			m.metallic = mat_res.metal
			m.roughness = mat_res.rough
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			# 启用透明度让 alpha_curve 淡出生效
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			box.material = m
	_particle_mesh_cache[key] = box
	return box


## 粒子生命周期结束：回收到池中复用（避免每次破坏新建/销毁 GPUParticles3D 节点）
## 回池时从树移除 + 断开 finished 信号，取出时统一重新挂载
func _cleanup_particles(p: Node) -> void:
	if p == null or not is_instance_valid(p):
		return
	_active_particle_count = maxi(_active_particle_count - 1, 0)
	if p is GPUParticles3D and _particle_pool.size() < PARTICLE_POOL_MAX:
		var gp := p as GPUParticles3D
		gp.emitting = false
		gp.visible = false
		if gp.is_inside_tree():
			gp.get_parent().remove_child(gp)
		if gp.finished.is_connected(_on_particle_finished):
			gp.finished.disconnect(_on_particle_finished)
		_particle_pool.append(gp)
	else:
		p.queue_free()


func _clear_debris() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	# 清空粒子池（场景退出时全部释放）
	for gp in _particle_pool:
		if is_instance_valid(gp):
			gp.queue_free()
	_particle_pool.clear()
	_active_particle_count = 0
	_particle_mesh_cache.clear()


# ----------------------------------------------------------------------------
# 主循环
# ----------------------------------------------------------------------------

## 帧尾合并发射硬化反馈信号：一次破坏几百个体素未摧毁时，
## 避免逐体素 emit voxel_hardened（几百次信号/破坏 → 高频轰炸外部监听器），
## 累积后统一发一次 voxel_hardened_batch（兼发兼容性单发信号到已连接监听器）。
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
	super._process(_delta)
	if Engine.is_editor_hint():
		return

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
	_process_pending_falling_groups()
	# 帧尾：GPU 忙时积压的掉落体 mesh 限量组装（add_surface_from_arrays 同步 GPU 上传）
	_process_pending_mesh_results()

	# 帧尾：合并发射硬化反馈（一次破坏几百个体素未摧毁时，避免逐体素高频信号）
	_flush_hardened_signals()

# 定期检测掉落块：按时间间隔（约 1 秒）冻结静止块 + 生命周期清理（上限/超时）。
	# 用累计时间而非固定帧数，避免帧率下降时清理频率同步下降的恶性循环。
	_sleep_check_counter += _delta
	if _sleep_check_counter >= 1.0:
		_sleep_check_counter = 0.0
		_freeze_sleeping_chunks()

	if diag_enabled:
		var _total_ms := (Time.get_ticks_usec() - _diag_t0) / 1000.0
		if _total_ms > 3.0:
			print("[诊断] VoxelDestructible._process 总耗时: %.2f ms" % _total_ms)


## 延迟破坏管道：每帧处理所有累积的待移除体素（去重合并后）
## 同一帧内多次伤害相同位置合并去重，仅执行一次移除 + 崩塌检测 + 碎片生成
func _process_destruction_pipeline() -> void:
	if _pending_removed.is_empty():
		return

	var _diag_t0 := Time.get_ticks_usec() if diag_enabled else 0

	# 提取所有待移除位置（去重后的唯一键）
	var removed: Array = _pending_removed.keys()
	var do_spawn: bool = _pending_spawn_debris
	_pending_removed.clear()
	_pending_spawn_debris = false

	if removed.is_empty():
		return

	# 0. 先在移除前收集材质快照（避免移除后 data.voxels 中找不到）
	var mat_map := _collect_voxel_materials(removed) if do_spawn and not Engine.is_editor_hint() else {}
	var _diag_t1 := Time.get_ticks_usec() if diag_enabled else 0

	# 1. 实际移除体素（触发 mesh 脏标记 → 下一帧 _process 自动重建）
	data.remove_voxels(removed)
	var _diag_t2 := Time.get_ticks_usec() if diag_enabled else 0

	# 2. 应力传播 + 崩塌检测 + 处理（同步，轻量 BFS）
	_after_removal(removed)
	var _diag_t3 := Time.get_ticks_usec() if diag_enabled else 0

	# 3. 生成粒子碎片（使用第 0 步收集的材质快照）
	if do_spawn and not Engine.is_editor_hint() and not mat_map.is_empty():
		_spawn_debris_with_materials(removed, mat_map)
	var _diag_t4 := Time.get_ticks_usec() if diag_enabled else 0

	# 4. 信号
	voxel_damaged.emit(removed, do_spawn)

	if diag_enabled:
		var _t_total := (_diag_t4 - _diag_t0) / 1000.0
		var _t_collect := (_diag_t1 - _diag_t0) / 1000.0
		var _t_remove := (_diag_t2 - _diag_t1) / 1000.0
		var _t_after := (_diag_t3 - _diag_t2) / 1000.0
		var _t_debris := (_diag_t4 - _diag_t3) / 1000.0
		if _t_total > 1.0:
			print("[诊断] 破坏管道: 共%d体素, 总%.2fms | 收集材质%.2f | 移除%.2f | 应力/崩塌%.2f | 粒子%.2f" % [removed.size(), _t_total, _t_collect, _t_remove, _t_after, _t_debris])