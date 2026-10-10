@tool
class_name PcgWfcOverlap
extends PcgModel

## WFC（波函数坍缩）—— **重叠式（overlapping）** 变体。
## 【与 socket 式 PcgWfc 的唯一区别：规则从哪来】
##   PcgWfc      —— 作者手写每块图块的六面接口名，WFC 只做"接口配对"。
##   本类        —— 作者只给一块**样例**（已画好的体素），
##                  算法自己从样例里"数"出所有 N³ 小窗口当作候选图案，再让它们重叠地拼满输出。
##   于是规则不用手写、从样例里学；代价是候选数大得多（样例越丰富越多），求解更重。
## 【学习】样例里每个 N³ 窗口（滑窗步长 1）去重后成为一种图案，权重 = 出现次数。
## 【图案相容】方向 d 上 p 与 q 相邻，要求**重叠区逐格一致**（这正是"重叠"的含义）：
##   d = +X 时，p 的 x∈[1,N-1] 切块 == q 的 x∈[0,N-2] 切块（y/z 全域）
##   d = -X 时，p 的 x∈[0,N-2] 切块 == q 的 x∈[1,N-1] 切块
##   即："p 沿 d 的前段"与"q 沿 d 的后段"对齐，重叠宽度 = N-1（socket 式则是"面碰面"）。
## 【输出】每格取所选图案的**左上角体素**（local 0,0,0）。
##   相邻图案的重叠区一致 → 全图自然连成一片（等价于"图案铺砌的一个 1:1 取样窗口"），
##   也因此输出尺寸 = grid_size，无需为图案越界额外扩边。
## 【确定性】固定 seed；某格候选被清空（矛盾）则按 max_retries 换 seed 重来；全失败输出空模型。
## 【尺寸警告】重叠式**每格一个图案**，格数 = 输出体素数 —— 比 socket 式重得多
##   （socket 式 32³ 配 4³ 图块只有 8³ = 512 格，两者不可比）。
##   建议 grid_size ≤ 24³；样例也不宜过大（图案数随样例边长三次方增长）。

## 六个相邻方向，顺序与 PcgWfc 一致（+X,-X,+Y,-Y,+Z,-Z）。
const DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## 学习用的样例体素（密集，值 = 材质ID，0 = 空）。
## 下标 = x + y*sample_size.x + z*sample_size.x*sample_size.y（与 PcgModel 布局一致）。
@export var sample: PackedInt32Array = PackedInt32Array()
## 样例尺寸（必须与 sample 长度一致）。
@export var sample_size: Vector3i = Vector3i(8, 8, 8)
## 图案边长 N（窗口 N³）。N=1 退化"照抄样例单格"，N=3 是常用值。
@export var pattern_size: int = 3
## 随机种子（同种子 → 同结果）。
@export var seed: int = 0
## 矛盾后的重试次数（第 n 次用 seed + n）。
@export var max_retries: int = 8

# --- 学习结果（每次 build 重建；数据层会缓存产出，故无需自己再缓存） ---
var _n := 0                                  ## 图案边长
var _patterns: Array[PackedInt32Array] = []  ## 去重后的图案内容
var _weights: PackedFloat32Array = PackedFloat32Array()  ## 图案出现次数（作选择权重）
var _allow: Array = []                       ## _allow[d][p] = Dictionary（与 p 在方向 d 相容的 q 集合）


## 链外节点：重叠式 WFC 要**全局**迭代收敛（矛盾回退、约束传播看的是整块体积的
## 接缝邻域），且 `_learn()` 会写本对象的可变缓存 —— 线性链既给不了它全局视窗，
## 也不该替它决定"该在第几步重新学习"。它只作为**整体产出**使用
## （数据层整块供数，见 qvoxelier 的"链外节点"分层）。
func chainable() -> bool:
	return false


func build(grid_size: Vector3i) -> PackedInt32Array:
	var volume := PcgModel.empty_volume(grid_size)
	if not _learn():
		return volume
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return volume

	# 重叠式：一格一个图案（含左上角读法），格网 = 输出体素尺寸。
	var cells := grid_size
	for attempt in maxi(max_retries, 1):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed + attempt
		var solved := _solve(cells, rng)
		if not solved.is_empty():
			_stamp(volume, grid_size, solved)
			return volume

	push_warning("[PcgWfcOverlap] %d 次尝试均矛盾，输出空模型（可增大 max_retries 或缩小样例）"
			% max_retries)
	return volume


