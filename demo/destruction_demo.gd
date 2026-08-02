extends Node
## 体素破坏系统演示场景 - 小房子测试
## 展示：
##   - 可破坏的体素小房子 (地板+墙壁+天花板) (VoxelDestructible)
##   - 鼠标左键球形破坏 / 右键单体破坏 / 空格射线破坏
##   - 按键切换碎片模式 (物理/视觉 MultiMesh)
##   - HUD 监控统计 (碎片数/移除体素数/破坏耗时)

## 体素缩放 (0.1 = 10cm 每体素，适合细致场景)
@export var voxel_scale: float = 0.1

## 破坏半径 (体素单位，7.0 = 0.7m 世界空间)
@export var damage_radius: float = 7.0

## 可选的数据源：指定任意 VoxelData 作为破坏对象的数据源
## 不设置时使用内置的 10x8x10 立方体演示数据
@export var voxel_data_source: VoxelData:
	set(v):
		voxel_data_source = v
		if is_inside_tree():
			_build_target()

## 可破坏对象
var _target: VoxelDestructible
var _hud: Label
var _mode_label: Label
var _camera: Camera3D


func _ready() -> void:
	_setup_ground()
	_build_target()
	_setup_camera()
	_setup_controls_hud()


## 创建地面（StaticBody3D 平面碰撞），让破坏/崩塌的碎片有落点
func _setup_ground() -> void:
	var ground_size := maxf(HOUSE_LEN, HOUSE_WID) * voxel_scale * 2.5
	var static_body := StaticBody3D.new()
	static_body.name = "Ground"
	var shape := BoxShape3D.new()
	shape.size = Vector3(ground_size, 0.5, ground_size)
	var owner_id := static_body.create_shape_owner(static_body)
	static_body.shape_owner_add_shape(owner_id, shape)
	static_body.position = Vector3(0, -0.5, 0)
	add_child(static_body)

	# 地面可视化（半透明灰）
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(ground_size, 0.5, ground_size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.35, 0.4, 0.8)
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0, -0.5, 0)
	add_child(mesh_inst)

	# 粒子碰撞体：顶面与地面(y=0)对齐，碎片粒子落地后停在地面表面（雪花堆积效果）
	var coll := GPUParticlesCollisionBox3D.new()
	coll.size = Vector3(ground_size, 2, ground_size)
	coll.position = Vector3(0, -1.0, 0)  # 中心 y=-1，顶面 y=0 = 地面
	add_child(coll)


func _process(_delta: float) -> void:
	_handle_input()
	_update_hud()


func _build_target() -> void:
	# 清除旧的破坏对象（避免重复重建时残留）
	if _target and is_instance_valid(_target):
		_target.queue_free()

	_target = VoxelDestructible.new()
	_target.name = "DestructibleVoxels"
	add_child(_target)

	# 确定数据源：优先使用用户指定的 VoxelData，否则用内置立方体
	var data: VoxelData
	if voxel_data_source != null:
		data = voxel_data_source
	else:
		data = _create_demo_cube_data()

	_target.data = data
	_target.voxel_scale = voxel_scale
	_target.spawn_debris_on_damage = true
	_target.max_debris_per_hit = 40
	_target.debris_mode = VoxelDestructible.DebrisMode.DEBRIS_PHYSICS
	# 逐体素健康度 + 悬空崩塌
	_target.use_voxel_health = true
	_target.damage_per_voxel = 1.0
	_target.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	# 局部增量崩塌检测：只检查破坏位置附近，避免每次破坏全量 BFS（中型场景性能关键）
	_target.local_collapse = true
	# 支撑强度系数（扩展预留，当前连通性判定不使用）
	_target.collapse_support_strength = 25.0
	# 连接破坏反馈信号（具体表现由游戏实现，这里仅记录用于 HUD 展示）
	if not _target.voxel_hardened.is_connected(_on_voxel_hardened):
		_target.voxel_hardened.connect(_on_voxel_hardened)
	if not _target.voxels_about_to_collapse.is_connected(_on_voxels_collapse):
		_target.voxels_about_to_collapse.connect(_on_voxels_collapse)
	# 居中摆放（按数据源包围盒）
	var bounds: AABB = data.get_voxels_aabb()
	_target.global_position = Vector3(-bounds.size.x * voxel_scale * 0.5, 0, -bounds.size.z * voxel_scale * 0.5)


