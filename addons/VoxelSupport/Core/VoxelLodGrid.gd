class_name VoxelLodGrid
extends RefCounted

## LOD 分带的**纯几何数学**：block 划分 / 层边长 / block 中心距 / 滞回带 / 预生成量 / 分带公式。

## 一个 LOD block 覆盖的基础网格边长（体素数，= 一个 chunk 的边长）。
const GRID := VoxelChunk.CHUNK_SIZE

## chunk 坐标 → 该层的 block 坐标（level 0 时 block == chunk）。
static func block_of_chunk(ck: Vector3i, level: int) -> Vector3i:
	return Vector3i(ck.x >> level, ck.y >> level, ck.z >> level)

## 该层 block 的世界边长（= GRID × 2^level 体素 × voxel_scale）
static func block_edge_world(level: int, voxel_scale: float) -> float:
	return voxel_scale * float(GRID << level)

## block 的世界中心（world_offset = 渲染节点自身的世界位置偏移）
static func block_center(bk: Vector3i, world_offset: Vector3, block_edge_world: float) -> Vector3:
	return world_offset + Vector3(bk) * block_edge_world + Vector3.ONE * block_edge_world * 0.5

## block 中心到相机的**平方**欧氏距离。
static func block_dist_sq(bk: Vector3i, level: int, cam_pos: Vector3, world_offset: Vector3, voxel_scale: float) -> float:
	return cam_pos.distance_squared_to(block_center(bk, world_offset, block_edge_world(level, voxel_scale)))

## block 中心到相机的欧氏距离（统一 world_offset / block_edge 来源）。
static func block_dist(bk: Vector3i, level: int, cam_pos: Vector3, world_offset: Vector3, voxel_scale: float) -> float:
	return sqrt(block_dist_sq(bk, level, cam_pos, world_offset, voxel_scale))

## LOD 层滞回带宽（世界单位）= 半个 block 边长。
static func margin(level: int, voxel_scale: float) -> float:
	return block_edge_world(level, voxel_scale) * 0.5

## 粗层预生成提前量（世界单位）：preload_blocks 个本层 block 边长。
static func preload_extent(level: int, voxel_scale: float, preload_blocks: int) -> float:
	if level <= 0 or preload_blocks <= 0:
		return 0.0
	return block_edge_world(level, voxel_scale) * float(preload_blocks)

## 各层外半径（世界单位）：等比 ×2 分带，最外层恒等于 view_distance。
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
static func chunk_render_level(ck: Vector3i, cam_pos: Vector3, world_offset: Vector3, voxel_scale: float, lod_outer: Array[float], lod_count: int) -> int:
	var n: int = mini(lod_outer.size(), maxi(lod_count, 1))
	if n <= 0:
		return 0
	for level in n:
		if block_dist(block_of_chunk(ck, level), level, cam_pos, world_offset, voxel_scale) <= lod_outer[level]:
			return level
	return n - 1
