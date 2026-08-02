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
signal voxel_hardened(pos: Vector3i, remaining: float)          ## 体素受伤但未摧毁 (材质硬度未达)
signal voxels_about_to_collapse(positions: Array)               ## 悬空体素即将崩塌掉落前

## 崩塌掉落模式枚举
enum CollapseMode {
	COLLAPSE_NONE,   ## 不启用悬空崩塌
	COLLAPSE_DEBRIS, ## 悬空体素转成粒子碎片掉落
}

## 破坏时是否生成碎片
@export var spawn_debris_on_damage: bool = true

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

## 碎片粒子初始速度范围（基准值，受材质 mass 影响）
## 最终速度 = 基准速度 / sqrt(mass) ，重物飞得近，轻物飞得远
@export var debris_min_speed: float = 2.0
@export var debris_max_speed: float = 6.0

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

## 级联崩塌状态：逐帧处理，每帧只处理一个级联层级
var _cascade_check_positions: Array = []  # 待检查的体素位置（下一级联层级）
var _cascade_total: Array = []            # 所有级联累积的失稳体素

## 单帧最大物理体生成数量（防止大规模级联时一帧创建过多 RigidBody3D）
const MAX_FALLING_CHUNKS_PER_FRAME: int = 10

## 掉落块落地静置检测帧计数器
var _sleep_check_counter: int = 0

const _DEBRIS_ROOT_NAME := "_VoxelDebris"


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		_ensure_debris_root()
		# 延迟一帧：确保外部在 _ready 前赋值的 data 已就绪，做一次初始全量稳定性校验
		# 使场景进入静态稳定状态（清除初始悬空结构），之后破坏由局部检测负责
		call_deferred("validate_stability")


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
			# 发出"受伤但未摧毁"反馈
			voxel_hardened.emit(pos, hardness - cur)
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
func _after_removal(removed: Array) -> void:
	# 应力传播：裂纹扩散（始终启用）
	if not removed.is_empty():
		var stress_removed := _propagate_stress(removed)
		if not stress_removed.is_empty():
			# 应力传播移除的体素先移除，再触发崩塌
			var stress_mat_map := _collect_voxel_materials(stress_removed)
			data.remove_voxels(stress_removed)
			# 应力传播的断裂体素：连通的转为物理体掉落，散落的用粒子
			if not Engine.is_editor_hint():
				# 按连通性分组，每组生成一个物理体掉落
				var stress_groups := VoxelData.partition_connected(stress_removed)
				var group_count := 0
				for sgroup in stress_groups:
					if group_count >= MAX_FALLING_CHUNKS_PER_FRAME:
						# 超出限制的用粒子代替
						var remaining: Array = []
						for j in range(group_count, stress_groups.size()):
							remaining.append_array(stress_groups[j])
						if not remaining.is_empty():
							_spawn_debris_with_materials(remaining, _collect_voxel_materials(remaining))
						break
					# 收集该组的材质映射
					var sgroup_mat_map: Dictionary = {}
					for pos in sgroup:
						sgroup_mat_map[pos] = stress_mat_map.get(pos, 0)
					_spawn_falling_chunk(sgroup, sgroup_mat_map)
					group_count += 1
			removed.append_array(stress_removed)

	_trigger_collapse(removed)
	if health >= 0:
		health -= float(removed.size()) * 0.5
		if health <= 0:
			destroy_all()


# ----------------------------------------------------------------------------
# 应力传播（裂纹扩散）
# ----------------------------------------------------------------------------

