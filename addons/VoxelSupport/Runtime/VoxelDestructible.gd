@tool
class_name VoxelDestructible
extends VoxelRenderer

const _CHUNK_GEN := preload("res://addons/VoxelSupport/VoxelChunkGenerator.gd")

## 动态体素破坏系统
## 继承 VoxelRenderer，在渲染基础上提供体素破坏能力
## 支持球形/盒形/单体素/射线破坏 + 逐体素健康度 + 悬空崩塌 + 碎片系统
## 破坏直接修改 VoxelDataResource，自动触发 mesh 重新生成

## 破坏反馈信号：具体表现（粒子/音效/震动）由游戏自行连接实现
signal voxel_damaged(positions: Array, spawn_debris: bool)      ## 体素被移除时 (含崩塌)
signal voxel_hardened(pos: Vector3i, remaining: float)          ## 体素受伤但未摧毁 (材质硬度未达)
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

## 碎片模式枚举
enum DebrisMode {
	DEBRIS_PHYSICS,  ## 物理碎片：每个碎片是 RigidBody3D，真实物理但 Draw Call 多
	DEBRIS_VISUAL,   ## 视觉碎片：MultiMeshInstance3D 实例化，单 Draw Call 高性能
}

## 崩塌掉落模式枚举
enum CollapseMode {
	COLLAPSE_NONE,   ## 不启用悬空崩塌
	COLLAPSE_DEBRIS, ## 悬空体素转成动态碎片掉落
}

## 崩塌判定模式
enum CollapseRule {
	RULE_CONNECTED,    ## 仅连通性：与地面完全断开才脱落（最简，速度快）
	RULE_SEGMENTED,    ## 分级脱落：连通断开 + 承载超载才脱落（接触面承载强度）
}

## 破坏时是否生成碎片
@export var spawn_debris_on_damage: bool = true

## 单次破坏生成的最大碎片数量 (性能保护)
@export var max_debris_per_hit: int = 64

## 碎片模式
@export var debris_mode: DebrisMode = DebrisMode.DEBRIS_PHYSICS:
	set(v):
		debris_mode = v
		_clear_debris()

## 崩塌掉落模式
@export var collapse_mode: CollapseMode = CollapseMode.COLLAPSE_DEBRIS

## 崩塌判定规则
## RULE_CONNECTED：只按连通性（与地面断开即脱），最简最快
## RULE_SEGMENTED：连通断开 + 承载超载才脱（分级），需配合下面两个系数
## 判定 = 悬空块总重量(mass之和) > 接触面承载强度(连接体素硬度之和 × 系数)
@export var collapse_rule: CollapseRule = CollapseRule.RULE_CONNECTED

## 支撑强度系数：单个支撑体素(接触面连接体素)能承受的重量
## 承载能力 = Σ(接触面连接体素的 hardness) × 该系数
## 值越大，同等硬度的支撑能撑住越重的悬空块；越小越易断裂
@export var collapse_support_strength: float = 15.0

## 分级脱落是否统计材质质量(mass)：关闭时每个体素按重量 1 计（仅按连接数分级）
## 开启时重量 = 材质 mass 之和（重型材质更易压断薄支撑）
@export var segmented_use_mass: bool = true

## 分级脱落是否统计连接体素硬度(hardness)：关闭时每个连接体素强度按 1 计（仅按接触面个数分级）
## 开启时承载能力 = Σ(hardness × 系数)（高硬度支撑更不易断）
@export var segmented_use_hardness: bool = true

## 逐体素健康度系统开关：关闭时忽略材质硬度，一击即碎
@export var use_voxel_health: bool = true

## 单次破坏对每个体素造成的伤害 (逐体素健康度用)
## 结合材质 hardness，伤害累积达到 hardness 才真正移除体素
@export var damage_per_voxel: float = 1.0

## 碎片初始速度范围 (物理模式)
@export var debris_min_speed: float = 2.0
@export var debris_max_speed: float = 6.0

## 碎片生命周期 (秒) —— 落地保留的碎片不受此限制，仅影响仍在运动的碎片
@export var debris_lifetime: float = 3.0

