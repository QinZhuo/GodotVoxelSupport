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
## 【表面处理已迁出本类（P3-2）】本生成器现在只做一件事：**把连续域采样成体素**。
## 风化 / 色阶 / 朝上染色改用链上的通用体素域算子（PcgWeather / PcgSurfaceTint），
## 走 QVoxObjectGenerator 的"先取完整体积，再进链"路径。收益有三：
##   · 同一件事不再有两份实现（过去这里内联了一份 PcgSurfaceTint + PcgWeather 的等价逻辑）；
##   · 表面处理对所有形态来源一视同仁（SDF / WFC / 元胞 / L-系统都吃得到）；
##   · 顺序变成链上可重排、可旁通、可叠加的条目，而不是写死在采样循环里。
## 代价是有界模型要常驻一份完整体积 —— 细节算子需要**完整邻域**，按 chunk 懒算必然在
## chunk 边界留下接缝。这是 P2/P3 的既定取舍，见 docs/REFACTOR_PLAN.md §4。


## SDF 字段根节点（原语 / 组合算子 / 变换构成的树）。
@export var field: Sdf
## 等值面：距离 <= isolevel 视为实心。默认 0（SDF 表面本身）。
@export var isolevel: float = 0.0


## LOD0：逐体素格心采样，写入 32³ chunk 缓冲。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	if field == null:
		return buf
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
## 【纯几何】本函数只采样 field，不做任何表面处理 —— 风化 / 染色由调用方在链上接着做
## （求值引擎的 SDF 生产步骤走的正是这里，见 QVoxEvalEngine）。
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
	return maxi(int(s.y), 0)
