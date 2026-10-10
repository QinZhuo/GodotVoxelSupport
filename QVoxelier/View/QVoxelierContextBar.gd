@tool
class_name QVoxelierContextBar
extends QVoxelierPanel
## 顶栏正下方的**上下文选项条**（PS 的选项条 / Blender 的 header）：只显示**当前工具**用得到的选项。
## 【为什么单独一条】把笔刷尺寸 / 形态 / 擦除 / 对称 / 选区动作常驻在左侧，等于让每个用户一直
## 看着他此刻用不上的东西；移到"随工具变化的一条"里，左侧就只剩"选哪个工具"一件事。
## 【仍然全部是可见按钮】与全应用一致：快捷键只是加速器，按钮才是入口（触摸屏没有键盘）。
## 【表即配置】工具与形态两组选项直接读 [QVoxelBrushTool] 的 MODES / SHAPES，
## 与左列工具条、状态栏提示同源 —— 加一种笔只改表，本条的显隐与文案一起跟着变。

## 笔刷尺寸加减（delta = ±1）。
signal brush_step(delta: int)
## 笔刷尺寸乘除（up = true 表示 ×2）。
signal brush_scale_requested(up: bool)
## 笔刷截面形态（值同 [enum QVoxelBrushTool.Shape]）。
signal brush_shape_selected(shape: int)
## 对称轴开关：axis 0 / 1 / 2 = X / Y / Z。
signal symmetry_toggled(axis: int, on: bool)
## 选区 / 剪贴板动作请求（值 = [constant SELECT_ACTIONS] 里的 id）。
signal selection_action(action: StringName)

## 选区动作表（表即配置，与左侧工具表同一套路数）。选中「选择 / 移动」时本行取代笔刷参数。
const SELECT_ACTIONS := [
	{"id": &"all", "text": "全选", "icon": "select_all", "key": "Ctrl+A", "tip": "选中整个网格"},
	{"id": &"copy", "text": "复制", "icon": "copy", "key": "Ctrl+C", "tip": "复制选区里的体素"},
	{"id": &"cut", "text": "剪切", "icon": "cut", "key": "Ctrl+X", "tip": "剪下选区里的体素"},
	{"id": &"paste", "text": "粘贴", "icon": "paste", "key": "Ctrl+V", "tip": "把剪贴板贴到光标处"},
	{"id": &"clear", "text": "清空", "icon": "clear", "key": "Delete", "tip": "挖掉选区里的体素"},
]

var _row: HBoxContainer
var _brush_group: HBoxContainer
var _shape_group: HBoxContainer
var _sym_group: HBoxContainer
var _select_group: HBoxContainer
var _brush_value: Label
var _brush_minus: Button
var _brush_plus: Button
var _brush_half: Button
var _brush_dbl: Button
var _shape_buttons: Array[Button] = []
var _sym: Array[Button] = []
var _select_buttons := {}   # id → Button
var _left_inset := 0.0
var _right_inset := 0.0


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_top = QVoxelUi.bar_height()
	offset_bottom = offset_top + _bar_height()

	# 与左侧工具栏同一种风格：**没有统一背景底**，一排独立按钮直接浮在视口上。
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
			QVoxelUi.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, QVoxelUi.space_s(), QVoxelUi.space_s()))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	_row = QVoxelUi.hbox(QVoxelUi.space_m())
	_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	panel.add_child(_row)

	_build_brush_group()
	_row.add_child(QVoxelUi.vdivider())
	_build_shape_group()
	_row.add_child(QVoxelUi.vdivider())
	_build_symmetry_group()
	_row.add_child(QVoxelUi.vdivider())
	_build_selection_group()
	_sync_rect()


func _bar_height() -> float:
	return QVoxelUi.hit_size() + QVoxelUi.space_s() * 2.0


## 笔刷尺寸：− 值 + （细调）+ ×2 / ÷2（粗调）。与左列旧版同一套，只是横排。
func _build_brush_group() -> void:
	_brush_group = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_row.add_child(_brush_group)

	_brush_minus = QVoxelUi.icon_button("−", "调小笔刷（[ 或 -）")
	_brush_minus.pressed.connect(func(): brush_step.emit(-1))
	_brush_group.add_child(_brush_minus)

	_brush_value = QVoxelUi.label("1", QVoxelUi.FONT_TITLE, QVoxelUi.TEXT)
	_brush_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_brush_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_brush_value.custom_minimum_size.x = 30
	_brush_group.add_child(_brush_value)

	_brush_plus = QVoxelUi.icon_button("+", "调大笔刷（] 或 =）")
	_brush_plus.pressed.connect(func(): brush_step.emit(1))
	_brush_group.add_child(_brush_plus)

	_brush_dbl = QVoxelUi.button("2X", "笔刷尺寸翻倍")
	_brush_dbl.focus_mode = Control.FOCUS_NONE
	_brush_dbl.pressed.connect(func(): brush_scale_requested.emit(true))
	_brush_group.add_child(_brush_dbl)

	_brush_half = QVoxelUi.button("1÷2", "笔刷尺寸减半")
	_brush_half.pressed.connect(func(): brush_scale_requested.emit(false))
	_brush_group.add_child(_brush_half)


