@tool
class_name PcgSdfGenerator
extends VoxelGenerator

## SDF 光栅化生成器 —— SDF 建模模块与现有框架的接合点（真正的"程序化生成"一步）。
##
## 【接合方式】直接实现 VoxelGenerator 的 per-chunk 抽象，无需任何额外的光栅化器或模型容器：
##   _generate_chunk(chunk_key) → 32³ 缓冲：逐体素**格心**采样 field.sample()，
##   距离 <= isolevel 且材质 ID > 0 时写入该体素。
## 产出直接进 VoxelData，随即可复用整条渲染 / 碰撞 / LOD / 编辑链路。
##
## 【有界范围】由 VoxelData.grid_size 驱动（VoxelData 设 generator 时自动调 set_grid_size），
## 本生成器不含任何裁剪逻辑。于是：
##   一个程序化模型 = 一个【有界 VoxelData】+ 一个【PcgSdfGenerator（内嵌一棵 SDF 树）】
##                    + 一个【VoxelRenderer 节点】。
##
## 【确定性】纯函数，不引入随机；同一 chunk_key 恒得同一结果，origin shift 后世界仍连续。
##
## 【表面层：为什么它必须在**这一层**做】
## `PcgModelGenerator.details` 那条细节链需要**完整邻域**，而 SDF 是惰性按 chunk 生成的
## （只有 32³ 就够），两者天然不兼容 —— 于是岛体、多孔岩、洞穴这些**画面里最大的表面**
## 一直吃不到风化与色阶，`pcg_world_demo` 的台面就是一块纯灰平板。
## 本层用 SDF 自带的距离值替代邻域：`s.x > isolevel - surface_shell` 即"距表面一壳之内"
## = 暴露面。**不需要再多采一次 SDF**，只需一次噪声/哈希，成本可以忽略。
## 代价是"暴露度"只有 6 邻域里"朝上"这一个方向被真正判定（多采 1 次 SDF），
## 其余方向按壳层近似 —— 对大面积地形足够，对细枝末节才需要 PcgDetail 那条链。


## SDF 字段根节点（原语 / 组合算子 / 变换构成的树）。
@export var field: Sdf
## 等值面：距离 <= isolevel 视为实心。默认 0（SDF 表面本身）。
@export var isolevel: float = 0.0


# ----------------------------------------------------------------------------
# 表面层（全部为 opt-in：三个参数都空/0 时逐体素行为与从前完全一致）
# ----------------------------------------------------------------------------