## 应力传播：从被移除的体素出发，向邻居传播应力
## 若邻居体素材质的 connection_strength 不足以承受应力，则断裂
## 返回所有因应力传播而断裂的体素位置
func _propagate_stress(removed: Array) -> Array:
	if not data or removed.is_empty():
		return []

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
	# 仅在 validate_stability 等初始化场景调用，后续破坏由局部检测负责
	if around_positions.is_empty():
		_process_full_cascade()
		return

	# 局部检测：只处理一个级联层级
	_process_cascade_level(around_positions)


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
			mat_map[pos] = data.voxels[pos]
		group_materials.append(mat_map)
	data.remove_voxels(total_unstable)
	if not Engine.is_editor_hint():
		var spawned_count := 0
		for i in range(groups.size()):
			if spawned_count >= MAX_FALLING_CHUNKS_PER_FRAME:
				# 超出限制的组用粒子代替
				var remaining: Array = []
				for j in range(i, groups.size()):
					remaining.append_array(groups[j])
				if not remaining.is_empty():
					var remaining_mat_map: Dictionary = {}
					for pos in remaining:
						remaining_mat_map[pos] = data.voxels.get(pos, -1) if data.has_voxel(pos) else _find_original_mat(pos, group_materials, i)
					_spawn_debris_with_materials(remaining, remaining_mat_map)
				break
			_spawn_falling_chunk(groups[i], group_materials[i])
			spawned_count += 1

	voxels_about_to_collapse.emit(total_unstable)
	last_collapse_count = total_unstable.size()
	voxel_damaged.emit(total_unstable, true)


## 处理一个级联层级（局部检测）
## 改为在同一帧内完成所有级联层级，避免建筑一层一层"消失"的视觉效果
## 失稳体素整块转为独立的 FallingChunk 物理体掉落，而非粒子
func _process_cascade_level(around_positions: Array) -> void:
	var all_unstable: Array = []
	var queue: Array = around_positions.duplicate()
	var guard := 64  # 防止无限循环

	while not queue.is_empty() and guard > 0:
		guard -= 1
		var unstable := _find_unstable_voxels(queue)
		if unstable.is_empty():
			break
		all_unstable.append_array(unstable)
		queue = unstable

	if all_unstable.is_empty():
		_finalize_cascade()
		return

	# 按连通性分组：同一组的体素作为一个整体掉落
	var groups := VoxelData.partition_connected(all_unstable)

	# 收集每组体素的材质ID（在移除前，_spawn_falling_chunk 需要读取）
	var group_materials: Array[Dictionary] = []
	for group in groups:
		var mat_map: Dictionary = {}
		for pos in group:
			mat_map[pos] = data.voxels[pos]
		group_materials.append(mat_map)

	# 从原始数据中移除所有失稳体素
	data.remove_voxels(all_unstable)

	# 每组生成一个 FallingChunk 物理体（防止一帧生成过多物理体）
	if not Engine.is_editor_hint():
		var spawned_count := 0
		for i in range(groups.size()):
			if spawned_count >= MAX_FALLING_CHUNKS_PER_FRAME:
				# 超出限制的组用粒子代替
				var remaining: Array = []
				for j in range(i, groups.size()):
					remaining.append_array(groups[j])
				if not remaining.is_empty():
					# 重新收集剩余体素的材质
					var remaining_mat_map: Dictionary = {}
					for pos in remaining:
						remaining_mat_map[pos] = data.voxels.get(pos, -1) if data.has_voxel(pos) else _find_original_mat(pos, group_materials, i)
					_spawn_debris_with_materials(remaining, remaining_mat_map)
				break
			_spawn_falling_chunk(groups[i], group_materials[i])
			spawned_count += 1

	# 累积并完成级联（发信号）
	_cascade_total.append_array(all_unstable)
	_cascade_check_positions = []
	_finalize_cascade()


