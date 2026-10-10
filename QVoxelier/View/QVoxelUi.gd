@tool
class_name QVoxelUi
extends RefCounted
## QVoxelier 界面的设计规范（design token）与控件工厂 —— **所有面板长相的唯一来源**。
## 【为什么要有这一层】界面一旦散着写颜色与字号，三处按钮就会长出三种深浅，
## 加一个面板就得重新猜"上次那个灰是多少"。把色彩 / 间距 / 圆角 / 字号 / 命中区
## 收成常量，再由主题（Theme）与工厂函数统一分发，新面板只描述**结构**，不描述**长相**。
## 【为什么是 Theme 而不是逐个 override】Theme 是 Godot 原生的分发机制：构造一次、
## 挂到面板上，其下所有 Button / Label / PanelContainer 自动获得同一套样式，新增控件
## 不必记得"再 override 一遍"。差异态（主操作按钮）用 type_variation 表达 ——
## 与默认按钮共享底色，只覆盖不同项，于是"改一处基调 = 全应用一起变"。
## 【密度档：同一套界面，两种输入形态】命中区与栏高原本为**手指**而设（44 / 52），
## 但桌面建模软件的惯例是鼠标 24~32 就够（Blender 的按钮约 20~26），
## 用 44 的骨架会白白吃掉近四分之一画布。于是骨架尺寸按输入形态取两档
## （见 compact() 起的一组函数）：**触摸 44 / 52，桌面 32 / 40**，间距同时收一档
## （6/8/12 对 8/12/16），而**配色、圆角、字号两档完全一致** —— 紧凑的是骨架，不是观感。
## 由此推出三条硬约定，写新控件时照做：
##   ① 状态**不能只靠 hover 表达**（触摸没有悬停）—— 选中态必须是常驻可见的底色变化；
##   ② 每个操作都要有**可见按钮**，快捷键只是加速器而不是唯一入口；
##   ③ 图标不可用时用文字/字母徽标（本项目的工具按钮用热键字母当徽标，顺带自解释）。
## 【约定失效的唯一一处】引擎自建的 FileDialog / AcceptDialog 内部按钮（保存/取消）实测
## 50×34，不到 44。**试过修且修不动**：给 get_ok_button() 写 custom_minimum_size 会在下一帧
## 被引擎抹回 (0,0)，扫全树（含内部子节点）改写同样无效 —— 所以别再加"补救"代码，
## 那是死路。本文件工厂出的控件全部达标；要彻底解决只能自绘文件面板（成本远超收益）。
## 【只读共享】theme() 返回同一个实例给所有面板 —— 省得每人各建一份。调用方
## **不得在运行时改它**（要改请改本文件的常量），否则会串味到其它面板。

# 设计令牌（design token）
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
## 强调色的低透明度底（选中态背景 / 主操作按钮的常态底）。
const ACCENT_DIM := Color(0.4353, 0.8275, 1.0, 0.16)
## 主操作按钮的悬停底（比常态略实一档）。
const ACCENT_HOVER := Color(0.4353, 0.8275, 1.0, 0.28)
## 铺在强调色上的文字色（深色，保证对比度）。用于主操作按钮"按下"那一瞬的实心反馈。
const ON_ACCENT := Color(0.0431, 0.0784, 0.1098, 1.0)
const WARN := Color(1.0, 0.5412, 0.4471, 1.0)
const OK := Color(0.4196, 0.8902, 0.6275, 1.0)

const RADIUS_S := 6
const RADIUS_M := 10

## 间距最小一档。**两档共用** —— 它已经是"元素挨在一起"的下限，再收就要粘成一块。
const SPACE_XS := 4

# 字号阶：整体比"网页习惯"大一档。这是长期注视的建模工具，11/12 那套在
# 1152×648 的实际窗口里读起来是"眯着看"（实测截图里状态栏与分组小标题尤其吃力）。
# **字号不分档**：密度该由骨架（命中区 / 栏高 / 间距）让出来，压字号只会换来难读。
const FONT_S := 12
const FONT_M := 13
const FONT_L := 14
const FONT_TITLE := 16

