class_name QVoxelierSession
extends RefCounted
## 应用会话：**世界 + 每个对象一条编辑会话 + 工程状态 + 应用能力**。

## 一句面向用户的提示（越界、没有可撤销的、已切换到 X 这类"刚发生的事"）。
signal hint(text: String)
## 数据变了：世界结构 / 链 / 材质 / 帧 / 当前活动对象。
signal changed()
## 未落盘改动变化（状态栏与窗口标题上的 *）。
signal dirty_changed(dirty: bool)

## 渲染唤醒回调（View 注入 `model.request_update`）。
var render_update := Callable()

## 当前世界。
var world: QVoxelWorld
## 当前活动编辑会话（`_sessions` 里的一条；切对象只换这个引用）。
var session: QVoxelEditSession
## 每个对象一条展示会话：model_id → QVoxelEditSession。
var _sessions: Dictionary = {}
## 帧末的 changed 是否已经排上队（一帧内多次改动只通知一次）。
var _changed_queued := false

## 当前工程文件路径（空 = 还没存过盘的新工程，"保存"会转成"另存为"）。
var project_path := ""
## 有未落盘的改动。
var dirty := false

# 装配：世界 → 会话

## 新建一个空模型（grid 为 ZERO 时用 size）：建世界 → 建对象 → 装配。
func new_model(grid: Vector3i, size: Vector3i, palette: Array[Color]) -> void:
	var g: Vector3i = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else size
	var w := QVoxelWorld.create_empty()
	for c in palette:
		w.add_material(c)
	install(w, w.create_model("Model", g))
	project_path = ""
	_set_dirty(false)

## 装配：世界 + 待编辑对象 → 每对象一条会话 + 活动会话。
func install(w: QVoxelWorld, obj: QVoxelModel) -> void:
	world = w
	# 每个对象一条展示会话：活动那条随后由 activate 选出，其余只喂渲染器
	_sessions.clear()
	for o in w.all_models():
		if o != null:
			_sessions[o.model_id] = _make_session(o, w)
	session = null
	activate(obj.model_id)
	changed.emit()

## 切换"当前编辑对象"。
func activate(model_id: int) -> bool:
	if world == null:
		return false
	var o := world.find_model(model_id)
	if o == null:
		return false
	if session != null and session.object == o:
		return false
	session = _sessions.get(model_id)
	if session == null:
		return false
	changed.emit()
	return true

## 打开时挑哪个模型作为**初始活动对象**：优先"有内容"的那个（打开样例时第一眼就有东西看），
static func pick_editable(w: QVoxelWorld) -> QVoxelModel:
	var first: QVoxelModel = null
	for o in w.all_models():
		if o == null:
			continue
		if first == null:
			first = o
		if not o.is_empty():
			return o
	return first

# 会话查询（View 的渲染器装配要按"世界的全部对象"挨个喂数据，故需要能遍历）

func session_for(model_id: int) -> QVoxelEditSession:
	return _sessions.get(model_id)

func all_sessions() -> Array[QVoxelEditSession]:
	var out: Array[QVoxelEditSession] = []
	for s in _sessions.values():
		out.append(s)
	return out

## 每个对象一条展示会话。
func _make_session(o: QVoxelModel, w: QVoxelWorld) -> QVoxelEditSession:
	var s := QVoxelEditSession.create_for(o, w)
	s.request_render_update = render_update
	s.history.changed.connect(_on_history_changed)
	return s

## 撤销栈一动就说明内容变了 —— 标脏 + 请 View 刷新，不会各说各话。
func _on_history_changed() -> void:
	_set_dirty(true)
	if _changed_queued:
		return
	_changed_queued = true
	_emit_changed.call_deferred()

func _emit_changed() -> void:
	_changed_queued = false
	changed.emit()

# 层级结构（树上的增 / 删 / 移 / 改字段）

## 新建模型：尺寸随当前模型（"再做一个同样大小的"是最常见的心智模型）。
func add_model(parent: QVoxelGroup) -> QVoxelModel:
	if world == null or session == null:
		return null
	# 尺寸随**当前输出盒**（= 屏幕上看到的那个大小），而不是手绘种子的尺寸：
	var o := world.create_model("", session.output_size(), parent)
	_sessions[o.model_id] = _make_session(o, world)
	activate(o.model_id)
	_record_structure(o, null, QVoxelStructureCommand.OFF_TREE, "新建模型")
	return o

## 新建组。
func add_group(parent: QVoxelGroup) -> QVoxelGroup:
	if world == null:
		return null
	var g := world.create_group("Group", parent)
	_record_structure(g, null, QVoxelStructureCommand.OFF_TREE, "新建组")
	hint.emit("已新建组")
	changed.emit()
	return g

## 删除节点（连同子树）。
func remove_node(node: QVoxelNode) -> void:
	if world == null or node == null:
		return
	# 至少留一个模型：世界空了就无物可编。
	if node.is_model() and world.all_models().size() <= 1:
		hint.emit("至少要留一个模型")
		return
	var from_parent := world.find_parent(node)
	var from_index := world.index_of(node)
	# 先抓住"删除前那个对象的栈"：删的可能正是当前对象，摘除后 session 就换人了，
	var hist := session
	var switched := _drop_node(node)
	_record_structure(node, from_parent, from_index, "删除 %s" % node.display_name(), hist)
	if not switched:
		hint.emit("已删除 %s" % node.display_name())

