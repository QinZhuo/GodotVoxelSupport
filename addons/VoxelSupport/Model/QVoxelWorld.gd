@tool
class_name QVoxelWorld
extends Resource
## 世界 —— QVoxelier 的顶层编辑模型，也就是一份 `.qvx` 工程的**唯一常驻真值**。

## HEAD JSON（qvx / channels 为必填键）。
@export var head: Dictionary = {}

## MATE：材质条目（每项 12 字节的语义结构 Dictionary，见 QVoxelMate.decode）。
@export var materials: Array = []

## NODE JSON（场景树 / 相机）。
@export var node: Dictionary = {}

## 场景树顶层（有序）。
@export var nodes: Array[QVoxelNode] = []

## CACH 块（派生数据，删掉语义为零）。
var cach: Array = []

## 组的运行时编号发号器（见 node_id / QVoxelNode.node_uid）。
static var _uid_seq := 1

## 每次"影响文件内容"的改动自增。
var revision := 0

## 上一次 from_document 时，格式层因类型未知 / 非对象而丢弃的节点数（**含子树**）。
var dropped_nodes := 0

signal content_changed

# 构造

## 新建空世界。
static func create_empty() -> QVoxelWorld:
	var w := QVoxelWorld.new()
	w.head = {
		"qvox": QVoxelSpec.VERSION,
		QVoxelSpec.HEAD_CHANNEL_KEY: QVoxelSpec.DOMINANT_CHANNEL,
		QVoxelSpec.HEAD_BPP_KEY: QVoxelSpec.CHANNEL_BPP,
		QVoxelSpec.HEAD_BLOCK_SIZE_KEY: QVoxelSpec.DEFAULT_BLOCK_SIZE,
		QVoxelSpec.HEAD_UP_AXIS_KEY: QVoxelSpec.DEFAULT_UP_AXIS,
		# 世界设置集中在 world 键下：HEAD 的其余键留给格式本身（§3）
		"world": {"name": "Untitled", "voxel_size": 0.1},
	}
	w.materials = [QVoxelMate.air_entry()]
	return w

## 从解析结果转入编辑模型（加载路径）。
static func from_document(doc: QVoxelFile.QVoxelDocument) -> QVoxelWorld:
	var w := QVoxelWorld.new()
	w.head = doc.head
	w.materials = doc.materials
	w.node = doc.node
	# 相机是独立块（CAMR）；在内存里并回 node（相机代码一直读 node["cameras"]）。
	if not doc.cameras.is_empty():
		w.node["cameras"] = doc.cameras
	w.cach = doc.cach

	var bs := doc.get_block_size()
	# 【唯一解析点在格式层】树在 QVoxelFile.parse 里就已经清洗完毕（doc.scene），这里**只做类型转换**：
	var scene := QVoxelFile.scene_of(doc)
	if scene != null:
		w.dropped_nodes = scene.dropped_nodes
		for e in scene.nodes:
			var n := _node_from_entry(e, doc, bs)
			if n != null:
				w.nodes.append(n)
		if w.dropped_nodes > 0:
			push_warning("[QVoxelWorld] 载入的 NODE 里有 %d 个节点因类型未知/非对象被丢弃（含子树）；" % w.dropped_nodes
					+ "继续编辑并保存会把它们永久移除。")
	# 【纯体素文件 / NODE 未引用】没有 NODE 块（或 NODE 里没引用某些 VXEL/FRAM）时，为每个
	var used := {}
	for m in w.all_models():
		used[m.model_id] = true
	var missing: Array = []
	for mid in doc.model_ids():
		if not used.has(int(mid)):
			missing.append(int(mid))
	for mid in doc.frame_model_ids():
		if not used.has(int(mid)):
			missing.append(int(mid))
	missing.sort()
	for mid in missing:
		var m := QVoxelModel.new()
		m.model_id = mid
		m.block_size = bs
		m.node_name = "Model %d" % mid
		var frames: Variant = doc.model_frames(mid)
		if frames is Array and not (frames as Array).is_empty():
			m.frames = _frames_of_array(frames)
		else:
			var blocks: Variant = doc.model_blocks(mid)
			m.blocks = blocks if blocks is Dictionary else {}
		m.grid_size = _size_of_entry({}, m, bs)
		w.nodes.append(m)
	return w

