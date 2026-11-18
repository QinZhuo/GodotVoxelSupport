class_name VoxelMesher
extends RefCounted

## 网格化层：**纯静态、无状态、无节点**。输入体素，输出几何。
##
## 【为什么独立成类】此前这一步散在三处：`VoxelChunkGenerator`（单 chunk 组装 +
## `_merge_meshes`）、`VoxelRenderer._generate_chunk_worker`（拼装调用）、
## `VoxelMeshGenerator`（导入路径）。三处各自持有"顶点数组长什么样"的知识，
## 于是加一个属性（比如顶点色）要同时改三处。
##
## 本类只做两件事：
##   1. 把「体素缓冲」变成「几何数组」（几何内核在 C++，这里只是调用 + 拼接）；
##   2. 把「几何数组」变成 `ArrayMesh`（surface 数 ≤ 2：实体 / 透明）。
##
## ❌ 不做：脏账本、异步调度、GPU 限流、LOD、流式、碰撞 —— 全在渲染核心/组件里。

## 术语：**chunk** = 32³ 体素（`VoxelChunk.CHUNK_SIZE`）；**group** = group_chunks³ 个 chunk，
## 是 DYNAMIC 模式的绘制单元（一个 group 一个 MeshInstance3D）。


## 整份模型 → 几何数组（一次原生调用：分 chunk + 光环 + 面生成 + 合并 + 索引偏移，全在 C++）。
## [param buffers] chunk_key → 32³ 密集缓冲。**可以只含一部分 chunk**，但边界处的面会被多画
##   （原生按"传入集合"判邻居）—— 需要正确剔除就传全量，或用 build_group 的手段补光环。
## 返回 {solid_verts, solid_normals, solid_uvs, solid_idxs, trans_*, ...}；空模型返回 {}。
static func build_all(buffers: Dictionary, materials: Array, scale: float,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if buffers.is_empty():
		return {}
	var trans_flags := VoxelMaterial.build_trans_flags(VoxelMaterial.align_by_id(materials))
	return NativeLoader.generate_arrays_from_chunks_native(buffers, trans_flags, scale, offset)


## 一组 chunk（group）→ 几何数组。
##
## 【与 build_all 的区别】build_all 把一整份字典交给原生，原生会给字典里**每个** chunk 生成网格。
## 而这里只要 group 内的 chunk 出网格，却需要 group 外一圈邻居参与"面是否可见"的判定。
## 原生 API 不区分"出网格"与"仅提供邻居"，所以改为：
##   逐 chunk 用 halo（由 buffers 自行外扩 1 体素）生成 → GDScript 侧拼接。
## 这样邻居信息齐全（不会多画面），且只输出 group 内的 chunk。
##
## [param buffers] chunk_key → 32³ 缓冲。**必须包含 group 外一圈邻居**，否则边界面会多画。
## [param group_key] 组坐标 = chunk_key >> group_shift。
## [param group_shift] 组边长 = 2^group_shift 个 chunk（1 → 2 chunk/边，2 → 4 chunk/边…）。
## [param chunk_keys] group 内需要出网格的 chunk（由调用方按"数据里真实存在"筛好）。
##
## 【顶点要按组原点平移 —— 交给原生做，不要 GDScript 逐顶点加】
## 单 chunk 生成的顶点是 **chunk 局部**坐标（原点 = 该 chunk 角），而一个 group 会被挂成
## 一个 MeshInstance3D 放在"组原点的世界位置"。所以每个 chunk 的顶点要平移
## `(ck - group_origin) × chunk_size_world`，否则整组几何会叠在一起。
##
## **关键：原生 `generate_chunk_dense` 的 `offset` 参数就是干这个的**（单位 = 体素，
## 内部乘 scale）。故每个 chunk 直接把 `offset + 相对偏移` 交给原生，GDScript 侧只拼接、
## 完全不平移顶点。实测 teapot1（gs=1，35 组 / 158 chunk）：逐顶点平移 1.62ms → 0。
## 【为何不各自传一份 offset 再拼】原生已把平移烘进顶点，拼接就退化成纯 append（均摊 O(m)）。
static func build_group(buffers: Dictionary, group_key: Vector3i, group_shift: int,
		chunk_keys: Array, materials: Array, scale: float,
		offset: Vector3 = Vector3.ZERO) -> Dictionary:
	if chunk_keys.is_empty():
		return {}
	var aligned := VoxelMaterial.align_by_id(materials)
	var trans_flags := VoxelMaterial.build_trans_flags(aligned)
	var out := _new_arrays()
	# 组原点（chunk 单位）。每个 chunk 的相对偏移换算成**体素单位**再叠到 offset 上。
	var group_origin := group_origin_chunk(group_key, group_shift)
	for ck in chunk_keys:
		var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, ck)
		if halo.is_empty():
			continue
		var rel_voxels := Vector3(ck - group_origin) * float(VoxelChunk.CHUNK_SIZE)
		var arr: Dictionary = VoxelChunkGenerator.generate_single_chunk_dense(
				halo, aligned, scale, ck, offset + rel_voxels, trans_flags)
		if arr.is_empty():
			continue
		append_arrays(out, arr, Vector3.ZERO)
	return out


