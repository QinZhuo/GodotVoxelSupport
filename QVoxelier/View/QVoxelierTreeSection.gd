@tool
class_name QVoxelierTreeSection
extends QVoxelierSection
## 统一层级树 —— **唯一的层级入口**（纯 Outliner，不含动画轴）。
## 【为什么只有一个面板】组 / 模型是同一棵树上的两种行，一切关系一眼可见、随手可改。
## 【树视图是模型的纯投影】落位只改 QVoxelWorld.nodes，然后整棵重建。行控件是"投影出来的像素"。
## 【为什么自绘而不是 Godot 的 Tree】Tree 自带整套滚选 / 焦点语义，行内只能放"单元格 + 图标 + 按钮"，
## 且触摸命中区不达标；自绘则每行都是**整行按钮**，行内可放任意控件。
## 【为什么本面板只发信号、不直接改数据】改动要能撤销，而撤销命令属于应用层
## （QVoxelPropertyCommand）。面板只报告"用户想做什么"，由 App 决定怎么记。
## 【动画帧编辑不在这里】最下方另有一条独立的「动画帧条」（QVoxelierTimeline）只显示当前模型的体素帧。

## 选中某个节点（模型用于切换当前编辑对象；组用于后续"整组操作"）。
signal node_selected(node: QVoxelNode)
signal model_add_requested(parent: QVoxelGroup)
signal group_add_requested(parent: QVoxelGroup)
signal node_remove_requested(node: QVoxelNode)
signal node_visible_changed(node: QVoxelNode, value: bool)
signal node_locked_changed(node: QVoxelNode, value: bool)
signal node_rename_requested(node: QVoxelNode, new_name: String)
## 双击行 → 请求在属性面板里开始改名（聚焦名字输入框）。
signal rename_begin_requested(node: QVoxelNode)
signal node_move_requested(node: QVoxelNode, parent: QVoxelGroup, index: int)

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
	var add := QVoxelUi.button("＋", "新建：组 / 模型", &"", "add")
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


## "＋" 菜单：新建组 / 新建模型。
func _popup_add(anchor: Control) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_icon_item(QVoxelUi.icon("group"), "新建组", 0)
	menu.add_icon_item(QVoxelUi.icon("model"), "新建模型", 1)
	menu.id_pressed.connect(_on_add_menu.bind(anchor))
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(anchor.global_position), Vector2i(anchor.size)))


func _on_add_menu(id: int, _anchor: Control) -> void:
	match id:
		0:
			group_add_requested.emit(_target_parent())
		1:
			model_add_requested.emit(_target_parent())


## 行右键菜单：删除节点（改名在右侧「对象」属性页里做）。
func _row_context(node: QVoxelNode) -> void:
	_selected = node
	_del.disabled = false
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_icon_item(QVoxelUi.icon("del"), "删除节点", 2)
	menu.id_pressed.connect(func(_id: int) -> void: node_remove_requested.emit(node))
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))


func set_world(world: QVoxelWorld, active_id := -1) -> void:
	# 只在**换了世界**时清选中；同一世界的刷新（改名 / 移动 / 撤销）要保住选中高亮。
	if world != _world:
		_selected = null
	_world = world
	_active_id = active_id
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


func _make_row(node: QVoxelNode, depth: int) -> Control:
	var is_active := _is_active(node)
	var is_sel := node == _selected
	var row := TreeRow.new()
	row.node = node
	row.section = self
	row.depth = depth
	row.custom_minimum_size.y = QVoxelUi.hit_size()
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = _row_tooltip(node)
	row.add_theme_color_override("font_color", QVoxelUi.ACCENT if (is_active or is_sel) else QVoxelUi.TEXT)
	# 选中 / 活动行给一层强调底（默认 Button 样式看不出选中，名字又只是子 Label）。
	if is_active or is_sel:
		var sb := _row_style()
		row.add_theme_stylebox_override("normal", sb)
		row.add_theme_stylebox_override("hover", sb)
		row.add_theme_stylebox_override("pressed", sb)
	row.pressed.connect(func():
		_selected = node
		_del.disabled = false
		node_selected.emit(node)
		_rebuild())

	var box := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 铺满整行（左缩进随层级），名字才有整行宽度可显示，不会被挤没。
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 8 + depth * INDENT
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

	# 名字用 Label（点整行 = 选中；改名在右侧「对象」属性页里做）。活动 / 选中行名字用强调色。
	var name_label := QVoxelUi.label(node.display_name(), QVoxelUi.FONT_M,
			QVoxelUi.ACCENT if (is_active or is_sel) else QVoxelUi.TEXT)
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
	lines.append("位置 %d, %d, %d" % [node.offset.x, node.offset.y, node.offset.z])
	return "\n".join(lines)


func _errors_of(_node: QVoxelNode) -> int:
	return 0


func _is_active(node: QVoxelNode) -> bool:
	return node.is_model() and (node as QVoxelModel).model_id == _active_id


## 选中 / 活动行的强调底。
func _row_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(QVoxelUi.ACCENT.r, QVoxelUi.ACCENT.g, QVoxelUi.ACCENT.b, 0.22)
	sb.set_corner_radius_all(4)
	return sb


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

	func _get_drag_data(_at: Vector2) -> Variant:
		if node == null:
			return null
		var preview := Label.new()
		preview.text = "  %s  " % node.display_name()
		set_drag_preview(preview)
		return {"qvoxel_node": node}

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton) or not event.pressed or node == null:
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			section._row_context(node)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			# 双击 = 开始改名（在属性面板里聚焦名字输入框）。
			section.rename_begin_requested.emit(node)
			accept_event()

	func _can_drop_data(at: Vector2, data: Variant) -> bool:
		if not (data is Dictionary) or not (data as Dictionary).has("qvoxel_node"):
			return false
		var dragged: QVoxelNode = (data as Dictionary)["qvoxel_node"]
		return section._drop_target(dragged, node, at) != null

	func _drop_data(at: Vector2, data: Variant) -> void:
		var dragged: QVoxelNode = (data as Dictionary)["qvoxel_node"]
		var t: Variant = section._drop_target(dragged, node, at)
		if t is Array and (t as Array).size() == 2:
			section.node_move_requested.emit(dragged, t[0], int(t[1]))
