@tool
class_name QVoxelierTreeSection
extends QVoxelierSection
## 统一层级树 —— **唯一的层级入口**。
## 【为什么只有一个面板】以前层级被拆成三处：对象面板（谁存在）、图层面板（谁和谁一组、
## 可见 / 锁定）、变换面板（摆在哪）。同一件事被切成三份，于是"删层要记得搬 layer"、
## "隐藏对象其实隐藏的是它那层"这类跨面板的隐性耦合到处滋生。现在组 / 模型 / 修改器
## 是**同一棵树上的三种行**，一切关系一眼可见、随手可改。
## 【树视图是模型的纯投影】落位只改 QVoxelWorld.nodes，然后整棵重建。
## 绝不在行控件上做增删 —— 行控件是"投影出来的像素"，不是数据。
## 【为什么自绘而不是 Godot 的 Tree】Tree 自带整套滚选 / 焦点语义，行内只能放
## "单元格 + 图标 + 按钮"，且触摸命中区不达标（见 QVoxelUi 密度档的说明）。
## 自绘则每行都是**整行按钮**，行内可放任意控件。
## 【为什么本面板只发信号、不直接改数据】改动要能撤销，而撤销命令属于应用层
## （QVoxelPropertyCommand）。面板只报告"用户想做什么"，由 App 决定怎么记。

## 选中某个节点（模型用于切换当前编辑对象；组用于后续"整组操作"）。
signal node_selected(node: QVoxelNode)
## 在 parent 下新建模型 / 组（parent 为 null = 顶层）。
signal model_add_requested(parent: QVoxelGroup)
signal group_add_requested(parent: QVoxelGroup)
## 删除节点（连同子树）。
signal node_remove_requested(node: QVoxelNode)
## 可见性 / 锁定 / 改名。
signal node_visible_changed(node: QVoxelNode, value: bool)
signal node_locked_changed(node: QVoxelNode, value: bool)
signal node_rename_requested(node: QVoxelNode, new_name: String)
## 拖拽落位：把 node 挂到 parent 下的 index（parent 为 null = 顶层）。
signal node_move_requested(node: QVoxelNode, parent: QVoxelGroup, index: int)
## 在某节点的链上追加一条修改器（kind 取 QVoxelModifier.KINDS）。
signal modifier_add_requested(node: QVoxelNode, kind: String)
## 从某节点的链上移除第 index 条修改器。
signal modifier_remove_requested(node: QVoxelNode, index: int)
## 旁通 / 启用某节点链上的第 index 条修改器。
signal modifier_enabled_changed(node: QVoxelNode, index: int, value: bool)
## 选中某节点链上的第 index 条修改器（供参数分组显示）。
signal modifier_selected(node: QVoxelNode, index: int)
## 动画轴展开 / 收起（App 据此显示 / 隐藏时间轴附板）。
signal anim_expanded_changed(expanded: bool)
## 在动画轴里点了某模型的某一帧（App 切到该模型并设活动帧）。
signal frame_selected(node: QVoxelNode, frame: int)

const INDENT := 14

var _world: QVoxelWorld
var _active_id := -1
var _rows: VBoxContainer
var _hint: Label
var _del: Button
var _selected: QVoxelNode
## 动画轴是否展开。展开时每个模型行在名字后横向铺开帧格子（Aseprite 的图层×帧网格思路）。
var _anim_expanded := false
## 搜索过滤词（小写）。空 = 不过滤。
var _filter := ""
## 全局帧数 = 各模型帧数的最大值（各行的帧格子据此对齐）。
var _frames := 1


func section_title() -> String:
	return "层级"


func _build_body(body: VBoxContainer) -> void:
	var tools := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(tools)
	# 新建 / 删除 / 动画轴：合并成三个纯图标按钮（＋菜单 / 垃圾桶 / 胶片）。
	var add := QVoxelUi.button("＋", "新建：组 / 模型，或给选中节点挂修改器", &"", "add")
	add.pressed.connect(_popup_add.bind(add))
	tools.add_child(add)
	_del = QVoxelUi.button("×", "删除选中的节点（连同它下面的全部内容）", &"", "del")
	_del.disabled = true
	_del.pressed.connect(func():
		if _selected != null:
			node_remove_requested.emit(_selected))
	tools.add_child(_del)
	var anim := QVoxelUi.toggle_button(
			"动画轴\n展开：每个节点一行，横向铺开帧，直接点格子切帧（普通建模时可关掉）",
			QVoxelUi.VARIATION_TOOL, "", "anim")
	anim.set_pressed_no_signal(_anim_expanded)
	anim.toggled.connect(func(on: bool) -> void:
		_anim_expanded = on
		anim_expanded_changed.emit(on)
		reset_measure()
		_rebuild())
	tools.add_child(anim)

	# 搜索框：按名字过滤层级（组按子树匹配 —— 能顺着组名找到里面的模型）。
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


