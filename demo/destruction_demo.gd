extends Node
## 体素破坏系统演示 - 超大型性能测试场景
##
## 展示+测试：
##   - 超大型体素结构 (可配置尺寸，默认 200x100x200)
##   - 持续按住鼠标左键进行连续球形破坏 (性能压力测试)
##   - 逐帧性能监控：网格重建耗时、顶点/三角形数、chunk 统计
##   - 滚动性能日志，方便定位瓶颈拐点
##
## 键位说明：
##   鼠标左键(按住) : 连续球形破坏
##   鼠标右键(按住) : 连续单体破坏
##   空格(按住)     : 连续射线破坏
##   C              : 切换 边缘触发/连续 模式
##   V              : 切换破坏显示模式 (球形/射线)
##   1/2            : 切换碎片模式 (物理/视觉)
##   B              : 破坏底部支撑层 (触发大面积崩塌)
##   R              : 重置场景
##   S/L            : 存档/读档
##   T              : 切换性能日志显示
##   +/-            : 调整破坏半径

## 体素缩放
@export var voxel_scale: float = 0.1

## 破坏半径 (体素单位)
@export var damage_radius: float = 7.0

## 大结构尺寸 [体素] (x, y, z)
@export var structure_size: Vector3i = Vector3i(200, 100, 200)

## 外壳厚度 (体素)
@export var shell_thickness: int = 3

## 内部隔墙间隔 (0=无隔墙)
@export var internal_wall_interval: int = 25

## 楼层数
@export var floor_count: int = 10

## 连续模式：每 N 帧执行一次破坏 (值越小越快)
@export var continuous_interval: int = 3

## 可选的数据源
@export var voxel_data_source: VoxelData:
	set(v):
		voxel_data_source = v
		if is_inside_tree():
			_build_target()

## 可破坏对象
var _target: VoxelDestructible
var _hud: Label
var _perf_log_label: Label
var _mode_label: Label
var _camera: Camera3D

## 连续破坏模式开关
var _continuous_mode: bool = true

## 性能日志
var _perf_log: Array[String] = []
var _show_perf_log: bool = true
const MAX_PERF_LOG: int = 60

## 性能统计滚动窗口
var _mesh_gen_times: Array[float] = []
var _damage_times: Array[float] = []
var _collapse_counts: Array[int] = []
var _voxel_counts: Array[int] = []

## 性能统计缓存（避免每帧重算）
var _cached_avg_mgt: float = 0.0
var _cached_min_mgt: float = 0.0
var _cached_max_mgt: float = 0.0
var _cached_avg_dt: float = 0.0
var _cached_high_mgt_count: int = 0
var _cached_under_200_count: int = 0
var _cached_under_500_count: int = 0
var _cached_chart: String = ""
var _stats_dirty: bool = true
var _chart_dirty: bool = true
var _frame_count: int = 0
var _continuous_counter: int = 0
var _last_log_time: int = 0

## 上一帧状态
var _prev_left := false
var _prev_right := false
var _prev_space := false
var _prev_r := false
var _prev_b := false
var _prev_s := false
var _prev_l := false
var _prev_1 := false
var _prev_2 := false
var _prev_c := false
var _prev_v := false
var _prev_t := false
var _prev_plus := false
var _prev_minus := false
var _saved_data: Variant = null

## 破坏模式
enum DamageMode { SPHERE, RAY }
var _damage_mode: int = DamageMode.SPHERE


func _ready() -> void:
	_setup_ground()
	_build_target()
	_setup_camera()
	_setup_hud()
	_perf_log.append("=".repeat(60))
	_perf_log.append("[性能测试] 超大型体素结构 %dx%dx%d 初始化完成" % [structure_size.x, structure_size.y, structure_size.z])
	_perf_log.append("[性能测试] 外壳厚度=%d 隔墙间隔=%d 楼层数=%d" % [shell_thickness, internal_wall_interval, floor_count])
	_perf_log.append("[性能测试] 连续模式=%s 间隔=%d帧" % [_continuous_mode, continuous_interval])
	_last_log_time = Time.get_ticks_msec()
	_log_perf_line("初始化完成")


