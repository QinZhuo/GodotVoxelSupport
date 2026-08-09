extends Node
## 流式加载演示场景（Streaming Demo）
##
## 目的：直观展示距离 LOD 卸载（Streaming）——相机远离的区域网格自动卸载释放显存，
## 靠近后自动重载。本场景为"大地面 + 散布建筑"的开放世界，相机 WASD 自由移动。
##
## 操作：
##   WASD / 方向键   : 水平移动相机
##   Q / E           : 下降 / 上升
##   空格 / Shift    : 加速 / 减速
##   1               : 切换 流式加载 开/关（对比显存与 FPS）
##   2               : 切换 视锥剔除 开/关
##   3               : 循环 超级块大小 0/4（对比 draw call）
##   Esc             : 退出
##
## 观察要点：
##   移动相机远离某区域 → 该区域 chunk 网格被卸载（HUD 显示卸载数增加）
##   走回该区域         → 网格自动重载
##   对比开关流式前后的 FPS 与内存占用

## 体素缩放（0.2 → 世界尺寸较大，便于观察距离效果）
@export var voxel_scale: float = 0.2

## 世界尺寸 [体素] (x, y, z) —— 超大开放世界 300×300 单位，验证流式+LOD 大场景表现
@export var world_size: Vector3i = Vector3i(1500, 40, 1500)

## 流式加载距离（世界单位）：相机进入此距离的 chunk 确保加载
## 超大场景：view=60（LOD0 视距 36），unload=100，LOD1 覆盖 [36,100]
@export var view_distance: float = 60
## 流式卸载距离：超出此距离的 chunk 网格+数据自动卸载（写盘释放内存）
@export var unload_distance: float = 100

## 可破坏对象
var _target: VoxelDestructible
var _camera: Camera3D
var _hud: Label
var _mode_label: Label

## 相机移动状态
var _move_forward := 0.0
var _move_right := 0.0
var _move_up := 0.0
var _speed: float = 20.0
const SPEED_BASE := 20.0
const SPEED_FAST := 60.0

## 流式/可见性开关状态
var _stream_state := true

## 上一帧按键状态（边沿触发）
var _prev_1 := false
var _prev_2 := false


func _ready() -> void:
	_build_world()
	_setup_camera()
	_setup_hud()
	_update_mode_label()
	print("[流式Demo] 初始化完成 world=%dx%dx%d 体素=%d" % [
		world_size.x, world_size.y, world_size.z, _target.data.get_voxel_count()])


## 构建世界：大面积地面 + 随机散布的建筑群（模拟开放世界）
func _build_world() -> void:
	_target = get_node_or_null("DestructibleVoxels") as VoxelDestructible
	if _target == null:
		_target = VoxelDestructible.new()
		_target.name = "DestructibleVoxels"
		add_child(_target)

	var data := VoxelData.new()

	# 材质
	var ground_mat := VoxelMaterial.new()
	ground_mat.id = 1; ground_mat.color = Color(0.45, 0.5, 0.4)
	ground_mat.rough = 0.95; ground_mat.hardness = 6.0
	ground_mat.connection_strength = 20.0; ground_mat.mass = 2.0
	data.add_material(ground_mat)

	var accent := VoxelMaterial.new()
	accent.id = 2; accent.color = Color(0.8, 0.6, 0.2)
	accent.rough = 0.7; accent.hardness = 4.0
	accent.connection_strength = 15.0; accent.mass = 1.5
	data.add_material(accent)

	var roof_mat := VoxelMaterial.new()
	roof_mat.id = 3; roof_mat.color = Color(0.75, 0.25, 0.2)
	roof_mat.rough = 0.6; roof_mat.hardness = 5.0
	roof_mat.connection_strength = 18.0; roof_mat.mass = 1.8
	data.add_material(roof_mat)

	# 地面（整片铺满全世界，斑块纹理）——用 set_voxels 批量填充，避免逐体素 set_voxel 的哈希开销。
	# 超大场景分批构建（每 128 行一批），避免一次性构造上千万 Vector3i 数组撑爆内存。
	# 走原生 set_voxels_bulk 批量路径，构建期主线程开销远小于逐体素 GDScript 写入。
	var S := world_size
	var ground_h := 8
	const GROUND_BATCH := 128
	for gz0 in range(0, S.z, GROUND_BATCH):
		var ground_positions: Array[Vector3i] = []
		for gz in range(gz0, mini(gz0 + GROUND_BATCH, S.z)):
			for gy in range(ground_h):
				for gx in range(S.x):
					ground_positions.append(Vector3i(gx, gy, gz))
		data.set_voxels(ground_positions, 1)

	# 随机散布建筑（120 栋，各 20×40×20 体素）——批量 set_voxels 加速构建
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var b_positions: Array[Vector3i] = []
	for i in 120:
		var bx := 30 + rng.randi_range(0, S.x - 60)
		var bz := 30 + rng.randi_range(0, S.z - 60)
		var bh := 25 + rng.randi_range(0, 30)
		var bw := 15 + rng.randi_range(0, 10)
		var bd := 15 + rng.randi_range(0, 10)
		# 空心盒子建筑
		for x in range(bw):
			for z in range(bd):
				b_positions.append(Vector3i(bx + x, ground_h, bz + z))          # 地板
				b_positions.append(Vector3i(bx + x, ground_h + bh - 1, bz + z))  # 天花板
		for y in range(1, bh - 1):
			for xi in range(bw):
				b_positions.append(Vector3i(bx + xi, ground_h + y, bz))
				b_positions.append(Vector3i(bx + xi, ground_h + y, bz + bd - 1))
			for z in range(bd):
				b_positions.append(Vector3i(bx, ground_h + y, bz + z))
				b_positions.append(Vector3i(bx + bw - 1, ground_h + y, bz + z))
	if not b_positions.is_empty():
		data.set_voxels(b_positions, roof_mat.id)

	_target.data = data
	# 数据层磁盘流式：chunk 数据按需写盘/读盘（目录 user://voxel_demo_stream）。
	# 启用后 STREAMING 模式不仅卸载网格，还按距离把 chunk 数据写回磁盘并释放内存，
	# 相机靠近时再从磁盘读回。内存占用随可见区域而非整个世界增长。
	var stream := VoxelFileStream.new()
	stream.directory = "user://voxel_demo_stream"
	# 演示场景每次运行从零开始：清空旧流数据目录（避免上一次的残留 chunk 干扰）
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(stream.directory))
	var cleanup := DirAccess.open(stream.directory)
	if cleanup:
		cleanup.list_dir_begin()
		var fn := cleanup.get_next()
		while fn != "":
			if not cleanup.current_is_dir():
				cleanup.remove(fn)
			fn = cleanup.get_next()
		cleanup.list_dir_end()
	_target.data_stream = stream
	_target.voxel_scale = voxel_scale
	# 网格模式：逐 chunk + 后台线程并行（推荐默认）
	_target.mesh_mode = VoxelRenderer.MeshMode.CHUNK_ASYNC
	# 可见性：流式模式（距离加载/卸载）
	_target.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
	_target.view_distance = view_distance
	_target.unload_distance = unload_distance
	# LOD：距离内全精度，之外用 LOD1 低分辨率大块（每格 2³ 体素，顶点约 1/8）
	_target.lod0_distance = view_distance * 0.6
	_target.spawn_debris_on_damage = true
	_target.use_voxel_health = true
	_target.damage_per_voxel = 1.0
	_target.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	_target.local_collapse = true

	# 世界居中（target 原点 = 世界中心）
	var bounds: AABB = data.get_voxels_aabb()
	_target.global_position = -Vector3(bounds.size.x, 0, bounds.size.z) * voxel_scale * 0.5


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 70
	_camera.far = 3000.0
	# 初始位置：世界中心地面之上，俯视周围
	_camera.global_position = Vector3(0, 30, 0)
	_camera.look_at(Vector3(0, 5, 40), Vector3.UP)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	layer.add_child(_hud)

	_mode_label = Label.new()
	_mode_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_mode_label.position = Vector2(-300, 10)
	_mode_label.size = Vector2(290, 0)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mode_label.add_theme_font_size_override("font_size", 13)
	layer.add_child(_mode_label)


