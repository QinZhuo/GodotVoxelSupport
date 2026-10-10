@tool
class_name QVoxelierTools
extends QVoxelierPanel
## 左侧**图标工具栏** —— 竖排一列纯图标按钮，**没有统一的背景底**（每个按钮自带圆角底），
## 直接浮在视口上（Blender 左侧工具架的观感）。
## 【为什么只有图标】竖排一列放不下文字；名字与热键交给悬浮提示，纯图标更紧凑、更像专业工具。
## 【为什么没有统一背景】一列独立按钮比"一整块深色板"更轻、更不占视线；选中态由按钮自己的
## 强调底表达（触摸没有 hover，选中必须常驻可见）。
## 【工具列表从哪来】直接读 [QVoxelBrushTool.MODES]（表即配置）：加一种笔只需在表里加一行。

## 选中了某个画笔模式（值同 QVoxelBrushTool.Mode）。
signal tool_selected(mode: int)
## 擦除开关（粘性）：与右键、Shift+左键的反向同源。
signal erase_toggled(enabled: bool)

var _scroll: ScrollContainer
var _col: VBoxContainer
var _buttons := {}          # Mode → Button
var _group := ButtonGroup.new()
var _erase: Button
## 底部让位高度（动画面板展开时）。
var bottom_reserved := 0.0


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(QVoxelUi.space_m(), QVoxelUi.bar_height() + QVoxelUi.space_m())
	size.x = _width()

	_scroll = QVoxelUi.scroll(true)
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)

	_col = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_col)
	_col.resized.connect(_fit)
	get_viewport().size_changed.connect(_fit)

	_group.allow_unpress = false
	var drawn_divider := false
	for row in QVoxelBrushTool.MODES:
		# 绘制类与选择类之间插一条分隔线（选择 / 移动是"框选"而非"落笔"，分开放更好读）。
		if not drawn_divider and QVoxelBrushTool.is_selection_mode(row.mode):
			_col.add_child(QVoxelUi.divider())
			drawn_divider = true
		var tip := "%s（%s）\n%s" % [row.label, String.chr(row.hotkey), row.hint]
		var b := _icon_toggle(tip, row.icon)
		b.button_group = _group
		b.toggled.connect(func(on: bool): if on: tool_selected.emit(row.mode))
		_buttons[row.mode] = b
		_col.add_child(b)

	_col.add_child(QVoxelUi.divider())
	_erase = _icon_toggle("擦除（E）\n画的时候挖掉体素（右键 / Shift+左键的反向）", "erase")
	_erase.toggled.connect(func(on: bool): erase_toggled.emit(on))
	_col.add_child(_erase)
	_fit()


## 一个纯图标开关按钮：方形命中区、图标居中、名字与热键走 tooltip。
func _icon_toggle(tooltip: String, icon_name: String) -> Button:
	var b := QVoxelUi.toggle_button(tooltip, QVoxelUi.VARIATION_TOOL, "", icon_name)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _width() -> float:
	return float(QVoxelUi.hit_size() + QVoxelUi.space_s() * 2)


## 矩形 = 图标列宽 × min(内容高, 可用高)。
func _fit() -> void:
	if _col == null:
		return
	var inner := _col.get_combined_minimum_size()
	_scroll.custom_minimum_size.y = maxf(0.0, minf(inner.y, _available_height()))
	size = Vector2(_width(), _scroll.custom_minimum_size.y)


## 本面板能占的最高高度：视口高 − 顶边位置 − 底部状态栏 − 底部让位 − 一点边距。
func _available_height() -> float:
	return (get_viewport_rect().size.y - position.y - QVoxelUi.status_height()
			- QVoxelUi.space_s() - bottom_reserved)


## 底部让位（动画面板高度）。
func set_bottom_reserved(h: float) -> void:
	if is_equal_approx(h, bottom_reserved):
		return
	bottom_reserved = h
	_fit()


# 对外：状态同步（只由 App 调用）

## 高亮当前工具（no_signal 避免"App 设界面、界面又通知 App"的回环）。
func set_tool(mode: int) -> void:
	var b: Button = _buttons.get(mode)
	if b != null:
		b.set_pressed_no_signal(true)


func set_erase(on: bool) -> void:
	if _erase != null:
		_erase.set_pressed_no_signal(on)


func erase_mode() -> bool:
	return _erase != null and _erase.button_pressed