func _log_perf_line(msg: String) -> void:
	var elapsed := Time.get_ticks_msec() - _last_log_time
	var time_str := "[+%dms]" % elapsed
	var full_msg := time_str + " " + msg
	_perf_log.append(full_msg)
	if _perf_log.size() > MAX_PERF_LOG:
		_perf_log.pop_front()
	print(full_msg)
	_last_log_time = Time.get_ticks_msec()


## 创建地面
func _setup_ground() -> void:
	var gs := maxf(structure_size.x, structure_size.z) * voxel_scale * 2.5
	var static_body := StaticBody3D.new()
	static_body.name = "Ground"
	var shape := BoxShape3D.new()
	shape.size = Vector3(gs, 0.5, gs)
	var oid := static_body.create_shape_owner(static_body)
	static_body.shape_owner_add_shape(oid, shape)
	static_body.position = Vector3(0, -0.5, 0)
	add_child(static_body)

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(gs, 0.5, gs)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.35, 0.4, 0.8)
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0, -0.5, 0)
	add_child(mesh_inst)

	var coll := GPUParticlesCollisionBox3D.new()
	coll.size = Vector3(gs, 2, gs)
	coll.position = Vector3(0, -1.0, 0)
	add_child(coll)


func _process(delta: float) -> void:
	_frame_count += 1
	_handle_input(delta)
	_update_hud()

	# 每 60 帧（约1秒）记录一次详细性能日志
	if _frame_count % 60 == 0 and _perf_log.size() < MAX_PERF_LOG - 10:
		var mgt := _target.last_mesh_gen_time_ms
		var vc := _target.data.get_voxel_count()
		var rebuild_chunks := _target.last_rebuild_chunk_count
		var total_tris := _target.last_solid_triangles + _target.last_trans_triangles
		var apply_time := _target.last_apply_time_ms
		_log_perf_line("[性能] 体素=%d 重建Chunk=%d 三角=%d 生成=%.1fms 应用=%.1fms" % [vc, rebuild_chunks, total_tris, mgt, apply_time])


func _build_target() -> void:
	if _target and is_instance_valid(_target):
		_target.queue_free()

	_target = VoxelDestructible.new()
	_target.name = "DestructibleVoxels"
	add_child(_target)

	var data: VoxelData
	if voxel_data_source != null:
		data = voxel_data_source
	else:
		data = _create_large_structure_data()

	_target.data = data
	_target.voxel_scale = voxel_scale
	_target.use_chunk_generator = true
	_target.async_generate = true
	_target.spawn_debris_on_damage = true
	_target.max_debris_per_hit = 40
	# 碎片系统已改为纯粒子实现，无物理碰撞体
	_target.use_voxel_health = true
	_target.damage_per_voxel = 1.0
	_target.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	_target.local_collapse = true

	if not _target.voxel_hardened.is_connected(_on_voxel_hardened):
		_target.voxel_hardened.connect(_on_voxel_hardened)
	if not _target.voxels_about_to_collapse.is_connected(_on_voxels_collapse):
		_target.voxels_about_to_collapse.connect(_on_voxels_collapse)
	if not _target.mesh_updated.is_connected(_on_mesh_updated):
		_target.mesh_updated.connect(_on_mesh_updated)

	var bounds: AABB = data.get_voxels_aabb()
	_target.global_position = Vector3(-bounds.size.x * voxel_scale * 0.5, 0, -bounds.size.z * voxel_scale * 0.5)

	# 重置性能统计
	_mesh_gen_times.clear()
	_damage_times.clear()
	_collapse_counts.clear()
	_voxel_counts.clear()


