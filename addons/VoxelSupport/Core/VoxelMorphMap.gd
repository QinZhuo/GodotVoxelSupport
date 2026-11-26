@tool
class_name VoxelMorphMap
extends RefCounted

## A→B 变形的**逐点配对表（可选工具）**：A 的第 i 个点 -> B 的第 `b_index[i]` 个点。

## 配对模式。
enum Mode {
	MORTON,        ## Morton 排序配对（默认，质量/速度平衡最好）
	SORTED_AXIS,   ## 单轴排序配对（最快，但交叉长线多）
	INDEX,         ## 按索引硬配（仅当两份点云本身已对齐时用）
}

## 点数上限：key 用 21 位给 index，其余给 Morton 码。
const MAX_MORTON_POINTS := (1 << 21) - 1

## 起点点数（= b_index 长度）。
var count: int = 0

## 配对表：A 的第 i 个点对应 B 的第 b_index[i] 个点。
var b_index: PackedInt32Array = PackedInt32Array()

## 构建时用的模式。
var mode: int = Mode.MORTON

## 配对质量统计（给美术/调试看：这次变形会不会乱）。
var avg_distance: float = 0.0
var max_distance: float = 0.0

## 为 a -> b 建立配对。
static func build(a: PackedFloat32Array, b: PackedFloat32Array,
		stride: int = 12, mode: int = Mode.MORTON) -> VoxelMorphMap:
	var out := VoxelMorphMap.new()
	var n := a.size() / stride
	var m := b.size() / stride
	if n <= 0 or m <= 0:
		return out
	out.mode = mode

	var effective := mode
	if effective == Mode.MORTON and (n > MAX_MORTON_POINTS or m > MAX_MORTON_POINTS):
		push_warning("[VoxelMorphMap] 点数超过 %d，Morton 退化为 SORTED_AXIS" % MAX_MORTON_POINTS)
		effective = Mode.SORTED_AXIS

	var map := PackedInt32Array()
	map.resize(n)
	match effective:
		Mode.INDEX:
			for i in n:
				map[i] = mini(i, m - 1)
		Mode.SORTED_AXIS:
			map = _pair_by_axis(a, b, n, m, stride)
		_:
			map = _pair_by_morton(a, b, n, m, stride)

	out.b_index = map
	out.count = n
	out._compute_stats(a, b, stride)
	return out

func _compute_stats(a: PackedFloat32Array, b: PackedFloat32Array, stride: int) -> void:
	if b_index.is_empty():
		return
	var total := 0.0
	var worst := 0.0
	var n := mini(b_index.size(), a.size() / stride)
	for i in n:
		var bi := b_index[i]
		if bi < 0 or bi >= b.size() / stride:
			continue
		var ab := i * stride
		var bb := bi * stride
		var pa := Vector3(a[ab], a[ab + 1], a[ab + 2])
		var pb := Vector3(b[bb], b[bb + 1], b[bb + 2])
		var d := pa.distance_to(pb)
		total += d
		worst = maxf(worst, d)
	avg_distance = total / float(n)
	max_distance = worst

# ── Morton 配对 ─────────────────────────────────────────────────────────…

## 预计算的 10 位 -> 30 位展开表（3 位间隔）。
static var _spread_cache: PackedInt64Array = PackedInt64Array()

static func _spread_table() -> PackedInt64Array:
	if _spread_cache.size() == 1024:
		return _spread_cache
	var t := PackedInt64Array()
	t.resize(1024)
	for i in 1024:
		var v: int = 0
		for b in 10:
			v |= ((i >> b) & 1) << (3 * b)
		t[i] = v
	_spread_cache = t
	return t

## 一份点数组的包围盒 -> [min, inv_extent]（量化用）。
static func _quant_params(data: PackedFloat32Array, n: int, stride: int) -> Array:
	var min_v := Vector3(INF, INF, INF)
	var max_v := -min_v
	for i in n:
		var b := i * stride
		var p := Vector3(data[b], data[b + 1], data[b + 2])
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	var size := max_v - min_v
	return [min_v, Vector3(
		1023.0 / maxf(size.x, 0.000001),
		1023.0 / maxf(size.y, 0.000001),
		1023.0 / maxf(size.z, 0.000001))]

static func _morton_of(data: PackedFloat32Array, base: int, inv: Vector3,
		origin: Vector3, spread: PackedInt64Array) -> int:
	var x := clampi(int((data[base] - origin.x) * inv.x), 0, 1023)
	var y := clampi(int((data[base + 1] - origin.y) * inv.y), 0, 1023)
	var z := clampi(int((data[base + 2] - origin.z) * inv.z), 0, 1023)
	return int(spread[x] | (spread[y] << 1) | (spread[z] << 2))