func _unhandled_input(event: InputEvent) -> void:
	# WASD / 方向键 移动
	if event is InputEventKey:
		match event.keycode:
			KEY_W, KEY_UP:
				_move_forward = 1.0 if event.pressed else 0.0
			KEY_S, KEY_DOWN:
				_move_forward = -1.0 if event.pressed else 0.0
			KEY_A, KEY_LEFT:
				_move_right = -1.0 if event.pressed else 0.0
			KEY_D, KEY_RIGHT:
				_move_right = 1.0 if event.pressed else 0.0
			KEY_Q:
				_move_up = -1.0 if event.pressed else 0.0
			KEY_E:
				_move_up = 1.0 if event.pressed else 0.0
			KEY_SPACE:
				_speed = SPEED_FAST if event.pressed else SPEED_BASE
			KEY_SHIFT:
				_speed = SPEED_BASE * 0.3 if event.pressed else SPEED_BASE
			KEY_1:
				if event.pressed and not _prev_1:
					_toggle_streaming()
				_prev_1 = event.pressed
			KEY_2:
				if event.pressed and not _prev_2:
					_toggle_streaming()
				_prev_2 = event.pressed


func _process(delta: float) -> void:
	# 相机移动（保持水平，方便观察地面）
	if _move_forward != 0.0 or _move_right != 0.0:
		var fwd := -_camera.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := _camera.global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		_camera.global_position += (fwd * _move_forward + right * _move_right) * _speed * delta
	_camera.global_position.y += _move_up * _speed * delta

	_update_hud()


func _toggle_streaming() -> void:
	# 流式开/关：STREAMING ↔ FRUSTUM（关闭流式退回视锥剔除）
	_stream_state = not _stream_state
	_target.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING if _stream_state \
			else VoxelRenderer.VisibilityMode.FRUSTUM
	_update_mode_label()
	print("[流式Demo] 流式加载: %s" % ("ON" if _stream_state else "OFF"))


func _update_mode_label() -> void:
	if _mode_label == null:
		return
	var vis_names := ["FULL", "FRUSTUM", "STREAMING"]
	var vis_name: String = vis_names[_target.visibility_mode]
	_mode_label.text = "可见性: %s" % vis_name


func _update_hud() -> void:
	if _hud == null or _target == null:
		return
	var fps := Engine.get_frames_per_second()
	var chunk_meshes := _target._lod0_meshes.size()
	var streamed := _target._streamed_out_chunks.size()
	var data_loaded := 0
	var data_unloaded := 0
	if _target.data != null:
		data_loaded = _target.data.get_loaded_chunk_keys().size()
		if _target.data.is_streaming():
			data_unloaded = _target.data.get_unloaded_chunk_keys().size()
	var draw := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	_hud.text = "FPS: %d    DrawCalls: %d\n" % [fps, draw] + \
			"网格数: %d    流式网格卸载: %d\n" % [chunk_meshes, streamed] + \
			"数据层: 内存%d  磁盘%d\n" % [data_loaded, data_unloaded] + \
			"相机位置: (%d, %d, %d)" % [int(_camera.global_position.x), int(_camera.global_position.y), int(_camera.global_position.z)] + \
			"\n\nWASD移动  Q/E升降  空格加速\n1流式开关  2视锥开关  3超级块"
