class_name VoxAssetWorld
extends RefCounted

## `.vox` 资产 → QVoxelWorld（世界）—— **从 VoxAsset 拆出的"世界侧"适配**。
## 【为什么单独一个类】`VoxAsset`（Importer/基础层）只该管"`.vox` 字节 ↔ 资产结构"，不该拖着
## 世界 / 场景图 / 求值这一层（`Model/`）。拆开后，"只把 `.vox` 导入成静态网格"的游戏不必编译 `Model/`。
## 【语义与原来完全一致】镜像 `.vox` 的场景图：nTRN / nGRP 容器 → QVoxelGroup（嵌套保留）、
## nSHP → QVoxelModel；带图层的节点其组名取图层名、可见性取 `_hidden` 的反。
## 【与 get_voxels 逐像素同构】递归规则对齐 VoxAsset.get_models：从 node 0 起、跳过隐藏图层的
## 整棵子树、同一模型被多个形状引用就摆多份；摆放 = 祖先变换 ×（模型居中 + 紧致盒重定位）。
## 于是世界求值出的体素集合与 `.vox` 渲染路径完全一致。
static func to_world(vox: VoxAsset) -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.materials = _world_materials(vox)
	for id in _top_vox_ids(vox):
		_build_world_node(w, vox, int(id), null, Transform3D.IDENTITY)
	return w


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


## 结构壳 = 无名字、不属任何图层、无模型帧、**无多帧摆放动画**、但有子节点（纯结构的 nTRN / nGRP）。
## 导入时**不单独成组**：它的变换并入孩子、它的孩子提到上一层 —— 于是不会多出"匿名组"。
static func _is_structural(vox: VoxAsset, id: int) -> bool:
	if not vox.nodes.has(id) or vox.nodes[id] == null:
		return false
	var n: VoxAsset.VoxelNode = vox.nodes[id]
	return n.name.is_empty() and not vox.layers.has(n.layerId) and not _has_model_frame(vox, n) \
			and not _has_transform_anim(n) and _child_ids(vox, id).size() > 0


static func _child_ids(vox: VoxAsset, id: int) -> Array:
	if not vox.nodes.has(id) or vox.nodes[id] == null:
		return []
	return vox.nodes[id].child_nodes


static func _has_model_frame(vox: VoxAsset, n: VoxAsset.VoxelNode) -> bool:
	if not n.frames.has(0):
		return false
	var f: VoxAsset.VoxelFrame = n.frames[0]
	return f != null and f.model_id >= 0 and f.model_id < vox.models.size()


## 节点自身局部变换（无 position/rotation 则恒等）。
static func _node_xf(n: VoxAsset.VoxelNode) -> Transform3D:
	if not n.frames.has(0):
		return Transform3D.IDENTITY
	var f: VoxAsset.VoxelFrame = n.frames[0]
	if f == null or (f.rotation == null and f.position == null):
		return Transform3D.IDENTITY
	return f.transform


## 该节点是否有**多帧**变换（`.vox` 的 nTRN 多帧摆放动画）。
static func _has_transform_anim(n: VoxAsset.VoxelNode) -> bool:
	var count := 0
	for k in n.frames:
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and (f.position != null or f.rotation != null):
			count += 1
			if count > 1:
				return true
	return false


## 第 k 帧的节点变换（缺失回落到第 0 帧 / 恒等）。
static func _frame_xf(n: VoxAsset.VoxelNode, k: int) -> Transform3D:
	if n.frames.has(k):
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and (f.position != null or f.rotation != null):
			return f.transform
	return _node_xf(n)


## 逐帧摆放轨道（按最大帧号稠密铺开）。仅 `_has_transform_anim` 为真时调用。
static func _transform_tracks(n: VoxAsset.VoxelNode) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var mx := -1
	for k in n.frames:
		mx = maxi(mx, int(k))
	for k in mx + 1:
		out.append(_frame_xf(n, k))
	return out


