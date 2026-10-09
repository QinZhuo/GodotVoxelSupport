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
var _model: Label
var _selection: Label
var _history: Label
var _toast: Label
var _legend: PanelContainer
var _log: PanelContainer
var _log_scroll: ScrollContainer
var _log_list: VBoxContainer
var _toast_left := 0.0

const TOAST_SECONDS := 2.5
## 日志浮层：宽固定（长消息换行，而不是把面板撑到半个屏幕），高固定（内容超出就滚动）。
const LOG_WIDTH := 360.0
const LOG_HEIGHT := 220.0
## 只留最近 N 行 —— 日志是"回看刚才发生了什么"，不是审计档案；无界增长会一直吃内存。
const LOG_MAX := 200


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
	_model.text = _model_readout()
	_selection.text = _selection_readout()
	# 有选区时点亮：选区是"下次复制 / 移动会作用在哪"的答案，用户必须一眼能看出它在不在。
	_selection.add_theme_color_override("font_color",
			QVoxelUi.ACCENT if not session.selection.is_empty() else QVoxelUi.TEXT_FAINT)
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


## 模型读数：**链作用后**的盒尺寸 + 屏幕上真实存在的体素数。
##
## 【为什么两个数都取自显示层，而不是手绘种子】用户看的是求值输出：链里有镜像 / 平铺时
## `object.grid_size` 与看到的盒尺寸不同；程序化修改器产出的体素也不在手绘种子里。
## 报种子数会变成"屏幕上有 8000 个体素，读数说 0"。
##
## 【为什么尺寸报 output_size 而体素数报 data】尺寸是**声明**（盒多大），体素数是**事实**
## （现在有多少个非空格）。前者由链的结构决定，后者只有数据层知道 —— 两处各取权威来源。
func _model_readout() -> String:
	if session == null or session.object == null:
		return "模型 —"
	var g := session.output_size()
	var n := session.data.get_voxel_count() if session.data != null else 0
	return "模型 %d×%d×%d · %d 体素" % [g.x, g.y, g.z, n]


## 选区 / 剪贴板读数。
##
## 【为什么剪贴板空时不显示】"剪贴板空"常驻在状态栏上是纯噪音 —— 它只在用户按过复制之后
## 才有意义。空选区则必须显示（"无选区"），因为它是"按了复制却没反应"的唯一解释。
func _selection_readout() -> String:
	if session == null:
		return "无选区"
	var s := session.selection.describe()
	if not session.clipboard.is_empty():
		s += " · " + session.clipboard.describe()
	return s


## 一行短提示（2.5 秒后自动消失）：越界、无可撤销、模式已切换这类"刚发生的事"。
##
## 【为什么顺带记进日志】提示一闪即过，而"我刚做了什么才变成这样"的上下文只在日志里留得住 ——
## 导入 / 导出 / 求值失败的原因全都走这条路。让 flash 一处同时做两件事：几十个调用点一行不改，
## 也不会有人新增提示时忘了记。
func flash(text: String) -> void:
	_toast.text = text
	_toast_left = TOAST_SECONDS
	_append_log(text)


## 操作说明浮层（由应用栏的「?」开关）。两块浮层都锚在右上角，同时开会叠在一起 ——
## 开一块就关另一块（应用栏那个按钮由 App 负责弹起，见 QVoxelierApp._set_legend_visible）。
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


## 日志内容（只读，按时间从旧到新）。给"复制日志"这类导出用，也让测试不必伸手掏私有字段。
func log_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for c in _log_list.get_children():
		out.append((c as Label).text)
	return out


# ----------------------------------------------------------------------------
# 界面
# ----------------------------------------------------------------------------

func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_status()
	_build_toast()
	_build_legend()
	_build_log()


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
	# 选区排在读数区最前：它是"接下来那一下会作用在哪"，比"光标在哪一格"更需要一眼看到。
	_selection = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT_FAINT)
	row.add_child(_selection)
	_cursor = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_cursor)
	_brush = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_brush)
	_material = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT)
	row.add_child(_material)
	_model = _readout(QVoxelUi.FONT_M, QVoxelUi.TEXT_DIM)
	row.add_child(_model)
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


## 日志浮层：与说明浮层并列（同样锚右上、同样默认隐藏），区别是**内容会增长**，故带滚动与清空。
##
## 【为什么不塞进右侧抽屉当第六组】抽屉里的组是"对工程做什么"（颜色 / 层级 / 修改器 / 时间轴），
## 而日志是"刚才发生了什么"—— 它与瞬时提示、操作说明同属"视口的回话"，放在视口这一层才连贯；
## 而且它多半在出错之后才被打开，那时用户的眼睛本来就在视口上。
func _build_log() -> void:
	_log = QVoxelUi.panel(QVoxelUi.space_m(), QVoxelUi.SURFACE_SOLID)
	_log.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_log.offset_right = -QVoxelUi.space_m()
	_log.offset_left = -LOG_WIDTH - QVoxelUi.space_m()
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


## 追加一行：新行在底部（时间从上往下读），并**有界**（只留最近 LOG_MAX 行）。
##
## 【为什么在 Label 上开自动换行】浮层宽固定（长消息不该把面板撑到半个屏幕），
## 若改成截断，则"失败原因"最关键的尾巴会被吃掉 —— 日志的价值恰恰在那后半句。
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
	_scroll_to_bottom.call_deferred()


## 滚到底。**延到帧末**：刚 add_child 的行还没参与布局，当场写 scroll_vertical 会被随后的
## 布局改回去（表现为"新行在下面看不见"）。
func _scroll_to_bottom() -> void:
	if _log_scroll == null:
		return
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


## 说明文案：**两套操作形态并列**，因为同一套界面上平板与鼠标的动作名字不同。
## 改输入约定时改这里一处（工具级的提示在 QVoxelBrushTool.MODES 里，两处各管一层）。
const _LEGEND := [
	["鼠标 + 键盘", [
		"左键拖动 画 · 右键 擦（或开左侧「擦除」）",
		"中键拖动 转视角 · Shift+中键 平移 · 滚轮 缩放 · Home 取景",
		"V/F/B/L/C 切工具 · T 选择 · M 移动 · E 擦除 · [ ] 改笔刷 · 1..8 选材质",
		"Ctrl+Z 撤销 · Ctrl+Shift+Z 重做 · Esc 取消这一笔 / 退掉选区",
		"Ctrl+A 全选 · Ctrl+C/X/V 复制 / 剪切 / 粘贴 · Del 清空选区",
		"Ctrl+S 保存 · Ctrl+Shift+S 另存 · Ctrl+O 打开（.qvx 可直接拖进窗口）",
		"Ctrl+E 导出 .vox（MagicaVoxel 等外部工具可打开）",
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