## 创建超大型体素结构
## 包含：外壳 + 多层地板 + 内部隔墙 + 窗户/门洞，模拟大型建筑群
func _create_large_structure_data() -> VoxelData:
	var data := VoxelData.new()
	var S := structure_size
	var t := shell_thickness

	# 材质定义
	# 物理属性说明：
	#   hardness       → 抗直接打击（需要多少伤害才能破坏）
	#   connection_strength → 抗应力传播（裂纹扩散阻力）
	#   mass           → 碎片粒子表现（重物飞得近/落得快，轻物飞得远/飘得久）
	var concrete := VoxelMaterial.new()
	concrete.id = 1
	concrete.color = Color(0.45, 0.45, 0.5)
	concrete.rough = 0.9
	concrete.hardness = 4.0
	concrete.connection_strength = 12.0
	concrete.mass = 1.5
	data.add_material(concrete)

	var metal := VoxelMaterial.new()
	metal.id = 2
	metal.color = Color(0.7, 0.7, 0.8)
	metal.metal = 0.8
	metal.rough = 0.3
	metal.hardness = 6.0
	metal.connection_strength = 20.0
	metal.mass = 2.0
	data.add_material(metal)

	var glass := VoxelMaterial.new()
	glass.id = 3
	glass.color = Color(0.6, 0.8, 1.0)
	glass.trans = 0.6
	glass.rough = 0.1
	glass.hardness = 0.5
	glass.connection_strength = 2.0
	glass.mass = 0.3
	data.add_material(glass)

	var accent := VoxelMaterial.new()
	accent.id = 4
	accent.color = Color(0.9, 0.3, 0.2)
	accent.rough = 0.5
	accent.hardness = 1.0
	accent.connection_strength = 8.0
	accent.mass = 0.5
	data.add_material(accent)

	# 根据楼层数计算每层高度
	var floor_height := maxi(1, (S.y - 2) / floor_count)

	# --- 1. 外壳 (地板、天花板、四周墙壁) ---
	# 地板: y=0, 整个底面
	for x in range(S.x):
		for z in range(S.z):
			data.set_voxel(Vector3i(x, 0, z), concrete.id)

	# 天花板: y=S.y-1
	for x in range(S.x):
		for z in range(S.z):
			data.set_voxel(Vector3i(x, S.y - 1, z), metal.id)

	# 四周墙壁 (厚度 t)
	for y in range(1, S.y - 1):
		# 前墙 (z=0) 和后墙 (z=S.z-1)
		for x in range(S.x):
			for thick in range(t):
				var z_pos := thick
				var z_end := S.z - 1 - thick
				if z_pos < S.z:
					data.set_voxel(Vector3i(x, y, z_pos), metal.id)
				if z_end >= 0 and z_end != z_pos:
					data.set_voxel(Vector3i(x, y, z_end), metal.id)
		# 左墙 (x=0) 和右墙 (x=S.x-1)
		for z in range(t, S.z - t):
			data.set_voxel(Vector3i(0, y, z), metal.id)
			data.set_voxel(Vector3i(S.x - 1, y, z), metal.id)

	# --- 2. 内部楼层地板 ---
	for floor in range(1, floor_count):
		var floor_y := floor * floor_height
		if floor_y >= S.y - 1:
			break
		# 楼层地板 (厚度 t)
		for fy in range(floor_y, mini(floor_y + t, S.y - 1)):
			for x in range(t, S.x - t):
				for z in range(t, S.z - t):
					data.set_voxel(Vector3i(x, fy, z), concrete.id)

	# --- 3. 内部隔墙 ---
	if internal_wall_interval > 0:
		for y in range(1, S.y - 1):
			# X 方向隔墙
			for wx in range(internal_wall_interval, S.x - t, internal_wall_interval):
				if wx >= S.x - t:
					break
				for z in range(t, S.z - t):
					# 跳过已有地板位置
					var is_floor := false
					for floor in range(floor_count):
						var fy := floor * floor_height
						if y >= fy and y < fy + t:
							is_floor = true
							break
					if not is_floor:
						data.set_voxel(Vector3i(wx, y, z), accent.id)
			# Z 方向隔墙
			for wz in range(internal_wall_interval, S.z - t, internal_wall_interval):
				if wz >= S.z - t:
					break
				for x in range(t, S.x - t):
					var is_floor := false
					for floor in range(floor_count):
						var fy := floor * floor_height
						if y >= fy and y < fy + t:
							is_floor = true
							break
					if not is_floor:
						data.set_voxel(Vector3i(x, y, wz), accent.id)

	# --- 4. 窗户 (前墙和后墙) ---
	var win_interval := maxi(15, S.x / 8)
	var win_h := 8
	var win_w := 6
	var win_y_start := 8
	var win_count := S.x / win_interval
	for wi in range(win_count):
		var wx := wi * win_interval + 4
		if wx + win_w >= S.x - 1:
			break
		# 前墙窗户 (z=0 处)
		for y in range(win_y_start, win_y_start + win_h):
			for x in range(wx, wx + win_w):
				if data.has_voxel(Vector3i(x, y, 0)):
					data.remove_voxel(Vector3i(x, y, 0))
		# 后墙窗户 (z=S.z-1 处)
		for y in range(win_y_start, win_y_start + win_h):
			for x in range(wx, wx + win_w):
				if data.has_voxel(Vector3i(x, y, S.z - 1)):
					data.remove_voxel(Vector3i(x, y, S.z - 1))

	# --- 5. 门洞 (前墙底部) ---
	var door_w := 6
	var door_h := 8
	var door_x := S.x / 2 - door_w / 2
	for y in range(0, door_h):
		for x in range(door_x, door_x + door_w):
			data.remove_voxel(Vector3i(x, y, 0))

	# 侧墙门洞
	for y in range(0, door_h):
		for z in range(S.z / 2 - door_w / 2, S.z / 2 + door_w / 2):
			data.remove_voxel(Vector3i(0, y, z))
			data.remove_voxel(Vector3i(S.x - 1, y, z))

	_perf_log.append("[生成] 结构尺寸: %dx%dx%d = ~%d 体素" % [S.x, S.y, S.z, S.x * S.y * S.z])
	_perf_log.append("[生成] 实际体素数: %d" % data.get_voxel_count())

	return data


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D")
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		_camera.current = true
		add_child(_camera)

	var world := Vector3(structure_size) * voxel_scale
	var center := world * 0.5
	var world_center := _target.global_position + center
	var max_dim := maxf(world.x, maxf(world.y, world.z))
	# 将相机置于建筑外部斜上方，确保能看清整体结构
	var dist := max_dim * 0.7
	_camera.global_position = world_center + Vector3(-dist * 0.6, dist * 0.5, dist * 0.8)
	_camera.look_at(world_center, Vector3.UP)
	_camera.fov = 65
	_camera.far = max_dim * 4.0


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

	# 性能日志 (右侧滚动区域)
	_perf_log_label = Label.new()
	_perf_log_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_perf_log_label.position = Vector2(-400, 10)
	_perf_log_label.size = Vector2(390, 580)
	_perf_log_label.add_theme_font_size_override("font_size", 12)
	_perf_log_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	_perf_log_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_perf_log_label.add_theme_constant_override("outline_size", 3)
	_perf_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	layer.add_child(_perf_log_label)

	_mode_label = Label.new()
	_mode_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_mode_label.position = Vector2(10, 260)
	_mode_label.add_theme_font_size_override("font_size", 13)
	_mode_label.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0))
	_mode_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_mode_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_mode_label)


