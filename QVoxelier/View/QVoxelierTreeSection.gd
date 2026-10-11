@tool
class_name QVoxelierTreeSection
extends QVoxelierSection
## 统一层级树 —— **唯一的层级入口**（纯 Outliner，不含动画轴）。
## 【为什么只有一个面板】组 / 模型 / 修改器是同一棵树上的三种行，一切关系一眼可见、随手可改。
## 【树视图是模型的纯投影】落位只改 QVoxelWorld.nodes，然后整棵重建。行控件是"投影出来的像素"。
## 【为什么自绘而不是 Godot 的 Tree】Tree 自带整套滚选 / 焦点语义，行内只能放"单元格 + 图标 + 按钮"，
## 且触摸命中区不达标；自绘则每行都是**整行按钮**，行内可放任意控件。
## 【为什么本面板只发信号、不直接改数据】改动要能撤销，而撤销命令属于应用层
## （QVoxelPropertyCommand）。面板只报告"用户想做什么"，由 App 决定怎么记。
## 【动画帧编辑不在这里】最下方另有一条独立的「动画帧条」（QVoxelierTimeline）只显示当前模型的帧。

## 选中某个节点（模型用于切换当前编辑对象；组用于后续"整组操作"）。
signal node_selected(node: QVoxelNode)
signal model_add_requested(parent: QVoxelGroup)
signal group_add_requested(parent: QVoxelGroup)
signal node_remove_requested(node: QVoxelNode)
signal node_visible_changed(node: QVoxelNode, value: bool)
signal node_locked_changed(node: QVoxelNode, value: bool)
signal node_rename_requested(node: QVoxelNode, new_name: String)
signal node_move_requested(node: QVoxelNode, parent: QVoxelGroup, index: int)
signal modifier_add_requested(node: QVoxelNode, kind: String)
signal modifier_remove_requested(node: QVoxelNode, index: int)
signal modifier_enabled_changed(node: QVoxelNode, index: int, value: bool)
signal modifier_selected(node: QVoxelNode, index: int)

const INDENT := 14

var _world: QVoxelWorld
var _active_id := -1
var _rows: VBoxContainer
var _hint: Label
var _del: Button
var _selected: QVoxelNode
var _filter := ""


func section_title() -> String:
	return "层级"


func _build_body(body: VBoxContainer) -> void:
	var tools := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(tools)
	# 新建 / 删除：纯图标按钮（＋菜单 / 垃圾桶）。
	var add := QVoxelUi.button("＋", "新建：组 / 模型，或给选中节点挂修改器", &"", "add")
	add.pressed.connect(_popup_add.bind(add))
	tools.add_child(add)
	_del = QVoxelUi.button("×", "删除选中的节点（连同它下面的全部内容）", &"", "del")
	_del.disabled = true
	_del.pressed.connect(func():
		if _selected != null:
			node_remove_requested.emit(_selected))
	tools.add_child(_del)

	# 搜索框：按名字过滤层级（组按子树匹配）。
	var search := QVoxelUi.text_field("", "搜索节点…", "按名字过滤层级")
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(t: String) -> void:
		_filter = t.strip_edges().to_lower()
		_rebuild())
	tools.add_child(search)

	_hint = QVoxelUi.label("", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT)
	body.add_child(_hint)

	_rows = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	body.add_child(_rows)


## "＋" 菜单：把 新建组 / 新建模型 / 挂修改器 合并到一个入口。
func _popup_add(anchor: Control) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_icon_item(QVoxelUi.icon("group"), "新建组", 0)
	menu.add_icon_item(QVoxelUi.icon("model"), "新建模型", 1)
	menu.add_icon_item(QVoxelUi.icon("modifier"), "给选中节点挂修改器", 2)
	menu.id_pressed.connect(_on_add_menu.bind(anchor))
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(anchor.global_position), Vector2i(anchor.size)))


func _on_add_menu(id: int, anchor: Control) -> void:
	match id:
		0:
			group_add_requested.emit(_target_parent())
		1:
			model_add_requested.emit(_target_parent())
		2:
			_popup_modifier_kinds.call_deferred(anchor)


