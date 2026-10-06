@tool
class_name SdfUnion
extends Sdf

## 并集：min(a, b)，两实体合并为一个。

@export var a: Sdf
@export var b: Sdf


func sample(p: Vector3) -> Vector2:
	return Sdf.pick(Sdf.sample_field(a, p), Sdf.sample_field(b, p))


func bounds() -> AABB:
	if a == null:
		return b.bounds() if b != null else Sdf.unbounded()
	if b == null:
		return a.bounds()
	return Sdf.merged_bounds(a.bounds(), b.bounds())
