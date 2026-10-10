@tool
class_name QVoxelierObjectSection
extends QVoxelierSection
## 右侧抽屉·**对象属性**分组：显示当前在层级里选中的那个节点的数据。
## 【为什么要有它】层级树（Outliner）负责"选谁"，本组负责"它是什么"—— 与 Blender 的
## Outliner + Properties 分工一致。选中模型看尺寸 / 体素数，选中组看子模型数；改名与
## 可见 / 锁定也在这里再给一份入口（树上也有，但属性区里能一眼看到当前对象全貌）。
## 【只读信息 + 轻量编辑】尺寸 / 体素数这类是**求值产物**，这里只读展示；改名是低频结构改动，
## 走与树同一条 rename 信号、由 App 记成命令。

signal rename_requested(node: QVoxelNode, new_name: String)
signal visible_changed(node: QVoxelNode, value: bool)
signal locked_changed(node: QVoxelNode, value: bool)

var _node: QVoxelNode
var _name: LineEdit
var _vis: Button
var _lock: Button
var _info: VBoxContainer


func section_title() -> String:
	return "对象"


func _build_body(body: VBoxContainer) -> void:
	var head := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(head)
	_name = QVoxelUi.text_field("", "名称", "节点名（回车或失焦提交）")
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text_submitted.connect(func(t: String) -> void:
		if _node != null and t != _node.display_name():
			rename_requested.emit(_node, t))
	_name.focus_exited.connect(func() -> void:
		if _node != null and _name.text != _node.display_name():
			rename_requested.emit(_node, _name.text))
	head.add_child(_name)

	var toggles := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(toggles)
	_vis = QVoxelUi.toggle_button("显示 / 隐藏（沿树继承）")
	_vis.text = "可见"
	_vis.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vis.toggled.connect(func(on: bool) -> void:
		if _node != null: visible_changed.emit(_node, on))
	toggles.add_child(_vis)
	_lock = QVoxelUi.toggle_button("锁定（沿树继承，锁上后整棵子树不可编辑）")
	_lock.text = "锁定"
	_lock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lock.toggled.connect(func(on: bool) -> void:
		if _node != null: locked_changed.emit(_node, on))
	toggles.add_child(_lock)

	_info = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	body.add_child(_info)
	_rebuild()


## 绑定选中的节点（App 在树上点选 / 撤销后调用）。
func bind(node: QVoxelNode) -> void:
	_node = node
	_rebuild()


func _rebuild() -> void:
	if _info == null:
		return
	for c in _info.get_children():
		_info.remove_child(c)
		c.queue_free()
	var has := _node != null
	_name.editable = has
	_vis.disabled = not has
	_lock.disabled = not has
	if not has:
		_name.text = ""
		_info.add_child(QVoxelUi.label("（未选中对象）", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		return
	# 正在输入时不要回写名字（刷新会打断用户打字）。
	if not _name.has_focus():
		_name.text = _node.display_name()
	_vis.set_pressed_no_signal(_node.visible)
	_lock.set_pressed_no_signal(_node.locked)
	if _node.is_model():
		var m := _node as QVoxelModel
		var g := m.grid_size
		_kv("类型", "模型 #%d" % m.model_id)
		_kv("尺度", "%d × %d × %d" % [g.x, g.y, g.z])
		_kv("体素", "%d" % m.count_solid())
		_kv("修改器", "%d 条" % m.modifiers.size())
	else:
		var grp := _node as QVoxelGroup
		_kv("类型", "组")
		_kv("子模型", "%d" % grp.count_models())
		_kv("修改器", "%d 条" % grp.modifiers.size())


func _kv(k: String, v: String) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	_info.add_child(row)
	var key := QVoxelUi.label(k, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	key.custom_minimum_size.x = 48
	row.add_child(key)
	var val := QVoxelUi.label(v, QVoxelUi.FONT_S, QVoxelUi.TEXT)
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(val)