## 已校验的节点条目 → 节点对象（递归）。
static func _node_from_entry(e: Variant, doc: QVoxelFile.QVoxelDocument, bs: int) -> QVoxelNode:
	if not (e is Dictionary):
		return null
	var entry: Dictionary = e
	var kind := str(entry.get("kind", ""))
	if kind == QVoxelNode.KIND_GROUP:
		var g := QVoxelGroup.new()
		g.node_uid = _take_uid()
		_read_common(g, entry)
		var kids: Variant = entry.get("children")
		if kids is Array:
			for c in (kids as Array):
				var cn := _node_from_entry(c, doc, bs)
				if cn != null:
					g.child_nodes.append(cn)
		return g
	if kind == QVoxelNode.KIND_MODEL:
		var m := QVoxelModel.new()
		_read_common(m, entry)
		m.model_id = maxi(0, QVoxelFile.as_index(entry.get("model_id")))
		m.block_size = bs
		# 【为什么"有帧就用帧，没有才读 blocks"】一个 model_id 只有一个体素源（§12.2 的互斥）。
		var frames: Variant = doc.model_frames(m.model_id)
		if frames is Array and not (frames as Array).is_empty():
			m.frames = _frames_of_array(frames)
		else:
			var blocks: Variant = doc.model_blocks(m.model_id)
			m.blocks = blocks if blocks is Dictionary else {}
		_read_anim(m, doc.model_anim_meta(m.model_id))
		m.grid_size = _size_of_entry(entry, m, bs)
		return m
	return null

## 节点条目里"两种节点共有"的那部分。
static func _read_common(n: QVoxelNode, entry: Dictionary) -> void:
	n.node_name = str(entry.get("name", ""))
	n.visible = bool(entry.get("visible", true))
	n.locked = bool(entry.get("locked", false))
	n.local_transform = QVoxelTransform.transform_from_json(entry.get("transform"))

# 导出为传输结构（保存路径）

## 构出可交给 QVoxelFile.serialize() 的文档。
func to_document() -> QVoxelFile.QVoxelDocument:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = head.duplicate(true)
	doc.head[QVoxelSpec.HEAD_BLOCK_SIZE_KEY] = block_size()  # 对象按它分块，必须与 HEAD 一致
	doc.materials = materials
	doc.node = _node_json()
	# 相机（CAMR）：从 node 里取出来单放（v4 拆块）。
	var cams: Variant = node.get("cameras")
	doc.cameras = (cams as Array).duplicate() if cams is Array else []
	doc.cach = cach
	var animated := false
	for m in all_models():
		# 【为什么是 if/else 而不是两个独立分支】模型只有一个体素源（§12.2 互斥）。
		if m.is_animated():
			doc.frames[m.model_id] = _frames_to_array(m.frames)
			# 时序 meta 随帧进 ANIM 块（v4：不再写进 NODE 节点条目）。
			var meta := _anim_of_model(m)
			if not meta.is_empty():
				doc.anim_meta[m.model_id] = meta
			animated = true
			continue
		var blocks := _dense_blocks_of(m)
		if not blocks.is_empty():
			doc.models[m.model_id] = blocks
	# §12.2：含 ANIM 的文件必须在 HEAD.require 里声明 "ANIM" —— 不认识它的读者**拒绝整个文件**
	if animated:
		doc.head["require"] = _with_requirement(doc.head.get("require"), QVoxelSpec.BLOCK_ANIM)
	else:
		doc.head["require"] = _without_requirement(doc.head.get("require"), QVoxelSpec.BLOCK_ANIM)
	return doc

## 往 require 列表里加一项（已存在则原样返回，不重复）。
static func _with_requirement(req: Variant, type_tag: String) -> Array:
	var out: Array = (req as Array).duplicate() if req is Array else []
	if not out.has(type_tag):
		out.append(type_tag)
	return out

## 从 require 列表里去掉一项。
static func _without_requirement(req: Variant, type_tag: String) -> Array:
	if not (req is Array):
		return []
	var out: Array = []
	for t in (req as Array):
		if t != type_tag:
			out.append(t)
	return out

