extends Node
## 体素优化测试场 - 大型世界性能对比场景
##
## 目标：在大型场景下测试所有优化方向的效果：
##   1. 视锥剔除 (use_frustum_culling)          —— 减少生成/渲染
##   2. 超级块合并 (superchunk_size)             —— 减少 draw call
##   3. 原生加速 (NativeLoader)                  —— GDExtension C++ 热路径
##   4. 异步生成 (async_generate)                —— 线程并行
##   5. 崩塌检测 (find_unsupported)              —— 失稳算法
##
## 场景：大型建筑群（多栋高层建筑 + 地面层），chunk 数远超单建筑 demo
## 提供自动测试模式：自动切换各优化开关并测 FPS，输出对比结果
##
## 键位：
##   1 : 切换 视锥剔除 开/关
##   2 : 循环 超级块大小 (0/2/4)
##   3 : 切换 异步生成 开/关
##   4 : 切换 原生加速 开/关 (需重启生效)
##   5 : 环绕相机 (自动测 FPS)
##   6 : 重置场景
##   左键 : 球形破坏
##   空格 : 射线破坏

## 体素缩放
@export var voxel_scale: float = 0.1

## 破坏半径 (体素单位)
@export var damage_radius: float = 7.0

## 世界尺寸 [体素] (x, y, z) - 大型
@export var world_size: Vector3i = Vector3i(400, 120, 400)

## 建筑数量（网格排列）
@export var buildings_x: int = 3
@export var buildings_z: int = 3

## 单栋建筑尺寸
@export var building_size: Vector3i = Vector3i(100, 100, 100)

## 建筑间距 (体素)
@export var building_spacing: int = 30

## 外壳厚度
@export var shell_thickness: int = 3

## 楼层数
@export var floor_count: int = 8

## 地面厚度
@export var ground_thickness: int = 4

## 自动测试模式：true 时启动后自动循环所有优化组合测 FPS
@export var auto_test: bool = false

## 自动测试每组合采样帧数
@export var auto_test_frames: int = 180

## 可破坏对象
var _target: VoxelDestructible
var _camera: Camera3D
var _hud: Label
var _mode_label: Label

## 环绕相机状态
var _orbit_angle: float = 0.0
var _orbit_active: bool = false

## 自动测试状态
var _auto_testing: bool = false
var _test_results: Array = []
var _auto_frame: int = 0
var _auto_fps_sum: float = 0.0
var _auto_combos: Array = []

## 上一帧按键
var _prev_1 := false
var _prev_2 := false
var _prev_3 := false
var _prev_4 := false
var _prev_5 := false
var _prev_6 := false
var _prev_space := false

## 原生可用性（用于 HUD 显示）
var _native_available := false


func _ready() -> void:
	_setup_ground()
	_build_target()
	_setup_camera()
	_setup_hud()
	_native_available = NativeLoader.is_available()
	print("[测试场] 初始化完成 world=%dx%dx%d 建筑=%dx%d 原生=%s" % [
		world_size.x, world_size.y, world_size.z, buildings_x, buildings_z,
		"ON" if _native_available else "OFF"])

	if auto_test:
		_start_auto_test()


func _process(delta: float) -> void:
	_handle_input(delta)

	# 环绕相机
	if _orbit_active:
		_orbit_angle += delta * 0.6
		var center := _get_world_center()
		var dist := maxf(world_size.x, world_size.z) * voxel_scale * 0.7
		_camera.global_position = center + Vector3(cos(_orbit_angle) * dist, 30, sin(_orbit_angle) * dist)
		_camera.look_at(center, Vector3.UP)

	# 自动测试：每组合测 N 帧 FPS
	if _auto_testing:
		_auto_frame += 1
		_auto_fps_sum += Engine.get_frames_per_second()
		if _auto_frame >= auto_test_frames:
			var avg := _auto_fps_sum / auto_test_frames
			var combo: Dictionary = _auto_combos[_auto_combos.size() - 1]
			_test_results.append({
				"culling": combo["culling"],
				"superchunk": combo["superchunk"],
				"async": combo["async"],
				"fps": avg,
			})
			print("[测试] culling=%s superchunk=%d async=%s → %.1f FPS" % [
				combo["culling"], combo["superchunk"], combo["async"], avg])
			_auto_fps_sum = 0.0
			_auto_frame = 0
			_advance_auto_test()

	_update_hud()


