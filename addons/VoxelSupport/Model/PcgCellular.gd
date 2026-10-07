@tool
class_name PcgCellular
extends PcgModel

## 三维元胞自动机（洞穴生成）：先按概率播撒实心胞，再按"邻居数"规则迭代平滑成洞穴。
##
## 【规则】26 邻域版本的地道 4-5 规则：
##   空胞周围实心邻居 >= birth_limit → 变为实心
##   实胞周围实心邻居 <  death_limit → 变为空
## 反复迭代后，随机噪点被抹平，留下连通的空腔与厚实的外壳——即"洞穴"。
##
## 【确定性】用固定 seed 的 RNG 播撒，同一 seed + 同一 grid_size 恒得同一结果。
##
## 【调参手感】结果对 fill_ratio 极其敏感 —— 它决定初始密度落在 26 邻域阈值的哪一侧，
## 而"全实心"与"全空"都是稳定态，密度只会被推得更极端。实测（32³ / 4 轮 / 13-12）：
##   shell_is_solid=true   0.40→39%  0.44→61%  0.46→74%  0.48→87%  0.50→94%
##   shell_is_solid=false  0.40→ 7%  0.44→24%  0.46→38%  0.48→54%  0.50→65%
## 即：想改结构粗细请以 0.01 为步长微调，别按 0.1 调。

## 初始实心概率（0 = 全空，1 = 全实）。
@export_range(0.0, 1.0) var fill_ratio: float = 0.44
## 平滑迭代次数。
@export var iterations: int = 4
## 空胞转实心的阈值（26 邻域）。
@export var birth_limit: int = 13
## 实胞保持实心的阈值（26 邻域）。
@export var death_limit: int = 12
## 随机种子（同种子 → 同结果）。
@export var seed: int = 0
## 实心材质 ID。
@export var material_id: int = 1
## 范围外按实心计入邻居数 → 外壳天然封闭（洞穴不外漏）。
@export var shell_is_solid: bool = true


func build(grid_size: Vector3i) -> PackedInt32Array:
	var volume := PcgModel.empty_volume(grid_size)
	var n := volume.size()
	if n <= 0:
		return volume

	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var cur := PackedByteArray()
	cur.resize(n)
	for i in n:
		cur[i] = 1 if rng.randf() < fill_ratio else 0

	for _it in maxi(iterations, 0):
		cur = _step(cur, grid_size)

	for i in n:
		if cur[i] != 0:
			volume[i] = material_id
	return volume


## 一轮迭代：逐格按邻居数决定下一状态。
func _step(cur: PackedByteArray, grid_size: Vector3i) -> PackedByteArray:
	var nxt := PackedByteArray()
	nxt.resize(cur.size())
	for z in grid_size.z:
		for y in grid_size.y:
			for x in grid_size.x:
				var i := PcgModel.index_of(x, y, z, grid_size)
				var alive := cur[i] != 0
				var count := _solid_neighbors(cur, grid_size, x, y, z)
				var limit := death_limit if alive else birth_limit
				nxt[i] = 1 if count >= limit else 0
	return nxt


## 26 邻域中实心胞个数。越界格按 shell_is_solid 计入（保证外壳封闭）。
func _solid_neighbors(cur: PackedByteArray, grid_size: Vector3i, x: int, y: int, z: int) -> int:
	var count := 0
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var nx := x + dx
				var ny := y + dy
				var nz := z + dz
				if nx < 0 or ny < 0 or nz < 0 \
						or nx >= grid_size.x or ny >= grid_size.y or nz >= grid_size.z:
					if shell_is_solid:
						count += 1
					continue
				if cur[PcgModel.index_of(nx, ny, nz, grid_size)] != 0:
					count += 1
	return count