## 小房子尺寸 [体素] (外壳尺寸，含墙壁厚度)
const HOUSE_LEN := 42   # x 方向长度 (4.2m)
const HOUSE_HGT := 32   # y 方向高度 (3.2m)
const HOUSE_WID := 42   # z 方向宽度 (4.2m)
const WALL_THK := 1     # 墙壁厚度 (10cm)

## 创建小房子测试数据 (地板 + 墙壁 + 天花板，内部中空)
func _create_demo_cube_data() -> VoxelData:
	var data := VoxelData.new()
	var solid := VoxelMaterial.new()
	solid.id = 1
	solid.color = Color(0.55, 0.45, 0.35)  # 泥土色 - 地板/天花板
	solid.rough = 0.9
	solid.hardness = 3.0  # 较硬，需 3 次伤害
	solid.mass = 1.0
	data.add_material(solid)
	var metal := VoxelMaterial.new()
	metal.id = 2
	metal.color = Color(0.7, 0.7, 0.8)    # 金属灰 - 墙壁
	metal.metal = 0.8
	metal.rough = 0.3
	metal.hardness = 5.0  # 很硬，需 5 次伤害
	metal.mass = 2.0
	data.add_material(metal)
	var accent := VoxelMaterial.new()
	accent.id = 3
	accent.color = Color(0.9, 0.4, 0.3)   # 红色 - 墙角装饰
	accent.rough = 0.6
	accent.hardness = 1.0  # 易碎，一击即碎
	accent.mass = 0.5
	data.add_material(accent)

	# 地板: y=0, 全部 x,z
	for x in range(HOUSE_LEN):
		for z in range(HOUSE_WID):
			data.voxels[Vector3i(x, 0, z)] = solid.id

	# 天花板: y=HOUSE_HGT-1, 全部 x,z
	var ceil_y := HOUSE_HGT - 1
	for x in range(HOUSE_LEN):
		for z in range(HOUSE_WID):
			data.voxels[Vector3i(x, ceil_y, z)] = solid.id

	# 四周墙壁: y=1 到 y=HOUSE_HGT-2
	var wall_top := HOUSE_HGT - 2
	for y in range(1, wall_top + 1):
		# 前墙 (z=0) 和后墙 (z=HOUSE_WID-1)
		for x in range(HOUSE_LEN):
			data.voxels[Vector3i(x, y, 0)] = metal.id
			data.voxels[Vector3i(x, y, HOUSE_WID - 1)] = metal.id
		# 左墙 (x=0) 和右墙 (x=HOUSE_LEN-1)
		for z in range(HOUSE_WID):
			data.voxels[Vector3i(0, y, z)] = metal.id
			data.voxels[Vector3i(HOUSE_LEN - 1, y, z)] = metal.id

	# 墙角装饰 (红色)
	for y in range(1, wall_top + 1):
		data.voxels[Vector3i(0, y, 0)] = accent.id
		data.voxels[Vector3i(0, y, HOUSE_WID - 1)] = accent.id
		data.voxels[Vector3i(HOUSE_LEN - 1, y, 0)] = accent.id
		data.voxels[Vector3i(HOUSE_LEN - 1, y, HOUSE_WID - 1)] = accent.id

	# 门洞: 在前墙 (z=0) 中间位置，宽 4 高 6
	var door_x_start := HOUSE_LEN / 2 - 2
	var door_h := 6
	for y in range(0, door_h):
		for x in range(door_x_start, door_x_start + 4):
			data.voxels.erase(Vector3i(x, y, 0))

	# 窗户: 在右墙 (x=HOUSE_LEN-1) 上开两个小窗
	var win_y_start := 10
	var win_h := 5
	var win_w := 4
	# 窗户1
	for y in range(win_y_start, win_y_start + win_h):
		for z in range(10, 10 + win_w):
			data.voxels.erase(Vector3i(HOUSE_LEN - 1, y, z))
	# 窗户2
	for y in range(win_y_start, win_y_start + win_h):
		for z in range(HOUSE_WID - 10 - win_w, HOUSE_WID - 10):
			data.voxels.erase(Vector3i(HOUSE_LEN - 1, y, z))

	return data