## 帧数组 → 传输结构（QVoxelFrame → `{"duration_ms", "blocks"}`）。
static func _frames_to_array(frames: Array[QVoxelFrame]) -> Array:
	var out: Array = []
	for f in frames:
		if f != null:
			out.append(f.to_dict())
	return out

## 传输结构 → 帧数组（每项经 QVoxelFrame.from_dict 补齐缺省）。
static func _frames_of_array(arr: Array) -> Array[QVoxelFrame]:
	var out: Array[QVoxelFrame] = []
	for d in arr:
		out.append(QVoxelFrame.from_dict(d))
	return out

## 动画时序 meta → 模型字段（§12.3）。
static func _read_anim(m: QVoxelModel, meta: Dictionary) -> void:
	if meta.is_empty():
		return
	m.anim_loop = bool(meta.get("loop", QVoxelSpec.ANIM_LOOP_DEFAULT))
	m.anim_fps = maxi(1, int(meta.get("fps", QVoxelSpec.ANIM_FPS_DEFAULT)))
	var tags: Variant = meta.get("tags")
	m.anim_tags = (tags as Array).duplicate() if tags is Array else []

## 模型字段 → 时序 meta 字典（写进 doc.anim_meta，最终进 ANIM 块）。
static func _anim_of_model(m: QVoxelModel) -> Dictionary:
	if not m.is_animated():
		return {}
	var a := {}
	if not m.anim_loop:
		a["loop"] = false
	# "与缺省不同才写"（P2）：缺省取 QVoxelSpec.ANIM_FPS_DEFAULT，否则缺省值每份文件都白背一个键。
	if m.anim_fps != QVoxelSpec.ANIM_FPS_DEFAULT:
		a["fps"] = m.anim_fps
	if not m.anim_tags.is_empty():
		a["tags"] = m.anim_tags
	return a

# 世界级设置

func block_size() -> int:
	return int(head.get(QVoxelSpec.HEAD_BLOCK_SIZE_KEY, QVoxelSpec.DEFAULT_BLOCK_SIZE))

func world_name() -> String:
	return str(_settings().get("name", "Untitled"))

func set_world_name(value: String) -> void:
	_write_settings(_patched_settings("name", value))

## 一个体素在世界单位（米）下的边长。
func voxel_size() -> float:
	return float(_settings().get("voxel_size", 0.1))

# 材质（MATE 就是调色板本身）

## 材质颜色。
func material_color(material_id: int) -> Color:
	if material_id <= 0 or material_id >= materials.size():
		return Color.MAGENTA
	return QVoxelMate.color(materials[material_id])

func set_material_color(material_id: int, color: Color) -> void:
	while materials.size() <= material_id:
		materials.append(QVoxelMate.air_entry())
	# 换掉**整个条目**而不是就地改它的键：撤销走 QVoxelPropertyCommand(world, &"materials") 时，
	materials[material_id] = QVoxelMate.with_color(materials[material_id], color)
	_touch()

## 追加一个新材质，返回其 ID。
func add_material(color: Color) -> int:
	var id := materials.size()
	materials.append(QVoxelMate.air_entry())
	set_material_color(id, color)
	return id

func used_materials() -> Dictionary:
	var used := {}
	for m in all_models():
		for mid in m.used_materials():
			used[mid] = true
	return used

## 材质 PBR 标量通道（`metal` / `rough` / `emission`，值域 0–1）。
func material_scalar(material_id: int, key: StringName) -> float:
	if material_id <= 0 or material_id >= materials.size():
		return 0.0
	var e: Dictionary = materials[material_id]
	match key:
		&"metal":
			return float(int(e.get("metal", 0))) / 255.0
		&"rough":
			return float(int(e.get("rough", 0))) / 255.0
		&"emission":
			var hi := maxi(maxi(int(e.get("e_r", 0)), int(e.get("e_g", 0))), int(e.get("e_b", 0)))
			return float(hi) / 255.0
	return 0.0

