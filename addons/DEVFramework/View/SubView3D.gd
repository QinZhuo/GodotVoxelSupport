@tool
class_name SubView3D extends MeshInstance3D

@export var viewport: SubViewport:
	set(value):
		viewport = value
		if viewport and Engine.is_editor_hint():
			var view := get_surface_override_material(0).emission_texture as ViewportTexture
			if not view.viewport_path:
				view.viewport_path = viewport.get_path()

@export var area: Area3D

var is_mouse_inside: bool = false
var last_event_pos2D := Vector2()
var last_event_time := -1.0

func _init() -> void:
	if not mesh:
		mesh = QuadMesh.new()
	if not get_surface_override_material(0):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.BLACK
		mat.albedo_texture = ViewportTexture.new()
		mat.emission_texture = mat.albedo_texture
		mat.emission_intensity = 0.5
		mat.emission_enabled = true
		mat.resource_local_to_scene = true
		set_surface_override_material(0, mat)

func _ready() -> void:
	if area:
		area.mouse_entered.connect(_on_mouse_entered)
		area.mouse_exited.connect(_on_mouse_exited)
		area.input_event.connect(_on_input_event)

func _on_mouse_entered() -> void:
	is_mouse_inside = true
	if viewport:
		viewport.notification(NOTIFICATION_VP_MOUSE_ENTER)

func _on_mouse_exited() -> void:
	if viewport:
		viewport.notification(NOTIFICATION_VP_MOUSE_EXIT)
	is_mouse_inside = false

func _unhandled_input(input_event: InputEvent) -> void:
	if not viewport:
		return

	for mouse_event in [InputEventMouseButton, InputEventMouseMotion, InputEventScreenDrag, InputEventScreenTouch]:
		if is_instance_of(input_event, mouse_event):
			return
	viewport.push_input(input_event)

func _on_input_event(_camera_ref: Camera3D, input_event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not viewport:
		return

	var mesh_size: Vector2 = mesh.size
	var event_pos3D := event_position
	var now := Time.get_ticks_msec() / 1000.0

	event_pos3D = area.global_transform.affine_inverse() * event_pos3D

	var event_pos2D := Vector2()

	if is_mouse_inside:
		event_pos2D = Vector2(event_pos3D.x, -event_pos3D.y)

		event_pos2D.x = event_pos2D.x / mesh_size.x
		event_pos2D.y = event_pos2D.y / mesh_size.y
		event_pos2D.x += 0.5
		event_pos2D.y += 0.5

		event_pos2D.x *= viewport.size.x
		event_pos2D.y *= viewport.size.y
	elif last_event_pos2D != Vector2():
		event_pos2D = last_event_pos2D

	input_event.position = event_pos2D
	if input_event is InputEventMouse:
		input_event.global_position = event_pos2D

	if input_event is InputEventMouseMotion or input_event is InputEventScreenDrag:
		if last_event_pos2D == Vector2():
			input_event.relative = Vector2(0, 0)
		else:
			input_event.relative = event_pos2D - last_event_pos2D
			input_event.velocity = input_event.relative / (now - last_event_time)

	last_event_pos2D = event_pos2D
	last_event_time = now

	viewport.push_input(input_event)
