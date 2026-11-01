class_name VoxAssetWorld
extends RefCounted

## `.vox` 资产 → QVoxelWorld（世界）—— **从 VoxAsset 拆出的"世界侧"适配**。
## 【为什么单独一个类】`VoxAsset`（Importer/基础层）只该管"`.vox` 字节 ↔ 资产结构"，不该拖着
## 世界 / 场景图 / 求值这一层（`Model/`）。拆开后，"只把 `.vox` 导入成静态网格"的游戏不必编译 `Model/`。
## 【语义与原来完全一致】镜像 `.vox` 的场景图：nTRN / nGRP 容器 → QVoxelGroup（嵌套保留）、
## nSHP → QVoxelModel；带图层的节点其组名取图层名、可见性取 `_hidden` 的反。
## 【与 get_voxels 逐帧同构】递归规则对齐 VoxAsset.get_models：从 node 0 起、跳过隐藏图层的
## 整棵子树、同一模型被多个形状引用就摆多份；摆放 = 祖先变换 ×（模型居中 + 紧致盒重定位）。
## nTRN 多帧摆放与 nSHP 逐帧换模型会烘焙进 `QVoxelModel` 的体素帧，因此每一帧的体素集合
## 仍与 `VoxAsset.get_voxels(k)` 一致。
static func to_world(vox: VoxAsset) -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.materials = _world_materials(vox)
	var ctx := {
		"frames": _frame_count(vox),
		"animated": false,
		"abs": {},
	}
	ctx.animated = int(ctx.frames) > 1
	if ctx.animated:
		var root_abs: Array[Transform3D] = []
		root_abs.resize(ctx.frames)
		for i in root_abs.size():
			root_abs[i] = Transform3D.IDENTITY
		var visited := {}
		if vox.nodes.has(0) and vox.nodes[0] != null:
			_collect_abs_frames(vox, 0, root_abs, ctx.abs, visited)
		for id in _top_vox_ids(vox):
			if not (ctx.abs as Dictionary).has(int(id)):
				_collect_abs_frames(vox, int(id), root_abs, ctx.abs, visited)
	for id in _top_vox_ids(vox):
		_build_world_node(w, vox, int(id), null, Transform3D.IDENTITY, ctx,
				Transform3D.IDENTITY)
	return w


## `.vox` 的全局帧数 = 所有节点关键帧的最大帧号 + 1（至少 1）。
static func _frame_count(vox: VoxAsset) -> int:
	var n := 1
	for id in vox.nodes:
		var node: VoxAsset.VoxelNode = vox.nodes[id]
		if node == null:
			continue
		for k in node.frames:
			n = maxi(n, int(k) + 1)
	return n


## 预计算每个节点在每一帧的**世界变换**（含祖先）；节点缺失的帧沿用上一关键帧。
static func _collect_abs_frames(vox: VoxAsset, id: int, parent_abs: Array[Transform3D],
		out: Dictionary, visited: Dictionary) -> void:
	if visited.has(id) or not vox.nodes.has(id) or vox.nodes[id] == null:
		return
	visited[id] = true
	var n: VoxAsset.VoxelNode = vox.nodes[id]
	var abs: Array[Transform3D] = []
	abs.resize(parent_abs.size())
	for k in parent_abs.size():
		abs[k] = parent_abs[k] * _frame_xf(n, k)
	out[id] = abs
	for c in n.child_nodes:
		_collect_abs_frames(vox, int(c), abs, out, visited)


## 顶层节点：折叠根部的"结构壳"样板链（MagicaVoxel 的 nTRN(0) → nGRP(1) → …），
## 若停在结构壳（如包住所有对象的 nGRP）则把它的孩子提到顶层 —— 世界顶层就是用户真正建的层 / 组。
static func _top_vox_ids(vox: VoxAsset) -> Array:
	if not vox.nodes.has(0) or vox.nodes[0] == null:
		return []
	var id := 0
	var guard := 0
	while guard < 64 and _is_structural(vox, id) and _child_ids(vox, id).size() == 1:
		id = int(_child_ids(vox, id)[0])
		guard += 1
	if _is_structural(vox, id):
		return _child_ids(vox, id)
	return [id]


## 结构壳 = 无名字、不属任何图层、无模型帧、但有子节点（纯结构的 nTRN / nGRP）。
## 导入时**不单独成组**：它的变换并入孩子、它的孩子提到上一层 —— 于是不会多出"匿名组"。
static func _is_structural(vox: VoxAsset, id: int) -> bool:
	if not vox.nodes.has(id) or vox.nodes[id] == null:
		return false
	var n: VoxAsset.VoxelNode = vox.nodes[id]
	return n.name.is_empty() and not vox.layers.has(n.layerId) and not _has_model_frame(vox, n) \
			and _child_ids(vox, id).size() > 0


