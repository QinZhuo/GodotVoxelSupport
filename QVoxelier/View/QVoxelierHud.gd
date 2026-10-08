@tool
class_name QVoxelierHud
extends UIPanel
## 建模视口的状态栏：当前工具 / 光标格 / 笔刷尺寸 / 撤销栈，以及一行操作提示。
##
## 【为什么值得单独一类】视口的"手感"有一半来自反馈：用户必须能当场看到
## "我在哪个格上""现在这一笔写下去的是几号材质""刚才那笔撤得掉吗"。
## 把这些塞进视口脚本，会让一个本该只翻译输入的角色长出界面细节；
## 而它们又必须与工具表（QVoxBrushTool.MODES）保持一致 —— 提示文案与按钮同源，
## 才不会出现"工具栏写着线笔、提示却还在讲盒笔"。
##
## 【形态无关】只依赖会话（Editing 层）与框架的 UIPanel/U，不认识相机与渲染器：
## 换成 Dock 内嵌视口时，本类一行都不用改。
##
## 【不抢输入】整条状态栏 mouse_filter = IGNORE：它压在视口上，但绝不吞鼠标事件
## （否则底部一条会被"点不进去"，表现为视口里有一条死区）。

## 会话（由视口装配后设进来；为空时只显示静态提示）。
var session: QVoxEditSession = null

var _tool: Label
var _hint: Label
var _cursor: Label
var _brush: Label
var _history: Label
var _toast: Label
var _toast_left := 0.0

const TOAST_SECONDS := 2.5
const DIM := Color(1, 1, 1, 0.55)
const BRIGHT := Color(1, 1, 1, 0.92)
const ACCENT := Color(0.62, 0.82, 1.0)


func _ready() -> void:
	layer = UITool.Layer.HUD
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	open()


func _process(delta: float) -> void:
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left <= 0.0:
		_toast.text = ""


# ----------------------------------------------------------------------------
# 对外：刷新 / 提示
# ----------------------------------------------------------------------------

## 按会话现状刷新整条状态栏（工具、笔刷、光标、撤销栈）。
func refresh() -> void:
	if session == null:
		return
	var t := session.tool
	_tool.text = t.label()
	_hint.text = t.hint()
	_brush.text = "笔刷 %d" % t.brush_size if t.supports_brush_size() else "笔刷 —"
	_brush.modulate = BRIGHT if t.supports_brush_size() else DIM
	var undo := session.history.undo_label()
	var redo := session.history.redo_label()
	# 可重做条数 = 命令流里游标之后的那一段（见 QVoxUndoStack：游标把一条命令流切成两半）。
	var redo_count := session.history.commands.size() - session.history.cursor
	_history.text = "撤销 %d%s · 重做 %d%s" % [
		session.history.cursor, "（%s）" % undo if undo != "" else "",
		redo_count, "（%s）" % redo if redo != "" else "",
	]


## 光标所在格（Vector3i.MIN = 没指到网格上）。
func set_cursor(cell: Vector3i) -> void:
	_cursor.text = "格 —" if cell == Vector3i.MIN else "格 (%d, %d, %d)" % [cell.x, cell.y, cell.z]


## 一行短提示（2.5 秒后自动消失）：越界、无可撤销、模式已切换这类"刚发生的事"。
func flash(text: String) -> void:
	_toast.text = text
	_toast_left = TOAST_SECONDS


# ----------------------------------------------------------------------------
# 界面
# ----------------------------------------------------------------------------

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_legend()
	_build_toast()
	_build_bar()


## 操作提示（左上角，常驻）：不占状态栏的行宽，也不随操作变化。
func _build_legend() -> void:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	box.position = Vector2(12, 10)
	add_child(box)
	for line in [
		"左键画 · 右键擦 · 拖动连续涂抹",
		"中键转视角 · Shift+中键平移 · 滚轮缩放 · Home 取景",
		"V/F/B/L/C 切工具 · [ ] 改笔刷 · Ctrl+Z 撤销 · Ctrl+Shift+Z 重做 · Esc 取消",
	]:
		var l := _label(line, 12, DIM)
		box.add_child(l)


func _build_toast() -> void:
	_toast = _label("", 14, ACCENT)
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.offset_top = -78.0
	_toast.offset_bottom = -56.0
	add_child(_toast)


func _build_bar() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.07, 0.09, 0.72)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 5
	bg.content_margin_bottom = 5

	var bar := PanelContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("panel", bg)
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -34.0
	bar.offset_bottom = 0.0
	add_child(bar)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 14)
	bar.add_child(row)

	_tool = _label("", 14, BRIGHT)
	row.add_child(_tool)
	_hint = _label("", 13, DIM)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_hint)
	_cursor = _label("", 13, BRIGHT)
	row.add_child(_cursor)
	_brush = _label("", 13, BRIGHT)
	row.add_child(_brush)
	_history = _label("", 13, DIM)
	row.add_child(_history)


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	# 视口底色深浅不定，给文字一圈暗描边保证可读（比强制不透明底板更轻）。
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	return l
