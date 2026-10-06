@tool
class_name SdfIntersect
extends Sdf

## 交集：max(a, b)，只保留两者重叠的部分（如球切掉方块得到圆角）。

@export var a: Sdf
@export var b: Sdf


func sample(p: Vector3) -> Vector2:
	# 约束更紧（距离更大）者决定表面，材质随之传递
	return Sdf.pick_far(Sdf.sample_field(a, p), Sdf.sample_field(b, p))


func bounds() -> AABB:
	if a == null:
		return b.bounds() if b != null else Sdf.unbounded()
	if b == null:
		return a.bounds()
	return Sdf.intersected_bounds(a.bounds(), b.bounds())
