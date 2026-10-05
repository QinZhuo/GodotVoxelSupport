class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区）
##
## 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格。
## 生成时始终输出所有非空 chunk 的完整 mesh，避免增量重建导致数据丢失。
## 支持在后台线程生成网格数据（generate_arrays_runtime），避免阻塞主线程。
## 自动跳过完全空的 chunk（空块提前终止）。
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数）——派生别名（权威源 VoxelChunk），供外部经 VoxelChunkGenerator.CHUNK_SIZE 访问
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE

## halo 体积别名（build_halo_from_buffers 校验 native 返回尺寸用）
const HALO_VOLUME := VoxelChunk.HALO_VOLUME


## 后台线程安全的网格数据生成入口（不创建/修改 ArrayMesh，可在子线程运行）
## 返回一个 Dictionary 或 null：
##   {
##     "solid_verts": PackedVector3Array, "solid_normals": PackedVector3Array,
##     "solid_uvs": PackedVector2Array, "solid_idxs": PackedInt32Array,
##     "trans_verts": PackedVector3Array, "trans_normals": PackedVector3Array,
##     "trans_uvs": PackedVector2Array, "trans_idxs": PackedInt32Array,
##   }
## 返回 null 表示没有任何可渲染的面（全空）
## 实现完全在 GDExtension (C++) 中（generate_arrays_native：分 chunk + 原生 dense 面生成 + 合并），
## 无 GDScript 兜底。
static func generate_arrays_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> Variant:
	var scale: float = options.get("scale", 0.1)
	var offset: Vector3 = options.get("offset", Vector3.ZERO)
	var aligned := VoxelMaterial.align_by_id(materials)
	if not voxels is Dictionary or voxels.is_empty():
		return null
	var trans_flags := VoxelMaterial.build_trans_flags(aligned)
	return NativeLoader.generate_arrays_native(voxels, trans_flags, scale, offset)


## 将 generate_arrays_runtime 生成的字典数据组装为 ArrayMesh（必须在主线程调用）
static func build_mesh_from_arrays(arrays: Dictionary) -> ArrayMesh:
	return _merge_meshes(arrays)