## 把多份几何数组拼成一份，返回拼接后的实体顶点基数（供下次调用当 base）。
## `dst` 与 `src` 都是 _new_arrays() 的形状。
##
## [param vertex_offset] 拼接前给 `src` 的**全部顶点**加上这个平移量。
## 【为什么需要它】单 chunk 生成的顶点在 **chunk 局部空间**（原点 = 该 chunk 的角）。
## 把多个 chunk 合成一个 mesh（DYNAMIC 分组）时，必须按"各 chunk 相对组原点的偏移"平移顶点，
## 否则所有 chunk 的几何会叠在组原点上。索引只需加顶点基数，平移必须逐顶点做。
##
## 【性能：取局部引用 + append_array，不要 `dst[k] = dst[k] + src_arr`】
## 后者每次新建整份 PackedArray 并全量拷贝 → N 次追加是 O(N²)。
## 实测 teapot1 组内 64 chunk（`group_shift=2`）时：直接相加 4.28ms，改用 append_array 后 ~0.9ms（4.7×）。
## 分组粒度越粗差距越大，而 gs=2 正是文档推荐的"draw 优先"档位，所以这条必须写对。
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
		# 局部引用 → append_array（均摊 O(m)）→ 写回。写回只是存引用，不触发拷贝。
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
## [param materials] 运行时 Material 数组（索引 0=实体、1=透明）。为 null/空时不绑材质。
## 返回 null 表示没有任何可渲染的面。
static func to_mesh(arrays: Dictionary, materials: Array = []) -> ArrayMesh:
	if arrays.is_empty():
		return null
	var result := ArrayMesh.new()
	var any := false
	for i in 2:
		var prefix := "solid" if i == 0 else "trans"
		var ids: PackedInt32Array = arrays.get(prefix + "_idxs", PackedInt32Array())
		if ids.is_empty():
			continue
		var sa: Array = []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = arrays.get(prefix + "_verts", PackedVector3Array())
		sa[Mesh.ARRAY_NORMAL] = arrays.get(prefix + "_normals", PackedVector3Array())
		sa[Mesh.ARRAY_TEX_UV] = arrays.get(prefix + "_uvs", PackedVector2Array())
		sa[Mesh.ARRAY_INDEX] = ids
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)
		if i < materials.size() and materials[i] != null:
			result.surface_set_material(result.get_surface_count() - 1, materials[i])
		any = true
	return result if any else null


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


## 组坐标 ↔ chunk 坐标转换（DYNAMIC 模式的分组键）。唯一实现，避免各处各写一遍移位。
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


# ── STATIC 模式的共享 mesh 缓存 ────────────────────────────────────────────────
#
# 【为什么必须有这一层】STATIC 的收益**完全来自"多个实例共享同一份 ArrayMesh 资源"**：
# Godot 只对「同一 mesh 资源 + 同一材质」的多个 MeshInstance3D 自动合批。若每个
# VoxelRenderer 各自建一份 mesh，draw call 仍是"实例数"，等于白做。
# 实测 deer×100：各自一份 mesh → 532 draw / 10 fps；共享一份 → 5 draw / 与导入 mesh 持平。
#
# 【失效策略】键 = (data 实例 id, voxel_scale)。data 变化时由第一个察觉的 renderer 调
# invalidate() 整条丢弃，其余 renderer 随后 acquire 时重建一次、之后共享 —— 因为所有挂在
# 同一份 data 上的 renderer 会同时收到 changed 信号，重建只会发生一次。
#
# 【为什么不放数据层】把它挂在 QVoxelSource 上就是"数据层持有渲染概念"，正是本次重构要消除的。

static var _shared: Dictionary = {}


static func _shared_key(data: QVoxelSource, scale: float) -> String:
	return "%d|%.6f" % [data.get_instance_id(), scale]


## 取（必要时构建）某份数据在 STATIC 模式下的共享 mesh。
## [param builder] 无参 Callable，返回 ArrayMesh；只在缓存未命中时调用。
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


## 让某份数据的共享 mesh 失效（data 内容/材质变化后调用）。下一次 acquire 会重建。
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