static func _child_ids(vox: VoxAsset, id: int) -> Array:
	if not vox.nodes.has(id) or vox.nodes[id] == null:
		return []
	return vox.nodes[id].child_nodes


## 预计算表里某节点第 0 帧的世界变换（静态构建不需要，回落到传入值）。
static func _abs0(ctx: Dictionary, id: int, fallback: Transform3D) -> Transform3D:
	var table: Dictionary = ctx.get("abs", {})
	if table.has(id):
		var arr: Array = table[id]
		if not arr.is_empty():
			return arr[0]
	return fallback


static func _has_model_frame(vox: VoxAsset, n: VoxAsset.VoxelNode) -> bool:
	if not n.frames.has(0):
		return false
	var f: VoxAsset.VoxelFrame = n.frames[0]
	return f != null and f.model_id >= 0 and f.model_id < vox.models.size()


## 节点自身局部变换（无 position/rotation 则恒等）。
static func _node_xf(n: VoxAsset.VoxelNode) -> Transform3D:
	return _frame_xf(n, 0)


## 第 frame 帧的节点局部变换：取 ≤frame 的最近一个带 position/rotation 的关键帧。
static func _frame_xf(n: VoxAsset.VoxelNode, frame: int) -> Transform3D:
	var best := -1
	var xf := Transform3D.IDENTITY
	for k in n.frames:
		var ki := int(k)
		if ki > frame or ki <= best:
			continue
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and (f.rotation != null or f.position != null):
			best = ki
			xf = f.transform
	return xf


## 第 frame 帧的形状模型 id（≤frame 的最近一个有效 model_id；没有则 -1）。
static func _model_id_at(vox: VoxAsset, n: VoxAsset.VoxelNode, frame: int) -> int:
	var best := -1
	var mid := -1
	for k in n.frames:
		var ki := int(k)
		if ki > frame or ki <= best:
			continue
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and f.model_id >= 0 and f.model_id < vox.models.size():
			best = ki
			mid = f.model_id
	return mid


## 递归镜像一个 `.vox` 节点到世界（挂在 parent 下）。`carry` = 被折叠掉的结构壳累积下来的变换。
## 隐藏图层的子树不参与（与 get_models 一致），但保留一个不可见组（图层 ↔ 组仍一一对应）。
static func _build_world_node(w: QVoxelWorld, vox: VoxAsset, id: int, parent: QVoxelGroup,
		carry: Transform3D, ctx: Dictionary, parent_abs0: Transform3D) -> void:
	if not vox.nodes.has(id) or vox.nodes[id] == null:
		return
	var n: VoxAsset.VoxelNode = vox.nodes[id]
	var kids := _child_ids(vox, id)
	if n.layerId in vox.layers and not vox.layers[n.layerId].isVisible:
		if not _has_model_frame(vox, n) and kids.size() > 0:
			var gh := w.create_group(_group_name(vox, n), parent)
			gh.visible = false
		return
	var xf := carry * _node_xf(n)
	if _is_structural(vox, id):
		# 结构壳：不单独成组 —— 变换并入孩子、孩子提到上一层。
		for c in kids:
			_build_world_node(w, vox, int(c), parent, xf, ctx, parent_abs0)
		return
	var has_model := _has_model_frame(vox, n)
	# 「变换节点 + 单个形状节点」折叠成一个模型，不单独成组。
	# 【为什么无名字也折叠】MagicaVoxel 的对象就是"一个 nTRN(变换) 挂一个 nSHP(形状)"，
	# 而我们的 `QVoxelModel` 本身带 `local_transform` —— 再包一层组只是把同一件事拆成两层。
	# 不折叠的话每次往返都会多出一批"只有一个孩子的空组"（实测 cars.vox：9 个 nTRN 涨到 15）。
	if not has_model and kids.size() == 1:
		var cid := int(kids[0])
		var c0: VoxAsset.VoxelNode = vox.nodes.get(cid)
		if c0 != null and _has_model_frame(vox, c0) and _child_ids(vox, cid).is_empty():
			if ctx.animated and _make_baked_model(w, vox, c0.id, parent, parent_abs0, ctx, n.name):
				return
			var cxf := xf * _node_xf(c0)
			var cmid := _model_id_at(vox, c0, 0)
			if cmid >= 0:
				var qm := _make_world_model(w, vox.models[cmid], cxf, parent, n.name)
				qm.visible = not (n.hidden or c0.hidden)
			return
	if has_model and kids.is_empty():
		if ctx.animated and _make_baked_model(w, vox, n.id, parent, parent_abs0, ctx):
			return
		var mid := _model_id_at(vox, n, 0)
		if mid >= 0:
			var qm := _make_world_model(w, vox.models[mid], xf, parent)
			qm.visible = not n.hidden
		return
	if not has_model and kids.is_empty():
		return  # 空壳节点：没有内容
	var g := w.create_group(_group_name(vox, n), parent)
	g.visible = _group_visible(vox, n)
	g.local_transform = xf
	var g_abs0 := _abs0(ctx, n.id, xf)
	if has_model:
		# 既有模型又有子节点：组包住"模型 + 子树"（与 get_models 的"先子后己"同构）。
		if ctx.animated and _make_baked_model(w, vox, n.id, g, g_abs0, ctx):
			pass
		else:
			var mid := _model_id_at(vox, n, 0)
			if mid >= 0:
				_make_world_model(w, vox.models[mid], Transform3D.IDENTITY, g)
	for c in kids:
		_build_world_node(w, vox, int(c), g, Transform3D.IDENTITY, ctx, g_abs0)


