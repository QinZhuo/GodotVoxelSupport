@tool
class_name QVoxelierTreeSection
extends QVoxelierSection
## 统一层级树 —— **唯一的层级入口**。
##
## 【为什么只有一个面板】以前层级被拆成三处：对象面板（谁存在）、图层面板（谁和谁一组、
## 可见 / 锁定）、变换面板（摆在哪）。同一件事被切成三份，于是"删层要记得搬 layer"、
## "隐藏对象其实隐藏的是它那层"这类跨面板的隐性耦合到处滋生。现在组 / 模型 / 修改器
## 是**同一棵树上的三种行**，一切关系一眼可见、随手可改。
##
## 【树视图是模型的纯投影】落位只改 QVoxWorld.nodes，然后整棵重建。
## 绝不在行控件上做增删 —— 行控件是"投影出来的像素"，不是数据。
##
## 【为什么自绘而不是 Godot 的 Tree】Tree 自带整套滚选 / 焦点语义，行内只能放
## "单元格 + 图标 + 按钮"，且触摸命中区不达标（见 QVoxUi 密度档的说明）。
## 自绘则每行都是**整行按钮**，行内可放任意控件。
##
## 【为什么本面板只发信号、不直接改数据】改动要能撤销，而撤销命令属于应用层
## （QVoxPropertyCommand，见 DESIGN §2.8）。面板只报告"用户想做什么"，由 App 决定怎么记。

## 选中某个节点（模型用于切换当前编辑对象；组用于后续"整组操作"）。
signal node_selected(node: QVoxNode)
## 在 parent 下新建模型 / 组（parent 为 null = 顶层）。
signal model_add_requested(parent: QVoxGroup)
signal group_add_requested(parent: QVoxGroup)
## 删除节点（连同子树）。
signal node_remove_requested(node: QVoxNode)
## 可见性 / 锁定 / 改名。
signal node_visible_changed(node: QVoxNode, value: bool)
signal node_locked_changed(node: QVoxNode, value: bool)
signal node_rename_requested(node: QVoxNode, new_name: String)
## 拖拽落位：把 node 挂到 parent 下的 index（parent 为 null = 顶层）。
signal node_move_requested(node: QVoxNode, parent: QVoxGroup, index: int)
## 在某节点的链上追加一条修改器（kind 取 QVoxModifier.KINDS）。
signal modifier_add_requested(node: QVoxNode, kind: String)
## 从某节点的链上移除第 index 条修改器。
signal modifier_remove_requested(node: QVoxNode, index: int)
## 旁通 / 启用某节点链上的第 index 条修改器。
signal modifier_enabled_changed(node: QVoxNode, index: int, value: bool)
## 选中某节点链上的第 index 条修改器（供参数分组显示）。
signal modifier_selected(node: QVoxNode, index: int)

const INDENT := 14

var _world: QVoxWorld
var _active_id := -1
var _rows: VBoxContainer
var _hint: Label
var _del: Button
var _selected: QVoxNode


func section_title() -> String:
	return "层级"


func _build_body(body: VBoxContainer) -> void:
	var tools := QVoxUi.hbox(QVoxUi.SPACE_XS)
	body.add_child(tools)
	var add_group := QVoxUi.button("＋组", "新建一个组（像文件夹一样把模型装在一起）")
	add_group.pressed.connect(func(): group_add_requested.emit(_target_parent()))
	tools.add_child(add_group)
	var add_model := QVoxUi.button("＋模型", "在当前组里新建一个模型")
	add_model.pressed.connect(func(): model_add_requested.emit(_target_parent()))
	tools.add_child(add_model)
	_del = QVoxUi.button("删除", "删除选中的节点（连同它下面的全部内容）")
	_del.disabled = true
	_del.pressed.connect(func():
		if _selected != null:
			node_remove_requested.emit(_selected))
	tools.add_child(_del)
	var add_mod := QVoxUi.button("＋滤镜", "给选中的节点挂一条修改器（挂上后再点它改参数）")
	add_mod.pressed.connect(_popup_modifier_kinds.bind(add_mod))
	tools.add_child(add_mod)

	_hint = QVoxUi.label("", QVoxUi.FONT_S, QVoxUi.TEXT_FAINT)
	body.add_child(_hint)

	_rows = QVoxUi.vbox(QVoxUi.SPACE_XS)
	body.add_child(_rows)


