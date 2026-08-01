extends Node
## 体素破坏系统演示场景
## 展示：
##   - 可破坏的体素立方体 (VoxelDestructible)
##   - 鼠标左键球形破坏 / 右键单体破坏 / 空格射线破坏
##   - 按键切换碎片模式 (物理/视觉 MultiMesh)
##   - HUD 监控统计 (碎片数/移除体素数/破坏耗时)

## 体素缩放
@export var voxel_scale: float = 0.4

## 破坏半径 (体素单位)
@export var damage_radius: float = 1.8

## 可破坏对象
var _target: VoxelDestructible
var _hud: Label
var _mode_label: Label
var _camera: Camera3D


func _ready() -> void:
	_build_target()
	_setup_camera()
	_setup_controls_hud()


func _process(delta: float) -> void:
	_handle_input()
	_update_hud()


func _build_target() -> void:
	_target = VoxelDestructible.new()
	_target.name = "DestructibleVoxels"
	add_child(_target)

	# 创建体素数据：一个 10x8x10 的立方体 (含材质)
	var data := VoxelDataResource.new()
	var solid := VoxelMaterial.new()
	solid.id = 1
	solid.color = Color(0.55, 0.45, 0.35)
	solid.rough = 0.9
	data.add_material(solid)
	var metal := VoxelMaterial.new()
	metal.id = 2
	metal.color = Color(0.7, 0.7, 0.8)
	metal.metal = 0.8
	metal.rough = 0.3
	data.add_material(metal)
	var accent := VoxelMaterial.new()
	accent.id = 3
	accent.color = Color(0.9, 0.4, 0.3)
	accent.rough = 0.6
	data.add_material(accent)

	# 填充立方体体素
	for x in range(10):
		for y in range(8):
			for z in range(10):
				var mat_id: int = solid.id
				# 外层用金属色，内部用泥土色，边缘用红色
				if x == 0 or x == 9 or z == 0 or z == 9:
					mat_id = metal.id
				elif y == 0:
					mat_id = accent.id
				data.voxels[Vector3i(x, y, z)] = mat_id

	_target.data = data
	_target.voxel_scale = voxel_scale
	_target.spawn_debris_on_damage = true
	_target.max_debris_per_hit = 40
	_target.debris_mode = VoxelDestructible.DebrisMode.DEBRIS_PHYSICS
	# 居中摆放
	_target.global_position = Vector3(-(10 * voxel_scale) * 0.5, 0, 0)


func _setup_camera() -> void:
	# 相机是场景内节点（在 _ready 时已就绪），直接查找，避免动态 add_child 到初始化中的父节点
	_camera = get_node_or_null("Camera3D")
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.global_position = Vector3(0, 3, 12)
	_camera.look_at(Vector3(0, 1.5, 0))
	_camera.fov = 65


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


func _handle_input() -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var space := Input.is_key_pressed(KEY_SPACE)
	var key1 := Input.is_key_pressed(KEY_1)
	var key2 := Input.is_key_pressed(KEY_2)
	var key_r := Input.is_key_pressed(KEY_R)

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

	_prev_left = left
	_prev_right = right
	_prev_space = space
	_prev_1 = key1
	_prev_2 = key2
	_prev_r = key_r


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
	_hud.text = """FPS: %d
体素总数: %d
碎片数: %d
上次破坏体素数: %d
破坏耗时: %.2f ms
Mesh生成: %.2f ms
""" % [Engine.get_frames_per_second(), _target.data.voxels.size(),
		_target.debris_count, _target.last_damage_count,
		_target.last_damage_time_ms, _target.last_mesh_gen_time_ms]
	_mode_label.text = """碎片模式: %s  (按 1=物理 2=视觉)
[鼠标左键] 球形破坏
[鼠标右键] 单体破坏
[空格] 射线破坏
[R] 重置
""" % mode_name