## 写材质 PBR 标量通道（与 `material_scalar` 成对，round-trip 稳定）。
func set_material_scalar(material_id: int, key: StringName, value: float) -> void:
	while materials.size() <= material_id:
		materials.append(QVoxelMate.air_entry())
	var e: Dictionary = (materials[material_id] as Dictionary).duplicate()
	match key:
		&"metal":
			e["metal"] = QVoxelMate.byte_of(value)
		&"rough":
			e["rough"] = QVoxelMate.byte_of(value)
		&"emission":
			var color := QVoxelMate.color(e)
			var hi := maxf(maxf(color.r, color.g), color.b)
			var scale := 0.0 if hi <= 0.0 else value * 255.0 / hi
			e["e_r"] = clampi(int(round(color.r * scale)), 0, 255)
			e["e_g"] = clampi(int(round(color.g * scale)), 0, 255)
			e["e_b"] = clampi(int(round(color.b * scale)), 0, 255)
		_:
			return
	materials[material_id] = e
	_touch()

# 相机（NODE 下的工程数据，§5.1）

## 相机书签数组（活引用，供面板遍历；**改动一律走下面的 setter**）。
func cameras() -> Array:
	return _json_array_of(QVoxelSpec.NODE_CAMERAS_KEY)

func camera_field(index: int, key: String) -> Variant:
	return _entry_field(QVoxelSpec.NODE_CAMERAS_KEY, index, key, QVoxelSpec.CAMERA_FIELD_DEFAULTS)

## 改相机某一项的一个字段。
func set_camera_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(QVoxelSpec.NODE_CAMERAS_KEY, index, key, value)

## 追加相机书签，返回新下标。
func add_camera(camera_name := "camera") -> int:
	return _append_entry(QVoxelSpec.NODE_CAMERAS_KEY, QVoxelSpec.CAMERA_FIELD_DEFAULTS,
			{"name": camera_name})

func remove_camera(index: int) -> bool:
	return _remove_entry_at(QVoxelSpec.NODE_CAMERAS_KEY, index)

# 场景树

## 新建模型并接进世界。
func create_model(node_name := "", grid := Vector3i.ZERO, parent: QVoxelGroup = null) -> QVoxelModel:
	var m := QVoxelModel.new()
	m.model_id = next_model_id()
	m.block_size = block_size()
	m.grid_size = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else Vector3i(32, 32, 32)
	m.node_name = node_name if not node_name.is_empty() else "Model %d" % m.model_id
	_attach(m, parent, -1)
	return m

## 新建组并接进世界。
func create_group(group_name := "Group", parent: QVoxelGroup = null) -> QVoxelGroup:
	var g := QVoxelGroup.new()
	g.node_name = group_name
	g.node_uid = _take_uid()
	_attach(g, parent, -1)
	return g

## 取一个新组编号（见 _uid_seq）。
static func _take_uid() -> int:
	var v := _uid_seq
	_uid_seq += 1
	return v

## 节点的标量 id：模型用落盘的 `model_id`（> 0），组用 `-node_uid`（< 0）。
func node_id(n: QVoxelNode) -> int:
	if n == null:
		return 0
	return n.model_id if n.is_model() else -n.node_uid

## 由标量 id 找回节点（node_id 的逆运算）。
func find_node(id: int) -> QVoxelNode:
	if id > 0:
		return find_model(id)
	if id == 0:
		return null
	for n in all_nodes():
		if n.is_group() and n.node_uid == -id:
			return n
	return null

