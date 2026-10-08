@tool
class_name QVoxUi
extends RefCounted
## QVoxelier 界面的设计规范（design token）与控件工厂 —— **所有面板长相的唯一来源**。
##
## 【为什么要有这一层】界面一旦散着写颜色与字号，三处按钮就会长出三种深浅，
## 加一个面板就得重新猜"上次那个灰是多少"。把色彩 / 间距 / 圆角 / 字号 / 命中区
## 收成常量，再由主题（Theme）与工厂函数统一分发，新面板只描述**结构**，不描述**长相**。
##
## 【为什么是 Theme 而不是逐个 override】Theme 是 Godot 原生的分发机制：构造一次、
## 挂到面板上，其下所有 Button / Label / PanelContainer 自动获得同一套样式，新增控件
## 不必记得"再 override 一遍"。差异态（主操作按钮）用 type_variation 表达 ——
## 与默认按钮共享底色，只覆盖不同项，于是"改一处基调 = 全应用一起变"。
##
## 【为什么所有命中区都 ≥ 44】同一套设计要同时喂给平板（手指，无 hover / 无右键 /
## 无中键 / 无键盘）与桌面（鼠标）。44 是触摸可点、鼠标也不显笨重的公认下限，
## 所以它是基线而不是"触摸设备才放大"的分支 —— 一套尺寸，处处可用。
## 由此推出三条硬约定，写新控件时照做：
##   ① 状态**不能只靠 hover 表达**（触摸没有悬停）—— 选中态必须是常驻可见的底色变化；
##   ② 每个操作都要有**可见按钮**，快捷键只是加速器而不是唯一入口；
##   ③ 图标不可用时用文字/字母徽标（本项目的工具按钮用热键字母当徽标，顺带自解释）。
##
## 【约定失效的唯一一处】引擎自建的 FileDialog / AcceptDialog 内部按钮（保存/取消）实测
## 50×34，不到 44。**试过修且修不动**：给 get_ok_button() 写 custom_minimum_size 会在下一帧
## 被引擎抹回 (0,0)，扫全树（含内部子节点）改写同样无效 —— 所以别再加"补救"代码，
## 那是死路。本文件工厂出的控件全部达标；要彻底解决只能自绘文件面板（成本远超收益）。
##
## 【只读共享】theme() 返回同一个实例给所有面板 —— 省得每人各建一份。调用方
## **不得在运行时改它**（要改请改本文件的常量），否则会串味到其它面板。

# ----------------------------------------------------------------------------
# 设计令牌（design token）
# ----------------------------------------------------------------------------
# 基调：深空冷调专业工具。长时间注视的底（低饱和深灰蓝）+ 单一冷色强调（窄色相）。
# 强调色只有一个 —— 界面上任何"当前选中/可交互"的暗示都用它，颜色本身即是信息。

## 面板底（半透明：浮在 3D 视口上仍能看出下面有东西，但不会晃眼）。
const SURFACE := Color(0.0706, 0.0863, 0.1137, 0.94)
## 不透明面板底（对话框、需要盖住内容的场合）。
const SURFACE_SOLID := Color(0.0706, 0.0863, 0.1137, 1.0)
## 底层（应用栏 / 状态栏，比面板再深一档，形成层次而不是靠描边区分）。
const BAR := Color(0.0431, 0.0549, 0.0745, 0.92)
## 控件默认底。
const SURFACE_HI := Color(0.1098, 0.1333, 0.1765, 1.0)
## 悬停底（鼠标专属，故只是锦上添花）。
const SURFACE_HOVER := Color(0.1451, 0.1765, 0.2235, 1.0)
## 按下 / 选中底。
const SURFACE_ACTIVE := Color(0.1765, 0.2157, 0.2706, 1.0)

const BORDER := Color(1.0, 1.0, 1.0, 0.08)
const BORDER_STRONG := Color(1.0, 1.0, 1.0, 0.18)

const TEXT := Color(0.9098, 0.9255, 0.9529, 1.0)
const TEXT_DIM := Color(0.5961, 0.6353, 0.7020, 1.0)
const TEXT_FAINT := Color(0.4196, 0.4549, 0.5098, 1.0)

## 唯一强调色。
const ACCENT := Color(0.4353, 0.8275, 1.0, 1.0)
## 强调色的低透明度底（选中态背景）。
const ACCENT_DIM := Color(0.4353, 0.8275, 1.0, 0.16)
## 铺在强调色上的文字色（深色，保证对比度）。
const ON_ACCENT := Color(0.0431, 0.0784, 0.1098, 1.0)
const WARN := Color(1.0, 0.5412, 0.4471, 1.0)
const OK := Color(0.4196, 0.8902, 0.6275, 1.0)

