class_name VoxelChunk
extends RefCounted
## Chunk 几何常量的唯一权威源 + 共享坐标换算。
##
## VoxelData 与 VoxelChunkGenerator 通过别名引用这里的常量，
## 防止两边重复定义导致漂移（如 HALO_SIZE 写错 → 光环下标 Y/Z 步长错位）。
## 两种线性下标约定：
##   缓冲下标   = lx + ly*CHUNK_SIZE + lz*CHUNK_SLICE       （16³ 密集缓冲）
##   光环下标   = lx + ly*HALO_SIZE + lz*HALO_SIZE*HALO_SIZE （18³ 光环缓冲）
## 其中 lx/ly/lz 为局部坐标（chunk 内 0..CS-1；光环内 0..HS-1）。

const CHUNK_SIZE := 16
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
## 单个 z 切片面积（缓冲线性化步长）
const CHUNK_SLICE := CHUNK_SIZE * CHUNK_SIZE
## CHUNK_SIZE=16=2⁴ 的移位量（chunk_of 用算术右移替代浮点除法）
const CHUNK_SHIFT := 4

## 外缘层数（跨界面的面可见性需要紧邻体素）
const HALO := 1
## 含外缘的光环缓冲边长（18）
const HALO_SIZE := CHUNK_SIZE + HALO * 2
const HALO_VOLUME := HALO_SIZE * HALO_SIZE * HALO_SIZE


## 体素坐标 → 所在 chunk（算术右移向下取整，正确处理负坐标）
## CHUNK_SIZE=16=2⁴ → 用 >> CHUNK_SHIFT 替代 floori(float/16)，热路径零浮点开销
## GDScript 的 >> 对负数执行算术右移（向下取整），与 floori(float/16) 语义完全一致：
##   例: pos=-17 → floori(-17/16)=-2, -17>>4=-2 ✓
static func chunk_of(pos: Vector3i) -> Vector3i:
	return Vector3i(
		pos.x >> CHUNK_SHIFT,
		pos.y >> CHUNK_SHIFT,
		pos.z >> CHUNK_SHIFT
	)


## chunk → 世界坐标原点
static func origin_of(chunk: Vector3i) -> Vector3i:
	return chunk * CHUNK_SIZE


## 局部坐标分量 → 缓冲线性下标（覆盖 0..CHUNK_VOLUME-1）
static func buf_index(lx: int, ly: int, lz: int) -> int:
	return lx + ly * CHUNK_SIZE + lz * CHUNK_SLICE


## 缓冲线性下标 → 局部坐标
static func local_from_index(i: int) -> Vector3i:
	return Vector3i(
		i % CHUNK_SIZE,
		(i / CHUNK_SIZE) % CHUNK_SIZE,
		i / CHUNK_SLICE
	)


## 光环局部坐标分量 → 光环线性下标（lx/ly/lz ∈ [0, HALO_SIZE)）
static func halo_index(lx: int, ly: int, lz: int) -> int:
	return lx + ly * HALO_SIZE + lz * HALO_SIZE * HALO_SIZE


## 世界坐标 + chunk 原点 → 光环线性下标
static func halo_index_world(wx: int, wy: int, wz: int, origin: Vector3i) -> int:
	return halo_index(wx - origin.x + HALO, wy - origin.y + HALO, wz - origin.z + HALO)