## 合并另一份世界：材质与模型全部并进本世界，材质 ID 整体平移（体素值跟着改）。
func merge_from(other: QVoxelWorld) -> Array[QVoxelModel]:
	var added: Array[QVoxelModel] = []
	if other == null or other == self:
		return added
	# 只搬**实际用到的**材质，并按"旧 ID → 新 ID"建映射。
	var src_ids := other.used_materials().keys()
	src_ids.sort()
	var slots: Array[int] = _free_material_slots(src_ids.size())
	if slots.size() < src_ids.size():
		push_warning("[QVoxelWorld] 材质槽已用尽（上限 %d），合并中止" % QVoxelSpec.MATERIAL_COUNT)
		return added
	# 先按需扩容到覆盖最大槽位，再逐条写 —— 中途不会留下"表长了但槽是空的"这种半成品。
	var need := 0
	for s in slots:
		need = maxi(need, int(s) + 1)
	while materials.size() < need:
		materials.append(QVoxelMate.air_entry())
	var remap := {}
	for k in src_ids.size():
		var sid := int(src_ids[k])
		var slot := int(slots[k])
		materials[slot] = (other.materials[sid] as Dictionary).duplicate(true)
		remap[sid] = slot
	for m in other.all_models():
		if m == null:
			continue
		var nm := create_model(m.node_name, m.grid_size, null)
		nm.local_transform = m.local_transform
		_copy_voxels(m, nm, remap)
		added.append(nm)
	if not remap.is_empty():
		_touch()
	return added

## 找出 n 个可写的材质槽：表尾还有空间就往后长，不够再复用**未被任何体素引用**的槽。
func _free_material_slots(n: int) -> Array[int]:
	var out: Array[int] = []
	var grow := QVoxelSpec.MATERIAL_COUNT - materials.size()
	for k in mini(n, grow):
		out.append(materials.size() + k)
	if out.size() < n:
		var used := used_materials()
		for i in range(1, materials.size()):
			if out.size() >= n:
				break
			if not used.has(i):
				out.append(i)
	if out.size() < n:
		return []
	return out

## 把 src 的体素（连同帧动画与材质 ID 重映射）复制进 dst。
static func _copy_voxels(src: QVoxelModel, dst: QVoxelModel, remap: Dictionary) -> void:
	if not src.is_animated():
		dst.blocks = _remap_table(src.blocks, remap)
		return
	dst.make_animated()
	for i in range(1, src.frame_count()):
		dst.add_frame(QVoxelFrame.new())
	for i in src.frame_count():
		var sf := src.frame_at(i)
		var df := dst.frame_at(i)
		if sf == null or df == null:
			continue
		df.blocks = _remap_table(sf.blocks, remap)
		df.duration_ms = sf.duration_ms
	dst.anim_fps = src.anim_fps
	dst.anim_loop = src.anim_loop
	dst.anim_tags = src.anim_tags.duplicate(true)

## 块表深拷 + 材质 ID 按映射表改写（0 恒为空；映射不到的退回 0，宁可少一格也不指向错色）。
static func _remap_table(src: Dictionary, remap: Dictionary) -> Dictionary:
	var out := {}
	for k: Vector3i in src:
		var buf: PackedInt32Array = (src[k] as PackedInt32Array).duplicate()
		for i in buf.size():
			var v := buf[i]
			if v > 0:
				buf[i] = int(remap.get(v, 0))
		out[k] = buf
	return out

func next_model_id() -> int:
	var top := -1
	for m in all_models():
		top = maxi(top, m.model_id)
	return top + 1

func find_model(model_id: int) -> QVoxelModel:
	for m in all_models():
		if m.model_id == model_id:
			return m
	return null

## 全部节点（深度优先）。
func all_nodes() -> Array[QVoxelNode]:
	var out: Array[QVoxelNode] = []
	_collect_nodes(nodes, out)
	return out

## 全部模型（深度优先，保持树上的顺序）。
func all_models() -> Array[QVoxelModel]:
	var out: Array[QVoxelModel] = []
	_collect_models(nodes, out)
	return out

## 包含 target 的那个数组（顶层 nodes，或某组的 child_nodes）。
func _list_holding(target: QVoxelNode) -> Array[QVoxelNode]:
	if nodes.has(target):
		return nodes
	for n in all_nodes():
		if n.is_group() and (n as QVoxelGroup).child_nodes.has(target):
			return (n as QVoxelGroup).child_nodes
	return [] as Array[QVoxelNode]

## target 的父组（顶层节点的父为 null）。
func find_parent(target: QVoxelNode) -> QVoxelGroup:
	for n in all_nodes():
		if n.is_group() and (n as QVoxelGroup).child_nodes.has(target):
			return n as QVoxelGroup
	return null

