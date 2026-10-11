class_name VoxAsset
extends RefCounted

## MagicaVoxel（`.vox`）资产的宿主：模型 / 材质 / 场景图（nTRN·nGRP·nSHP·LAYR）/ 动画帧。
## 【只服务 `.vox`】`.qvx` 的对应概念形状不同（一个 `model_id` 一个 `VXEL` + `NODE` 定位，
## 没有 `nSHP`/frame/`Z` 翻转那套约定），由 `QVoxelAsset` 承载。把 `.qvx` 塞进本类会丢
## NODE 与多模型信息（详见 QVoxelAsset 类注释），故 `from_asset()` 遇到 `.qvx` 会直接报错。

const SUPPORTED_EXTENSIONS := ["vox", "qvx"]

## `.vox` 的扩展名（本类实际处理的格式）。`SUPPORTED_EXTENSIONS` 是两个格式的合集，
## 供四个导入器统一声明"识别哪些扩展名"。
const VOX_EXTENSION := "vox"


## 按扩展名把资产文件解析为 VoxAsset；不支持的格式或解析失败返回 null。
static func from_asset(path: String) -> VoxAsset:
	if QVoxelAsset.handles(path):
		push_error("[VoxAsset] %s 是 .qvx：请改用 QVoxelAsset.from_file()。"
				% path + "（VoxAsset 是 MagicaVoxel 专用适配器，硬塞会丢 NODE 与多模型信息）")
		return null
	var access := VoxAccess.Open(path)
	return access.voxel if access != null else null


## 世界 → `.vox` 资产（**结构保留**：每个模型一个 SIZE/XYZI，每个顶层组一条 LAYR，节点摆放 → nTRN）。
## 与 `from_asset`（读）恰成一对进出；与 `from_node`（把一块体积拍平）不同，这里保持
## "多模型 + 图层 + 摆放"，于是 `.qvx` ⇄ `.vox` 往返后结构与显示都一致。
## 【为什么不再拍平成一块】旧实现把整世界合成一个模型（画面一致但结构尽失）。现在编辑器
## 自身已支持"每个模型独立尺寸 + 自由摆放 + 组嵌套"，导出自然应把这些结构写回 `.vox`
## —— 图层（LAYR）与组一一对应、摆放进 nTRN，正是 `.vox` 的分层/场景图语义。
static func from_world(world: QVoxelWorld, _ctx: QVoxelEvalContext = null,
		flatten_animation := false) -> VoxAsset:
	var out := VoxAsset.new()
	out._build_structured(world, flatten_animation)
	return out


## 世界 → 结构化 `.vox` 资产（填入 self 的 materials / models / nodes / layers）。
## 【节点图】root nTRN(0) → nGRP(1) → 每个顶层节点一个 nTRN 包装（携带变换与图层）→ 其子树。
## 模型是 nSHP（只带 model_id），摆放挂在包它的 nTRN 上 —— nSHP 的帧首字段是 model_id，装不下
## 位置/旋转（见 VoxAccess._shape_frames 与 _write_transform 的分工）。
func _build_structured(world: QVoxelWorld, flatten_animation := false) -> void:
	# 材质：索引 0 恒为空；1..255 从世界 MATE 逐条解释（与 from_result 同一套摆放契约）。
	materials.resize(256)
	for i in range(1, 256):
		var mat := VoxelMaterial.new()
		mat.id = i
		materials[i] = mat
	if world == null:
		return
	for i in range(1, mini(256, world.materials.size())):
		if world.materials[i] is Dictionary:
			materials[i] = VoxelMaterial.from_mate(world.materials[i], i)
	# 图层：每个顶层组一条 LAYR（组名 = 图层名，可见性 = `_hidden` 的反）。
	var layer_of := {}
	var layer_id := 0
	for top in world.nodes:
		if top is QVoxelGroup:
			var l := VoxelLayer.new()
			l.id = layer_id
			l.name = (top as QVoxelGroup).node_name
			l.isVisible = top.visible
			layers[layer_id] = l
			layer_of[top] = layer_id
			layer_id += 1
	# 场景图（模型在 _emit_node 里顺带产出，动画模型会产出多块）。
	var next := [2]
	var root := VoxelNode.new()
	root.id = 0
	root.child_nodes.append(1)
	var topgrp := VoxelNode.new()
	topgrp.id = 1
	for top in world.nodes:
		if top != null:
			topgrp.child_nodes.append(_emit_node(top, int(layer_of.get(top, -1)), next, flatten_animation))
	nodes[0] = root
	nodes[1] = topgrp


