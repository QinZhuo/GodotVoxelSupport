@tool
class_name QVoxelUi
extends RefCounted
## QVoxelier 界面的设计规范（design token）与控件工厂 —— **所有面板长相的唯一来源**。

# 设计令牌（design token）

## 面板底（半透明：浮在 3D 视口上仍能看出下面有东西，但不会晃眼）。
const SURFACE := Color("#1a1d22f0")
## 不透明面板底（对话框、需要盖住内容的场合）。
const SURFACE_SOLID := Color("#1a1d22ff")
## 底层（应用栏 / 状态栏，比面板再深一档，形成层次而不是靠描边区分）。
const BAR := Color("#0e1013eb")
## 控件默认底。
const SURFACE_HI := Color("#262b32ff")
## 悬停底（鼠标专属，故只是锦上添花）。
const SURFACE_HOVER := Color("#30363eff")
## 按下 / 选中底。
const SURFACE_ACTIVE := Color("#3a414bff")

const BORDER := Color(1.0, 1.0, 1.0, 0.08)
const BORDER_STRONG := Color(1.0, 1.0, 1.0, 0.18)

## 正文。
const TEXT := Color("#edeff3ff")
const TEXT_DIM := Color("#9aa1acff")
## 提示 / 占位 / 禁用文字。
const TEXT_FAINT := Color("#7c838eff")

## 唯一强调色（蓝）。
const ACCENT := Color("#4f86c2ff")
## 强调色的低透明度底（选中态背景 / 主操作按钮的常态底）。
const ACCENT_DIM := Color("#4f86c229")
## 主操作按钮的悬停底（比常态略实一档）。
const ACCENT_HOVER := Color("#4f86c24d")
## 铺在强调色上的文字色（深色，保证对比度）。
const ON_ACCENT := Color("#0e1013ff")
## 危险 / 警告。
const WARN := Color("#e8584eff")

# 圆角：Blender 那类专业工具偏"方"（很浅的圆角），过圆会显得像消费级 App。
const RADIUS_S := 5
const RADIUS_M := 8

## 间距最小一档。
const SPACE_XS := 4

# 字号阶：整体比"网页习惯"大一档。
const FONT_S := 12
const FONT_M := 13
const FONT_L := 14
const FONT_TITLE := 16

## type_variation 名：主操作按钮（保存、确认），强调色实心。
const VARIATION_ACCENT := &"AccentButton"
## type_variation 名：工具按钮（互斥选中），选中态用强调色描边 + 强调色底。
const VARIATION_TOOL := &"ToolButton"

static var _theme: Theme = null

## 悬停提示的接收端（App 接到底部状态栏）。
static var hint_sink := Callable()

static func _wire_hint(c: Control) -> void:
	if c.tooltip_text.is_empty():
		return
	c.mouse_entered.connect(func() -> void:
		if hint_sink.is_valid():
			hint_sink.call(c.tooltip_text.get_slice("\n", 0)))
	c.mouse_exited.connect(func() -> void:
		if hint_sink.is_valid():
			hint_sink.call(""))

# 密度档（界面骨架尺寸的唯一来源）

## 是否用桌面紧凑档。
static func compact() -> bool:
	return not OS.has_feature("mobile")

## 最小命中区边长。
static func hit_size() -> int:
	return 32 if compact() else 44

## 顶部应用栏高度。
static func bar_height() -> int:
	return 40 if compact() else 52

## 底部状态栏高度。
static func status_height() -> int:
	return 30 if compact() else 36

## 底部动画帧条高度：**与状态栏同高**，两条并排才是一条整齐的底栏。
static func strip_height() -> int:
	return status_height()

## 左侧调色板列的宽度（竖排色块，像工具栏一样）= 色块 + 两侧各一道缝。
static func palette_width() -> int:
	return hit_size() + space_s() * 2

## 右列的目标宽度（0 = 用默认档）。
static var _dock_w := 0

## 右列（层级 / 属性）的目标宽度。
static func dock_width() -> int:
	if _dock_w > 0:
		return _dock_w
	return 116 if compact() else 132

## 右列宽度的硬上限：再宽画布就没了。
const DOCK_MAX_W := 640

## 拖动条改右列宽度。
static func set_dock_width(w: float, max_w := -1.0) -> void:
	var cap := float(DOCK_MAX_W) if max_w <= 0.0 else minf(max_w, float(DOCK_MAX_W))
	_dock_w = clampi(int(round(w)), 96, int(cap))