# ① 学习：样例 → 图案集合 + 权重 + 相容表

## 从样例里滑窗抽取所有 N³ 图案（去重计权），并预计算六个方向的相容表。
## 样例缺失 / 尺寸不符 / 小于图案时返回 false（调用方输出空模型）。
func _learn() -> bool:
	_patterns = []
	_weights = PackedFloat32Array()
	_allow = []
	_n = pattern_size
	var ss := sample_size
	if _n < 1 or ss.x < _n or ss.y < _n or ss.z < _n or sample.size() != ss.x * ss.y * ss.z:
		push_warning("[PcgWfcOverlap] 样例缺失或小于图案尺寸（sample_size=%s, N=%d, 数据长度=%d），输出空模型"
				% [str(ss), _n, sample.size()])
		return false

	var seen := {}
	for wz in ss.z - _n + 1:
		for wy in ss.y - _n + 1:
			for wx in ss.x - _n + 1:
				var win := _window(wx, wy, wz)
				if seen.has(win):
					_weights[seen[win]] += 1.0
				else:
					seen[win] = _patterns.size()
					_patterns.append(win)
					_weights.append(1.0)
	if _patterns.is_empty():
		return false

	_build_allow()
	return true


## 抽样例中左上角 (ox,oy,oz) 的 N³ 窗口（紧凑布局 x 连续，与图案下标同构）。
func _window(ox: int, oy: int, oz: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(_n * _n * _n)
	var ss := sample_size
	var i := 0
	for lz in _n:
		for ly in _n:
			var base := ox + (oy + ly) * ss.x + (oz + lz) * ss.x * ss.y
			for lx in _n:
				out[i] = sample[base + lx]
				i += 1
	return out


## 预计算相容表：避免传播时对每对图案都逐格比较。
## 做法（每方向一次）：按 q 的"后段切块"分桶，则 p 的相容集合就是"p 的前段切块"所在的桶。
func _build_allow() -> void:
	var pc := _patterns.size()
	for d in DIRS.size():
		var axis := _axis_of(d)
		var forward := _is_forward(d)
		# 桶：q 的"后段"切块签名 → q 集合
		var buckets := {}
		for qi in pc:
			var key := _slice(qi, axis, 0 if forward else 1)
			if not buckets.has(key):
				buckets[key] = {}
			(buckets[key] as Dictionary)[qi] = true
		# 每个 p 的相容集合 = 桶[p 的"前段"切块签名]
		var table: Array = []
		table.resize(pc)
		for pi in pc:
			var key := _slice(pi, axis, 1 if forward else 0)
			table[pi] = buckets.get(key, {})
		_allow.append(table)


## 图案 pat 沿 axis 轴、从该轴偏移 off 处取长度 N-1 的切块（其余两轴全域）。
## 紧凑布局：剩余两轴按升序各循环一遍，保证同一 axis 的"前段/后段"逐位可比。
func _slice(pat: int, axis: int, off: int) -> PackedInt32Array:
	var w := _patterns[pat]
	var m := _n - 1
	var out := PackedInt32Array()
	out.resize(m * _n * _n)
	var i := 0
	for a in _n:
		for b in _n:
			for c in m:
				var p := Vector3i.ZERO
				if axis == 0:
					p = Vector3i(off + c, a, b)
				elif axis == 1:
					p = Vector3i(b, off + c, a)
				else:
					p = Vector3i(b, a, off + c)
				out[i] = w[p.x + p.y * _n + p.z * _n * _n]
				i += 1
	return out


## 方向 d 作用的轴（0=X / 1=Y / 2=Z）。
func _axis_of(d: int) -> int:
	var v := DIRS[d]
	if v.x != 0:
		return 0
	return 1 if v.y != 0 else 2


## 方向 d 是否为该轴的正向（+X / +Y / +Z）。
func _is_forward(d: int) -> bool:
	var v := DIRS[d]
	return (v.x + v.y + v.z) > 0


# ② 求解：观察 → 坍缩 → 传播（与 PcgWfc 同一骨架，只是约束来源不同）

## 解一次。返回每格选中的图案下标（长度 = 格数）；矛盾则返回空数组。
func _solve(cells: Vector3i, rng: RandomNumberGenerator) -> PackedInt32Array:
	var count := cells.x * cells.y * cells.z
	if count <= 0:
		return PackedInt32Array()

	# 每格候选集合，初始为全部图案。
	var all := PackedInt32Array()
	for i in _patterns.size():
		all.append(i)
	var domains: Array = []
	domains.resize(count)
	for i in count:
		domains[i] = all.duplicate()

	while true:
		# ① 观察：挑候选最少的未定格（熵最小）；找不到未定格即全部定下。
		var best := -1
		var best_size := 1 << 30
		for i in count:
			var d: PackedInt32Array = domains[i]
			if d.is_empty():
				return PackedInt32Array()
			if d.size() > 1 and d.size() < best_size:
				best_size = d.size()
				best = i
		if best == -1:
			break
		# ② 坍缩：按权重定下该格。
		domains[best] = PackedInt32Array([_pick(domains[best], rng)])
		# ③ 传播：邻居候选按重叠区一致性收缩，任何一处清空即矛盾。
		if not _propagate(domains, cells, best):
			return PackedInt32Array()

	var solved := PackedInt32Array()
	solved.resize(count)
	for i in count:
		solved[i] = (domains[i] as PackedInt32Array)[0]
	return solved


## 按权重从候选里挑一个（权重全为 0 时退化为等概率）。
func _pick(candidates: PackedInt32Array, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for pi in candidates:
		total += maxf(_weights[pi], 0.0)
	if total <= 0.0:
		return candidates[rng.randi_range(0, candidates.size() - 1)]
	var r := rng.randf() * total
	for pi in candidates:
		r -= maxf(_weights[pi], 0.0)
		if r <= 0.0:
			return pi
	return candidates[candidates.size() - 1]


## 从 start 出发，按"重叠区必须一致"把约束传给邻居，直到不再有候选收缩。
## 返回 false = 出现矛盾（某格候选被清空）。
func _propagate(domains: Array, cells: Vector3i, start: int) -> bool:
	var queue: Array = [start]
	while not queue.is_empty():
		var ci: int = queue.pop_front()
		var cell := _cell_of(ci, cells)
		var src: PackedInt32Array = domains[ci]
		for d in DIRS.size():
			var nc: Vector3i = cell + DIRS[d]
			if nc.x < 0 or nc.y < 0 or nc.z < 0 \
					or nc.x >= cells.x or nc.y >= cells.y or nc.z >= cells.z:
				continue
			var ni := _index_of(nc, cells)
			var keep := _compatible(src, domains[ni], d)
			if keep.size() == (domains[ni] as PackedInt32Array).size():
				continue
			if keep.is_empty():
				return false
			domains[ni] = keep
			if not queue.has(ni):
				queue.append(ni)
	return true


## dst 里能与 src 中某个图案在方向 d 上重叠相接的那些（用预算的相容表查，不逐格比较）。
func _compatible(src: PackedInt32Array, dst: PackedInt32Array, d: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var table: Array = _allow[d]
	for qi in dst:
		for pi in src:
			if (table[pi] as Dictionary).has(qi):
				out.append(qi)
				break
	return out


# ③ 落格：每格取其图案的左上角体素

func _stamp(volume: PackedInt32Array, grid_size: Vector3i, solved: PackedInt32Array) -> void:
	for z in grid_size.z:
		for y in grid_size.y:
			var row := y * grid_size.x + z * grid_size.x * grid_size.y
			for x in grid_size.x:
				var m := _patterns[solved[row + x]][0]
				if m > 0:
					volume[row + x] = m


# 格网坐标换算（布局与 PcgModel.index_of 一致：x 连续，再 y，再 z）

func _index_of(cell: Vector3i, cells: Vector3i) -> int:
	return cell.x + cell.y * cells.x + cell.z * cells.x * cells.y


func _cell_of(i: int, cells: Vector3i) -> Vector3i:
	return Vector3i(i % cells.x, (i / cells.x) % cells.y, i / (cells.x * cells.y))