## 递归镜像一个 `.vox` 节点到世界（挂在 parent 下）。`carry` = 被折叠掉的结构壳累积下来的变换。
## 隐藏图层的子树不参与（与 get_models 一致），但保留一个不可见组（图层 ↔ 组仍一一对应）。
static func _build_world_node(w: QVoxelWorld, vox: VoxAsset, id: int, parent: QVoxelGroup,
		carry: Transform3D) -> void:
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
			_build_world_node(w, vox, int(c), parent, xf)
		return
	var has_model := _has_model_frame(vox, n)
	# 命名包装（nTRN 带 name、单子且子是形状）：名字并进模型，不单独成组 —— 于是"模型名"能往返。
	if not has_model and not n.name.is_empty() and kids.size() == 1:
		var cid := int(kids[0])
		var c0: VoxAsset.VoxelNode = vox.nodes.get(cid)
		if c0 != null and _has_model_frame(vox, c0) and _child_ids(vox, cid).is_empty():
			var cxf := xf * _node_xf(c0)
			if _model_frame_count(vox, c0) > 1:
				_make_world_animated_model(w, vox, c0, cxf, parent, n.name)
			else:
				_make_world_model(w, vox.models[c0.frames[0].model_id], cxf, parent, n.name)
			return
	if has_model and kids.is_empty():
		# 多帧 nSHP（同一形状逐帧换模型 = .vox 的**体素动画**）→ QVoxelModel 的 ANIM 帧。
		if _model_frame_count(vox, n) > 1:
			_make_world_animated_model(w, vox, n, xf, parent)
		else:
			_make_world_model(w, vox.models[n.frames[0].model_id], xf, parent)
		return
	if not has_model and kids.is_empty():
		return  # 空壳节点：没有内容
	var g := w.create_group(_group_name(vox, n), parent)
	g.visible = _group_visible(vox, n)
	g.local_transform = xf
	# 多帧摆放动画 → 逐帧轨道（`.vox` 的 nTRN 多帧）。被折叠结构壳的静态变换(carry)并入每帧。
	if _has_transform_anim(n):
		var tracks := _transform_tracks(n)
		for i in tracks.size():
			tracks[i] = carry * tracks[i]
		g.transform_tracks = tracks
	if has_model:
		# 既有模型又有子节点：组包住"模型 + 子树"（与 get_models 的"先子后己"同构）。
		_make_world_model(w, vox.models[n.frames[0].model_id], Transform3D.IDENTITY, g)
	for c in kids:
		_build_world_node(w, vox, int(c), g, Transform3D.IDENTITY)


## 一个形状引用 → QVoxelModel（本地内容 + 紧致盒重定位；摆放 = 形状节点变换 × 居中/重定位平移）。
static func _make_world_model(w: QVoxelWorld, m: VoxAsset.VoxelModel, xf: Transform3D,
		parent: QVoxelGroup, node_name := "") -> void:
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


## 该形状节点有几帧带模型（>1 = .vox 体素动画）。
static func _model_frame_count(vox: VoxAsset, n: VoxAsset.VoxelNode) -> int:
	var c := 0
	for k in n.frames:
		var f: VoxAsset.VoxelFrame = n.frames[k]
		if f != null and f.model_id >= 0 and f.model_id < vox.models.size():
			c += 1
	return c


## 多帧 nSHP（逐帧换模型）→ QVoxelModel 的 **ANIM 帧**：所有帧共用一个分辨率（各帧模型包围盒并集），
## 摆放沿用形状节点变换 ×（第 0 帧模型的居中/重定位平移）。于是 `.vox` 的体素动画在编辑器里可播可编辑。
static func _make_world_animated_model(w: QVoxelWorld, vox: VoxAsset, n: VoxAsset.VoxelNode,
		xf: Transform3D, parent: QVoxelGroup, node_name := "") -> void:
	var maxk := 0
	for k in n.frames:
		maxk = maxi(maxk, int(k))
	var mids: Array[int] = []
	for k in maxk + 1:
		var f: VoxAsset.VoxelFrame = n.frames.get(k)
		mids.append(f.model_id if (f != null and f.model_id >= 0 and f.model_id < vox.models.size()) else -1)
	# 各帧模型内容的并集包围盒 → 共用分辨率。
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for mid in mids:
		if mid < 0:
			continue
		var bb := _voxel_bounds(vox.models[mid].voxels)
		var bmin: Vector3i = bb["min"]
		var bmax: Vector3i = bmin + (bb["size"] as Vector3i) - Vector3i.ONE
		mn = Vector3i(mini(mn.x, bmin.x), mini(mn.y, bmin.y), mini(mn.z, bmin.z))
		mx = Vector3i(maxi(mx.x, bmax.x), maxi(mx.y, bmax.y), maxi(mx.z, bmax.z))
	var base := mn
	var grid: Vector3i = mx - mn + Vector3i.ONE
	var qm := w.create_model(node_name, grid, parent)
	qm.make_animated()
	for i in range(1, mids.size()):
		qm.add_frame(QVoxelFrame.new(), i)
	for idx in mids.size():
		var mid := mids[idx]
		if mid < 0:
			continue
		var m: VoxAsset.VoxelModel = vox.models[mid]
		for pos: Vector3i in m.voxels:
			var c: Vector3i = pos - base
			qm.set_frame_voxel(idx, c.x, c.y, c.z, m.voxels[pos])
	var first_mid := mids[0] if mids[0] >= 0 else 0
	qm.local_transform = xf * _offset_shift(vox.models[first_mid], base)


## 组名：节点自带名优先，其次图层名（无名图层给 "Layer N"），都没有则留空（用默认名）。
static func _group_name(vox: VoxAsset, n: VoxAsset.VoxelNode) -> String:
	if not n.name.is_empty():
		return n.name
	if vox.layers.has(n.layerId):
		var layer: VoxAsset.VoxelLayer = vox.layers[n.layerId]
		if layer != null and not layer.name.is_empty():
			return layer.name
		return "Layer %d" % int(n.layerId)
	return ""


static func _group_visible(vox: VoxAsset, n: VoxAsset.VoxelNode) -> bool:
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
