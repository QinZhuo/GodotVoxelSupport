class_name VoxelChunkGenerator
## 高性能体素网格生成器（Chunk 分区 + 增量重建）
##
## 相比 VoxelMeshGenerator 的全局网格生成，本生成器：
##   - 将体素世界划分为固定大小的 chunk，每个 chunk 独立生成网格
##   - 支持"增量重建"：只重新生成发生变化的 chunk，而非全量重建
## 对大型动态场景（如水模拟、地形编辑）性能提升显著。

## 单个 chunk 的边长（体素个数），chunk 越大网格合并效率越高但增量重建粒度越粗
const CHUNK_SIZE := 16


## 运行时网格生成入口（全量或增量）
## 通过 rebuild_chunks 指定只重建部分 chunk；为空则全量生成
static func generate_mesh_runtime(
		voxels: Dictionary[Vector3i, int],
		materials: Array,
		options: Dictionary = {},
		rebuild_chunks: Array[Vector3i] = []) -> ArrayMesh:
	var scale: float = options.get("scale", 0.1)
	var aligned := _align_materials(materials)

	# 确定需要重建的 chunk
	var chunk_keys: Array[Vector3i] = []
	if rebuild_chunks.is_empty():
		chunk_keys = _all_chunks(voxels)
	else:
		chunk_keys = _unique(rebuild_chunks)

	if chunk_keys.is_empty():
		return null

	# 合并所有 chunk 的面片
	var all_solid_verts := PackedVector3Array()
	var all_solid_uvs := PackedVector2Array()
	var all_solid_idxs := PackedInt32Array()
	var all_trans_verts := PackedVector3Array()
	var all_trans_uvs := PackedVector2Array()
	var all_trans_idxs := PackedInt32Array()

	for ck in chunk_keys:
		_generate_chunk_into(voxels, aligned, scale, ck,
			all_solid_verts, all_solid_uvs, all_solid_idxs,
			all_trans_verts, all_trans_uvs, all_trans_idxs)

	return _merge_meshes(all_solid_verts, all_solid_uvs, all_solid_idxs,
		all_trans_verts, all_trans_uvs, all_trans_idxs)


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


static func _all_chunks(voxels) -> Array[Vector3i]:
	var chunk_keys: Array[Vector3i] = []
	for pos_key in voxels:
		var ck := _chunk_of(pos_key)
		if not chunk_keys.has(ck):
			chunk_keys.append(ck)
	return chunk_keys


static func _unique(arr: Array[Vector3i]) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for v in arr:
		if not result.has(v):
			result.append(v)
	return result


## 生成单个 chunk 的面片并追加到全局数组
static func _generate_chunk_into(voxels, materials, scale: float, chunk: Vector3i,
		solid_verts: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array) -> void:
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
					_add_face(solid_verts, solid_uvs, solid_idxs,
						trans_verts, trans_uvs, trans_idxs,
						pos, mat_id, face_idx, scale, is_trans)


static func _get_mat(materials, mat_id: int):
	if mat_id < 0 or mat_id >= materials.size():
		return null
	return materials[mat_id]


const _DIRS: Array[Vector3i] = [
	Vector3i(0, 1, 0),  Vector3i(0, -1, 0),  # top, bottom
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),   # left, right
	Vector3i(0, 0, 1),  Vector3i(0, 0, -1),  # front, back
]

# 每个面的 4 个角（单位立方体局部坐标）
const _FACE_CORNERS: Array = [
	[Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)],  # top
	[Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)],  # bottom
	[Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)],  # left
	[Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1)],  # right
	[Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)],  # front
	[Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)],  # back
]


## 添加一个面（两个三角形，6 顶点）
static func _add_face(
		solid_verts: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array,
		pos: Vector3i, mat_id: int, face_idx: int, scale: float, is_trans: bool) -> void:
	var corners: Array = _FACE_CORNERS[face_idx]
	# 当前表面顶点基数
	var base := solid_verts.size() if not is_trans else trans_verts.size()
	var u := (float(mat_id) + 0.5) / 256.0
	# 三角形 0-1-2 和 0-2-3（每面 6 个顶点，两个三角形）
	var tri := [[0, 1, 2], [0, 2, 3]]
	for t in tri:
		for k in 3:
			var corner: Vector3 = corners[t[k]]
			var world_pos := (Vector3(pos) + corner) * scale
			if is_trans:
				trans_verts.append(world_pos)
				trans_uvs.append(Vector2(u, 0.0))
				trans_idxs.append(base + trans_verts.size() - 1)
			else:
				solid_verts.append(world_pos)
				solid_uvs.append(Vector2(u, 0.0))
				solid_idxs.append(base + solid_verts.size() - 1)


static func _merge_meshes(solid_verts: PackedVector3Array, solid_uvs: PackedVector2Array, solid_idxs: PackedInt32Array,
		trans_verts: PackedVector3Array, trans_uvs: PackedVector2Array, trans_idxs: PackedInt32Array) -> ArrayMesh:
	var result := ArrayMesh.new()
	var has_any := false
	if not solid_idxs.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_arrays(solid_verts, solid_uvs, solid_idxs))
		has_any = true
	if not trans_idxs.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_arrays(trans_verts, trans_uvs, trans_idxs))
		has_any = true
	if not has_any:
		return null
	return result


static func _make_arrays(verts: PackedVector3Array, uvs: PackedVector2Array, idxs: PackedInt32Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs
	return arrays


static func _align_materials(materials: Array) -> Array:
	var aligned: Array = []
	for mat in materials:
		if mat == null:
			continue
		var mat_id: int = mat.id
		while aligned.size() <= mat_id:
			aligned.append(null)
		aligned[mat_id] = mat
	return aligned
