class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区）
##
## 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格。
## 生成时始终输出所有非空 chunk 的完整 mesh，避免增量重建导致数据丢失。
## 支持在后台线程生成网格数据（generate_arrays_runtime），避免阻塞主线程。
## 自动跳过完全空的 chunk（空块提前终止）。
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数），chunk 越大网格合并效率越高但增量重建粒度越粗
## Chunk 几何常量唯一权威源见 VoxelChunk，此处全部派生别名防止漂移
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const CHUNK_SLICE := VoxelChunk.CHUNK_SLICE
const HALO := VoxelChunk.HALO
const HALO_SIZE := VoxelChunk.HALO_SIZE
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

# 6 个面在光环缓冲中的邻居下标偏移（对应 FaceTool.Normals 顺序）
# 光环下标 = x + y*HALO_SIZE + z*HALO_SIZE*HALO_SIZE，故 ±X=±1, ±Y=±HS, ±Z=±HS²
const _HALO_DIRS: Array[int] = [
	HALO_SIZE,               # +Y (0, 1, 0)
	-HALO_SIZE,              # -Y (0,-1, 0)
	-1,                      # -X (-1,0, 0)
	1,                       # +X ( 1,0, 0)
	HALO_SIZE * HALO_SIZE,   # +Z (0, 0, 1)
	-HALO_SIZE * HALO_SIZE,  # -Z (0, 0,-1)
]


## 提取单个 chunk 及其 1 体素外缘(shell) 的体素快照（绝对坐标键）
## 网格生成只需要该 chunk 内部 + 跨界面的相邻体素，无需拷贝整个世界的体素字典。
## 返回独立的 Dictionary，供子线程安全读取（主线程后续增删不会影响它）。
## halo_voxels: 外扩层数，默认 1（跨界面的面可见性需要紧邻体素）
static func slice_chunk(voxels: Dictionary, chunk: Vector3i, halo_voxels: int = 1) -> Dictionary:
	var origin := VoxelChunk.origin_of(chunk)
	var slice := {}
	var lo := origin - Vector3i(halo_voxels, halo_voxels, halo_voxels)
	var hi := origin + Vector3i(CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE) + Vector3i(halo_voxels - 1, halo_voxels - 1, halo_voxels - 1)
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var p := Vector3i(x, y, z)
				if voxels.has(p):
					slice[p] = voxels[p]
	return slice


## 运行时网格生成入口，在主线程调用
## 始终生成所有非空 chunk，确保输出完整 mesh。rebuild_chunks 参数保留用于 API 兼容。
static func generate_mesh_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> ArrayMesh:
	var arrays: Variant = generate_arrays_runtime(voxels, materials, options, rebuild_chunks)
	if arrays == null:
		return null
	return _merge_meshes(arrays as Dictionary)


## 后台线程安全的网格数据生成入口（不创建/修改 ArrayMesh，可在子线程运行）
## 返回一个 Dictionary 或 null：
##   {
##     "solid_verts": PackedVector3Array, "solid_normals": PackedVector3Array,
##     "solid_uvs": PackedVector2Array, "solid_idxs": PackedInt32Array,
##     "trans_verts": PackedVector3Array, "trans_normals": PackedVector3Array,
##     "trans_uvs": PackedVector2Array, "trans_idxs": PackedInt32Array,
##   }
## 返回 null 表示没有任何可渲染的面（全空）
static func generate_arrays_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> Variant:
	var scale: float = options.get("scale", 0.1)
	var offset: Vector3 = options.get("offset", Vector3.ZERO)
	var aligned := VoxelMaterial.align_by_id(materials)

	# 原生快路径：稀疏体素字典 → 网格 arrays（掉落体大块/大范围破坏核心全 C++：分 chunk + 原生
	# dense 面生成 + 合并）。无原生（旧库）时回退下方 GDScript 多 chunk 实现。
	if voxels is Dictionary and not voxels.is_empty() and NativeLoader.is_available():
		var trans_flags := _build_trans_flags(aligned)
		var native := NativeLoader.generate_arrays_native(voxels, trans_flags, scale, offset)
		if native != null and not native.is_empty():
			return native

	# 一次遍历 voxels，建立"非空 chunk"哈希索引（避免逐 chunk 16³ 扫描）
	var non_empty := _build_non_empty_chunk_index(voxels)

	# 必须重建所有非空 chunk，确保输出的 mesh 包含完整场景。
	# 增量重建（只重建部分 chunk）会导致其他 chunk 的数据丢失，
	# 因为生成的 mesh 会完全替换之前的 mesh。
	var chunk_keys: Array[Vector3i] = _all_non_empty_chunks_from_index(non_empty)

	if chunk_keys.is_empty():
		return null

	# 合并所有 chunk 的面片
	var all_solid_verts := PackedVector3Array()
	var all_solid_normals := PackedVector3Array()
	var all_solid_uvs := PackedVector2Array()
	var all_solid_idxs := PackedInt32Array()
	var all_trans_verts := PackedVector3Array()
	var all_trans_normals := PackedVector3Array()
	var all_trans_uvs := PackedVector2Array()
	var all_trans_idxs := PackedInt32Array()

	for ck in chunk_keys:
		# 复用原生 C++ greedy 面生成（generate_single_chunk_dense）替代 GDScript 面生成，
		# 掉落体大块 / 大范围破坏重建的核心耗时下沉 C++（原生 chunk 局部坐标 → 合并时加 chunk 世界偏移）
		var halo := _halo_from_dict(voxels, ck)
		var arr := generate_single_chunk_dense(halo, aligned, scale, ck, offset)
		if arr != null and not arr.is_empty():
			var chunk_world := Vector3(ck) * (scale * float(VoxelChunk.CHUNK_SIZE)) + offset
			_append_offset_arrays(all_solid_verts, all_solid_normals, all_solid_uvs, all_solid_idxs, arr, "solid", chunk_world)
			_append_offset_arrays(all_trans_verts, all_trans_normals, all_trans_uvs, all_trans_idxs, arr, "trans", chunk_world)

	if all_solid_idxs.is_empty() and all_trans_idxs.is_empty():
		return null

	return {
		"solid_verts": all_solid_verts, "solid_normals": all_solid_normals,
		"solid_uvs": all_solid_uvs, "solid_idxs": all_solid_idxs,
		"trans_verts": all_trans_verts, "trans_normals": all_trans_normals,
		"trans_uvs": all_trans_uvs, "trans_idxs": all_trans_idxs,
	}


