@tool
class_name QVoxelierHud
extends QVoxelierPanel
## 状态栏 + 瞬时提示 + 操作说明 —— 视口的全部"回话"都在这里。
##
## 【为什么值得单独一类】视口的手感有一半来自反馈：用户必须能当场看到"我在哪个格上"
## "这一笔写下去是几号材质""刚才那笔撤得掉吗"。把这些塞进视口脚本，会让一个本该只翻译
## 输入的角色长出界面细节；而它们又必须与工具表（[QVoxelBrushTool.MODES]）保持一致 ——
## 提示文案与按钮同源，才不会出现"工具栏写着线笔、提示却还在讲盒笔"。
##
## 【形态无关】只依赖会话（Editing 层），不认识相机与渲染器：换成 Dock 内嵌视口时一行都不用改。
##
## 【不抢输入】状态栏整条 mouse_filter = IGNORE：它压在视口底边上，但绝不吞鼠标事件
## （否则底部会多出一条"点不进去"的死区）。唯一吃事件的只有「?」打开的那块说明面板，
## 因为那块是**浮层**——盖住视口时本就该拦住点击。
##
## 【为什么要有一份操作说明】同一套界面要喂给"鼠标 + 键盘"和"单根手指"两种操作形态，
## 两者的动作名字完全不同（右键 = 擦除开关，中键 = 导航模式）。说明面板把两套对照着列出来，
## 用户不必猜"平板上的右键在哪"。

## 会话（由视口装配后设进来；为空时只显示静态文案）。
var session: QVoxelEditSession = null

var _tool: Label
var _hint: Label
var _cursor: Label
var _brush: Label
var _material: Label
var _history: Label
var _toast: Label
var _legend: PanelContainer
var _toast_left := 0.0

const TOAST_SECONDS := 2.5


func _process(delta: float) -> void:
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left <= 0.0:
		_toast.text = ""


# ----------------------------------------------------------------------------
# 对外：刷新 / 提示
# ----------------------------------------------------------------------------

## 按会话现状刷新状态栏（工具 / 笔刷 / 撤销栈）。
func refresh() -> void:
	if session == null:
		return
	var t := session.tool
	_tool.text = t.label()
	_hint.text = t.hint()
	_brush.text = "笔刷 %d" % t.brush_size if t.supports_brush_size() else "笔刷 —"
	_brush.add_theme_color_override("font_color",
			QVoxelUi.TEXT if t.supports_brush_size() else QVoxelUi.TEXT_FAINT)
	var undo := session.history.undo_label()
	var redo := session.history.redo_label()
	# 可重做条数 = 命令流里游标之后的那一段（游标把一条命令流切成"已生效 / 可重做"两半）。
	var redo_count := session.history.commands.size() - session.history.cursor
	_history.text = "撤销 %d%s · 重做 %d%s" % [
		session.history.cursor, "（%s）" % undo if undo != "" else "",
		redo_count, "（%s）" % redo if redo != "" else "",
	]


## 光标所在格（Vector3i.MIN = 没指到网格上）。
func set_cursor(cell: Vector3i) -> void:
	_cursor.text = "格 —" if cell == Vector3i.MIN else "格 %d,%d,%d" % [cell.x, cell.y, cell.z]


## 当前材质号（与调色板的选中块同源，由 App 一处回写）。
## 名字带 `_id` 后缀是必须的：`set_material` 会**覆盖 CanvasItem 的原生方法**（画布材质），
## 签名不匹配直接编译不过。
func set_material_id(material_id: int) -> void:
	_material.text = "材质 %d" % material_id


## 一行短提示（2.5 秒后自动消失）：越界、无可撤销、模式已切换这类"刚发生的事"。
func flash(text: String) -> void:
	_toast.text = text
	_toast_left = TOAST_SECONDS


## 操作说明浮层（由应用栏的「?」开关）。
func set_legend_visible(on: bool) -> void:
	_legend.visible = on


func legend_visible() -> bool:
	return _legend.visible


# ----------------------------------------------------------------------------
# 界面
# ----------------------------------------------------------------------------

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_status()
	_build_toast()
	_build_legend()


## 底部状态栏：左起工具名（强调色，一眼定位），中间是当前工具的用法提示（可伸缩，
## 窄屏时先压缩它），右侧是光标 / 笔刷 / 材质 / 撤销栈这些随操作跳动的读数。
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
	_cursor = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_cursor)
	_brush = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_brush)
	_material = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_material)
	# 撤销栈是"改了什么"的历史，与光标读数不是一类，再隔一条。
	row.add_child(QVoxelUi.vdivider(QVoxelUi.status_height() / 2))
	_history = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT_DIM)
	row.add_child(_history)


## 提示条压在调色板上方（调色板占着底边），避免被盖住。
func _build_toast() -> void:
	_toast = QVoxelUi.label("", QVoxelUi.FONT_TITLE, QVoxelUi.ACCENT, true)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var bottom := QVoxelUi.status_height() + QVoxelUi.hit_size() + 2 * QVoxelUi.space_s() + QVoxelUi.space_m()
	_toast.offset_top = -float(bottom) - QVoxelUi.FONT_TITLE - QVoxelUi.space_s()
	_toast.offset_bottom = -float(bottom)
	add_child(_toast)


## 操作说明浮层：鼠标与触摸两套并列。默认隐藏（视口第一印象要干净），
## 由应用栏的「?」开关 —— 说明是查得到的东西，不该常驻占地方。
func _build_legend() -> void:
	_legend = QVoxelUi.panel(QVoxelUi.space_m(), QVoxelUi.SURFACE_SOLID)
	_legend.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	# 锚在右上角、向左下方生长：浮层宽度由文案决定（不写死宽度，改文案不必调这里）。
	_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_legend.offset_left = -QVoxelUi.space_m()
	_legend.offset_right = -QVoxelUi.space_m()
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


## 说明文案：**两套操作形态并列**，因为同一套界面上平板与鼠标的动作名字不同。
## 改输入约定时改这里一处（工具级的提示在 QVoxelBrushTool.MODES 里，两处各管一层）。
const _LEGEND := [
	["鼠标 + 键盘", [
		"左键拖动 画 · 右键 擦（或开左侧「擦除」）",
		"中键拖动 转视角 · Shift+中键 平移 · 滚轮 缩放 · Home 取景",
		"V/F/B/L/C 切工具 · E 擦除 · [ ] 改笔刷 · 1..8 选材质",
		"Ctrl+Z 撤销 · Ctrl+Shift+Z 重做 · Esc 取消这一笔",
		"Ctrl+S 保存 · Ctrl+Shift+S 另存 · Ctrl+O 打开（.qvx 可直接拖进窗口）",
	]],
	["触摸屏", [
		"单指拖动 画 · 用左侧「擦除」开关代替右键",
		"「导航」模式下单指拖动 = 转视角 · −/+ 缩放 ·「取景」把模型框回画面",
		"色块与按钮都按手指尺寸留足命中区，无需键盘即可完成全部操作",
	]],
]


func _readout(font_size: int, color: Color) -> Label:
	# 压在 3D 画面上，故一律带暗描边（见 QVoxelUi.label 的 outlined）。
	var l := QVoxelUi.label("", font_size, color, true)
	# 状态栏比一行字高，Label 默认顶对齐会让整排读数贴在上边；显式居中。
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l
