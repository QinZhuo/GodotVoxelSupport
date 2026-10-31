class_name QVoxelierSession
extends RefCounted
## 应用会话：**世界 + 每个对象一条编辑会话 + 工程状态 + 应用能力**。
## 【为什么它必须独立于视口脚本】§2.1 把"应用能力"（改世界、记撤销）划给 App/Command 层，
## 把"只管 UI，不含算法"划给 View 层。此前这些能力住在 `QVoxelierApp` 里，于是那个类同时是
## 界面装配、输入翻译、命令编排与刷新中枢（1789 行）。本类承接其中的**数据与应用能力**，
## 视口脚本因此只剩装配 / 翻译 / 刷新三件事。
## 【它不认识任何 UI 类型】不引用 hud、不引用面板、不引用渲染器 —— 要说话就发信号：
##   · `hint`          —— 一句面向用户的提示（View 转给状态栏）
##   · `changed`       —— 数据变了（View 据此重挂显示层 + 刷面板）
##   · `dirty_changed` —— 未落盘改动变化（View 据此刷标题星号）
## 这条边界是可测性的全部依据：本类可无头驱动（见 Scripts/Test/test_qvoxelier_session.gd）。
## 【显示层怎么被叫醒】会话刻意不认识渲染器，故"哪一份数据该喂给哪个渲染器"由 View 注入：
## `render_update` 是 View 给的唤醒回调，本类新建 / 重挂 QVoxelEditSession 时压给它们。
## 与 `QVoxelEditSession.request_render_update` 同一套约定，只是从"一条会话一个"提到"一个应用一个"。

## 一句面向用户的提示（越界、没有可撤销的、已切换到 X 这类"刚发生的事"）。
signal hint(text: String)
## 数据变了：世界结构 / 链 / 材质 / 帧 / 当前活动对象。View 收到后重挂显示层并刷新界面。
signal changed()
## 未落盘改动变化（状态栏与窗口标题上的 *）。
signal dirty_changed(dirty: bool)

## 渲染唤醒回调（View 注入 `model.request_update`）。空 Callable = 无显示层，会话照样能跑。
var render_update := Callable()

## 当前世界。换世界只走 `install`（新建 / 打开工程共用那一条路径）。
var world: QVoxelWorld
## 当前活动编辑会话（`_sessions` 里的一条；切对象只换这个引用）。
var session: QVoxelEditSession
## 每个对象一条展示会话：model_id → QVoxelEditSession。**活动那条就是 session**。
## 非活动会话不接鼠标，只负责把它那份 QVoxelSource 喂给对应渲染器。
var _sessions: Dictionary = {}
## 帧末的 changed 是否已经排上队（一帧内多次改动只通知一次）。
var _changed_queued := false

## 当前工程文件路径（空 = 还没存过盘的新工程，"保存"会转成"另存为"）。
var project_path := ""
## 有未落盘的改动。
var dirty := false


# 装配：世界 → 会话

## 新建一个空模型（grid 为 ZERO 时用 size）：建世界 → 建对象 → 装配。
## 【为什么尺寸与色板由调用方传入】它们是视口的 @export（在场景里可调），属 View 的配置；
## 本类只认"给我多大、给我哪些色"这两件事。
func new_model(grid: Vector3i, size: Vector3i, palette: Array[Color]) -> void:
	var g: Vector3i = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else size
	var w := QVoxelWorld.create_empty()
	for c in palette:
		w.add_material(c)
	install(w, w.create_model("Model", g))
	project_path = ""
	_set_dirty(false)


## 装配：世界 + 待编辑对象 → 每对象一条会话 + 活动会话。
## **新建与打开共用这一条路径** —— 两套初始化迟早会分叉出"新建能画、打开画不了"这类怪病。
func install(w: QVoxelWorld, obj: QVoxelModel) -> void:
	world = w
	# 每个对象一条展示会话：活动那条随后由 activate 选出，其余只喂渲染器
	# （理由见 _sessions 的注释 —— 多对象世界才能"看见全部、只编辑一个"）。
	_sessions.clear()
	for o in w.all_models():
		if o != null:
			_sessions[o.model_id] = _make_session(o, w)
	session = null
	activate(obj.model_id)
	changed.emit()


## 切换"当前编辑对象"。三条入口共用这一条路径：对象列表点击、新建对象、打开工程挑初始对象。
## 【为什么不重建会话】非活动对象也早就有一条展示会话（见 install），切换只是把活动引用换掉。
## 于是撤销栈按对象各自保留 —— 切走再切回来，那一个对象的撤销历史还在，
## 不会因为"看了一眼别的对象"就清空。
## 返回是否真的换了对象（调用方据此决定要不要提示 / 重挂显示层）。
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


## 一期只编辑一个模型：优先挑"有内容"的那个（打开样例时第一眼就有东西看），都没有就取第一个。
## 多模型 / 组是二期的事。
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