const RADIUS_S := 6
const RADIUS_M := 10

const SPACE_XS := 4
const SPACE_S := 8
const SPACE_M := 12
const SPACE_L := 16

const FONT_S := 11
const FONT_M := 12
const FONT_L := 13
const FONT_TITLE := 15

## 最小命中区边长（触摸可点 / 鼠标不笨重的共同下限）。见类文档第 3 段。
const MIN_TOUCH := 44
## 扁平小按钮（撤销、加减号这类成组出现的）边长 —— 仍不低于 MIN_TOUCH。
const ICON_SIZE := MIN_TOUCH
## 顶部应用栏 / 底部状态栏高度。
const BAR_HEIGHT := 52
const STATUS_HEIGHT := 30

## type_variation 名：主操作按钮（保存、确认），强调色实心。
const VARIATION_ACCENT := &"AccentButton"
## type_variation 名：工具按钮（互斥选中），选中态用强调色描边 + 强调色底。
const VARIATION_TOOL := &"ToolButton"

static var _theme: Theme = null


# ----------------------------------------------------------------------------
# 主题（一次构造，全应用共享）
# ----------------------------------------------------------------------------

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
	_theme_tooltip(t)
	return t


## 按钮：常态 / 悬停 / 按下 / 禁用 / 焦点五态。**键盘焦点框刻意不做醒目**（本应用
## 的按钮一律 FOCUS_NONE，键盘归视口），只留一条细描边以防将来接入手柄导航。
static func _theme_button(t: Theme) -> void:
	t.set_stylebox("normal", "Button", box(SURFACE_HI, BORDER, 1, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("hover", "Button", box(SURFACE_HOVER, ACCENT, 1, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("pressed", "Button", box(SURFACE_ACTIVE, ACCENT, 1, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("disabled", "Button", box(SURFACE_HI.darkened(0.3), BORDER, 1, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), ACCENT, 1, RADIUS_S, SPACE_M, SPACE_S))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", TEXT_FAINT)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_font_size("font_size", "Button", FONT_L)
	t.set_constant("h_separation", "Button", SPACE_S)

	# 主操作：实心强调（一个界面上最多一个，否则强调就不成其为强调）。
	t.set_type_variation(VARIATION_ACCENT, "Button")
	t.set_stylebox("normal", VARIATION_ACCENT, box(ACCENT, ACCENT, 0, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("hover", VARIATION_ACCENT, box(ACCENT.lightened(0.15), ACCENT, 0, RADIUS_S, SPACE_M, SPACE_S))
	t.set_stylebox("pressed", VARIATION_ACCENT, box(ACCENT.darkened(0.15), ACCENT, 0, RADIUS_S, SPACE_M, SPACE_S))
	t.set_color("font_color", VARIATION_ACCENT, ON_ACCENT)
	t.set_color("font_hover_color", VARIATION_ACCENT, ON_ACCENT)
	t.set_color("font_pressed_color", VARIATION_ACCENT, ON_ACCENT)

	# 工具按钮：常态继承 Button，只改写"选中"（toggle 按下）—— 触摸下这是唯一的选中线索。
	t.set_type_variation(VARIATION_TOOL, "Button")
	t.set_stylebox("pressed", VARIATION_TOOL, box(ACCENT_DIM, ACCENT, 1, RADIUS_S, SPACE_S, SPACE_XS))
	t.set_stylebox("hover", VARIATION_TOOL, box(SURFACE_HOVER, BORDER_STRONG, 1, RADIUS_S, SPACE_S, SPACE_XS))
	t.set_stylebox("normal", VARIATION_TOOL, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, RADIUS_S, SPACE_S, SPACE_XS))
	t.set_color("font_pressed_color", VARIATION_TOOL, ACCENT)
	t.set_font_size("font_size", VARIATION_TOOL, FONT_L)


static func _theme_label(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FONT_M)


static func _theme_container(t: Theme) -> void:
	t.set_stylebox("panel", "PanelContainer", box(SURFACE, BORDER, 1, RADIUS_M, SPACE_M, SPACE_M))
	t.set_stylebox("separator", "HSeparator", line(BORDER))
	t.set_stylebox("panel", "Panel", box(BAR, BORDER, 0, 0, SPACE_S, SPACE_XS))
	t.set_constant("separation", "VBoxContainer", SPACE_S)
	t.set_constant("separation", "HBoxContainer", SPACE_S)
	t.set_constant("separation", "GridContainer", SPACE_XS)


## 滚动条：调色板材质多时会出现。做得极窄极暗 —— 它是"还有内容"的暗示，不是控件。
static func _theme_scrollbar(t: Theme) -> void:
	for type in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", type, box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber", type, box(Color(1, 1, 1, 0.16), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber_highlight", type, box(ACCENT_DIM, ACCENT, 1, 4, 0, 0))
		t.set_stylebox("grabber_pressed", type, box(ACCENT, Color(0, 0, 0, 0), 0, 4, 0, 0))


## 提示气泡：鼠标的专属福利（触摸看不到），但也给个统一长相。
static func _theme_tooltip(t: Theme) -> void:
	t.set_stylebox("panel", "TooltipPanel", box(Color(0.0353, 0.0431, 0.0588, 0.98), BORDER_STRONG, 1, RADIUS_S, SPACE_S, SPACE_XS))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FONT_S)


# ----------------------------------------------------------------------------
# 样式盒工厂
# ----------------------------------------------------------------------------

## 通用圆角矩形：底色 + 描边 + 内边距。所有面板 / 按钮底都出自这一个函数，
## 于是"改圆角 = 全应用一起改"。
static func box(bg: Color, border := BORDER, border_w := 1, radius := RADIUS_S,
		pad_x := SPACE_M, pad_y := SPACE_S) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


static func line(color := BORDER, thickness := 1) -> StyleBoxLine:
	var sb := StyleBoxLine.new()
	sb.color = color
	sb.thickness = thickness
	sb.vertical = false
	return sb


# ----------------------------------------------------------------------------
# 控件工厂
# ----------------------------------------------------------------------------

static func label(text := "", size := FONT_M, color := TEXT, outlined := false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outlined:
		# 视口底色深浅不定，给压在 3D 上的文字一圈暗描边保证可读
		# （比强制不透明底板更轻，也不遮住模型）。
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", 4)
	return l


## 分组小标题：小字号 + 弱色 + 全大写字母间距感，用于"工具 / 笔刷 / 调色板"这类分区。
static func heading(text: String) -> Label:
	var l := label(text, FONT_S, TEXT_FAINT)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	return l


## 普通按钮。variation 传 VARIATION_ACCENT 即主操作样式。
static func button(text: String, tooltip := "", variation := &"") -> Button:
	var b := Button.new()
	b.text = text
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 键盘焦点一律不要：本应用的键盘归视口（热键），按钮只吃指针。
	b.focus_mode = Control.FOCUS_NONE
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	if not variation.is_empty():
		b.theme_type_variation = variation
	return b


## 纯文字小按钮（撤销、加减号）：定死方形命中区，不随文字长度跳动。
static func icon_button(text: String, tooltip := "", size := ICON_SIZE) -> Button:
	var b := button(text, tooltip)
	b.custom_minimum_size = Vector2(size, size)
	return b


## 互斥选中按钮（工具、材质）：pressed 态即"当前"，触摸下没有 hover 也一眼看得出。
static func toggle_button(tooltip := "", variation := VARIATION_TOOL) -> Button:
	var b := button("", tooltip, variation)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, MIN_TOUCH)
	return b


## 材质色块：颜色本身就是内容，故底色取自材质，不是主题色。
## 选中靠 **加粗强调描边**（不用变色 —— 变色会让"这个色块代表什么颜色"失真）。
static func swatch(color: Color, tooltip := "", size := MIN_TOUCH) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(size, size)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	var radius := RADIUS_S
	b.add_theme_stylebox_override("normal", box(color, Color(1, 1, 1, 0.18), 1, radius, 0, 0))
	b.add_theme_stylebox_override("hover", box(color.lightened(0.15), Color.WHITE, 2, radius, 0, 0))
	b.add_theme_stylebox_override("pressed", box(color, ACCENT, 3, radius, 0, 0))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), ACCENT, 3, radius, 0, 0))
	return b


static func panel(margin := SPACE_M, bg := SURFACE) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(bg, BORDER, 1, RADIUS_M, margin, margin))
	return p


static func vbox(sep := SPACE_S) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep := SPACE_S) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func divider() -> HSeparator:
	return HSeparator.new()


## 弹性占位（把同一行里的两组控件推向两端）。
static func spacer() -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c
