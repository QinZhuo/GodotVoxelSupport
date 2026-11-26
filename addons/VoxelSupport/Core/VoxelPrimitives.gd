@tool
class_name VoxelPrimitives
extends RefCounted
## 体素**几何图元**：纯 static、可无头测试的一组形状/布尔原语（线 / 盒 / 球 / 膨胀 / 连通域…）。

## 3D 直线（Bresenham 误差累积版，26-连通）。
static func line(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var d := b - a
	var n := maxi(maxi(absi(d.x), absi(d.y)), absi(d.z))
	var out: Array[Vector3i] = [a]
	if n == 0:
		return out
	var step := Vector3i(signi(d.x), signi(d.y), signi(d.z))
	var ex := 0
	var ey := 0
	var ez := 0
	var p := a
	for _i in n:
		ex += absi(d.x)
		ey += absi(d.y)
		ez += absi(d.z)
		if ex >= n:
			ex -= n
			p.x += step.x
		if ey >= n:
			ey -= n
			p.y += step.y
		if ez >= n:
			ez -= n
			p.z += step.z
		out.append(p)
	return out

## 实心长方体（两个角点含端点）。
static func box(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	var out: Array[Vector3i] = []
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				out.append(Vector3i(x, y, z))
	return out

## 球偏移缓存（key = 半径）。
static var _ball_offsets := {}

## 半径 r 的欧氏球偏移，含中心偏移。
static func ball_offsets(radius: int) -> Array[Vector3i]:
	var key := maxi(radius, 0)
	if not _ball_offsets.has(key):
		var r2 := key * key
		var made: Array[Vector3i] = []
		for z in range(-key, key + 1):
			for y in range(-key, key + 1):
				for x in range(-key, key + 1):
					if x * x + y * y + z * z <= r2:
						made.append(Vector3i(x, y, z))
		_ball_offsets[key] = made
	return _ball_offsets[key]

## 体素球（笔刷尺寸的载体）。
static func ball(center: Vector3i, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for off in ball_offsets(radius):
		out.append(center + off)
	return out

## 用球把一组格子膨胀（笔刷尺寸 > 1 时让线 / 盒变粗）。
static func dilate(cells: Array[Vector3i], radius: int) -> Array[Vector3i]:
	if radius <= 0 or cells.is_empty():
		return cells
	return _dilate_shifted(cells, float(radius), 0.0)

## 以「直径 size 的球」膨胀 —— 球**内切于 size³ 的立方体**，球心对齐立方体的几何中心。
static func dilate_ball(cells: Array[Vector3i], size: int) -> Array[Vector3i]:
	if size <= 1 or cells.is_empty():
		return cells
	var shift := -0.5 if (size & 1) == 0 else 0.0
	return _dilate_shifted(cells, size * 0.5, shift)

## 距离变换的共用主体：半径是浮点，`shift` 是**球心相对源格的偏移**（0 = 球心在格上）。
static func _dilate_shifted(cells: Array[Vector3i], radius: float, shift: float) -> Array[Vector3i]:
	var grow := int(ceil(radius))
	# 输出范围：源集包围盒各向外扩 radius（球不可能跑出这个盒子）
	var lo := cells[0]
	var hi := cells[0]
	for c in cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	lo -= Vector3i.ONE * grow
	hi += Vector3i.ONE * grow
	var sx := hi.x - lo.x + 1
	var sy := hi.y - lo.y + 1
	var sz := hi.z - lo.z + 1
	# 距离场：源格置 0，其余置"远"，随后三轮扫描就地变成平方距离
	var d := PackedFloat64Array()
	d.resize(sx * sy * sz)
	d.fill(float(_FAR))
	for c in cells:
		var q := c - lo
		d[q.x + sx * (q.y + sy * q.z)] = 0.0
	var span := maxi(maxi(sx, sy), sz)
	var env_pos := PackedInt32Array()
	var env_val := PackedFloat64Array()
	var f_buf := PackedFloat64Array()
	env_pos.resize(span)
	env_val.resize(span + 1)
	f_buf.resize(span)
	_edt_axis(d, sx, sy, sz, 0, shift, env_pos, env_val, f_buf)
	_edt_axis(d, sx, sy, sz, 1, shift, env_pos, env_val, f_buf)
	_edt_axis(d, sx, sy, sz, 2, shift, env_pos, env_val, f_buf)
	var r2 := radius * radius
	var out: Array[Vector3i] = []
	for qz in sz:
		for qy in sy:
			var base := sx * (qy + sy * qz)
			for qx in sx:
				if d[base + qx] <= r2:
					out.append(lo + Vector3i(qx, qy, qz))
	return out

## 用「平面」把一组格子膨胀成边长 `size` 的方片 —— 只在拾取面的两个轴向摊开，
static func dilate_plane(cells: Array[Vector3i], size: int, normal: Vector3i) -> Array[Vector3i]:
	if size <= 1 or cells.is_empty():
		return cells
	var ax := face_axes(normal)
	var neg := size >> 1
	var pos := (size - 1) >> 1
	return _dilate_axis(_dilate_axis(cells, _axis_index(ax[0]), neg, pos),
			_axis_index(ax[1]), neg, pos)

## 轴向向量的轴序号（0/1/2）。
static func _axis_index(v: Vector3i) -> int:
	if v.x != 0:
		return 0
	return 1 if v.y != 0 else 2

## 沿单个轴向做一维膨胀：每个格扩成 `[-neg, +pos]` 的线段（总长 neg + pos + 1 = 笔头边长）。
static func _dilate_axis(cells: Array[Vector3i], axis: int, neg: int, pos: int) -> Array[Vector3i]:
	var lines := {}    # 其余两轴的坐标 → 沿 axis 的坐标表
	for c in cells:
		var key := _rest2(c, axis)
		if not lines.has(key):
			lines[key] = []
		# 必须存 Array 而不是 PackedInt32Array：后者在 GDScript 里是**值类型**，
		(lines[key] as Array).append(_axis_of(c, axis))
	var out: Array[Vector3i] = []
	for key in lines:
		var ts: Array = lines[key]
		ts.sort()
		var lo: int = ts[0] - neg
		var hi: int = ts[0] + pos
		for i in range(1, ts.size()):
			var t: int = ts[i]
			if t - neg > hi + 1:
				_emit_span(out, key, axis, lo, hi)
				lo = t - neg
			hi = maxi(hi, t + pos)
		_emit_span(out, key, axis, lo, hi)
	return out

## 取走 axis 之后剩下的两个坐标（只当分组键用，顺序固定）。
static func _rest2(p: Vector3i, axis: int) -> Vector2i:
	match axis:
		0: return Vector2i(p.y, p.z)
		1: return Vector2i(p.x, p.z)
		_: return Vector2i(p.x, p.y)

## 沿 axis 的那一个坐标。
static func _axis_of(p: Vector3i, axis: int) -> int:
	match axis:
		0: return p.x
		1: return p.y
		_: return p.z

## 把"分组键 + 沿 axis 的区间"还原成坐标并追加。
static func _emit_span(out: Array[Vector3i], key: Vector2i, axis: int, lo: int, hi: int) -> void:
	for t in range(lo, hi + 1):
		match axis:
			0: out.append(Vector3i(t, key.x, key.y))
			1: out.append(Vector3i(key.x, t, key.y))
			_: out.append(Vector3i(key.x, key.y, t))

## 距离场里的"足够远"。
const _FAR := 1 << 28

## 把体积里所有沿 `axis` 的直线依次交给 `_edt_line` 做一维变换。
static func _edt_axis(d: PackedFloat64Array, sx: int, sy: int, sz: int, axis: int, shift: float,
		env_pos: PackedInt32Array, env_val: PackedFloat64Array, f_buf: PackedFloat64Array) -> void:
	match axis:
		0:
			for qz in sz:
				for qy in sy:
					_edt_line(d, sx * (qy + sy * qz), 1, sx, shift, env_pos, env_val, f_buf)
		1:
			for qz in sz:
				for qx in sx:
					_edt_line(d, qx + sx * sy * qz, sx, sy, shift, env_pos, env_val, f_buf)
		_:
			for qy in sy:
				for qx in sx:
					_edt_line(d, qx + sx * qy, sx * sy, sz, shift, env_pos, env_val, f_buf)

## 一维平方距离变换（下包络法，O(n)）：令 d[start + i*stride] ← min over j of ((i-j)² +…
static func _edt_line(d: PackedFloat64Array, start: int, stride: int, n: int, shift: float,
		env_pos: PackedInt32Array, env_val: PackedFloat64Array, f_buf: PackedFloat64Array) -> void:
	if n <= 1:
		return
	# ① 自左向右：把每点看成一条抛物线，求出它们组成的下包络（哪些点上榜、交点在哪）
	var k := 0
	env_pos[0] = 0
	env_val[0] = -INF
	env_val[1] = INF
	for q in range(1, n):
		var fq := d[start + q * stride] + (q + shift) * (q + shift)
		var cross := 0.0
		while true:
			var p := env_pos[k]
			var fp := d[start + p * stride] + (p + shift) * (p + shift)
			cross = (fq - fp) / float(2 * (q - p))
			if cross > env_val[k]:
				break
			k -= 1
		k += 1
		env_pos[k] = q
		env_val[k] = cross
		env_val[k + 1] = INF
	# ② 自左向右：每点取它落在哪一段包络上，即得它的最小平方距离（原值先备份，见函数注释）
	for i in n:
		f_buf[i] = d[start + i * stride]
	k = 0
	for q in n:
		while env_val[k + 1] < float(q):
			k += 1
		var p := env_pos[k]
		var t := float(q - p) - shift
		d[start + q * stride] = t * t + f_buf[p]

## 与给定法线垂直的两个轴向（单位向量，顺序固定）。
static func face_axes(normal: Vector3i) -> Array[Vector3i]:
	if absi(normal.y) == 1:
		return [Vector3i(1, 0, 0), Vector3i(0, 0, 1)]
	if absi(normal.x) == 1:
		return [Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	return [Vector3i(1, 0, 0), Vector3i(0, 1, 0)]

## 平面内的 4 个邻域偏移（给定法线所在平面的正交方向）。
static func plane_offsets4(normal: Vector3i) -> Array[Vector3i]:
	var ax := face_axes(normal)
	return [ax[0], -ax[0], ax[1], -ax[1]]

## 6 邻域偏移（填充用；体素连通性按面相邻算，避免对角"穿缝"漏填）。
static func neighbors6() -> Array[Vector3i]:
	return [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]

## 连通域搜索（广度优先）。
static func region(seeds: Array[Vector3i], accept: Callable, step: Callable) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var seen := {}
	var queue: Array[Vector3i] = []
	for s in seeds:
		if accept.call(s):
			seen[s] = true
			queue.append(s)
			out.append(s)
	var head := 0
	while head < queue.size():
		var p: Vector3i = queue[head]
		head += 1
		for off: Vector3i in step.call(p):
			var q := p + off
			if seen.has(q):
				continue
			if not accept.call(q):
				continue
			seen[q] = true
			queue.append(q)
			out.append(q)
	return out
