@tool
class_name QVoxelierHud
extends QVoxelierPanel
## 状态栏 + 瞬时提示 + 操作说明 —— 视口的全部"回话"都在这里。

## 会话（由视口装配后设进来；为空时只显示静态文案）。
var session: QVoxelEditSession = null

var _tool: Label
var _hint: Label
var _cursor: RichTextLabel
var _selection: Label
var _toast: Label
## 悬停提示（按钮/控件的 tooltip 首行）。
var _hover_hint := ""
## 后台任务（烘焙间接光、体素化…）。
var _busy_text := ""
var _busy_frame := 0
var _busy_t := 0.0
var _legend: PanelContainer
var _log: PanelContainer
var _log_scroll: ScrollContainer
var _log_list: VBoxContainer
var _log_empty: Label
var _toast_left := 0.0
## 两块浮层右侧要让开的宽度。
var _right_inset := QVoxelUi.dock_width() + QVoxelUi.space_s()

const TOAST_SECONDS := 2.5
## 日志浮层：宽固定（长消息换行，而不是把面板撑到半个屏幕），高固定（内容超出就滚动）。
const LOG_WIDTH := 360.0
const LOG_HEIGHT := 220.0
## 只留最近 N 行 —— 日志是"回看刚才发生了什么"，不是审计档案；无界增长会一直吃内存。
const LOG_MAX := 200

## 后台任务指示：四个方向依次转，比"..."更能让人看出"它还在动"。
const SPINNER := ["◐", "◓", "◑", "◒"]
## 转圈帧间隔（秒）。
const SPIN_INTERVAL := 0.12

func _process(delta: float) -> void:
	if not _busy_text.is_empty():
		_busy_t += delta
		if _busy_t >= SPIN_INTERVAL:
			_busy_t = 0.0
			_busy_frame = (_busy_frame + 1) % SPINNER.size()
			_apply_hint()
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left <= 0.0:
		_toast.text = ""

# 对外：刷新 / 提示

## 按会话现状刷新状态栏（工具 + 提示）。
func refresh() -> void:
	if session == null:
		return
	_tool.text = session.tool.label()
	_apply_hint()
	_selection.text = _selection_readout()
	# 有选区时点亮：选区是"下次复制 / 移动会作用在哪"的答案，用户必须一眼能看出它在不在。
	_selection.add_theme_color_override("font_color",
			QVoxelUi.ACCENT if not session.selection.is_empty() else QVoxelUi.TEXT_FAINT)

## 悬停某个按钮 / 控件时把它的提示送到状态栏（空串 = 恢复默认的工具提示）。
func show_hover_hint(text: String) -> void:
	_hover_hint = text
	_apply_hint()

## 设 / 清后台任务状态（空串 = 结束）。
func set_busy(text: String) -> void:
	if text == _busy_text:
		return
	_busy_text = text
	_busy_frame = 0
	_busy_t = 0.0
	_apply_hint()

func is_busy() -> bool:
	return not _busy_text.is_empty()

## 状态栏中间那一格：后台任务 > 悬停提示 > 当前工具的用法。
func _apply_hint() -> void:
	if _hint == null:
		return
	if not _busy_text.is_empty():
		_hint.text = "%s %s" % [SPINNER[_busy_frame], _busy_text]
		_hint.add_theme_color_override("font_color", QVoxelUi.ACCENT)
		return
	_hint.add_theme_color_override("font_color", QVoxelUi.TEXT_DIM)
	_hint.text = _hover_hint if not _hover_hint.is_empty() else (
			session.tool.hint() if session != null else "")

## 光标所在格（Vector3i.MIN = 没指到网格上）。
func set_cursor(cell: Vector3i) -> void:
	if cell == Vector3i.MIN:
		_cursor.text = "[color=#%s]X[/color] —   [color=#%s]Y[/color] —   [color=#%s]Z[/color] —" % [
				_axis_hex(0), _axis_hex(1), _axis_hex(2)]
	else:
		_cursor.text = "[color=#%s]X[/color] %d   [color=#%s]Y[/color] %d   [color=#%s]Z[/color] %d" % [
				_axis_hex(0), cell.x, _axis_hex(1), cell.y, _axis_hex(2), cell.z]

static func _axis_hex(i: int) -> String:
	return (QVoxelierGizmo.AXIS_COLORS[i] as Color).to_html(false)

## 模型读数：**链作用后**的盒尺寸 + 屏幕上真实存在的体素数。
func _model_readout() -> String:
	if session == null or session.object == null:
		return "模型 —"
	var g := session.output_size()
	var n := session.data.evaluated_voxel_count() if session.data != null else 0
	return "模型 %d×%d×%d · %d 体素" % [g.x, g.y, g.z, n]

## 选区 / 剪贴板读数。
func _selection_readout() -> String:
	if session == null:
		return "无选区"
	var s := session.selection.describe()
	if not session.clipboard.is_empty():
		s += " · " + session.clipboard.describe()
	return s