## 构建测试目标
func _build_target() -> void:
	if _target and is_instance_valid(_target):
		_target.queue_free()

	_target = VoxelDestructible.new()
	_target.name = "DestructibleVoxels"
	add_child(_target)

	var data := _create_test_world_data()
	_target.data = data
	_target.voxel_scale = voxel_scale
	_target.use_chunk_generator = true
	_target.async_generate = _async_mode()
	_target.superchunk_size = _superchunk_mode()
	_target.use_frustum_culling = _culling_mode()
	_target.spawn_debris_on_damage = false  # 测试模式关碎片减少干扰
	_target.use_voxel_health = true
	_target.damage_per_voxel = 1.0
	_target.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	_target.local_collapse = true

	var bounds: AABB = data.get_voxels_aabb()
	_target.global_position = Vector3(-bounds.size.x * voxel_scale * 0.5, 0, -bounds.size.z * voxel_scale * 0.5)


## 优化开关状态（自动测试时被切换）
var _culling_state := true
var _superchunk_state := 0
var _async_state := true

func _culling_mode() -> bool: return _culling_state
func _superchunk_mode() -> int: return _superchunk_state
func _async_mode() -> bool: return _async_state


## 创建大型测试世界：多栋建筑 + 地面
func _create_test_world_data() -> VoxelData:
	var data := VoxelData.new()

	# 材质
	var concrete := VoxelMaterial.new()
	concrete.id = 1; concrete.color = Color(0.45, 0.45, 0.5)
	concrete.rough = 0.9; concrete.hardness = 4.0
	concrete.connection_strength = 12.0; concrete.mass = 1.5
	data.add_material(concrete)

	var metal := VoxelMaterial.new()
	metal.id = 2; metal.color = Color(0.7, 0.7, 0.8)
	metal.metal = 0.8; metal.rough = 0.3
	metal.hardness = 6.0; metal.connection_strength = 20.0; metal.mass = 2.0
	data.add_material(metal)

	var glass := VoxelMaterial.new()
	glass.id = 3; glass.color = Color(0.6, 0.8, 1.0)
	glass.trans = 0.6; glass.rough = 0.1
	glass.hardness = 0.5; glass.connection_strength = 2.0; glass.mass = 0.3
	data.add_material(glass)

	var accent := VoxelMaterial.new()
	accent.id = 4; accent.color = Color(0.9, 0.3, 0.2)
	accent.rough = 0.5; accent.hardness = 1.0
	accent.connection_strength = 8.0; accent.mass = 0.5
	data.add_material(accent)

	# 地面层（整片，含多种材质斑块）
	var gx_max := buildings_x * building_size.x + (buildings_x - 1) * building_spacing
	var gz_max := buildings_z * building_size.z + (buildings_z - 1) * building_spacing
	for gz in range(gz_max):
		for gy in ground_thickness:
			for gx in range(gx_max):
				var mat_id := 1
				if (gx / 50 + gz / 50) % 2 == 0:
					mat_id = 4
				data.set_voxel(Vector3i(gx, gy, gz), mat_id)

	# 各栋建筑
	for bi in buildings_x:
		for bj in buildings_z:
			var base_x := bi * (building_size.x + building_spacing)
			var base_z := bj * (building_size.z + building_spacing)
			var S := building_size
			var t := shell_thickness

			# 地板
			for x in range(S.x):
				for z in range(S.z):
					data.set_voxel(Vector3i(base_x + x, ground_thickness, base_z + z), concrete.id)

			# 天花板
			for x in range(S.x):
				for z in range(S.z):
					data.set_voxel(Vector3i(base_x + x, ground_thickness + S.y - 1, base_z + z), metal.id)

			# 四周墙壁
			for y in range(1, S.y - 1):
				for x in range(S.x):
					for thick in range(t):
						var zp := thick
						var ze := S.z - 1 - thick
						data.set_voxel(Vector3i(base_x + x, ground_thickness + y, base_z + zp), metal.id)
						if ze >= 0 and ze != zp:
							data.set_voxel(Vector3i(base_x + x, ground_thickness + y, base_z + ze), metal.id)
				for z in range(t, S.z - t):
					data.set_voxel(Vector3i(base_x, ground_thickness + y, base_z + z), metal.id)
					data.set_voxel(Vector3i(base_x + S.x - 1, ground_thickness + y, base_z + z), metal.id)

			# 楼层地板
			var floor_height := maxi(1, (S.y - 2) / floor_count)
			for floor in range(1, floor_count):
				var floor_y := ground_thickness + floor * floor_height
				if floor_y >= ground_thickness + S.y - 1:
					break
				for fy in range(floor_y, mini(floor_y + t, ground_thickness + S.y - 1)):
					for x in range(t, S.x - t):
						for z in range(t, S.z - t):
							data.set_voxel(Vector3i(base_x + x, fy, base_z + z), concrete.id)

			# 窗户（前墙和后墙）
			var win_interval := maxi(12, S.x / 6)
			var win_h := 6
			var win_w := 4
			var win_y := ground_thickness + 6
			for wi in range(S.x / win_interval):
				var wx := wi * win_interval + 3
				if wx + win_w >= S.x - 1:
					break
				for y in range(win_y, win_y + win_h):
					for x in range(wx, wx + win_w):
						data.remove_voxel(Vector3i(base_x + x, y, base_z))
						data.remove_voxel(Vector3i(base_x + x, y, base_z + S.z - 1))

			# 门洞
			var door_w := 5
			var door_h := 6
			var door_x := base_x + S.x / 2 - door_w / 2
			for y in range(0, door_h):
				for x in range(door_x, door_x + door_w):
					data.remove_voxel(Vector3i(x, ground_thickness + y, base_z))

	print("[生成] 世界体素数: %d" % data.get_voxel_count())
	return data


