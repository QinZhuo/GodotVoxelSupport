@tool
class_name QVoxelGridPick
extends RefCounted
## 网格拾取：一条射线 → 一次落笔的命中信息（**空图上也能落笔**）。
## 【它补的是内核不回答的那半句】`VoxelRay` 只在实心格上给命中；而 QVoxelier 的模型是一块
## 有界立方体，新建出来是空的 —— 空图上射线永远打不到东西，画笔就无处落笔。
## 【画在**远端面**，不是近端面】空网格时，把射线**射出网格盒的那一面**当作落笔面，落笔格取它的
## 里侧一格。于是近端始终敞开，模型从远侧往里长 —— 否则画在近端面上等于给盒子糊了一层壳，
## 里面永远改不到。俯视时远端就是底面 y=0，与"在地板上起笔"完全一致。
## 【不扩内核契约的补法】这一层不是实心格，是网格盒的隐含表面。落笔格 = 远端面外侧那一格 +
## 朝内法线 = 盒内相邻格，与体素命中的 `place = hit + normal` 完全同构。
## 【为什么单独一个类】它是"屏幕 → 落笔"这条链里唯一一段纯数学（无节点、无场景树），
## 单拎出来才能在 TestCase 里把地板命中与侧墙命中的边界逐条钉住。

## 底面那层的编号。命中它时 hit.y 恒为此值、normal 恒为 +Y。
const FLOOR_LAYER := -1


## 射线拾取：先走体素 DDA（内核），未命中再看网格盒的**远端面**（侧墙 / 底面）。
## origin / direction 与 QVoxelSource 同处**体素单位**空间（视口负责把世界坐标除一次 voxel_size）。
## 返回 VoxelRay 同形字典（键见 VoxelRay.KEY_*）；都没命中 → 空字典。
static func hit(data: QVoxelSource, origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float = 100.0) -> Dictionary:
	var info := VoxelRay.cast(data, origin, direction, max_distance)
	if not info.is_empty():
		return info
	return _far_face_hit(origin, direction, grid_size, max_distance)


## 远端面命中：取射线**射出**盒的那一面作为落笔面，落笔格取它的里侧一格。
## 顶面（从下往上看时的远端面）不作为落笔面 —— 体素建模里没有"天花板"。
static func _far_face_hit(origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float) -> Dictionary:
	var dir := direction.normalized()
	if dir == Vector3.ZERO or grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return {}
	# slab：逐轴算进入 / 离开参数；全局**离开**参数最小的那一轴即射出面（远端面）。
	var t_entry := -INF
	var t_exit := INF
	var axis := -1
	var exit_at_zero := true
	for a in 3:
		var o := origin[a]
		var d := dir[a]
		var h := float(grid_size[a])
		if is_zero_approx(d):
			if o < 0.0 or o > h:
				return {}
			continue
		var t1 := (0.0 - o) / d
		var t2 := (h - o) / d
		var t_lo := minf(t1, t2)
		var t_hi := maxf(t1, t2)
		if t_lo > t_entry:
			t_entry = t_lo
		if t_hi < t_exit:
			t_exit = t_hi
			axis = a
			# 离开面落在 0 平面（t1 更大）还是 h 平面。
			exit_at_zero = t1 >= t2
		if t_entry > t_exit:
			return {}
	# 起点在盒内（t_entry < 0）也允许：远端面依然可算，画在远侧。
	if axis < 0 or t_exit < 0.0 or t_exit > max_distance:
		return _floor_hit(origin, direction, grid_size, max_distance)
	# 远端是顶面（从下往上看）：不画天花板。
	if axis == 1 and not exit_at_zero:
		return _floor_hit(origin, direction, grid_size, max_distance)
	var p := origin + dir * t_exit
	var cell := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var normal := Vector3i.ZERO
	match axis:
		0:
			cell.x = FLOOR_LAYER if exit_at_zero else grid_size.x
			normal = Vector3i(1, 0, 0) if exit_at_zero else Vector3i(-1, 0, 0)
		1:
			cell.y = FLOOR_LAYER if exit_at_zero else grid_size.y
			normal = Vector3i(0, 1, 0) if exit_at_zero else Vector3i(0, -1, 0)
		2:
			cell.z = FLOOR_LAYER if exit_at_zero else grid_size.z
			normal = Vector3i(0, 0, 1) if exit_at_zero else Vector3i(0, 0, -1)
	return {
		VoxelRay.KEY_HIT: cell,
		VoxelRay.KEY_PREV: cell,
		VoxelRay.KEY_NORMAL: normal,
		VoxelRay.KEY_DISTANCE: t_exit,
		VoxelRay.KEY_MATERIAL: 0,
	}


## 地板命中：射线与 y = 0 平面（第 -1 层的顶面）的交点落在网格的 x/z 范围内才算数。
## 主要作为 `_far_face_hit` 的兜底（例如射线与 x/z 平面平行、落在盒外）。
## 【法线恒为 +Y】落笔格只由 hit + normal 决定，"从地板下看时也想画在 y = 0 层"才符合直觉。
static func _floor_hit(origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float) -> Dictionary:
	var dir := direction.normalized()
	if dir == Vector3.ZERO or grid_size.x <= 0 or grid_size.z <= 0:
		return {}
	if dir.y == 0.0:
		return {}
	var t := -origin.y / dir.y
	if t <= 0.0 or t > max_distance:
		return {}
	var p := origin + dir * t
	var x := floori(p.x)
	var z := floori(p.z)
	if x < 0 or z < 0 or x >= grid_size.x or z >= grid_size.z:
		return {}
	var cell := Vector3i(x, FLOOR_LAYER, z)
	return {
		VoxelRay.KEY_HIT: cell,
		VoxelRay.KEY_PREV: cell,
		VoxelRay.KEY_NORMAL: Vector3i.UP,
		VoxelRay.KEY_DISTANCE: t,
		VoxelRay.KEY_MATERIAL: 0,
	}
