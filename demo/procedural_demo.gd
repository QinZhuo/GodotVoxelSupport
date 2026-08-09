extends Node3D

## 程序化无限世界 demo：VoxelProceduralStream + 程序化生成器 + origin shift。
## WASD/空格/Shift 移动相机（上帝视角），鼠标滚轮改变高度。

@export var move_speed: float = 30.0
@export var view_distance := 50.0
@export var unload_distance := 100.0
@export var lod0_distance := 30.0
@export var voxel_scale := 0.2

var _renderer: VoxelRenderer
var _camera: Camera3D
var _move := Vector3.ZERO

func _ready() -> void:
	_camera = $Camera3D as Camera3D
	_renderer = $DestructibleVoxels as VoxelRenderer
	# 程序化流（子类覆写 _generate_chunk 实现生成算法）
	var stream := ProceduralTerrainGenerator.new()
	# 数据
	var data := VoxelData.new()
	data.stream = stream
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = Color(0.35, 0.55, 0.3)
	data.add_material(mat)
	_renderer.data = data
	_renderer.voxel_scale = voxel_scale
	_renderer.mesh_mode = VoxelRenderer.MeshMode.CHUNK_ASYNC
	_renderer.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
	_renderer.view_distance = view_distance
	_renderer.unload_distance = unload_distance
	_renderer.lod0_distance = lod0_distance
	_camera.global_position = Vector3(0, 25, 0)
	_renderer.global_position = Vector3.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed:
			match k.keycode:
				KEY_W: _move.z = -1.0
				KEY_S: _move.z = 1.0
				KEY_A: _move.x = -1.0
				KEY_D: _move.x = 1.0
				KEY_SPACE: _move.y = 1.0
				KEY_SHIFT: _move.y = -1.0
		else:
			match k.keycode:
				KEY_W, KEY_S: _move.z = 0.0
				KEY_A, KEY_D: _move.x = 0.0
				KEY_SPACE, KEY_SHIFT: _move.y = 0.0
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.global_position.y += 5.0
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.global_position.y -= 5.0

func _process(delta: float) -> void:
	if _move != Vector3.ZERO:
		_camera.global_position += _move * move_speed * delta
	_camera.look_at(_camera.global_position + Vector3(0, -1.0, -1.0), Vector3.UP)