## 表面壳厚（体素）：距表面在此距离内的实心体素才参与表面层。
## 1.5 覆盖地表往下 1~2 层 —— 刚好够风化出"浅坑 + 坑底也有色阶"。
@export var surface_shell: float = 1.5
## 表面色阶：源材质 ID → 目标 ID 数组（同色系深浅三档之类）。
## 命中的体素按**分块哈希**在其中挑一档（均匀 → 各档数量均衡；成块 → 不碎成噪点）。
@export var surface_ramps: Dictionary = {}
## 挑档的格边长（体素）。它是"看得出一个个体素"与"碎成电视雪花"的分界：
## 地形尺度上取 3~5，树/小件取 1.5~2。
@export var shade_cell: float = 3.0
## 挑档方式。
##   false（默认）= 按 shade_cell 分块哈希：各档数量均衡、同一格内同色。
##   true        = 按 fbm 噪声挑档：输出向中间档聚（大片中间色 + 少量两端），
##                 空间上**成片且连续**（没有格子的直边）。
## 【什么时候必须用 true】大面积的连续面 —— 台面、崖壁。分块哈希在 20 单位宽的
## 崖壁上会排出一张**方格迷彩**（每格 0.8 单位、边界笔直），近看像贴图错位；
## 而噪声挑档得到的是"这片岩层偏亮、那片偏暗"的软边界，才读作岩体。
## 反过来，小件（柱子、墙、树）用哈希更均匀，不容易被中间档吃掉全部变化。
@export var shade_noise: bool = false
## 色阶覆盖率 0~1：其余比例的体素保持原色（留白，避免整片被分档覆盖）。
@export_range(0.0, 1.0) var shade_coverage: float = 0.9
## 朝上染色：源材质 ID → 目标 ID。只作用于**正上方为空**的表面（积尘、苔藓、雪）。
## 判定代价是每命中体素多采 1 次 SDF（近表面体素只占少数，实测可忽略）。
@export var top_tints: Dictionary = {}
## 朝上染色的覆盖率（再乘下面那个尺度噪声，形成成片的苔斑而不是均匀撒点）。
@export_range(0.0, 1.0) var tint_coverage: float = 0.3
## 苔斑的特征尺寸（体素）。太小会变成"雀斑"，太大则整片同色。
@export var tint_cell: float = 6.0
## 表面风化强度 0~1：近表面体素被噪声挖空的概率上限。0 = 不风化。
## 用**噪声**而不是哈希：风化是成片的（一片酥松的岩面），哈希会得到均匀撒点。
@export_range(0.0, 1.0) var erode_strength: float = 0.0
## 风化特征尺寸（体素）。
@export var erode_cell: float = 3.0
## 风化只作用在**朝上的表面**（正上方为空）。
##
## 【为什么默认开】竖直崖壁上挖 1 体素深的坑，在掠射视角下坑的侧壁朝向与主平面差
## 一大截（受光量低、坑底还被邻格挡住直射光），一排坑连起来看就是**竖向条纹**
## ——台地会像一块瓦楞铁皮（world 场景实测：崖面一行像素在 0.45~0.55 与 0.05~0.13
## 之间反复跳，间距 1~2 体素）。
## 平台面没有这个问题：坑就是坑，从上往下看仍然是地面。
## 所以"破平板"这件事只该做在顶面，崖壁的层次交给色阶。
## 需要"崖壁也被啃"的场合把它关掉即可。
@export var erode_up_only: bool = true
## 表面层噪声种子。
@export var surface_seed: int = 0


## LOD0：逐体素格心采样，写入 32³ chunk 缓冲。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	if field == null:
		return buf
	_prepare()
	var base := Vector3(VoxelChunk.origin_of(chunk_key))
	for lz in VoxelChunk.CHUNK_SIZE:
		for ly in VoxelChunk.CHUNK_SIZE:
			for lx in VoxelChunk.CHUNK_SIZE:
				var p := base + Vector3(lx + 0.5, ly + 0.5, lz + 0.5)
				var m := _material_at(p)
				if m > 0:
					buf[VoxelChunk.buf_index(lx, ly, lz)] = m
	return buf


## 整块体积光栅化：把一棵连续域表达式树采样成 [0, grid_size) 上的密集体积。
##
## 【表面开关一律不启用】surface_ramps / top_tints / erode_strength 保持默认关。它们是
## **内联在本生成器里的体素域算子**，而链上的体素域处理由显式的修改器完成（PcgWeather /
## PcgSurfaceTint）。有界模型（完整邻域可得）让这条合并第一次成立：同一件事只有一条路径，
## 且体素域处理变成可重排、可旁通、可叠加的修改器。
static func rasterize_field(field_: Sdf, grid_size: Vector3i) -> PackedInt32Array:
	var gen := PcgSdfGenerator.new()
	gen.field = field_
	return gen.to_volume(grid_size)


## 粗层 LOD：按 2^lod 体素的大格取格心采样（远处粗粒度直接生成，无需先加载 LOD0 再降采样）。
## 细薄特征在粗层可能被漏掉，与程序化地形的粗层策略一致，属预期行为。
func _generate_chunk_lod(block_key: Vector3i, lod: int) -> PackedInt32Array:
	var grid := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var buf := PackedInt32Array()
	buf.resize(grid * grid * grid)
	if field == null:
		return buf
	_prepare()
	var cell := 1 << lod
	var half := cell * 0.5
	var base := Vector3(block_key * (grid * cell))
	for lz in grid:
		for ly in grid:
			for lx in grid:
				var p := base + Vector3(
					lx * cell + half,
					ly * cell + half,
					lz * cell + half
				)
				var m := _material_at(p)
				if m > 0:
					buf[lx + ly * grid + lz * grid * grid] = m
	return buf


