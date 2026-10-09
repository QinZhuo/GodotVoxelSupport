@tool
class_name QVoxelWorld
extends Resource
## 世界 —— QVoxelier 的顶层编辑模型，也就是一份 `.qvx` 工程的**唯一常驻真值**。
##
## 【与 QVoxelFile.QVoxelDocument 的分工：一份真值 + 一个瞬时 DTO】
##   QVoxelWorld    活的编辑状态（对象 + 手绘体素 + 修改器链），常驻内存、可被就地改写。
##   QVoxelDocument QVoxelFile 解析/序列化用的传输结构，**只在读写的那一瞬间存在**。
## 两者用 from_document() / to_document() 一对显式转换连接，**不允许同时常驻** ——
## 否则同一份体素会有两个账本，改动落哪边取决于调用顺序（这类静默数据丢失最难查）。
##
## 【为什么加载/保存要经一次转换，而不是直接编辑 Document】
## QVoxelDocument 是"格式的忠实投影"：块表按 model_id 分桶、对象元数据散在 NODE 的 JSON 里、
## 没有"选择/焦点/撤销目标"这类编辑期概念。拿它当编辑模型，UI 每次都要自己拼装语义，
## 于是"格式细节"会渗透到每个面板里。转换一次（而不是每处各转一次）才能把格式关在 QVoxelFile 内。
##
## 【head / materials / node / cach 原样保留】HEAD 与 NODE 都是 JSON，格式层不解释未知键
## （QVoxelSpec §3/§7）。本类只解释自己拥有的键（world 设置、nodes 树、cameras），
## 其余**原样写回** —— 于是"读进来再存出去"不会丢掉任何我们还没实现的东西。
##
## 【铁律：写入 = "替换"，绝不就地改嵌套结构】本类的改动由 QVoxelPropertyCommand 撤销，
## 而它的快照是**浅**副本（见该类 _snapshot）。浅副本与活数据**共享**嵌套容器，所以
## `head["world"]["name"] = x` 这种就地写会让命令手里的"改前值"跟着一起变 ——
## 撤销于是"撤了个寂寞"，且全程不报错。故所有 setter 一律构造新容器再整体写回；
## 撤销的粒度也因此天然落在"数组 / 字典整体"上。

## HEAD JSON（qvx / channels 为必填键）。
@export var head: Dictionary = {}

## MATE：材质条目（每项 12 字节的语义结构 Dictionary，见 QVoxelFile._parse_mate）。
## 索引即材质 ID，[0] 恒为空气。**这就是调色板本身**，不再另存一份"ID → Color"的映射。
@export var materials: Array = []

## NODE JSON（场景树 / 相机）。本类只写 nodes 树与 cameras，其余键**原样保留**。
@export var node: Dictionary = {}

## 场景树顶层（有序）。**唯一真值** —— 组/模型的父子关系全在这里。
##
## 【为什么不再有"图层"这张平行表】层与对象本是同一件事的两半：层管分组/可见/顺序，
## 对象管内容。两张表就得同步（"删层要把层内对象的 layer 一起搬"就是这么来的），
## 而同步总有漏掉一处的时候。合成一棵树后，层就是一个 QVoxelGroup 节点、归属就是父子关系。
@export var nodes: Array[QVoxelNode] = []

## CACH 块（派生数据，删掉语义为零）。求解缓存、缩略图这类东西放这里。
var cach: Array = []

## 每次"影响文件内容"的改动自增。UI 据此判断"是否需要提示保存"。
var revision := 0

signal content_changed


# ----------------------------------------------------------------------------
# 构造
# ----------------------------------------------------------------------------

## 新建空世界。HEAD 由格式常量组装（qvx 版本、必填 channels 等一律取自 QVoxelSpec，
## 免得把"版本号"抄第二遍 —— 那正是升级格式时漏改一处的地方）。
static func create_empty() -> QVoxelWorld:
	var w := QVoxelWorld.new()
	w.head = {
		"qvox": QVoxelSpec.VERSION,
		"channels": [{"name": QVoxelSpec.DOMINANT_CHANNEL, "bpp": QVoxelSpec.CHANNEL_BPP}],
		"block_size": QVoxelSpec.DEFAULT_BLOCK_SIZE,
		"up_axis": QVoxelSpec.DEFAULT_UP_AXIS,
		# 世界设置集中在 world 键下：HEAD 的其余键留给格式本身（§3）
		"world": {"name": "Untitled", "voxel_size": 0.1},
	}
	w.materials = [_air_entry()]
	return w