## 一行短提示（2.5 秒后自动消失）：越界、无可撤销、模式已切换这类"刚发生的事"。
func flash(text: String) -> void:
	_toast.text = text
	_toast_left = TOAST_SECONDS
	_append_log(text)

## 操作说明浮层（由应用栏的「?」开关）。
func set_legend_visible(on: bool) -> void:
	_legend.visible = on
	if on:
		_log.visible = false

func legend_visible() -> bool:
	return _legend.visible

## 日志浮层（由应用栏的「日志」开关）：刚才发生了什么，按时间从上往下排。
func set_log_visible(on: bool) -> void:
	_log.visible = on
	if on:
		_legend.visible = false
		# 打开即滚到底：点它多半是想看"最近这一下"，而不是从头读起。
		_scroll_to_bottom.call_deferred()

func log_visible() -> bool:
	return _log.visible

## 清空日志（浮层标题栏的按钮）。
func clear_log() -> void:
	for c in _log_list.get_children():
		_log_list.remove_child(c)
		c.queue_free()
	_refresh_log_empty()

## 日志内容（只读，按时间从旧到新）。
func log_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for c in _log_list.get_children():
		out.append((c as Label).text)
	return out

# 界面

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_status()
	_build_toast()
	_build_legend()
	_build_log()

## 底部状态栏：左起工具名（强调色，一眼定位），中间是当前工具的用法提示（可伸缩，
func _build_status() -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
			QVoxelUi.box(QVoxelUi.BAR, Color(0, 0, 0, 0), 0, 0, QVoxelUi.space_m(), 0))
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -QVoxelUi.status_height()
	add_child(bar)

	var row := QVoxelUi.hbox(QVoxelUi.space_m())
	bar.add_child(row)

	_tool = _readout(QVoxelUi.FONT_L, QVoxelUi.ACCENT)
	row.add_child(_tool)
	_hint = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT_DIM)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_hint)
	# 隔一条线：左边是"你现在能做什么"（提示），右边是"你现在是什么状态"（读数）。
	row.add_child(QVoxelUi.vdivider(QVoxelUi.status_height() / 2))
	# 选区排在读数区最前：它是"接下来那一下会作用在哪"，比"光标在哪一格"更需要一眼看到。
	_selection = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT_FAINT)
	row.add_child(_selection)
	# 光标坐标单用富文本：X/Y/Z 三段按轴着色（与右下角坐标轴同色），一眼分得开三行坐标。
	_cursor = RichTextLabel.new()
	_cursor.fit_content = true
	# 关掉自动换行是必须的：fit_content 的"最小宽度 = 内容宽度"与换行互相喂招 ——
	_cursor.autowrap_mode = TextServer.AUTOWRAP_OFF
	_cursor.bbcode_enabled = true
	_cursor.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cursor.add_theme_color_override("default_color", QVoxelUi.TEXT)
	_cursor.add_theme_font_size_override("normal_font_size", QVoxelUi.FONT_M)
	_cursor.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_cursor.add_theme_constant_override("outline_size", 4)
	row.add_child(_cursor)
	# 模型尺寸/体素数、撤销/重做计数已删：前者在层级里可见，后者顶栏的撤销/重做按钮已表达。

## 提示条压在调色板上方（调色板占着底边），避免被盖住。
func _build_toast() -> void:
	_toast = QVoxelUi.label("", QVoxelUi.FONT_TITLE, QVoxelUi.ACCENT, true)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var bottom := QVoxelUi.status_height() + QVoxelUi.strip_height() + QVoxelUi.hit_size() + 2 * QVoxelUi.space_s() + QVoxelUi.space_m()
	_toast.offset_top = -float(bottom) - QVoxelUi.FONT_TITLE - QVoxelUi.space_s()
	_toast.offset_bottom = -float(bottom)
	add_child(_toast)

## 操作说明浮层：鼠标与触摸两套并列。
func _build_legend() -> void:
	_legend = QVoxelUi.panel(QVoxelUi.space_m(), QVoxelUi.SURFACE_SOLID)
	_legend.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	# 锚在右上角、向左下方生长：浮层宽度由文案决定（不写死宽度，改文案不必调这里）。
	_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_legend.offset_left = -_float_inset()
	_legend.offset_right = -_float_inset()
	_legend.offset_top = QVoxelUi.bar_height() + QVoxelUi.space_m()
	_legend.offset_bottom = QVoxelUi.bar_height() + QVoxelUi.space_m()
	_legend.visible = false
	add_child(_legend)

	var col := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_legend.add_child(col)
	col.add_child(QVoxelUi.heading("操作说明"))
	for block in _LEGEND:
		var section := QVoxelUi.label(block[0], QVoxelUi.FONT_M, QVoxelUi.ACCENT)
		section.custom_minimum_size.y = QVoxelUi.space_l()
		col.add_child(section)
		for line in block[1]:
			col.add_child(QVoxelUi.label(line, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))