## 节点在父列表里的下标（不在树上返回 -1）。
func index_of(target: QVoxelNode) -> int:
	# Array.find() 对空数组返回 -1，故不必再判 _list_holding 是否为空（那层分支是冗余的）。
	return _list_holding(target).find(target)

## 节点在**世界里的组合摆放**：从根到它逐层累乘 local_transform。
func world_transform(target: QVoxelNode) -> Transform3D:
	var path: Array[QVoxelNode] = []
	if not _path_to(nodes, target, path):
		return Transform3D.IDENTITY
	var xf := Transform3D.IDENTITY
	for n in path:
		xf = xf * n.local_transform
	return xf

## 深度优先找 target 的路径（根 → target），填入 path。
func _path_to(list: Array[QVoxelNode], target: QVoxelNode, path: Array[QVoxelNode]) -> bool:
	for n in list:
		if n == null:
			continue
		path.append(n)
		if n == target:
			return true
		if n.is_group() and _path_to((n as QVoxelGroup).child_nodes, target, path):
			return true
		path.pop_back()
	return false

## target 在同级里的下标（不在树上返回 -1）。
func node_index(target: QVoxelNode) -> int:
	return index_of(target)

## 把已有节点挂到 parent 下的 index 位置（index < 0 = 末尾）。
func attach_node(target: QVoxelNode, parent: QVoxelGroup, index := -1) -> bool:
	if target == null:
		return false
	if parent != null and (parent == target or _is_ancestor(target, parent)):
		return false
	var lst := _list_holding(target)
	if not lst.is_empty():
		lst.erase(target)
	_attach(target, parent, index)
	return true

## 删除节点（连同其子树）。
func remove_node(target: QVoxelNode) -> bool:
	var lst := _list_holding(target)
	if lst.is_empty():
		return false
	lst.erase(target)
	_touch()
	return true

func _attach(target: QVoxelNode, parent: QVoxelGroup, index: int) -> void:
	var lst: Array[QVoxelNode] = nodes if parent == null else parent.child_nodes
	if index < 0 or index >= lst.size():
		lst.append(target)
	else:
		lst.insert(index, target)
	_touch()

## anc 是不是 node 的祖先（或就是 node 自己）。
func _is_ancestor(anc: QVoxelNode, node: QVoxelNode) -> bool:
	if not anc.is_group():
		return false
	for c in (anc as QVoxelGroup).child_nodes:
		if c == node or _is_ancestor(c, node):
			return true
	return false

func _collect_nodes(list: Array[QVoxelNode], out: Array[QVoxelNode]) -> void:
	for n in list:
		if n == null:
			continue
		out.append(n)
		if n.is_group():
			_collect_nodes((n as QVoxelGroup).child_nodes, out)

func _collect_models(list: Array[QVoxelNode], out: Array[QVoxelModel]) -> void:
	for n in list:
		if n == null:
			continue
		if n.is_model():
			out.append(n as QVoxelModel)
		elif n.is_group():
			_collect_models((n as QVoxelGroup).child_nodes, out)

# 内部

func _touch() -> void:
	revision += 1
	content_changed.emit()

func _settings() -> Dictionary:
	var w: Variant = head.get("world")
	return w if w is Dictionary else {}

## 造一份"改过某个键"的设置副本。
func _patched_settings(key: String, value: Variant) -> Dictionary:
	var w := _settings().duplicate()
	w[key] = value
	return w

func _write_settings(w: Dictionary) -> void:
	head["world"] = w
	_touch()

## 取 node 下的 JSON 数组。
func _json_array_of(key: String) -> Array:
	var v: Variant = node.get(key)
	return v if v is Array else []

## 写回 node 下的 JSON 数组（**整体替换**，见类头铁律），并标脏。
func _write_json_array(key: String, arr: Array) -> void:
	node[key] = arr
	_touch()

func _entry_at(key: String, index: int) -> Dictionary:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size() or not (arr[index] is Dictionary):
		return {}
	return arr[index]

func _entry_field(key: String, index: int, field: String, defaults: Dictionary) -> Variant:
	return _entry_at(key, index).get(field, defaults.get(field))