func _setup_camera() -> void:
	# 相机是场景内节点（在 _ready 时已就绪），直接查找，避免动态 add_child 到初始化中的父节点
	_camera = get_node_or_null("Camera3D")
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	# 相机从斜上方俯瞰小房子，看到整个房子 + 门洞 + 窗户
	var house_world := Vector3(HOUSE_LEN, HOUSE_HGT, HOUSE_WID) * voxel_scale
	var center := house_world * 0.5
	_camera.global_position = Vector3(center.x * 0.5, center.y * 1.8, center.z * 2.2)
	_camera.look_at(center)
	_camera.fov = 70


func _setup_controls_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)

	_mode_label = Label.new()
	_mode_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_mode_label.position = Vector2(10, 200)
	_mode_label.add_theme_font_size_override("font_size", 15)
	_mode_label.add_theme_color_override("font_color", Color(0.4, 0.9, 1.0))
	_mode_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_mode_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_mode_label)


## 上一帧鼠标按钮状态 (用于边缘检测，只在按下的瞬间触发破坏)
var _prev_left := false
var _prev_right := false
var _prev_space := false
var _prev_1 := false
var _prev_2 := false
var _prev_r := false
var _prev_b := false
var _prev_s := false
var _prev_l := false
var _saved_data: Variant = null


func _handle_input() -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var space := Input.is_key_pressed(KEY_SPACE)
	var key1 := Input.is_key_pressed(KEY_1)
	var key2 := Input.is_key_pressed(KEY_2)
	var key_r := Input.is_key_pressed(KEY_R)
	var key_b := Input.is_key_pressed(KEY_B)
	var key_s := Input.is_key_pressed(KEY_S)
	var key_l := Input.is_key_pressed(KEY_L)

	# 左键按下瞬间：球形破坏 (按住不重复触发)
	if left and not _prev_left:
		var hit := _mouse_to_voxel()
		if hit != Vector3i.MIN:
			_target.damage_sphere(Vector3(hit) + Vector3(0.5, 0.5, 0.5), damage_radius)
	# 右键按下瞬间：单体素破坏
	if right and not _prev_right:
		var hit := _mouse_to_voxel()
		if hit != Vector3i.MIN:
			_target.damage_voxel(hit)
	# 空格按下瞬间：射线破坏 (朝正前方)
	if space and not _prev_space:
		var forward := -_camera.global_transform.basis.z
		var origin := _camera.global_position
		var local_origin := _target.to_local(origin)
		var local_dir := _target.global_transform.basis.inverse() * forward
		_target.damage_ray(local_origin / voxel_scale, local_dir, 50.0)
	# R 按下瞬间：重置场景
	if key_r and not _prev_r:
		_build_target()
	# 1/2 按下瞬间：切换碎片模式
	if key1 and not _prev_1:
		_target.debris_mode = VoxelDestructible.DebrisMode.DEBRIS_PHYSICS
	if key2 and not _prev_2:
		_target.debris_mode = VoxelDestructible.DebrisMode.DEBRIS_VISUAL
	# B 按下瞬间：破坏前墙底部整层支撑，触发上方结构整体崩塌掉落
	if key_b and not _prev_b:
		_target.damage_box(AABB(Vector3(0, 0, 0), Vector3(HOUSE_LEN, 1.5, 1.5)))
	# S 按下瞬间：存档当前体素数据（含破坏状态）
	if key_s and not _prev_s:
		_saved_data = _target.data.save_data()
	# L 按下瞬间：读档，从存档重建体素数据
	if key_l and not _prev_l and _saved_data != null:
		# 先清空碎片（避免旧碎片残留），再重建体素
		_target.damage_map.clear()
		_target.data.load_data(_saved_data)
		# 读档重建后做一次全量稳定性校验，使场景回到静态稳定（局部检测依赖此前提）
		_target.validate_stability()

	_prev_left = left
	_prev_right = right
	_prev_space = space
	_prev_1 = key1
	_prev_2 = key2
	_prev_r = key_r
	_prev_b = key_b
	_prev_s = key_s
	_prev_l = key_l


