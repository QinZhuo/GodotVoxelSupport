@tool
class_name SdfCapsule
extends Sdf

## 胶囊原语：线段 a→b 按 radius 膨胀（球扫掠线段）。

@export var a: Vector3 = Vector3(0.0, -5.0, 0.0)
@export var b: Vector3 = Vector3(0.0, 5.0, 0.0)
@export var radius: float = 3.0
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var pa := p - a
	var ba := b - a
	var denom := ba.dot(ba)
	# 退化（a == b）时按球处理，避免除零
	if denom <= 0.0:
		return Vector2(pa.length() - radius, float(material_id))
	var h := clampf(pa.dot(ba) / denom, 0.0, 1.0)
	return Vector2((pa - ba * h).length() - radius, float(material_id))


func bounds() -> AABB:
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	var r := Vector3(radius, radius, radius)
	return AABB(lo - r, (hi - lo) + r * 2.0)