func _setup_ground() -> void:
	var gs := maxf(world_size.x, world_size.z) * voxel_scale * 2.0
	var static_body := StaticBody3D.new()
	static_body.name = "Ground"
	var shape := BoxShape3D.new()
	shape.size = Vector3(gs, 0.5, gs)
	var oid := static_body.create_shape_owner(static_body)
	static_body.shape_owner_add_shape(oid, shape)
	static_body.position = Vector3(0, -0.5, 0)
	add_child(static_body)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.current = true
	add_child(_camera)
	_camera.fov = 70
	_camera.far = maxf(world_size.x, world_size.z) * voxel_scale * 3.0
	var center := _get_world_center()
	_camera.global_position = center + Vector3(0, 40, maxf(world_size.x, world_size.z) * voxel_scale * 0.8)
	_camera.look_at(center, Vector3.UP)


func _get_world_center() -> Vector3:
	var world := Vector3(world_size) * voxel_scale
	return Vector3(world.x * 0.5, world.y * 0.3, world.z * 0.5)


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

	_mode_label = Label.new()
	_mode_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_mode_label.position = Vector2(10, 260)
	_mode_label.add_theme_font_size_override("font_size", 13)
	_mode_label.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0))
	_mode_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_mode_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_mode_label)


func _handle_input(delta: float) -> void:
	var key_1 := Input.is_key_pressed(KEY_1)
	var key_2 := Input.is_key_pressed(KEY_2)
	var key_3 := Input.is_key_pressed(KEY_3)
	var key_5 := Input.is_key_pressed(KEY_5)
	var key_6 := Input.is_key_pressed(KEY_6)
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var space := Input.is_key_pressed(KEY_SPACE)

	# 视锥剔除
	if key_1 and not _prev_1:
		_culling_state = not _culling_state
		_rebuild_for_test()
		print("[测试] 视锥剔除: %s" % ("ON" if _culling_state else "OFF"))
	# 超级块
	if key_2 and not _prev_2:
		_superchunk_state = (_superchunk_state + 2) % 6  # 0,2,4
		_rebuild_for_test()
		print("[测试] 超级块大小: %d" % _superchunk_state)
	# 异步
	if key_3 and not _prev_3:
		_async_state = not _async_state
		_rebuild_for_test()
		print("[测试] 异步生成: %s" % ("ON" if _async_state else "OFF"))
	# 环绕
	if key_5 and not _prev_5:
		_orbit_active = not _orbit_active
	# 重置
	if key_6 and not _prev_6:
		_rebuild_for_test()
		print("[测试] 场景重置")

	# 破坏
	if left:
		_damage_at_center()
	if space and not _prev_space:
		_ray_damage()

	_prev_1 = key_1
	_prev_2 = key_2
	_prev_3 = key_3
	_prev_5 = key_5
	_prev_6 = key_6
	_prev_space = space