## 行右键菜单：挂修改器 / 删除（改名已在行内输入框，无需再列）。
func _row_context(node: QVoxelNode) -> void:
	_selected = node
	_del.disabled = false
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_icon_item(QVoxelUi.icon("modifier"), "挂修改器…", 1)
	menu.add_icon_item(QVoxelUi.icon("del"), "删除节点", 2)
	menu.id_pressed.connect(_on_context_menu.bind(node))
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))


func _on_context_menu(id: int, node: QVoxelNode) -> void:
	match id:
		1:
			_popup_modifier_kinds.call_deferred(self)
		2:
			node_remove_requested.emit(node)


func set_world(world: QVoxelWorld, active_id := -1) -> void:
	_world = world
	_active_id = active_id
	_selected = null
	_rebuild()


func set_active(active_id: int) -> void:
	_active_id = active_id
	_rebuild()


func refresh() -> void:
	_rebuild()


# 投影

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
		_hint.text = "空世界：点「＋」新建模型开始"
	else:
		_hint.text = "%d 个顶层节点 · 共 %d 个模型" % [total, _world.all_models().size()]
	for n in _world.nodes:
		if n != null and _visible_in_filter(n):
			_add_rows(n, 0)
	_measure()


## 搜索过滤：名字命中即显示；组还看子树。
func _visible_in_filter(node: QVoxelNode) -> bool:
	if _filter.is_empty():
		return true
	if node.display_name().to_lower().contains(_filter):
		return true
	if node.is_group():
		for c in (node as QVoxelGroup).child_nodes:
			if c != null and _visible_in_filter(c):
				return true
	return false


func _add_rows(node: QVoxelNode, depth: int) -> void:
	_rows.add_child(_make_row(node, depth))
	if node.is_group() and not node.expanded_in_tree:
		return
	if node.is_group():
		for c in (node as QVoxelGroup).child_nodes:
			if c != null:
				_add_rows(c, depth + 1)
	var errors := _chain_errors_by_modifier(node)
	for i in node.modifiers.size():
		var m: QVoxelModifier = node.modifiers[i]
		_rows.add_child(_make_modifier_row(node, i, depth + 1, errors.get(m, [])))


## 一条修改器行：旁通开关 / 显示名 / 域徽标 / 错误红标 / 移除。点整行 = 选中它去改参数。
func _make_modifier_row(node: QVoxelNode, index: int, depth: int, errors: Array = []) -> Control:
	var m: QVoxelModifier = node.modifiers[index]
	var row := TreeRow.new()
	row.node = node
	row.modifier_index = index
	row.section = self
	row.depth = depth
	row.custom_minimum_size.y = QVoxelUi.hit_size()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = _modifier_tooltip(node, index, m, errors)
	row.add_theme_color_override("font_color", QVoxelUi.TEXT_DIM)
	row.pressed.connect(func(): modifier_selected.emit(node, index))

	var box := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(8 + depth * INDENT, 0)
	row.add_child(box)

	var on := QVoxelUi.toggle_button("旁通 / 启用这条修改器")
	on.button_pressed = m.enabled
	on.icon = QVoxelUi.icon("dot_on" if m.enabled else "dot_off")
	on.toggled.connect(func(v: bool):
		on.icon = QVoxelUi.icon("dot_on" if v else "dot_off")
		modifier_enabled_changed.emit(node, index, v))
	box.add_child(on)

	var text := "· %s" % m.display_name()
	if not m.enabled:
		text += "（旁通）"
	var name_label := QVoxelUi.label(text, QVoxelUi.FONT_S,
			QVoxelUi.TEXT if m.enabled else QVoxelUi.TEXT_FAINT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(name_label)

	box.add_child(QVoxelUi.label(QVoxelDomain.KIND_NAMES[m.domain()],
			QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))

	if not errors.is_empty():
		var msgs := PackedStringArray()
		for e in errors:
			msgs.append(String(e["message"]))
		var warn := TextureRect.new()
		warn.texture = QVoxelUi.icon("warn")
		warn.custom_minimum_size = Vector2(15, 15)
		warn.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		warn.tooltip_text = "\n".join(msgs)
		warn.mouse_filter = Control.MOUSE_FILTER_PASS
		box.add_child(warn)

	var rm := QVoxelUi.icon_button("×", "从链上移除这条修改器")
	rm.pressed.connect(func(): modifier_remove_requested.emit(node, index))
	box.add_child(rm)
	return row


func _modifier_tooltip(node: QVoxelNode, index: int, m: QVoxelModifier, errors: Array = []) -> String:
	var lines := PackedStringArray()
	lines.append("%s · 第 %d 条" % [m.display_name(), index + 1])
	lines.append("种类 %s · 合成 %d" % [m.kind(), int(m.combine)])
	if not m.enabled:
		lines.append("已旁通（不参与求值）")
	var seen := {}
	for e in errors:
		seen[String(e["message"])] = true
		lines.append("· %s" % e["message"])
	for e in QVoxelDomain.chain_errors([m]):
		var msg := String(e["message"])
		if not seen.has(msg):
			lines.append("· %s" % msg)
	return "\n".join(lines)


## 弹"挂哪种修改器"菜单。条目来自 QVoxelModifier.KINDS。
func _popup_modifier_kinds(anchor: Control) -> void:
	if _selected == null:
		_hint.text = "先在树上点一个节点，再挂修改器"
		return
	var menu := PopupMenu.new()
	add_child(menu)
	for i in QVoxelModifier.KINDS.size():
		menu.add_icon_item(QVoxelUi.icon("modifier"), QVoxelModifier.KIND_NAMES[i], i)
	menu.id_pressed.connect(func(id: int) -> void:
		modifier_add_requested.emit(_selected, QVoxelModifier.KINDS[id]))
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(anchor.global_position), Vector2i(anchor.size)))