func _handle_input(_delta: float) -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var space := Input.is_key_pressed(KEY_SPACE)
	var key_r := Input.is_key_pressed(KEY_R)
	var key_b := Input.is_key_pressed(KEY_B)
	var key_s := Input.is_key_pressed(KEY_S)
	var key_l := Input.is_key_pressed(KEY_L)
	var key_1 := Input.is_key_pressed(KEY_1)
	var key_2 := Input.is_key_pressed(KEY_2)
	var key_c := Input.is_key_pressed(KEY_C)
	var key_v := Input.is_key_pressed(KEY_V)
	var key_t := Input.is_key_pressed(KEY_T)
	var key_plus := Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_KP_ADD)
	var key_minus := Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT)

	# --- 模式切换 (边缘触发) ---
	# C: 切换连续/边缘模式
	if key_c and not _prev_c:
		_continuous_mode = not _continuous_mode
		_log_perf_line("连续模式: %s" % _continuous_mode)

	# V: 切换破坏模式
	if key_v and not _prev_v:
		_damage_mode = (DamageMode.SPHERE if _damage_mode == DamageMode.RAY else DamageMode.RAY)
		_log_perf_line("破坏模式: %s" % ("球形" if _damage_mode == DamageMode.SPHERE else "射线"))

	# T: 切换性能日志
	if key_t and not _prev_t:
		_show_perf_log = not _show_perf_log

	# +/-: 调整破坏半径
	if key_plus and not _prev_plus:
		damage_radius = mini(damage_radius + 1.0, 30.0)
		_log_perf_line("破坏半径: %.1f" % damage_radius)
	if key_minus and not _prev_minus:
		damage_radius = maxf(damage_radius - 1.0, 1.0)
		_log_perf_line("破坏半径: %.1f" % damage_radius)

	# 1/2: 调整应力传播强度
	if key_1 and not _prev_1:
		_target.stress_force = mini(_target.stress_force + 5.0, 50.0)
		_log_perf_line("应力强度: %.0f (max_steps=%d)" % [_target.stress_force, _target.stress_max_steps])
	if key_2 and not _prev_2:
		_target.stress_force = maxf(_target.stress_force - 5.0, 5.0)
		_log_perf_line("应力强度: %.0f (max_steps=%d)" % [_target.stress_force, _target.stress_max_steps])

	# R: 重置
	if key_r and not _prev_r:
		_build_target()
		_log_perf_line("场景重置")

	# B: 破坏底部支撑层
	if key_b and not _prev_b:
		_target.damage_box(AABB(Vector3(0, 0, 0), Vector3(structure_size.x, 1.5, 1.5)))
		_log_perf_line("触发底部支撑层破坏")

	# S/L: 存档/读档
	if key_s and not _prev_s:
		_saved_data = _target.data.save_data()
		_log_perf_line("存档 (%d 体素)" % _target.data.get_voxel_count())
	if key_l and not _prev_l and _saved_data != null:
		_target.damage_map.clear()
		_target.data.load_data(_saved_data)
		_target.validate_stability()
		_log_perf_line("读档重建")

	# --- 破坏执行 ---
	if _continuous_mode:
		# 连续模式：按住时持续执行，按 continuous_interval 帧间隔
		_continuous_counter += 1
		if _continuous_counter >= continuous_interval:
			_continuous_counter = 0
			_execute_damage(left, right, space)
	else:
		# 边缘触发模式：只在按下瞬间执行
		if left and not _prev_left:
			_execute_damage(true, false, false)
		if right and not _prev_right:
			_execute_damage(false, true, false)
		if space and not _prev_space:
			_execute_damage(false, false, true)

	_prev_left = left
	_prev_right = right
	_prev_space = space
	_prev_r = key_r
	_prev_b = key_b
	_prev_s = key_s
	_prev_l = key_l
	_prev_1 = key_1
	_prev_2 = key_2
	_prev_c = key_c
	_prev_v = key_v
	_prev_t = key_t
	_prev_plus = key_plus
	_prev_minus = key_minus