## 把节点放到指定位置（`parent == null` 且 `index < 0` = 从树上摘掉）。
func place_node(node: QVoxelNode, parent: QVoxelGroup, index: int) -> void:
	if world == null or node == null or _place_is(node, parent, index):
		return
	if parent == null and index < 0:
		_drop_node(node)
	else:
		if not world.attach_node(node, parent, index):
			hint.emit("不能把组放进它自己里面")
			return
		_open_sessions(node)
	_set_dirty(true)
	changed.emit()

## 记一条结构命令。
func _record_structure(node: QVoxelNode, from_parent: QVoxelGroup, from_index: int,
		label: String, hist: QVoxelEditSession = null) -> void:
	var target := hist if hist != null else session
	if target == null:
		return
	var cmd := QVoxelStructureCommand.new()
	cmd.node = node
	cmd.host = self
	cmd.label = label
	cmd.from_parent = from_parent
	cmd.from_index = from_index
	cmd.to_parent = world.find_parent(node)
	cmd.to_index = world.index_of(node)
	target.history.push(cmd)

## 节点当前是否就在这个位置。
func _place_is(node: QVoxelNode, parent: QVoxelGroup, index: int) -> bool:
	var on_tree := world.nodes.has(node) or world.find_parent(node) != null
	if parent == null and index < 0:
		return not on_tree
	if not on_tree or world.find_parent(node) != parent:
		return false
	return index < 0 or world.index_of(node) == index

## 从树上摘掉，并清掉子树里所有模型的编辑会话；摘的是当前对象就切到剩下的第一个。
func _drop_node(node: QVoxelNode) -> bool:
	var gone: Array[QVoxelModel] = []
	for n in world.all_nodes():
		if n.is_model() and _is_under(node, n):
			gone.append(n as QVoxelModel)
	for m in gone:
		_close_session(m.model_id)
	var was_active := session != null and gone.has(session.object)
	world.remove_node(node)
	_set_dirty(true)
	if not was_active:
		return false
	session = null
	var rest := world.all_models()
	if not rest.is_empty():
		activate(rest[0].model_id)
		hint.emit("已删除当前模型，切到 %s" % rest[0].display_name())
	return true

## 给子树里还没有编辑会话的模型补上（撤销"删除"之后它们要能立刻编辑）。
func _open_sessions(node: QVoxelNode) -> void:
	for n in world.all_nodes():
		if n.is_model() and _is_under(node, n):
			var m := n as QVoxelModel
			if not _sessions.has(m.model_id):
				_sessions[m.model_id] = _make_session(m, world)
	if session == null:
		var rest := world.all_models()
		if not rest.is_empty():
			activate(rest[0].model_id)

## 关掉某个模型的编辑会话（断开它的历史信号，免得已摘下的模型还在影响脏标记）。
func _close_session(model_id: int) -> void:
	var s: QVoxelEditSession = _sessions.get(model_id)
	if s != null and s.history.changed.is_connected(_on_history_changed):
		s.history.changed.disconnect(_on_history_changed)
	_sessions.erase(model_id)

## node 是否在 root 的子树里（含 root 自己）。
func _is_under(root: QVoxelNode, node: QVoxelNode) -> bool:
	if root == node:
		return true
	if not root.is_group():
		return false
	for c in (root as QVoxelGroup).child_nodes:
		if c != null and _is_under(c, node):
			return true
	return false

## 沿树往上看：任何一层隐藏都算数（可见性**沿树继承**）。
func node_visible(node: QVoxelNode) -> bool:
	var n := node
	while n != null:
		if not n.visible:
			return false
		n = world.find_parent(n)
	return true

## 沿树往上看：任何一层锁定都算数（锁定**沿树继承**）。
func node_locked(node: QVoxelNode) -> bool:
	var n := node
	while n != null:
		if n.locked:
			return true
		n = world.find_parent(n)
	return false

func set_node_visible(node: QVoxelNode, on: bool) -> void:
	write_node_field(node, &"visible", on, "可见性")

func set_node_locked(node: QVoxelNode, on: bool) -> void:
	write_node_field(node, &"locked", on, "锁定")

func rename_node(node: QVoxelNode, new_name: String) -> void:
	write_node_field(node, &"node_name", new_name, "重命名")

## 拖拽落位：把节点挂到新父下的 index 位置。
func move_node(node: QVoxelNode, parent: QVoxelGroup, index: int) -> void:
	if world == null or node == null:
		return
	var from_parent := world.find_parent(node)
	var from_index := world.index_of(node)
	if not world.attach_node(node, parent, index):
		hint.emit("不能把组放进它自己里面")
		return
	_record_structure(node, from_parent, from_index, "移动 %s" % node.display_name())
	_set_dirty(true)
	changed.emit()

## 改节点的一个字段并记成一条可撤销命令。
func write_node_field(node: QVoxelNode, prop: StringName, value: Variant, label: String) -> void:
	if world == null or node == null or session == null:
		return
	var cmd := QVoxelPropertyCommand.apply(node, prop, value, node, label)
	if cmd != null:
		session.history.push(cmd)
	changed.emit()

# 工程状态

## 标记"有未落盘改动"。
func mark_dirty() -> void:
	_set_dirty(true)

## 落盘 / 新建 / 打开之后清掉脏标记（View 的 I/O 编排调）。
func clear_dirty() -> void:
	_set_dirty(false)

func _set_dirty(on: bool) -> void:
	if dirty == on:
		return
	dirty = on
	dirty_changed.emit(on)