## Morton 排序配对：两边各自按 Morton 码排序，再按排序后的位置同序配对。
static func _pair_by_morton(a: PackedFloat32Array, b: PackedFloat32Array,
		n: int, m: int, stride: int) -> PackedInt32Array:
	var spread := _spread_table()
	var qa := _quant_params(a, n, stride)
	var qb := _quant_params(b, m, stride)
	var oa: Vector3 = qa[0]
	var ia: Vector3 = qa[1]
	var ob: Vector3 = qb[0]
	var ib: Vector3 = qb[1]

	# key 与 index 打包：低 21 位放 index，高位放 Morton 码 -> 一次 sort() 同时完成
	var packed_a := PackedInt64Array()
	packed_a.resize(n)
	for i in n:
		packed_a[i] = (_morton_of(a, i * stride, ia, oa, spread) << 21) | i
	packed_a.sort()

	var packed_b := PackedInt64Array()
	packed_b.resize(m)
	for i in m:
		packed_b[i] = (_morton_of(b, i * stride, ib, ob, spread) << 21) | i
	packed_b.sort()

	var mask := (1 << 21) - 1
	var map := PackedInt32Array()
	map.resize(n)
	for k in n:
		var bp := k if n == m else int(float(k) * float(m) / float(n))
		map[packed_a[k] & mask] = packed_b[clampi(bp, 0, m - 1)] & mask
	return map

static func _pair_by_axis(a: PackedFloat32Array, b: PackedFloat32Array,
		n: int, m: int, stride: int) -> PackedInt32Array:
	var qa := _quant_params(a, n, stride)
	var size: Vector3 = (qa[1] as Vector3)
	var axis := 0
	if size.y < size.x and size.y <= size.z:
		axis = 1
	elif size.z < size.x and size.z < size.y:
		axis = 2
	var mask := (1 << 21) - 1

	var packed_a := PackedInt64Array()
	packed_a.resize(n)
	for i in n:
		var v := a[i * stride + axis]
		packed_a[i] = (int(clampf(v * 2000.0 + 1000000.0, 0.0, 2097151.0)) << 21) | i
	packed_a.sort()

	var packed_b := PackedInt64Array()
	packed_b.resize(m)
	for i in m:
		var v := b[i * stride + axis]
		packed_b[i] = (int(clampf(v * 2000.0 + 1000000.0, 0.0, 2097151.0)) << 21) | i
	packed_b.sort()

	var map := PackedInt32Array()
	map.resize(n)
	for k in n:
		var bp := k if n == m else int(float(k) * float(m) / float(n))
		map[packed_a[k] & mask] = packed_b[clampi(bp, 0, m - 1)] & mask
	return map

# ── 单份点云的空间排序（不配对，只重排）──────────────────────────────────────

## 按 Morton 码给**一份**点云排序：返回原索引的排列 `order`（`order[k]` = 排第 k 位的点在原数组里的序号）。
static func sorted_indices(points: PackedFloat32Array, stride: int = 12) -> PackedInt32Array:
	var order := PackedInt32Array()
	var n := points.size() / stride if stride > 0 else 0
	if n <= 0:
		return order
	# 【超过 MAX_MORTON_POINTS 不排序，返回恒等排列】打包格式是 "Morton 码 << 21 | index"，
	if n > MAX_MORTON_POINTS:
		push_warning("[VoxelMorphMap] 点数 %d 超过 %d，空间排序跳过（返回恒等排列）" % [n, MAX_MORTON_POINTS])
		order.resize(n)
		for i in n:
			order[i] = i
		return order
	var spread := _spread_table()
	var q := _quant_params(points, n, stride)
	var origin: Vector3 = q[0]
	var inv: Vector3 = q[1]
	# 与 _pair_by_morton 同一手法：key 放高位、index 放低 21 位，一次内置 sort() 同时完成
	var packed := PackedInt64Array()
	packed.resize(n)
	for i in n:
		packed[i] = (_morton_of(points, i * stride, inv, origin, spread) << 21) | i
	packed.sort()
	var mask := (1 << 21) - 1
	order.resize(n)
	for k in n:
		order[k] = int(packed[k]) & mask
	return order

## 按 `sorted_indices` 给出的排列重排点数组（逐点整块搬运 stride 个 float）。
static func reorder(points: PackedFloat32Array, order: PackedInt32Array,
		stride: int = 12) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := order.size()
	if n <= 0 or stride <= 0:
		return points
	out.resize(n * stride)
	for k in n:
		var src := int(order[k]) * stride
		var dst := k * stride
		for c in stride:
			out[dst + c] = points[src + c]
	return out

func _to_string() -> String:
	return "VoxelMorphMap(count=%d, avg=%.4f, max=%.4f)" % [count, avg_distance, max_distance]