func _execute_damage(do_left: bool, do_right: bool, do_space: bool) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	if _camera == null:
		return

	if do_left:
		match _damage_mode:
			DamageMode.SPHERE:
				var hit := _mouse_to_voxel()
				if hit != Vector3i.MIN:
					var t0 := Time.get_ticks_usec()
					_target.damage_sphere(Vector3(hit) + Vector3(0.5, 0.5, 0.5), damage_radius)
					var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
					_damage_times.append(elapsed)
					if _damage_times.size() > 100:
						_damage_times.pop_front()
					_log_perf_line("球形破坏 半径=%.1f 移除=%d 崩塌=%d 耗时=%.3fms" % [
						damage_radius, _target.last_damage_count, _target.last_collapse_count, elapsed])
			DamageMode.RAY:
				var forward := -_camera.global_transform.basis.z
				var origin := _camera.global_position
				var local_origin := _target.to_local(origin)
				var local_dir := _target.global_transform.basis.inverse() * forward
				var t0 := Time.get_ticks_usec()
				_target.damage_ray(local_origin / voxel_scale, local_dir, 1000.0)
				var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
				_damage_times.append(elapsed)
				if _damage_times.size() > 100:
					_damage_times.pop_front()
				_log_perf_line("射线破坏 移除=%d 崩塌=%d 耗时=%.3fms" % [
					_target.last_damage_count, _target.last_collapse_count, elapsed])

	if do_right:
		var hit := _mouse_to_voxel()
		if hit != Vector3i.MIN:
			var t0 := Time.get_ticks_usec()
			_target.damage_voxel(hit)
			var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
			_damage_times.append(elapsed)
			if _damage_times.size() > 100:
				_damage_times.pop_front()
			_log_perf_line("单体破坏 移除=%d 崩塌=%d" % [_target.last_damage_count, _target.last_collapse_count])

	if do_space:
		var forward := -_camera.global_transform.basis.z
		var origin := _camera.global_position
		var local_origin := _target.to_local(origin)
		var local_dir := _target.global_transform.basis.inverse() * forward
		var t0 := Time.get_ticks_usec()
		_target.damage_ray(local_origin / voxel_scale, local_dir, 1000.0)
		var elapsed := (Time.get_ticks_usec() - t0) / 1000.0
		_damage_times.append(elapsed)
		if _damage_times.size() > 100:
			_damage_times.pop_front()
		_log_perf_line("空格射线 移除=%d 崩塌=%d 耗时=%.3fms" % [_target.last_damage_count, _target.last_collapse_count, elapsed])


