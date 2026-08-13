extends Node

## 流式演示场景（Streaming Demo）——整合【磁盘文件流】与【程序化无限流】两种数据源
##
## 目的：直观展示距离 LOD 卸载（Streaming）与两种数据流，测试内容高度关联：
##   - 文件流模式：手工构建的大地面+散布建筑（VoxelFileStream 磁盘流式，破坏可写盘）
##   - 程序化模式：VoxelProceduralStream 子类（_generate_chunk 噪声地形）+ origin shift 无限世界
## 两种模式共用同一渲染器与 LOD/流式逻辑，相机 WASD 自由移动。
##
## 操作：
##   WASD / 方向键   : 水平移动相机
##   Q / E           : 下降 / 上升
##   空格 / Shift    : 加速 / 减速
##   数字 1-4        : 切换 LOD 层数（1=仅 LOD0，2/3/4=多层）
##   Esc             : 退出
##
## 观察要点：
##   移动相机远离某区域 → 该区域 chunk 网格被卸载（HUD 显示卸载数增加）
##   走回该区域         → 网格自动重载
##   程序化模式远移     → origin shift 触发（HUD 显示基准平移），相机坐标保持小值

## 数据源模式：文件流（手工世界）/ 程序化（无限世界）
enum Mode { FILE_STREAM, PROCEDURAL }

## 体素缩放（0.2 → 世界尺寸较大，便于观察距离效果）
@export var voxel_scale: float = 0.2

## 初始数据源（运行中可按 0 切换）
@export var mode: Mode = Mode.FILE_STREAM

## 世界尺寸 [体素] (x, y, z) —— 超大开放世界，仅文件流模式使用
@export var world_size: Vector3i = Vector3i(1500, 40, 1500)

## 可破坏对象
var _target: VoxelDestructible
var _camera: Camera3D
var _hud: Label
var _mode_label: Label

## 相机移动状态
var _move_forward := 0.0
var _move_right := 0.0
var _move_up := 0.0
var _speed: float = 12.0
# 相机速度（与流式加载吞吐匹配：模型 300 世界，12/秒 ≈ 25 秒穿越，加载能跟上）
const SPEED_BASE := 12.0
const SPEED_FAST := 30.0

## 当前数据源模式
var _current_mode: Mode = Mode.FILE_STREAM


func _ready() -> void:
	_current_mode = mode
	_target = get_node_or_null("DestructibleVoxels") as VoxelDestructible
	if _target == null:
		_target = VoxelDestructible.new()
		_target.name = "DestructibleVoxels"
		add_child(_target)
	_setup_camera()
	_setup_hud()
	_rebuild_world()
	print("[流式Demo] 初始化完成 模式=%s" % _mode_name())


## 按当前模式重建世界（数据源切换时调用：释放旧数据 → 构建新世界 → 重置相机）
func _rebuild_world() -> void:
	if _target.data:
		_target.data.flush()
		_target.data = null
	match _current_mode:
		Mode.FILE_STREAM:
			_build_world_file()
		Mode.PROCEDURAL:
			_build_world_procedural()
	_reset_camera()
	_update_mode_label()


## 渲染器公共配置（两种模式共用同一套 LOD/流式/破坏参数）
func _apply_renderer_config() -> void:
	_target.voxel_scale = voxel_scale
	_target.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
	_target.lod_count = 3
	_target.spawn_debris_on_damage = true
	_target.use_voxel_health = true
	_target.damage_per_voxel = 1.0
	_target.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	_target.local_collapse = true


## 文件流模式：手工构建大地面 + 随机散布建筑（VoxelFileStream 磁盘流式，破坏可写盘）
func _build_world_file() -> void:
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

	# 地面（整片铺满全世界，斑块纹理）——批量填充走原生 set_voxels_bulk
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
	var stream := VoxelFileStream.new()
	stream.directory = "user://voxel_demo_stream"
	# 每次从零开始：清空旧流数据目录（避免上一次的残留 chunk 干扰）
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
	_target.data.stream = stream
	_apply_renderer_config()
	# 世界居中（target 原点 = 世界中心）
	var bounds: AABB = data.get_voxels_aabb()
	_target.global_position = -Vector3(bounds.size.x, 0, bounds.size.z) * voxel_scale * 0.5