## 从解析结果转入编辑模型（加载路径）。**接管** doc 里的块表，不做深拷贝 ——
## doc 用完即弃（约定：不允许同时常驻），拷贝一份几百万格的数据纯属浪费。
static func from_document(doc: QVoxelFile.QVoxelDocument) -> QVoxelWorld:
	var w := QVoxelWorld.new()
	w.head = doc.head
	w.materials = doc.materials
	w.node = doc.node
	w.cach = doc.cach

	var bs := doc.get_block_size()
	var raw: Variant = doc.node.get("nodes")
	if raw is Array:
		for e in (raw as Array):
			var n := _node_from_entry(e, doc, bs)
			if n != null:
				w.nodes.append(n)
	return w


## 节点条目 → 节点对象（递归）。
##
## 【认不出来就丢弃，不造空壳】未知 kind 意味着这份文件来自更新的版本或别的工具。
## 凭猜补一个空节点出来，用户会以为数据还在（然后在保存时把真正的数据覆盖掉）。
static func _node_from_entry(e: Variant, doc: QVoxelFile.QVoxelDocument, bs: int) -> QVoxelNode:
	if not (e is Dictionary):
		return null
	var entry: Dictionary = e
	var kind := str(entry.get("kind", ""))
	if kind == QVoxelNode.KIND_GROUP:
		var g := QVoxelGroup.new()
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
		# 两个都读会造出"既有静态体素又有动画"的模型 —— 而格式层已经在解析期把这种文件拒了，
		# 这里再挑一次是防"手改过的文件"，也让内存占用与文件里的实际源一致。
		var frames: Variant = doc.model_frames(m.model_id)
		if frames is Array and not (frames as Array).is_empty():
			m.frames = _frames_of_array(frames)
		else:
			var blocks: Variant = doc.model_blocks(m.model_id)
			m.blocks = blocks if blocks is Dictionary else {}
		_read_anim(m, entry)
		m.grid_size = _size_of_entry(entry, m, bs)
		return m
	return null


## 节点条目里"两种节点共有"的那部分。
##
## 【为什么没有 position / combine】摆放已是链上的一条平移条目，而"怎么并进父画布"是父侧
## 恒定的并集（见 QVoxelEvalEngine._composite），两者都不再是节点自己的属性。
static func _read_common(n: QVoxelNode, entry: Dictionary) -> void:
	n.node_name = str(entry.get("name", ""))
	n.visible = bool(entry.get("visible", true))
	n.locked = bool(entry.get("locked", false))
	n.modifiers = _modifiers_of_entry(entry)


# ----------------------------------------------------------------------------
# 导出为传输结构（保存路径）
# ----------------------------------------------------------------------------

## 构出可交给 QVoxelFile.serialize() 的文档。**每次调用都重新构**（Document 不常驻）。
func to_document() -> QVoxelFile.QVoxelDocument:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = head.duplicate(true)
	doc.head["block_size"] = block_size()  # 对象按它分块，必须与 HEAD 一致
	doc.materials = materials
	doc.node = _node_json()
	doc.cach = cach
	var animated := false
	for m in all_models():
		# 【为什么是 if/else 而不是两个独立分支】模型只有一个体素源（§12.2 互斥）。
		# 写成"动画也写、静态也写"会让同一 model_id 同时进 models 与 frames —— 序列化时
		# 格式层会直接判 FATAL（这正是我们想要的兜底），但真到了那一步就说明本函数有 bug。
		if m.is_animated():
			doc.frames[m.model_id] = _frames_to_array(m.frames)
			animated = true
			continue
		var blocks := _dense_blocks_of(m)
		if not blocks.is_empty():
			doc.models[m.model_id] = blocks
	# §12.2：含 FRAM 的文件必须在 HEAD.require 里声明 "FRAM" —— 不认识它的读者**拒绝整个文件**
	# （fail-fast），而不是静默少几个模型。反过来，全是静态模型时**不声明**：声明了等于
	# 让老读者白白拒掉一份它们本来完全能读的文件。
	if animated:
		doc.head["require"] = _with_requirement(doc.head.get("require"), QVoxelSpec.BLOCK_FRAM)
	else:
		doc.head["require"] = _without_requirement(doc.head.get("require"), QVoxelSpec.BLOCK_FRAM)
	return doc