func _make_row(node: QVoxelNode, depth: int) -> Control:
	var row := TreeRow.new()
	row.node = node
	row.section = self
	row.depth = depth
	row.custom_minimum_size.y = QVoxelUi.hit_size()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = _row_tooltip(node)
	row.add_theme_color_override("font_color", QVoxelUi.ACCENT if _is_active(node) else QVoxelUi.TEXT)
	row.pressed.connect(func():
		_selected = node
		_del.disabled = false
		node_selected.emit(node)
		_rebuild())

	var box := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position = Vector2(8 + depth * INDENT, 0)
	row.add_child(box)

	if node.is_group():
		var arrow := QVoxelUi.icon_button("", "展开 / 收起这一组", QVoxelUi.hit_size() - 6)
		arrow.icon = QVoxelUi.icon("caret_down" if node.expanded_in_tree else "caret_right")
		arrow.pressed.connect(func():
			node.expanded_in_tree = not node.expanded_in_tree
			_rebuild())
		box.add_child(arrow)

	var vis := QVoxelUi.toggle_button("显示 / 隐藏")
	vis.button_pressed = node.visible
	vis.icon = QVoxelUi.icon("eye" if node.visible else "eye_off")
	vis.toggled.connect(func(v):
		vis.icon = QVoxelUi.icon("eye" if v else "eye_off")
		node_visible_changed.emit(node, v))
	box.add_child(vis)
	var lock := QVoxelUi.toggle_button("锁定（锁上后整棵子树不可编辑）")
	lock.button_pressed = node.locked
	lock.icon = QVoxelUi.icon("lock" if node.locked else "lock_open")
	lock.toggled.connect(func(v):
		lock.icon = QVoxelUi.icon("lock" if v else "lock_open")
		node_locked_changed.emit(node, v))
	box.add_child(lock)

	# 名字用 Label（点整行 = 选中；改名在右侧「对象」属性页里做）。
	var name_label := QVoxelUi.label(node.display_name(), QVoxelUi.FONT_M, QVoxelUi.TEXT)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(name_label)

	var badge := _badge_of(node)
	if not badge.is_empty():
		box.add_child(QVoxelUi.label(badge, QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))

	var errs := _errors_of(node)
	if errs > 0:
		var warn := TextureRect.new()
		warn.texture = QVoxelUi.icon("warn")
		warn.custom_minimum_size = Vector2(15, 15)
		warn.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		warn.tooltip_text = _row_tooltip(node)
		warn.mouse_filter = Control.MOUSE_FILTER_PASS
		box.add_child(warn)
		if errs > 1:
			box.add_child(QVoxelUi.label(str(errs), QVoxelUi.FONT_S, QVoxelUi.WARN))

	return row


