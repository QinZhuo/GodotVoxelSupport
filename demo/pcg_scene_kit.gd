class_name PcgSceneKit
extends RefCounted

## PCG 场景共享组装工具（静态类，只做"把模型装成节点"这一件事）。
##
## 【为什么需要它】既有两个 demo（pcg_models_demo / pcg_operators_demo）各自抄了一份
## 同构的 `_add_model` / `_material` / `_wfc_tile` / `_overlap_sample`。再加 5 个场景
## 就是 5 份拷贝，改一处要改 7 处。这里给出唯一一份实现，场景脚本只描述"造什么"。
##
## 【为什么不重构既有两个 demo】它们已验证可用，且组织方式与各自讲的主题耦合，
## 动它们只有风险没有收益。新场景一律走本工具。
##
## 【一个程序化模型 = 什么】有界 VoxelData（grid_size 即生成范围）
## + 一个 VoxelGenerator（PcgModelGenerator 或 PcgSdfGenerator）
## + 一个 VoxelRenderer / VoxelDestructible 节点。
## 因为产出就是一个普通节点，"编辑 / 破坏 / 物理 / 碰撞 / LOD"全部自动可用——
## 换可破坏版本只是 `VoxelDestructible.new()` 替掉 `VoxelRenderer.new()`，其余一字不改。

## 一个模型的默认世界尺度（32³ 体素 → 6.4 世界单位）。
## 1 chunk = 32 体素 = 6.4 世界单位，故 128 宽的基底 = 25.6 世界单位。
const DEFAULT_VOXEL_SCALE := 0.2


## 由紧凑描述批量造材质。
##
## 每项为 `[id, color, rough]`，可选第 4 项 `trans`（透明度，0 = 不透明）。
## 物理参数用一套与既有 demo 一致的常量：硬、韧、中等质量——够"能打能崩"演示用。
static func materials(specs: Array) -> Array:
	var out: Array = []
	for spec in specs:
		var m := VoxelMaterial.new()
		m.id = int(spec[0])
		m.color = spec[1] as Color
		m.rough = float(spec[2])
		if spec.size() > 3:
			m.trans = float(spec[3])
		m.hardness = 5.0
		m.connection_strength = 20.0
		m.mass = 2.0
		out.append(m)
	return out


## 组装一个模型并挂到 parent 上，返回该节点（供场景持有引用 / 做破坏目标 / 统计）。
##
## generator 直接传入（`PcgModelGenerator` 或 `PcgSdfGenerator`），因为"用哪种注入方式"
## 恰是各场景要展示的内容之一，不该被本工具藏掉。
## destructible = true 时用 VoxelDestructible 替掉 VoxelRenderer（见 destruction_demo 的接线）。
static func add_model(parent: Node3D, model_name: String, pos: Vector3, generator: VoxelGenerator,
		grid_size: Vector3i, mats: Array, destructible := false,
		voxel_scale := DEFAULT_VOXEL_SCALE) -> Node3D:
	var data := VoxelData.new()
	for m in mats:
		data.add_material(m)
	data.generator = generator
	data.grid_size = grid_size

	var node: Node3D
	if destructible:
		var d := VoxelDestructible.new()
		# 与 destruction_demo 同一套破坏参数：碎片粒子 + 局部增量崩塌。
		d.lod_count = 3
		d.spawn_debris_on_damage = true
		d.use_voxel_health = true
		d.damage_per_voxel = 1.0
		d.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
		d.local_collapse = true
		node = d
	else:
		node = VoxelRenderer.new()

	node.name = model_name
	node.data = data
	node.voxel_scale = voxel_scale
	# 有界模型：FULL 让"grid_size 覆盖到的 chunk 全建出来"，无需相机驱动流式加载。
	# 大 grid_size（如 128 宽基底）配合大 view_distance 会在首帧做立方枚举，故
	# 场景必须让 view_distance 覆盖模型的实际范围而不是一味放大。
	node.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	parent.add_child(node)
	node.global_position = pos
	return node


## 构造一块 WFC 图块：solid(x, y, z) 返回 true 的格子填 material_id。
##
## sockets 顺序与 PcgWfc 一致：+X, -X, +Y, -Y, +Z, -Z。接口名相同的面才能相邻——
## 这是 socket 式 WFC 唯一的约束来源，也是它"手动但可控"的代价。
static func wfc_tile(tile_size: Vector3i, sockets: Array, weight: float, material_id: int,
		solid: Callable) -> PcgWfcTile:
	var voxels := PackedInt32Array()
	voxels.resize(tile_size.x * tile_size.y * tile_size.z)
	for z in tile_size.z:
		for y in tile_size.y:
			for x in tile_size.x:
				if solid.call(x, y, z):
					voxels[x + y * tile_size.x + z * tile_size.x * tile_size.y] = material_id
	return PcgWfcTile.make(tile_size, voxels, PackedStringArray(sockets), weight)


## 重叠式 WFC 的样例：一块多孔岩 —— 实心岩石里挖出孔洞，部分孔洞填另一种材质。
##
## 【样例怎么挑：重叠式能不能求出解，全看样例的图案有没有重复】
##   ① 不能是"地板 + 一圈墙"这类**稀疏骨架**：8³ 里大部分为空的样例学出的图案
##      绝大多数是纯空气，且纯空气自相容，WFC 会整体坍缩进"整块全空"的退化解。
##   ② 也不能是**白噪声**：每个 N³ 窗口都唯一（8³ 配 N=3 即 216/216 全不同），
##      相容图近乎一条无环长链，铺到网格边缘必然死路，重试多少次都矛盾（实测）。
##   ③ 要的是**致密 + 图案重复**：孔洞用两族周期互质（5 与 6）的斜切取并集，
##      于是 8³ 样例内每族各自重复数轮，学出的图案既能拼、又有多样性。
## 单族斜切是平行平面，输出会露出明显的"格栅"；两族相交后才成团状的天然孔隙。
static func overlap_sample(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var m := 0
				if (x + 2 * y + 3 * z) % 5 < 2 or (2 * x + y - z) % 6 < 2:
					m = 2 if (x + z) % 3 == 0 else 1
				v[x + y * size.x + z * size.x * size.y] = m
	return v