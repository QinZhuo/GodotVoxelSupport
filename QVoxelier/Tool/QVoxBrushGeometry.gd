@tool
class_name QVoxBrushGeometry
extends RefCounted
## 画笔几何：把"手势的两个端点 + 拾取上下文"翻译成一串**要写的体素坐标**。
##
## 【为什么是独立的纯函数类】预览（ghost）与落笔必须画的是同一批格子，否则"看到的不等于
## 画出来的"。让两边调**同一个函数**，一致性就成了构造保证，而不是靠两处逻辑各自对齐。
## 因此这里不碰 QVoxModel、不碰节点、不碰输入：全 static，可无头测试。
##
## 【坐标约定】一律**对象局部体素坐标**（与 QVoxModel.get_voxel / VoxelData.has_voxel 同一套）。
## 越界与否由调用方（QVoxBrushTool）统一裁剪，几何函数只管形状本身。
##
## 【为什么用 Array[Vector3i] 而不是 PackedVector3Array】写入侧（QVoxVoxelEditCommand.set_voxel）
## 是整数坐标；用 Vector3i 一路到底可以避免在边界上来回取整。


## 3D 直线（Bresenham 误差累积版，26-连通）。
##
## 【为什么要"最长轴 + 误差进位"而不是各轴独立插值】独立插值会在端点漂移（浮点累积），
## 而画笔的终点必须**恰好落在用户指到的那一格**；误差累积版 n 步走完后各轴恰好走了 |d| 次，
## 端点由构造保证。26-连通（可对角跨格）对手绘线来说视觉最自然，也让"粗笔"不出现锯齿空洞。
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
##
## 【为什么要缓存】`ball()` 是"中心 + 偏移"的形态，按格盖章的用法会把同一个半径的球反复算：
## 半径 15 的球有一万四千多个偏移，每算一次都要走三重循环 31³。缓存后同一半径只算一次，
## 其余全是查表 —— 球偏移只由半径决定，这笔缓存没有失效条件。
##
## 约定：返回的是**共享只读池**，调用方只许遍历（ball 不改它）。
static var _ball_offsets := {}


## 半径 r 的欧氏球偏移，含中心偏移。radius <= 0 → 只有 Vector3i.ZERO。
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