## 重建目标（优化开关切换后）
func _rebuild_for_test() -> void:
	_build_target()
	_native_available = NativeLoader.is_available()


## 中心球形破坏
func _damage_at_center() -> void:
	if not _target or not is_instance_valid(_target):
		return
	var center := Vector3(world_size.x * 0.5, world_size.y * 0.5, world_size.z * 0.5)
	_target.damage_sphere(center, damage_radius)


## 射线破坏（相机方向）
func _ray_damage() -> void:
	if not _target or not is_instance_valid(_target):
		return
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var local_origin := _target.to_local(origin)
	var local_dir := _target.global_transform.basis.inverse() * dir
	_target.damage_ray(local_origin / voxel_scale, local_dir, 500.0)


# ----------------------------------------------------------------------------
# 自动测试
# ----------------------------------------------------------------------------

## 启动自动测试：遍历所有优化组合测 FPS
func _start_auto_test() -> void:
	_auto_testing = true
	_auto_frame = 0
	_auto_fps_sum = 0.0
	_test_results.clear()
	_auto_combos = []
	for culling in [false, true]:
		for superchunk in [0, 2, 4]:
			for async_mode in [true, false]:
				_auto_combos.append({
					"culling": culling, "superchunk": superchunk, "async": async_mode,
				})
	print("[测试] 自动测试开始，共 %d 组组合" % _auto_combos.size())
	_advance_auto_test()


## 推进到下一组测试
func _advance_auto_test() -> void:
	if _auto_combos.is_empty():
		_finish_auto_test()
		return
	var combo: Dictionary = _auto_combos.pop_front()
	_culling_state = combo["culling"]
	_superchunk_state = combo["superchunk"]
	_async_state = combo["async"]
	_rebuild_for_test()
	_auto_frame = 0
	_auto_fps_sum = 0.0
	print("[测试] 开始组合: culling=%s superchunk=%d async=%s" % [
		combo["culling"], combo["superchunk"], combo["async"]])


## 完成自动测试
func _finish_auto_test() -> void:
	_auto_testing = false
	print("")
	print("========== 自动测试结果 ==========")
	print("原生加速: %s" % ("ON" if _native_available else "OFF (GDScript 回退)"))
	print("-----------------------------------")
	for r in _test_results:
		print("culling=%-5s superchunk=%-3d async=%-5s → %6.1f FPS" % [
			r["culling"], r["superchunk"], r["async"], r["fps"]])
	print("===================================")
	# 找出最优组合
	var best: Dictionary = _test_results[0] if not _test_results.is_empty() else {}
	for r in _test_results:
		if r["fps"] > best["fps"]:
			best = r
	if not best.is_empty():
		print("[测试] 最优组合: culling=%s superchunk=%d async=%s → %.1f FPS" % [
			best["culling"], best["superchunk"], best["async"], best["fps"]])


func _update_hud() -> void:
	if not _hud:
		return
	var t := _target
	var chunk_count := t._superchunk_meshes.size() if t.superchunk_size > 0 else t._chunk_meshes.size()
	var draw_calls := 0
	for c in t.get_children():
		if c is MeshInstance3D and c.mesh != null and c.visible:
			draw_calls += 1
	_hud.text = """===== 体素优化测试场 =====
FPS: %d
原生加速: %s
模式: culling=%s superchunk=%d async=%s
Chunk数: %d  |  draw call: %d
体素: %d
[1]视锥剔除 [2]超级块 [3]异步 [5]环绕 [6]重置
左键破坏 空格射线""" % [
		Engine.get_frames_per_second(),
		"ON" if _native_available else "OFF",
		"ON" if _culling_state else "OFF", _superchunk_state, "ON" if _async_state else "OFF",
		chunk_count, draw_calls,
		t.data.get_voxel_count() if t and t.data else 0,
	]
	_mode_label.text = "自动测试: %s" % ("运行中..." if _auto_testing else "待命")