## 用户是否亲手调过右列宽度。
static func dock_width_custom() -> bool:
	return _dock_w > 0

## 小间距：同组控件之间、面板内边距。
static func space_s() -> int:
	return 6 if compact() else 8

## 中间距：分组之间、面板外边距。
static func space_m() -> int:
	return 8 if compact() else 12

## 大间距：标题与内容之间这类大块区隔。
static func space_l() -> int:
	return 12 if compact() else 16

# 主题（一次构造，全应用共享）

static func theme() -> Theme:
	if _theme == null:
		_theme = _build_theme()
	return _theme

static func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT_M
	_theme_button(t)
	_theme_label(t)
	_theme_container(t)
	_theme_scrollbar(t)
	_theme_slider(t)
	_theme_line_edit(t)
	_theme_tooltip(t)
	_theme_split(t)
	return t

## 分割容器（`VSplitContainer` / `HSplitContainer`）。
static func _theme_split(t: Theme) -> void:
	# 横向分隔（上下分栏）：一条水平细线，上下各留 5px 抓取余量 —— 看得见也抓得住。
	var hbar := StyleBoxFlat.new()
	hbar.bg_color = Color(0, 0, 0, 0)
	hbar.border_color = BORDER
	hbar.border_width_top = 1
	hbar.border_width_bottom = 1
	hbar.content_margin_top = 5
	hbar.content_margin_bottom = 5
	t.set_stylebox("split_bar_background", "VSplitContainer", hbar)
	t.set_constant("separation", "VSplitContainer", 10)

	# 竖向分隔（左右分栏）：同理，只是换成竖线。
	var vbar := StyleBoxFlat.new()
	vbar.bg_color = Color(0, 0, 0, 0)
	vbar.border_color = BORDER
	vbar.border_width_left = 1
	vbar.border_width_right = 1
	vbar.content_margin_left = 5
	vbar.content_margin_right = 5
	t.set_stylebox("split_bar_background", "HSplitContainer", vbar)
	t.set_constant("separation", "HSplitContainer", 10)