func _badge_of(node: QVoxelNode) -> String:
	if node.is_model():
		return "%d 体素" % (node as QVoxelModel).count_solid()
	return "%d 模型" % (node as QVoxelGroup).count_models()


func _row_tooltip(node: QVoxelNode) -> String:
	var lines := PackedStringArray()
	lines.append(node.display_name())
	if node.is_model():
		var g := (node as QVoxelModel).grid_size
		lines.append("模型 %d · %d×%d×%d" % [(node as QVoxelModel).model_id, g.x, g.y, g.z])
	else:
		lines.append("组 · %d 个模型" % (node as QVoxelGroup).count_models())
	var chain := node.active_modifiers()
	if not chain.is_empty():
		lines.append("修改器 %d 条" % chain.size())
		for e in QVoxelDomain.chain_errors(chain):
			lines.append("· %s" % e["message"])
	return "\n".join(lines)


func _errors_of(node: QVoxelNode) -> int:
	var n := _chain_errors_by_modifier(node).size()
	if node.is_group():
		for c in (node as QVoxelGroup).child_nodes:
			if c != null:
				n += _errors_of(c)
	return n


func _chain_errors_by_modifier(node: QVoxelNode) -> Dictionary:
	var chain := node.active_modifiers()
	var out := {}
	for e in QVoxelDomain.chain_errors(chain):
		var i := int(e["index"])
		if i < 0 or i >= chain.size():
			continue
		var m: QVoxelModifier = chain[i]
		if not out.has(m):
			out[m] = []
		(out[m] as Array).append(e)
	return out


func _is_active(node: QVoxelNode) -> bool:
	return node.is_model() and (node as QVoxelModel).model_id == _active_id


func _target_parent() -> QVoxelGroup:
	if _selected != null and _selected.is_group():
		return _selected as QVoxelGroup
	return null


# 拖拽落位

## 把 dragged 落到 hovered 上，返回 [parent, index]；不合法返回 null。
func _drop_target(dragged: QVoxelNode, hovered: QVoxelNode, at: Vector2) -> Variant:
	if dragged == null or hovered == null or dragged == hovered:
		return null
	var h := float(QVoxelUi.hit_size())
	if hovered.is_group() and at.y >= h / 3.0 and at.y <= h * 2.0 / 3.0:
		if dragged == hovered:
			return null
		return [hovered, -1]
	var parent := _world.find_parent(hovered)
	var idx := _world.node_index(hovered)
	if idx < 0:
		return null
	if parent == null and not _world.nodes.has(hovered):
		return null
	return [parent, idx + (1 if at.y > h / 2.0 else 0)]


## 一行。继承 Button 是为了拿到拖拽三个虚方法；右键弹行菜单。
class TreeRow extends Button:
	var node: QVoxelNode
	var section: QVoxelierTreeSection
	var depth := 0
	var modifier_index := -1

	func _get_drag_data(_at: Vector2) -> Variant:
		if node == null or modifier_index >= 0:
			return null
		var preview := Label.new()
		preview.text = "  %s  " % node.display_name()
		set_drag_preview(preview)
		return {"qvoxel_node": node}

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton) or not event.pressed or modifier_index >= 0 or node == null:
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			section._row_context(node)
			accept_event()

	func _can_drop_data(at: Vector2, data: Variant) -> bool:
		if modifier_index >= 0:
			return false
		if not (data is Dictionary) or not (data as Dictionary).has("qvoxel_node"):
			return false
		var dragged: QVoxelNode = (data as Dictionary)["qvoxel_node"]
		return section._drop_target(dragged, node, at) != null

	func _drop_data(at: Vector2, data: Variant) -> void:
		var dragged: QVoxelNode = (data as Dictionary)["qvoxel_node"]
		var t: Variant = section._drop_target(dragged, node, at)
		if t is Array and (t as Array).size() == 2:
			section.node_move_requested.emit(dragged, t[0], int(t[1]))