## 递归把一个 QVoxelNode 写进节点图，返回其外层 nTRN 的 id（包装变换与图层）。
## 模型顺带产出 VoxelModel（动画模型每帧一块），因此不需要预建 model 索引。
## `flatten` = 动画模型只导出**当前帧**（逐帧烘焙用），否则导出多帧 nSHP。
func _emit_node(node: QVoxelNode, layer: int, next: Array, flatten := false) -> int:
	if node.is_model():
		var qm := node as QVoxelModel
		var grid := qm.grid_size
		var shp := VoxelNode.new()
		shp.id = next[0]
		next[0] += 1
		if qm.is_animated() and not flatten:
			# 体素动画：每帧一个 VoxelModel，nSHP 逐帧引用（= `.vox` 的 nSHP 多帧）。
			for k in qm.frame_count():
				var fk := VoxelFrame.new()
				fk.model_id = models.size()
				shp.frames[k] = fk
				models.append(_model_from_volume(grid, qm.frame_volume(k)))
		else:
			var f0 := VoxelFrame.new()
			f0.model_id = models.size()
			shp.frames[0] = f0
			models.append(_model_from_volume(grid, qm.to_volume()))
		nodes[shp.id] = shp
		# 抵消 `.vox` 的"按尺寸居中 + Z 平移"约定，使导出的 `.vox` 渲染（get_voxels）与世界求值
		# 逐格一致：get_voxels 摆的是 `node_xf * (key + offset)`，key = 局部坐标 + e（e = 0,0,-(gz-1)），
		# 故令 node_xf = W ∘ T(-(e + centering))，导入时 base(=e+minp) 会抵消掉，结果 = W * 局部坐标。
		var e := Vector3(0, 0, -float(grid.z - 1))
		var off := Transform3D(Basis.IDENTITY, -(e + _centering(grid)))
		var tracks: Array[Transform3D] = []
		for t in node.transform_tracks:
			tracks.append(t * off)
		return _emit_wrapper(shp.id, node.local_transform * off, layer, next, tracks, qm.node_name)
	var grp := VoxelNode.new()
	grp.id = next[0]
	next[0] += 1
	for c in (node as QVoxelGroup).child_nodes:
		if c != null:
			# 图层沿子树**下传**：MagicaVoxel 的图层挂在 nTRN 上且不继承，故该层内每个节点都写。
			grp.child_nodes.append(_emit_node(c, layer, next, flatten))
	nodes[grp.id] = grp
	return _emit_wrapper(grp.id, node.local_transform, layer, next, node.transform_tracks, node.node_name)


## `.vox` 对模型的居中偏移（VoxAsset.VoxelModel.size setter 的同一算法）。
static func _centering(grid: Vector3i) -> Vector3:
	return Vector3(-floori(grid.x / 2.0), -floori(grid.y / 2.0), floori(grid.z / 2.0))


## 造一个"包装节点"：单子 nTRN，携带变换、layerId 与名字（VoxAccess 据此写 nTRN）。
## `tracks` 非空时写成 nTRN 的**多帧变换**（摆放动画）；否则只写第 0 帧。
func _emit_wrapper(child_id: int, xf: Transform3D, layer: int, next: Array,
		tracks: Array[Transform3D] = [], node_name := "") -> int:
	var trn := VoxelNode.new()
	trn.id = next[0]
	next[0] += 1
	trn.child_nodes.append(child_id)
	trn.layerId = layer
	trn.name = node_name
	if tracks.is_empty():
		trn.frames[0] = _frame_of_transform(xf)
	else:
		for k in tracks.size():
			trn.frames[k] = _frame_of_transform(tracks[k])
	nodes[trn.id] = trn
	return trn.id


## 模块局部变换 → nTRN 帧。缺省分量不写（位置为 0 / 无旋转时留空帧）。
## `VoxelFrame.position` 存的是 Y-up 世界坐标（VoxAccess 读 `_t` 时已换算），故直接拷 origin。
static func _frame_of_transform(xf: Transform3D) -> VoxelFrame:
	var f := VoxelFrame.new()
	if not xf.origin.is_zero_approx():
		f.position = xf.origin
	var q := xf.basis.get_rotation_quaternion()
	if not q.is_equal_approx(Quaternion.IDENTITY):
		f.rotation = xf.basis
	return f


