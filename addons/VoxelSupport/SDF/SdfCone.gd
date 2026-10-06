@tool
class_name SdfCone
extends Sdf

## 圆锥 / 圆台原语（iq 的 capped cone），轴沿 +Y，以 center 为中心。
## bottom_radius / top_radius 为底 / 顶半径：top_radius = 0 即尖锥，
## 两者相等即退化为圆柱。

@export var center: Vector3 = Vector3.ZERO
@export var bottom_radius: float = 4.0
@export var top_radius: float = 0.0
## 全高（沿 Y 轴长度）。
@export var height: float = 8.0
@export var material_id: int = 1


func sample(p: Vector3) -> Vector2:
	var q := p - center
	var h := height * 0.5
	var r1 := maxf(bottom_radius, 0.0)
	var r2 := maxf(top_radius, 0.0)
	var qx := Vector2(q.x, q.z).length()
	# k1 = 顶面圆心，k2 = 底 → 顶的侧面方向；ca / cb 分别是最靠近"端盖"与"侧面"的偏差
	var k1 := Vector2(r2, h)
	var k2 := Vector2(r2 - r1, 2.0 * h)
	var ca := Vector2(qx - minf(qx, r1 if q.y < 0.0 else r2), absf(q.y) - h)
	var t := clampf((k1 - Vector2(qx, q.y)).dot(k2) / maxf(k2.dot(k2), 1e-12), 0.0, 1.0)
	var cb := Vector2(qx, q.y) - k1 + k2 * t
	# 在体内部时取负号
	var sign_inside := -1.0 if (cb.x < 0.0 and ca.y < 0.0) else 1.0
	return Vector2(sign_inside * sqrt(minf(ca.dot(ca), cb.dot(cb))), float(material_id))


func bounds() -> AABB:
	var r := maxf(maxf(bottom_radius, top_radius), 0.0)
	return AABB(
		center - Vector3(r, height * 0.5, r),
		Vector3(r * 2.0, height, r * 2.0)
	)