## 按钮：常态 / 悬停 / 按下 / 禁用 / 焦点五态。
static func _theme_button(t: Theme) -> void:
	t.set_stylebox("normal", "Button", box(SURFACE_HI, BORDER, 1, RADIUS_S))
	t.set_stylebox("hover", "Button", box(SURFACE_HOVER, ACCENT, 1, RADIUS_S))
	t.set_stylebox("pressed", "Button", box(SURFACE_ACTIVE, ACCENT, 1, RADIUS_S))
	t.set_stylebox("disabled", "Button", box(SURFACE_HI.darkened(0.3), BORDER, 1, RADIUS_S))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), ACCENT, 1, RADIUS_S))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_font_size("font_size", "Button", FONT_L)
	t.set_constant("h_separation", "Button", space_s())

	# 主操作：强调色 tonal（低透明底 + 强调字 + 强调描边），只在"按下"那一瞬给实心。
	t.set_type_variation(VARIATION_ACCENT, "Button")
	t.set_stylebox("normal", VARIATION_ACCENT, box(ACCENT_DIM, ACCENT, 1, RADIUS_S))
	t.set_stylebox("hover", VARIATION_ACCENT, box(ACCENT_HOVER, ACCENT, 1, RADIUS_S))
	t.set_stylebox("pressed", VARIATION_ACCENT, box(ACCENT, ACCENT, 0, RADIUS_S))
	t.set_color("font_color", VARIATION_ACCENT, ACCENT)
	t.set_color("font_hover_color", VARIATION_ACCENT, Color.WHITE)
	t.set_color("font_pressed_color", VARIATION_ACCENT, ON_ACCENT)

	# 工具按钮：常态继承 Button，只改写"选中"（toggle 按下）—— 触摸下这是唯一的选中线索。
	t.set_type_variation(VARIATION_TOOL, "Button")
	t.set_stylebox("pressed", VARIATION_TOOL, box(ACCENT_DIM, ACCENT, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_stylebox("hover", VARIATION_TOOL, box(SURFACE_HOVER, BORDER_STRONG, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_stylebox("normal", VARIATION_TOOL, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, RADIUS_S, space_s(), SPACE_XS))
	t.set_color("font_pressed_color", VARIATION_TOOL, ACCENT)
	t.set_font_size("font_size", VARIATION_TOOL, FONT_L)

static func _theme_label(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FONT_M)

static func _theme_container(t: Theme) -> void:
	t.set_stylebox("panel", "PanelContainer", box(SURFACE, BORDER, 1, RADIUS_M, space_m(), space_m()))
	t.set_stylebox("separator", "HSeparator", line(BORDER))
	t.set_stylebox("separator", "VSeparator", vline(BORDER))
	t.set_stylebox("panel", "Panel", box(BAR, BORDER, 0, 0, space_s(), SPACE_XS))
	t.set_constant("separation", "VBoxContainer", space_s())
	t.set_constant("separation", "HBoxContainer", space_s())
	t.set_constant("separation", "GridContainer", SPACE_XS)

## 滚动条：调色板材质多时会出现。
static func _theme_scrollbar(t: Theme) -> void:
	for type in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", type, box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber", type, box(Color(1, 1, 1, 0.16), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber_highlight", type, box(ACCENT_DIM, ACCENT, 1, 4, 0, 0))
		t.set_stylebox("grabber_pressed", type, box(ACCENT, Color(0, 0, 0, 0), 0, 4, 0, 0))

## 滑条：颜色分组的 RGBA 通道用它。
static func _theme_slider(t: Theme) -> void:
	for type in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", type, box(SURFACE_HI, BORDER, 1, 4, 0, 0))
		t.set_stylebox("grabber_area", type, box(ACCENT_DIM, Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber_area_highlight", type, box(ACCENT, Color(0, 0, 0, 0), 0, 4, 0, 0))

## 单行文本输入：时间轴分组的标签编辑用它。
static func _theme_line_edit(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", box(SURFACE_HI, BORDER, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_stylebox("focus", "LineEdit", box(SURFACE_HI, ACCENT, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_stylebox("read_only", "LineEdit", box(SURFACE_HI.darkened(0.3), BORDER, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_FAINT)
	t.set_color("font_uneditable_color", "LineEdit", TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", ACCENT_DIM)
	t.set_font_size("font_size", "LineEdit", FONT_M)

## 提示气泡：鼠标的专属福利（触摸看不到），但也给个统一长相。
static func _theme_tooltip(t: Theme) -> void:
	t.set_stylebox("panel", "TooltipPanel", box(Color("#0b0d10fa"), BORDER_STRONG, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FONT_S)

# 样式盒工厂

## 通用圆角矩形：底色 + 描边 + 内边距。
static func box(bg: Color, border := BORDER, border_w := 1, radius := RADIUS_S,
		pad_x := -1, pad_y := -1) -> StyleBoxFlat:
	# 【为什么默认值是 -1 而不是直接写 space_m()】GDScript 的默认参数必须是**编译期常量**，
	var px := space_m() if pad_x < 0 else pad_x
	var py := space_s() if pad_y < 0 else pad_y
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.content_margin_left = px
	sb.content_margin_right = px
	sb.content_margin_top = py
	sb.content_margin_bottom = py
	return sb

static func line(color := BORDER, thickness := 1) -> StyleBoxLine:
	return _style_line(color, thickness, false)

static func vline(color := BORDER, thickness := 1) -> StyleBoxLine:
	return _style_line(color, thickness, true)

static func _style_line(color: Color, thickness: int, vertical: bool) -> StyleBoxLine:
	var sb := StyleBoxLine.new()
	sb.color = color
	sb.thickness = thickness
	sb.vertical = vertical
	return sb

# 控件工厂

static func label(text := "", size := FONT_M, color := TEXT, outlined := false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outlined:
		# 视口底色深浅不定，给压在 3D 上的文字一圈暗描边保证可读
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", 4)
	return l

## 分组小标题：小字号 + 次级色，用于"工具 / 笔刷 / 调色板"这类分区。
static func heading(text: String) -> Label:
	var l := label(text, FONT_S, TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	return l

## 图标目录。
const ICON_DIR := "res://QVoxelier/View/icons/"
static var _icon_cache := {}

## 取图标。
static func icon(name: String) -> Texture2D:
	if _icon_cache.has(name):
		return _icon_cache[name]
	var path := ICON_DIR + name + ".svg"
	var t: Texture2D = load(path) if ResourceLoader.exists(path) else null
	_icon_cache[name] = t
	return t

## 普通按钮。
static func button(text: String, tooltip := "", variation := &"", icon_name := "") -> Button:
	var b := Button.new()
	var glyph := icon(icon_name) if not icon_name.is_empty() else null
	b.text = "" if glyph != null else text
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 键盘焦点一律不要：本应用的键盘归视口（热键），按钮只吃指针。
	b.focus_mode = Control.FOCUS_NONE
	if glyph != null:
		b.icon = glyph
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	if not variation.is_empty():
		b.theme_type_variation = variation
	_wire_hint(b)
	return b

## 纯文字小按钮（撤销、加减号）：定死方形命中区，不随文字长度跳动。
static func icon_button(text: String, tooltip := "", size := -1) -> Button:
	var b := button(text, tooltip)
	var s := hit_size() if size < 0 else size
	b.custom_minimum_size = Vector2(s, s)
	return b

## 互斥选中按钮（工具、材质）：pressed 态即"当前"，触摸下没有 hover 也一眼看得出。
static func toggle_button(tooltip := "", variation := VARIATION_TOOL, text := "", icon_name := "") -> Button:
	var b := button(text, tooltip, variation, icon_name)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, hit_size())
	return b

## 单行文本输入（长相由 _theme_line_edit 统一）。
static func text_field(text := "", placeholder := "", tooltip := "") -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	# 必须可聚焦，否则点进去也打不了字（Tab 导航由 App 在 _input 里统一消费，不靠关焦点实现）。
	e.focus_mode = Control.FOCUS_ALL
	e.caret_blink = true
	e.custom_minimum_size = Vector2(0, hit_size())
	if not tooltip.is_empty():
		e.tooltip_text = tooltip
	_wire_hint(e)
	return e

## 数值滑条（时间轴分组的时长 / 帧率用它）：与颜色通道同一套长相，右侧留出数值位。
static func value_slider(minimum: float, maximum: float, step: float, value: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = minimum
	s.max_value = maximum
	s.step = step
	s.value = value
	s.focus_mode = Control.FOCUS_NONE
	s.custom_minimum_size = Vector2(0, hit_size())
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

## 材质色块：颜色本身就是内容，故底色取自材质，不是主题色。
static func swatch(color: Color, tooltip := "", size := -1) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	var s := hit_size() if size < 0 else size
	b.custom_minimum_size = Vector2(s, s)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	paint_swatch(b, color)
	_wire_hint(b)
	return b

## 把色块画成某个颜色。
static func paint_swatch(b: Button, color: Color) -> void:
	var radius := RADIUS_S
	b.add_theme_stylebox_override("normal", box(color, Color(1, 1, 1, 0.18), 1, radius, 0, 0))
	b.add_theme_stylebox_override("hover", box(color, Color.WHITE, 2, radius, 0, 0))
	var sel := box(color, Color(1, 1, 1) if color.get_luminance() < 0.55 else Color("#0f1115ff"), 3, radius, 0, 0)
	sel.set_expand_margin_all(1.5)
	b.add_theme_stylebox_override("pressed", sel)
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), ACCENT, 3, radius, 0, 0))

static func panel(margin := -1, bg := SURFACE) -> PanelContainer:
	var m := space_m() if margin < 0 else margin
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(bg, BORDER, 1, RADIUS_M, m, m))
	return p

## 侧栏面板（贴窗口左右边、贯通上下的那条长栏）。
static func side_panel(side: Side, pad_y := -1) -> StyleBoxFlat:
	var sb := box(SURFACE_SOLID, BORDER, 0, 0, 0, pad_y)
	sb.set_border_width(SIDE_RIGHT if side == SIDE_LEFT else SIDE_LEFT, 1)
	return sb

static func vbox(sep := -1) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", space_s() if sep < 0 else sep)
	return v

static func hbox(sep := -1) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", space_s() if sep < 0 else sep)
	return h

## 滚动容器：内容超出即滚动，**另一轴不参与布局**。
static func scroll(vertical: bool, height := 0.0) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = (ScrollContainer.SCROLL_MODE_DISABLED if vertical
			else ScrollContainer.SCROLL_MODE_AUTO)
	s.vertical_scroll_mode = (ScrollContainer.SCROLL_MODE_AUTO if vertical
			else ScrollContainer.SCROLL_MODE_DISABLED)
	if height > 0.0:
		s.custom_minimum_size.y = height
	return s

static func divider() -> HSeparator:
	return HSeparator.new()

## 竖分隔：把同一行里的若干组控件隔开（应用栏的 文件 | 历史 | 视图）。
static func vdivider(height := 24) -> VSeparator:
	var s := VSeparator.new()
	s.custom_minimum_size = Vector2(space_l(), height)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return s

## 弹性占位（把同一行里的两组控件推向两端）。
static func spacer() -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c