## 一块本地密集体积 → VoxAsset.VoxelModel（Z 平移那套约定与 from_result 同源）。
static func _model_from_volume(grid: Vector3i, volume: PackedInt32Array) -> VoxelModel:
	var model := VoxelModel.new()
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		return model
	model.size = Vector3(grid)
	var z_shift := grid.z - 1
	for i in volume.size():
		var material: int = volume[i]
		if material == 0:
			continue
		var p := VoxelVolume.pos_of(i, grid)
		model.voxels[Vector3i(p.x, p.y, p.z - z_shift)] = material
	return model


## 树上任一节点（组 / 模型）→ `.vox` 资产：**只取该节点自己局部盒里的体积**，不含它在父画布里的
## 摆放（摆放是"在哪个世界"的信息，而一份独立文件里没有那个世界）。
## 批量导出的"每个节点 / 每个模型"走这条路。与 `from_world` 共用 `from_result` —— 于是
## "一块体积怎么变成资产"（含 Z 翻转那套约定）全项目只有一份实现，多一条出口就多一处能写错的地方。
static func from_node(world: QVoxelWorld, node: QVoxelNode, ctx: QVoxelEvalContext = null) -> VoxAsset:
	return from_result(world, QVoxelEvalEngine.evaluate_node(node,
			ctx if ctx != null else QVoxelEvalContext.new()))


## 求值结果 → `.vox` 资产：**世界 / 组 / 模型三条出口共用的最后一段**（材质表 + 体素搬运）。
static func from_result(world: QVoxelWorld, res: QVoxelEvalResult) -> VoxAsset:
	var out := VoxAsset.new()
	# 索引 0 恒为 null 空气占位；1..255 预建并设好 id —— 与 VoxAccess._init 同一套约定，
	# 这样写出的 RGBA 块与读入的资产在"下标 == 材质ID"上完全对齐。
	out.materials.resize(256)
	for i in range(1, 256):
		var mat := VoxelMaterial.new()
		mat.id = i
		out.materials[i] = mat
	if world == null:
		return out
	for i in range(1, mini(256, world.materials.size())):
		out.materials[i].color = world.material_color(i)

	var size := res.grid_size
	if res.volume.is_empty() or size.x <= 0 or size.y <= 0 or size.z <= 0:
		return out  # 世界为空（或全被差集挖空）：给一份"只有调色板"的资产，不造 0 尺寸模型

	var model := VoxelModel.new()
	model.size = Vector3(size)
	# 【为什么 Z 要平移 size.z - 1】原始坐标（.vox 的体素坐标经 `(x,y,z)→(x,z,-y)` 旋转后的样子）
	# 其 Z 轴落在 (-size.z, 0]，而世界盒的 z 在 [0, size.z)。平移后既落回合法区间、又**不镜像**
	# —— 若写成更"对称"的 -z，导出的模型会沿 Z 前后翻转（在 MagicaVoxel 里一眼看不出，
	# 因为对称的模型翻转后长得一样）。
	var z_shift := size.z - 1
	for i in res.volume.size():
		var material: int = res.volume[i]
		if material == 0:
			continue
		var p := VoxelVolume.pos_of(i, size)
		model.voxels[Vector3i(p.x, p.y, p.z - z_shift)] = material
	out.models.append(model)
	return out


## 资产里所有模型盒的**逐轴最大值** —— 导出前的尺寸自检用。
func box() -> Vector3i:
	var b := Vector3i.ZERO
	for m in models:
		b.x = maxi(b.x, int(m.size.x))
		b.y = maxi(b.y, int(m.size.y))
		b.z = maxi(b.z, int(m.size.z))
	return b


## 能不能被 MagicaVoxel 完整打开。上限**按单轴**判（`VoxAccess.MODEL_LIMIT`）：超了它不报错、
## 直接截断，而 XYZI 的坐标是单字节，写口会把 256 以外的体素丢掉 —— 那对用户就是"导出成功了，
## 可我的模型少了一层壳"。单次导出与批量导出都问这一句，判断只此一处。
func fits_magica() -> bool:
	var b := box()
	return maxi(maxi(b.x, b.y), b.z) <= VoxAccess.MODEL_LIMIT