## 挂上世界。**每次换世界都要调**（新建 / 打开工程）。
func set_world(world: QVoxWorld, active_id := -1) -> void:
	_world = world
	_active_id = active_id
	_selected = null
	_rebuild()


## 当前活动模型变了（视口里正在编辑的那一个）。
func set_active(active_id: int) -> void:
	_active_id = active_id
	_rebuild()


## 世界内容变了（结构 / 链 / 参数）→ 重投影。
func refresh() -> void:
	_rebuild()


# ----------------------------------------------------------------------------
# 投影
# ----------------------------------------------------------------------------

func _rebuild() -> void:
	if _rows == null:
		return
	for c in _rows.get_children():
		c.queue_free()
	if _world == null:
		_hint.text = "没有打开的世界"
		return
	var total := _world.nodes.size()
	if total == 0:
		_hint.text = "空世界：点「＋模型」开始"
	else:
		_hint.text = "%d 个顶层节点 · 共 %d 个模型" % [total, _world.all_models().size()]
	for n in _world.nodes:
		if n != null:
			_add_rows(n, 0)


func _add_rows(node: QVoxNode, depth: int) -> void:
	_rows.add_child(_make_row(node, depth))
	# 折叠的组：子树与它自己的链都藏起来（眼不见即"这组现在不参与"）。
	if node.is_group() and not node.expanded_in_tree:
		return
	if node.is_group():
		for c in (node as QVoxGroup).child_nodes:
			if c != null:
				_add_rows(c, depth + 1)
	# 链是节点的**一部分**（见 QVoxNode），故紧跟在它的子树之后、再缩进一级显示。
	for i in node.modifiers.size():
		_rows.add_child(_make_modifier_row(node, i, depth + 1))


## 一条修改器行：旁通开关 / 显示名 / 移除。点整行 = 选中它去改参数。
##
## 【为什么修改器要成为树上的行，而不是另开一个面板】链是节点的属性，"哪条链属于谁"必须
## 一眼可见；另开面板就要维护"当前看的是谁的链"这份额外的选中状态。成为行之后，选中状态
## 就是行本身，增删改都落在同一棵树里（"万物皆修改器"在 UI 上的对应物）。
func _make_modifier_row(node: QVoxNode, index: int, depth: int) -> Control:
	var m: QVoxModifier = node.modifiers[index]
	var row := TreeRow.new()
	row.node = node
	row.modifier_index = index
	row.section = self
	row.depth = depth
	row.custom_minimum_size.y = QVoxUi.hit_size()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = _modifier_tooltip(node, index, m)
	row.add_theme_color_override("font_color", QVoxUi.TEXT_DIM)
	row.pressed.connect(func(): modifier_selected.emit(node, index))

	var box := QVoxUi.hbox(QVoxUi.SPACE_XS)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(8 + depth * INDENT, 0)
	row.add_child(box)

	# 旁通开关：不删条目、只是不参与求值（与 Blender 的修改器眼睛同义）。
	var on := QVoxUi.toggle_button("旁通 / 启用这条修改器")
	on.button_pressed = m.enabled
	on.text = "◉" if m.enabled else "○"
	on.toggled.connect(func(v: bool):
		on.text = "◉" if v else "○"
		modifier_enabled_changed.emit(node, index, v))
	box.add_child(on)

	var text := "· %s" % m.display_name()
	if not m.enabled:
		text += "（旁通）"
	var name_label := QVoxUi.label(text, QVoxUi.FONT_S,
			QVoxUi.TEXT if m.enabled else QVoxUi.TEXT_FAINT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(name_label)

	var rm := QVoxUi.icon_button("×", "从链上移除这条修改器")
	rm.pressed.connect(func(): modifier_remove_requested.emit(node, index))
	box.add_child(rm)
	return row


func _modifier_tooltip(node: QVoxNode, index: int, m: QVoxModifier) -> String:
	var lines := PackedStringArray()
	lines.append("%s · 第 %d 条" % [m.display_name(), index + 1])
	lines.append("种类 %s · 合成 %d" % [m.kind(), int(m.combine)])
	if not m.enabled:
		lines.append("已旁通（不参与求值）")
	for e in QVoxDomain.chain_errors([m]):
		lines.append("· %s" % e["message"])
	return "\n".join(lines)


## 弹"挂哪种滤镜"菜单。条目直接来自 QVoxModifier.KINDS —— 将来加一种域就自动多一项。
func _popup_modifier_kinds(anchor: Control) -> void:
	if _selected == null:
		_hint.text = "先在树上点一个节点，再挂滤镜"
		return
	var menu := PopupMenu.new()
	add_child(menu)
	for i in QVoxModifier.KINDS.size():
		menu.add_item(QVoxModifier.KIND_NAMES[i], i)
	menu.id_pressed.connect(func(id: int) -> void:
		modifier_add_requested.emit(_selected, QVoxModifier.KINDS[id]))
	menu.popup_closed.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(anchor.global_position), Vector2i(anchor.size)))


