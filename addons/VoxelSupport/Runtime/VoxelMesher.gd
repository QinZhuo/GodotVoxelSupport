class_name VoxelMesher
extends RefCounted

## 网格化层：**纯静态、无状态、无节点**。

## 术语：**chunk** = 32³ 体素（`VoxelChunk.CHUNK_SIZE`）；**group** =…

## 整份模型 → 几何数组（一次原生调用：分 chunk + 光环 + 面生成 + 合并 + 索引偏移，全在 C++）。
static func build_all(buffers: Dictionary, materials: Array, scale: float,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if buffers.is_empty():
		return {}
	var trans_flags := VoxelMaterial.build_trans_flags(VoxelMaterial.align_by_id(materials))
	return NativeLoader.generate_arrays_from_chunks_native(buffers, trans_flags, scale, offset)

## 把多份几何数组拼成一份，返回拼接后的实体顶点基数（供下次调用当 base）。
static func append_arrays(dst: Dictionary, src: Dictionary, vertex_offset: Vector3 = Vector3.ZERO) -> int:
	var base := (dst["solid_verts"] as PackedVector3Array).size()
	var trans_base := (dst["trans_verts"] as PackedVector3Array).size()
	for prefix in ["solid", "trans"]:
		var verts: PackedVector3Array = src.get(prefix + "_verts", PackedVector3Array())
		if verts.is_empty():
			continue
		if vertex_offset != Vector3.ZERO:
			# 先 duplicate 再就地加：不改 src（worker 产出可能被复用），也不新建"空+resize"的中间数组
			verts = verts.duplicate()
			for i in verts.size():
				verts[i] += vertex_offset
		var ids: PackedInt32Array = src.get(prefix + "_idxs", PackedInt32Array())
		var offset := base if prefix == "solid" else trans_base
		if not ids.is_empty() and offset != 0:
			ids = ids.duplicate()
			for i in ids.size():
				ids[i] += offset
		# 局部引用 → append_array（均摊 O(m)）→ 写回。
		var dst_v: PackedVector3Array = dst[prefix + "_verts"]
		dst_v.append_array(verts)
		dst[prefix + "_verts"] = dst_v
		var dst_n: PackedVector3Array = dst[prefix + "_normals"]
		dst_n.append_array(src.get(prefix + "_normals", PackedVector3Array()))
		dst[prefix + "_normals"] = dst_n
		var dst_u: PackedVector2Array = dst[prefix + "_uvs"]
		dst_u.append_array(src.get(prefix + "_uvs", PackedVector2Array()))
		dst[prefix + "_uvs"] = dst_u
		var dst_i: PackedInt32Array = dst[prefix + "_idxs"]
		dst_i.append_array(ids)
		dst[prefix + "_idxs"] = dst_i
	return base

## 几何数组 → ArrayMesh（1~2 个 surface：0=实体、1=透明）。
static func to_mesh(arrays: Dictionary, materials: Array = []) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not VoxelMeshGenerator.append_arrays_to_mesh(mesh, arrays, materials):
		return null
	return mesh

## 几何数组的三角形总数（统计 / 断言用）
static func triangle_count(arrays: Dictionary) -> int:
	var n := 0
	for prefix in ["solid", "trans"]:
		n += (arrays.get(prefix + "_idxs", PackedInt32Array()) as PackedInt32Array).size() / 3
	return n

## 几何数组的顶点总数
static func vertex_count(arrays: Dictionary) -> int:
	var n := 0
	for prefix in ["solid", "trans"]:
		n += (arrays.get(prefix + "_verts", PackedVector3Array()) as PackedVector3Array).size()
	return n

## 空的几何数组容器（唯一构造点：拼接与生成器必须共用同一形状）
static func _new_arrays() -> Dictionary:
	return {
		"solid_verts": PackedVector3Array(),
		"solid_normals": PackedVector3Array(),
		"solid_uvs": PackedVector2Array(),
		"solid_idxs": PackedInt32Array(),
		"trans_verts": PackedVector3Array(),
		"trans_normals": PackedVector3Array(),
		"trans_uvs": PackedVector2Array(),
		"trans_idxs": PackedInt32Array(),
	}

## 组坐标 ↔ chunk 坐标转换（DYNAMIC 模式的分组键）。
static func group_of(chunk_key: Vector3i, group_shift: int) -> Vector3i:
	return Vector3i(chunk_key.x >> group_shift, chunk_key.y >> group_shift, chunk_key.z >> group_shift)

## 组内第一个 chunk 的坐标（组的世界原点由它推出）
static func group_origin_chunk(group_key: Vector3i, group_shift: int) -> Vector3i:
	return Vector3i(group_key.x << group_shift, group_key.y << group_shift, group_key.z << group_shift)

## 列出组内的全部 chunk 坐标（不判断数据是否存在；调用方自行过滤）
static func chunks_in_group(group_key: Vector3i, group_shift: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var n := 1 << group_shift
	var origin := group_origin_chunk(group_key, group_shift)
	for z in n:
		for y in n:
			for x in n:
				out.append(origin + Vector3i(x, y, z))
	return out

# ── STATIC 模式的共享 mesh 缓存 ──────────────────────────────────────────────…

static var _shared: Dictionary = {}

static func _shared_key(data: QVoxelSource, scale: float) -> String:
	return "%d|%.6f" % [data.get_instance_id(), scale]

## 取（必要时构建）某份数据在 STATIC 模式下的共享 mesh。
static func acquire_shared_mesh(data: QVoxelSource, scale: float, builder: Callable) -> ArrayMesh:
	if data == null:
		return null
	var key := _shared_key(data, scale)
	var hit: ArrayMesh = _shared.get(key)
	if hit != null and is_instance_valid(hit):
		return hit
	var built: ArrayMesh = builder.call()
	if built != null:
		_shared[key] = built
	return built

## 让某份数据的共享 mesh 失效（data 内容/材质变化后调用）。
static func invalidate_shared_mesh(data: QVoxelSource) -> void:
	if data == null:
		return
	var prefix := "%d|" % data.get_instance_id()
	for k in _shared.keys():
		if String(k).begins_with(prefix):
			_shared.erase(k)

## 当前缓存条目数（诊断 / 测试用）
static func shared_mesh_count() -> int:
	return _shared.size()

## 清空共享缓存（测试用；生产不需要）
static func clear_shared_meshes() -> void:
	_shared.clear()