## 将 generate_arrays_runtime 生成的字典数据组装为 ArrayMesh（必须在主线程调用）
static func build_mesh_from_arrays(arrays: Dictionary) -> ArrayMesh:
	return _merge_meshes(arrays)


## 合并原生单 chunk arrays 到全局数组（顶点加 chunk 世界偏移、index 加基准偏移）。
## 供 generate_arrays_runtime 复用原生 greedy 面生成时拼合多 chunk。
static func _append_offset_arrays(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, idxs: PackedInt32Array, arr: Dictionary, prefix: String,
		chunk_world: Vector3) -> void:
	var v: PackedVector3Array = arr.get(prefix + "_verts", PackedVector3Array())
	if v.is_empty():
		return
	var base := verts.size()
	for i in v.size():
		v[i] = v[i] + chunk_world
	verts.append_array(v)
	normals.append_array(arr.get(prefix + "_normals", PackedVector3Array()))
	uvs.append_array(arr.get(prefix + "_uvs", PackedVector2Array()))
	var ind: PackedInt32Array = arr.get(prefix + "_idxs", PackedInt32Array())
	for i in ind.size():
		idxs.append(ind[i] + base)


## 为指定的 chunk 列表生成网格数据（增量重建路径）
## 每个 chunk 的顶点使用局部坐标（相对于 chunk 原点），方便直接放到独立 MeshInstance3D
## 返回 {chunk_key: {solid_verts, solid_normals, ...}}，空 chunk 不在结果中
## 为指定的 chunk 列表生成网格数据（增量重建路径）
## 每个 chunk 的顶点使用局部坐标（相对于 chunk 原点），方便直接放到独立 MeshInstance3D
## 返回 {chunk_key: {solid_verts, solid_normals, ...}}，空 chunk 不在结果中
static func generate_chunks_arrays_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {},
		chunk_keys: Array[Vector3i] = []) -> Dictionary:
	var scale: float = options.get("scale", 0.1)
	var offset: Vector3 = options.get("offset", Vector3.ZERO)
	var aligned := VoxelMaterial.align_by_id(materials)
	var result := {}
	for ck in chunk_keys:
		var arrays := _generate_single_chunk_arrays_impl(voxels, aligned, scale, ck, true, offset)
		if arrays != null:
			result[ck] = arrays
	return result


## 生成所有非空 chunk 的 per-chunk 网格数据（初始构建或全量增量重建）
static func generate_all_chunks_arrays_runtime(
		voxels: Dictionary,
		materials: Array,
		options: Dictionary = {}) -> Dictionary:
	var non_empty := _build_non_empty_chunk_index(voxels)
	var chunk_keys := _all_non_empty_chunks_from_index(non_empty)
	return generate_chunks_arrays_runtime(voxels, materials, options, chunk_keys)


