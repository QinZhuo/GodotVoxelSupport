@tool
class_name SdfSubtract
extends Sdf

## 差集：max(a, -b)，从 a 中挖去 b（如从石块中掏洞）。

@export var a: Sdf
@export var b: Sdf


func sample(p: Vector3) -> Vector2:
	var sa := Sdf.sample_field(a, p)
	var sb := Sdf.sample_field(b, p)
	# 材质恒取 a：被挖出的是空，留下的部分仍属 a
	return Vector2(maxf(sa.x, -sb.x), sa.y)


func bounds() -> AABB:
	# 挖洞只会减小体积，a 的包围盒仍是安全上界
	return a.bounds() if a != null else Sdf.unbounded()
