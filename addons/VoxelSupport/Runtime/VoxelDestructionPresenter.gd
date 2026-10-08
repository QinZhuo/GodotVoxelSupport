class_name VoxelDestructionPresenter
extends Node3D

## 破坏表现层：把"怎么演"从编辑逻辑里彻底分开。
##
## 【边界】编辑侧（`VoxelEditKernel` 的编辑数学 + `VoxelDestructible` 的编辑管道）只产出
##   **数据**——"哪些体素没了 / 哪些体素失稳 / 材质快照"；本组件负责**演出**——粒子碎片、
##   掉落刚体、mesh 组装、冻结与生命周期清理。宿主 `_process` 里因此不再出现
##   "级联调度 + mesh 组装"混在一条链上的情况。
##
## 【依赖方向】本组件是宿主的**子节点**（identity 变换，故 `global_position` 即宿主世界位置）：
##   · 宿主 → 本组件：只调本组件的公开方法——`ensure_debris_root` / `spawn_debris_with_materials`
##     / `spawn_falling_chunks_from_groups` / `process_pending_falling_groups`
##     / `process_pending_mesh_results` / `freeze_sleeping_chunks` / `configure`
##     / `on_origin_shift` / `shutdown`。
##     （`spawn_chunk_break_debris` / `spawn_chunk_break_at_body` / `clear_all` 同为公开，
##     但当前只在本组件内部/`shutdown` 里调用。）
##   · 本组件 → 宿主：**只读**宿主的公开面（`host.data` / `host.voxel_scale` / `host.infinite_layer` /
##     `host.diag_enabled` / `host.surface_materials()`），与 P2-2 冻结的内核契约一致；
##     **不碰宿主私有成员**。构造时传入 `host`，之后不再变更。
##
## 【配置旋钮】本组件不是被 Inspector 编辑的节点（由宿主在 `_ready` 里创建），
##   故破坏手感 / 掉落旋钮仍留在宿主的 `@export` 上，由 `configure()` 每帧传入——
##   避免同一旋钮出现第二套 Inspector 真值。

## 宿主（只读上下文来源）。只读 host.data / host.voxel_scale / host.infinite_layer /
## host.diag_enabled / host.surface_materials()。
var host: VoxelRenderer

# --- 配置（由宿主 configure() 传入；子节点不挂 @export） ---
var _max_debris_per_hit: int = 24
var _debris_speed_range: Vector2 = Vector2(3.0, 7.0)
var _debris_lifetime: float = 1.2
var _debris_gravity_scale: float = 1.0
## 掉落表现模式（数值与宿主 `VoxelDestructible.FallingMode` 一一对应，由 configure 传入）。
## 【为何只收数值而非引用该枚举】宿主已持有本组件的类型引用，反向引用会构成脚本循环依赖。
const FALLING_AUTO: int = 0
const FALLING_PARTICLE: int = 1
var _falling_mode: int = FALLING_AUTO
var _falling_pool_size: int = 64
var _max_falling_chunks: int = 200
var _falling_cleanup_time: float = 6.0

# --- 掉落体分档常量（表现策略，只有本组件使用） ---
## AUTO 模式分档阈值：<= 粒子阈值 → GPU 粒子；<= Box 阈值 → Box 碰撞；> Box 阈值 → 凸包碰撞
const AUTO_PARTICLE_VOXELS: int = 32
const AUTO_BOX_VOXELS: int = 256
## 单帧最大物理体生成数量（防止大规模级联时一帧创建过多 RigidBody3D）
const MAX_FALLING_CHUNKS_PER_FRAME: int = 10
## 单个掉落体最大体素数：超大崩塌拆分为多个掉落体，避免单块 ArrayMesh 上传超大 buffer
const MAX_FALLING_GROUP_VOXELS: int = 4096

# --- 碎片（粒子）状态 ---
var _debris_root: Node3D
var _particle_mesh_cache: Dictionary = {}
var _particle_pool: Array[GPUParticles3D] = []
var _particle_fade_gradient: GradientTexture1D
const _DEBRIS_ROOT_NAME := "_VoxelDebris"
## 粒子池上限（超过此数量不再缓存空闲节点，直接销毁）
const PARTICLE_POOL_MAX: int = 64