## 从 chunk 缓冲字典（chunk key → PackedInt32Array，密集 32³）构建单个 chunk 的 18³ 光环缓冲
## 线程安全：buffers 必须是调用方提供的独立快照（深拷贝），子线程内只读。
## 供异步 worker 在子线程内直接从快照构建 halo，避免主线程逐 chunk 提取的阻塞。
## 实现完全在 GDExtension (C++) 中（build_halo_from_buffers），无 GDScript 兜底。
static func build_halo_from_buffers(buffers: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var native_halo := NativeLoader.build_halo_from_buffers(buffers, chunk)
	if native_halo.size() != HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 halo 尺寸异常：%d != %d" % [native_halo.size(), HALO_VOLUME])
	return native_halo


## 从"光环缓冲"生成单个 chunk 的网格数据（密集数组版，性能关键路径）
## halo 为 34³ 密集缓冲（统一材质契约：值 = 材质ID，0 = 空），由 build_halo_from_buffers 提供。
## 覆盖 chunk 内部 + 1 体素外缘，所有邻居读取均为数组下标且无越界检查。
## 线程安全：halo 是独立的深拷贝，子线程只读。
## trans_flags 可由调用方预计算传入（逐块重建它要扫一遍材质表，批量构建时应只算一次）；
## 传空则内部按 aligned_materials 现算。
## 返回 {solid_verts, solid_normals, solid_uvs, solid_idxs, trans_verts, ...} 或 {}（空块）
## 实现完全在 GDExtension (C++) 中（NativeLoader.generate_chunk_dense），无 GDScript 兜底。
static func generate_single_chunk_dense(
		halo: PackedInt32Array, aligned_materials: Array, scale: float, chunk_key: Vector3i,
		offset: Vector3 = Vector3.ZERO, trans_flags: PackedByteArray = PackedByteArray()) -> Dictionary:
	if trans_flags.is_empty():
		trans_flags = VoxelMaterial.build_trans_flags(aligned_materials)
	var result: Dictionary = NativeLoader.generate_chunk_dense(halo, trans_flags, scale, chunk_key, true, offset)
	if result.get("solid_idxs", PackedInt32Array()).is_empty() and result.get("trans_idxs", PackedInt32Array()).is_empty():
		return {}
	return result


# LOD1 大块：32³ 大格（每大格 = 2³ 体素），覆盖 64³ 体素 = 2×2×2 LOD0 chunk（CHUNK_SIZE=32 时）。
# LOD 大块：LOD_BLOCK_SIZE³ 大格（每大格 = 2^lod_shift 体素），覆盖 (LOD_BLOCK_SIZE×2^lod_shift)³ 体素。
#   lod_shift=1：32³ 大格覆盖 64³ 体素 = 2×2×2 chunk（CHUNK_SIZE=32 时），即原 LOD1。
#   lod_shift=i：每格 2^i 体素 → 大块边长 32×2^i 体素（32→64→128→…）。
const LOD_BLOCK_SIZE := VoxelChunk.CHUNK_SIZE
const LOD_BLOCK_HALO := 1
const LOD_BLOCK_HALO_SIZE := LOD_BLOCK_SIZE + LOD_BLOCK_HALO * 2
const LOD_BLOCK_HALO_VOLUME := LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE


## 从 chunk 缓冲快照构建 LOD 大块的 34³ 大格 halo（纯函数，供异步 worker，线程安全）。
## 中心 32³ 大格 = 大块内部（降采样 2^lod_shift³ 体素 → 1 大格，取非空材质）；
## 6 外缘面 = 相邻大块边界 1 大格层（跨界可见性）。
## 实现完全在 GDExtension (C++) 中（build_lod_block_halo_from_buffers_native），无 GDScript 兜底。
static func build_lod_block_halo_from_buffers(buffers: Dictionary, block_key: Vector3i, lod_shift: int = 1) -> PackedInt32Array:
	var native_halo := NativeLoader.build_lod_block_halo_from_buffers_native(buffers, block_key, lod_shift)
	if native_halo.size() != LOD_BLOCK_HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 LOD halo 尺寸异常：%d != %d" % [native_halo.size(), LOD_BLOCK_HALO_VOLUME])
	return native_halo


## 从独立 LOD 数据块（每 LOD 32³ 大格，值 = 材质ID）构建 34³ halo（无降采样，直接拷大格）：
## 中心 32³ = block 自身；6 外缘面 = 相邻 block 边界 1 大格层（跨界可见性）。
## Voxel Tools 式独立数据层的网格化入口：粗层 mesh 直接由大格数据生成，无需 LOD0 chunk。
## 实现完全在 GDExtension (C++) 中（build_lod_block_halo_from_lod_buffers_native），无 GDScript 兜底。
static func build_lod_block_halo_from_lod_buffers(buffers: Dictionary, block_key: Vector3i) -> PackedInt32Array:
	var native_halo := NativeLoader.build_lod_block_halo_from_lod_buffers_native(buffers, block_key)
	if native_halo.size() != LOD_BLOCK_HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 原生返回的 LOD halo 尺寸异常：%d != %d" % [native_halo.size(), LOD_BLOCK_HALO_VOLUME])
	return native_halo


## 生成 LOD 大块网格（一次性 32³ 大格，原生 generate_lod1_block_dense / generate_chunk_dense）。
## scale = voxel_scale；每大格世界尺寸 = scale × 2^lod_shift，MeshInstance3D 位置应设为
## block_key × (32 × 2^lod_shift) × voxel_scale。
## lod_shift=1 沿用 generate_lod1_block_dense；更高层复用 generate_chunk_dense
## （同一 32³ 网格核心 generate_dense_impl，仅 scale/格数不同）。
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


## 将生成的网格数据组装为 ArrayMesh（必须在主线程调用，会修改 ArrayMesh）
static func _merge_meshes(arrays: Dictionary) -> ArrayMesh:
	var result := ArrayMesh.new()
	var has_any := false
	var solid_idxs: PackedInt32Array = arrays.get("solid_idxs", PackedInt32Array())
	var trans_idxs: PackedInt32Array = arrays.get("trans_idxs", PackedInt32Array())
	if not solid_idxs.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_make_arrays(arrays.get("solid_verts"), arrays.get("solid_normals"), arrays.get("solid_uvs"), solid_idxs))
		has_any = true
	if not trans_idxs.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_make_arrays(arrays.get("trans_verts"), arrays.get("trans_normals"), arrays.get("trans_uvs"), trans_idxs))
		has_any = true
	if not has_any:
		return null
	return result


static func _make_arrays(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, idxs: PackedInt32Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs
	return arrays