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
		offset: Vector3 = Vector3.ZERO, trans_flags: PackedByteArray = PackedByteArray(),
		ao_strength: float = 0.0, ao_min: float = 0.4) -> Dictionary:
	if trans_flags.is_empty():
		trans_flags = VoxelMaterial.build_trans_flags(aligned_materials)
	var result: Dictionary = NativeLoader.generate_chunk_dense(halo, trans_flags, scale, chunk_key, true, offset)
	if result.get("solid_idxs", PackedInt32Array()).is_empty() and result.get("trans_idxs", PackedInt32Array()).is_empty():
		return {}
	# 顶点色 AO：本函数是运行时 chunk 路径（VoxelRenderer._generate_chunk_worker，子线程）
	# 与导入路径共用的最后一道几何入口，故 AO 放这里可一次覆盖两条路径。
	# 纯读 halo + 写结果字典，无共享状态，子线程安全。
	if ao_strength > 0.0:
		var sv: PackedVector3Array = result.get("solid_verts", PackedVector3Array())
		if not sv.is_empty():
			result["solid_colors"] = generate_ao_colors(halo, sv,
					result["solid_normals"], scale, offset, chunk_key,
					ao_strength, ao_min, true)
	return result


## 逐顶点面环境光遮蔽（AO），输出 Mesh.ARRAY_COLOR 用的灰度顶点色。
##
## 【为什么必须有顶点色】体素材质是"256×1 调色板 + UV 查表"的单色方案，整面只有
## 一个颜色；而体素观感里很大一部分立体感来自"凹处自阴影"。烘进顶点色后，
## 材质侧只需开 vertex_color_use_as_albedo（见 VoxelMeshGenerator._configure_*_material）
## 即可对所有材质统一生效，不必为每种材质写一套 shader。
##
## 【采样语义：看"面外侧被谁挡住"】对每个顶点，取它所属面**外侧**那一层的 3×3
## 九格（沿法线紧邻的一格 + 环绕 8 格），数其中有几格是实体：
##   平坦大面 → 九格全是空气 → AO = 1（亮）
##   墙内转角 → 2~3 格被挡 → 变暗
##   凹槽 / 缝隙 → 8 格几乎都被挡 → 最暗
## 这里不能用"沿法线采样 6 邻域"：暴露面沿法线必然是空气，6 邻域几乎恒为 5，
## 算不出任何对比度。
##
## 【halo 恰好够用】halo 是 34³（chunk 32³ 加 1 圈外缘），本采样最远触及 chunk
## 局部 -1 / 32，正好落在外缘层内，无需跨 chunk 查询。仅当 chunk 最外一格的面
## 朝外时才会探出 halo，此时按"不遮挡"处理（保守，且只影响整场景最外一圈体素）。
##
## 【顶点 → 体素的反推】顶点恰在体素边界上，朝法线那侧是空气，故所属实心体素
## 沿法线轴退一格（n > 0 时 -1），切向轴取 floor。切向轴对"贪婪合并出的大 quad"
## 会偏出该 quad 覆盖的体素范围，但外侧九格在开阔处都是空气、结果仍为 AO = 1；
## 而真正需要 AO 的地方（墙角、凹槽）quad 都很小、不会被合并，故误差无害。
##
## 【为什么不做 26 邻域】对比度更好，但每顶点 26 次采样。这里 8 次，
## 在 GDScript 里顶点数上万时差距是数量级的。
##
## 【为什么不做平滑逐顶点插值】合并 quad 只有 4 个顶点，插值天然形成"面内渐变"，
## 已足够；不做逐体素细分是因为那会让 AO 反而丢掉"面是平面"的信息。
static func generate_ao_colors(halo: PackedInt32Array, verts: PackedVector3Array,
		normals: PackedVector3Array, scale: float, offset: Vector3, chunk_key: Vector3i,
		strength: float, min_ao: float, local_space: bool) -> PackedColorArray:
	var colors := PackedColorArray()
	var n_verts := verts.size()
	colors.resize(n_verts)
	if n_verts == 0 or scale == 0.0 or verts.size() != normals.size():
		return colors
	var inv_scale := 1.0 / scale
	# use_local_space = true 时原生已把 chunk 原点减掉（顶点是 chunk 局部坐标）；
	# = false 时是世界坐标，需再减去 chunk 原点才能落到 halo 索引上。
	var chunk_origin := Vector3.ZERO
	if not local_space:
		chunk_origin = Vector3(chunk_key * VoxelChunk.CHUNK_SIZE)
	var hs := VoxelChunk.HALO_SIZE
	var h_max := hs - 1
	var h_stride_z := hs * hs
	var inv8 := strength / 8.0
	for i in n_verts:
		var lp := (verts[i] - offset) * inv_scale - chunk_origin
		# 由法线分出"法线轴 n"与"两个切向轴 u/v"，直接写成单位向量免去后续推导
		var n := normals[i]
		var ax := absf(n.x)
		var ay := absf(n.y)
		var az := absf(n.z)
		var nx := 0
		var ny := 0
		var nz := 0
		var ux := 0
		var uy := 0
		var uz := 0
		var vx := 0
		var vy := 0
		var vz := 0
		if ax > 0.5:
			nx = 1 if n.x > 0.0 else -1
			uy = 1
			vz = 1
		elif ay > 0.5:
			ny = 1 if n.y > 0.0 else -1
			ux = 1
			vz = 1
		else:
			nz = 1 if n.z > 0.0 else -1
			ux = 1
			uy = 1
		var px := floori(lp.x) - (1 if nx > 0 else 0)
		var py := floori(lp.y) - (1 if ny > 0 else 0)
		var pz := floori(lp.z) - (1 if nz > 0 else 0)
		# 面外侧那一层的中心格
		var cx := px + nx
		var cy := py + ny
		var cz := pz + nz
		var occ := 0
		for su in 3:
			var du := su - 1
			for sv in 3:
				if su == 1 and sv == 1:
					continue
				var dv := sv - 1
				var hx := cx + ux * du + vx * dv + VoxelChunk.HALO
				var hy := cy + uy * du + vy * dv + VoxelChunk.HALO
				var hz := cz + uz * du + vz * dv + VoxelChunk.HALO
				if hx < 0 or hy < 0 or hz < 0 or hx > h_max or hy > h_max or hz > h_max:
					continue
				if halo[hx + hy * hs + hz * h_stride_z] > 0:
					occ += 1
		var ao := clampf(1.0 - inv8 * float(occ), min_ao, 1.0)
		colors[i] = Color(ao, ao, ao)
	return colors


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
			_make_arrays(arrays.get("solid_verts"), arrays.get("solid_normals"), arrays.get("solid_uvs"), solid_idxs, arrays.get("solid_colors")))
		has_any = true
	if not trans_idxs.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_make_arrays(arrays.get("trans_verts"), arrays.get("trans_normals"), arrays.get("trans_uvs"), trans_idxs))
		has_any = true
	if not has_any:
		return null
	return result


## colors 为可选的 AO 顶点色（见 generate_ao_colors）；为空或长度不匹配时
## 不写入 ARRAY_COLOR —— 材质侧 vertex_color_use_as_albedo 在缺该通道时按白色处理。
static func _make_arrays(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, idxs: PackedInt32Array,
		colors: Variant = null) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if colors is PackedColorArray and (colors as PackedColorArray).size() == verts.size() and not verts.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idxs
	return arrays