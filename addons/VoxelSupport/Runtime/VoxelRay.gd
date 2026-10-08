@tool
class_name VoxelRay
extends RefCounted
## 体素射线（Amanatides & Woo 的 DDA 走格）。
##
## 【为什么单独一个类，而不是长进 VoxelData】射线查询是"按 chunk 查"之上的**派生查询**：
## 它只需要 has_voxel / get_voxel 两个公开面，不该扩内核契约（VoxelData 的公开 API 由
## test_voxel_kernel_contract 逐条钉死）。放在这里，编辑器的拾取与运行时的破坏
## （VoxelDestructible）共用同一份实现 —— 这段 DDA 过去只存在于 VoxelDestructible 里，
## 编辑器要拾取就得抄第二份，正是 P4「统一接口」要消掉的东西。
##
## 【为什么必须返回入射面法线】画笔的"落笔格" = 命中格 + 法线（往空的那一侧长）；
## 面笔/盒笔/填充也要靠它判断朝向。法线由"进入命中格之前的那一格"得出：DDA 每步只推进
## 一个轴，故 hit - prev 恰好是单轴 ±1 —— 不必另算浮点交点，也不会在斜射时抖成斜向量。

## 命中结果字典的键（未命中返回空字典）：
##   hit      Vector3i  命中的体素（**体素坐标**，与 VoxelData.has_voxel 同一套）
##   prev     Vector3i  进入 hit 之前的那一格（起点就在实心格内时 == hit）
##   normal   Vector3i  入射面法线（朝外，单轴 ±1）；起点在实心格内时为 ZERO（没有入射面）
##   distance float     沿射线走到命中格的距离（体素单位）
##   material int       命中格的材质（get_voxel；取不到时 0）
const KEY_HIT := &"hit"
const KEY_PREV := &"prev"
const KEY_NORMAL := &"normal"
const KEY_DISTANCE := &"distance"
const KEY_MATERIAL := &"material"


## 投射一条射线，返回首个实心格的完整命中信息（未命中 → 空字典）。
##
## 【起点落在实心格内】直接命中该格，normal = ZERO（"没有入射面"比"编一个法线"诚实：
## 调用方要么拒绝对这种命中落笔，要么按自己的规则处理）。
static func cast(data: VoxelData, origin: Vector3, direction: Vector3,
		max_distance: float = 100.0) -> Dictionary:
	if data == null:
		return {}
	var dir := direction.normalized()
	if dir == Vector3.ZERO:
		return {}
	var pos := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	var prev := pos
	var step := Vector3i(
		1 if dir.x > 0.0 else -1,
		1 if dir.y > 0.0 else -1,
		1 if dir.z > 0.0 else -1)
	# t_delta：跨过一整格所需的参数增量；t_max：到下一个格边界的参数值。
	# 某轴分量为 0 时该轴永不推进（INF 让它永远输给另两轴）。
	var t_delta := Vector3(
		absf(1.0 / dir.x) if dir.x != 0.0 else INF,
		absf(1.0 / dir.y) if dir.y != 0.0 else INF,
		absf(1.0 / dir.z) if dir.z != 0.0 else INF)
	var t_max := Vector3(
		(float(pos.x + (1 if step.x > 0 else 0)) - origin.x) / dir.x if dir.x != 0.0 else INF,
		(float(pos.y + (1 if step.y > 0 else 0)) - origin.y) / dir.y if dir.y != 0.0 else INF,
		(float(pos.z + (1 if step.z > 0 else 0)) - origin.z) / dir.z if dir.z != 0.0 else INF)
	var traveled := 0.0
	while traveled < max_distance:
		if data.has_voxel(pos):
			return _result(data, pos, prev, traveled)
		prev = pos
		if t_max.x < t_max.y and t_max.x < t_max.z:
			pos.x += step.x
			traveled = t_max.x
			t_max.x += t_delta.x
		elif t_max.y < t_max.z:
			pos.y += step.y
			traveled = t_max.y
			t_max.y += t_delta.y
		else:
			pos.z += step.z
			traveled = t_max.z
			t_max.z += t_delta.z
	return {}


## 只要命中格坐标（未命中 → Vector3i.MIN）。破坏类接口的既有形状，避免调用方解字典。
static func hit_voxel(data: VoxelData, origin: Vector3, direction: Vector3,
		max_distance: float = 100.0) -> Vector3i:
	var r := cast(data, origin, direction, max_distance)
	return r[KEY_HIT] if r.has(KEY_HIT) else Vector3i.MIN


## 命中格 + 法线 → 落笔格（往法线方向的空格长一格）。
## 没有入射面（起点在实心格内）时返回 Vector3i.MIN —— 这种命中无处落笔。
static func placement_of(hit: Vector3i, normal: Vector3i) -> Vector3i:
	if hit == Vector3i.MIN or normal == Vector3i.ZERO:
		return Vector3i.MIN
	return hit + normal


static func _result(data: VoxelData, hit: Vector3i, prev: Vector3i, distance: float) -> Dictionary:
	var normal := Vector3i.ZERO
	if prev != hit:
		normal = hit - prev
	return {
		KEY_HIT: hit,
		KEY_PREV: prev,
		KEY_NORMAL: normal,
		KEY_DISTANCE: distance,
		KEY_MATERIAL: maxi(data.get_voxel(hit), 0),
	}
