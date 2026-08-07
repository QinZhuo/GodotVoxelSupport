@tool
class_name Trail3D extends Node3D

enum Alignment {
	VIEW,
	TRANSFORM_Z,
	STATIC
}

enum TextureMode {
	STRETCH,
	TILE,
	PER_SEGMENT
}

#region Trail Settings

@export var lifetime: float = 1.0:
	set(value):
		lifetime = max(value, 0.01)

@export var min_vertex_distance: float = 0.1:
	set(value):
		min_vertex_distance = max(value, 0.01)

@export var emitting: bool = true

#endregion

#region Shape

@export var width: float = 1.0
@export var width_curve: Curve
@export var alignment: Alignment = Alignment.VIEW

#endregion

#region Appearance

@export var material: Material:
	set(value):
		material = value
		if _mesh_instance:
			_mesh_instance.material_override = value if value else _create_default_material()

@export var cast_shadow: GeometryInstance3D.ShadowCastingSetting = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
	set(value):
		cast_shadow = value
		if _mesh_instance:
			_mesh_instance.cast_shadow = value

@export var color_gradient: Gradient
@export var texture_mode: TextureMode = TextureMode.STRETCH

#endregion

#region Internal

class TrailPoint:
	var position: Vector3
	var age: float
	var basis_z: Vector3

	func _init(p_pos: Vector3, p_age: float, p_basis_z: Vector3) -> void:
		position = p_pos
		age = p_age
		basis_z = p_basis_z

var _points: Array[TrailPoint] = []
var _mesh_instance: MeshInstance3D
var _immediate_mesh: ImmediateMesh
var _last_position: Vector3
var _total_length: float = 0.0
var _prefix_lengths: Array[float] = []

#endregion


func _init() -> void:
	_immediate_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _immediate_mesh
	_mesh_instance.cast_shadow = cast_shadow
	_mesh_instance.material_override = _create_default_material()

	if not width_curve:
		width_curve = _create_default_width_curve()


func _enter_tree() -> void:
	if not _mesh_instance.get_parent():
		add_child(_mesh_instance)
	_update_material()


func _exit_tree() -> void:
	if _mesh_instance and _mesh_instance.get_parent() == self:
		remove_child(_mesh_instance)


func _ready() -> void:
	_last_position = global_position


func _process(delta: float) -> void:
	_update_points(delta)
	_prune_old_points()
	_build_mesh()


#region Point Management

func _update_points(delta: float) -> void:
	for p in _points:
		p.age += delta

	if not emitting:
		return

	var current_pos := global_position
	var dist := current_pos.distance_to(_last_position)

	if dist >= min_vertex_distance or _points.is_empty():
		_points.push_back(TrailPoint.new(current_pos, 0.0, global_basis.z.normalized()))
		_last_position = current_pos


func _prune_old_points() -> void:
	while _points.size() > 0 and _points[0].age >= lifetime:
		_points.pop_front()


func clear() -> void:
	_points.clear()
	_prefix_lengths.clear()
	_total_length = 0.0
	_last_position = global_position

#endregion


#region Mesh Building

func _build_mesh() -> void:
	_immediate_mesh.clear_surfaces()

	var count := _points.size()
	if count == 0:
		return

	var origin := global_position

	if texture_mode == TextureMode.TILE:
		_calc_lengths()

	if count >= 2:
		_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		_build_recorded_segments(count, origin)
		_build_virtual_segment(origin)
		_immediate_mesh.surface_end()
	elif emitting:
		var last_p := _points[0]
		var current_pos := global_position
		if last_p.position.distance_squared_to(current_pos) > 0.00000001:
			_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			_build_virtual_only(origin)
			_immediate_mesh.surface_end()


func _build_recorded_segments(count: int, origin: Vector3) -> void:
	for i in range(count - 1):
		var p0 := _points[i]
		var p1 := _points[i + 1]
		var right := _get_right(p0, p1)
		var uv := _get_uv(i, count)

		_add_quad(
			p0.position - origin, p1.position - origin,
			_get_width(p0.age / lifetime), _get_width(p1.age / lifetime),
			right,
			_get_color(p0.age / lifetime), _get_color(p1.age / lifetime),
			uv.x, uv.y
		)


func _build_virtual_segment(origin: Vector3) -> void:
	if not emitting:
		return

	var last_p := _points[_points.size() - 1]
	var current_pos := global_position
	var dist_sq := last_p.position.distance_squared_to(current_pos)
	if dist_sq < 0.00000001:
		return

	var t_last := last_p.age / lifetime
	var w_last := _get_width(t_last)
	var w_curr := _get_width(0.0)
	var col_last := _get_color(t_last)
	var col_curr := _get_color(0.0)
	var right := _get_right_for_virtual(last_p, current_pos)

	var uv_last: float
	var uv_curr: float
	match texture_mode:
		TextureMode.STRETCH:
			uv_last = 1.0; uv_curr = 1.0
		TextureMode.TILE:
			uv_last = _total_length
			uv_curr = _total_length + sqrt(dist_sq)
		TextureMode.PER_SEGMENT:
			uv_last = 0.0; uv_curr = 1.0

	_add_quad(
		last_p.position - origin, Vector3.ZERO,
		w_last, w_curr, right,
		col_last, col_curr,
		uv_last, uv_curr
	)