## 一个形状引用 → QVoxelModel（本地内容 + 紧致盒重定位；摆放 = 形状节点变换 × 居中/重定位平移）。
## 可见性由调用方设置 —— 它取决于"节点 hidden ∨ 图层 hidden"，只有调用处同时持有两者。
static func _make_world_model(w: QVoxelWorld, m: VoxAsset.VoxelModel, xf: Transform3D,
		parent: QVoxelGroup, node_name := "") -> QVoxelModel:
	var bounds := _voxel_bounds(m.voxels)
	var grid: Vector3i = bounds["size"]
	var base: Vector3i = bounds["min"]
	var qm := w.create_model(node_name, grid, parent)
	for pos: Vector3i in m.voxels:
		var c: Vector3i = pos - base
		qm.set_voxel(c.x, c.y, c.z, m.voxels[pos])
	# world = xf * (voxel + offset)，局部坐标 c = voxel - base ⇒
	# world = (xf ∘ T(base+offset)) * c。整数平移 ⇒ 旋转仍保整数。
	qm.local_transform = xf * _offset_shift(m, base)
	return qm


## 该形状节点有几帧带模型（>1 = .vox 体素动画）。
static func _model_frame_count(vox: VoxAsset, n: VoxAsset.VoxelNode) -> int:
	var c := 0
	for k in n.frames:
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and f.model_id >= 0 and f.model_id < vox.models.size():
			c += 1
	return c


## `.vox` 的 nTRN 摆放动画 + nSHP 逐帧换模型 → **一个 QVoxelModel 的体素帧动画**。
## 关键：把"第 k 帧世界变换 / 第 k 帧模型"烘焙进**静态父层级**下的局部体素坐标。
## 返回 false 表示该实例在所有帧都没有变化，调用方回落静态模型（避免无谓的整模型复制）。
static func _make_baked_model(w: QVoxelWorld, vox: VoxAsset, node_id: int, parent: QVoxelGroup,
		parent_abs0: Transform3D, ctx: Dictionary, node_name := "") -> bool:
	var n: VoxAsset.VoxelNode = vox.nodes.get(node_id)
	var abs_table: Dictionary = ctx.get("abs", {})
	if n == null or not abs_table.has(node_id):
		return false
	var abs: Array = abs_table[node_id]
	var frame_count := int(ctx.get("frames", 1))
	if frame_count <= 1 or abs.size() < frame_count:
		return false

	var mids: Array[int] = []
	var first_mid := -1
	var changed := false
	for k in frame_count:
		var mid := _model_id_at(vox, n, k)
		mids.append(mid)
		if first_mid < 0 and mid >= 0:
			first_mid = mid
		if mid != mids[0]:
			changed = true
		if k > 0 and not (abs[k] as Transform3D).is_equal_approx(abs[0]):
			changed = true
	if first_mid < 0 or not changed:
		return false

	var m0: VoxAsset.VoxelModel = vox.models[first_mid]
	var bb := _voxel_bounds(m0.voxels)
	var base0: Vector3i = bb["min"]
	var anchor := Vector3(base0) + m0.offset
	var abs0: Transform3D = abs[0]

	# 先求所有帧烘焙后的局部包围盒（坐标已扣掉静态基准），再统一平移到非负。
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for k in frame_count:
		var mid := mids[k]
		if mid < 0:
			continue
		var mk: VoxAsset.VoxelModel = vox.models[mid]
		var d := abs0.affine_inverse() * (abs[k] as Transform3D)
		for pos: Vector3i in mk.voxels:
			var c := _baked_pos(d, Vector3(pos) + mk.offset, anchor)
			mn = Vector3i(mini(mn.x, c.x), mini(mn.y, c.y), mini(mn.z, c.z))
			mx = Vector3i(maxi(mx.x, c.x), maxi(mx.y, c.y), maxi(mx.z, c.z))
	if mn.x > mx.x:
		return false
	var shift := mn
	var grid := mx - mn + Vector3i.ONE

	var qm := w.create_model(node_name, grid, parent)
	qm.visible = not n.hidden
	qm.make_animated()
	for i in range(1, frame_count):
		qm.add_frame(QVoxelFrame.new(), i)
	for k in frame_count:
		var mid := mids[k]
		if mid < 0:
			continue
		var mk: VoxAsset.VoxelModel = vox.models[mid]
		var d := abs0.affine_inverse() * (abs[k] as Transform3D)
		for pos: Vector3i in mk.voxels:
			var c := _baked_pos(d, Vector3(pos) + mk.offset, anchor) - shift
			qm.set_frame_voxel(k, c.x, c.y, c.z, mk.voxels[pos])

	# 局部摆放 = 父静态变换⁻¹ × 本节点第 0 帧世界变换 × 静态基准（含统一平移 shift）。
	qm.local_transform = parent_abs0.affine_inverse() * abs0 \
			* Transform3D(Basis.IDENTITY, anchor + Vector3(shift))
	return true


