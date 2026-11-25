class_name QVoxelTransform
extends RefCounted

## 节点摆放（`transform` 键）的 JSON 编解码 —— **全项目唯一实现**，放在**基础层**（Format/）。
## 【为什么在基础层】`.qvx` 的 NODE 摆放解析是**格式**的事，不是模型的事。下沉到这里后，
## 导入器（`QVoxelAsset`）解析 NODE 时不必依赖世界 / 场景图 / 求值层（`Model/`）。
## 布局：`t` 平移 [x,y,z]（体素单位）、`r` 旋转四元数 [x,y,z,w]、`s` 缩放 [x,y,z]（三者皆可缺省）。

## `transform` 键 → Transform3D。缺失 / 非法一律回落到恒等。
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


## Transform3D → `transform` 键。**恒等返回空字典**（P2：缺省才是常态），于是调用方
## "非空才写键"即可，不必自己判恒等。
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
