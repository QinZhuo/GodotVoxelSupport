class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区）
##
## 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格。
## 生成时始终输出所有非空 chunk 的完整 mesh，避免增量重建导致数据丢失。
## 支持在后台线程生成网格数据（generate_arrays_runtime），避免阻塞主线程。
## 自动跳过完全空的 chunk（空块提前终止）。
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数），chunk 越大网格合并效率越高但增量重建粒度越粗
const CHUNK_SIZE := 16


## 运行时网格生成入口，在主线程调用
## 始终生成所有非空 chunk，确保输出完整 mesh。rebuild_chunks 参数保留用于 API 兼容。
static func generate_mesh_runtime(
		voxels: Dictionary[Vector3i, int],
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> ArrayMesh:
	var arrays := generate_arrays_runtime(voxels, materials, options, rebuild_chunks)
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
		voxels: Dictionary[Vector3i, int],
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> Variant:
	var scale: float = options.get("scale", 0.1)
	var offset: Vector3 = options.get("offset", Vector3.ZERO)
	var aligned := VoxelMaterial.align_by_id(materials)

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
		_generate_chunk_into(voxels, aligned, scale, ck,
			all_solid_verts, all_solid_normals, all_solid_uvs, all_solid_idxs,
			all_trans_verts, all_trans_normals, all_trans_uvs, all_trans_idxs,
			false, offset)

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


## 为指定的 chunk 列表生成网格数据（增量重建路径）
## 每个 chunk 的顶点使用局部坐标（相对于 chunk 原点），方便直接放到独立 MeshInstance3D
## 返回 {chunk_key: {solid_verts, solid_normals, ...}}，空 chunk 不在结果中
static func generate_chunks_arrays_runtime(
		voxels: Dictionary[Vector3i, int],
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
## 等价于先获取所有非空 chunk 再调用 generate_chunks_arrays_runtime
static func generate_all_chunks_arrays_runtime(
		voxels: Dictionary[Vector3i, int],
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


## 根据变更体素集合，计算需要重建的 chunk（增量重建核心）
## 当体素在 chunk 边界发生变化时，相邻 chunk 也需要重建，
## 因为相邻 chunk 中边界体素的面可见性依赖于该体素的存在状态。
static func chunks_for_dirty_voxels(dirty_voxels: Dictionary) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	var added := {}
	for pos_key in dirty_voxels:
		var ck := _chunk_of(pos_key)
		if not added.has(ck):
			chunk_keys.append(ck)
			added[ck] = true
		# 检查该体素是否位于 chunk 的 6 个边界面上
		# 如果是，需要同时重建相邻 chunk，确保边界面的可见性正确
		var p: Vector3i = pos_key
		var local_pos := p - ck * CHUNK_SIZE
		# 6 方向：如果在边界（local == 0 或 local == CHUNK_SIZE-1），相邻 chunk 也需要重建
		if local_pos.x == 0:
			_add_chunk(ck + Vector3i(-1, 0, 0), chunk_keys, added)
		elif local_pos.x == CHUNK_SIZE - 1:
			_add_chunk(ck + Vector3i(1, 0, 0), chunk_keys, added)
		if local_pos.y == 0:
			_add_chunk(ck + Vector3i(0, -1, 0), chunk_keys, added)
		elif local_pos.y == CHUNK_SIZE - 1:
			_add_chunk(ck + Vector3i(0, 1, 0), chunk_keys, added)
		if local_pos.z == 0:
			_add_chunk(ck + Vector3i(0, 0, -1), chunk_keys, added)
		elif local_pos.z == CHUNK_SIZE - 1:
			_add_chunk(ck + Vector3i(0, 0, 1), chunk_keys, added)
	return chunk_keys


## 从体素数据中提取所有非空 chunk 的键列表
## 用于初始全量构建时分块独立线程处理，避免单线程全量生成
static func get_all_non_empty_chunk_keys(voxels: Dictionary) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	var added := {}
	for pos_key in voxels:
		var ck := _chunk_of(pos_key)
		if not added.has(ck):
			chunk_keys.append(ck)
			added[ck] = true
	return chunk_keys


static func _add_chunk(ck: Vector3i, chunk_keys: Array, added: Dictionary) -> void:
	if not added.has(ck):
		chunk_keys.append(ck)
		added[ck] = true


# ----------------------------------------------------------------------------
# 私有实现
# ----------------------------------------------------------------------------

static func _chunk_of(pos: Vector3i) -> Vector3i:
	var fx := float(pos.x) / float(CHUNK_SIZE)
	var fy := float(pos.y) / float(CHUNK_SIZE)
	var fz := float(pos.z) / float(CHUNK_SIZE)
	return Vector3i(floori(fx), floori(fy), floori(fz))


## 一次遍历 voxels，建立"非空 chunk"的哈希索引 (chunk -> true)
## 相比逐 chunk 扫描 16³ 体素，只需一次遍历所有体素，查询变为 O(1)
static func _build_non_empty_chunk_index(voxels) -> Dictionary:
	var index := {}
	for pos_key in voxels:
		index[_chunk_of(pos_key)] = true
	return index


## 从非空 chunk 索引收集所有非空 chunk（全量重建路径）
static func _all_non_empty_chunks_from_index(non_empty: Dictionary) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	for ck in non_empty:
		chunk_keys.append(ck)
	return chunk_keys


## 从待重建 chunk 中过滤掉空 chunk（基于非空索引 O(1) 查询，并去重）
static func _unique_non_empty(arr: Array[Vector3i], non_empty: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for ck in arr:
		if result.has(ck):
			continue
		# 空块提前终止：该 chunk 在非空索引中不存在则跳过
		if non_empty.has(ck):
			result.append(ck)
	return result


## 生成单个 chunk 的面片并追加到全局数组（贪婪网格）- 优化版
## 使用贪婪网格算法：将相邻同材质面合并为更大的四边形，大幅减少三角形数。
## use_local_space=true 时顶点使用 chunk 局部坐标（适合独立 MeshInstance3D）
## offset: 渲染偏移（体素单位，最终乘以 scale 叠加到顶点），用于导入居中显示
##
## 性能优化说明：
## 原方案：对每个面（6次）独立扫描整个 32³ 空间 → 6 × 32³ = 196,608 次字典查找
## 优化方案：单次扫描所有填充位置，同时检查6个面的可见性 → 32³ + 6 × filled_count 次查找
## 对半填充 Chunk 提升约 33%，对稀疏 Chunk 提升可达 50%+
static func _generate_chunk_into(voxels, materials, scale: float, chunk: Vector3i,
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		use_local_space: bool = false, offset: Vector3 = Vector3.ZERO) -> void:
	var chunk_origin := chunk * CHUNK_SIZE
	var origin_offset := Vector3(chunk_origin) * scale if use_local_space else Vector3.ZERO

	# 预分配：6个面的可见面收集器
	# slices_by_face[face_idx][slice_key] = { Vector2i(u,v): mat_id }
	var slices_by_face: Array[Dictionary] = []
	for i in 6:
		slices_by_face.append({})

	# 单次遍历：扫描所有位置，同时检查6个面的可见性
	# 相比原方案（每面独立扫描），减少 5/6 的空位置字典查找开销
	for x in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for z in CHUNK_SIZE:
				var pos := chunk_origin + Vector3i(x, y, z)
				var mat_id: int = voxels.get(pos, -1)
				if mat_id < 0:
					continue
				
				var local_pos := Vector3i(x, y, z)
				var mat = _get_mat(materials, mat_id)
				var is_trans: bool = mat != null and mat.trans > 0
				
				# 一次检查所有6个面
				for face_idx in 6:
					var dir: Vector3i = _DIRS[face_idx]
					var n_id: int = voxels.get(pos + dir, -1)
					
					var visible := false
					if n_id < 0:
						visible = true
					else:
						var n_mat = _get_mat(materials, n_id)
						var n_trans: bool = n_mat != null and n_mat.trans > 0
						if is_trans != n_trans or mat_id != n_id:
							visible = true
					
					if visible:
						var axis_info: Dictionary = _FACE_AXES[face_idx]
						var perp := axis_info.perp as int
						var u_axis := axis_info.u as int
						var v_axis := axis_info.v as int
						var slice_key := local_pos[perp]
						var uv := Vector2i(local_pos[u_axis], local_pos[v_axis])
						
						var slices: Dictionary = slices_by_face[face_idx]
						if not slices.has(slice_key):
							slices[slice_key] = {}
						slices[slice_key][uv] = mat_id

	# 处理每个面的贪婪合并
	for face_idx in 6:
		var axis_info: Dictionary = _FACE_AXES[face_idx]
		var perp := axis_info.perp as int
		var u_axis := axis_info.u as int
		var v_axis := axis_info.v as int
		var slices: Dictionary = slices_by_face[face_idx]

		for slice_key in slices:
			var grid: Dictionary = slices[slice_key]
			var rects: Array[VoxelGreedyMesher.RectInfo] = VoxelGreedyMesher.greedy_merge(grid)
			for rect in rects:
				# 重建世界坐标（局部坐标 + chunk_origin 偏移）
				var pos := chunk_origin
				pos[perp] += slice_key
				pos[u_axis] += rect.position.x
				pos[v_axis] += rect.position.y
				var size := Vector3i(1, 1, 1)
				size[u_axis] = rect.size.x
				size[v_axis] = rect.size.y

				_add_greedy_face(
					solid_verts, solid_normals, solid_uvs, solid_idxs,
					trans_verts, trans_normals, trans_uvs, trans_idxs,
					pos, rect.value, face_idx, scale, size,
					materials, origin_offset, offset)


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

	# 判断是否透明
	var mat = _get_mat(materials, mat_id)
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


static func _get_mat(materials, mat_id: int):
	return VoxelMaterial.find_by_id(materials, mat_id)


# 6 个面的方向向量（与 FaceTool.Normals 同一组方向，统一数据源）
const _DIRS: Array[Vector3i] = [
	Vector3i(FaceTool.Normals[0]), Vector3i(FaceTool.Normals[1]),
	Vector3i(FaceTool.Normals[2]), Vector3i(FaceTool.Normals[3]),
	Vector3i(FaceTool.Normals[4]), Vector3i(FaceTool.Normals[5]),
]

# 每个面的轴向信息：{perp(切片轴), u(水平轴), v(垂直轴)}
# 用于贪婪网格的 2D 扫描合并
const _FACE_AXES: Array[Dictionary] = [
	{perp=0, u=1, v=2},  # +X
	{perp=0, u=1, v=2},  # -X
	{perp=1, u=0, v=2},  # +Y
	{perp=1, u=0, v=2},  # -Y
	{perp=2, u=0, v=1},  # +Z
	{perp=2, u=0, v=1},  # -Z
]


## 添加一个面（两个三角形，6 顶点）
## origin_offset 用于将顶点偏移到局部坐标（per-chunk mesh 使用）
## 与 VoxelMeshGenerator 共用 FaceTool.Faces 面片数据，确保法线/缠绕方向完全一致
static func _add_face(
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		pos: Vector3i, mat_id: int, face_idx: int, scale: float, is_trans: bool,
		origin_offset: Vector3 = Vector3.ZERO) -> void:
	var normal: Vector3 = FaceTool.Normals[face_idx]
	var u := VoxelMaterial.uv_for_id(mat_id)
	# FaceTool.Faces[face_idx] 已按 CCW 拆好 6 个顶点（两个三角形）
	for point: Vector3 in FaceTool.Faces[face_idx]:
		var world_pos := (Vector3(pos) + point) * scale - origin_offset
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