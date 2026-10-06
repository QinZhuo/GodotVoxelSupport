@tool
class_name SdfTransform
extends Sdf

## 变换：对子字段施加一个 Transform3D（平移 / 旋转 / 缩放），是摆放部件的通用手段。
## 采用标准做法——把父空间采样点**反变换**回子空间再采样，因此平移/旋转不会破坏距离场；
## 均匀缩放时按缩放因子还原距离（见 _ensure_scale）。
## 非均匀缩放会让距离场轻微畸变（符号仍正确），个位数缩放下肉眼难辨，可放心用于椭球等造型。

@export var child: Sdf:
	set(v):
		child = v
		_dirty = true

## 子空间 → 父空间 的变换（在 inspector 里直接调位置/旋转/缩放）。
@export var transform: Transform3D = Transform3D.IDENTITY:
	set(v):
		transform = v
		_dirty = true

# 逆变换与缩放因子缓存：采样是逐体素热路径，不能在每次 sample 里重算矩阵逆。
var _dirty := true
var _inverse := Transform3D.IDENTITY
var _scale := 1.0


func sample(p: Vector3) -> Vector2:
	if child == null:
		return Sdf.far()
	var r := child.sample(_ensure_inverse() * p)
	var s := _ensure_scale()
	if s != 0.0 and s != 1.0:
		r.x *= s
	return r


func bounds() -> AABB:
	if child == null:
		return Sdf.unbounded()
	var b := child.bounds()
	if Sdf.is_unbounded(b):
		return b
	return _transform_aabb(b)


func _ensure_inverse() -> Transform3D:
	if _dirty:
		_refresh_cache()
	return _inverse


func _ensure_scale() -> float:
	if _dirty:
		_refresh_cache()
	return _scale


func _refresh_cache() -> void:
	_inverse = transform.affine_inverse()
	# 基矢长度的均值（均匀缩放时三轴相等）；0 缩放视为退化（不还原距离）
	var s := transform.basis.get_scale()
	_scale = (s.x + s.y + s.z) / 3.0
	_dirty = false


## 变换包围盒：变换 8 个角点后重新求 min/max（旋转后 AABB 需外扩，Godot 无内置 AABB 变换）。
func _transform_aabb(b: AABB) -> AABB:
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for i in 8:
		var corner := b.position + Vector3(
			b.size.x * float(i & 1),
			b.size.y * float((i >> 1) & 1),
			b.size.z * float((i >> 2) & 1)
		)
		var t := transform * corner
		lo = lo.min(t)
		hi = hi.max(t)
	return AABB(lo, hi - lo)