## 资产里体素总数（导出提示里报个数，让用户知道刚才那一下干了多少活）。
func voxel_count() -> int:
	var n := 0
	for m in models:
		n += m.voxels.size()
	return n


# `.vox` → QVoxelier 的编辑模型（结构保留）

## `.vox` 资产 → QVoxelWorld（世界）。**镜像 `.vox` 的场景图**：nTRN / nGRP 容器 → QVoxelGroup
## （嵌套保留），nSHP → QVoxelModel；带图层的节点其组名取图层名、可见性取 `_hidden` 的反。
## 【为什么放这里】它是"外部格式 → 本项目编辑模型"的适配，与 VoxAsset 同属一侧。于是 `.vox`
## 与 `.qvx` 最终都落到**同一个 QVoxelWorld**，编辑 / 求值 / 渲染只有一套语义 —— 这正是"两种
## 格式显示一致"的根本保证。
## 【与 get_voxels 逐像素同构】递归规则对齐 VoxAsset.get_models：从 node 0 起、跳过隐藏图层的
## 整棵子树、同一模型被多个形状引用就摆多份；摆放 = 祖先变换 ×（模型居中 + 紧致盒重定位）。
## 于是世界求值出的体素集合与 `.vox` 渲染路径完全一致。
func to_world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.materials = _world_materials()
	for id in _top_vox_ids():
		_build_world_node(w, int(id), null, Transform3D.IDENTITY)
	return w


## 顶层节点：折叠根部的"结构壳"样板链（MagicaVoxel 的 nTRN(0) → nGRP(1) → …），
## 若停在结构壳（如包住所有对象的 nGRP）则把它的孩子提到顶层 —— 世界顶层就是用户真正建的层 / 组。
func _top_vox_ids() -> Array:
	if not nodes.has(0) or nodes[0] == null:
		return []
	var id := 0
	var guard := 0
	while guard < 64 and _is_structural(id) and _child_ids(id).size() == 1:
		id = int(_child_ids(id)[0])
		guard += 1
	if _is_structural(id):
		return _child_ids(id)
	return [id]


## 结构壳 = 无名字、不属任何图层、无模型帧、**无多帧摆放动画**、但有子节点（纯结构的 nTRN / nGRP）。
## 导入时**不单独成组**：它的变换并入孩子、它的孩子提到上一层 —— 于是不会多出"匿名组"。
## （`.vox` 里"带变换 / 图层的组"必然写成 nTRN 包 nGRP 两层，这个约定不该在编辑器里多出一层。）
func _is_structural(id: int) -> bool:
	if not nodes.has(id) or nodes[id] == null:
		return false
	var n: VoxelNode = nodes[id]
	return n.name.is_empty() and not layers.has(n.layerId) and not _has_model_frame(n) \
			and not _has_transform_anim(n) and _child_ids(id).size() > 0


func _child_ids(id: int) -> Array:
	if not nodes.has(id) or nodes[id] == null:
		return []
	return nodes[id].child_nodes


func _has_model_frame(n: VoxelNode) -> bool:
	if not n.frames.has(0):
		return false
	var f: VoxelFrame = n.frames[0]
	return f != null and f.model_id >= 0 and f.model_id < models.size()


## 节点自身局部变换（无 position/rotation 则恒等）。
static func _node_xf(n: VoxelNode) -> Transform3D:
	if not n.frames.has(0):
		return Transform3D.IDENTITY
	var f: VoxelFrame = n.frames[0]
	if f == null or (f.rotation == null and f.position == null):
		return Transform3D.IDENTITY
	return f.transform


## 该节点是否有**多帧**变换（`.vox` 的 nTRN 多帧摆放动画）。
static func _has_transform_anim(n: VoxelNode) -> bool:
	var count := 0
	for k in n.frames:
		var f: VoxelFrame = n.frames[k]
		if f != null and (f.position != null or f.rotation != null):
			count += 1
			if count > 1:
				return true
	return false


## 第 k 帧的节点变换（缺失回落到第 0 帧 / 恒等）。
static func _frame_xf(n: VoxelNode, k: int) -> Transform3D:
	if n.frames.has(k):
		var f: VoxelFrame = n.frames[k]
		if f != null and (f.position != null or f.rotation != null):
			return f.transform
	return _node_xf(n)