## 体素球（笔刷尺寸的载体）。radius = 0 → 只有中心格。
## 判据用"立方到中心 ≤ r²"（欧氏）：比切比雪夫球更像圆笔，又不必开平方。
static func ball(center: Vector3i, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for off in ball_offsets(radius):
		out.append(center + off)
	return out


## 用球把一组格子膨胀（笔刷尺寸 > 1 时让线 / 盒变粗）。radius = 0 原样返回。
##
## 【为什么不能"每格盖一个球"】那是 `源格数 × 球偏移数` 次写入。半径 15 的球有一万四千个偏移，
## 盒笔铺满 32³ 就是 4.6 亿次 append —— 实测一次落笔要卡一百秒以上（与"画几下整机卡死"同源：
## 代价随笔刷尺寸乘性爆炸，只是这里卡在**正常用法**上，不是哨兵坐标那种错误路径）。
##
## 【分离式平方距离变换】欧氏距离的平方是可分离的：
##   d²(p) = min over s of ((px-sx)² + (py-sy)² + (pz-sz)²)
## 于是沿三个轴各做一轮一维下包络扫描（Felzenszwalb & Huttenlocher，每轮 O(n)）就得到精确的
## 三维平方距离，最后取 `d² <= r²`。代价只与**输出体积**成正比，与半径、源格数都无关 ——
## 半径 15 也是几毫秒。结果按 z,y,x 扫描顺序产出（确定性，便于测试与预览比对）。
static func dilate(cells: Array[Vector3i], radius: int) -> Array[Vector3i]:
	if radius <= 0 or cells.is_empty():
		return cells
	# 输出范围：源集包围盒各向外扩 radius（球不可能跑出这个盒子）
	var lo := cells[0]
	var hi := cells[0]
	for c in cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	lo -= Vector3i.ONE * radius
	hi += Vector3i.ONE * radius
	var sx := hi.x - lo.x + 1
	var sy := hi.y - lo.y + 1
	var sz := hi.z - lo.z + 1
	# 距离场：源格置 0，其余置"远"，随后三轮扫描就地变成平方距离
	# 用浮点列存是为了让一维扫描里没有 int/float 转换（距离本身都是整数，浮点表示精确）
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
	_edt_axis(d, sx, sy, sz, 0, env_pos, env_val, f_buf)
	_edt_axis(d, sx, sy, sz, 1, env_pos, env_val, f_buf)
	_edt_axis(d, sx, sy, sz, 2, env_pos, env_val, f_buf)
	var r2 := float(radius * radius)
	var out: Array[Vector3i] = []
	for qz in sz:
		for qy in sy:
			var base := sx * (qy + sy * qz)
			for qx in sx:
				if d[base + qx] <= r2:
					out.append(lo + Vector3i(qx, qy, qz))
	return out


## 距离场里的"足够远"。只要大于任何可达的平方距离即可（区域对角线的平方远小于它）。
const _FAR := 1 << 28


## 把体积里所有沿 `axis` 的直线依次交给 `_edt_line` 做一维变换。
## 三个轴各跑一轮；下包络法的可分离性保证三轮叠加后就是精确的三维平方欧氏距离。
static func _edt_axis(d: PackedFloat64Array, sx: int, sy: int, sz: int, axis: int,
		env_pos: PackedInt32Array, env_val: PackedFloat64Array, f_buf: PackedFloat64Array) -> void:
	match axis:
		0:
			for qz in sz:
				for qy in sy:
					_edt_line(d, sx * (qy + sy * qz), 1, sx, env_pos, env_val, f_buf)
		1:
			for qz in sz:
				for qx in sx:
					_edt_line(d, qx + sx * sy * qz, sx, sy, env_pos, env_val, f_buf)
		_:
			for qy in sy:
				for qx in sx:
					_edt_line(d, qx + sx * qy, sx * sy, sz, env_pos, env_val, f_buf)


## 一维平方距离变换（下包络法，O(n)）：令 d[start + i*stride] ← min over j of ((i-j)² + 原值)。
##
## 【为什么需要 f_buf】第 ② 步是**就地**改写 d 的，而 `(i-j)² + f[j]` 里的 f[j] 必须是改写**之前**
## 的原值 —— 否则读到的是已经变小的 D[j]，结果会系统性偏小（笔刷球被算成"漏气的蜂窝"）。
## f_buf 就是这一行的原值副本（复用缓冲，长度 >= n）。env_pos / env_val 同样复用，
## 避免体积里上万行每行都新建数组。
static func _edt_line(d: PackedFloat64Array, start: int, stride: int, n: int,
		env_pos: PackedInt32Array, env_val: PackedFloat64Array, f_buf: PackedFloat64Array) -> void:
	if n <= 1:
		return
	# ① 自左向右：把每点看成一条抛物线，求出它们组成的下包络（哪些点上榜、交点在哪）
	var k := 0
	env_pos[0] = 0
	env_val[0] = -INF
	env_val[1] = INF
	for q in range(1, n):
		var fq := d[start + q * stride] + float(q * q)
		var cross := 0.0
		while true:
			var p := env_pos[k]
			cross = (fq - d[start + p * stride] - float(p * p)) / float(2 * (q - p))
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
		d[start + q * stride] = float((q - p) * (q - p)) + f_buf[p]


## 与给定法线垂直的两个轴向（单位向量，顺序固定）。
## 面笔靠它把"铺满一片面"降成平面上的 4 邻域搜索。
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
##
## accept(p) → 该格是否属于目标区域；step(p) → 从 p 出发还要试哪些邻格。
## 面笔（"铺满一片暴露面"）与填充（"同材质的整块"）共用它，差别只在两个闭包 ——
## 这正是这两个工具在界面上像两件事、在实现上是同一件事的原因。
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