## 往 require 列表里加一项（已存在则原样返回，不重复）。
static func _with_requirement(req: Variant, type_tag: String) -> Array:
	var out: Array = (req as Array).duplicate() if req is Array else []
	if not out.has(type_tag):
		out.append(type_tag)
	return out


## 从 require 列表里去掉一项。**必须在"不再含 FRAM"时也跑一次**：用户删掉最后一帧后
## 若还留着 `require:["FRAM"]`，文件就会莫名其妙地被不支持的读者整份拒掉（残留声明）。
static func _without_requirement(req: Variant, type_tag: String) -> Array:
	if not (req is Array):
		return []
	var out: Array = []
	for t in (req as Array):
		if t != type_tag:
			out.append(t)
	return out


## 帧数组 → 传输结构（QVoxelFrame → `{"duration_ms", "blocks"}`）。**不拷贝块缓冲**：
## doc 是瞬时 DTO、用完即弃（同 from_document 的"接管"约定）。
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


## 节点条目的 `anim` 键 → 时间轴元数据（§12.3）。
##
## 【为什么只认 anim，不认旧的 animations】旧键按"节点下标"寻址，而 v3 的嵌套树没有下标
## 这层身份（§12.4），与旧 layers 键同一处置：读盘忽略、写盘抹掉。
static func _read_anim(m: QVoxelModel, entry: Dictionary) -> void:
	var a: Variant = entry.get("anim")
	if not (a is Dictionary):
		return
	var d: Dictionary = a
	m.anim_loop = bool(d.get("loop", true))
	m.anim_fps = maxi(1, int(d.get("fps", 12)))
	var tags: Variant = d.get("tags")
	m.anim_tags = (tags as Array).duplicate() if tags is Array else []


## 时间轴元数据 → `anim` 键。**静态模型不写**（没有帧就没有时间轴）；
## 各字段**取缺省值同样不写**（P2：缺省才是常态）—— 于是"整条 anim 全缺省"时根本不落键。
static func _anim_of_model(m: QVoxelModel) -> Dictionary:
	if not m.is_animated():
		return {}
	var a := {}
	if not m.anim_loop:
		a["loop"] = false
	if m.anim_fps != 12:
		a["fps"] = m.anim_fps
	if not m.anim_tags.is_empty():
		a["tags"] = m.anim_tags
	return a


# ----------------------------------------------------------------------------
# 世界级设置
# ----------------------------------------------------------------------------

func block_size() -> int:
	return int(head.get("block_size", QVoxelSpec.DEFAULT_BLOCK_SIZE))


func world_name() -> String:
	return str(_settings().get("name", "Untitled"))


func set_world_name(value: String) -> void:
	_write_settings(_patched_settings("name", value))


## 一个体素在世界单位（米）下的边长。渲染与导出正交投影都读它。
func voxel_size() -> float:
	return float(_settings().get("voxel_size", 0.1))


## 【为什么改它要 _touch()】它一变，所有对象的实际尺寸跟着变 → 视口必须重排。
func set_voxel_size(value: float) -> void:
	_write_settings(_patched_settings("voxel_size", value))


# ----------------------------------------------------------------------------
# 材质（MATE 就是调色板本身）
# ----------------------------------------------------------------------------

## 材质颜色。ID 越界或条目缺失返回洋红（可见的错误色，而不是悄悄变黑）。
func material_color(material_id: int) -> Color:
	if material_id <= 0 or material_id >= materials.size():
		return Color.MAGENTA
	return _color_of(materials[material_id])


func set_material_color(material_id: int, color: Color) -> void:
	while materials.size() <= material_id:
		materials.append(_air_entry())
	var rgba := _rgba_of(color)
	# 换掉**整个条目**而不是就地改它的键：撤销走 QVoxelPropertyCommand(world, &"materials") 时，
	# 快照只浅拷数组，就地改会让"改前值"一起变（见类头铁律）。
	var e: Dictionary = (materials[material_id] as Dictionary).duplicate()
	e["rgba"] = rgba
	e["r"] = (rgba >> 24) & 0xFF
	e["g"] = (rgba >> 16) & 0xFF
	e["b"] = (rgba >> 8) & 0xFF
	e["a"] = rgba & 0xFF
	materials[material_id] = e
	_touch()