## 逐帧摆放轨道（按最大帧号稠密铺开）。仅 `_has_transform_anim` 为真时调用。
static func _transform_tracks(n: VoxelNode) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var mx := -1
	for k in n.frames:
		mx = maxi(mx, int(k))
	for k in mx + 1:
		out.append(_frame_xf(n, k))
	return out


## 递归镜像一个 `.vox` 节点到世界（挂在 parent 下）。`carry` = 被折叠掉的结构壳累积下来的变换。
## 隐藏图层的子树不参与（与 get_models 一致），但保留一个不可见组（图层 ↔ 组仍一一对应）。
func _build_world_node(w: QVoxelWorld, id: int, parent: QVoxelGroup, carry: Transform3D) -> void:
	if not nodes.has(id) or nodes[id] == null:
		return
	var n: VoxelNode = nodes[id]
	var kids := _child_ids(id)
	if n.layerId in layers and not layers[n.layerId].isVisible:
		if not _has_model_frame(n) and kids.size() > 0:
			var gh := w.create_group(_group_name(n), parent)
			gh.visible = false
		return
	var xf := carry * _node_xf(n)
	if _is_structural(id):
		# 结构壳：不单独成组 —— 变换并入孩子、孩子提到上一层。
		for c in kids:
			_build_world_node(w, int(c), parent, xf)
		return
	var has_model := _has_model_frame(n)
	# 命名包装（nTRN 带 name、单子且子是形状）：名字并进模型，不单独成组 —— 于是"模型名"能往返。
	if not has_model and not n.name.is_empty() and kids.size() == 1:
		var cid := int(kids[0])
		var c0: VoxelNode = nodes.get(cid)
		if c0 != null and _has_model_frame(c0) and _child_ids(cid).is_empty():
			var cxf := xf * _node_xf(c0)
			if _model_frame_count(c0) > 1:
				_make_world_animated_model(w, c0, cxf, parent, n.name)
			else:
				_make_world_model(w, models[c0.frames[0].model_id], cxf, parent, n.name)
			return
	if has_model and kids.is_empty():
		# 多帧 nSHP（同一形状逐帧换模型 = .vox 的**体素动画**）→ QVoxelModel 的 FRAM 帧。
		if _model_frame_count(n) > 1:
			_make_world_animated_model(w, n, xf, parent)
		else:
			_make_world_model(w, models[n.frames[0].model_id], xf, parent)
		return
	if not has_model and kids.is_empty():
		return  # 空壳节点：没有内容
	var g := w.create_group(_group_name(n), parent)
	g.visible = _group_visible(n)
	g.local_transform = xf
	# 多帧摆放动画 → 逐帧轨道（`.vox` 的 nTRN 多帧）。被折叠结构壳的静态变换(carry)并入每帧。
	if _has_transform_anim(n):
		var tracks := _transform_tracks(n)
		for i in tracks.size():
			tracks[i] = carry * tracks[i]
		g.transform_tracks = tracks
	if has_model:
		# 既有模型又有子节点：组包住"模型 + 子树"（与 get_models 的"先子后己"同构）。
		_make_world_model(w, models[n.frames[0].model_id], Transform3D.IDENTITY, g)
	for c in kids:
		_build_world_node(w, int(c), g, Transform3D.IDENTITY)


## 一个形状引用 → QVoxelModel（本地内容 + 紧致盒重定位；摆放 = 形状节点变换 × 居中/重定位平移）。
func _make_world_model(w: QVoxelWorld, m: VoxelModel, xf: Transform3D, parent: QVoxelGroup,
		node_name := "") -> void:
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
func _model_frame_count(n: VoxelNode) -> int:
	var c := 0
	for k in n.frames:
		var f: VoxelFrame = n.frames[k]
		if f != null and f.model_id >= 0 and f.model_id < models.size():
			c += 1
	return c


