@tool
@abstract
class_name PcgDetail
extends Resource

## 细节层 —— 在 PcgModel 已经产出整块体素**之后**、交给渲染器**之前**再做一轮改写。
##
## 【为什么必须有这一层】三条产出栈（SDF 组合 / WFC 图块 / L-系统盖章）都只会产出
## "数学上正确"的形态：球就是球、立方体就是立方体、枝干就是等粗的线。真正让体素资产
## 脱离"算法演示"观感的，是表面那层**不规则性**——边缘的缺角、风化的凹坑、按高度
## 或噪声分布的材质分区。这类操作是纯体素域上的重写，与"形态怎么来的"完全无关，
## 所以必须独立于三条栈之外、挂在生成器后处理位上；否则每个 demo 都得为自己的算法
## 重写一遍，且永远漏掉一部分。
##
## 【契约】`apply()` 收到的是模型刚 build 出来的那份体积（引用计数为 1，可安全原地改写），
## 就地修改。约定：
##   - 只允许改写体素（写材质 ID 或置 0 挖空），**不得改变 grid_size**；
##   - 必须确定性：同 seed + 同参数恒得同一结果；
##   - 不得把模型挖到"整体悬空"或"整体消失"（各算子自带 protect_* 开关兜底）。
##
## 【接入】PcgModelGenerator.details 是本类数组，按数组顺序依次执行。
## 与 SDF 栈能"组合出实体"不同，这一层只能改写既有实体（挖 / 换材质），不能凭空造形状。
##
## 【凹处的层次只能由本层表达】渲染器**不提供几何级顶点色 AO**（曾实现过，实测观感
## 更差，已移除 —— 原因见 VoxelChunkGenerator 的"已移除：顶点色 AO"）。所以"这里凹、
## 这里背光"必须由本层**换材质**写出来（同色系更暗的一档体素），不能指望光照去补。


## 就地改写整块体积。seed 由生成器统一传入，保证多算子链也只掷一次确定性骰。
@abstract
func apply(volume: PackedInt32Array, grid_size: Vector3i, seed: int) -> void


# ----------------------------------------------------------------------------
# 子类共用工具（静态、越界安全）
# ----------------------------------------------------------------------------

## 6 邻域偏移（面邻居，不含对角）。
const OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## 该格是否实心（越界视为空）。
static func is_solid(volume: PackedInt32Array, grid_size: Vector3i, x: int, y: int, z: int) -> bool:
	if x < 0 or y < 0 or z < 0 or x >= grid_size.x or y >= grid_size.y or z >= grid_size.z:
		return false
	return volume[PcgModel.index_of(x, y, z, grid_size)] > 0


# ----------------------------------------------------------------------------
# 噪声（直接用引擎自带的 FastNoiseLite，不自研）
# ----------------------------------------------------------------------------

## 噪声实例缓存：细节层是逐体素调用的热路径，若每次采样都 new 一个 FastNoiseLite
## 会被 GC 拖垮，故按参数键缓存复用。
##
## 【为什么是字典而不是单个实例】一个算子常要同时用两把不同尺度的噪声 ——
## 比如 PcgSurfaceTint 用粗噪声决定"哪些体素被改写"、用细噪声决定"改成哪一档颜色"，
## 两者频率不同就无法共用一个实例。单槽缓存在这里会被反复覆盖，退化成每次重建。
## 上限 4 把够用（超出即整体清空，避免算子被极端参数撑爆内存）。
var _noises: Dictionary = {}
const NOISE_CACHE_LIMIT := 4

## 取得按 (cell, octaves, seed) 配置好的原生 3D 噪声。
##
## 【为什么用 FastNoiseLite 而不是自己写哈希噪声】① 引擎自带，零维护；
## ② fractal_octaves / fractal_gain / fractal_lacunarity 就是现成的 fbm 参数，
##   不必自己实现倍频叠加；③ Godot 承诺同 seed 同参数的噪声输出一致，
##   而"同参数恒得同一结果"正是 PcgModel 的确定性契约。
## 注意 FastNoiseLite 的频率是"每单位坐标"，与 OpenSimplexNoise 的 noise_scale 相反；
## cell 的语义是"特征的世界（体素）尺寸"，故 frequency 取其倒数。
func noise_at(cell: float, octaves: int, seed: int) -> FastNoiseLite:
	var key := "%d:%.4f:%d" % [seed, cell, octaves]
	if _noises.has(key):
		return _noises[key] as FastNoiseLite
	var n := make_noise(cell, octaves, seed)
	if _noises.size() >= NOISE_CACHE_LIMIT:
		_noises.clear()
	_noises[key] = n
	return n


## 造一把 fbm 噪声（无缓存）。给**不继承本类**的调用方用（如 PcgTerrain 继承 PcgModel），
## 保证"噪声怎么配"这件事全模块只有一份实现，不会出现两处 frequency/gain 各写一遍的漂移。
static func make_noise(cell: float, octaves: int, seed: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0 / maxf(cell, 0.001)
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = clampi(octaves, 1, 8)
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	return n


## 采样噪声并归一到 [0,1)（FastNoiseLite 原始输出是 [-1,1]）。
static func sample01(noise: FastNoiseLite, x: int, y: int, z: int) -> float:
	return (noise.get_noise_3d(float(x), float(y), float(z)) + 1.0) * 0.5



## 暴露度 = 6 个面邻居中有几个是空的（0 = 埋在实体内部，6 = 孤立单块）。
## 细节算子据此只动"看得见的表面"，避免把模型内部掏空。
static func exposure(volume: PackedInt32Array, grid_size: Vector3i,
		x: int, y: int, z: int) -> int:
	var empty := 0
	for o in OFFSETS:
		if not is_solid(volume, grid_size, x + o.x, y + o.y, z + o.z):
			empty += 1
	return empty


## 上方是否空（用于"只风化顶面"这类约束）。
static func open_above(volume: PackedInt32Array, grid_size: Vector3i, x: int, y: int, z: int) -> bool:
	return not is_solid(volume, grid_size, x, y + 1, z)


## 该体素中心是否位于 y = 高度 之上（按模型高度比例）。
static func above_ratio(y: int, grid_size: Vector3i, threshold: float) -> bool:
	if grid_size.y <= 0:
		return false
	return float(y) / float(grid_size.y) >= threshold


## 确定性整点哈希 → [0,1)。给定 (x,y,z,salt) 恒得同一个值。
##
## 【什么时候用它，而不是噪声】需要**各档数量均衡**的时候。
## fbm 这类连续噪声的输出天然向中间聚（正态状），拿它来"挑 N 档"会让中间档吃掉八成
## ——实测遗迹墙三档是 250 / 2418 / 280，画面基本还是平涂，分档等于白做。
## 哈希是均匀的，配合下面的"按格分块"用，既能均衡数量、又能保持成片的空间结构。
##
## 【为什么是 32 位掩码 + 这种乘数】全程把中间结果 & 0xFFFFFFFF 夹住再乘，
## 保证每步都不超出 int64；乘数取无规律的奇数（黄金分割系）是为了把高位的规律性
## 抖散。任何一处不夹住，长网格上的格子就会出现可见的周期条纹。
static func hash01(x: int, y: int, z: int, salt: int) -> float:
	var h := (x * 0x1f1f1f1f) ^ (y * 0x2f2f2f2f) ^ (z * 0x3f3f3f3f) ^ salt
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 15)) * 0x2c1b3c6d) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 0x297a2d39) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFFFF) / 4294967296.0