func _mouse_to_voxel() -> Vector3i:
	if _camera == null:
		return Vector3i.MIN
	var from := _camera.project_ray_origin(get_viewport().get_mouse_position())
	var dir := _camera.project_ray_normal(get_viewport().get_mouse_position())
	var local_origin := _target.to_local(from)
	var local_dir := _target.global_transform.basis.inverse() * dir
	return _target.raycast_voxel(local_origin / voxel_scale, local_dir, 1000.0)


func _update_hud() -> void:
	if _hud == null:
		return

	# 收集最新数据（仅当有变化时才标记脏）
	var mgt := _target.last_mesh_gen_time_ms
	if _mesh_gen_times.is_empty() or mgt != _mesh_gen_times.back():
		_stats_dirty = true
		_chart_dirty = true
		_mesh_gen_times.append(mgt)
		if _mesh_gen_times.size() > 200:
			_mesh_gen_times.pop_front()

	var vc := _target.data.get_voxel_count()
	if _voxel_counts.is_empty() or vc != _voxel_counts.back():
		_voxel_counts.append(vc)
		if _voxel_counts.size() > 200:
			_voxel_counts.pop_front()

	# 仅当数据变化时重算统计值
	if _stats_dirty:
		_stats_dirty = false
		_recompute_stats()

	# 仅每 10 帧重生成柱状图（字符串操作开销较大）
	if _chart_dirty and _frame_count % 10 == 0:
		_chart_dirty = false
		_recompute_chart()

	# 读取缓存值
	var avg_mgt := _cached_avg_mgt
	var min_mgt := _cached_min_mgt
	var max_mgt := _cached_max_mgt
	var avg_dt := _cached_avg_dt
	var high_mgt_count := _cached_high_mgt_count
	var under_200_count := _cached_under_200_count
	var under_500_count := _cached_under_500_count
	var chart := _cached_chart

	var initial_voxels := _voxel_counts[0] if not _voxel_counts.is_empty() else 0
	var destroyed := initial_voxels - vc

	# 网格重建统计
	var chunk_count := _target.last_total_chunks
	var solid_tris := _target.last_solid_triangles
	var trans_tris := _target.last_trans_triangles
	var total_tris := solid_tris + trans_tris
	var rebuild_chunks := _target.last_rebuild_chunk_count
	var affected_chunks := _target.last_rebuild_affected_count
	var mesh_gen_slice := _target.last_mesh_gen_time_slice_ms
	var apply_time := _target.last_apply_time_ms

	# Chunk 生成效率
	var avg_chunk_gen_ms := 0.0
	if rebuild_chunks > 0:
		avg_chunk_gen_ms = mgt / rebuild_chunks

	# 性能缩放评价
	var perf_rating := "优秀"
	var perf_rating_color := "绿色"
	if avg_mgt > 500:
		perf_rating = "卡顿"
		perf_rating_color = "红色"
	elif avg_mgt > 200:
		perf_rating = "一般"
		perf_rating_color = "黄色"
	elif avg_mgt > 100:
		perf_rating = "良好"
		perf_rating_color = "浅绿"

	var mode_name := "粒子"
	var collapse_method := "局部增量" if _target.local_collapse else "全量"
	var dm_name := "球形" if _damage_mode == DamageMode.SPHERE else "射线"

	_hud.text = """===== 体素性能监控 =====
FPS: %d  |  帧: %d
体素总数: %d  |  已破坏: %d
Chunk数: %d  |  应力: %.0f(步数%d)

[网格重建耗时] 评价: %s(%s)
当前: %.1f ms  |  平均: %.1f ms
最低: %.1f ms  |  最高: %.1f ms
近60帧: <=200ms(%d)  <=500ms(%d)  >1000ms(%d)

[重建明细]
重建Chunk: %d  |  受影响Chunk: %d
生成阶段: %.1f ms  |  应用阶段: %.1f ms
平均每Chunk: %.2f ms
实心三角: %d  |  透明三角: %d  |  合计: %d

[破坏 (Damage)]
平均耗时: %.4f ms
上次移除体素: %d
上次崩塌体素数: %d

[体素坍缩]
崩塌检测: %s  |  支撑强度: 无(粒子系统)

[时间线: 近%d帧网格重建耗时趋势]
%s
""" % [
		Engine.get_frames_per_second(), _frame_count,
		vc, destroyed,
		chunk_count, _target.stress_force, _target.stress_max_steps,
		perf_rating, perf_rating_color,
		mgt, avg_mgt,
		min_mgt, max_mgt,
		under_200_count, under_500_count, high_mgt_count,
		rebuild_chunks, affected_chunks,
		mesh_gen_slice, apply_time,
		avg_chunk_gen_ms,
		solid_tris, trans_tris, total_tris,
		avg_dt,
		_target.last_damage_count,
		_target.last_collapse_count,
		collapse_method,
		_mesh_gen_times.size(), chart,
	]

	_mode_label.text = """碎片: %s  |  模式: %s  |  连续: %s
半径: %.1f  |  间隔: %d帧
[左键]球形 [右键]单体 [空格]射线
[C]连续开关 [V]切换模式 [T]日志开关
[+/-]半径  [R]重置 [B]崩底
[1]应力+ [2]应力-  [S]存档 [L]读档
结构: %dx%dx%d  |  外壳: %d  |  楼层: %d
""" % [
		mode_name, dm_name, "开" if _continuous_mode else "关",
		damage_radius, continuous_interval,
		structure_size.x, structure_size.y, structure_size.z,
		shell_thickness, floor_count,
	]

	# 性能日志仅在 Godot 控制台输出（不再显示在 UI 中）
	# 日志由 _log_perf_line 统一管理，自动打印到控制台
	if _show_perf_log and _perf_log_label:
		_perf_log_label.text = "日志已输出到 Godot 控制台\n按 T 切换显示"


