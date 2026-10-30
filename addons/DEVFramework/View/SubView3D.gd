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
		PointerTool.bind(area, _on_mouse_entered, _on_mouse_exited)
		area.input_event.connect(_on_input_event)
		area.input_ray_pickable = is_visible_in_tree()

func _notification(what: int) -> void:
	# 隐藏的面板不参与鼠标拾取：否则看不见的面板会抢走点击，把事件按自己的 UV 转发给视口
	if what == NOTIFICATION_VISIBILITY_CHANGED and area and is_inside_tree():
		area.input_ray_pickable = is_visible_in_tree()
		if not is_visible_in_tree():
			_on_mouse_exited()

func _on_mouse_entered() -> void:
	is_mouse_inside = true
	PointerTool.enter(area)
	if viewport:
		viewport.notification(NOTIFICATION_VP_MOUSE_ENTER)

func _on_mouse_exited() -> void:
	PointerTool.exit(area)
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

## 子视口内的 2D 矩形 → 主屏幕矩形（贴图面四角投影后的包围盒）。
## 与 `_on_input_event` 的"屏幕命中点 → 视口坐标"互逆，供挖孔/定位等需要反查屏幕位置的地方使用。
func viewport_rect_to_screen(rect: Rect2) -> Rect2:
	if viewport == null or mesh == null or viewport.size.x <= 0 or viewport.size.y <= 0:
		return Rect2()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var vp_size := Vector2(viewport.size)
	var aabb := mesh.get_aabb()
	var plane_size := Vector2(aabb.size.x, aabb.size.y)
	var center := aabb.get_center()
	var result := Rect2()
	for i in 4:
		# 四角: (0,0) (1,0) (0,1) (1,1)
		var uv := rect.position + rect.size * Vector2(i & 1, i >> 1)
		# 视口坐标 → 贴图面局部坐标(纹理顶部对应本地 +Y)
		var local := Vector2(
			center.x + (uv.x / vp_size.x - 0.5) * plane_size.x,
			center.y + (0.5 - uv.y / vp_size.y) * plane_size.y)
		var p := cam.unproject_position(global_transform * Vector3(local.x, local.y, center.z))
		result = result.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	return result


## 碰撞盒有厚度，命中点落在靠相机的那一面：斜视时直接换算会偏，先沿视线投回贴图平面
func _on_plane(camera: Camera3D, hit: Vector3) -> Vector3:
	if camera == null:
		return hit
	var gt := area.global_transform
	var p = Plane(gt.basis.z.normalized(), gt.origin).intersects_ray(hit, hit - camera.global_position)
	return p if p != null else hit


func _on_input_event(camera: Camera3D, input_event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not viewport:
		return

	var mesh_size: Vector2 = mesh.size
	var local_pos := area.to_local(_on_plane(camera, event_position))
	var now := Time.get_ticks_msec() / 1000.0

	# 事件能到这里就说明鼠标正压在面板上，直接按命中点换算。
	# 不能用 mouse_entered 状态做门禁，否则首次点击会落到 (0,0) 或上一次的旧坐标。
	var event_pos2D := Vector2(
		(local_pos.x / mesh_size.x + 0.5) * viewport.size.x,
		(0.5 - local_pos.y / mesh_size.y) * viewport.size.y)

	# 复制一份再改坐标：这个事件对象是同一帧内所有 Area3D 共用的，
	# 就地改写会把子视口坐标泄漏给其它面板和主视口的 UI
	var ev := input_event.duplicate() as InputEvent
	ev.position = event_pos2D
	if ev is InputEventMouse:
		ev.global_position = event_pos2D

	if ev is InputEventMouseMotion or ev is InputEventScreenDrag:
		if last_event_pos2D == Vector2():
			ev.relative = Vector2(0, 0)
		else:
			ev.relative = event_pos2D - last_event_pos2D
			ev.velocity = ev.relative / (now - last_event_time)

	last_event_pos2D = event_pos2D
	last_event_time = now

	viewport.push_input(ev)