## 生成单个 chunk 的网格数据（线程安全，可在子线程调用）
## materials 参数应为已对齐的材质数组（通过 VoxelMaterial.align_by_id 预先对齐）
## 返回 {solid_verts, solid_normals, solid_uvs, solid_idxs, trans_verts, ...} 或 {}（空块）
static func generate_single_chunk_array(
		voxels: Dictionary, aligned_materials: Array, scale: float, chunk_key: Vector3i,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var result := _generate_single_chunk_arrays_impl(voxels, aligned_materials, scale, chunk_key, true, offset)
	return result if result else {}


## 从 chunk 缓冲字典（chunk key → PackedInt32Array，密集 16³）构建单个 chunk 的 18³ 光环缓冲
## 线程安全：buffers 必须是调用方提供的独立快照（深拷贝），子线程内只读。
## 供异步 worker 在子线程内直接从快照构建 halo，避免主线程逐 chunk 提取的阻塞。
static func build_halo_from_buffers(buffers: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	# 原生下沉（C++ 遍历 27 邻居 + 数组读取，worker 端 halo 构建吞吐提升）
	var native_halo := NativeLoader.build_halo_from_buffers(buffers, chunk)
	if native_halo.size() == HALO_VOLUME:
		return native_halo
	# GDScript 兜底（旧原生库/无原生时）
	var halo := PackedInt32Array()
	halo.resize(HALO_VOLUME)
	var origin := VoxelChunk.origin_of(chunk)
	# 只遍历 27 个邻居 chunk 与光环的重叠区，避免逐体素世界坐标换算
	for nz in 3:
		for ny in 3:
			for nx in 3:
				var nck := chunk + Vector3i(nx - HALO, ny - HALO, nz - HALO)
				if not buffers.has(nck):
					continue
				var buf: PackedInt32Array = buffers[nck]
				var n_origin := VoxelChunk.origin_of(nck)
				var lo := Vector3i(
					maxi(origin.x - HALO, n_origin.x),
					maxi(origin.y - HALO, n_origin.y),
					maxi(origin.z - HALO, n_origin.z))
				var hi := Vector3i(
					mini(origin.x + CHUNK_SIZE + HALO, n_origin.x + CHUNK_SIZE),
					mini(origin.y + CHUNK_SIZE + HALO, n_origin.y + CHUNK_SIZE),
					mini(origin.z + CHUNK_SIZE + HALO, n_origin.z + CHUNK_SIZE)) - Vector3i.ONE
				if lo.x > hi.x or lo.y > hi.y or lo.z > hi.z:
					continue
				for pz in range(lo.z, hi.z + 1):
					for py in range(lo.y, hi.y + 1):
						for px in range(lo.x, hi.x + 1):
							var lidx := (px - origin.x + HALO) + (py - origin.y + HALO) * HALO_SIZE + (pz - origin.z + HALO) * HALO_SIZE * HALO_SIZE
							var nidx := (px - n_origin.x) + (py - n_origin.y) * CHUNK_SIZE + (pz - n_origin.z) * CHUNK_SLICE
							halo[lidx] = buf[nidx]
	return halo


## 从"光环缓冲"生成单个 chunk 的网格数据（密集数组版，性能关键路径）
## halo 为 18³ 密集缓冲（统一材质契约：值 = 材质ID，0 = 空），由 build_halo_from_buffers 提供。
## 覆盖 chunk 内部 + 1 体素外缘，所有邻居读取均为数组下标且无越界检查。
## 线程安全：halo 是独立的深拷贝，子线程只读。
## 返回 {solid_verts, solid_normals, solid_uvs, solid_idxs, trans_verts, ...} 或 {}（空块）
## 实现完全在 GDExtension (C++) 中（NativeLoader.generate_chunk_dense），无 GDScript 兜底。
static func generate_single_chunk_dense(
		halo: PackedInt32Array, aligned_materials: Array, scale: float, chunk_key: Vector3i,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if not NativeLoader.is_available():
		push_error("[VoxelChunkGenerator] chunk 网格生成需要原生库 VoxelNative（未加载）")
		return {}
	var trans_flags := _build_trans_flags(aligned_materials)
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


## 从 chunk 缓冲快照构建 LOD 大块的 34³ 大格 halo（纯函数，供异步 worker，线程安全）。
## 中心 32³ 大格 = 大块内部（降采样 2^lod_shift³ 体素 → 1 大格，取非空材质）；
## 6 外缘面 = 相邻大块边界 1 大格层（跨界可见性）。
## 任意 lod_shift 统一走原生通用降采样（build_lod_block_halo_from_buffers_native）；原生缺失时兜底 GDScript 降采样。
static func build_lod_block_halo_from_buffers(buffers: Dictionary, block_key: Vector3i, lod_shift: int = 1) -> PackedInt32Array:
	# 原生通用降采样（任意 lod_shift）
	var native_halo := NativeLoader.build_lod_block_halo_from_buffers_native(buffers, block_key, lod_shift)
	if native_halo.size() == LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE:
		return native_halo
	# 兜底 GDScript 降采样（原生不可用，任意 lod_shift：每大格 = 2^lod_shift 体素）
	var cell_voxels := 1 << lod_shift
	var cells_per_chunk := VoxelChunk.CHUNK_SIZE / cell_voxels
	var chunks_per_block := LOD_BLOCK_SIZE / cells_per_chunk
	var block_voxels := LOD_BLOCK_SIZE * cell_voxels  # 大块体素边长 = 32 × 2^lod_shift
	var base_chunk := block_key * chunks_per_block
	var halo := PackedInt32Array()
	halo.resize(LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE)
	# 中心 32³ 大格：遍历大块覆盖的 chunks_per_block³ 个 chunk，降采样 cell_voxels³ 体素 → 1 大格
	for cz in chunks_per_block:
		for cy in chunks_per_block:
			for cx in chunks_per_block:
				var ck := base_chunk + Vector3i(cx, cy, cz)
				var cbuf: PackedInt32Array = buffers.get(ck, PackedInt32Array())
				if cbuf.is_empty():
					continue
				for lz8 in cells_per_chunk:
					var bz := lz8 * cell_voxels
					for ly8 in cells_per_chunk:
						var by := ly8 * cell_voxels
						for lx8 in cells_per_chunk:
							var bx := lx8 * cell_voxels
							var mat := 0
							for dz in cell_voxels:
								for dy in cell_voxels:
									for dx in cell_voxels:
										var m := cbuf[(bz + dz) * CHUNK_SLICE + (by + dy) * CHUNK_SIZE + (bx + dx)]
										if m > 0:
											mat = m
											break
									if mat > 0:
										break
								if mat > 0:
									break
							var lx := cx * cells_per_chunk + lx8
							var ly := cy * cells_per_chunk + ly8
							var lz := cz * cells_per_chunk + lz8
							halo[(1 + lx) + (1 + ly) * LOD_BLOCK_HALO_SIZE + (1 + lz) * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE] = mat
	# 6 外缘面：相邻大块边界 1 大格层（降采样 cell_voxels³ 体素）
	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for d in dirs:
		var nbk: Vector3i = block_key + d
		var face := 0
		if d.x != 0:
			face = 0
		elif d.y != 0:
			face = 1
		else:
			face = 2
		_fill_lod_block_face(halo, buffers, nbk, face, d, cell_voxels, block_voxels)
	return halo


## 从独立 LOD 数据块（每 LOD 32³ 大格，值 = 材质ID）构建 34³ halo（无降采样，直接拷大格）：
## 中心 32³ = block 自身；6 外缘面 = 相邻 block 边界 1 大格层（跨界可见性）。
## Voxel Tools 式独立数据层的网格化入口：粗层 mesh 直接由大格数据生成，无需 LOD0 chunk。
## 原生下沉 C++（build_lod_block_halo_from_lod_buffers_native）；原生缺失时兜底 GDScript。
static func build_lod_block_halo_from_lod_buffers(buffers: Dictionary, block_key: Vector3i) -> PackedInt32Array:
	var native_halo := NativeLoader.build_lod_block_halo_from_lod_buffers_native(buffers, block_key)
	if native_halo.size() == LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE * LOD_BLOCK_HALO_SIZE:
		return native_halo
	var HS := LOD_BLOCK_HALO_SIZE
	var g := LOD_BLOCK_SIZE
	var halo := PackedInt32Array()
	halo.resize(HS * HS * HS)
	# 中心 32³ = block 自身大格
	var self_buf: PackedInt32Array = buffers.get(block_key, PackedInt32Array())
	if self_buf.size() >= g * g * g:
		for lz in g:
			for ly in g:
				for lx in g:
					halo[(1 + lx) + (1 + ly) * HS + (1 + lz) * HS * HS] = self_buf[lx + ly * g + lz * g * g]
	# 6 外缘面 = 相邻 block 边界 1 大格层（直接拷邻居大格，无降采样）
	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	for d in dirs:
		var nbk: Vector3i = block_key + d
		var face := 0 if d.x != 0 else (1 if d.y != 0 else 2)
		_fill_lod_block_face_from_lod(halo, buffers, nbk, face, d)
	return halo


## 从独立大格数据填充外缘面（直接拷贝邻居 block 的边界层大格，无降采样）
static func _fill_lod_block_face_from_lod(halo: PackedInt32Array, buffers: Dictionary, nbk: Vector3i, face: int, d: Vector3i) -> void:
	var HS := LOD_BLOCK_HALO_SIZE
	var g := LOD_BLOCK_SIZE
	var side := 1 if d[face] > 0 else 0
	var fix := 0 if side == 1 else (g - 1)  # 邻居 block 的边界格索引
	var halo_pos := 0 if d[face] < 0 else (HS - 1)
	var nb: PackedInt32Array = buffers.get(nbk, PackedInt32Array())
	var has_nb := nb.size() >= g * g * g
	for lv in g:
		for lu in g:
			var mat := 0
			if has_nb:
				var ni := 0
				match face:
					0: ni = fix + lu * g + lv * g * g
					1: ni = lu + fix * g + lv * g * g
					_: ni = lu + lv * g + fix * g * g
				mat = nb[ni]
			var hx := 0
			var hy := 0
			var hz := 0
			match face:
				0: hx = halo_pos; hy = 1 + lu; hz = 1 + lv
				1: hx = 1 + lu; hy = halo_pos; hz = 1 + lv
				_: hx = 1 + lu; hy = 1 + lv; hz = halo_pos
			halo[hx + hy * HS + hz * HS * HS] = mat


## 填充大块 halo 的一个外缘面（邻居大块 nbk 的边界 1 大格层）。
## face: 0=x, 1=y, 2=z；d: 方向（+1/-1，决定取低侧0面还是高侧31面）
## cell_voxels = 2^lod_shift（每大格体素），block_voxels = 32 × 2^lod_shift（大块体素边长）
static func _fill_lod_block_face(halo: PackedInt32Array, buffers: Dictionary, nbk: Vector3i, face: int, d: Vector3i,
		cell_voxels: int, block_voxels: int) -> void:
	var HS := LOD_BLOCK_HALO_SIZE
	var u_axis := (face + 1) % 3
	var v_axis := (face + 2) % 3
	# 固定轴：d>0 → 当前大块 +x 侧 halo 面 = 邻居的 0 大格层（低侧，取 +1）；
	# d<0 → 邻居的 31 大格层（高侧，取 31）
	var side := 1 if d[face] > 0 else 0
	var fix_grid := 0 if side == 1 else (LOD_BLOCK_SIZE - 1)
	# halo 中该面的位置：d>0 → 高侧（HS-1），d<0 → 低侧（0）
	var halo_pos := 0 if d[face] < 0 else (HS - 1)
	# 邻居大块覆盖体素 [nbk*block_voxels, nbk*block_voxels+block_voxels-1]
	for lv in LOD_BLOCK_SIZE:
		for lu in LOD_BLOCK_SIZE:
			var mat := 0
			for dv in cell_voxels:
				for du in cell_voxels:
					for df in cell_voxels:
						var vox := Vector3i(
							nbk.x * block_voxels + ((fix_grid * cell_voxels + df) if face == 0 else (lu * cell_voxels + du)),
							nbk.y * block_voxels + ((fix_grid * cell_voxels + df) if face == 1 else ((lu * cell_voxels + du) if face == 0 else (lv * cell_voxels + dv))),
							nbk.z * block_voxels + ((fix_grid * cell_voxels + df) if face == 2 else (lv * cell_voxels + dv)))
						var ck := Vector3i(vox.x >> VoxelChunk.CHUNK_SHIFT, vox.y >> VoxelChunk.CHUNK_SHIFT, vox.z >> VoxelChunk.CHUNK_SHIFT)
						var cbuf: PackedInt32Array = buffers.get(ck, PackedInt32Array())
						if not cbuf.is_empty():
							var local := Vector3i(vox.x - ck.x * CHUNK_SIZE, vox.y - ck.y * CHUNK_SIZE, vox.z - ck.z * CHUNK_SIZE)
							var m := cbuf[local.z * CHUNK_SLICE + local.y * CHUNK_SIZE + local.x]
							if m > 0:
								mat = m
								break
					if mat > 0:
						break
				if mat > 0:
					break
			# 写 halo 面：halo 坐标 = (u,v) 映射到 halo 的 (x,y,z)
			var hx := 0
			var hy := 0
			var hz := 0
			match face:
				0:
					hx = halo_pos
					hy = 1 + lu
					hz = 1 + lv
				1:
					hx = 1 + lu
					hy = halo_pos
					hz = 1 + lv
				_:
					hx = 1 + lu
					hy = 1 + lv
					hz = halo_pos
			halo[hx + hy * HS + hz * HS * HS] = mat


## 生成 LOD 大块网格（一次性 32³ 大格，原生 generate_lod1_block_dense / generate_chunk_dense）。
## scale = voxel_scale；每大格世界尺寸 = scale × 2^lod_shift，MeshInstance3D 位置应设为
## block_key × (32 × 2^lod_shift) × voxel_scale。
## lod_shift=1 沿用 generate_lod1_block_dense；更高层复用 generate_chunk_dense
## （同一 32³ 网格核心 generate_dense_impl，仅 scale/格数不同）。
static func generate_lod_block_arrays(
		lod_halo: PackedInt32Array, aligned_materials: Array, scale: float, block_key: Vector3i,
		offset: Vector3 = Vector3.ZERO, lod_shift: int = 1) -> Dictionary:
	if not NativeLoader.is_available():
		push_error("[VoxelChunkGenerator] LOD 大块网格生成需要原生库 VoxelNative（未加载）")
		return {}
	var trans_flags := _build_trans_flags(aligned_materials)
	var result: Dictionary
	if lod_shift == 1:
		result = NativeLoader.generate_lod1_block_dense(lod_halo, trans_flags, scale * 2.0, block_key, offset)
	else:
		result = NativeLoader.generate_chunk_dense(lod_halo, trans_flags, scale * float(1 << lod_shift), block_key, true, offset)
	if result.get("solid_idxs", PackedInt32Array()).is_empty() and result.get("trans_idxs", PackedInt32Array()).is_empty():
		return {}
	return result


## 从对齐材质数组构建透明标志数组（PackedByteArray，索引=材质ID，1=透明）
## 供原生 generate_chunk_dense 使用（C++ 跨语言读 VoxelMaterial 属性较慢，预计算传入）
## 防御：worker 线程读材质数组时主线程可能正在对齐（COW/竞态），访问前再校验边界防越界崩溃。
static func _build_trans_flags(aligned_materials: Array) -> PackedByteArray:
	var n := aligned_materials.size()
	var flags := PackedByteArray()
	flags.resize(n)
	for i in n:
		var mat: Variant = aligned_materials[i] if i < aligned_materials.size() else null
		flags[i] = 1 if mat != null and mat.trans > 0 else 0
	return flags


# ----------------------------------------------------------------------------
# 私有实现
# ----------------------------------------------------------------------------

## 生成单个 chunk 的网格数据（顶点使用局部坐标）- 内部实现
static func _generate_single_chunk_arrays_impl(
		voxels, materials, scale: float, chunk: Vector3i,
		use_local_space: bool = true, offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var solid_verts := PackedVector3Array()
	var solid_normals := PackedVector3Array()
	var solid_uvs := PackedVector2Array()
	var solid_idxs := PackedInt32Array()
	var trans_verts := PackedVector3Array()
	var trans_normals := PackedVector3Array()
	var trans_uvs := PackedVector2Array()
	var trans_idxs := PackedInt32Array()
	_generate_chunk_into(voxels, materials, scale, chunk,
		solid_verts, solid_normals, solid_uvs, solid_idxs,
		trans_verts, trans_normals, trans_uvs, trans_idxs,
		use_local_space, offset)
	if solid_idxs.is_empty() and trans_idxs.is_empty():
		return {}
	return {
		"solid_verts": solid_verts, "solid_normals": solid_normals,
		"solid_uvs": solid_uvs, "solid_idxs": solid_idxs,
		"trans_verts": trans_verts, "trans_normals": trans_normals,
		"trans_uvs": trans_uvs, "trans_idxs": trans_idxs,
	}


## 一次遍历 voxels，建立"非空 chunk"的哈希索引 (chunk -> true)
## 相比逐 chunk 扫描 16³ 体素，只需一次遍历所有体素，查询变为 O(1)
static func _build_non_empty_chunk_index(voxels) -> Dictionary:
	var index := {}
	for pos_key in voxels:
		index[VoxelChunk.chunk_of(pos_key)] = true
	return index


## 从非空 chunk 索引收集所有非空 chunk（全量重建路径）
static func _all_non_empty_chunks_from_index(non_empty: Dictionary) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	for ck in non_empty:
		chunk_keys.append(ck)
	return chunk_keys


## 生成单个 chunk 的面片并追加到全局数组（贪婪网格）
## use_local_space=true 时顶点使用 chunk 局部坐标（适合独立 MeshInstance3D）
## offset: 渲染偏移（体素单位，最终乘以 scale 叠加到顶点），用于导入居中显示
## 字典版入口：先把 chunk 区域（18³）转换成分片独立的光环缓冲，再统一走密集核心。
## 兼容旧调用方（落块生成 / 非 chunk 渲染模式 / 导入路径），渲染主路径请用 dense 版本。
static func _generate_chunk_into(voxels, materials, scale: float, chunk: Vector3i,
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		use_local_space: bool = false, offset: Vector3 = Vector3.ZERO) -> void:
	var halo := _halo_from_dict(voxels, chunk)
	_generate_chunk_dense_into(halo, materials, scale, chunk,
		solid_verts, solid_normals, solid_uvs, solid_idxs,
		trans_verts, trans_normals, trans_uvs, trans_idxs,
		use_local_space, offset)


## 从稀疏字典构建 18³ 光环缓冲（统一材质契约：值 = 材质ID，0 = 空）
static func _halo_from_dict(voxels: Dictionary, chunk: Vector3i) -> PackedInt32Array:
	var halo := PackedInt32Array()
	halo.resize(HALO_VOLUME)
	var origin := VoxelChunk.origin_of(chunk)
	for z in HALO_SIZE:
		for y in HALO_SIZE:
			for x in HALO_SIZE:
				var p := origin + Vector3i(x - HALO, y - HALO, z - HALO)
				var v: int = voxels.get(p, -1)
				if v > 0:
					halo[VoxelChunk.halo_index(x, y, z)] = v
	return halo


## 从 18³ 密集光环缓冲生成单个 chunk 的面片（性能关键路径）
## 单次扫描 16³，每体素 6 方向可见性全部为数组下标读取（无字典哈希、无越界检查）。
## 使用贪婪网格算法：将相邻同材质面合并为更大的四边形，大幅减少三角形数。
## use_local_space=true 时顶点使用 chunk 局部坐标（适合独立 MeshInstance3D）
static func _generate_chunk_dense_into(halo: PackedInt32Array, materials, scale: float, chunk: Vector3i,
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		use_local_space: bool = false, offset: Vector3 = Vector3.ZERO) -> void:
	var chunk_origin := VoxelChunk.origin_of(chunk)
	var origin_offset := Vector3(chunk_origin) * scale if use_local_space else Vector3.ZERO

	# 预计算材质透明标志（数组索引==材质ID，O(1) 查询）。
	# 统一材质契约：体素值即材质ID（0=空），热循环只做数组下标读取，无任何函数调用/字典哈希。
	var n_mats: int = materials.size()
	var trans_flags := PackedByteArray()
	trans_flags.resize(n_mats)
	for i in n_mats:
		var mat = materials[i]
		trans_flags[i] = 1 if mat != null and mat.trans > 0 else 0

	# 预分配：6个面的可见面收集器（定长 Array[16] 替代 Dictionary，消除哈希分配）
	# slices_by_face[face_idx][slice_key] = PackedInt32Array（16×16 密集，统一材质契约：0=空，否则=材质ID）
	# slice_key ∈ [0, CHUNK_SIZE)，每个元素初始为 null，首次使用才分配 grid
	var slices_by_face: Array[Array] = []
	for i in 6:
		var arr: Array = []
		arr.resize(CHUNK_SIZE)
		slices_by_face.append(arr)

	# 单次遍历 16³：光环下标覆盖 6 邻，全部为数组读取
	for z in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for x in CHUNK_SIZE:
				var idx := (x + HALO) + (y + HALO) * HALO_SIZE + (z + HALO) * HALO_SIZE * HALO_SIZE
				var v: int = halo[idx]
				if v <= 0:
					continue

				var mat_id := v
				var is_trans: bool = mat_id < n_mats and trans_flags[mat_id] > 0

				# 一次检查所有6个面
				for face_idx in 6:
					var nv: int = halo[idx + _HALO_DIRS[face_idx]]

					var visible := false
					if nv <= 0:
						visible = true
					else:
						var n_mat_id := nv
						var n_trans: bool = n_mat_id < n_mats and trans_flags[n_mat_id] > 0
						# 面可见性统一规则（与 FaceTool.face_visible 完全一致，热路径内联避免函数调用）：
						# 透明类型不同 → 可见；皆透明且材质不同 → 可见；其余（含实心材质接缝）→ 不可见
						if is_trans != n_trans:
							visible = true
						elif is_trans and mat_id != n_mat_id:
							visible = true

					if visible:
						var axis_info: Dictionary = _FACE_AXES[face_idx]
						var perp := axis_info.perp as int
						var u_axis := axis_info.u as int
						var v_axis := axis_info.v as int
						var slice_key := _axis_val(x, y, z, perp)
						var u := _axis_val(x, y, z, u_axis)
						var vv := _axis_val(x, y, z, v_axis)

						var slices: Array = slices_by_face[face_idx]
						if slices[slice_key] == null:
							slices[slice_key] = _new_slice_grid()
						var grid: PackedInt32Array = slices[slice_key]
						grid[u + vv * CHUNK_SIZE] = mat_id

	# 处理每个面的贪婪合并（定长数组遍历，无字典哈希迭代）
	for face_idx in 6:
		var axis_info: Dictionary = _FACE_AXES[face_idx]
		var perp := axis_info.perp as int
		var u_axis := axis_info.u as int
		var v_axis := axis_info.v as int
		var slices: Array = slices_by_face[face_idx]

		for slice_key in CHUNK_SIZE:
			if slices[slice_key] == null:
				continue
			var grid: PackedInt32Array = slices[slice_key]
			var merge_result := VoxelGreedyMesher.greedy_merge_dense(grid, CHUNK_SIZE, CHUNK_SIZE)
			var m_pos: PackedInt32Array = merge_result["pos"]
			var m_size: PackedInt32Array = merge_result["size"]
			var m_val: PackedInt32Array = merge_result["val"]
			var n_rects := m_val.size()
			for i in n_rects:
				# 重建世界坐标（局部坐标 + chunk_origin 偏移）
				var pos := chunk_origin
				pos[perp] += slice_key
				pos[u_axis] += m_pos[i * 2]
				pos[v_axis] += m_pos[i * 2 + 1]
				var size := Vector3i(1, 1, 1)
				size[u_axis] = m_size[i * 2]
				size[v_axis] = m_size[i * 2 + 1]

				_add_greedy_face(
					solid_verts, solid_normals, solid_uvs, solid_idxs,
					trans_verts, trans_normals, trans_uvs, trans_idxs,
					pos, m_val[i], face_idx, scale, size,
					materials, origin_offset, offset)


## 取局部坐标在指定轴上的值
static func _axis_val(x: int, y: int, z: int, axis: int) -> int:
	if axis == 0:
		return x
	elif axis == 1:
		return y
	return z


## 新建一个 16×16 密集切面网格（全 0，行优先，下标 = u + v*CHUNK_SIZE）
static func _new_slice_grid() -> PackedInt32Array:
	var g := PackedInt32Array()
	g.resize(CHUNK_SLICE)
	return g


## 添加一个贪婪合并后的面（大四边形，2 三角形）
## size 控制面的大小（体素单位），用于合并相邻面
## 与 VoxelMeshGenerator 的缩放方案一致：point * size + pos
static func _add_greedy_face(
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		pos: Vector3i, mat_id: int, face_idx: int, scale: float, size: Vector3i,
		materials, origin_offset: Vector3, offset: Vector3 = Vector3.ZERO) -> void:
	var normal: Vector3 = FaceTool.Normals[face_idx]
	var u := VoxelMaterial.uv_for_id(mat_id)

	# 判断是否透明（统一材质契约：materials 已按 id 对齐，直接下标；越界防御性视为不透明）
	var mat = materials[mat_id] if mat_id < materials.size() else null
	var is_trans: bool = mat != null and mat.trans > 0

	# 顶点位置：pos + point * size
	# 与 VoxelMeshGenerator._generate_size_dir_face 一致
	# offset 为渲染居中偏移（体素单位），换算为世界单位后叠加到最终顶点
	for point: Vector3 in FaceTool.Faces[face_idx]:
		var world_pos := (Vector3(pos) + point * Vector3(size)) * scale - origin_offset + offset * scale
		if is_trans:
			trans_verts.append(world_pos)
			trans_normals.append(normal)
			trans_uvs.append(Vector2(u, 0.0))
			trans_idxs.append(trans_verts.size() - 1)
		else:
			solid_verts.append(world_pos)
			solid_normals.append(normal)
			solid_uvs.append(Vector2(u, 0.0))
			solid_idxs.append(solid_verts.size() - 1)


# 每个面的轴向信息：{perp(切片轴), u(水平轴), v(垂直轴)}
# 用于贪婪网格的 2D 扫描合并。
# 直接从 FaceTool.SliceAxis 派生（与 VoxelMeshGenerator 同一权威数据源），
# 保证与 FaceTool.Normals/Faces/_HALO_DIRS 的索引顺序 [+Y,-Y,-X,+X,+Z,-Z] 一致。
const _FACE_AXES: Array[Dictionary] = [
	{perp=FaceTool.SliceAxis[0].x, u=FaceTool.SliceAxis[0].y, v=FaceTool.SliceAxis[0].z},  # +Y Top
	{perp=FaceTool.SliceAxis[1].x, u=FaceTool.SliceAxis[1].y, v=FaceTool.SliceAxis[1].z},  # -Y Bottom
	{perp=FaceTool.SliceAxis[2].x, u=FaceTool.SliceAxis[2].y, v=FaceTool.SliceAxis[2].z},  # -X Left
	{perp=FaceTool.SliceAxis[3].x, u=FaceTool.SliceAxis[3].y, v=FaceTool.SliceAxis[3].z},  # +X Right
	{perp=FaceTool.SliceAxis[4].x, u=FaceTool.SliceAxis[4].y, v=FaceTool.SliceAxis[4].z},  # +Z Front
	{perp=FaceTool.SliceAxis[5].x, u=FaceTool.SliceAxis[5].y, v=FaceTool.SliceAxis[5].z},  # -Z Back
]


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