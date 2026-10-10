@tool
class_name PcgWfc
extends PcgModel

## WFC（波函数坍缩）：把"一整块体素"看作由若干小图块拼成的格网，
## 从"每格都能是任意图块"出发，反复做"选一格定下来 + 传播约束"，直到处处定下。
## 【为什么和 SDF 互补】WFC 的规则是**局部**的（只看邻居接口是否对得上），
## 全局形态是**涌现**的：作者只写"墙接墙、门接墙、地板接地板"，算法自动拼出连通的房间与走廊。
## 这正适合"我说不清具体长什么样、但知道每块该怎么接"的建筑/遗迹。
## 【确定性】固定 seed；一旦某格候选被清空（矛盾）就换 seed 重来，
## 因此同参数同 grid_size 恒得同一结果。全部重试都失败则输出空模型并告警。
## 【边界】本实现不约束世界边界（边上的图块朝外的面自由），成品边缘可能有开口。
## 需要封闭时加一块"朝外面全为实心"的图块，并调高其 weight。

## 六个相邻方向，顺序与 PcgWfcTile.sockets 的面顺序一致（+X,-X,+Y,-Y,+Z,-Z）。
const DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## 第 d 面的对面编号（DIRS[d] 取反后的下标）。
const OPPOSITE: PackedInt32Array = [1, 0, 3, 2, 5, 4]


## 候选图块集合（同一套里所有图块的 size 应一致）。
@export var tiles: Array[PcgWfcTile] = []
## 随机种子（同种子 → 同结果）。
@export var seed: int = 0
## 矛盾后的重试次数（第 n 次用 seed + n）。
@export var max_retries: int = 8


func build(grid_size: Vector3i) -> PackedInt32Array:
	var volume := PcgModel.empty_volume(grid_size)
	if tiles.is_empty():
		return volume
	var ts: Vector3i = tiles[0].size
	if ts.x <= 0 or ts.y <= 0 or ts.z <= 0:
		push_warning("[PcgWfc] 图块尺寸非法，输出空模型")
		return volume
	var cells := Vector3i(
			_grid_count(grid_size.x, ts.x),
			_grid_count(grid_size.y, ts.y),
			_grid_count(grid_size.z, ts.z))
	if cells.x == 0 or cells.y == 0 or cells.z == 0:
		return volume

	for attempt in maxi(max_retries, 1):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed + attempt
		var solved := _solve(cells, rng)
		if not solved.is_empty():
			_stamp(volume, grid_size, ts, cells, solved)
			return volume

	push_warning("[PcgWfc] %d 次尝试均矛盾，输出空模型（可增大 max_retries 或减少图块种类）"
			% max_retries)
	return volume


# ① 求解：观察 → 坍缩 → 传播

## 解一次。返回每格选中的图块下标（长度 = 格数）；矛盾则返回空数组。
func _solve(cells: Vector3i, rng: RandomNumberGenerator) -> PackedInt32Array:
	var count := cells.x * cells.y * cells.z

	# 每格的候选集合（domain），初始为全部图块。
	var domains: Array = []
	domains.resize(count)
	var all := PackedInt32Array()
	for i in tiles.size():
		if tiles[i] != null:
			all.append(i)
	if all.is_empty():
		return PackedInt32Array()
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
		# ③ 传播：邻居候选按接口一致性收缩，任何一处清空即矛盾。
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
	for ti in candidates:
		total += maxf(tiles[ti].weight, 0.0)
	if total <= 0.0:
		return candidates[rng.randi_range(0, candidates.size() - 1)]
	var r := rng.randf() * total
	for ti in candidates:
		r -= maxf(tiles[ti].weight, 0.0)
		if r <= 0.0:
			return ti
	return candidates[candidates.size() - 1]


## 从 start 出发，按"接触面必须同名"把约束传给邻居，直到不再有候选收缩。
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


## dst 方向 d 侧的图块里，其 OPPOSITE[d] 面能与 src 任意图块的 d 面接上的那些。
func _compatible(src: PackedInt32Array, dst: PackedInt32Array, d: int) -> PackedInt32Array:
	var back := OPPOSITE[d]
	var out := PackedInt32Array()
	for bi in dst:
		for ai in src:
			if tiles[bi].socket_of(back) == tiles[ai].socket_of(d):
				out.append(bi)
				break
	return out


# ② 落格：把每格选中的图块画进体积

func _stamp(volume: PackedInt32Array, grid_size: Vector3i, ts: Vector3i,
		cells: Vector3i, solved: PackedInt32Array) -> void:
	for cz in cells.z:
		for cy in cells.y:
			for cx in cells.x:
				var t: PcgWfcTile = tiles[solved[_index_of(Vector3i(cx, cy, cz), cells)]]
				if t == null:
					continue
				var origin := Vector3i(cx * ts.x, cy * ts.y, cz * ts.z)
				for lz in t.size.z:
					for ly in t.size.y:
						for lx in t.size.x:
							var m := t.voxel_at(lx, ly, lz)
							if m > 0:
								PcgModel.set_voxel(volume, origin.x + lx, origin.y + ly,
										origin.z + lz, grid_size, m)


# 格网坐标换算（布局与 PcgModel.index_of 一致：x 连续，再 y，再 z）

func _grid_count(extent: int, cell: int) -> int:
	return maxi(int(ceil(float(extent) / float(cell))), 0)


func _index_of(cell: Vector3i, cells: Vector3i) -> int:
	return cell.x + cell.y * cells.x + cell.z * cells.x * cells.y


func _cell_of(i: int, cells: Vector3i) -> Vector3i:
	return Vector3i(i % cells.x, (i / cells.x) % cells.y, i / (cells.x * cells.y))
