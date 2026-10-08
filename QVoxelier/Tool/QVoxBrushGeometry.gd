@tool
class_name QVoxBrushGeometry
extends RefCounted
## 画笔几何：把"手势的两个端点 + 拾取上下文"翻译成一串**要写的体素坐标**。
##
## 【为什么是独立的纯函数类】预览（ghost）与落笔必须画的是同一批格子，否则"看到的不等于
## 画出来的"。让两边调**同一个函数**，一致性就成了构造保证，而不是靠两处逻辑各自对齐。
## 因此这里不碰 QVoxObject、不碰节点、不碰输入：全 static，可无头测试。
##
## 【坐标约定】一律**对象局部体素坐标**（与 QVoxObject.get_voxel / VoxelData.has_voxel 同一套）。
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


## 体素球（笔刷尺寸的载体）。radius = 0 → 只有中心格。
## 判据用"立方到中心 ≤ r²"（欧氏）：比切比雪夫球更像圆笔，又不必开平方。
static func ball(center: Vector3i, radius: int) -> Array[Vector3i]:
	if radius <= 0:
		return [center]
	var r2 := radius * radius
	var out: Array[Vector3i] = []
	for z in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if x * x + y * y + z * z <= r2:
					out.append(center + Vector3i(x, y, z))
	return out


## 用球把一组格子膨胀（笔刷尺寸 > 1 时让线/盒变粗）。radius = 0 原样返回。
## 结果去重且**顺序稳定**（按输入顺序首次出现的位置），便于测试与预览比对。
static func dilate(cells: Array[Vector3i], radius: int) -> Array[Vector3i]:
	if radius <= 0:
		return cells
	var seen := {}
	var out: Array[Vector3i] = []
	for c in cells:
		for v in ball(c, radius):
			if seen.has(v):
				continue
			seen[v] = true
			out.append(v)
	return out


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