## 碎片大小倍数 (相对于体素 scale)
@export var debris_size_scale: float = 0.9

## 碎片重力倍数
@export var debris_gravity_scale: float = 1.0

## 碎片落地判定速度阈值 (低于该速度认为静止，转静态保留)
@export var debris_rest_threshold: float = 0.5

## 碎片池大小 (物理碎片对象池，减少创建/销毁开销)
@export var debris_pool_size: int = 128

## 落地保留碎片的最大数量 (防止长时间运行内存/节点无限增长)
## 超过上限时，最早落地的碎片会被回收释放
@export_range(0, 1000) var max_settled_debris: int = 200

## 整体健康度 (<=0 时触发完全破坏，-1 表示不启用健康度系统)
@export var health: float = -1.0

## 监控统计
var debris_count: int = 0          ## 当前存活碎片数
var last_damage_count: int = 0     ## 最近一次破坏实际移除的体素数
var last_damage_time_ms: float = 0 ## 最近一次破坏耗时 (ms)
var last_collapse_count: int = 0   ## 最近一次崩塌的悬空体素数

## 逐体素累计伤害 (位置 -> 累计伤害)
var damage_map: Dictionary[Vector3i, float] = {}

var _debris_root: Node3D = null
var _debris_pool: Array[RigidBody3D] = []          # 物理碎片对象池 (空闲)
var _settled_debris: Array[RigidBody3D] = []       # 已落地保留的碎片
var _active_debris: Array[RigidBody3D] = []        # 仍在运动的物理碎片 (供 _settle 遍历)
var _debris_mesh_cache: Dictionary = {}            # "mat_id:size" -> BoxMesh

# 异步崩塌 mesh 生成状态
var _collapse_task_id := -1
var _collapse_blocks_data: Array = []              # 每个元素的块信息 {voxels, min, max, center}
var _collapse_results: Array = []                  # 后台生成的 mesh arrays (与 _collapse_blocks_data 对应)
var _collapse_pending := false

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()


func _exit_tree() -> void:
	_clear_debris()


# ----------------------------------------------------------------------------
# 破坏入口
# ----------------------------------------------------------------------------

