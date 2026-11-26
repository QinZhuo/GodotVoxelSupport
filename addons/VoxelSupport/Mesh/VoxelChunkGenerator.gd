class_name VoxelChunkGenerator
extends RefCounted
## 高性能体素网格生成器（Chunk 分区）

## 单个 chunk 的边长（体素个数）——派生别名（权威源 VoxelChunk），供外部经…
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE

## halo 体积别名（build_halo_from_buffers 校验 native 返回尺寸用）
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

## halo 边长（34 = CHUNK_SIZE + 2×HALO）。
const HALO_SIZE := VoxelChunk.HALO_SIZE

## 后台线程安全的网格数据生成入口（不创建/修改 ArrayMesh，可在子线程运行）
static func generate_arrays_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {}) -> Variant:
	var scale: float = options.get("scale", 0.1)
	var offset: Vector3 = options.get("offset", Vector3.ZERO)
	var aligned := VoxelMaterial.align_by_id(materials)
	if not voxels is Dictionary or voxels.is_empty():
		return null
	var trans_flags := VoxelMaterial.build_trans_flags(aligned)
	return NativeLoader.generate_arrays_native(voxels, trans_flags, scale, offset)

## 将 generate_arrays_runtime 生成的字典数据组装为 ArrayMesh（必须在主线程调用）
static func build_mesh_from_arrays(arrays: Dictionary, materials: Array = []) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not VoxelMeshGenerator.append_arrays_to_mesh(mesh, arrays, materials):
		return null
	return mesh

## 从 chunk 缓冲字典（chunk key → PackedInt32Array，密集 CHUNK_SIZE³ = 32³）构建单个…
static func build_halo_from_buffers(buffers: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var native_halo := NativeLoader.build_halo_from_buffers(buffers, chunk)
	if native_halo.size() != HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 halo 尺寸异常：%d != %d" % [native_halo.size(), HALO_VOLUME])
	return native_halo

## 从"光环缓冲"生成单个 chunk 的网格数据（密集数组版，性能关键路径）
static func generate_single_chunk_dense(
		halo: PackedInt32Array, aligned_materials: Array, scale: float, chunk_key: Vector3i,
		offset: Vector3 = Vector3.ZERO, trans_flags: PackedByteArray = PackedByteArray()) -> Dictionary:
	if trans_flags.is_empty():
		trans_flags = VoxelMaterial.build_trans_flags(aligned_materials)
	var result: Dictionary = NativeLoader.generate_chunk_dense(halo, trans_flags, scale, chunk_key, true, offset)
	if result.get("solid_idxs", PackedInt32Array()).is_empty() and result.get("trans_idxs", PackedInt32Array()).is_empty():
		return {}
	return result

## 从"光环缓冲"生成单个 chunk 的**球体**网格数据（每体素一颗小球）。
static func generate_spheres_for_chunk(halo: PackedInt32Array, aligned_materials: Array,
		scale: float, subdivisions: int = 0, sphere_scale: float = 1.0,
		vertex_budget: int = SPHERE_VERTEX_BUDGET,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if halo.size() != HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 球体生成需要 34³ halo，实际 %d" % halo.size())
		return {}
	# 【只传 chunk 本体（局部 0..31），不传 halo 外缘】这是有意为之：
	var voxels := {}
	for lz in CHUNK_SIZE:
		for ly in CHUNK_SIZE:
			for lx in CHUNK_SIZE:
				var m: int = halo[(lx + HALO_INSET) + (ly + HALO_INSET) * HALO_SIZE
						+ (lz + HALO_INSET) * HALO_SIZE * HALO_SIZE]
				if m > 0:
					voxels[Vector3i(lx, ly, lz)] = m
	if voxels.is_empty():
		return {}
	var trans_flags := VoxelMaterial.build_trans_flags(aligned_materials)
	# 【offset 必须传】它是 QVoxelSource.center_offset（体素单位的原点偏移），
	return NativeLoader.generate_spheres_native(
			voxels, trans_flags, subdivisions, sphere_scale, scale, vertex_budget, offset)

## halo 外缘层数（1）。
const HALO_INSET := 1

## 球体路径的默认顶点预算。
const SPHERE_VERTEX_BUDGET := 200000

# 【不做顶点色 AO（逐顶点环境光遮蔽烘进 Mesh.ARRAY_COLOR）】

# LOD1 大块：32³ 大格（每大格 = 2³ 体素），覆盖 64³ 体素 = 2×2×2 LOD0…
const LOD_BLOCK_SIZE := VoxelChunk.CHUNK_SIZE
const LOD_BLOCK_HALO := 1
const LOD_BLOCK_HALO_SIZE := LOD_BLOCK_SIZE + LOD_BLOCK_HALO * 2
const LOD_BLOCK_HALO_VOLUME := LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE

## 从 chunk 缓冲快照构建 LOD 大块的 34³ 大格 halo（纯函数，供异步 worker，线程安全）。
static func build_lod_block_halo_from_buffers(buffers: Dictionary, block_key: Vector3i, lod_shift: int = 1) -> PackedInt32Array:
	var native_halo := NativeLoader.build_lod_block_halo_from_buffers_native(buffers, block_key, lod_shift)
	if native_halo.size() != LOD_BLOCK_HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 LOD halo 尺寸异常：%d != %d" % [native_halo.size(), LOD_BLOCK_HALO_VOLUME])
	return native_halo

## 从独立 LOD 数据块（每 LOD 32³ 大格，值 = 材质ID）构建 34³ halo（无降采样，直接拷大格）：
static func build_lod_block_halo_from_lod_buffers(buffers: Dictionary, block_key: Vector3i) -> PackedInt32Array:
	var native_halo := NativeLoader.build_lod_block_halo_from_lod_buffers_native(buffers, block_key)
	if native_halo.size() != LOD_BLOCK_HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 LOD halo 尺寸异常：%d != %d" % [native_halo.size(), LOD_BLOCK_HALO_VOLUME])
	return native_halo

## 生成 LOD 大块网格（一次性 32³ 大格，原生 generate_lod1_block_dense /…
static func generate_lod_block_arrays(
		lod_halo: PackedInt32Array, aligned_materials: Array, scale: float, block_key: Vector3i,
		offset: Vector3 = Vector3.ZERO, lod_shift: int = 1) -> Dictionary:
	var trans_flags := VoxelMaterial.build_trans_flags(aligned_materials)
	var result: Dictionary
	if lod_shift == 1:
		result = NativeLoader.generate_lod1_block_dense(lod_halo, trans_flags, scale * 2.0, block_key, offset)
	else:
		result = NativeLoader.generate_chunk_dense(lod_halo, trans_flags, scale * float(1 << lod_shift), block_key, true, offset)
	if result.get("solid_idxs", PackedInt32Array()).is_empty() and result.get("trans_idxs", PackedInt32Array()).is_empty():
		return {}
	return result

## 金字塔增量降采样：只重算 block 内 [rmin, rmax] 脏大格，未脏大格从 coarse 复用。
static func patch_lod_block(buffers: Dictionary, block_key: Vector3i, lod_shift: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	return NativeLoader.patch_lod_block(buffers, block_key, lod_shift, coarse, rmin, rmax)

## 逐级上推：当前层（lod>=2）从上一层 coarse 数据降采样。
static func patch_lod_block_from_lod(coarse_buffers: Dictionary, block_key: Vector3i, lod: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	return NativeLoader.patch_lod_block_from_lod(coarse_buffers, block_key, lod, coarse, rmin, rmax)
