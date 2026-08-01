class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区 + 增量重建）
##
## 相比 VoxelMeshGenerator 的全局网格生成，本生成器：
##   - 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格
##   - 支持"增量重建"：只重新生成发生变化的 chunk，而非全量重建
##   - 支持在后台线程生成网格数据（generate_arrays_runtime），避免阻塞主线程
##   - 自动跳过完全空的 chunk（空块提前终止）
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数），chunk 越大网格合并效率越高但增量重建粒度越粗
const CHUNK_SIZE := 16


## 运行时网格生成入口（全量或增量），在主线程调用
## 通过 rebuild_chunks 指定只重建部分 chunk；为空则全量生成
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
	var aligned := VoxelMaterial.align_by_id(materials)

	# 确定需要重建的 chunk（跳过完全空的 chunk）
	var chunk_keys: Array[Vector3i] = []
	if rebuild_chunks.is_empty():
		chunk_keys = _all_non_empty_chunks(voxels)
	else:
		chunk_keys = _unique_non_empty(rebuild_chunks, voxels)

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
			all_trans_verts, all_trans_normals, all_trans_uvs, all_trans_idxs)

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


## 根据变更体素集合，计算需要重建的 chunk（增量重建核心）
static func chunks_for_dirty_voxels(dirty_voxels: Dictionary) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	for pos_key in dirty_voxels:
		var ck := _chunk_of(pos_key)
		if not chunk_keys.has(ck):
			chunk_keys.append(ck)
	return chunk_keys


# ----------------------------------------------------------------------------
# 私有实现
# ----------------------------------------------------------------------------

static func _chunk_of(pos: Vector3i) -> Vector3i:
	var fx := float(pos.x) / float(CHUNK_SIZE)
	var fy := float(pos.y) / float(CHUNK_SIZE)
	var fz := float(pos.z) / float(CHUNK_SIZE)
	return Vector3i(floori(fx), floori(fy), floori(fz))


## 收集所有"非空"的 chunk（空块提前终止：跳过 voxels 中不存在的 chunk）
static func _all_non_empty_chunks(voxels) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	for pos_key in voxels:
		var ck := _chunk_of(pos_key)
		if not chunk_keys.has(ck):
			chunk_keys.append(ck)
	return chunk_keys


## 从待重建 chunk 中过滤掉空 chunk（该 chunk 在 voxels 中无任何体素）
static func _unique_non_empty(arr: Array[Vector3i], voxels) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for ck in arr:
		if result.has(ck):
			continue
		# 空块提前终止：chunk 内无体素则跳过，避免为不存在的 chunk 分配/遍历
		var origin := ck * CHUNK_SIZE
		var empty := true
		for x in CHUNK_SIZE:
			for y in CHUNK_SIZE:
				for z in CHUNK_SIZE:
					if voxels.has(origin + Vector3i(x, y, z)):
						empty = false
						break
				if not empty:
					break
			if not empty:
				break
		if not empty:
			result.append(ck)
	return result


## 生成单个 chunk 的面片并追加到全局数组
static func _generate_chunk_into(voxels, materials, scale: float, chunk: Vector3i,
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array) -> void:
	var chunk_origin := chunk * CHUNK_SIZE

	for x in CHUNK_SIZE:
		for y in CHUNK_SIZE:
			for z in CHUNK_SIZE:
				var pos := chunk_origin + Vector3i(x, y, z)
				var mat_id: int = voxels.get(pos, -1)
				if mat_id < 0:
					continue
				var mat = _get_mat(materials, mat_id)
				var is_trans: bool = mat != null and mat.trans > 0
				for face_idx in 6:
					var dir: Vector3i = _DIRS[face_idx]
					var n_id: int = voxels.get(pos + dir, -1)
					var n_mat = _get_mat(materials, n_id)
					var n_trans: bool = n_mat != null and n_mat.trans > 0
					var visible := n_id < 0 or (is_trans != n_trans) or (mat_id != n_id)
					if not visible:
						continue
					_add_face(solid_verts, solid_normals, solid_uvs, solid_idxs,
						trans_verts, trans_normals, trans_uvs, trans_idxs,
						pos, mat_id, face_idx, scale, is_trans)


static func _get_mat(materials, mat_id: int):
	return VoxelMaterial.find_by_id(materials, mat_id)


# 6 个面的方向向量（与 FaceTool.Normals 同一组方向，统一数据源）
const _DIRS: Array[Vector3i] = [
	Vector3i(FaceTool.Normals[0]), Vector3i(FaceTool.Normals[1]),
	Vector3i(FaceTool.Normals[2]), Vector3i(FaceTool.Normals[3]),
	Vector3i(FaceTool.Normals[4]), Vector3i(FaceTool.Normals[5]),
]


## 添加一个面（两个三角形，6 顶点）
## 与 VoxelMeshGenerator 共用 FaceTool.Faces 面片数据，确保法线/缠绕方向完全一致
static func _add_face(
		solid_verts: PackedVector3Array, solid_normals: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_normals: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		pos: Vector3i, mat_id: int, face_idx: int, scale: float, is_trans: bool) -> void:
	var normal: Vector3 = FaceTool.Normals[face_idx]
	var u := (float(mat_id) + 0.5) / 256.0
	# FaceTool.Faces[face_idx] 已按 CCW 拆好 6 个顶点（两个三角形）
	for point: Vector3 in FaceTool.Faces[face_idx]:
		var world_pos := (Vector3(pos) + point) * scale
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