## "＋" 菜单：把 新建组 / 新建模型 / 挂修改器 合并到一个入口（减少顶栏一排文字按钮）。
func _popup_add(anchor: Control) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("新建组", 0)
	menu.add_item("新建模型", 1)
	menu.add_item("给选中节点挂修改器", 2)
	menu.id_pressed.connect(_on_add_menu.bind(anchor))
	menu.popup_closed.connect(func() -> void: menu.queue_free())
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
	menu.add_item("挂修改器…", 1)
	menu.add_item("删除节点", 2)
	menu.id_pressed.connect(_on_context_menu.bind(node))
	menu.popup_closed.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))


func _on_context_menu(id: int, node: QVoxelNode) -> void:
	match id:
		1:
			_popup_modifier_kinds.call_deferred(self)
		2:
			node_remove_requested.emit(node)


## 挂上世界。**每次换世界都要调**（新建 / 打开工程）。
func set_world(world: QVoxelWorld, active_id := -1) -> void:
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
	# 全局帧数（各行帧格子据此对齐）。
	_frames = 1
	for m in _world.all_models():
		if m != null:
			_frames = maxi(_frames, m.frame_count())
	for n in _world.nodes:
		if n != null and _visible_in_filter(n):
			_add_rows(n, 0)
	# 行内容变了（尤其动画轴展开后带帧格子）→ 重报内容宽度，右列才会跟着变宽。
	_measure()


## 搜索过滤：名字命中即显示；组还看子树（能顺着组名找到里面的模型）。
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
	# 折叠的组：子树与它自己的链都藏起来（眼不见即"这组现在不参与"）。
	if node.is_group() and not node.expanded_in_tree:
		return
	if node.is_group():
		for c in (node as QVoxelGroup).child_nodes:
			if c != null:
				_add_rows(c, depth + 1)
	# 链是节点的**一部分**（见 QVoxelNode），故紧跟在它的子树之后、再缩进一级显示。
	# 链错误按**实例**归属一次算好，行控件只负责显示（见 _chain_errors_by_modifier）。
	var errors := _chain_errors_by_modifier(node)
	for i in node.modifiers.size():
		var m: QVoxelModifier = node.modifiers[i]
		_rows.add_child(_make_modifier_row(node, i, depth + 1, errors.get(m, [])))


