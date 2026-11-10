class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区）
## 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格。
## 生成时始终输出所有非空 chunk 的完整 mesh，避免增量重建导致数据丢失。
## 支持在后台线程生成网格数据（generate_arrays_runtime），避免阻塞主线程。
## 自动跳过完全空的 chunk（空块提前终止）。
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数）——派生别名（权威源 VoxelChunk），供外部经 VoxelChunkGenerator.CHUNK_SIZE 访问
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE

## halo 体积别名（build_halo_from_buffers 校验 native 返回尺寸用）
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

## halo 边长（34 = CHUNK_SIZE + 2×HALO）。球体生成要遍历整块 halo，故需要它。
const HALO_SIZE := VoxelChunk.HALO_SIZE


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


## 从"光环缓冲"生成单个 chunk 的**球体**网格数据（每体素一颗小球）。
##
## 【为什么需要它】球体形状此前只有**导入路径**（VoxelMeshGenerator → generate_spheres_native）
## 支持，而运行时渲染走的是 generate_chunk_dense（只有方块面）。
## 于是"模型能导成球、运行时却只能显示方块"—— 同一份数据在两条路径上长得不一样。
## 本函数把球体能力补进运行时路径，两条路径共用同一原生内核。
##
## [param halo] 34³ 稠密光环（值 = 材质 ID，0 = 空）。用 halo 而不是 chunk 本体，
##   是为了让**跨 chunk 边界的内部体素也能被正确剔除**（否则边界上会多出看不见的球）。
## [param vertex_budget] 顶点预算：超出时原生按 step 抽稀（chunk 级一般用不到）。
##
## 【坐标约定】与方块路径完全一致：顶点在 **chunk 局部空间**，调用方把
## MeshInstance3D.position 设为 chunk_key × chunk_size × scale。
## 为此把 halo 的 (0..33) 平移到 (-1..32) 再交给原生（halo 的外缘就是邻块的最后一层）。
static func generate_spheres_for_chunk(halo: PackedInt32Array, aligned_materials: Array,
		scale: float, subdivisions: int = 0, sphere_scale: float = 1.0,
		vertex_budget: int = SPHERE_VERTEX_BUDGET,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if halo.size() != HALO_VOLUME:
		push_error("[VoxelChunkGenerator] 球体生成需要 34³ halo，实际 %d" % halo.size())
		return {}
	# 【只传 chunk 本体（局部 0..31），不传 halo 外缘】这是有意为之：
	# 原生 generate_spheres_native 的剔除规则是"相对**传入集合**是否外露"，
	# 把外缘邻居一起传进去，那些邻居格子自身也会被判为外露并画出来 ——
	# 而它们在相邻 chunk 里还会再画一遍（坐标不同），表现为**模型外面多出一层球**。
	# 只传本体时，chunk 边界上的体素会被判为外露而多画一颗球；
	# 但那颗球位于实体内部（邻居 chunk 是实心时才出现），被周围球挡住，只多花几个三角形。
	# 视觉结果与"完整剔除"一致，代价是一次可控的 overdraw。
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
	# 与方块路径同一约定：顶点 = (体素坐标 + offset) × scale。
	# 漏掉它会让球体整体偏掉一个模型尺寸 —— 这正是"球模式和其它形态位置对不上"的原因。
	# 原生内部会乘 scale，故这里传体素单位的 offset。
	return NativeLoader.generate_spheres_native(
			voxels, trans_flags, subdivisions, sphere_scale, scale, vertex_budget, offset)


## halo 外缘层数（1）。halo 局部坐标减去它 = chunk 局部坐标。
const HALO_INSET := 1

## 球体路径的默认顶点预算。20 面 icosphere = 12 顶点/球；32³ 全实心约 39 万顶点，故需要上限。
## 【给得比导入路径（400 万）小得多】运行时按 chunk 结算，单个 chunk 撑爆预算就会抽稀到出现空洞；
## 而一个 chunk 正常只有几千个表面球，20 万顶点已经足够。
const SPHERE_VERTEX_BUDGET := 200000


# 【已移除：顶点色 AO（逐顶点环境光遮蔽烘进 Mesh.ARRAY_COLOR）】
# 曾在本函数下方实现"按面外侧 3×3 九格数遮挡 → 灰度顶点色 → 材质侧
# vertex_color_use_as_albedo 乘进 albedo"，实测**观感更差**：体素表面本来就靠
# 硬边直角与方向光/投影读体积，AO 在每个凹角再压一层暗，结果是
# ① 大面出现不该有的亮度渐变（"面是平面"这条信息被抹掉）；
# ② 转角/缝隙糊成一团黑，体素颗粒反而看不清；③ 网格生成耗时涨 1.5~2 倍。
# 结论：本渲染器不提供几何级 AO。需要"凹处更暗"的场合请用**材质分档**
#（PcgSurfaceTint 那套：把凹处换成同色系更暗的一档体素）—— 那才是体素画法。
# 同时 VoxelMeshGenerator._configure_*_material 也不再开 vertex_color_use_as_albedo。



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


## 金字塔增量降采样：只重算 block 内 [rmin, rmax] 脏大格，未脏大格从 coarse 复用。
## 与其它几何内核一样**经本类统一入口**转发原生桥：调用方（渲染器）不应直接依赖
## NativeLoader，否则"几何内核统一走这里"的分层约定会被逐个直调侵蚀掉。
static func patch_lod_block(buffers: Dictionary, block_key: Vector3i, lod_shift: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	return NativeLoader.patch_lod_block(buffers, block_key, lod_shift, coarse, rmin, rmax)


## 逐级上推：当前层（lod>=2）从上一层 coarse 数据降采样。同上，统一入口。
static func patch_lod_block_from_lod(coarse_buffers: Dictionary, block_key: Vector3i, lod: int,
		coarse: PackedInt32Array, rmin: Vector3i, rmax: Vector3i) -> PackedInt32Array:
	return NativeLoader.patch_lod_block_from_lod(coarse_buffers, block_key, lod, coarse, rmin, rmax)


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


static func _make_arrays(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, idxs: PackedInt32Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs
	return arrays