## 格心处命中实体则返回材质 ID，否则返回 0（空）。
func _material_at(p: Vector3) -> int:
	var s := field.sample(p)
	if s.x > isolevel:
		return 0
	var id := int(s.y)
	if id <= 0:
		return 0
	if _surface_active and s.x > isolevel - surface_shell:
		return _surface_material(p, id)
	return id


# ----------------------------------------------------------------------------
# 表面层实现
# ----------------------------------------------------------------------------

var _surface_active: bool = false
var _tier_noise: FastNoiseLite
var _tint_noise: FastNoiseLite
var _erode_noise: FastNoiseLite


## 三个开关全关时整条表面层短路 —— 保证既有场景（pcg_models / pcg_cave /
## pcg_porous）的产出与从前逐体素一致，改本文件不会动它们的画面。
func _prepare() -> void:
	_surface_active = (not surface_ramps.is_empty()) \
			or (not top_tints.is_empty()) \
			or erode_strength > 0.0
	if not _surface_active:
		return
	if _tier_noise == null:
		_tier_noise = PcgDetail.make_noise(maxf(shade_cell, 0.001), 1, surface_seed + 7)
	if _tint_noise == null:
		_tint_noise = PcgDetail.make_noise(maxf(tint_cell, 0.001), 3, surface_seed + 23)
	if _erode_noise == null:
		_erode_noise = PcgDetail.make_noise(maxf(erode_cell, 0.001), 3, surface_seed + 51)


## 近表面体素的材质改写：风化 → 朝上染色 → 色阶分档。
##
## 【顺序为什么不能反】风化先挖，后两步才作用在"剩下的表面"上；
## 反过来会让新挖出的坑侧面保持原色，坑就成了一块突兀的补丁。
func _surface_material(p: Vector3, src: int) -> int:
	var ix := int(floor(p.x))
	var iy := int(floor(p.y))
	var iz := int(floor(p.z))

	# 朝上判定：正上方一格是空的 → 这一格是"顶面"。这是本层唯一额外的 SDF 采样，
	# 且风化与朝上染色**共用**同一次结果（两边都要用它，各采一次是白花成本）。
	var need_up := (erode_strength > 0.0 and erode_up_only) \
			or (not top_tints.is_empty() and top_tints.has(src))
	var up_empty := true
	if need_up:
		up_empty = field.sample(p + Vector3.UP).x > isolevel

	if erode_strength > 0.0 and (up_empty or not erode_up_only):
		if PcgDetail.sample01(_erode_noise, ix, iy, iz) < erode_strength:
			return 0

	if not top_tints.is_empty() and top_tints.has(src) and up_empty:
		var n := PcgDetail.sample01(_tint_noise, ix, iy, iz)
		if n < tint_coverage:
			var tint: int = top_tints[src]
			return tint

	if not surface_ramps.is_empty() and surface_ramps.has(src):
		var ramp: PackedInt32Array = surface_ramps[src]
		var count := ramp.size()
		if count > 0:
			var n := PcgDetail.sample01(_tier_noise, ix, iy, iz)
			if shade_coverage < 1.0 and n >= shade_coverage:
				return src
			if count == 1:
				return ramp[0]
			# 挑档默认用**分块哈希**：噪声输出向中间聚，三档会变成 9%/82%/9%，
			# 画面照旧平涂（实测依据见 PcgDetail.hash01）。哈希均匀 → 各档各 1/3，
			# 且同一格内同色，不会碎成逐体素噪点。
			# 大面积连续面（台面/崖壁）则改用 shade_noise：宁可要"中间档吃八成"的
			# 软分布，也不要方格迷彩。
			var pick := n
			if not shade_noise:
				var s := maxf(shade_cell, 0.001)
				pick = PcgDetail.hash01(
						int(floor(float(ix) / s)), int(floor(float(iy) / s)), int(floor(float(iz) / s)),
						surface_seed + 7)
			return ramp[clampi(int(pick * float(count)), 0, count - 1)]
	return src