static func _baked_pos(d: Transform3D, p: Vector3, anchor: Vector3) -> Vector3i:
	var v := d * p - anchor
	return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))


## 组名：节点自带名优先。节点没名字时退一步借外部文件的图层名 —— 那是**读取兼容**
## （某些 .vox 把名字记在 LAYR 上），本项目的组名只来自节点自身，不从图层推导。
static func _group_name(vox: VoxAsset, n: VoxAsset.VoxelNode) -> String:
	if not n.name.is_empty():
		return n.name
	if vox.layers.has(n.layerId):
		var layer: VoxAsset.VoxelLayer = vox.layers[n.layerId]
		if layer != null and not layer.name.is_empty():
			return layer.name
		return "Layer %d" % int(n.layerId)
	return ""


## 可见性 = **节点级 `_hidden` 与图层级隐藏取与**：两处任一为隐藏，整棵子树都不显示。
## 本项目的 `QVoxelNode.visible` 是节点属性，图层只是外部文件里的另一种隐藏来源。
static func _group_visible(vox: VoxAsset, n: VoxAsset.VoxelNode) -> bool:
	if n.hidden:
		return false
	if vox.layers.has(n.layerId) and vox.layers[n.layerId] != null:
		return vox.layers[n.layerId].isVisible
	return true


## 场景图变换与居中偏移的合成：Translate(base + model.offset)。
static func _offset_shift(m: VoxAsset.VoxelModel, base: Vector3i) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(base) + m.offset)


## 体素坐标的紧致包围盒（供 QVoxelModel 的非负局部坐标与尺寸）。空模型返回原点 + 1³。
static func _voxel_bounds(voxels: Dictionary) -> Dictionary:
	if voxels.is_empty():
		return {"min": Vector3i.ZERO, "size": Vector3i.ONE}
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for pos: Vector3i in voxels:
		mn = Vector3i(mini(mn.x, pos.x), mini(mn.y, pos.y), mini(mn.z, pos.z))
		mx = Vector3i(maxi(mx.x, pos.x), maxi(mx.y, pos.y), maxi(mx.z, pos.z))
	return {"min": mn, "size": mx - mn + Vector3i.ONE}


## VoxAsset 材质表 → QVX MATE 条目数组（索引即材质 ID，条目 0 恒为空气）。
static func _world_materials(vox: VoxAsset) -> Array:
	var out: Array = []
	for i in 256:
		var src: VoxelMaterial = vox.materials[i] if i < vox.materials.size() else null
		out.append(_mate_entry(src))
	return out


## VoxelMaterial → MATE 条目（含 QVoxelWorld._color_of 需要的 r/g/b/a 视图）。
static func _mate_entry(mat: VoxelMaterial) -> Dictionary:
	var e := VoxelMaterial.to_mate(mat)
	var rgba := int(e.get("rgba", 0))
	e["r"] = (rgba >> 24) & 0xFF
	e["g"] = (rgba >> 16) & 0xFF
	e["b"] = (rgba >> 8) & 0xFF
	e["a"] = rgba & 0xFF
	return e