## 笔刷截面形态（球 / 平面）。读 [constant QVoxelBrushTool.SHAPES]。
func _build_shape_group() -> void:
	_shape_group = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_row.add_child(_shape_group)
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for entry in QVoxelBrushTool.SHAPES:
		var b := QVoxelUi.toggle_button("%s\n%s" % [entry.text, entry.tip],
				QVoxelUi.VARIATION_TOOL, entry.text, entry.icon)
		b.custom_minimum_size.x = QVoxelUi.hit_size()
		b.button_group = group
		b.toggled.connect(_on_shape_toggled.bind(int(entry.shape)))
		_shape_buttons.append(b)
		_shape_group.add_child(b)


## 对称轴 X / Y / Z（对一切写体素的工具生效）。
func _build_symmetry_group() -> void:
	_sym_group = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_row.add_child(_sym_group)
	for i in 3:
		var axis := String.chr("X".unicode_at(0) + i)
		var b := QVoxelUi.toggle_button("沿 %s 轴镜像：画一笔，网格对侧同步出现" % axis)
		b.text = axis
		b.custom_minimum_size.x = QVoxelUi.hit_size()
		# bind 而不是闭包捕获 i：三个按钮各连各的轴，不会一起变成 Z。
		b.toggled.connect(_on_sym_toggled.bind(i))
		_sym.append(b)
		_sym_group.add_child(b)


func _build_selection_group() -> void:
	_select_group = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_row.add_child(_select_group)
	for row in SELECT_ACTIONS:
		var b := QVoxelUi.button(String(row.text),
				"%s（%s）\n%s" % [row.text, row.key, row.tip], &"", row.icon)
		# bind 而不是闭包捕获：每个按钮各钉各的 id，不会一起变成最后一个。
		b.pressed.connect(_on_select_action.bind(row.id))
		_select_buttons[row.id] = b
		_select_group.add_child(b)


func _on_shape_toggled(on: bool, shape: int) -> void:
	if on:
		brush_shape_selected.emit(shape)


func _on_sym_toggled(on: bool, axis: int) -> void:
	symmetry_toggled.emit(axis, on)


func _on_select_action(id: StringName) -> void:
	selection_action.emit(id)


# 位置（左右让开两侧栏）

## 本条横跨"左列右缘 → 右列左缘"的可见区。两侧宽度由 App 报进来（内容驱动，不是常量）。
func set_insets(left: float, right: float) -> void:
	if is_equal_approx(left, _left_inset) and is_equal_approx(right, _right_inset):
		return
	_left_inset = left
	_right_inset = right
	_sync_rect()


func _sync_rect() -> void:
	offset_left = _left_inset
	offset_right = -_right_inset


# 对外：状态同步（只由 App 调用）

## 切工具 → 换一套选项。selection_mode（选择 / 移动）显示选区动作；其笔画工具显示笔刷参数。
func set_tool(mode: int, supports_brush: bool, selection_mode: bool) -> void:
	_brush_group.visible = supports_brush
	_shape_group.visible = supports_brush
	_sym_group.visible = not selection_mode
	_select_group.visible = selection_mode


## 刷新笔刷显示；supported = false 时整组置灰（面笔 / 填充不吃笔刷）。
func set_brush(size: int, supported: bool) -> void:
	_brush_value.text = str(size)
	_brush_value.add_theme_color_override("font_color",
			QVoxelUi.TEXT if supported else QVoxelUi.TEXT_FAINT)
	_brush_minus.disabled = not supported or size <= 1
	_brush_plus.disabled = not supported
	_brush_half.disabled = not supported or size <= 1
	_brush_dbl.disabled = not supported


## 回写形态（App 在切对象 / 撤销后调用；no_signal 避免回环）。
func set_brush_shape(shape: int, supported: bool) -> void:
	for i in QVoxelBrushTool.SHAPES.size():
		if i >= _shape_buttons.size():
			break
		var b := _shape_buttons[i]
		if int(QVoxelBrushTool.SHAPES[i].shape) == shape:
			b.set_pressed_no_signal(true)
		b.disabled = not supported


## 回写对称轴状态（App 在切对象 / 撤销后调用；no_signal 避免回环）。
func set_symmetry(mask: Vector3i) -> void:
	var flags := [mask.x, mask.y, mask.z]
	for i in 3:
		if i < _sym.size():
			_sym[i].set_pressed_no_signal(flags[i] != 0)


## 回写选区 / 剪贴板的可用性（置灰而不是隐藏，位置固定）。
func set_selection_state(has_selection: bool, has_clipboard: bool) -> void:
	_set_action_enabled(&"all", true)
	_set_action_enabled(&"copy", has_selection)
	_set_action_enabled(&"cut", has_selection)
	_set_action_enabled(&"paste", has_clipboard)
	_set_action_enabled(&"clear", has_selection)


static func select_actions() -> Array:
	return SELECT_ACTIONS


func _set_action_enabled(id: StringName, on: bool) -> void:
	var b: Button = _select_buttons.get(id)
	if b != null:
		b.disabled = not on