## 多帧 nSHP（逐帧换模型）→ QVoxelModel 的 **FRAM 帧**：所有帧共用一个分辨率（各帧模型包围盒并集），
## 摆放沿用形状节点变换 ×（第 0 帧模型的居中/重定位平移）。于是 `.vox` 的体素动画在编辑器里可播可编辑。
func _make_world_animated_model(w: QVoxelWorld, n: VoxelNode, xf: Transform3D, parent: QVoxelGroup,
		node_name := "") -> void:
	var maxk := 0
	for k in n.frames:
		maxk = maxi(maxk, int(k))
	var mids: Array[int] = []
	for k in maxk + 1:
		var f: VoxelFrame = n.frames.get(k)
		mids.append(f.model_id if (f != null and f.model_id >= 0 and f.model_id < models.size()) else -1)
	# 各帧模型内容的并集包围盒 → 共用分辨率。
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for mid in mids:
		if mid < 0:
			continue
		var bb := _voxel_bounds(models[mid].voxels)
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
		var m: VoxelModel = models[mid]
		for pos: Vector3i in m.voxels:
			var c: Vector3i = pos - base
			qm.set_frame_voxel(idx, c.x, c.y, c.z, m.voxels[pos])
	var first_mid := mids[0] if mids[0] >= 0 else 0
	qm.local_transform = xf * _offset_shift(models[first_mid], base)


## 组名：节点自带名优先，其次图层名（无名图层给 "Layer N"），都没有则留空（用默认名）。
func _group_name(n: VoxelNode) -> String:
	if not n.name.is_empty():
		return n.name
	if layers.has(n.layerId):
		var layer: VoxelLayer = layers[n.layerId]
		if layer != null and not layer.name.is_empty():
			return layer.name
		return "Layer %d" % int(n.layerId)
	return ""


func _group_visible(n: VoxelNode) -> bool:
	if layers.has(n.layerId) and layers[n.layerId] != null:
		return layers[n.layerId].isVisible
	return true


## 场景图变换与居中偏移的合成：Translate(base + model.offset)。
static func _offset_shift(m: VoxelModel, base: Vector3i) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(base) + m.offset)


## 体素坐标的紧致包围盒（供 QVoxelModel 的非负局部坐标与尺寸）。空模型返回原点 + 1³。
static func _voxel_bounds(voxels: Dictionary[Vector3i, int]) -> Dictionary:
	if voxels.is_empty():
		return {"min": Vector3i.ZERO, "size": Vector3i.ONE}
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for pos: Vector3i in voxels:
		mn = Vector3i(mini(mn.x, pos.x), mini(mn.y, pos.y), mini(mn.z, pos.z))
		mx = Vector3i(maxi(mx.x, pos.x), maxi(mx.y, pos.y), maxi(mx.z, pos.z))
	return {"min": mn, "size": mx - mn + Vector3i.ONE}


## VoxAsset 材质表 → QVX MATE 条目数组（索引即材质 ID，条目 0 恒为空气）。
func _world_materials() -> Array:
	var out: Array = []
	for i in 256:
		var src: VoxelMaterial = materials[i] if i < materials.size() else null
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


var models: Array[VoxelModel]

var materials: Array[VoxelMaterial]

var nodes: Dictionary[int, VoxelNode]

var layers: Dictionary[int, VoxelLayer]

func get_voxels(frame_index: int = 0) -> Dictionary[Vector3i, int]:
	if nodes.size() > 0:
		return nodes[0].get_voxels(self, frame_index)
	return {}


func check_nodes() -> Dictionary:
	# 当 .vox 无场景图(scene graph)时，为每个 model 建一个帧节点，确保能取到体素
	if nodes.size() == 0 and models.size() > 0:
		var node := VoxelNode.new()
		nodes[0] = node
		for i in models.size():
			var frame := VoxelFrame.new()
			frame.model_id = i
			node.frames[i] = frame
	return nodes


func _to_string() -> String:
	return str("nodes:", nodes, "models:", models)

static func get_offset_voxels(voxels: Dictionary[Vector3i, int], offset: Vector3i):
	var result: Dictionary[Vector3i, int]
	for pos in voxels:
		result[pos + offset] = voxels[pos]
	return result


## 导入面板选项名的单一出处：mesh/frame_index、mesh/scale 同时被 Mesh 与 Data 两个
## 导入器使用（VoxelMeshImporter / VoxelDataImporter），值必须与既有 .import 文件完全一致。
const OPT_FRAME_INDEX := "mesh/frame_index"
const OPT_SCALE := "mesh/scale"

