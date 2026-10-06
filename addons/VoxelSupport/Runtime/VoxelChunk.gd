class_name VoxelChunk
extends RefCounted
## Chunk 几何常量的唯一权威源 + 共享坐标换算。
##
## VoxelData 与 VoxelChunkGenerator 通过别名引用这里的常量，
## 防止两边重复定义导致漂移（如 HALO_SIZE 写错 → 光环下标 Y/Z 步长错位）。
## 两种线性下标约定：
##   缓冲下标   = lx + ly*CHUNK_SIZE + lz*CHUNK_SLICE       （32³ 密集缓冲）
##   光环下标   = lx + ly*HALO_SIZE + lz*HALO_SIZE*HALO_SIZE （34³ 光环缓冲）
## 其中 lx/ly/lz 为局部坐标（chunk 内 0..CS-1；光环内 0..HS-1）。

const CHUNK_SIZE := 32
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
## 单个 z 切片面积（缓冲线性化步长）
const CHUNK_SLICE := CHUNK_SIZE * CHUNK_SIZE
## CHUNK_SIZE=32=2⁵ 的移位量（chunk_of 用算术右移替代浮点除法）
const CHUNK_SHIFT := 5

## 外缘层数（跨界面的面可见性需要紧邻体素）
const HALO := 1
## 含外缘的光环缓冲边长（34）
const HALO_SIZE := CHUNK_SIZE + HALO * 2
const HALO_VOLUME := HALO_SIZE * HALO_SIZE * HALO_SIZE


## 体素坐标 → 所在 chunk（算术右移向下取整，正确处理负坐标）
## CHUNK_SIZE=32=2⁵ → 用 >> CHUNK_SHIFT 替代 floori(float/32)，热路径零浮点开销
## GDScript 的 >> 对负数执行算术右移（向下取整），与 floori(float/32) 语义完全一致：
##   例: pos=-33 → floori(-33/32)=-2, -33>>5=-2 ✓
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


# ----------------------------------------------------------------------------
# 坐标键字典平移（origin shift）
# ----------------------------------------------------------------------------

## 把"以 chunk / block 坐标为键"的字典整体平移。
## **全项目唯一实现**：VoxelData / VoxelAsyncLoader / VoxelRenderer 曾各有一套同名静态函数，
## 三者实现逐字符相同——任一处改动漏改另一处，症状是"平移后某几张表仍指旧坐标"（脏标记、
## 去重集合、在途登记各自脱节），极难定位。收在这里与坐标换算同源。
static func shift_key_dict(d: Dictionary, offset: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + offset] = d[k]
	return nd


# ----------------------------------------------------------------------------
# LOD 大块几何
# ----------------------------------------------------------------------------
# 约定（见 VoxelData.LOD_GRID / VoxelChunkGenerator.LOD_BLOCK_SIZE）：
#   LOD 大块 = CHUNK_SIZE³ 个大格，每格代表 2^lod 体素。
#   故边长 = CHUNK_SIZE × 2^lod 体素 → 每轴覆盖 2^lod 个 LOD0 chunk。
# 这两个函数是"哪些 LOD0 chunk 属于某个 LOD 大块"的唯一权威算法：
# 降采样（哪些 chunk 作为输入）与派生缓存的来源校验（source_crc 覆盖哪些 chunk）
# 必须用同一套坐标，否则缓存会在来源没变时被判失效（或反之，更糟）。

## lod（>=1）大块每轴覆盖的 LOD0 chunk 数。
static func lod_chunks_per_axis(lod: int) -> int:
	return 1 << maxi(lod, 0)


## lod（>=1）大块 block_key 覆盖的全部 LOD0 chunk 坐标（ZYX 遍历，确定性顺序）。
static func lod_covered_chunks(block_key: Vector3i, lod: int) -> Array[Vector3i]:
	var span := lod_chunks_per_axis(lod)
	var base := block_key * span
	var out: Array[Vector3i] = []
	for dz in span:
		for dy in span:
			for dx in span:
				out.append(base + Vector3i(dx, dy, dz))
	return out


## 从光环缓冲（34³）中抽取中心块（去掉 HALO 外缘一圈），返回紧凑缓冲（CHUNK_VOLUME）。
## 供 LOD 大块降采样等复用，避免各处重复手写光环下标公式（下标步长漂移风险）。
static func extract_center_from_halo(halo: PackedInt32Array) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(CHUNK_VOLUME)
	for lz in CHUNK_SIZE:
		for ly in CHUNK_SIZE:
			for lx in CHUNK_SIZE:
				buf[buf_index(lx, ly, lz)] = halo[halo_index(HALO + lx, HALO + ly, HALO + lz)]
	return buf