## 追加一个新材质，返回其 ID。
func add_material(color: Color) -> int:
	var id := materials.size()
	materials.append(_air_entry())
	set_material_color(id, color)
	return id


func used_materials() -> Dictionary:
	var used := {}
	for m in all_models():
		for mid in m.used_materials():
			used[mid] = true
	return used


# ----------------------------------------------------------------------------
# 相机（NODE 下的工程数据，§5.1）
# ----------------------------------------------------------------------------
# 【为什么相机没有自己的 Resource 类】相机的唯一归宿是 `node` 这个 JSON 字典：
# 存盘要 JSON、读盘要 JSON。中间再过一层 Resource，只会凭空多出两处"字段改名"的机会 ——
# 而改名错位不报错，只静默丢字段。故本类直接读写 node 下的键，
# 与 HEAD 的 world 设置（_settings / _write_settings）同一手法。
#
# 【改相机怎么撤销】面板把一次改动包成 QVoxelPropertyCommand(world, &"node") 即可 ——
# 本节 setter 一律**整体替换** node 下的数组，于是浅快照里的旧数组原封不动（见类头铁律）。

## 相机书签数组（活引用，供面板遍历；**改动一律走下面的 setter**）。
func cameras() -> Array:
	return _json_array_of(QVoxelSpec.NODE_CAMERAS_KEY)


func camera_field(index: int, key: String) -> Variant:
	return _entry_field(QVoxelSpec.NODE_CAMERAS_KEY, index, key, QVoxelSpec.CAMERA_FIELD_DEFAULTS)


## 改相机某一项的一个字段。返回"是否真的改了"—— false 表示越界或值本来就相同，
## 调用方据此**不要**产生撤销单位（同"空手势不入栈"的约定）。
func set_camera_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(QVoxelSpec.NODE_CAMERAS_KEY, index, key, value)


## 追加相机书签，返回新下标。
func add_camera(camera_name := "camera") -> int:
	return _append_entry(QVoxelSpec.NODE_CAMERAS_KEY, QVoxelSpec.CAMERA_FIELD_DEFAULTS,
			{"name": camera_name})


func remove_camera(index: int) -> bool:
	return _remove_entry_at(QVoxelSpec.NODE_CAMERAS_KEY, index)


# ----------------------------------------------------------------------------
# 场景树
# ----------------------------------------------------------------------------
# 【为什么"层"没有了】层与对象本是同一件事的两半。合成一棵树后，分组 = 父子关系，
# 可见 / 锁定 / 摆放 / 滤镜全是节点属性 —— **只有一处真值**，也不再需要"删层要连带搬 layer"
# 这种跨表同步（那条规则的存在本身就是"有两张表"的证据）。
#
# 【为什么没有 parent 指针】父 → 子只朝一个方向，引用图是 DAG、没有环。Resource 是
# RefCounted：存反向指针就造出环，环永远不被释放（静默泄漏）。需要"我在谁下面"时从根往下找。

## 新建模型并接进世界。parent 为 null 则挂到顶层。
##
## model_id 取"现有最大值 + 1"（而不是 size()）：删掉中间某个模型后，ID 不会被新模型复用
## —— 复用会让仍在引用旧 ID 的撤销命令改错模型。
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
	_attach(g, parent, -1)
	return g


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


## 深度优先遍历整棵树（先父后子，按树上的顺序）。
func walk(visitor: Callable) -> void:
	_walk_list(nodes, visitor)


## 全部节点（深度优先）。
func all_nodes() -> Array[QVoxelNode]:
	var out: Array[QVoxelNode] = []
	_collect_nodes(nodes, out)
	return out


## 全部模型（深度优先，保持树上的顺序）。**这是"世界里的模型"的唯一枚举入口**。
func all_models() -> Array[QVoxelModel]:
	var out: Array[QVoxelModel] = []
	_collect_models(nodes, out)
	return out