## 重新计算统计缓存（仅在数据变化时调用）
func _recompute_stats() -> void:
	if _mesh_gen_times.is_empty():
		_cached_avg_mgt = 0.0
		_cached_min_mgt = 0.0
		_cached_max_mgt = 0.0
		_cached_high_mgt_count = 0
		_cached_under_200_count = 0
		_cached_under_500_count = 0
		return

	var sum := 0.0
	var min_val := _mesh_gen_times[0]
	var max_val := _mesh_gen_times[0]
	var high_count := 0
	var under_200 := 0
	var under_500 := 0
	# 单次遍历计算所有统计指标
	var start_idx := maxi(0, _mesh_gen_times.size() - 60)
	for i in _mesh_gen_times.size():
		var v := _mesh_gen_times[i]
		sum += v
		if v < min_val: min_val = v
		if v > max_val: max_val = v
		if i >= start_idx:
			if v > 1000: high_count += 1
			if v <= 200: under_200 += 1
			if v <= 500: under_500 += 1

	_cached_avg_mgt = sum / _mesh_gen_times.size()
	_cached_min_mgt = min_val
	_cached_max_mgt = max_val
	_cached_high_mgt_count = high_count
	_cached_under_200_count = under_200
	_cached_under_500_count = under_500

	# 计算破坏平均耗时
	if not _damage_times.is_empty():
		var dsum := 0.0
		for v in _damage_times:
			dsum += v
		_cached_avg_dt = dsum / _damage_times.size()