func _build_virtual_only(origin: Vector3) -> void:
	var last_p := _points[0]
	var current_pos := global_position
	if last_p.position.distance_squared_to(current_pos) <= 0.00000001:
		return

	var right := _get_right_for_virtual(last_p, current_pos)
	_add_quad(
		last_p.position - origin, Vector3.ZERO,
		_get_width(last_p.age / lifetime), _get_width(0.0),
		right,
		_get_color(last_p.age / lifetime), _get_color(0.0),
		0.0, 0.0
	)


func _add_quad(p0: Vector3, p1: Vector3, w0: float, w1: float, right: Vector3, col0: Color, col1: Color, uv0: float, uv1: float) -> void:
	var h0 := right * w0 * 0.5
	var h1 := right * w1 * 0.5

	_add_vertex(p0 + h0, col0, Vector2(uv0, 0.0))
	_add_vertex(p1 + h1, col1, Vector2(uv1, 0.0))
	_add_vertex(p0 - h0, col0, Vector2(uv0, 1.0))
	_add_vertex(p1 + h1, col1, Vector2(uv1, 0.0))
	_add_vertex(p1 - h1, col1, Vector2(uv1, 1.0))
	_add_vertex(p0 - h0, col0, Vector2(uv0, 1.0))


func _add_vertex(pos: Vector3, col: Color, uv: Vector2) -> void:
	_immediate_mesh.surface_set_color(col)
	_immediate_mesh.surface_set_uv(uv)
	_immediate_mesh.surface_add_vertex(pos)

#endregion


#region Helpers

func _get_right(p0: TrailPoint, p1: TrailPoint) -> Vector3:
	match alignment:
		Alignment.VIEW:
			return _calc_view_right(p0.position, p1.position)
		Alignment.TRANSFORM_Z:
			return _calc_transform_z_right()
		Alignment.STATIC:
			return _calc_static_right(p0)
	return Vector3.RIGHT


func _get_right_for_virtual(last_p: TrailPoint, current_pos: Vector3) -> Vector3:
	match alignment:
		Alignment.VIEW:
			return _calc_view_right(last_p.position, current_pos)
		Alignment.TRANSFORM_Z:
			return _calc_transform_z_right()
		Alignment.STATIC:
			return _calc_static_right(last_p)
	return Vector3.RIGHT


func _get_uv(i: int, count: int) -> Vector2:
	match texture_mode:
		TextureMode.STRETCH:
			var t := float(i) / float(count - 1)
			return Vector2(t, float(i + 1) / float(count - 1))
		TextureMode.TILE:
			return Vector2(_prefix_lengths[i], _prefix_lengths[i + 1])
		TextureMode.PER_SEGMENT:
			return Vector2(0.0, 1.0)
	return Vector2.ZERO


func _calc_view_right(p0: Vector3, p1: Vector3) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return Vector3.RIGHT

	var forward := (p1 - p0).normalized()
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD

	var right := forward.cross(-camera.global_basis.z).normalized()
	if right.length_squared() < 0.0001:
		right = camera.global_basis.x.normalized()
	return right


func _calc_transform_z_right() -> Vector3:
	var forward: Vector3
	if _points.size() >= 2:
		forward = (_points.back().position - _points.front().position).normalized()
	else:
		forward = Vector3.FORWARD

	var right := forward.cross(global_basis.z).normalized()
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	return right


func _calc_static_right(p: TrailPoint) -> Vector3:
	var forward: Vector3
	if _points.size() >= 2:
		forward = (_points.back().position - _points.front().position).normalized()
	else:
		forward = Vector3.FORWARD

	var right := forward.cross(p.basis_z).normalized()
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	return right


func _get_width(t: float) -> float:
	var cv := width_curve.sample(clampf(t, 0.0, 1.0)) if width_curve else 1.0
	return width * cv


func _get_color(t: float) -> Color:
	if color_gradient:
		return color_gradient.sample(clampf(t, 0.0, 1.0))
	return Color.WHITE


func _calc_lengths() -> void:
	_total_length = 0.0
	var n := _points.size()
	_prefix_lengths.resize(n)
	_prefix_lengths[0] = 0.0
	for i in range(n - 1):
		var seg_len := _points[i].position.distance_to(_points[i + 1].position)
		_total_length += seg_len
		_prefix_lengths[i + 1] = _total_length

#endregion


#region Material

func _create_default_width_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0, 1.0))
	curve.add_point(Vector2(1, 1.0))
	return curve


func _create_default_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = StandardMaterial3D.CULL_DISABLED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = StandardMaterial3D.BLEND_MODE_MIX
	mat.vertex_color_use_as_albedo = true
	return mat


func _update_material() -> void:
	if _mesh_instance:
		_mesh_instance.material_override = material if material else _create_default_material()

#endregion