## 当体素已被移除后，从已收集的材质映射中查找原始材质ID
func _find_original_mat(pos: Vector3i, group_materials: Array[Dictionary], start_idx: int) -> int:
	for i in range(start_idx, group_materials.size()):
		if group_materials[i].has(pos):
			return group_materials[i][pos]
	return 0


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
## 将一组连通体素创建为独立的 VoxelDestructible，包裹在 RigidBody3D 中掉落
## 体素位置偏移到居中，使 RigidBody3D 位于块的中心
## mat_map: 体素位置 -> 材质ID 的映射（在调用前已从 data 中收集，因为 data 可能在调用前已移除体素）
func _spawn_falling_chunk(group: Array, mat_map: Dictionary) -> void:
	if group.is_empty():
		return

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

	# 2. 创建新的 VoxelData（偏移体素位置使中心对齐到原点）
	# 使用提前收集的 mat_map 而非 data.voxels（体素可能已被移除）
	var new_data := VoxelData.new()
	for pos in group:
		var p: Vector3i = pos
		var offset_p := p - Vector3i(voxel_center)
		new_data.voxels[offset_p] = mat_map.get(p, 0)
	# 复制材质
	for m in data.materials:
		if m:
			new_data.add_material(m)

	# 3. 创建新的 VoxelDestructible（只负责渲染，不参与破坏逻辑）
	var chunk := VoxelDestructible.new()
	chunk.name = "FallingChunk_%d" % _falling_chunk_id
	_falling_chunk_id += 1
	chunk.data = new_data
	chunk.voxel_scale = voxel_scale
	chunk.collapse_mode = CollapseMode.COLLAPSE_NONE
	chunk.health = -1
	chunk.spawn_debris_on_damage = false

	# 4. 创建 RigidBody3D 作为物理体
	# 注意：不能使用 global_position，因为 body 尚未加入场景树
	# body 将作为 _falling_chunk_root 的子节点，而 _falling_chunk_root 位于当前节点原点
	# 所以 body.position = world_center 即可达到正确位置
	var body := RigidBody3D.new()
	body.name = chunk.name + "_Body"
	body.position = world_center
	body.gravity_scale = 1.0
	body.mass = maxf(group.size() * 0.5, 1.0)
	body.continuous_cd = true

	# 5. VoxelDestructible 作为子节点（体素已居中，位置为 0）
	body.add_child(chunk)
	chunk.owner = body

	# 6. 添加碰撞形状（盒体包围整个块）
	var block_size := Vector3(voxel_max - voxel_min) + Vector3.ONE
	var shape := BoxShape3D.new()
	shape.size = block_size * voxel_scale
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	col.owner = body

	# 7. 添加到场景
	_falling_chunk_root.add_child(body)
	body.owner = _falling_chunk_root

	# 8. 连接落地检测：落地后静置一段时间自动冻结（节省物理开销，不掉落块不消失）
	body.body_entered.connect(_on_chunk_landed.bind(body))


## 清理已停稳或超时的掉落块
func _cleanup_falling_chunk(body: RigidBody3D) -> void:
	if body and is_instance_valid(body):
		body.queue_free()


## 手动清理所有掉落块（用于场景重置等）
func _clear_falling_chunks() -> void:
	if _falling_chunk_root:
		for child in _falling_chunk_root.get_children():
			child.queue_free()


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
func _freeze_sleeping_chunks() -> void:
	if not _falling_chunk_root:
		return
	for child in _falling_chunk_root.get_children():
		var body := child as RigidBody3D
		if body and not body.freeze and body.sleeping:
			body.freeze = true
			body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC


