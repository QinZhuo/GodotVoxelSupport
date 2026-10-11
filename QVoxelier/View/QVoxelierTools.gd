@tool
class_name QVoxelierTools
extends QVoxelierPanel
## 左侧**图标工具栏** —— 竖排一列纯图标按钮，**没有统一的背景底**（每个按钮自带圆角底），
## 直接浮在视口上（Blender 左侧工具架的观感）。
## 【为什么只有图标】竖排一列放不下文字；名字与热键交给悬浮提示，纯图标更紧凑、更像专业工具。
## 【为什么没有统一背景】一列独立按钮比"一整块深色板"更轻、更不占视线；选中态由按钮自己的
## 强调底表达（触摸没有 hover，选中必须常驻可见）。
## 【工具列表从哪来】直接读 [QVoxelBrushTool.MODES]（表即配置）：加一种笔只需在表里加一行。

## 选中了某个工具：笔刷模式（值同 QVoxelBrushTool.Mode）或生成/风化（见 TOOL_* 常量）。
signal tool_selected(mode: int)

## 自定义笔刷 = 把自己做好的模型当图章盖。它是"工具"而非笔刷模式，故用独立 id。
const TOOL_CUSTOM := 100

var _scroll: ScrollContainer
var _col: VBoxContainer
var _buttons := {}          # Mode → Button
var _group := ButtonGroup.new()
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

	# 自定义笔刷：与笔类并列（互斥选中）—— 拿一个做好的模型当图章盖，同样是"点哪画哪"。
	_col.add_child(QVoxelUi.divider())
	var cb := QVoxelUi.toggle_button(
			"自定义笔刷\n把复制出的体素当笔刷：先框选并复制，再点击盖章（支持添加 / 移除 / 上色）",
			QVoxelUi.VARIATION_TOOL, "笔刷", "brush")
	cb.custom_minimum_size = Vector2(0, QVoxelUi.hit_size())
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cb.button_group = _group
	cb.toggled.connect(func(on: bool): if on: tool_selected.emit(TOOL_CUSTOM))
	_buttons[TOOL_CUSTOM] = cb
	_col.add_child(cb)

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
