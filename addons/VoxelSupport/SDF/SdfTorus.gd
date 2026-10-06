@tool
class_name SdfTorus
extends Sdf

## 圆环原语，轴沿 +Y，以 center 为中心。
## major_radius = 大半径（环心到管心），minor_radius = 小半径（管的半径）。

@export var center: Vector3 = Vector3.ZERO
@export var major_radius: float = 6.0
@export var minor_radius: float = 1.5
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var q := p - center
	var d := Vector2(Vector2(q.x, q.z).length() - major_radius, q.y)
	return Vector2(d.length() - minor_radius, float(material_id))


func bounds() -> AABB:
	var outer := major_radius + minor_radius
	return AABB(
		center - Vector3(outer, minor_radius, outer),
		Vector3(outer * 2.0, minor_radius * 2.0, outer * 2.0)
	)