## 程序化模式：VoxelProceduralStream 子类（_generate_chunk 噪声地形）+ origin shift 无限世界
func _build_world_procedural() -> void:
	# 程序化流（子类覆写 _generate_chunk 实现生成算法）
	var stream := ProceduralTerrainGenerator.new()
	# 修改持久化：用户破坏的 chunk 写盘，重启后保留（跨进程验证程序化+破坏存档）
	stream.persist_directory = "user://voxel_procedural_stream"
	var data := VoxelData.new()
	data.stream = stream
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = Color(0.35, 0.55, 0.3)
	mat.rough = 0.9
	data.add_material(mat)
	_target.data = data
	_target.global_position = Vector3.ZERO
	_apply_renderer_config()


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 70
	_camera.far = 3000.0


## 模式切换后重置相机初始位置
func _reset_camera() -> void:
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


func _mode_name() -> String:
	return "文件流" if _current_mode == Mode.FILE_STREAM else "程序化"


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
			KEY_0:
				# 数据源切换：文件流 ↔ 程序化（释放旧数据 → 重建世界 → 重置相机）
				if event.pressed:
					_current_mode = Mode.PROCEDURAL if _current_mode == Mode.FILE_STREAM else Mode.FILE_STREAM
					_rebuild_world()
					print("[流式Demo] 切换到数据源: %s" % _mode_name())
			KEY_1:
				if event.pressed:
					_target.lod_count = 1
			KEY_2:
				if event.pressed:
					_target.lod_count = 2
			KEY_3:
				if event.pressed:
					_target.lod_count = 3
			KEY_4:
				if event.pressed:
					_target.lod_count = 4


func _process(delta: float) -> void:
	# 相机移动（保持水平，方便观察地面）
	if _move_forward != 0.0 or _move_right != 0.0:
		var fwd := -_camera.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := _camera.global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		# delta 限幅：fps 低时避免相机一次跳超大距离（流式加载跟不上 → 前方空白）
		var dt := minf(delta, 0.05)
		_camera.global_position += (fwd * _move_forward + right * _move_right) * _speed * dt
	_camera.global_position.y += _move_up * _speed * minf(delta, 0.05)

	_update_hud()


func _update_mode_label() -> void:
	if _mode_label == null:
		return
	var vis_names := ["FULL", "FRUSTUM", "STREAMING"]
	var vis_name: String = vis_names[_target.visibility_mode]
	_mode_label.text = "模式: %s\n可见性: %s" % [_mode_name(), vis_name]


func _update_hud() -> void:
	if _hud == null or _target == null:
		return
	var fps := Engine.get_frames_per_second()
	var chunk_meshes := _target._lod_meshes[0].size() if _target._lod_meshes.size() > 0 else 0
	# 磁盘/修改已持久化但不在内存的 chunk 数（原 _streamed_out_chunks 已合并进统一流式）
	var streamed := _target.data.get_unloaded_chunk_keys().size() if _target.data != null else 0
	var data_loaded := 0
	var data_unloaded := 0
	if _target.data != null:
		data_loaded = _target.data.get_loaded_chunk_keys().size()
		if _target.data.is_streaming():
			data_unloaded = _target.data.get_unloaded_chunk_keys().size()
	var draw := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	# 各 LOD 层实际挂载的块数（null = 空块标记，不计）
	var lod_counts := ""
	for lv in _target._lod_meshes.size():
		var cnt := 0
		for bk in _target._lod_meshes[lv]:
			if _target._lod_meshes[lv][bk] != null:
				cnt += 1
		lod_counts += "L%d:%d  " % [lv, cnt]
	_hud.text = "模式: %s    FPS: %d    DrawCalls: %d\n" % [_mode_name(), fps, draw] + \
			"网格数: %d    流式网格卸载: %d\n" % [chunk_meshes, streamed] + \
			"数据层: 内存%d  磁盘%d\n" % [data_loaded, data_unloaded] + \
			"LOD: %d层  %s\n" % [_target.lod_count, lod_counts] + \
			"相机位置: (%d, %d, %d)\n" % [int(_camera.global_position.x), int(_camera.global_position.y), int(_camera.global_position.z)]
	if _current_mode == Mode.PROCEDURAL:
		_hud.text += "origin shift: %s\n" % _target._origin_chunk
	_hud.text += "\nWASD移动 Q/E升降 空格加速\n0: 切换数据源   数字1-4: 切换LOD层数"