## 资产原点模式（取值见 QVoxelSource.OriginMode）。
## 【为什么两个导入器必须同名同义】同一个模型经 "导入成 mesh" 与 "导入成 data" 两条路进场景，
## 原点若各按各的习惯摆，位置就会差一截（本仓库实测差 0.35~0.50）；共用一个选项名与一套
## 语义，是"两条路结果一致"在选项层的表达。
const OPT_ORIGIN := "mesh/origin"


class VoxelModel:
	var size: Vector3:
		set(value):
			size = value
			offset = - (size / 2).floor()
			offset.z *= -1

	var offset: Vector3

	var voxels: Dictionary[Vector3i, int]

	func _to_string() -> String:
		return str(voxels.size(), ' ', size)

	func get_voxels():
		return VoxAsset.get_offset_voxels(voxels, offset)


class VoxelNode:
	var id: int

	var name: String

	var layerId := -1

	var child_nodes: Array[int]

	var frames: Dictionary[int, VoxelFrame]

	var models: Array[Array]

	func get_name(voxel: VoxAsset, frame_index: int = 0, is_root: bool = true) -> String:
		if name:
			return name
		for i in child_nodes:
			var child_name := voxel.nodes[i].get_name(voxel, frame_index, false)
			if child_name:
				return child_name
		if is_root:
			return str("node_", id)
		else:
			return name

	func get_frame(index: int, merge: bool = false) -> VoxelFrame:
		if merge:
			if index == 0 and frames.size() > 0:
				return frames[0]
			var frame := VoxelFrame.new()
			for i in index + 1:
				if not frames.has(i):
					continue
				frame.merge_frame(frames[i])
			return frame
		else:
			if not frames.has(index):
				frames[index] = VoxelFrame.new()
			return frames[index]

	## 递归收集本节点子树的 [模型, 变换] 列表（结果缓存在本节点的 models 字段）。
	## 直接递归：子节点的 models 字段本身就是缓存，交给线程池再立刻 wait 只会让
	## 父任务占着线程等子任务（层级深时可能饿死线程池），且任务返回值本身也取不到。
	func get_models(voxel: VoxAsset, frame_index: int, ignore_trans: bool = false) -> Array:
		if layerId in voxel.layers and not voxel.layers[layerId].isVisible:
			return models
		models.clear()
		for i in child_nodes:
			# ignore_trans 必须继续往下传：漏传会让子树永远按 ignore_trans=false 展开，
			# 于是"忽略透明体素"这个选项只在当前层生效（层级一深就失效）。
			models.append_array(voxel.nodes[i].get_models(voxel, frame_index, ignore_trans))
		get_frame(frame_index, true).merge_models(voxel, models, ignore_trans)
		return models

	func get_voxels(voxel: VoxAsset, frame_index: int, center: bool = false) -> Dictionary[Vector3i, int]:
		var voxels: Dictionary[Vector3i, int]
		var models := get_models(voxel, frame_index, center)
		for i in models.size():
			var model: VoxelModel = models[i][0]
			var transform: Transform3D = models[i][1]
			for pos in model.voxels:
				var new_pos := transform * Vector3(pos)
				voxels[Vector3i(new_pos)] = model.voxels[pos]
		return voxels

	func _to_string() -> String:
		return str('[', name, '] childs: ', child_nodes)

class VoxelFrame:
	var model_id := -1

	var position = null

	var rotation = null

	var transform: Transform3D:
		get(): return Transform3D(rotation if rotation else Quaternion.IDENTITY,
			position if position else Vector3.ZERO)

	func merge_models(voxel: VoxAsset, models: Array[Array], ignore_trans: bool):
		if model_id >= 0:
			var model := voxel.models[model_id]
			models.append([model, Transform3D.IDENTITY.translated(model.offset)])
		if ignore_trans:
			return
		if rotation or position:
			for i in models.size():
				var model_transform: Transform3D = models[i][1]
				models[i][1] = transform * model_transform

	func merge_frame(other: VoxelFrame):
		if other.position:
			position = other.position
		if other.rotation:
			rotation = other.rotation
		if other.model_id >= 0:
			model_id = other.model_id


	func _to_string() -> String:
		return str(' model_id: ', model_id, ' position: ', position, ' rotation: ', rotation)

class VoxelLayer:
	var id: int;

	var isVisible: bool;

	## 图层名（LAYR 的 `_name`）。与 QVX 的组名一一对应。
	var name: String = ""
