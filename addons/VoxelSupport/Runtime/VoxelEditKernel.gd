class_name VoxelEditKernel
extends RefCounted

## 体素编辑内核：**无场景节点、无 `_process`、可无头调用**（P2-4）。
##
## 【定位】把"编辑数学"从表现层节点里抽出来，只依赖 `VoxelData` + `NativeLoader`：
##   · 无 Node / 无场景树 / 无物理 / 无粒子 / 无信号 —— 服务端、建模"画笔"、批处理工具
##     都可以 `VoxelEditKernel.new()` 后直接调用，**不需要一个 `VoxelDestructible` 节点**：
##       var k := VoxelEditKernel.new()
##       var r := k.apply_damage(data, VoxelEditKernel.SHAPE_SPHERE, c, 3.0, Vector3i.ZERO, Vector3i.ZERO, 1.0, true)
##       data.remove_voxels(r["removed"])
##       var broken := k.propagate_stress(data, r["removed"], 3, 15.0, 0.5)
##       data.remove_voxels(broken)
##       var unstable := k.find_unstable(data, false)
##   · **配置旋钮不在内核里存**：`RefCounted` 挂不了 `@export`，而伤害量 / 应力参数 / 硬度开关
##     都是 Inspector 旋钮 → 一律由调用方按参数传入（见 `VoxelDestructible` 的同名 `@export`）。
##   · **表现层职责不在内核里**：粒子碎片、掉落刚体、级联分帧调度、信号发射、帧尾合并、
##     诊断输出都留在 `VoxelDestructible`。内核只产出"发生了什么"的数据，不决定怎么演。
##
## 【无状态】逐体素累计伤害账归 `VoxelData`（体素相邻状态，必须与 chunk 缓冲同生共死——
##   卸载 / 清空 / origin shift / 载荷重建都要同步清理），内核通过
##   `data.get_damage_buffers()` / `data.set_damage_buffers()` 读写，自己不持有任何状态。
##   因此同一个内核实例可以长期复用、可以跨多个 `VoxelData` 使用。
##
## 【与原生库的关系】原生库（`NativeLoader`）是强制依赖，本内核不做 GDScript 回退：
##   全部数学都是一趟原生调用（伤害结算 / 应力传播），GDScript 侧只做入参组装与结果搬运。


## 破坏形状常量（对应原生 damage_shape 的 shape 参数）
const SHAPE_SPHERE: int = 0
const SHAPE_BOX: int = 1


## 伤害结算（一趟原生）：范围 → 材质 → 硬度比较 → 累伤 / 判移除。
##
## 语义与原逐体素 GDScript 版完全一致（`use_voxel_health` / 硬度 / 累伤 / 硬化反馈），只是下沉 C++：
##   · 伤害账本从 Dictionary[Vector3i, float] 改为按 chunk 的扁平 Float32 缓冲（原生直接读写）；
##   · 材质硬度按材质ID 查表一次传下去（原实现是逐体素 `materials[id]` 读取）。
##
## 返回 `{removed: Array[Vector3i], hardened: Dictionary, hardened_dirty: bool}`：
##   `removed`        本趟应被移除的体素（**调用方**负责实际 `data.remove_voxels`，内核不删）
##   `hardened`       受伤但未摧毁的 `{pos: 剩余硬度}`（数据产出，帧尾合并信号是表现层的事）
##   `hardened_dirty` 本次是否有硬化反馈（省得调用方再判空）
func apply_damage(data: VoxelData, shape: int, center: Vector3, radius: float,
		vmin: Vector3i, vmax: Vector3i, damage_per_voxel: float, use_voxel_health: bool) -> Dictionary:
	if data == null:
		return {"removed": [], "hardened": {}, "hardened_dirty": false}
	var res := NativeLoader.damage_shape(data.get_chunk_buffers(), data.get_damage_buffers(),
		shape, center, radius, vmin, vmax, hardness_table(data), damage_per_voxel,
		use_voxel_health, {})
	# 伤害缓冲回写（原生在本地副本上改，契约同 remove_voxels_bulk）
	data.set_damage_buffers(res.get("damage_chunks", {}))
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
## 表长下界取 `MAX_MATERIAL_ID`：原生按 ID 直读，表若短于最大体素材质ID 会越界读
## （短表只可能出现在"材质数组与实际体素ID 不同步"的损坏数据上，此处兜住）。
func hardness_table(data: VoxelData) -> PackedFloat32Array:
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
## 邻居材质 `connection_strength` 不足以承受应力则断裂。
## 原生 C++（chunk 缓冲直读 + 材质强度查表），无 GDScript 回退。
## 返回所有因应力传播而断裂的体素位置（**调用方**负责实际移除）。
func propagate_stress(data: VoxelData, removed: Array,
		max_steps: int, force: float, decay: float) -> Array:
	if data == null or removed.is_empty():
		return []
	return NativeLoader.propagate_stress(data.get_chunk_buffers(), removed,
		strength_table(data), max_steps, force, decay)


## 材质连接强度预取表（索引 = 材质ID）：BFS 内直接数组读，替代逐邻居 as 转换 + 动态属性访问。
## 无效材质取默认 10.0。表长下界同 `hardness_table`（原生按 ID 直读，防越界）。
func strength_table(data: VoxelData) -> PackedFloat32Array:
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
##   `local` = true 且 `around_positions` 非空 → 只查破坏点 6 邻附近（中频破坏 + 中型场景）
##   `local` = false 或 `around_positions` 为空   → 全量检测（结果最精确，适合小型场景 / 低频）
## 返回失稳体素位置（**调用方**负责实际移除与表现）。
## 诊断输出留在表现层节点：内核不做 print。
func find_unstable(data: VoxelData, local: bool, around_positions: Array = []) -> Array:
	if data == null or data.is_empty():
		return []
	var use_local: bool = local and not around_positions.is_empty()
	var unstable_set: Dictionary = data.find_unsupported_around(around_positions) if use_local else data.find_unsupported()
	var unstable: Array = []
	for key in unstable_set:
		unstable.append(key)
	return unstable