## type_variation 名：主操作按钮（保存、确认），强调色实心。
const VARIATION_ACCENT := &"AccentButton"
## type_variation 名：工具按钮（互斥选中），选中态用强调色描边 + 强调色底。
const VARIATION_TOOL := &"ToolButton"

static var _theme: Theme = null


# 密度档（界面骨架尺寸的唯一来源）

## 是否用桌面紧凑档。
## 【判据为什么是 mobile 而不是"有没有触摸屏"】带触摸屏的笔记本两者都报，
## 而那类机器的主输入仍是鼠标键盘；真正需要 44 命中区的是**手指操作的移动设备**。
## 宁可在触摸屏桌面上偏紧凑（鼠标毫无压力），也不要让平板收到 32。
## 【为什么档位是函数而不是 static var】本项目实测：**新建**脚本里的 static var 在
## 编辑器热加载下可能读回全 0（静态初值没落地）；而 const 又必须是编译期常量，
## 容不下 OS.has_feature() 这种运行时判断。于是"两档数值写在函数里、由 compact()
## 现算"是唯一没有时序依赖的写法（已存在脚本里的 static var 是好的，但没必要赌）。
static func compact() -> bool:
	return not OS.has_feature("mobile")


## 最小命中区边长。44 = 公认的手指下限；32 = 鼠标的舒适下限（Blender 约 20~26）。
static func hit_size() -> int:
	return 32 if compact() else 44


## 顶部应用栏高度。
static func bar_height() -> int:
	return 40 if compact() else 52


## 底部状态栏高度。
static func status_height() -> int:
	return 30 if compact() else 36


## 左侧工具坞的目标宽度（下限：内容更宽时以内容为准）。
static func dock_width() -> int:
	return 116 if compact() else 132


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
	return t


## 按钮：常态 / 悬停 / 按下 / 禁用 / 焦点五态。**键盘焦点框刻意不做醒目**（本应用
## 的按钮一律 FOCUS_NONE，键盘归视口），只留一条细描边以防将来接入手柄导航。
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
	# 【为什么不做成常驻的实心高亮块】实测它会是整屏最亮的东西（比模型还亮），把视线从
	# 视口拉走；而且强调色在本层的约定是"当前选中 / 可交互"，一个常驻亮块会稀释这条约定。
	# 主操作靠"整条栏里唯一带强调描边与强调字"依然一眼可辨 —— 区分度没丢，噪声降了。
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


## 滚动条：调色板材质多时会出现。做得极窄极暗 —— 它是"还有内容"的暗示，不是控件。
static func _theme_scrollbar(t: Theme) -> void:
	for type in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", type, box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber", type, box(Color(1, 1, 1, 0.16), Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber_highlight", type, box(ACCENT_DIM, ACCENT, 1, 4, 0, 0))
		t.set_stylebox("grabber_pressed", type, box(ACCENT, Color(0, 0, 0, 0), 0, 4, 0, 0))


## 滑条：颜色分组的 RGBA 通道用它。槽做得极窄极暗、已填充段用强调色 ——
## 与滚动条同一思路：控件本身低调，"当前值"才是信息。
## grabber（滑块）图标沿用引擎默认 —— 那是图标不是样式盒，自绘成本远超收益。
static func _theme_slider(t: Theme) -> void:
	for type in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", type, box(SURFACE_HI, BORDER, 1, 4, 0, 0))
		t.set_stylebox("grabber_area", type, box(ACCENT_DIM, Color(0, 0, 0, 0), 0, 4, 0, 0))
		t.set_stylebox("grabber_area_highlight", type, box(ACCENT, Color(0, 0, 0, 0), 0, 4, 0, 0))


## 单行文本输入：时间轴分组的标签编辑用它。
## 【为什么必须进主题、而不是就地 override】QVoxelUi 是"面板长相的唯一来源"（见类文档）。
## LineEdit 的引擎默认长相是**亮底深字**，压在深空冷调的面板上会像一块贴错的便签；
## 收进主题后它和其它控件共享同一套底色 / 描边 / 字号，"改一处基调 = 全应用一起变"仍然成立。
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
	t.set_stylebox("panel", "TooltipPanel", box(Color(0.0353, 0.0431, 0.0588, 0.98), BORDER_STRONG, 1, RADIUS_S, space_s(), SPACE_XS))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FONT_S)