## 一条修改器行：旁通开关 / 显示名 / 域徽标 / 错误红标 / 移除。点整行 = 选中它去改参数。
## 【为什么修改器要成为树上的行，而不是另开一个面板】链是节点的属性，"哪条链属于谁"必须
## 一眼可见；另开面板就要维护"当前看的是谁的链"这份额外的选中状态。成为行之后，选中状态
## 就是行本身，增删改都落在同一棵树里（"万物皆修改器"在 UI 上的对应物）。
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

	# 旁通开关：不删条目、只是不参与求值（与 Blender 的修改器眼睛同义）。
	var on := QVoxelUi.toggle_button("旁通 / 启用这条修改器")
	on.button_pressed = m.enabled
	on.text = "◉" if m.enabled else "○"
	on.toggled.connect(func(v: bool):
		on.text = "◉" if v else "○"
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

	# 域徽标（§3.1）：这条修改器吃 / 吐哪种数据形态。域决定"改这个参数会不会重排输出盒"，
	# 是用户预判代价的唯一线索 —— 只写在 tooltip 里等于没有。
	box.add_child(QVoxelUi.label(QVoxelDomain.KIND_NAMES[m.domain()],
			QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))

	# 错误红标（§3.1）：**打在有错的那一条上**，而不是等到求值崩 —— 域序号回升这类
	# "设计错误"一定有明确的人为原因（链被拖错了位置），在求值前就该被看见。
	# 旁通项不在生效链里、不产出错误，故不打标（见 _chain_errors_by_modifier）。
	if not errors.is_empty():
		var msgs := PackedStringArray()
		for e in errors:
			msgs.append(String(e["message"]))
		var warn := QVoxelUi.label("⚠", QVoxelUi.FONT_S, QVoxelUi.WARN)
		warn.tooltip_text = "\n".join(msgs)
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
	# 生效链里的错误（含"域序号回升"这类只有放回链里才看得出的问题）。
	var seen := {}
	for e in errors:
		seen[String(e["message"])] = true
		lines.append("· %s" % e["message"])
	# 条目自身的问题：旁通时它不在生效链里，上面那段看不到，这里补上（按消息去重）。
	for e in QVoxelDomain.chain_errors([m]):
		var msg := String(e["message"])
		if not seen.has(msg):
			lines.append("· %s" % msg)
	return "\n".join(lines)


## 弹"挂哪种修改器"菜单。条目直接来自 QVoxelModifier.KINDS —— 将来加一种域就自动多一项。
func _popup_modifier_kinds(anchor: Control) -> void:
	if _selected == null:
		_hint.text = "先在树上点一个节点，再挂修改器"
		return
	var menu := PopupMenu.new()
	add_child(menu)
	for i in QVoxelModifier.KINDS.size():
		menu.add_item(QVoxelModifier.KIND_NAMES[i], i)
	menu.id_pressed.connect(func(id: int) -> void:
		modifier_add_requested.emit(_selected, QVoxelModifier.KINDS[id]))
	menu.popup_closed.connect(func() -> void: menu.queue_free())
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

	# 展开箭头（只有组有）。
	if node.is_group():
		var arrow := QVoxelUi.label("▾" if node.expanded_in_tree else "▸", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
		box.add_child(arrow)

	# 可见性 / 锁定：**每行都有**（组上就是"隐藏整组"）。
	var vis := QVoxelUi.toggle_button("显示 / 隐藏")
	vis.button_pressed = node.visible
	vis.text = "👁"
	vis.toggled.connect(func(v): node_visible_changed.emit(node, v))
	box.add_child(vis)
	var lock := QVoxelUi.toggle_button("锁定（锁上后整棵子树不可编辑）")
	lock.button_pressed = node.locked
	lock.text = "🔒"
	lock.toggled.connect(func(v): node_locked_changed.emit(node, v))
	box.add_child(lock)

	# 名字（双击改名走 LineEdit —— 触摸没有 hover，改名必须是显式动作）。
	var name_edit := LineEdit.new()
	name_edit.text = node.display_name()
	name_edit.flat = true
	name_edit.custom_minimum_size.x = 96
	# 动画轴展开时名字定宽（各行的帧格子才能横向对齐）；否则撑满。
	name_edit.size_flags_horizontal = (Control.SIZE_SHRINK_BEGIN if _anim_expanded
			else Control.SIZE_EXPAND_FILL)
	if _anim_expanded:
		name_edit.custom_minimum_size.x = 88
	name_edit.text_submitted.connect(func(t):
		if t != node.display_name():
			node_rename_requested.emit(node, t))
	box.add_child(name_edit)

	# 动画轴：每个模型一行，名字后横向铺开帧格子（Aseprite 的图层×帧网格）。
	if _anim_expanded and node.is_model():
		box.add_child(_frame_strip(node as QVoxelModel))
		return row

	# 类型 / 内容徽标。
	var badge := _badge_of(node)
	if not badge.is_empty():
		box.add_child(QVoxelUi.label(badge, QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))

	# 链校验徽标（出问题的那一行打红标，而不是等到求值崩）。
	var errs := _errors_of(node)
	if errs > 0:
		var warn := QVoxelUi.label("⚠%d" % errs, QVoxelUi.FONT_S, QVoxelUi.WARN)
		warn.tooltip_text = _row_tooltip(node)
		box.add_child(warn)

	return row


## 动画轴：某模型行的帧格子条（横向滚动，宽度封顶以免把右列撑宽）。
func _frame_strip(m: QVoxelModel) -> Control:
	var sc := QVoxelUi.scroll(false, QVoxelUi.hit_size())
	sc.custom_minimum_size = Vector2(132, QVoxelUi.hit_size())
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	var h := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sc.add_child(h)
	for f in _frames:
		h.add_child(_frame_cell(m, f))
	return sc


## 一个帧格子：实心点 = 该帧有内容、空心 = 空帧；按下态 = 当前正在编辑的帧。点它即切帧。
func _frame_cell(m: QVoxelModel, f: int) -> Button:
	var exists := f < maxi(m.frame_count(), 1)
	var b := QVoxelUi.toggle_button("", QVoxelUi.VARIATION_TOOL, "")
	b.custom_minimum_size = Vector2(18, QVoxelUi.hit_size() - 12)
	b.disabled = not exists
	if not exists:
		return b
	var filled := _frame_has(m, f)
	b.text = "●" if filled else "○"
	b.button_pressed = f == m.active_frame
	b.tooltip_text = "第 %d 帧%s" % [f + 1, "" if filled else "（空）"]
	b.toggled.connect(func(on: bool) -> void:
		if on:
			frame_selected.emit(m, f))
	return b


## 该帧是否有内容（静态模型看手绘块，动画模型看那一帧的块表）。
func _frame_has(m: QVoxelModel, f: int) -> bool:
	if not m.is_animated():
		return m.count_solid() > 0
	var fr := m.frame_at(f)
	return fr != null and not fr.is_empty()


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
	# 摆放不在这里回显：它已是链上的一条（平移），下面"修改器 N 条"里就看得见。
	var chain := node.active_modifiers()
	if not chain.is_empty():
		lines.append("修改器 %d 条" % chain.size())
		for e in QVoxelDomain.chain_errors(chain):
			lines.append("· %s" % e["message"])
	return "\n".join(lines)


## 本节点（含子树）里有问题的**修改器条数**。组行汇总子树 —— 折叠着也能看见"这组里有问题"。
## 【为什么数条数而不是数错误条】节点行的 ⚠N 与修改器行的红标是同一件事的两种粒度：
## 用户看到 N 个红标，父行就该是 ⚠N。数"错误条数"会让一条修改器犯两个错时对不上号。
func _errors_of(node: QVoxelNode) -> int:
	var n := _chain_errors_by_modifier(node).size()
	if node.is_group():
		for c in (node as QVoxelGroup).child_nodes:
			if c != null:
				n += _errors_of(c)
	return n


## 把链校验结果按**修改器实例**归属，返回 {QVoxelModifier: Array[错误]}。
## 【为什么必须按实例而不是按下标】`chain_errors()` 的 index 指向**传入数组**里的位置，
## 而树遍历的是全量 `node.modifiers` —— 旁通项会被 `active_modifiers()` 滤掉，于是
## "第 i 条"在两条路径上根本不是同一条（拿下标去标红，标错行）。实例是唯一稳定的归属键。
## 【为什么只用生效链】旁通项不参与求值，也就不产生错误；拿它标红是假警报。
## 它自身的问题（如重排算子配了「平滑并」）仍会在 tooltip 里说明 —— 见 _modifier_tooltip。
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


## 新建时的落点：选中的组就放进它，否则放顶层。
func _target_parent() -> QVoxelGroup:
	if _selected != null and _selected.is_group():
		return _selected as QVoxelGroup
	return null


# 拖拽落位（三个 Control 虚方法的实现体在 TreeRow 里）

## 把 dragged 落到 hovered 上，返回 [parent, index]；不合法返回 null。
## 【为什么"上 / 中 / 下三段"要自己算】因为不是 Godot 的 Tree（见类头），
## 也就没有 get_drop_section_at_position() 可借，只有自己按行高切三段。
func _drop_target(dragged: QVoxelNode, hovered: QVoxelNode, at: Vector2) -> Variant:
	if dragged == null or hovered == null or dragged == hovered:
		return null
	var h := float(QVoxelUi.hit_size())
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
	var node: QVoxelNode
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
		return {"qvoxel_node": node}

	func _gui_input(event: InputEvent) -> void:
		# 右键 = 行上下文菜单（挂修改器 / 删除）。修改器行不弹（它只有"移除"，行尾已有 ×）。
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_RIGHT and modifier_index < 0 and node != null:
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