## 球形破坏: 对中心点半径内的体素造成伤害
## center 为体素空间坐标 (1单位 = 1体素)，radius 单位同上
## 返回实际被移除(彻底摧毁)的体素位置数组
func damage_sphere(center: Vector3, radius: float, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	var positions := data.get_voxels_in_sphere(center, radius)
	var mat_map := _collect_voxel_materials(positions)
	var removed := _apply_damage(positions, mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 盒形破坏
func damage_box(aabb: AABB, spawn_debris: Variant = null) -> Array:
	if not data:
		return []
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var t0 := Time.get_ticks_usec()
	var positions := data.get_voxels_in_box(aabb)
	var mat_map := _collect_voxel_materials(positions)
	var removed := _apply_damage(positions, mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
	last_damage_time_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return removed


## 单体素破坏
func damage_voxel(pos: Vector3i, spawn_debris: Variant = null) -> bool:
	if not data or not data.has_voxel(pos):
		return false
	var do_spawn: bool = spawn_debris if spawn_debris is bool else spawn_debris_on_damage
	var mat_map := _collect_voxel_materials([pos])
	var removed := _apply_damage([pos], mat_map, damage_per_voxel, do_spawn)
	if not removed.is_empty():
		_after_removal(removed)
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

## 对一组体素应用伤害，返回实际被彻底移除的体素
## 若开启逐体素健康度，累计伤害达到材质 hardness 才移除；否则一击即碎
func _apply_damage(positions: Array, mat_map: Dictionary, damage: float, do_spawn: bool) -> Array:
	var removed: Array = []
	var damaged_but_alive: Array = []
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
			# 伤害足够，摧毁体素
			damage_map.erase(pos)
			removed.append(pos)
		else:
			damage_map[pos] = cur
			damaged_but_alive.append([pos, hardness - cur])

	# 实际移除已摧毁的体素
	if not removed.is_empty():
		data.remove_voxels(removed)

	# 发出"受伤但未摧毁"反馈
	for entry in damaged_but_alive:
		voxel_hardened.emit(entry[0], entry[1])

	# 生成碎片 (仅对已移除的体素)
	if do_spawn and not Engine.is_editor_hint() and not removed.is_empty():
		var removed_map := {}
		for pos in removed:
			removed_map[pos] = mat_map.get(pos, -1)
		_spawn_debris_with_materials(removed, removed_map)

	last_damage_count = removed.size()
	return removed


func _get_material_hardness(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.hardness
	return 1.0


## 破坏后的统一处理：崩塌检测 + 整体健康度扣减
## removed 为本次破坏移除的体素位置，用于局部支撑检测（只在破坏位置附近做 BFS）
func _after_removal(removed: Array) -> void:
	# 触发悬空崩塌（局部检测：只检查破坏位置附近的悬空）
	_trigger_collapse(removed)
	# 整体健康度扣减
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()


# ----------------------------------------------------------------------------
# 悬空检测 + 崩塌掉落
# ----------------------------------------------------------------------------

## 检测并处理悬空体素（与地面/支撑断开的体素），崩塌成整块刚体掉落
## 局部支撑检测：只检查"破坏位置附近"的悬空，避免每次破坏都全场景 BFS
## around_positions 为本次破坏移除的体素位置；为空则做全场景检测
func _trigger_collapse(around_positions: Array = []) -> void:
	if collapse_mode == CollapseMode.COLLAPSE_NONE or not data:
		return
	var unstable := _find_unstable_voxels(around_positions)
	if unstable.is_empty():
		return
	# 崩塌前反馈信号
	voxels_about_to_collapse.emit(unstable)
	last_collapse_count = unstable.size()

	# 崩塌的悬空/支撑不足体素转成"整块刚体"掉落（按连通块分组）
	var mat_map := _collect_voxel_materials(unstable)
	data.remove_voxels(unstable)
	if not Engine.is_editor_hint():
		_spawn_collapse_blocks(unstable, mat_map)
	# 崩塌也算破坏，发信号
	voxel_damaged.emit(unstable, true)


## 找出所有"失稳"体素，返回这些体素位置的并集
## 连通性支撑判断：从贴地(y==0)体素 6 方向 BFS 标记所有"与地面连通"的体素，
## 与地面断开（完全悬空）的体素才会脱落
## 这样：破坏底部后，上方块若左右仍连到两侧(贴地)则保持稳定；只有与地面完全断开才脱落
## around_positions 参数保留(接口兼容)，但本算法基于全局连通性判断，保证正确性
##
## 分级脱落(RULE_SEGMENTED)：在连通断开基础上，再按"接触面承载强度"判定
##   - 悬空块按 6 方向连通分组
##   - 承载需求 = Σ(块内体素重量)，重量 = 材质 mass（若 segmented_use_mass）否则按 1
##   - 接触面 = 块中与 supported 集合相邻的体素（支撑连接点）
##   - 承载能力 = Σ(接触体素 hardness) × collapse_support_strength
##       （若 segmented_use_hardness）否则按接触体素数 × 系数
##   - 块超载(需求 > 能力)才脱落，否则保持稳定（防止"单点相连不断"的误判）
func _find_unstable_voxels(_around_positions: Array = []) -> Array:
	var voxels: Dictionary = data.voxels
	if voxels.is_empty():
		return []

	# 先按连通性判定：与地面断开的体素（完全悬空）
	var unstable_set: Dictionary = data.find_unsupported(voxels)
	if unstable_set.is_empty():
		return []

	if collapse_rule == CollapseRule.RULE_SEGMENTED:
		# 分级脱落：还需 supported 集合判定接触面
		var seeds: Array = []
		for key in voxels:
			var pos: Vector3i = key
			if pos.y == 0:
				seeds.append(key)
		var supported: Dictionary = data.flood_fill(seeds, voxels)
		return _apply_segmented_rule(unstable_set, supported)
	# RULE_CONNECTED：全部连通断开的体素都脱落
	var unstable: Array = []
	for key in unstable_set:
		unstable.append(key)
	return unstable


## 分级脱落：对连通断开的悬空块按"接触面承载强度"过滤
## unstable_set 为连通断开的集合；supported 为与地面连通的集合
func _apply_segmented_rule(unstable_set: Dictionary, supported: Dictionary) -> Array:
	var unstable_keys: Array = []
	for key in unstable_set:
		unstable_keys.append(key)
	# 悬空体素按连通块分组
	var blocks: Array = data.partition_connected(unstable_keys)
	var result: Array = []
	for block in blocks:
		if _block_should_collapse(block, supported):
			result.append_array(block)
	return result


## 单个悬空块是否超载脱落：承载需求 > 承载能力
## block 为悬空块体素位置数组；supported 为与地面连通的支撑集合 {pos:true}
func _block_should_collapse(block: Array, supported: Dictionary) -> bool:
	var demand := 0.0   # 承载需求 = 块总重量
	var capacity := 0.0 # 承载能力 = 接触面连接体素承载强度
	for p in block:
		var pos: Vector3i = p
		# 需求：块内每个体素的重量
		var mat_id: int = data.get_voxel(pos)
		demand += _get_material_mass(mat_id) if segmented_use_mass else 1.0
		# 能力：接触面 = 与该悬空块相邻的 supported 体素（真正的支撑连接点）
		for d: Vector3i in VoxelDataResource.get_neighbor_dirs():
			var nb := pos + d
			if supported.has(nb):
				var nb_mat: int = data.get_voxel(nb)
				capacity += _get_material_hardness(nb_mat) if segmented_use_hardness else 1.0
	return demand > capacity * collapse_support_strength





# ----------------------------------------------------------------------------
# 碎片系统：生成 / 池化 / 落地保留
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
		mat_map[pos] = data.voxels[pos]
	return mat_map


func _spawn_debris_with_materials(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	if debris_mode == DebrisMode.DEBRIS_PHYSICS:
		for i in count:
			var pos: Vector3i = positions[i]
			var mat_id: int = mat_map.get(pos, -1)
			_spawn_physics_debris(pos, mat_id, false)
	else:
		_spawn_visual_debris_batch(positions, mat_map, count)


## 崩塌掉落的悬空体素 → 按连通块分组，每个块作为一个整块刚体塌落
## 避免悬空体素"整体消失"，而是作为完整块从原位置落下
func _spawn_collapse_blocks(positions: Array, mat_map: Dictionary) -> void:
	_ensure_debris_root()
	if positions.is_empty():
		return
	# 将悬空体素按 6 方向连通分量分组
	var blocks := _partition_connected_blocks(positions)

	# 快照每个块的体素 + 包围盒信息，后台线程生成 mesh 数据（避免主线程卡顿）
	_collapse_blocks_data = []
	_collapse_results = []
	_collapse_pending = false
	for block in blocks:
		var block_voxels: Dictionary[Vector3i, int] = {}
		var min_pos := Vector3(99999, 99999, 99999)
		var max_pos := Vector3(-99999, -99999, -99999)
		for p in block:
			var pos: Vector3i = p
			block_voxels[pos] = mat_map.get(pos, -1)
			min_pos = min_pos.min(Vector3(pos))
			max_pos = max_pos.max(Vector3(pos))
		_collapse_blocks_data.append({
			"voxels": block_voxels,
			"min": min_pos,
			"max": max_pos,
		})

	# 材质深拷贝快照（子线程只读，避免与主线程冲突）
	var mat_snapshot: Array = data.materials.duplicate(true)
	var scale := voxel_scale
	# 启动后台生成任务（生成所有块的 mesh arrays）
	if _collapse_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_collapse_task_id)
	_collapse_task_id = WorkerThreadPool.add_task(
		_collapse_gen_worker.bind(_collapse_blocks_data, mat_snapshot, scale))


## 后台线程：为所有崩塌块生成 mesh arrays
func _collapse_gen_worker(blocks_data: Array, materials: Array, scale: float) -> void:
	var results: Array = []
	var options := {"scale": scale}
	for bd in blocks_data:
		var arrays: Variant = _CHUNK_GEN.generate_arrays_runtime(
			bd["voxels"] as Dictionary[Vector3i, int], materials, options)
		results.append(arrays)
	_collapse_results = results
	_collapse_pending = true


## 将体素位置集合按 6 方向连通性分组
func _partition_connected_blocks(positions: Array) -> Array:
	var result: Array = []
	var visited := {}
	var all_pos := {}
	for p in positions:
		all_pos[p] = true
	var dirs := [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	]
	for key in all_pos:
		var start: Vector3i = key
		if visited.has(start):
			continue
		var block: Array = []
		var queue: Array = [start]
		visited[start] = true
		while not queue.is_empty():
			var cur: Vector3i = queue.pop_front()
			block.append(cur)
			for d: Vector3i in dirs:
				var nb := cur + d
				if all_pos.has(nb) and not visited.has(nb):
					visited[nb] = true
					queue.append(nb)
		result.append(block)
	return result


## 主线程：用后台生成的 mesh arrays 构建整块刚体（body 位于 _debris_root 原点）
## mesh/碰撞用体素绝对坐标，保证整块与掉落前外观一致
func _build_collapse_body(bd: Dictionary, arrays: Variant) -> void:
	if arrays == null or bd.is_empty():
		return
	var arr_mesh: ArrayMesh = _CHUNK_GEN.build_mesh_from_arrays(arrays as Dictionary)
	if arr_mesh == null:
		return
	# 给整块 mesh 赋材质（复用与原体素一致的纹理材质，保证颜色正确）
	_apply_mesh_materials(arr_mesh)

	# 块信息
	var min_pos: Vector3 = bd["min"]
	var max_pos: Vector3 = bd["max"]
	var block_voxels: Dictionary[Vector3i, int] = bd["voxels"]
	var block: Array = []
	for p in block_voxels:
		block.append(p)

	var body := RigidBody3D.new()
	# 整块质量 = 块内体素质量之和（材质质量影响塌落物理表现）
	var block_mass := _compute_block_mass(block, _to_mat_map(block_voxels))
	body.mass = maxf(block_mass, 0.01)
	# 组合碰撞形状：每个体素一个独立的 shape owner + BoxShape，偏移到体素绝对位置（相对 body 原点）
	for p in block:
		var pos: Vector3i = p
		var shape := BoxShape3D.new()
		shape.size = Vector3(voxel_scale, voxel_scale, voxel_scale)
		var oid := body.create_shape_owner(body)
		body.shape_owner_add_shape(oid, shape)
		body.shape_owner_set_transform(oid, Transform3D.IDENTITY.translated(
			(Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale))

	# 整块显示：贪婪合并 mesh（顶点为体素绝对坐标，与 body 原点对齐）
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	body.add_child(mesh_inst)

	body.position = Vector3.ZERO
	# 整块从质心缓慢下落，带轻微随机旋转；质量越大越"沉重"
	body.linear_velocity = Vector3(randf_range(-0.3, 0.3), -debris_min_speed * 0.5, randf_range(-0.3, 0.3))
	body.angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
	body.gravity_scale = debris_gravity_scale
	body.sleeping = false
	body.set_meta("_born_ms", Time.get_ticks_msec())
	_debris_root.add_child(body)
	debris_count += 1


## 把 block_voxels(Dictionary[Vector3i,int]) 转成 mat_map 形式（pos -> mat_id）
func _to_mat_map(block_voxels: Dictionary) -> Dictionary:
	var m := {}
	for key in block_voxels:
		m[key] = block_voxels[key]
	return m


## 计算块的质量（块内体素质量之和）
func _compute_block_mass(block: Array, mat_map: Dictionary) -> float:
	var total := 0.0
	for p in block:
		var pos: Vector3i = p
		var mat_id: int = mat_map.get(pos, -1)
		total += _get_material_mass(mat_id)
	return total


func _get_material_mass(mat_id: int) -> float:
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var m = data.materials[mat_id]
		if m:
			return m.mass
	return 1.0


## 给整块 mesh 赋材质：复用与原体素一致的纹理材质 (VoxelMeshGenerator 生成的 PBR 材质)
## 保证崩塌整块与原体素块颜色/材质完全一致
var _block_mat_cache: Array = []

func _apply_mesh_materials(arr_mesh: ArrayMesh) -> void:
	if arr_mesh == null:
		return
	if _block_mat_cache.is_empty():
		_block_mat_cache = VoxelMeshGenerator.generate_textured_materials_runtime(data.materials)
	for i in arr_mesh.get_surface_count():
		if i < _block_mat_cache.size() and _block_mat_cache[i] != null:
			arr_mesh.surface_set_material(i, _block_mat_cache[i])


## 崩塌掉落的悬空体素 → 动态碎片 (带重力，落地保留)  [兼容：散碎片模式，非默认]
func _spawn_falling_debris(positions: Array, mat_map: Dictionary) -> void:
	_ensure_debris_root()
	var count := mini(positions.size(), max_debris_per_hit)
	if debris_mode == DebrisMode.DEBRIS_PHYSICS:
		for i in count:
			var pos: Vector3i = positions[i]
			var mat_id: int = mat_map.get(pos, -1)
			# 崩塌碎片带重力，落地后保留
			_spawn_physics_debris(pos, mat_id, true)
	else:
		# 视觉模式：崩塌碎片也走 MultiMesh，但做短暂下落 (视觉近似)
		_spawn_visual_debris_batch(positions, mat_map, count)


# --- 物理碎片 (RigidBody) + 对象池 + 落地保留 ---

func _spawn_physics_debris(pos: Vector3i, mat_id: int, is_collapse: bool) -> void:
	var box_size := voxel_scale * debris_size_scale
	var body := _acquire_debris_body(box_size)
	var mesh_inst := body.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_inst == null:
		mesh_inst = MeshInstance3D.new()
		mesh_inst.name = "MeshInstance3D"
		body.add_child(mesh_inst)
	mesh_inst.mesh = _get_debris_mesh(mat_id, box_size)
	body.position = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * voxel_scale
	if is_collapse:
		# 崩塌碎片：从原位置下落
		body.linear_velocity = Vector3(randf_range(-0.5, 0.5), -debris_min_speed, randf_range(-0.5, 0.5))
		body.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
	else:
		var speed := randf_range(debris_min_speed, debris_max_speed)
		var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1), randf_range(-1, 1)).normalized()
		body.linear_velocity = dir * speed
		body.angular_velocity = Vector3(randf_range(-5, 5), randf_range(-5, 5), randf_range(-5, 5))
	body.gravity_scale = debris_gravity_scale
	body.visible = true
	# 设置速度会自动唤醒 RigidBody；显式清除睡眠确保物理启动
	body.sleeping = false
	# 记录出生时间，用于出生保护期（避免刚生成就被误判冻结）
	body.set_meta("_born_ms", Time.get_ticks_msec())
	_debris_root.add_child(body)
	if not _active_debris.has(body):
		_active_debris.append(body)
	debris_count += 1


## 从对象池获取或创建物理碎片 (池化，减少 GC)
## box_size 为碎片碰撞体尺寸，必须与显示尺寸一致，否则碰撞范围会偏离
func _acquire_debris_body(box_size: float) -> RigidBody3D:
	var body: RigidBody3D
	if not _debris_pool.is_empty():
		body = _debris_pool.pop_back()
	else:
		body = RigidBody3D.new()
	# 更新碰撞形状尺寸，使其与显示大小一致
	var owner_ids := body.get_shape_owners()
	if owner_ids.is_empty():
		var shape := BoxShape3D.new()
		shape.size = Vector3(box_size, box_size, box_size)
		var owner_id := body.create_shape_owner(body)
		body.shape_owner_add_shape(owner_id, shape)
	else:
		for owner in owner_ids:
			if body.shape_owner_get_shape_count(owner) > 0:
				var shape: BoxShape3D = body.shape_owner_get_shape(owner, 0)
				shape.size = Vector3(box_size, box_size, box_size)
	# 重置物理状态（可能从落地保留/池中复用，需解除冻结并唤醒）
	body.freeze = false
	body.sleeping = false
	return body


## 物理碎片落地后转静态保留 + 轮询异步崩塌 mesh（由 _process 每帧检查）
func _process(_delta: float) -> void:
	super._process(_delta)
	if Engine.is_editor_hint():
		return
	# 轮询崩塌 mesh 异步生成结果，完成后创建整块刚体
	_poll_collapse_task()
	_settle_resting_debris()


## 轮询后台崩塌 mesh 生成，完成则创建整块刚体
func _poll_collapse_task() -> void:
	if _collapse_task_id < 0:
		return
	if not WorkerThreadPool.is_task_completed(_collapse_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_collapse_task_id)
	_collapse_task_id = -1
	if not _collapse_pending:
		return
	var blocks_data := _collapse_blocks_data
	var results := _collapse_results
	_collapse_blocks_data = []
	_collapse_results = []
	_collapse_pending = false
	for i in mini(blocks_data.size(), results.size()):
		_build_collapse_body(blocks_data[i], results[i])


## 检查物理碎片：落地后（物理引擎判定睡眠）转静态保留，不再被清除
## 只遍历活跃碎片集合（_active_debris），避免每帧扫描所有子节点（含已落地/粒子）
## 用 RigidBody.sleeping（物理引擎在接触静止后自动判定）而非速度阈值，
## 避免碎片在空中（刚生成速度慢）被误判为静止而冻结
func _settle_resting_debris() -> void:
	var i := 0
	while i < _active_debris.size():
		var rb: RigidBody3D = _active_debris[i]
		if not is_instance_valid(rb) or rb.get_parent() == null:
			_active_debris.remove_at(i)
			continue
		var settled := false
		# 出生保护期：刚生成的碎片（<0.5秒）不冻结，确保物理有时间作用下落
		if rb.has_meta("_born_ms") and Time.get_ticks_msec() - rb.get_meta("_born_ms") < 500:
			i += 1
			continue
		if rb.sleeping and rb.linear_velocity.length() < debris_rest_threshold:
			# 落地静止 → 转静态保留，并放到已落地列表，移出活跃集合
			rb.freeze = true
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			if not _settled_debris.has(rb):
				_settled_debris.append(rb)
			settled = true
		if settled:
			_active_debris.remove_at(i)
		else:
			i += 1
	# 落地保留碎片超过上限：回收最早的（释放到对象池，控制内存）
	if max_settled_debris > 0 and _settled_debris.size() > max_settled_debris:
		var overflow := _settled_debris.size() - max_settled_debris
		for k in overflow:
			var rb: RigidBody3D = _settled_debris.pop_front()
			_remove_physics_debris(rb)


## 移除碎片（落地保留的除外），释放到对象池
func _remove_physics_debris(body: Node) -> void:
	if not body or not is_instance_valid(body):
		return
	var rb := body as RigidBody3D
	# 已落地保留的碎片不回收
	if _settled_debris.has(rb):
		return
	_active_debris.erase(rb)
	rb.get_parent().remove_child(rb)
	if _debris_pool.size() < debris_pool_size:
		_debris_pool.append(rb)
	debris_count = maxi(0, debris_count - 1)


# --- 视觉碎片 (粒子系统，纯表现) ---

## 爆发碎片粒子：纯表现，GPU 粒子天然有飞出动态，无需物理/清理逻辑
func _spawn_visual_debris_batch(positions: Array, mat_map: Dictionary, count: int) -> void:
	if positions.is_empty():
		return
	_ensure_debris_root()
	# 按材质分组，每组发射一个粒子系统
	var by_mat := {}
	for i in count:
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
	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		_spawn_debris_particles(center, mat_id, list.size())


## 在指定位置发射一批碎片粒子（GPUParticles3D，粒子碰撞只支持 GPU 版本）
## 用 ParticleProcessMaterial.collision_friction/bounce 精确控制落地停住不滑动
func _spawn_debris_particles(center: Vector3, mat_id: int, amount: int) -> void:
	if amount <= 0:
		return
	var particles := GPUParticles3D.new()
	particles.name = "DebrisParticles_%d" % mat_id
	particles.position = center
	particles.amount = amount
	# 粒子停留时间较长（至少 4 秒），配合慢速淡出慢慢消失
	particles.lifetime = maxf(debris_lifetime, 4.0)
	particles.explosiveness = 1.0
	particles.one_shot = true
	particles.local_coords = true
	# 碰撞仅在 visibility_aabb 区域内发生，扩大以覆盖粒子运动范围
	particles.visibility_aabb = AABB(Vector3(-8, -4, -8), Vector3(16, 16, 16))

	# 粒子材质：碰撞(刚体) + 高摩擦(落地停住) + 无弹性(不反弹)
	var pm := ParticleProcessMaterial.new()
	pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	# 关键：collision_friction(摩擦) 与 collision_bounce(弹性) 是正确属性名
	pm.collision_friction = 1.0  # 最大摩擦：粒子落地后原地停住，不沿地面滑动
	pm.collision_bounce = 0.0    # 无弹性：落地不反弹

	# 粒子运动：主要向上喷发 + 强重力快速落地，减少水平位移
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 45.0
	pm.initial_velocity_min = debris_min_speed * 0.8
	pm.initial_velocity_max = debris_max_speed * 0.8
	pm.gravity = Vector3(0, -20.0 * debris_gravity_scale, 0)
	pm.angular_velocity_min = -6.0
	pm.angular_velocity_max = 6.0
	# 粒子大小 = 原体素大小
	pm.scale_min = 1.0
	pm.scale_max = 1.0

	# 淡出：alpha_curve(GradientTexture1D) 控制粒子 alpha 随时间变化，
	# 从生命周期 50% 开始慢慢渐变到透明，过程平缓而非瞬间消失
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	fade.colors = PackedColorArray([
		Color(1, 1, 1, 1),  # 初始不透明
		Color(1, 1, 1, 1),  # 前一半保持不透明
		Color(1, 1, 1, 0),  # 末期完全透明
	])
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = fade
	pm.alpha_curve = alpha_tex
	particles.process_material = pm
	# 碎片用立方体 mesh，尺寸 = 原体素大小（voxel_scale），保证与原体素一致
	var mesh := BoxMesh.new()
	mesh.size = Vector3(voxel_scale, voxel_scale, voxel_scale)
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var mat_res = data.materials[mat_id]
		if mat_res:
			var m := StandardMaterial3D.new()
			m.albedo_color = VoxelMaterial.albedo_color(mat_res)
			m.metallic = mat_res.metal
			m.roughness = mat_res.rough
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			# 启用透明度：让 alpha_curve 淡出能真正生效（否则 alpha 被忽略，粒子不透明）
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mesh.material = m
	particles.draw_pass_1 = mesh

	_debris_root.add_child(particles)
	# 粒子发射完并淡出后自动销毁节点（留足够时间让淡出完整播放）
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(particles.lifetime + 0.5)
		timer.timeout.connect(_cleanup_particles.bind(particles))


func _cleanup_particles(p: Node) -> void:
	if p and is_instance_valid(p):
		p.queue_free()


func _get_debris_mesh(mat_id: int, size: float) -> Mesh:
	# 缓存键包含尺寸，避免不同 size 的碎片 mesh 复用错误尺寸
	var key := "%d:%.3f" % [mat_id, size]
	if _debris_mesh_cache.has(key):
		return _debris_mesh_cache[key]
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	if data and mat_id >= 0 and mat_id < data.materials.size():
		var mat_res = data.materials[mat_id]
		if mat_res:
			# 碎片材质复用原体素材质的完整 PBR 属性 (颜色/金属/粗糙/自发光)，
			# 保证光照下颜色与原体素块一致
			var mat := StandardMaterial3D.new()
			mat.albedo_color = VoxelMaterial.albedo_color(mat_res)
			mat.metallic = mat_res.metal
			mat.roughness = mat_res.rough
			mat.emission_enabled = mat_res.emission > 0.0
			mat.emission = VoxelMaterial.emission_color(mat_res)
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			if mat_res.trans > 0:
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			box.material = mat
	_debris_mesh_cache[key] = box
	return box


func _clear_debris() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	debris_count = 0
	_settled_debris.clear()
	_active_debris.clear()
	_debris_mesh_cache.clear()
