class_name VoxelChunk
extends RefCounted
## Chunk 几何常量的唯一权威源 + 共享坐标换算。

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

# 坐标键字典平移（origin shift）

## 把"以 chunk / block 坐标为键"的字典整体平移（origin shift）。
static func shift_key_dict(d: Dictionary, offset: Vector3i) -> Dictionary:
	var nd := {}
	for k in d:
		nd[Vector3i(k) + offset] = d[k]
	return nd

## 把"位置列表"（Array[Vector3i]）整体平移（origin shift）。
static func shift_positions(positions: Array, offset: Vector3i) -> Array:
	if positions.is_empty():
		return []
	var out: Array = []
	out.resize(positions.size())
	for i in positions.size():
		out[i] = Vector3i(positions[i]) + offset
	return out

# LOD 大块几何

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
static func extract_center_from_halo(halo: PackedInt32Array) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(CHUNK_VOLUME)
	for lz in CHUNK_SIZE:
		for ly in CHUNK_SIZE:
			for lx in CHUNK_SIZE:
				buf[buf_index(lx, ly, lz)] = halo[halo_index(HALO + lx, HALO + ly, HALO + lz)]
	return buf
