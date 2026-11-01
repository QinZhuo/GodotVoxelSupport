@tool
class_name QVoxelierPalette
extends QVoxelierPanel
## 左侧**调色板列** —— 竖排材质色块，像工具栏一样**贯通上下、常驻最左**。
## 【为什么改成竖排常驻】色块是高频切换的东西，竖着排一列比横在底部更顺手（鼠标/手指移动距离短），
## 也让底部腾出来给动画帧条；一列到底、可滚动，色多也不挤。
## 【颜色本身就是内容】块面取自材质而不是主题色。选中靠一圈加粗描边（见 QVoxelUi.swatch）——
## 用变色表示选中会让"这个色块代表什么颜色"失真。
## 【与热键同源】数字键 1..8 与点击色块走的是同一个状态（App 的 _material_id），
## 由 App 两边都调用 set_current() 回写。

signal material_selected(material_id: int)
## 新建一个材质（列顶的 ＋）。
signal add_material_requested

var _scroll: ScrollContainer
var _col: VBoxContainer
var _add: Button
var _group := ButtonGroup.new()
var _swatches := {}         # material_id → Button
var _sig := PackedStringArray()


func _build() -> void:
	# 贴窗口左缘、上下贯通 —— 这一列**自己就是**左侧栏，外面不再套底板。
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(0.0, QVoxelUi.bar_height())

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
			QVoxelUi.side_panel(SIDE_LEFT, QVoxelUi.space_m(), QVoxelUi.space_s()))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var vb := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	panel.add_child(vb)

	_scroll = QVoxelUi.scroll(true)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_scroll)

	_col = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_col)

	# 新建材质按钮：排在**最后一个色块下面**（跟着色块一起滚动），而不是钉在列底。
	_add = QVoxelUi.icon_button("＋", "新建材质", QVoxelUi.hit_size())
	_add.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_add.pressed.connect(func(): add_material_requested.emit())
	_col.add_child(_add)

	get_viewport().size_changed.connect(_resize)
	_resize()


## 高度贯通上下：从顶栏下沿到底部帧条上沿。整宽含两侧内边距（见 QVoxelUi.side_width）。
func _resize() -> void:
	var h := (get_viewport_rect().size.y - position.y - QVoxelUi.status_height()
			- QVoxelUi.strip_height())
	size = Vector2(QVoxelUi.side_width(QVoxelUi.palette_width()), maxf(h, 120.0))


# 对外：状态同步（只由 App 调用）

## 重建色板。colors 的下标即材质 ID（0 位是空气占位，跳过）。颜色序列没变就直接返回。
func set_palette(colors: Array[Color]) -> void:
	var sig := PackedStringArray()
	for c in colors:
		sig.append(c.to_html(true))
	if sig == _sig:
		return
	_sig = sig

	for c in _col.get_children():
		if c == _add:
			continue
		_col.remove_child(c)
		c.queue_free()
	_swatches.clear()

	for id in range(1, colors.size()):
		var b := QVoxelUi.swatch(colors[id], "材质 %d · %s" % [id, colors[id].to_html(false)],
				QVoxelUi.hit_size())
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.button_group = _group
		var captured := id
		b.toggled.connect(func(on: bool): if on: material_selected.emit(captured))
		_swatches[id] = b
		_col.add_child(b)
	# 新建按钮永远排在最后一个色块之后（已在树上 → 用 move_child，不能再 add_child）。
	if _add.get_parent() == _col:
		_col.move_child(_add, _col.get_child_count() - 1)
	else:
		_col.add_child(_add)


## 单个色块就地换色（实时改色时用）。
func set_color(material_id: int, color: Color) -> void:
	var b: Button = _swatches.get(material_id)
	if b == null:
		return
	QVoxelUi.paint_swatch(b, color)
	b.tooltip_text = "材质 %d · %s" % [material_id, color.to_html(false)]
	if material_id < _sig.size():
		_sig[material_id] = color.to_html(true)


## 高亮当前材质（点击与数字键共用同一条回写路径）。
func set_current(material_id: int) -> void:
	for id in _swatches:
		var b: Button = _swatches[id]
		b.set_pressed_no_signal(id == material_id)
	_scroll_into_view(material_id)


func _scroll_into_view(material_id: int) -> void:
	if not _swatches.has(material_id) or _scroll == null:
		return
	var b: Button = _swatches[material_id]
	await get_tree().process_frame
	if is_instance_valid(b) and is_instance_valid(_scroll):
		_scroll.ensure_control_visible(b)
