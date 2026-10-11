@tool
class_name QVoxelierMoveGizmo
extends Node3D
## 移动用的**坐标轴 gizmo**：在选区中心画出 X/Y/Z 三条双向轴（圆柱 + 圆锥箭头，红/绿/蓝）。
## 【交互】按住任意一条轴拖动 = 沿该轴连续移动选区；移动只经它发生，点空白不会误移。
## 【坐标约定】与选区线框 / 预览体素同一套：子节点顶点用**体素单位**、中心烘进子节点位置，
## 节点 scale = voxel_scale。origin 再叠上数据层的 center_offset，保证与体素对齐。

@export var voxel_scale := 0.1:
	set(v):
		voxel_scale = maxf(v, 0.0001)
		scale = Vector3.ONE * voxel_scale

## 体素单位的整体偏移（= QVoxelSource.center_offset）。
@export var origin := Vector3.ZERO

## 轴臂长（体素）。
const ARM := 2.8
const SHAFT_R := 0.075
const HEAD_R := 0.2
const HEAD_H := 0.6
## 旋转环半径与分段（体素单位；绕三轴各一条，拖动即绕该轴旋转节点）。
const RING_R := 3.6
const RING_SEG := 32
const AXIS_DIRS := [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
const AXIS_COLORS := [Color(0.95, 0.33, 0.33), Color(0.40, 0.85, 0.40), Color(0.40, 0.60, 0.98)]

var _center := Vector3.ZERO
## 几何缩放系数（相对 base scale）：视口每帧按相机距离设定，让手柄在屏幕上**大小恒定**。
var _size_factor := 1.0
var _geom: Node3D
## 悬停高亮：-1 = 无。轴与环各自记一个；`_hover_seg` 是环上被指到的那一段（分段高亮）。
var _hover_axis := -1
var _hover_ring := -1
var _hover_seg := -1
## 命中测试时记下的"最近环段"下标（供视口做分段高亮）。
var _last_seg := 0
var _axis_meshes: Array = []
var _ring_segs: Array = []


## 按选区盒（体素坐标）摆到中心。空选区隐藏。
func set_selection(lo: Vector3i, size: Vector3i) -> void:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		visible = false
		return
	visible = true
	var c := Vector3(lo) + Vector3(size) * 0.5 + Vector3(origin)
	# 中心没变就不重建（刷新很频繁，上百个手柄网格每次重建太浪费）。
	if c.is_equal_approx(_center) and _geom != null:
		return
	_center = c
	_rebuild()


## 把 gizmo 摆到**任意体素点**（布局模式：摆在盒中心，拖动即改模型整体变换）。
func set_center(point: Vector3) -> void:
	visible = true
	var c := point + Vector3(origin)
	if c.is_equal_approx(_center) and _geom != null:
		return
	_center = c
	_rebuild()


## gizmo 中心的世界坐标。
func center_global() -> Vector3:
	return global_transform * _center


## 某条轴在世界里的方向向量（长度 = 每体素对应的世界尺寸 × 轴长？这里取每体素世界尺寸）。
func axis_world(axis: int) -> Vector3:
	return global_transform.basis * AXIS_DIRS[axis]


## 点中哪条轴（屏幕空间：光标到该轴投影线段的距离 < threshold 像素）。返回轴下标或 -1。
func axis_hit(screen: Vector2, camera: Camera3D, threshold := 12.0) -> int:
	if not visible or camera == null:
		return -1
	var best := -1
	var best_d := threshold
	for a in 3:
		var dir: Vector3 = AXIS_DIRS[a]
		var reach := ARM * _size_factor
		var p0: Vector3 = global_transform * (_center - dir * reach)
		var p1: Vector3 = global_transform * (_center + dir * reach)
		var d := _seg_dist(screen, camera.unproject_position(p0), camera.unproject_position(p1))
		if d < best_d:
			best_d = d
			best = a
	return best


## 点中哪条**旋转环**（屏幕空间：光标到该环投影折线的距离 < threshold 像素）。返回轴下标或 -1。
## 同时把最近的环段下标记进 `_last_seg`（供分段高亮）。
func ring_hit(screen: Vector2, camera: Camera3D, threshold := 10.0) -> int:
	if not visible or camera == null:
		return -1
	var best := -1
	var best_d := threshold
	var best_seg := 0
	for a in 3:
		var pts := _ring_points(a)
		var n := pts.size()
		for i in n:
			var p0 := camera.unproject_position(global_transform * pts[i])
			var p1 := camera.unproject_position(global_transform * pts[(i + 1) % n])
			var d := _seg_dist(screen, p0, p1)
			if d < best_d:
				best_d = d
				best = a
				best_seg = i
	_last_seg = best_seg
	return best


## 光标绕轴 `a` 的夹角（弧度）：把相机射线投到"过 _center、法线为轴"的平面上再取极角。
func ring_angle(screen: Vector2, camera: Camera3D, a: int) -> float:
	return ring_angle_ref(screen, camera, a, global_transform.basis, center_global())


## 用**固定的参考基/中心**算夹角。布局模式下模型随拖动旋转、gizmo 也跟着转，
## 若每帧用实时 global_transform，参考系会跟着转 → 夹角乱跳（"一拖就飞速变角度"）。
## 故按下时抓一份参考，拖动全程用它。
func ring_angle_ref(screen: Vector2, camera: Camera3D, a: int, ref_basis: Basis, ref_center: Vector3) -> float:
	var axis: Vector3 = AXIS_DIRS[a]
	var ux: Vector3 = AXIS_DIRS[(a + 1) % 3]
	var vy: Vector3 = AXIS_DIRS[(a + 2) % 3]
	var n := (ref_basis * axis).normalized()
	var ro := camera.project_ray_origin(screen)
	var rd := camera.project_ray_normal(screen)
	var den := n.dot(rd)
	if absf(den) < 1e-6:
		return 0.0
	var t := n.dot(ref_center - ro) / den
	var hit := ro + rd * t - ref_center
	var u := (ref_basis * ux).normalized()
	var v := (ref_basis * vy).normalized()
	return atan2(hit.dot(v), hit.dot(u))


## 某条旋转环在体素坐标下的采样点（用于屏幕空间命中测试）。
func _ring_points(a: int) -> Array[Vector3]:
	var u: Vector3 = AXIS_DIRS[(a + 1) % 3]
	var v: Vector3 = AXIS_DIRS[(a + 2) % 3]
	var r := RING_R * _size_factor
	var out: Array[Vector3] = []
	for i in RING_SEG:
		var t := TAU * float(i) / float(RING_SEG)
		out.append(_center + (u * cos(t) + v * sin(t)) * r)
	return out


func _rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_axis_meshes.clear()
	_ring_segs.clear()
	# 几何挂在一个"枢轴"下：枢轴放在盒中心、按 _size_factor 缩放 → 位置正确、大小可独立调。
	_geom = Node3D.new()
	_geom.position = _center
	_geom.scale = Vector3.ONE * _size_factor
	add_child(_geom)
	for a in 3:
		var dir: Vector3 = AXIS_DIRS[a]
		var col: Color = AXIS_COLORS[a]
		var group: Array[MeshInstance3D] = []
		group.append(_make(SHAFT_R, SHAFT_R, ARM * 2.0, _basis_to(dir), Vector3.ZERO, col))
		group.append(_make(0.0, HEAD_R, HEAD_H, _basis_to(dir), dir * (ARM - HEAD_H * 0.5), col))
		group.append(_make(0.0, HEAD_R, HEAD_H, _basis_to(-dir), -dir * (ARM - HEAD_H * 0.5), col))
		_axis_meshes.append(group)
		_ring_segs.append(_ring(a))
	_apply_hover()


## 设定几何缩放（相对 base scale）。视口每帧按相机距离调用 → 手柄屏幕大小恒定。
func set_size_factor(f: float) -> void:
	if is_equal_approx(f, _size_factor):
		return
	_size_factor = f
	if _geom != null:
		_geom.scale = Vector3.ONE * f


## 命中测试时记下的最近环段（供视口做分段高亮）。
func last_ring_seg() -> int:
	return _last_seg


## 悬停反馈：高亮被指到的轴或**环上那一段**（命中与否一眼可见）。由视口在鼠标移动 / 拖动时喂入。
func set_hover(axis: int, ring: int, seg := -1) -> void:
	if axis == _hover_axis and ring == _hover_ring and seg == _hover_seg:
		return
	_hover_axis = axis
	_hover_ring = ring
	_hover_seg = seg
	_apply_hover()


func _apply_hover() -> void:
	for a in 3:
		var base: Color = AXIS_COLORS[a]
		var axis_col := base.lerp(Color.WHITE, 0.7) if a == _hover_axis else base
		if a < _axis_meshes.size():
			for mi in _axis_meshes[a]:
				mi.material_override.albedo_color = axis_col
		if a < _ring_segs.size():
			var segs: Array = _ring_segs[a]
			for i in segs.size():
				var c := base
				if a == _hover_ring:
					# 被指到的那一段最亮，同环其余段略提亮 → 知道选中了哪条环、哪一段。
					c = Color.WHITE if i == _hover_seg else base.lerp(Color.WHITE, 0.3)
				segs[i].material_override.albedo_color = c


## 一条旋转环（**分段**的小方块，法线 = 该轴）—— 分段才能只高亮光标附近那一段。
func _ring(a: int) -> Array[MeshInstance3D]:
	var u: Vector3 = AXIS_DIRS[(a + 1) % 3]
	var v: Vector3 = AXIS_DIRS[(a + 2) % 3]
	var axis: Vector3 = AXIS_DIRS[a]
	var seg_len := TAU * RING_R / float(RING_SEG) * 1.15
	var out: Array[MeshInstance3D] = []
	for i in RING_SEG:
		var t := TAU * float(i) / float(RING_SEG)
		var pos := (u * cos(t) + v * sin(t)) * RING_R
		var tang := (-u * sin(t) + v * cos(t)).normalized()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(seg_len, 0.07, 0.07)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = Transform3D(Basis(tang, axis.cross(tang), axis), pos)
		mi.material_override = _material(AXIS_COLORS[a])
		_geom.add_child(mi)
		out.append(mi)
	return out


## 造一段圆柱 / 圆锥（top/bottom 半径、高），摆到 pos、朝向 basis。返回该 MeshInstance3D。
func _make(top_r: float, bottom_r: float, height: float, basis: Basis, pos: Vector3, col: Color) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = height
	mesh.radial_segments = 12
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = Transform3D(basis, pos)
	mi.material_override = _material(col)
	_geom.add_child(mi)
	return mi


## 把 +Y 转到 dir 的旋转基底（dir 已归一化）。
static func _basis_to(dir: Vector3) -> Basis:
	var d := dir.normalized()
	if d.dot(Vector3.UP) > 0.9999:
		return Basis.IDENTITY
	if d.dot(Vector3.UP) < -0.9999:
		return Basis(Vector3.RIGHT, PI)
	return Basis(Quaternion(Vector3.UP, d))


func _material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	# 不做深度测试：gizmo 压在体素上也看得见（它是操作手柄，不是场景实体）。
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## 点到线段（二维）的距离。
static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _ready() -> void:
	visible = false