## 每个对象一条展示会话。**request_render_update 一律指向 View 注入的那条回调** ——
## 会话不认识渲染器，只认这个 Callable（见类文档）。
func _make_session(o: QVoxelModel, w: QVoxelWorld) -> QVoxelEditSession:
	var s := QVoxelEditSession.create_for(o, w)
	s.request_render_update = render_update
	s.history.changed.connect(_on_history_changed)
	return s


## 撤销栈一动就说明内容变了 —— 标脏 + 请 View 刷新，不会各说各话。
## 【为什么请 View 刷新要延到帧末】`history.changed` 是在命令写进**对象**之后、而
## `QVoxelEditSession._refresh`（作废显示层缓存）之前发出来的。View 的刷新会真的去取数：
## 状态栏的体素数是当场重建求值体积得到的（见 QVoxelSource.evaluated_voxel_count），
## 若此时缓存尚未作废，这次重建立刻会被随后的 _refresh 再作废一次 —— 一次落笔白算两遍整条链；
## 而撤销那条路径更糟：体积缓存还是改动前那份，读数会停在旧数字上。
## 推到帧末，_refresh 已经跑完，取到的是本次改动之后的那一份。
## （标脏仍走当场：那是"文件有没有改过"的账，与显示层无关。）
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
## 新模型会挂一条展示会话并**直接切过去** —— 建了却停在旧的上面，用户会以为没建成。
func add_model(parent: QVoxelGroup) -> void:
	if world == null or session == null:
		return
	# 尺寸随**当前输出盒**（= 屏幕上看到的那个大小），而不是手绘种子的尺寸：
	# 当前模型若挂了平铺，照抄种子尺寸会做出一个明显更小的"同样大小"的模型。
	var o := world.create_model("", session.output_size(), parent)
	_sessions[o.model_id] = _make_session(o, world)
	_set_dirty(true)
	activate(o.model_id)


## 新建组。组没有内容，故只标脏 + 请 View 刷新（不切换编辑对象）。
func add_group(parent: QVoxelGroup) -> void:
	if world == null:
		return
	world.create_group("Group", parent)
	_set_dirty(true)
	hint.emit("已新建组")
	changed.emit()


## 删除节点（连同子树）。
## 【为什么删组不先拆散】"删掉这个组"在用户心里就是"这一坨不要了"；想留内容就先把它拖出来。
## 拆散是另一个动作，混进来会让"删除"变得不可预期。
## 【为什么不入撤销栈】结构增删与体素编辑是两类东西：后者才是高频、真正需要逐笔回退的手势。
func remove_node(node: QVoxelNode) -> void:
	if world == null or node == null:
		return
	# 至少留一个模型：世界空了就无物可编。
	if node.is_model() and world.all_models().size() <= 1:
		hint.emit("至少要留一个模型")
		return
	var gone: Array[QVoxelModel] = []
	for n in world.all_nodes():
		if n.is_model() and _is_under(node, n):
			gone.append(n as QVoxelModel)
	for m in gone:
		var s: QVoxelEditSession = _sessions.get(m.model_id)
		if s != null and s.history.changed.is_connected(_on_history_changed):
			s.history.changed.disconnect(_on_history_changed)
		_sessions.erase(m.model_id)
	var was_active := session != null and gone.has(session.object)
	world.remove_node(node)
	_set_dirty(true)
	if was_active:
		session = null
		var rest := world.all_models()
		if not rest.is_empty():
			activate(rest[0].model_id)
			hint.emit("已删除当前模型，切到 %s" % rest[0].display_name())
		return
	changed.emit()
	hint.emit("已删除 %s" % node.display_name())


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
## 【为什么"移动"和"插入"是同一个操作】树上没有"移动"这回事 —— 移动就是"从原父摘下来、
## 挂到新父"。QVoxelWorld.attach_node 直接拒绝"把组挂进自己的子树"（那会造出环）。
func move_node(node: QVoxelNode, parent: QVoxelGroup, index: int) -> void:
	if world == null or node == null:
		return
	if not world.attach_node(node, parent, index):
		hint.emit("不能把组放进它自己里面")
		return
	_set_dirty(true)
	changed.emit()


## 改节点的一个字段并记成一条可撤销命令。
## 【为什么改完要重建显示】可见性不只是个数据字段 —— 它决定该节点渲染与否；
## 而这条命令的 undo() 只写属性、不会替我们叫醒视口，故两条路径都得手动重建（由 changed 带出）。
func write_node_field(node: QVoxelNode, prop: StringName, value: Variant, label: String) -> void:
	if world == null or node == null or session == null:
		return
	var cmd := QVoxelPropertyCommand.apply(node, prop, value, node, label)
	if cmd != null:
		session.history.push(cmd)
	changed.emit()


# 工程状态

## 标记"有未落盘改动"。对象增删这类不入撤销栈的操作也走这里，保证标题星号不漏。
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