## 日志浮层：与说明浮层并列（同样锚右上、同样默认隐藏），区别是**内容会增长**，故带滚动与清空。
func _build_log() -> void:
	_log = QVoxelUi.panel(QVoxelUi.space_m(), QVoxelUi.SURFACE_SOLID)
	_log.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_log.offset_right = -_float_inset()
	_log.offset_left = -LOG_WIDTH - _float_inset()
	_log.offset_top = QVoxelUi.bar_height() + QVoxelUi.space_m()
	_log.offset_bottom = _log.offset_top + LOG_HEIGHT
	_log.visible = false
	add_child(_log)

	var col := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_log.add_child(col)

	var head := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	col.add_child(head)
	var title := QVoxelUi.heading("日志")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(title)
	var clear := QVoxelUi.icon_button("清", "清空日志")
	clear.pressed.connect(clear_log)
	head.add_child(clear)

	# 高度由浮层的固定矩形决定（EXPAND_FILL 吃掉标题行之外的余量），故不必在这里算高度。
	_log_scroll = QVoxelUi.scroll(true)
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_log_scroll)
	_log_list = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_log_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_scroll.add_child(_log_list)

	# 空态：日志是"回看刚才发生了什么"，一条都没有时得给句话 —— 否则用户对着空面板分不清
	_log_empty = QVoxelUi.label("还没有操作记录 —— 画一笔、切个工具，都会记在这里",
			QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT)
	_log_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_log_empty)
	_refresh_log_empty()

## 追加一行：新行在底部（时间从上往下读），并**有界**（只留最近 LOG_MAX 行）。
func _append_log(text: String) -> void:
	if _log_list == null:
		return
	var l := QVoxelUi.label(text, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_list.add_child(l)
	while _log_list.get_child_count() > LOG_MAX:
		var old := _log_list.get_child(0)
		_log_list.remove_child(old)
		old.queue_free()
	_refresh_log_empty()
	_scroll_to_bottom.call_deferred()

## 空态与列表互斥可见：一条记录都没有时给提示，否则给滚动区。
func _refresh_log_empty() -> void:
	if _log_empty == null or _log_scroll == null:
		return
	var empty := _log_list.get_child_count() == 0
	_log_empty.visible = empty
	_log_scroll.visible = not empty

## 两块浮层右侧要让开的宽度：右侧栏（`dock_width`）再加一条缝。
func _float_inset() -> float:
	return _right_inset

## 报告右列占掉的宽度（App 装配时喂入抽屉的实际宽度 + 一条缝），变了就把浮层挪过去。
func set_right_inset(w: float) -> void:
	if is_equal_approx(w, _right_inset):
		return
	_right_inset = w
	if _legend != null:
		_legend.offset_left = -w
		_legend.offset_right = -w
	if _log != null:
		_log.offset_right = -w
		_log.offset_left = -LOG_WIDTH - w

## 滚到底。
func _scroll_to_bottom() -> void:
	if _log_scroll == null:
		return
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)

## 说明文案：**两套操作形态并列**，因为同一套界面上平板与鼠标的动作名字不同。
const _LEGEND := [
	["鼠标 + 键盘", [
		"左键拖动 按当前操作落笔 （顶栏选项条选 添加 / 移除 / 上色）",
		"右键 / Shift+左键 临时切到移除 · E 在添加与移除之间切换",
		"空白处拖动 转视角 · 中键拖动 同（任意位置）· Shift+中键 平移",
		"滚轮 俯仰 · Ctrl+滚轮 缩放 · 右下坐标轴：点轴切视图、拖动转视角、点盘心等轴",
		"选择：拖出矩形框 / 单击连通一块（顶栏切 同色 / 相连）· 移动：在选区上拖坐标轴",
		"图章：复制一块体素（Ctrl+C），切到「图章」工具点击盖章",
		"V/F/B/L/C 切工具 · T 选择 · M 移动 · [ ] 改笔刷 · 1..8 选材质",
		"Ctrl+Z 撤销 · Ctrl+Shift+Z 重做 · Esc 取消这一笔 / 退掉选区",
		"Ctrl+A 全选 · Ctrl+C/X/V 复制 / 剪切 / 粘贴 · Del 清空选区",
		"Ctrl+S 保存 · Ctrl+Shift+S 另存 · Ctrl+O 打开（.qvx/.vox） · Ctrl+E 导出 .vox",
	]],
	["触摸屏 / 触摸板", [
		"单指拖动 按当前操作落笔 · 用顶部选项条切「添加 / 移除 / 上色」",
		"双指拖动 平移画面 · 双指捏合 缩放（任意位置）",
		"单指拖动**空白处** = 转视角 · 右下坐标轴：点轴切视图 / 拖动转视角 / 点盘心等轴",
		"色块与按钮都按手指尺寸留足命中区，无需键盘即可完成全部操作",
	]],
]

func _readout(font_size: int, color: Color) -> Label:
	# 压在 3D 画面上，故一律带暗描边（见 QVoxelUi.label 的 outlined）。
	var l := QVoxelUi.label("", font_size, color, true)
	# 状态栏比一行字高，Label 默认顶对齐会让整排读数贴在上边；显式居中。
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l
