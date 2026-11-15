@tool
## 默认表现: 一条圆角气泡 + 富文本 + 左侧插槽竖排。
## 项目想要别的样子 → 继承 `DialogueView`（或本类只覆盖 `_build_view` / `_apply_style`）。
class_name BubbleView extends DialogueView

@export var style: StyleBox
@export var font_size := 20
@export var font_color := Color(1, 1, 1, 1)
## 宽度上限(像素)。屏幕装不下时会自动收窄。
@export var max_width := 1200.0
@export var min_height := 0.0
## 内容内边距 left/top/right/bottom
@export var padding := Vector4(22.0, 14.0, 22.0, 14.0)

var panel: Panel
var label: RichTextLabel

var _slots := {}
var _text := ""
var _key := []


func _ready() -> void:
	super._ready()
	_build_view()


func _build_view() -> void:
	panel = Panel.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	label = RichTextLabel.new()
	label.name = "Label"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.bbcode_enabled = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	_apply_style()


func _apply_style() -> void:
	if panel == null:
		return
	var box := style
	if box == null and has_theme_stylebox("panel", "DialogueBubble"):
		box = get_theme_stylebox("panel", "DialogueBubble")
	if box == null:
		var flat := StyleBoxFlat.new()
		flat.bg_color = Color(0.09, 0.1, 0.12, 0.94)
		flat.set_corner_radius_all(10)
		box = flat
	panel.add_theme_stylebox_override("panel", box)
	# 主题可覆盖字号/字体(项目一般把它放在自己的 theme 里)
	if has_theme_font_size("font_size", "DialogueBubble"):
		font_size = get_theme_font_size("font_size", "DialogueBubble")
	if label:
		label.add_theme_font_size_override("normal_font_size", font_size)
		if has_theme_font("font", "DialogueBubble"):
			label.add_theme_font_override("normal_font", get_theme_font("font", "DialogueBubble"))
		label.add_theme_color_override("default_color", font_color)


func present(line: DialogueLineDef, text: String) -> void:
	var content := text
	if content.is_empty() and line:
		content = line.display_text()
	set_text(content)


func set_text(text: String) -> void:
	_text = text
	if label:
		label.text = text  # 真正把文案写进控件
	var show_it := not text.is_empty()
	if show_it and not visible:
		visible = true
		shown.emit()
	elif not show_it and visible:
		dismissed.emit()
		visible = false
	_key = []
	refresh()


func get_text() -> String:
	return _text


func dismiss() -> void:
	set_text("")


func attach_slot(slot_name: StringName, node: Control, size: Vector2) -> void:
	if node == null:
		return
	# 挂到**面板内**(跟着气泡走)。挂到 view 自身的话坐标是全屏的, 插槽会跑到屏幕左上角。
	var host: Control = panel if panel else self
	if node.get_parent() == null:
		host.add_child(node)
	elif node.get_parent() != host:
		node.reparent(host)
	_slots[slot_name] = {"node": node, "size": size}
	refresh()


func detach_slot(slot_name: StringName) -> void:
	if _slots.erase(slot_name):
		refresh()


func refresh() -> void:
	if not visible or label == null:
		return
	var view := view_size()
	if view.x <= 0.0:
		return
	var key := [view, _text, anchor(), max_width, min_height, padding, _slot_height()]
	if key == _key:
		return
	_key = key

	var pad_l := padding.x
	var pad_t := padding.y
	var pad_r := padding.z
	var pad_b := padding.w
	var slot_w := _slot_width()

	var limit_w := minf(view.x - 24.0, max_width)
	var pad_w := pad_l + pad_r + slot_w

	## 第一遍: 按上限宽度排版, 量出文案真实需要多宽(短句不要撑成整条)
	label.size = Vector2(maxf(limit_w - pad_w, 1.0), 0.0)
	var width := clampf(label.get_content_width() + pad_w, 240.0, limit_w)

	## 第二遍: 用最终宽度重新排版, 拿高度
	label.size = Vector2(maxf(width - pad_w, 1.0), 0.0)
	var height := maxf(label.get_content_height(), _slot_height()) + pad_t + pad_b
	height = maxf(height, min_height)

	## 高度封顶: 超出可用高度时改为内部滚动, 不再顶出屏幕
	var limit_h := view.y - 24.0
	label.scroll_active = height > limit_h
	height = minf(height, limit_h)

	var panel_size := Vector2(width, height)
	panel.position = place_default(panel_size)
	panel.size = panel_size
	label.position = Vector2(pad_l + slot_w, pad_t)
	label.size = Vector2(maxf(panel_size.x - pad_w, 1.0),
			maxf(panel_size.y - pad_t - pad_b, 1.0))

	var y := pad_t
	for entry in _slots.values():
		var node: Control = entry.node
		if is_instance_valid(node):
			node.position = Vector2(pad_l, y)
			node.size = entry.size
			y += entry.size.y
	if get_parent():
		get_parent().move_child(self, -1)
	placed.emit()


func _slot_width() -> float:
	var total := 0.0
	for entry in _slots.values():
		total = maxf(total, entry.size.x)
	return total + (8.0 if not _slots.is_empty() else 0.0)


func _slot_height() -> float:
	var total := 0.0
	for entry in _slots.values():
		total += entry.size.y
	return total