## 包含 target 的那个数组（顶层 nodes，或某组的 child_nodes）。不在树上返回空数组。
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


## target 的同级列表（顶层节点的同级 = 顶层数组）。
func siblings_of(target: QVoxelNode) -> Array[QVoxelNode]:
	var lst := _list_holding(target)
	return lst if not lst.is_empty() else nodes


## target 在同级里的下标（不在树上返回 -1）。
func node_index(target: QVoxelNode) -> int:
	return _list_holding(target).find(target)


## 从树上摘下来（不删数据，节点对象仍被调用方持有）。**递归删除请用 remove_node**。
func detach_node(target: QVoxelNode) -> bool:
	var lst := _list_holding(target)
	if lst.is_empty():
		return false
	lst.erase(target)
	_touch()
	return true


## 把已有节点挂到 parent 下的 index 位置（index < 0 = 末尾）。会先把它从原位置摘下来。
##
## 【为什么"移动"和"插入"是同一个操作】树上没有"移动"这回事 —— 移动就是"从原父摘下来、
## 挂到新父"。分成两套只会让"跨组拖拽"和"组内重排"各有一套边界条件。
## 【为什么必须挡祖先】把组挂进自己的子树会造出环 —— 环上的节点既不在任何根的可达集合里、
## 又互相引用，求值会无限递归、存盘会写出悬空引用。这里直接拒绝，而不是事后检测。
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


func _walk_list(list: Array[QVoxelNode], visitor: Callable) -> void:
	for n in list:
		if n == null:
			continue
		visitor.call(n)
		if n.is_group():
			_walk_list((n as QVoxelGroup).child_nodes, visitor)


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


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _touch() -> void:
	revision += 1
	content_changed.emit()


func _settings() -> Dictionary:
	var w: Variant = head.get("world")
	return w if w is Dictionary else {}


## 造一份"改过某个键"的设置副本。**不看原字典**（见类头铁律），缺了 world 键就得到一份
## 只含这个键的新字典 —— 这正是"缺了就补一个"的新写法：补的是副本，不是原地挖个洞。
func _patched_settings(key: String, value: Variant) -> Dictionary:
	var w := _settings().duplicate()
	w[key] = value
	return w


func _write_settings(w: Dictionary) -> void:
	head["world"] = w
	_touch()


## 取 node 下的 JSON 数组。缺失 / 类型不对一律回落到空数组 ——
## **不就地补键**：读路径不写数据，只有 setter 才写。
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


## 造一条"先套缺省值、再盖上 seed"的新条目。**必须复制缺省表**：QVoxelSpec 里的表是 const，
## 改它会直接运行期报错，而且会污染此后所有新条目。
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
## 【为什么排序】Dictionary 迭代顺序不保证稳定，而落盘字节、增量写的块搬运、
## 回归测试的逐字节哈希都要求"同一份数据 ⇒ 同一串字节"。
func _dense_blocks_of(o: QVoxelModel) -> Dictionary:
	var out := {}
	var bs := o.block_size
	for k in o.block_keys():
		var buf := o.get_block(k)
		if buf.size() != QVoxelSpec.block_volume(bs):
			continue
		var solid := false
		for m in buf:
			if m != 0:
				solid = true
				break
		if solid:
			out[k] = buf
	return out


## NODE JSON：把场景树写进 nodes，其余键**原样保留**。
##
## 【为什么是"打补丁"而不是"重新生成"】NODE 里还有相机、动画、我们的未知键。
## 重新生成会静默丢掉它们；打补丁则只碰自己拥有的键（§7：格式不解释未知键）。
##
## 【为什么显式 erase("layers")】图层已被树取代（qvx 3）。node 里若还留着旧的 layers 键，
## 写回去就等于"存盘时复活了一个已经删掉的概念"，下次读盘还会被当成有效数据。
##
## 【为什么也要 erase("animations")】旧动画键按"节点下标"寻址，与 v3 的嵌套树对不上号
## （§12.4：动画已并入各模型节点的 `anim` 键）。留着它 → 下次读盘拿到一份指向错误节点的
## 动画元数据，且与 `anim` 并存时谁生效取决于读取顺序（这类"两处真值"正是要消掉的）。
func _node_json() -> Dictionary:
	var out := node.duplicate(true)
	out.erase("layers")
	out.erase("animations")
	var arr: Array = []
	for n in nodes:
		if n != null:
			arr.append(_entry_of_node(n))
	if not arr.is_empty() or out.has("nodes"):
		out["nodes"] = arr
	return out


