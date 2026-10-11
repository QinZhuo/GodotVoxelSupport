@tool
class_name QVoxelGridPick
extends RefCounted
## 网格拾取：一条射线 → 一次落笔的命中信息（**空图上也能落笔**）。
## 【它补的是内核不回答的那半句】`VoxelRay` 只在实心格上给命中；而 QVoxelier 的模型是一块
## 有界立方体，新建出来是空的 —— 空图上射线永远打不到东西，画笔就无处落笔。
## 【只打在"可见背景面"上】落笔面由调用方传入的 `allowed_faces` 限定（= 网格背景面里当前
## 边框可见的那几个面，见 QVoxelGridFloor.visible_faces）—— **有边框的面才作画笔地面**，
## 于是拾取与边框显示永远一致，不会出现"没边框的面却被当成画笔地面"。
## 【落笔格 = 命中面外侧那一格 + 朝内法线 = 盒内相邻格】与体素命中的 `place = hit + normal` 同构。
## 【为什么单独一个类】它是"屏幕 → 落笔"这条链里唯一一段纯数学（无节点、无场景树），
## 单拎出来才能在 TestCase 里把各个背景面的命中边界逐条钉住。

## 底面那层的编号。命中它时 hit.y 恒为此值、normal 恒为 +Y。
const FLOOR_LAYER := -1


## 射线拾取：先走体素 DDA（内核），未命中再看背景面（取最近的那个）。
## allowed_faces：允许作背景面的面下标（0 底 / 1 顶 / 2 -X / 3 +X / 4 -Z / 5 +Z）；为空 = 全部。
static func hit(data: QVoxelSource, origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float = 100.0,
		allowed_faces := PackedInt32Array()) -> Dictionary:
	var info := VoxelRay.cast(data, origin, direction, max_distance)
	if not info.is_empty():
		return info
	return _plane_hit(origin, direction, grid_size, max_distance, allowed_faces)


static func _plane_hit(origin: Vector3, direction: Vector3, grid_size: Vector3i,
		max_distance: float, allowed_faces: PackedInt32Array) -> Dictionary:
	var dir := direction.normalized()
	if dir == Vector3.ZERO or grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return {}
	var faces := allowed_faces
	if faces.is_empty():
		faces = PackedInt32Array([0, 1, 2, 3, 4, 5])
	var best := {}
	var best_t := max_distance
	for i in faces:
		var r := _face_intersect(i, origin, dir, grid_size)
		if r.is_empty():
			continue
		var t: float = r["t"]
		if t <= 0.0 or t > best_t:
			continue
		best_t = t
		best = r
	if best.is_empty():
		return {}
	return {
		VoxelRay.KEY_HIT: best["hit"],
		VoxelRay.KEY_PREV: best["hit"],
		VoxelRay.KEY_NORMAL: best["normal"],
		VoxelRay.KEY_DISTANCE: best["t"],
		VoxelRay.KEY_MATERIAL: 0,
	}


## 某背景面与射线的交点（正 t、且交点落在该面范围内）。返回 {t, hit, normal} 或 {}。
static func _face_intersect(i: int, o: Vector3, d: Vector3, g: Vector3i) -> Dictionary:
	var gx := float(g.x)
	var gy := float(g.y)
	var gz := float(g.z)
	match i:
		0:  # 底 y=0
			if d.y == 0.0:
				return {}
			var t0 := -o.y / d.y
			var p0 := o + d * t0
			if p0.x < 0.0 or p0.x > gx or p0.z < 0.0 or p0.z > gz:
				return {}
			return {"t": t0, "hit": Vector3i(floori(p0.x), FLOOR_LAYER, floori(p0.z)),
					"normal": Vector3i.UP}
		1:  # 顶 y=gy
			if d.y == 0.0:
				return {}
			var t1 := (gy - o.y) / d.y
			var p1 := o + d * t1
			if p1.x < 0.0 or p1.x > gx or p1.z < 0.0 or p1.z > gz:
				return {}
			return {"t": t1, "hit": Vector3i(floori(p1.x), g.y, floori(p1.z)),
					"normal": Vector3i.DOWN}
		2:  # -X x=0
			if d.x == 0.0:
				return {}
			var t2 := -o.x / d.x
			var p2 := o + d * t2
			if p2.y < 0.0 or p2.y > gy or p2.z < 0.0 or p2.z > gz:
				return {}
			return {"t": t2, "hit": Vector3i(FLOOR_LAYER, floori(p2.y), floori(p2.z)),
					"normal": Vector3i.RIGHT}
		3:  # +X x=gx
			if d.x == 0.0:
				return {}
			var t3 := (gx - o.x) / d.x
			var p3 := o + d * t3
			if p3.y < 0.0 or p3.y > gy or p3.z < 0.0 or p3.z > gz:
				return {}
			return {"t": t3, "hit": Vector3i(g.x, floori(p3.y), floori(p3.z)),
					"normal": Vector3i.LEFT}
		4:  # -Z z=0
			if d.z == 0.0:
				return {}
			var t4 := -o.z / d.z
			var p4 := o + d * t4
			if p4.x < 0.0 or p4.x > gx or p4.y < 0.0 or p4.y > gy:
				return {}
			return {"t": t4, "hit": Vector3i(floori(p4.x), floori(p4.y), FLOOR_LAYER),
					"normal": Vector3i.BACK}
		_:  # +Z z=gz
			if d.z == 0.0:
				return {}
			var t5 := (gz - o.z) / d.z
			var p5 := o + d * t5
			if p5.x < 0.0 or p5.x > gx or p5.y < 0.0 or p5.y > gy:
				return {}
			return {"t": t5, "hit": Vector3i(floori(p5.x), floori(p5.y), g.z),
					"normal": Vector3i.FORWARD}