## 鼠标指向 → 体素空间坐标 (通过射线与体素数据的 DDA)
func _mouse_to_voxel() -> Vector3i:
	if _camera == null:
		return Vector3i.MIN
	var from := _camera.project_ray_origin(get_viewport().get_mouse_position())
	var dir := _camera.project_ray_normal(get_viewport().get_mouse_position())
	var local_origin := _target.to_local(from)
	var local_dir := _target.global_transform.basis.inverse() * dir
	return _target.raycast_voxel(local_origin / voxel_scale, local_dir, 60.0)


func _update_hud() -> void:
	if _hud == null:
		return
	var mode_name := "物理 (RigidBody)" if _target.debris_mode == VoxelDestructible.DebrisMode.DEBRIS_PHYSICS else "视觉 (MultiMesh)"
	var collapse_method := "局部增量" if _target.local_collapse else "全量"
	_hud.text = """FPS: %d
体素总数: %d
碎片数: %d
上次破坏体素数: %d
上次崩塌体素数: %d
破坏耗时: %.2f ms
Mesh生成: %.2f ms
崩塌检测: %s
材质 硬度/质量: 内%d/%.1f 外%d/%.1f 底%d/%.1f
""" % [Engine.get_frames_per_second(), _target.data.voxels.size(),
		_target.debris_count, _target.last_damage_count,
		_target.last_collapse_count, _target.last_damage_time_ms,
		_target.last_mesh_gen_time_ms, collapse_method, _get_hardness(1), _get_mass(1),
		_get_hardness(2), _get_mass(2), _get_hardness(3), _get_mass(3)]
	_mode_label.text = """碎片模式: %s  (按 1=物理 2=视觉)
[鼠标左键] 球形破坏(伤害1)  [鼠标右键] 单体破坏  [空格] 射线破坏
[B] 破坏前墙底部(触发整面墙崩塌)
[S] 存档当前体素  [L] 读档重建  [R] 重置
小房子: 42x32x42 体素 @ 0.1m  |  门洞+窗户  |  墙壁硬度5/地板硬度3
""" % mode_name


func _get_hardness(mat_id: int) -> int:
	if _target.data and mat_id >= 0 and mat_id < _target.data.materials.size():
		var m = _target.data.materials[mat_id]
		if m:
			return int(m.hardness)
	return 1


func _get_mass(mat_id: int) -> float:
	if _target.data and mat_id >= 0 and mat_id < _target.data.materials.size():
		var m = _target.data.materials[mat_id]
		if m:
			return m.mass
	return 1.0


## 反馈信号：体素受伤但未摧毁（材质硬度未达）
func _on_voxel_hardened(_pos: Vector3i, _remaining: float) -> void:
	# 示例：此处可触发受击特效/音效，具体由游戏实现
	pass


## 反馈信号：悬空体素即将崩塌掉落前
func _on_voxels_collapse(_positions: Array) -> void:
	# 示例：此处可触发崩塌尘埃/震动，具体由游戏实现
	pass
