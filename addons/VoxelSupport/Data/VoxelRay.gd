@tool
class_name VoxelRay
extends RefCounted
## 体素射线（Amanatides & Woo 的 DDA 走格）。

## 命中结果字典的键（未命中返回空字典）：
const KEY_HIT := &"hit"
const KEY_PREV := &"prev"
const KEY_NORMAL := &"normal"
const KEY_DISTANCE := &"distance"
const KEY_MATERIAL := &"material"

## 投射一条射线，返回首个实心格的完整命中信息（未命中 → 空字典）。
static func cast(data: QVoxelSource, origin: Vector3, direction: Vector3,
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

## 只要命中格坐标（未命中 → Vector3i.MIN）。
static func hit_voxel(data: QVoxelSource, origin: Vector3, direction: Vector3,
		max_distance: float = 100.0) -> Vector3i:
	var r := cast(data, origin, direction, max_distance)
	return r[KEY_HIT] if r.has(KEY_HIT) else Vector3i.MIN

## 命中格 + 法线 → 落笔格（往法线方向的空格长一格）。
static func placement_of(hit: Vector3i, normal: Vector3i) -> Vector3i:
	if hit == Vector3i.MIN or normal == Vector3i.ZERO:
		return Vector3i.MIN
	return hit + normal

static func _result(data: QVoxelSource, hit: Vector3i, prev: Vector3i, distance: float) -> Dictionary:
	var normal := Vector3i.ZERO
	if prev != hit:
		normal = prev - hit
	return {
		KEY_HIT: hit,
		KEY_PREV: prev,
		KEY_NORMAL: normal,
		KEY_DISTANCE: distance,
		KEY_MATERIAL: maxi(data.get_voxel(hit), 0),
	}
