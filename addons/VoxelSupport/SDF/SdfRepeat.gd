@tool
class_name SdfRepeat
extends Sdf

## 域重复：把子字段沿各轴以 spacing 为周期**无限重复**（栅栏 / 链条 / 柱林 等）。
## 做法是标准域操作——把采样点折回单个周期内再交给子字段，因此与子字段形状无关。
## 【无界】重复是无限的，故 bounds() 恒为无界；实际生成多少份完全由采样范围决定，
## 也就是由 QVoxelSource.grid_size 裁剪——与框架"真正裁剪交给 grid_size"的约定一致。

@export var child: Sdf
## 各轴重复周期（体素单位）。某轴 <= 0 表示该轴不重复（退化为原样采样）。
@export var spacing: Vector3 = Vector3(8.0, 8.0, 8.0)


func sample(p: Vector3) -> Vector2:
	if child == null:
		return Sdf.far()
	return child.sample(_fold(p))


func bounds() -> AABB:
	return Sdf.unbounded()


## 把 p 各轴折回到 [-spacing/2, spacing/2] 的单个周期内。
func _fold(p: Vector3) -> Vector3:
	return Vector3(
		p.x if spacing.x <= 0.0 else p.x - spacing.x * roundf(p.x / spacing.x),
		p.y if spacing.y <= 0.0 else p.y - spacing.y * roundf(p.y / spacing.y),
		p.z if spacing.z <= 0.0 else p.z - spacing.z * roundf(p.z / spacing.z)
	)