## 节点 → JSON 条目（递归）。缺省值一律**不写**（P2：缺省才是常态）：
## visible=true / locked=false 都是冗语，写了只会让文件更长、且"改回缺省"时需要记得删键。
##
## 【摆放为什么不在这里】它已是 steps 里的一条平移条目 —— 节点的摆放与链上的旋转 / 镜像
## 走同一条序列化路径，于是"文件里有两份摆放"这种可能根本不存在。
func _entry_of_node(n: QVoxelNode) -> Dictionary:
	var e := {}
	e["kind"] = n.kind()
	e["name"] = n.node_name
	if not n.visible:
		e["visible"] = false
	if n.locked:
		e["locked"] = true
	var steps: Array = []
	for m in n.modifiers:
		if m != null:
			steps.append(QVoxelModifierSerializer.modifier_to_dict(m))
	e["steps"] = steps
	if n.is_model():
		var mo := n as QVoxelModel
		e["model_id"] = mo.model_id
		e["size"] = [mo.grid_size.x, mo.grid_size.y, mo.grid_size.z]
		var anim := _anim_of_model(mo)
		if not anim.is_empty():
			e["anim"] = anim
	else:
		var kids: Array = []
		for c in (n as QVoxelGroup).child_nodes:
			if c != null:
				kids.append(_entry_of_node(c))
		e["children"] = kids
	return e


## 节点里的 steps → 修改器链。认不出来的条目**跳过**（而不是让整份工程加载失败）：
## 一个失联的算子不该把用户另外九十九个对象一起拖下水。
static func _modifiers_of_entry(entry: Dictionary) -> Array[QVoxelModifier]:
	var out: Array[QVoxelModifier] = []
	var steps: Variant = entry.get("steps")
	if not (steps is Array):
		return out
	for d in (steps as Array):
		var m := QVoxelModifierSerializer.modifier_from_dict(d)
		if m != null:
			out.append(m)
	return out


## 节点里显式写了 size 就用它；否则从块范围推断（外来文件可能没写 size）。
##
## 【为什么推断要并上**所有**帧】动画模型的分辨率是整份 FRAM 共用的（§12.2），
## 只看第 0 帧会让"第 5 帧才长出外圈"的模型分辨率偏小 → 那些体素一进来就被判越界丢掉。
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
## 【为什么舍入到块边界】块是稀疏存储的分配单位，分辨率若不是它的整数倍，
## 最外一圈块就有一半永远用不到；外来文件本来也没记分辨率，取整是代价最小的还原。
static func _infer_grid(blocks: Dictionary, bs: int) -> Vector3i:
	var mx := Vector3i(bs, bs, bs)
	for k: Vector3i in blocks:
		mx.x = maxi(mx.x, (k.x + 1) * bs)
		mx.y = maxi(mx.y, (k.y + 1) * bs)
		mx.z = maxi(mx.z, (k.z + 1) * bs)
	return mx


static func _color_of(entry: Variant) -> Color:
	if not (entry is Dictionary):
		return Color.MAGENTA
	var e: Dictionary = entry
	return Color8(int(e.get("r", 255)), int(e.get("g", 0)), int(e.get("b", 255)),
			int(e.get("a", 255)))


static func _rgba_of(c: Color) -> int:
	var r := int(round(c.r * 255.0)) & 0xFF
	var g := int(round(c.g * 255.0)) & 0xFF
	var b := int(round(c.b * 255.0)) & 0xFF
	var a := int(round(c.a * 255.0)) & 0xFF
	return (r << 24) | (g << 16) | (b << 8) | a


## 空气条目（ID 0）。材质 ID 0 = 空，必须全零，否则 QVoxelFile 会把它当实体材质。
static func _air_entry() -> Dictionary:
	return {"rgba": 0, "r": 0, "g": 0, "b": 0, "a": 0,
			"metal": 0, "rough": 0, "hardness": 0, "mass": 0,
			"e_r": 0, "e_g": 0, "e_b": 0}
