class_name VoxelLodGrid
extends RefCounted

## LOD 分带的**纯几何数学**：block 划分 / 层边长 / block 中心距 / 滞回带 / 预生成量 / 分带公式。
## 【为什么单独成类】这是无限层（LOD 调度）与内核（粗层网格组装）**唯一共享的几何**：
## 内核组装粗层 mesh 时要知道"该层 block 的世界边长"才能摆节点位置，但它不该知道
## LOD 调度、相机、分带策略的存在。把几何抽成无状态静态函数后，两侧只借用数学，
## 依赖方向保持单向（内核 → 几何 ← 无限层），内核不反向依赖无限层。
## 【无状态】不持有相机 / voxel_scale / world_offset / 任何调度状态，全部由调用方传入。
## 这是它能被两侧安全共享的前提 —— 一旦有状态，内核调用它就把视点信息拖进了内核。
## 单位约定：block 边长与分带半径都用**世界单位**（体素数 × voxel_scale），与 view_distance 同尺度。

## 一个 LOD block 覆盖的基础网格边长（体素数，= 一个 chunk 的边长）。
## 粗层 block 覆盖 GRID × 2^level 个体素。
const GRID := VoxelChunk.CHUNK_SIZE


## chunk 坐标 → 该层的 block 坐标（level 0 时 block == chunk）。
## 右移即"向下取整除法"，对负数同样成立（-1 >> 1 == -1）。
static func block_of_chunk(ck: Vector3i, level: int) -> Vector3i:
	return Vector3i(ck.x >> level, ck.y >> level, ck.z >> level)


## 该层 block 的世界边长（= GRID × 2^level 体素 × voxel_scale）
static func block_edge_world(level: int, voxel_scale: float) -> float:
	return voxel_scale * float(GRID << level)


## block 的世界中心（world_offset = 渲染节点自身的世界位置偏移）
static func block_center(bk: Vector3i, world_offset: Vector3, block_edge_world: float) -> Vector3:
	return world_offset + Vector3(bk) * block_edge_world + Vector3.ONE * block_edge_world * 0.5


## block 中心到相机的欧氏距离（统一 world_offset / block_edge 来源）。
## 注：粗层 needed 判定另有平方距离快路径（避免 sqrt），此函数供最终判定 / 排序复用。
static func block_dist(bk: Vector3i, level: int, cam_pos: Vector3, world_offset: Vector3, voxel_scale: float) -> float:
	return cam_pos.distance_to(block_center(bk, world_offset, block_edge_world(level, voxel_scale)))


## LOD 层滞回带宽（世界单位）= 半个 block 边长。
## 该层显示区 = block 距离 ∈ (inner - margin, outer + margin)：带滞回，
## 避免相机停在边界上时反复建/删（抖动闪烁）。
static func margin(level: int, voxel_scale: float) -> float:
	return block_edge_world(level, voxel_scale) * 0.5


## 粗层预生成提前量（世界单位）：preload_blocks 个本层 block 边长。
## level 0 不预生成（chunk 由流式加载逻辑负责）。
static func preload_extent(level: int, voxel_scale: float, preload_blocks: int) -> float:
	if level <= 0 or preload_blocks <= 0:
		return 0.0
	return block_edge_world(level, voxel_scale) * float(preload_blocks)


## 各层外半径（世界单位）：等比 ×2 分带，最外层恒等于 view_distance。
##   lod_count=1 → [D]（单层全距）
##   lod_count=2 → [D/4, D]（LOD0=[0,D/4]，LOD1=[D/4,D]）
##   lod_count=3 → [D/8, D/2, D]（LOD0=[0,D/8]，LOD1=[D/8,D/2]，LOD2=[D/2,D]）
##   lod_count=4 → [D/16, D/4, D/2, D]（以此类推，LOD0 随层数等比缩小）
## 【为什么 LOD0 是 D/2^n 而不是统一的 D/2^(n-1-i)】后者对 i=0 会多算一倍 —— 这是踩过的坑，
## 也是"LOD0 区"边界被取错导致"越改越近"的根因，故此处把两条公式分开写死。
## 几何意义：LOD0 全精度只覆盖最内层（近处精细），粗层自 LOD1 起逐级 ×2 到 D。
static func bands(view_distance: float, lod_count: int) -> Array[float]:
	var out: Array[float] = []
	var n := maxi(lod_count, 1)
	if n == 1:
		out.append(view_distance)
		return out
	for i in n:
		if i == 0:
			out.append(view_distance / pow(2.0, float(n)))
		else:
			out.append(view_distance / pow(2.0, float(n - 1 - i)))
	return out


## 该 chunk 区域应渲染的 LOD 层级（block 中心距离落在哪个分带）。
## 剔除（无限层）与 LOD 调度（内核）都要用它，故同样归入共享数学，避免任何一侧反向依赖。
## 用 lod_outer.size() 而非 lod_count，避免 lod_count 切换瞬间 lod_outer 未同步时越界。
static func chunk_render_level(ck: Vector3i, cam_pos: Vector3, world_offset: Vector3, voxel_scale: float, lod_outer: Array[float], lod_count: int) -> int:
	var n: int = mini(lod_outer.size(), maxi(lod_count, 1))
	if n <= 0:
		return 0
	for level in n:
		if block_dist(block_of_chunk(ck, level), level, cam_pos, world_offset, voxel_scale) <= lod_outer[level]:
			return level
	return n - 1