## 重新生成柱状图（每 10 帧调用一次）
func _recompute_chart() -> void:
	if _mesh_gen_times.is_empty():
		_cached_chart = ""
		return

	var chart_width := 50
	var chart_data := _mesh_gen_times.slice(maxi(0, _mesh_gen_times.size() - chart_width))
	if chart_data.is_empty():
		_cached_chart = ""
		return

	var c_max: float = chart_data.max()
	c_max = maxf(c_max, 1.0)
	var c_min: float = chart_data.min()
	var thresholds: Array[float] = [c_max * 0.8, c_max * 0.6, c_max * 0.4, c_max * 0.2, 0.0]
	var labels: Array[String] = ["800%+ ", "600%+ ", "400%+ ", "200%+ ", "min  "]

	var chart := ""
	for row in 5:
		var line: String = labels[row]
		var th: float = thresholds[row]
		var next_th: float = thresholds[row + 1] if row + 1 < thresholds.size() else -1.0
		for v in chart_data:
			if v >= th:
				line += "█"
			elif next_th >= 0 and v >= next_th:
				line += "▓"
			else:
				line += "░"
		chart += line + "\n"
	chart += "      " + ("%.0f" % c_min).rpad(10) + ("%.0fms" % c_max) + "\n"
	_cached_chart = chart


func _on_voxel_hardened(_pos: Vector3i, _remaining: float) -> void:
	pass


func _on_voxels_collapse(positions: Array) -> void:
	_collapse_counts.append(positions.size())
	if _collapse_counts.size() > 100:
		_collapse_counts.pop_front()
	_log_perf_line("崩塌: %d 体素掉落" % positions.size())


## 网格重建完成回调 - 记录详细性能信息
func _on_mesh_updated() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var mgt := _target.last_mesh_gen_time_ms
	var rebuild_chunks := _target.last_rebuild_chunk_count
	var affected_chunks := _target.last_rebuild_affected_count
	var total_tris := _target.last_solid_triangles + _target.last_trans_triangles
	var apply_time := _target.last_apply_time_ms
	_log_perf_line("[网格完成] 重建Chunk=%d 受影响=%d 三角=%d 生成=%.1fms 应用=%.1fms" % [rebuild_chunks, affected_chunks, total_tris, mgt, apply_time])