func _make_row(node: QVoxNode, depth: int) -> Control:
	var row := TreeRow.new()
	row.node = node
	row.section = self
	row.depth = depth
	row.custom_minimum_size.y = QVoxUi.hit_size()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = _row_tooltip(node)
	row.add_theme_color_override("font_color", QVoxUi.ACCENT if _is_active(node) else QVoxUi.TEXT)
	row.pressed.connect(func():
		_selected = node
		_del.disabled = false
		node_selected.emit(node)
		_rebuild())

	var box := QVoxUi.hbox(QVoxUi.SPACE_XS)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(8 + depth * INDENT, 0)
	row.add_child(box)

	# 展开箭头（只有组有）。
	if node.is_group():
		var arrow := QVoxUi.label("▾" if node.expanded_in_tree else "▸", QVoxUi.FONT_S, QVoxUi.TEXT_DIM)
		box.add_child(arrow)

	# 可见性 / 锁定：**每行都有**（组上就是"隐藏整组"）。
	var vis := QVoxUi.toggle_button("显示 / 隐藏")
	vis.button_pressed = node.visible
	vis.text = "👁"
	vis.toggled.connect(func(v): node_visible_changed.emit(node, v))
	box.add_child(vis)
	var lock := QVoxUi.toggle_button("锁定（锁上后整棵子树不可编辑）")
	lock.button_pressed = node.locked
	lock.text = "🔒"
	lock.toggled.connect(func(v): node_locked_changed.emit(node, v))
	box.add_child(lock)

	# 名字（双击改名走 LineEdit —— 触摸没有 hover，改名必须是显式动作）。
	var name_edit := LineEdit.new()
	name_edit.text = node.display_name()
	name_edit.flat = true
	name_edit.custom_minimum_size.x = 96
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(t):
		if t != node.display_name():
			node_rename_requested.emit(node, t))
	box.add_child(name_edit)

	# 类型 / 内容徽标。
	var badge := _badge_of(node)
	if not badge.is_empty():
		box.add_child(QVoxUi.label(badge, QVoxUi.FONT_S, QVoxUi.TEXT_FAINT))

	# 链校验徽标（出问题的那一行打红标，而不是等到求值崩）。
	var errs := _errors_of(node)
	if errs > 0:
		var warn := QVoxUi.label("⚠%d" % errs, QVoxUi.FONT_S, QVoxUi.WARN)
		warn.tooltip_text = _row_tooltip(node)
		box.add_child(warn)

	return row


func _badge_of(node: QVoxNode) -> String:
	if node.is_model():
		return "%d 体素" % (node as QVoxModel).count_solid()
	return "%d 模型" % (node as QVoxGroup).count_models()