# --- 掉落物理状态 ---
var _falling_chunk_root: Node3D = null
var _falling_chunk_id: int = 0
## 在途的掉落块 mesh worker 任务 ID（退出时必须 join，见 shutdown）。
var _falling_mesh_tasks: Array[int] = []
## 在途任务 ID 的压缩下限（超过才做压缩，避免每次派发都白跑一趟）。
const _FALLING_TASK_COMPACT_MIN: int = 64

## 掉落块 -> 生成时刻 (msec)，用于生命周期上限/超时清理（含未冻结仍在掉落的块）
var _chunk_spawn_times: Dictionary = {}

## 物理掉落体对象池：空闲的 RigidBody3D 集合（复用，避免反复创建/销毁）
var _body_pool: Array[RigidBody3D] = []
## 池中所有已创建的 RigidBody3D（含使用中），用于池容量管理
var _body_pool_total: Array[RigidBody3D] = []

## 物理体代次：每次 `_acquire_body` 取出都 +1 → { body: gen }。
## 池复用会让同一个 RigidBody3D 先后承载多个掉落块，仅凭 is_instance_valid 无法区分
## "这个在途 mesh 结果属于当初那个块吗"。故结果随生成代次一起回传，应用前比对代次，
## 不匹配即丢弃（否则会把上一世的网格挂到复用后的新块上）。
var _body_gen: Dictionary = {}
var _next_body_gen: int = 0

## 大块掉落交替策略：相邻中块连续快速生成时，物理体与粒子破碎交替出现，
## 防止多个中块同帧物理落地互相碰撞被推飞，同时画面表现更多样。
var _last_physics_chunk_time: int = 0
var _last_physics_chunk_pos: Vector3 = Vector3.INF
const _chunk_alternate_ms: int = 300      # 连续生成时间窗口（毫秒）
const _chunk_alternate_dist: float = 5.0  # 相邻判定距离（世界单位，≈1-2块宽）

## 待生成掉落体队列：大面积崩塌时超出单帧上限的物理组暂存于此，
## 由宿主每帧限量生成，把 GPU/物理负载摊平到多帧（消除 Metal fence 洪峰）
var _pending_falling_groups: Array = []
var _pending_falling_materials: Array[Dictionary] = []
## 每帧最多从待生成队列生成多少个掉落体（与 MAX_FALLING_CHUNKS_PER_FRAME 一致）
var _pending_build_per_frame: int = 10

## 掉落体 mesh 结果队列：后台线程生成完 arrays 后，若 GPU 忙则暂存于此，
## 由宿主每帧限量组装 ArrayMesh（add_surface_from_arrays 同步 GPU 上传，
## 避免 GPU 满载时 Metal fence wait() 超时）。元素: {body, arrays, local_voxels}
var _pending_mesh_results: Array[Dictionary] = []
## 每帧最多组装的掉落体 mesh 数（连续破坏时提高，减少掉落块网格延迟感）
var _mesh_apply_per_frame: int = 6

## 退出中：在途 worker 的结果回调据此直接丢弃，避免访问已清理数据
var _exiting := false


func _init(host_ref: VoxelRenderer = null) -> void:
	host = host_ref


## 由宿主在 _process 每帧调用：手感 / 掉落旋钮的真值在宿主的 @export 上。
func configure(max_debris_per_hit: int, debris_speed_range: Vector2,
		debris_lifetime: float, debris_gravity_scale: float,
		falling_mode: int, falling_pool_size: int,
		max_falling_chunks: int, falling_cleanup_time: float) -> void:
	_max_debris_per_hit = max_debris_per_hit
	_debris_speed_range = debris_speed_range
	_debris_lifetime = debris_lifetime
	_debris_gravity_scale = debris_gravity_scale
	_falling_mode = falling_mode
	_falling_pool_size = falling_pool_size
	_max_falling_chunks = max_falling_chunks
	_falling_cleanup_time = falling_cleanup_time


# ----------------------------------------------------------------------------
# 碎片系统：粒子系统（无物理碰撞体）
# ----------------------------------------------------------------------------

