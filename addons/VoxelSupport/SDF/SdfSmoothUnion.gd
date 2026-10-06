@tool
class_name SdfSmoothUnion
extends Sdf

## 平滑并（iq 的多项式 smin）：把两个实体柔和地连成一体，接缝处像"焊"过一样圆润。
## k 越大融合越圆滑；k → 0 退化为硬并集。做有机体（树枝/岩石堆/黏土）尤其好用。

@export var a: Sdf
@export var b: Sdf
## 融合半径（体素单位）。建议与体素尺度同量级，过大将吞掉细节。
@export var k: float = 2.0


func sample(p: Vector3) -> Vector2:
	var sa := Sdf.sample_field(a, p)
	var sb := Sdf.sample_field(b, p)
	if k <= 0.0:
		return Sdf.pick(sa, sb)
	var h := clampf(0.5 + 0.5 * (sb.x - sa.x) / k, 0.0, 1.0)
	var d := lerpf(sb.x, sa.x, h) - k * h * (1.0 - h)
	# 材质取更近者：融合面附近仍归属原本更近的部件
	return Vector2(d, sa.y if sa.x <= sb.x else sb.y)


func bounds() -> AABB:
	if a == null:
		return b.bounds() if b != null else Sdf.unbounded()
	if b == null:
		return a.bounds()
	# 融合会把表面外扩约 k，包围盒相应放宽
	return Sdf.merged_bounds(a.bounds(), b.bounds()).grow(k * 0.5)
