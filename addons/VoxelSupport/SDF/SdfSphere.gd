@tool
class_name SdfSphere
extends Sdf

## 球体原语：`|p - center| - radius`。

@export var center: Vector3 = Vector3.ZERO
@export var radius: float = 8.0
## 实心部分写入的材质 ID（0 = 空 → 不写入体素）。
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	return Vector2(p.distance_to(center) - radius, float(material_id))


func bounds() -> AABB:
	var r := Vector3(radius, radius, radius)
	return AABB(center - r, r * 2.0)
