class_name QVoxelTransform
extends RefCounted

## 节点摆放（`transform` 键）的 JSON 编解码 —— **全项目唯一实现**，放在**基础层**（Format/）。

## `transform` 键 → Transform3D。
static func transform_from_json(d: Variant) -> Transform3D:
	if not (d is Dictionary):
		return Transform3D.IDENTITY
	var xf: Dictionary = d
	var basis := Basis.IDENTITY
	var r: Variant = xf.get("r")
	if r is Array and (r as Array).size() >= 4:
		var a: Array = r
		var q := Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		if q.length_squared() > 0.0:
			basis = Basis(q.normalized())
	var s: Variant = xf.get("s")
	if s is Array and (s as Array).size() >= 3:
		var sa: Array = s
		basis = basis * Basis.from_scale(Vector3(float(sa[0]), float(sa[1]), float(sa[2])))
	return Transform3D(basis, _json_vec3(xf.get("t")))

## Transform3D → `transform` 键。
static func transform_to_json(xf: Transform3D) -> Dictionary:
	var d := {}
	if not xf.origin.is_zero_approx():
		d["t"] = [xf.origin.x, xf.origin.y, xf.origin.z]
	var q := xf.basis.get_rotation_quaternion()
	if not q.is_equal_approx(Quaternion.IDENTITY):
		d["r"] = [q.x, q.y, q.z, q.w]
	var sc := xf.basis.get_scale()
	if not sc.is_equal_approx(Vector3.ONE):
		d["s"] = [sc.x, sc.y, sc.z]
	return d

static func _json_vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