# 样式盒工厂

## 通用圆角矩形：底色 + 描边 + 内边距。所有面板 / 按钮底都出自这一个函数，
## 于是"改圆角 = 全应用一起改"。
static func box(bg: Color, border := BORDER, border_w := 1, radius := RADIUS_S,
		pad_x := -1, pad_y := -1) -> StyleBoxFlat:
	# 【为什么默认值是 -1 而不是直接写 space_m()】GDScript 的默认参数必须是**编译期常量**，
	# 而间距要随密度档变（见 compact()），于是用 -1 当"未指定"哨兵、进函数再解析。
	# 传 0 是合法值（色块这类就要零内边距），不会被当成哨兵。
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
static func icon_button(text: String, tooltip := "", size := -1) -> Button:
	var b := button(text, tooltip)
	var s := hit_size() if size < 0 else size
	b.custom_minimum_size = Vector2(s, s)
	return b


## 互斥选中按钮（工具、材质）：pressed 态即"当前"，触摸下没有 hover 也一眼看得出。
static func toggle_button(tooltip := "", variation := VARIATION_TOOL) -> Button:
	var b := button("", tooltip, variation)
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, hit_size())
	return b


## 单行文本输入（长相由 _theme_line_edit 统一）。placeholder 为空则不留提示。
static func text_field(text := "", placeholder := "", tooltip := "") -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.focus_mode = Control.FOCUS_NONE
	e.caret_blink = true
	e.custom_minimum_size = Vector2(0, hit_size())
	if not tooltip.is_empty():
		e.tooltip_text = tooltip
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
## 选中靠 **加粗强调描边**（不用变色 —— 变色会让"这个色块代表什么颜色"失真）。
static func swatch(color: Color, tooltip := "", size := -1) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	var s := hit_size() if size < 0 else size
	b.custom_minimum_size = Vector2(s, s)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not tooltip.is_empty():
		b.tooltip_text = tooltip
	var radius := RADIUS_S
	b.add_theme_stylebox_override("normal", box(color, Color(1, 1, 1, 0.18), 1, radius, 0, 0))
	b.add_theme_stylebox_override("hover", box(color.lightened(0.15), Color.WHITE, 2, radius, 0, 0))
	b.add_theme_stylebox_override("pressed", box(color, ACCENT, 3, radius, 0, 0))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), ACCENT, 3, radius, 0, 0))
	return b


static func panel(margin := -1, bg := SURFACE) -> PanelContainer:
	var m := space_m() if margin < 0 else margin
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(bg, BORDER, 1, RADIUS_M, m, m))
	return p


static func vbox(sep := -1) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", space_s() if sep < 0 else sep)
	return v


static func hbox(sep := -1) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", space_s() if sep < 0 else sep)
	return h


## 滚动容器：内容超出即滚动，**另一轴不参与布局**。
## 【为什么另一轴用 DISABLED 而不是 SHOW_NEVER】SHOW_NEVER 仍会把子节点的总宽 / 总高算进
## minimum size，于是"把滚动条藏起来"的容器会把父容器撑爆（DefTableView 踩过同一个坑）。
## height > 0 时定高；要"跟着父容器伸缩"就传 0 并自行设 SIZE_EXPAND_FILL。
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
## 定高居中而不是顶满 —— 满高会被读成"分栏"，而它们只是同一层里的分组。
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