func _row_tooltip(node: QVoxNode) -> String:
	var lines := PackedStringArray()
	lines.append(node.display_name())
	if node.is_model():
		var g := (node as QVoxModel).grid_size
		lines.append("模型 %d · %d×%d×%d" % [(node as QVoxModel).model_id, g.x, g.y, g.z])
	else:
		lines.append("组 · %d 个模型" % (node as QVoxGroup).count_models())
	# 摆放不在这里回显：它已是链上的一条（平移），下面"滤镜 N 条"里就看得见。
	var chain := node.active_modifiers()
	if not chain.is_empty():
		lines.append("滤镜 %d 条" % chain.size())
		for e in QVoxDomain.chain_errors(chain):
			lines.append("· %s" % e["message"])
	return "\n".join(lines)


## 本节点（含子树）里的链错误数。组行汇总子树 —— 折叠着也能看见"这组里有问题"。
func _errors_of(node: QVoxNode) -> int:
	var n := QVoxDomain.chain_errors(node.active_modifiers()).size()
	if node.is_group():
		for c in (node as QVoxGroup).child_nodes:
			if c != null:
				n += _errors_of(c)
	return n


func _is_active(node: QVoxNode) -> bool:
	return node.is_model() and (node as QVoxModel).model_id == _active_id


## 新建时的落点：选中的组就放进它，否则放顶层。
func _target_parent() -> QVoxGroup:
	if _selected != null and _selected.is_group():
		return _selected as QVoxGroup
	return null


# ----------------------------------------------------------------------------
# 拖拽落位（三个 Control 虚方法的实现体在 TreeRow 里）
# ----------------------------------------------------------------------------

## 把 dragged 落到 hovered 上，返回 [parent, index]；不合法返回 null。
##
## 【为什么"上 / 中 / 下三段"要自己算】因为不是 Godot 的 Tree（见类头），
## 也就没有 get_drop_section_at_position() 可借，只有自己按行高切三段。
func _drop_target(dragged: QVoxNode, hovered: QVoxNode, at: Vector2) -> Variant:
	if dragged == null or hovered == null or dragged == hovered:
		return null
	var h := float(QVoxUi.hit_size())
	# 正中 1/3 → 落进该组（成为它的最后一个子节点）。
	if hovered.is_group() and at.y >= h / 3.0 and at.y <= h * 2.0 / 3.0:
		if dragged == hovered:
			return null
		return [hovered, -1]
	# 上 / 下缘 → 与 hovered 同级，插在它前 / 后。
	var parent := _world.find_parent(hovered)
	var idx := _world.node_index(hovered)
	if idx < 0:
		return null
	if parent == null and not _world.nodes.has(hovered):
		return null
	return [parent, idx + (1 if at.y > h / 2.0 else 0)]


## 一行。继承 Button 是为了拿到 `_get_drag_data` / `_can_drop_data` / `_drop_data`
## 三个虚方法 —— 它们只能由脚本重写，没法"挂"到普通实例上。
class TreeRow extends Button:
	var node: QVoxNode
	var section: QVoxelierTreeSection
	var depth := 0
	## >= 0 表示这是一条**修改器行**（它的 node 是宿主节点）。修改器不参与拖拽落位。
	var modifier_index := -1

	func _get_drag_data(_at: Vector2) -> Variant:
		if node == null or modifier_index >= 0:
			return null
		var preview := Label.new()
		preview.text = "  %s  " % node.display_name()
		set_drag_preview(preview)
		return {"qvox_node": node}

	func _can_drop_data(at: Vector2, data: Variant) -> bool:
		if modifier_index >= 0:
			return false
		if not (data is Dictionary) or not (data as Dictionary).has("qvox_node"):
			return false
		var dragged: QVoxNode = (data as Dictionary)["qvox_node"]
		return section._drop_target(dragged, node, at) != null

	func _drop_data(at: Vector2, data: Variant) -> void:
		var dragged: QVoxNode = (data as Dictionary)["qvox_node"]
		var t: Variant = section._drop_target(dragged, node, at)
		if t is Array and (t as Array).size() == 2:
			section.node_move_requested.emit(dragged, t[0], int(t[1]))
