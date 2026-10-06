@tool
class_name SdfBox
extends Sdf

## 轴对齐盒原语（iq 的切比雪夫外推，内部距离为负、外部为欧氏距离）。

@export var center: Vector3 = Vector3.ZERO
## 全尺寸（非半尺寸）：各轴长度。
@export var size: Vector3 = Vector3(8.0, 8.0, 8.0)
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var q := (p - center).abs() - size * 0.5
	var outside := q.max(Vector3.ZERO).length()
	var inside := minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
	return Vector2(outside + inside, float(material_id))


func bounds() -> AABB:
	return AABB(center - size * 0.5, size)