func _set_entry_field(key: String, index: int, field: String, value: Variant) -> bool:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size() or not (arr[index] is Dictionary):
		return false
	if (arr[index] as Dictionary).get(field) == value:
		return false  # 值没变 → 不该占一次撤销
	var d: Dictionary = (arr[index] as Dictionary).duplicate()
	d[field] = value
	var next: Array = arr.duplicate()  # 新数组 + 新元素：旧的两份都留给浅快照
	next[index] = d
	_write_json_array(key, next)
	return true

## 造一条"先套缺省值、再盖上 seed"的新条目。
func _seeded_entry(defaults: Dictionary, seed: Dictionary) -> Dictionary:
	var d := defaults.duplicate()
	for k in seed:
		d[k] = seed[k]
	return d

func _append_entry(key: String, defaults: Dictionary, seed: Dictionary) -> int:
	var next: Array = _json_array_of(key).duplicate()
	next.append(_seeded_entry(defaults, seed))
	_write_json_array(key, next)
	return next.size() - 1

func _remove_entry_at(key: String, index: int) -> bool:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size():
		return false
	var next: Array = arr.duplicate()
	next.remove_at(index)
	_write_json_array(key, next)
	return true

## 对象 → 文件块表：丢掉全零块（= 空块不写入），并**排序键**。
func _dense_blocks_of(o: QVoxelModel) -> Dictionary:
	var out := {}
	var bs := o.block_size
	for k in o.block_keys():
		var buf := o.get_block(k)
		if buf.size() != QVoxelSpec.block_volume(bs):
			continue
		# 判空走原生 count(0)：这是保存世界的必经路径，逐体素 GDScript 扫描是秒级开销。
		if not QVoxelBlockCodec.is_empty_block(buf):
			out[k] = buf
	return out

## NODE JSON：把场景树写进 nodes，其余键**原样保留**。
func _node_json() -> Dictionary:
	var out := node.duplicate(true)
	out.erase("layers")
	out.erase("animations")
	out.erase("cameras")   # v4：相机单放 CAMR 块，不留在 NODE
	var arr: Array = []
	for n in nodes:
		if n != null:
			arr.append(_entry_of_node(n))
	if not arr.is_empty() or out.has("nodes"):
		out["nodes"] = arr
	return out

## 节点 → JSON 条目（递归）。
func _entry_of_node(n: QVoxelNode) -> Dictionary:
	var e := {}
	e["kind"] = n.kind()
	e["name"] = n.node_name
	if not n.visible:
		e["visible"] = false
	if n.locked:
		e["locked"] = true
	var xf := QVoxelTransform.transform_to_json(n.local_transform)
	if not xf.is_empty():
		e["transform"] = xf
	if n.is_model():
		var mo := n as QVoxelModel
		e["model_id"] = mo.model_id
		e["size"] = [mo.grid_size.x, mo.grid_size.y, mo.grid_size.z]
	else:
		var kids: Array = []
		for c in (n as QVoxelGroup).child_nodes:
			if c != null:
				kids.append(_entry_of_node(c))
		e["children"] = kids
	return e

## 节点里显式写了 size 就用它；否则从块范围推断（外来文件可能没写 size）。
static func _size_of_entry(entry: Dictionary, m: QVoxelModel, bs: int) -> Vector3i:
	var s: Variant = entry.get("size")
	if s is Array and (s as Array).size() == 3:
		return Vector3i(int(s[0]), int(s[1]), int(s[2]))
	var mx := _infer_grid(m.blocks, bs)
	for f in m.frames:
		var fg := _infer_grid(f.blocks, bs)
		mx = Vector3i(maxi(mx.x, fg.x), maxi(mx.y, fg.y), maxi(mx.z, fg.z))
	return mx

## 从块范围推断分辨率：取"最高块边界"，并向下取整到块边长的整数倍。
static func _infer_grid(blocks: Dictionary, bs: int) -> Vector3i:
	var mx := Vector3i(bs, bs, bs)
	for k: Vector3i in blocks:
		mx.x = maxi(mx.x, (k.x + 1) * bs)
		mx.y = maxi(mx.y, (k.y + 1) * bs)
		mx.z = maxi(mx.z, (k.z + 1) * bs)
	return mx