## 找出所有"失稳"体素，返回这些体素位置的并集
## 连通性支撑判断：从贴地(y==0)体素 6 方向 BFS 标记所有"与地面连通"的体素，
## 与地面断开（完全悬空）的体素才会脱落
## around_positions 为本次破坏移除的体素位置：
##   - 局部增量(local_collapse=true)：只检查破坏位置 6 邻附近可能失稳的体素，
##     避免每次破坏都全量 BFS，适合中频破坏 + 中型场景
##   - 全量检测(local_collapse=false)：全局遍历，结果最精确，适合小型场景/低频
## around_positions 为空时回退全量检测
func _find_unstable_voxels(around_positions: Array = []) -> Array:
	var voxels: Dictionary = data.voxels
	if voxels.is_empty():
		return []

	var unstable_set: Dictionary
	if local_collapse and not around_positions.is_empty():
		unstable_set = data.find_unsupported_around(around_positions)
	else:
		unstable_set = data.find_unsupported(voxels)

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
			mat_map[pos] = data.voxels[pos]
		group_materials.append(mat_map)
	data.remove_voxels(unstable)
	if not Engine.is_editor_hint():
		var spawned_count := 0
		for i in range(groups.size()):
			if spawned_count >= MAX_FALLING_CHUNKS_PER_FRAME:
				var remaining: Array = []
				for j in range(i, groups.size()):
					remaining.append_array(groups[j])
				if not remaining.is_empty():
					var remaining_mat_map: Dictionary = {}
					for pos in remaining:
						remaining_mat_map[pos] = data.voxels.get(pos, -1) if data.has_voxel(pos) else _find_original_mat(pos, group_materials, i)
					_spawn_debris_with_materials(remaining, remaining_mat_map)
				break
			_spawn_falling_chunk(groups[i], group_materials[i])
			spawned_count += 1
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
		mat_map[pos] = data.voxels[pos]
	return mat_map


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
		var pos: Vector3i = positions[i] if i < positions.size() else positions[0]
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
func _spawn_debris_particles(center: Vector3, mat_id: int, amount: int, mat_mass: float = 1.0, is_collapse: bool = false) -> void:
	if amount <= 0:
		return
	# mass 影响因子：质量越大，速度越慢、重力越大、喷发角度越小
	# 用 1/sqrt(mass) 使效果平滑：mass=0.5→速度×1.41, mass=2.0→速度×0.71
	var mass_factor := 1.0 / sqrt(mat_mass)
	var particles := GPUParticles3D.new()
	particles.name = "DebrisParticles_%d" % mat_id
	particles.position = center
	particles.amount = amount
	# 粒子停留时间：重物落地快，生命周期缩短；轻物飘得久
	particles.lifetime = maxf(debris_lifetime / maxf(mass_factor, 0.3), 2.0)
	particles.explosiveness = 1.0
	particles.one_shot = true
	particles.local_coords = true
	# 碰撞仅在 visibility_aabb 区域内发生，扩大以覆盖粒子运动范围
	particles.visibility_aabb = AABB(Vector3(-8, -4, -8), Vector3(16, 16, 16))

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
		pm.initial_velocity_min = debris_min_speed * 0.8 * mass_factor
		pm.initial_velocity_max = debris_max_speed * 0.8 * mass_factor
		pm.gravity = Vector3(0, -20.0 * debris_gravity_scale * mass_factor, 0)
		pm.angular_velocity_min = -6.0 * mass_factor
		pm.angular_velocity_max = 6.0 * mass_factor
	pm.scale_min = 1.0
	pm.scale_max = 1.0

	# 淡出：从生命周期 50% 开始慢慢渐变到透明
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	fade.colors = PackedColorArray([
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 1),
		Color(1, 1, 1, 0),
	])
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = fade
	pm.alpha_curve = alpha_tex
	particles.process_material = pm

	# 碎片用立方体 mesh，尺寸 = 原体素大小
	var mesh := _get_particle_mesh(mat_id)
	particles.draw_pass_1 = mesh

	_debris_root.add_child(particles)
	# 粒子发射完并淡出后自动销毁节点
	var tree := get_tree()
	if tree:
		var timer := tree.create_timer(particles.lifetime + 0.5)
		timer.timeout.connect(_cleanup_particles.bind(particles))


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


func _cleanup_particles(p: Node) -> void:
	if p and is_instance_valid(p):
		p.queue_free()


func _clear_debris() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	_particle_mesh_cache.clear()


# ----------------------------------------------------------------------------
# 主循环
# ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	super._process(_delta)
	if Engine.is_editor_hint():
		return

	# 处理级联崩塌（安全兜底，正常情况下级联已在 _trigger_collapse 中完成）
	if not _cascade_check_positions.is_empty():
		_process_cascade_level(_cascade_check_positions)
	# 处理普通破坏批次（每帧一个）
	_process_destruction_pipeline()

	# 每 120 帧（约 2 秒）检测一次掉落块是否已静止，冻结以节省物理开销
	_sleep_check_counter += 1
	if _sleep_check_counter >= 120:
		_sleep_check_counter = 0
		_freeze_sleeping_chunks()


## 延迟破坏管道：每帧处理所有累积的待移除体素（去重合并后）
## 同一帧内多次伤害相同位置合并去重，仅执行一次移除 + 崩塌检测 + 碎片生成
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

	# 0. 先在移除前收集材质快照（避免移除后 data.voxels 中找不到）
	var mat_map := _collect_voxel_materials(removed) if do_spawn and not Engine.is_editor_hint() else {}

	# 1. 实际移除体素（触发 mesh 脏标记 → 下一帧 _process 自动重建）
	data.remove_voxels(removed)

	# 2. 应力传播 + 崩塌检测 + 处理
	_after_removal(removed)

	# 3. 生成粒子碎片（使用第 0 步收集的材质快照）
	if do_spawn and not Engine.is_editor_hint() and not mat_map.is_empty():
		_spawn_debris_with_materials(removed, mat_map)

	# 4. 信号
	voxel_damaged.emit(removed, do_spawn)