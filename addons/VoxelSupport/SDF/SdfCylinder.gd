@tool
class_name SdfCylinder
extends Sdf

## 有限圆柱原语，轴沿 +Y，以 center 为中心。

@export var center: Vector3 = Vector3.ZERO
@export var radius: float = 4.0
## 全高（沿 Y 轴长度）。
@export var height: float = 10.0
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var q := p - center
	var d := Vector2(Vector2(q.x, q.z).length() - radius, absf(q.y) - height * 0.5)
	var inside := minf(maxf(d.x, d.y), 0.0)
	return Vector2(inside + d.max(Vector2.ZERO).length(), float(material_id))


func bounds() -> AABB:
	return AABB(
		center - Vector3(radius, height * 0.5, radius),
		Vector3(radius * 2.0, height, radius * 2.0)
	)
