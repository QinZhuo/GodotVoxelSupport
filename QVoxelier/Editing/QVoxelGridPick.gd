@tool
class_name QVoxelGridPick
extends RefCounted
## 网格拾取：一条射线 → 一次落笔的命中信息（**空图上也能落笔**）。
##
## 【它补的是内核不回答的那半句】`VoxelRay` 只在实心格上给命中；而 QVoxelier 的模型是一块
## 有界立方体，新建出来是空的 —— 空图上射线永远打不到东西，画笔就无处落笔。用户打开软件
## 画不出第一笔，是这类工具最劝退的地方（MagicaVoxel 的语义正是"光标打在网格底面上也能落笔"）。
##
## 【不扩内核契约的补法】网格底面被当作 y = -1 那一层**隐含的实心格**（网格之外的坐标，
## 缺省不存在）：hit = (x, -1, z)、normal = +Y → 落笔格 = hit + normal = (x, 0, z)。
## 于是三条既有行为全部自然成立，一处特判都不需要：
##   · 体素笔 / 盒笔 / 线笔：照常从底层长起来；
##   · 面笔 / 填充：锚点是"实心格"，这一层不是实心格 → 不可用（no-op，符合直觉）；
##   · 擦除：落笔格落在网格外 → 对象侧丢弃（no-op，符合直觉）。
##
## 【为什么单独一个类】它是"屏幕 → 落笔"这条链里唯一一段纯数学（无节点、无场景树），
## 单拎出来才能在 TestCase 里把地板命中的边界（背后、平行、出界、beyond 距离）逐条钉住。
##
## 【依赖方向】只读插件的 VoxelData / VoxelRay 与结果字典的既有键，不认 QVoxelier 的其他类。

## 底面那层的编号。命中它的 hit.y 恒为此值、normal 恒为 +Y。
const FLOOR_LAYER := -1


## 射线拾取：先走体素 DDA（内核），未命中再看是否打在地板上。
## origin / direction 与 VoxelData 同处**体素单位**空间（视口负责把世界坐标除一次 voxel_size）。
## 返回 VoxelRay 同形字典（键见 VoxelRay.KEY_*）；两处都没命中 → 空字典。
static func hit(data: VoxelData, origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float = 100.0) -> Dictionary:
	var info := VoxelRay.cast(data, origin, direction, max_distance)
	if not info.is_empty():
		return info
	return _floor_hit(origin, direction, grid_size, max_distance)


## 地板命中：射线与 y = 0 平面（第 -1 层的顶面）的交点落在网格的 x/z 范围内才算数。
##
## 【法线恒为 +Y，不随视线方向翻转】从地板下方往上看时，几何上的入射面其实是底面（-Y），
## 但落笔格只由 hit + normal 决定，而"从地板下看时也想画在 y = 0 层"才是符合直觉的结果 ——
## 这里取的是**落笔语义**的一致性，不是摄影机所在半球的一致性。
static func _floor_hit(origin: Vector3, direction: Vector3,
		grid_size: Vector3i, max_distance: float) -> Dictionary:
	var dir := direction.normalized()
	if dir == Vector3.ZERO or grid_size.x <= 0 or grid_size.z <= 0:
		return {}
	# 平行于地板（永不相交），或交点在射线反向延长线上（t <= 0），都落不到地板上。
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
