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
const AXIS_DIRS := [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
const AXIS_COLORS := [Color(0.95, 0.33, 0.33), Color(0.40, 0.85, 0.40), Color(0.40, 0.60, 0.98)]

var _center := Vector3.ZERO


## 按选区盒（体素坐标）摆到中心。空选区隐藏。
func set_selection(lo: Vector3i, size: Vector3i) -> void:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		visible = false
		return
	visible = true
	_center = Vector3(lo) + Vector3(size) * 0.5 + Vector3(origin)
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
		var p0: Vector3 = global_transform * (_center - dir * ARM)
		var p1: Vector3 = global_transform * (_center + dir * ARM)
		var d := _seg_dist(screen, camera.unproject_position(p0), camera.unproject_position(p1))
		if d < best_d:
			best_d = d
			best = a
	return best


func _rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	for a in 3:
		var dir: Vector3 = AXIS_DIRS[a]
		var col: Color = AXIS_COLORS[a]
		_make(SHAFT_R, SHAFT_R, ARM * 2.0, _basis_to(dir), _center, col)
		_make(0.0, HEAD_R, HEAD_H, _basis_to(dir), _center + dir * (ARM - HEAD_H * 0.5), col)
		_make(0.0, HEAD_R, HEAD_H, _basis_to(-dir), _center - dir * (ARM - HEAD_H * 0.5), col)


## 造一段圆柱 / 圆锥（top/bottom 半径、高），摆到 pos、朝向 basis。
func _make(top_r: float, bottom_r: float, height: float, basis: Basis, pos: Vector3, col: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = height
	mesh.radial_segments = 12
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = Transform3D(basis, pos)
	mi.material_override = _material(col)
	add_child(mi)


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