func ensure_debris_root() -> void:
	if not _debris_root:
		_debris_root = Node3D.new()
		_debris_root.name = _DEBRIS_ROOT_NAME
		add_child(_debris_root, false, Node.INTERNAL_MODE_BACK)

## 整块碎裂粒子：当物理体池已满、大块无法生成物理体时，
## 把整块转成"从块包围盒范围发射"的粒子，保留"整块碎裂散开"的视觉，
## 而非从质心一点发射导致"大块突然消失"。
## 粒子数量按块大小比例（不受 max_debris_per_hit 限制，避免大块只剩几个粒子）
func spawn_chunk_break_debris(positions: Array, mat_map: Dictionary) -> void:
	if positions.is_empty():
		return
	ensure_debris_root()

	# 计算块包围盒（世界单位）
	var scale: float = host.voxel_scale
	var min_v := Vector3(positions[0]) * scale
	var max_v := min_v
	for pos in positions:
		var p: Vector3 = (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * scale
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	var center := (min_v + max_v) * 0.5
	var emission_size := max_v - min_v

	# 视锥外跳过（相机看不到的整块碎裂，不生成粒子）
	# center 为体素世界坐标（相对 target），转全局坐标判定
	if not host.infinite_layer.is_world_visible(center + global_position):
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
func spawn_debris_with_materials(positions: Array, mat_map: Dictionary, is_collapse: bool = false) -> void:
	if positions.is_empty():
		return
	ensure_debris_root()
	var count := mini(positions.size(), _max_debris_per_hit)
	# 按材质分组，每组发射一个粒子系统
	var by_mat := {}
	for i in range(count):
		var pos: Vector3i = positions[i]
		var mat_id: int = mat_map.get(pos, -1)
		if not by_mat.has(mat_id):
			by_mat[mat_id] = []
		by_mat[mat_id].append(pos)

	# 粒子发射中心：**发射集**的质心（与上面 by_mat 取的前 count 个一致）。
	# 不能遍历全部 positions——destroy_all 时那是整个世界，会为十几个粒子走完全世界，
	# 且算出的质心与真正发射的体素不符（粒子从块外飘出来）。
	var center := Vector3.ZERO
	for i in range(count):
		center += (Vector3(positions[i]) + Vector3(0.5, 0.5, 0.5)) * host.voxel_scale
	if count > 0:
		center /= float(count)

	# 视锥外跳过（相机看不到的破坏，不生成粒子，省 GPU）
	# 注意：center 是局部坐标，需加 global_position 转世界坐标再判定
	if not host.infinite_layer.is_world_visible(center + global_position):
		return

	for mat_id in by_mat:
		var list: Array = by_mat[mat_id]
		# 获取材质的 mass，用于调整粒子运动表现
		var mat_mass: float = _get_material_mass(mat_id)
		_spawn_debris_particles(center, mat_id, list.size(), mat_mass, is_collapse)


## 获取材质的质量
func _get_material_mass(mat_id: int) -> float:
	if host.data and mat_id >= 0 and mat_id < host.data.materials.size():
		var m = host.data.materials[mat_id] as VoxelMaterial
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
		ensure_debris_root()
		_debris_root.add_child(particles)
	particles.visible = true

	particles.position = center
	particles.amount = amount
	# 粒子停留时间：重物落地快，生命周期缩短；轻物飘得久
	particles.lifetime = maxf(_debris_lifetime / maxf(mass_factor, 0.3), 2.0)
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
		pm.initial_velocity_min = _debris_speed_range.x * 0.8 * mass_factor
		pm.initial_velocity_max = _debris_speed_range.y * 0.8 * mass_factor
		pm.gravity = Vector3(0, -20.0 * _debris_gravity_scale * mass_factor, 0)
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
	var vs: float = host.voxel_scale
	box.size = Vector3(vs, vs, vs)
	if host.data and mat_id >= 0 and mat_id < host.data.materials.size():
		var mat_res = host.data.materials[mat_id]
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


## origin shift 钩子（宿主转发）：把本组件持有的**体素坐标**在途队列一起平移。
## 【为什么必须做】待生成掉落体队列里存的是体素坐标；数据坐标整体挪了 shift 后若不平移，
## 下一帧生成的就是错位的掉落体与材质映射。
func on_origin_shift(shift: Vector3i) -> void:
	if _pending_falling_groups.is_empty():
		return
	var ng: Array = []
	var nm: Array[Dictionary] = []
	for i in _pending_falling_groups.size():
		ng.append(VoxelChunk.shift_positions(_pending_falling_groups[i], shift))
		nm.append(VoxelChunk.shift_key_dict(_pending_falling_materials[i], shift)
				if i < _pending_falling_materials.size() else {})
	_pending_falling_groups = ng
	_pending_falling_materials = nm


## 退出 / 销毁时调用：先等在途 worker 结束（否则其 call_deferred 会打到已释放实例），
## 再清空全部表现层产物。
## 【为何先等再清】worker 结果回调会访问本组件状态；置 `_exiting` 只能丢弃迟到结果，
## 仍必须先 join 未完成任务，避免回调落在释放后的实例上。
func shutdown() -> void:
	_exiting = true
	for tid in _falling_mesh_tasks:
		WorkerThreadPool.wait_for_task_completion(tid)
	_falling_mesh_tasks.clear()
	clear_all()


## 清空全部表现层产物（销毁 / 退出场景 / 重建时调用）。
func clear_all() -> void:
	if _debris_root:
		for child in _debris_root.get_children():
			child.queue_free()
	# 清空粒子池（场景退出时全部释放）
	for gp in _particle_pool:
		if is_instance_valid(gp):
			gp.queue_free()
	_particle_pool.clear()
	_particle_mesh_cache.clear()


## 在掉落块当前位置播放"整块碎裂"粒子（回收时视觉过渡）
## 从 body 记录的体素信息重建破碎粒子，用块中心作为发射中心
## 视锥外不执行（相机看不到，跳过昂贵粒子效果）
func spawn_chunk_break_at_body(body: RigidBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var local_voxels: Dictionary = body.get_meta("local_voxels", {})
	if local_voxels.is_empty():
		return
	# 发射中心 = 块中心（body 仍在场景中时的全局位置）
	var center := body.global_position
	# 视锥外跳过（看不到的破碎不需要粒子）
	if not host.infinite_layer.is_world_visible(center):
		return
	var emission_size := Vector3(2.0, 2.0, 2.0) * host.voxel_scale
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


## 压缩在途掉落块 mesh 任务表：丢弃已完成任务的 ID。
## 【为什么必须有】这些任务在结束时没有回调能摘除自己的 ID（结果回主线程时只带 body，
## 不带 tid），此前**只增不减**（仅 _exit_tree 清空）→ 长玩内存单调增长，退出时还要把
## 全部历史任务集体 wait。派发前做一次压缩，规模收敛到"真正在途"的数量。
func _prune_falling_mesh_tasks() -> void:
	if _falling_mesh_tasks.size() <= _FALLING_TASK_COMPACT_MIN:
		return
	var alive: Array[int] = []
	for tid in _falling_mesh_tasks:
		if not WorkerThreadPool.is_task_completed(tid):
			alive.append(tid)
	_falling_mesh_tasks = alive
## 从连通分组中生成掉落体（统一入口，消除代码重复）
## group_materials: Array[Dictionary]，每个元素是 {pos: mat_id} 映射
## 分流规则（按 falling_mode）：
##   - AUTO + 组体素数 <= AUTO_PARTICLE_VOXELS → GPU 粒子破碎（零物理开销，视觉自然）
##   - 其余 → 物理体（Box 或凸包，见 _on_falling_chunk_mesh_result）
## 返回实际生成的物理掉落体数量
func spawn_falling_chunks_from_groups(groups: Array, group_materials: Array[Dictionary]) -> int:
	var spawned_count := 0
	# 先处理小块（粒子）和大块（物理体）分流
	# 按 falling_mode 决定：AUTO 按体素数分档，PARTICLE 全转粒子，PHYSICS 全物理体
	var physics_groups: Array = []
	var physics_materials: Array[Dictionary] = []
	for i in range(groups.size()):
		var group: Array = groups[i]
		var to_particle := _falling_mode == FALLING_PARTICLE \
				or (_falling_mode == FALLING_AUTO and group.size() <= AUTO_PARTICLE_VOXELS)
		if to_particle:
			# 小块：直接转粒子破碎
			var mat_map: Dictionary = group_materials[i]
			if not group.is_empty():
				spawn_debris_with_materials(group, mat_map, true)
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
## 由宿主 _process 帧尾调用
func process_pending_falling_groups() -> void:
	if _pending_falling_groups.is_empty():
		return
	var count := 0
	while not _pending_falling_groups.is_empty() and count < _pending_build_per_frame:
		var group: Array = _pending_falling_groups.pop_front() as Array
		var mat_map: Dictionary = _pending_falling_materials.pop_front() as Dictionary
		_spawn_falling_chunk(group, mat_map)
		count += 1
	if host.diag_enabled and count > 0:
		print("[诊断] 待生成掉落体: 本帧生成%d, 剩余%d" % [count, _pending_falling_groups.size()])
## 确保崩塌掉落块根节点存在
func _ensure_falling_chunk_root() -> void:
	if not _falling_chunk_root:
		_falling_chunk_root = Node3D.new()
		_falling_chunk_root.name = "_FallingChunks"
		add_child(_falling_chunk_root, false, Node.INTERNAL_MODE_BACK)


## 生成一个崩塌掉落块（整块物理体）
## 将一组连通体素创建为一个"轻量静态 MeshInstance3D" + RigidBody3D 掉落
## 体素位置偏移到居中，使 RigidBody3D 位于块的中心
## mat_map: 体素位置 -> 材质ID 的映射（在调用前已从 host.data 中收集，因为体素可能在调用前已移除）
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
	if _body_pool_total.size() >= _falling_pool_size and _body_pool.is_empty():
		var evicted := _evict_oldest_falling_chunks(1)
		if evicted <= 0:
			spawn_chunk_break_debris(group, mat_map)
			return

	var _diag_t0 := Time.get_ticks_usec() if host.diag_enabled else 0

	_ensure_falling_chunk_root()

	# 1. 计算体素边界和中心
	var voxel_min := Vector3i(group[0])
	var voxel_max := Vector3i(group[0])
	for pos in group:
		var p: Vector3i = pos
		voxel_min = Vector3i(min(voxel_min.x, p.x), min(voxel_min.y, p.y), min(voxel_min.z, p.z))
		voxel_max = Vector3i(max(voxel_max.x, p.x), max(voxel_max.y, p.y), max(voxel_max.z, p.z))

	var voxel_center := (Vector3(voxel_min) + Vector3(voxel_max)) * 0.5 + Vector3(0.5, 0.5, 0.5)
	var world_center := voxel_center * host.voxel_scale

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
		if host.infinite_layer.is_world_visible(world_center + global_position):
			spawn_chunk_break_debris(group, mat_map)
		return

	# 2. 构建偏移到居中的体素字典（供一次性生成静态 mesh）
	# 使用提前收集的 mat_map 而非 host.data.voxels（体素可能已被移除）
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

	if host.diag_enabled:
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
	var materials_snapshot: Array = host.data.materials.duplicate(false) if host.data else []
	var spawn_scale := host.voxel_scale
	# 本块所用 body 的代次：随结果一起回传，应用前比对（body 可能已回池并被复用到新块）
	var body_gen: int = _body_gen.get(body, 0)
	# 跟踪任务 ID：退出时必须 join（见 _exit_tree），否则未跟踪 worker 的 call_deferred
	# 会打到已释放实例。派发前压缩一次，保证集合只保留真正在途的任务（有界）。
	_prune_falling_mesh_tasks()
	_falling_mesh_tasks.append(WorkerThreadPool.add_task(
		_falling_chunk_mesh_worker.bind(local_voxels, materials_snapshot, spawn_scale, body, body_gen)))


## 后台线程入口：为掉落块生成网格数组（线程安全，不触碰 ArrayMesh/节点）
## 完成后 call_deferred 回主线程 _on_falling_chunk_mesh_result 组装 ArrayMesh
## 优先走原生 dense 路径（generate_single_chunk_dense → GDExtension C++，
## 顶点复用 + 网格生成主循环 ~10 倍提速）；块体超 HALO_SIZE 时回退 generate_arrays_runtime
func _falling_chunk_mesh_worker(local_voxels: Dictionary, materials: Array, scale: float, body: RigidBody3D, body_gen: int) -> void:
	var arrays: Variant = _generate_falling_chunk_arrays(local_voxels, materials, scale)
	# 【凸包后台化】在后台线程计算碰撞外壳点集（体素包围盒 8 角点，O(1) 无凸包算法），
	# 替代主线程 create_convex_shape（实测 4096 体素块 69ms 主线程卡顿）。
	# 传回主线程 set_points 秒完成。
	var hull_points := _compute_hull_points(local_voxels, scale)
	call_deferred("_on_falling_chunk_mesh_result", body, arrays, local_voxels, hull_points, body_gen)


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
	# 【负坐标修复】local_voxels 以 center 为中心（可为负）。原生生成器按 chunk 分组时
	# 对负坐标（p>>CHUNK_SHIFT）分 chunk 导致各 chunk mesh 顶点基准不一致 → 掉落块被拉伸成"横条"。
	# 统一平移到非负（相对组最小角），并用 offset=min 补偿回 center 坐标系（C++: world = pos*scale + offset*scale）。
	var min_p := Vector3i(local_voxels.keys()[0])
	for pos_key in local_voxels:
		var p: Vector3i = pos_key
		min_p = Vector3i(mini(min_p.x, p.x), mini(min_p.y, p.y), mini(min_p.z, p.z))
	var translated: Dictionary = {}
	var max_extent := 0
	for pos_key in local_voxels:
		var p: Vector3i = pos_key
		var tp := p - min_p
		translated[tp] = int(local_voxels[pos_key])
		max_extent = maxi(max_extent, maxi(maxi(tp.x, tp.y), tp.z))
	var offset := Vector3(min_p)
	# 判断掉落体是否超出单 chunk dense 范围（平移后最大坐标）
	if max_extent <= VoxelChunk.HALO_SIZE - VoxelChunk.HALO - 1:
		# 构造密集 halo：以平移后原点为 chunk 原点（chunk_key=0），坐标 + HALO 偏移（非负）
		var halo := PackedInt32Array()
		halo.resize(VoxelChunk.HALO_VOLUME)
		for pos_key in translated:
			var p: Vector3i = pos_key
			var lx := p.x + VoxelChunk.HALO
			var ly := p.y + VoxelChunk.HALO
			var lz := p.z + VoxelChunk.HALO
			if lx < 0 or ly < 0 or lz < 0 or lx >= VoxelChunk.HALO_SIZE or ly >= VoxelChunk.HALO_SIZE or lz >= VoxelChunk.HALO_SIZE:
				return VoxelChunkGenerator.generate_arrays_runtime(translated, materials, {"scale": scale, "offset": offset})
			halo[VoxelChunk.halo_index(lx, ly, lz)] = int(translated[pos_key])
		var aligned := VoxelMaterial.align_by_id(materials)
		var result := VoxelChunkGenerator.generate_single_chunk_dense(
			halo, aligned, scale, Vector3i.ZERO, offset)
		if result != null and not result.is_empty():
			return result
	return VoxelChunkGenerator.generate_arrays_runtime(translated, materials, {"scale": scale, "offset": offset})


## 掉落体 mesh 组装入口：
## 结果入队，由 _process 帧尾限量组装（add_surface_from_arrays 的同步 GPU 上传
## 摊平到多帧，避免 Metal 满载时 fence wait() 超时）。
func _on_falling_chunk_mesh_result(body: RigidBody3D, arrays: Variant, local_voxels: Dictionary = {}, hull_points: PackedVector3Array = PackedVector3Array(), body_gen: int = -1) -> void:
	if _exiting:
		return
	if body == null or not is_instance_valid(body) or body.is_queued_for_deletion():
		return
	# 代次已过期（body 回池后被复用于新块）：本结果属于上一世的块，直接丢。
	if _body_gen.get(body, -1) != body_gen:
		return
	if arrays == null or not arrays is Dictionary or (arrays as Dictionary).is_empty():
		return
	_pending_mesh_results.append({
		"body": body, "arrays": arrays as Dictionary, "local_voxels": local_voxels,
		"hull_points": hull_points, "gen": body_gen,
	})


## 每帧从队列限量组装掉落体 mesh（积压的结果）
## 由宿主 _process 帧尾调用
func process_pending_mesh_results() -> void:
	if _pending_mesh_results.is_empty():
		return
	var count := 0
	while not _pending_mesh_results.is_empty() and count < _mesh_apply_per_frame:
		var entry: Dictionary = _pending_mesh_results.pop_front()
		var body: RigidBody3D = entry.get("body")
		if body != null and is_instance_valid(body) and not body.is_queued_for_deletion():
			# 二次比对代次（入队到出队之间 body 也可能被回池复用）
			if _body_gen.get(body, -1) != entry.get("gen", -1):
				continue
			_apply_falling_chunk_mesh(body, entry.get("arrays"), entry.get("local_voxels", {}), entry.get("hull_points", PackedVector3Array()))
			count += 1
	if host.diag_enabled and count > 0:
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
	var scale := host.voxel_scale
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
	# 体素格 p 在体素坐标里占 [p-0.5, p+0.5]，故 min_p..max_p 这段的盒心是 (min_p+max_p)/2。
	# 此前写成 min_p + size*0.5 = (min_p+max_p+1)/2，比正确位置多出半格，
	# 与 _compute_hull_points 给出的凸包（那一条是对的）错开半个体素 → 碰撞与视觉不符。
	col.position = (Vector3(min_p) + Vector3(max_p)) * 0.5 * scale
	body.add_child(col)
	col.owner = body


## 获取掉落块共用材质。走内核唯一材质缓存（同一份 data.materials 只生成一次，
## 源引用变化或 regenerate_materials 时自动作废），与渲染共用同一份 Material 对象。
func _get_cached_chunk_materials() -> Array:
	return host.surface_materials()


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
		_next_body_gen += 1
		_body_gen[body] = _next_body_gen
		return body
	# 池空：新建（若已达总容量上限则仍新建，由 _spawn_falling_chunk 的守卫控制降级）
	var new_body := RigidBody3D.new()
	new_body.name = "FallingChunk_%d_Body" % _falling_chunk_id
	_falling_chunk_id += 1
	new_body.gravity_scale = 1.0
	_body_pool_total.append(new_body)
	_next_body_gen += 1
	_body_gen[new_body] = _next_body_gen
	return new_body


## 释放物理体回池（复用，避免反复创建/销毁）
## 先从场景移除，复位状态后入空闲池
func _release_body(body: RigidBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	# 【改进3】回收前播放粒子破碎效果：块从场景消失时"哗啦碎成粒子"，
	# 而非凭空消失。用块自身的位置 + 记录的体素信息生成整块碎裂粒子。
	spawn_chunk_break_at_body(body)
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
##   - 超时：生成超过 `_falling_cleanup_time`（宿主 falling_chunk_cleanup_time）的块移除
##   - 数量上限：超出 `_max_falling_chunks`（宿主 max_falling_chunks）时按生成先后移除最老的（复用 _evict_oldest_falling_chunks）
## 防止大量破坏后物理体+网格无限堆积拖慢帧率（用户反馈的帧率下降问题）
## 由宿主按 ~1 秒的节奏调用（宿主用累计时间而非固定帧数驱动）。
func freeze_sleeping_chunks() -> void:
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

	# 2. 超时清理：生成超过 _falling_cleanup_time 的块移除（含未冻结的）
	var cleanup_ms := int(_falling_cleanup_time * 1000.0)
	for body in alive:
		if not is_instance_valid(body):
			continue
		if now - _chunk_spawn_times.get(body, 0) >= cleanup_ms:
			_cleanup_falling_chunk(body)

	# 3. 数量上限清理：超出 _max_falling_chunks 时移除最老的（复用统一逐出逻辑）
	var overflow := alive.size() - _max_falling_chunks
	if overflow > 0:
		_evict_oldest_falling_chunks(overflow)

	# 4. 清理已失效引用（queue_free 是延迟的，这里只清记录，避免字典残留）
	for body in _chunk_spawn_times.keys():
		if not is_instance_valid(body):
			_chunk_spawn_times.erase(body)

