@tool
class_name SdfPlane
extends Sdf

## 半空间平面：法线 normal 指向"外部"，实心在 -normal 一侧。
## offset = 平面到原点的有符号距离（沿 normal 度量）。
##
## 本身无界，通常与交 / 差配合使用——例如用它与盒求交切出平整底面，
## 或从球中减去它切掉下半部分。

@export var normal: Vector3 = Vector3.UP:
	set(v):
		normal = v
		_n = _safe_normal(v)
@export var offset: float = 0.0
@export var material_id: int = 1

# 归一化法线缓存：采样是逐体素热路径，不在每次 sample 里重复归一化。
var _n := Vector3.UP


func sample(p: Vector3) -> Vector2:
	return Vector2(p.dot(_n) - offset, float(material_id))


func bounds() -> AABB:
	return Sdf.unbounded()


## 零向量法线退化为 UP（避免归一化得 NaN 污染整片距离场）。
static func _safe_normal(v: Vector3) -> Vector3:
	return Vector3.UP if v.length_squared() < 1e-12 else v.normalized()
