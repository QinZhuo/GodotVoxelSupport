class_name VoxelEditKernel
extends RefCounted

## 体素编辑内核：**无场景节点、无 `_process`、可无头调用**。

## 破坏形状常量（对应原生 damage_shape 的 shape 参数）
const SHAPE_SPHERE: int = 0
const SHAPE_BOX: int = 1

## 伤害结算（一趟原生）：范围 → 材质 → 硬度比较 → 累伤 / 判移除。
func apply_damage(data: QVoxelSource, shape: int, center: Vector3, radius: float,
		vmin: Vector3i, vmax: Vector3i, damage_per_voxel: float, use_voxel_health: bool) -> Dictionary:
	if data == null:
		return {"removed": [], "hardened": {}, "hardened_dirty": false}
	var res := NativeLoader.damage_shape(data._chunk_buffers_view(), data._damage_buffers_view(),
		shape, center, radius, vmin, vmax, hardness_table(data), damage_per_voxel,
		use_voxel_health, {})
	# 伤害缓冲回写（原生在本地副本上改，契约同 remove_voxels_bulk）
	data._set_damage_buffers(res.get("damage_chunks", {}))
	var hpos: PackedVector3Array = res.get("hardened_pos", PackedVector3Array())
	var hrem: PackedFloat32Array = res.get("hardened_rem", PackedFloat32Array())
	var hardened := {}
	for i in hpos.size():
		hardened[Vector3i(hpos[i])] = hrem[i] if i < hrem.size() else 0.0
	var removed: Array = []
	for v in res.get("removed", PackedVector3Array()):
		removed.append(Vector3i(v))
	return {"removed": removed, "hardened": hardened, "hardened_dirty": not hpos.is_empty()}

## 材质硬度查表（索引 = 材质ID）：一次 ≤256 项扫描，之后原生按 ID 直读。
func hardness_table(data: QVoxelSource) -> PackedFloat32Array:
	var mats: Array = data.materials if data != null else []
	var out := PackedFloat32Array()
	out.resize(maxi(mats.size(), VoxelMaterial.MAX_MATERIAL_ID))
	out.fill(1.0)
	for i in mats.size():
		var m = mats[i]
		if m != null:
			out[i] = m.hardness
	return out

## 应力传播（裂纹扩散）：从被移除的体素出发向邻居传播应力，
func propagate_stress(data: QVoxelSource, removed: Array,
		max_steps: int, force: float, decay: float) -> Array:
	if data == null or removed.is_empty():
		return []
	return NativeLoader.propagate_stress(data._chunk_buffers_view(), removed,
		strength_table(data), max_steps, force, decay)

## 材质连接强度预取表（索引 = 材质ID）：BFS 内直接数组读，替代逐邻居 as 转换 + 动态属性访问。
func strength_table(data: QVoxelSource) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	var mats: Array = data.materials if data != null else []
	table.resize(maxi(mats.size(), VoxelMaterial.MAX_MATERIAL_ID))
	table.fill(10.0)
	for i in mats.size():
		var m = mats[i]
		if m:
			table[i] = m.connection_strength
	return table

## 失稳（悬空）体素检测：与地面（y==0）6 方向连通的体素算有支撑，其余算失稳。
func find_unstable(data: QVoxelSource, local: bool, around_positions: Array = []) -> Array:
	if data == null or data.is_empty():
		return []
	var use_local: bool = local and not around_positions.is_empty()
	var unstable_set: Dictionary = data.find_unsupported_around(around_positions) if use_local else data.find_unsupported()
	var unstable: Array = []
	for key in unstable_set:
		unstable.append(key)
	return unstable
