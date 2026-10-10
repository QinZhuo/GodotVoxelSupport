@tool
class_name QVoxelierToolbar
extends QVoxelierPanel
## 顶部应用栏 —— 文件 / 历史 / 视图三组操作，**每一件都有按钮**。
## 【为什么必须有按钮】桌面用户习惯 Ctrl+S / Ctrl+Z / 中键转视角，但本应用要同时跑在
## 平板上：那里没有键盘、没有中键、没有滚轮。于是快捷键在本项目里的定位降级为
## **加速器**而不是入口 —— 按钮才是唯一入口，快捷键只让熟练用户少点两下。
## 三处针对触摸的补位：中键转视角 → [导航] 模式开关；滚轮缩放 → [−]/[+]；Home 取景 → [取景]。
## 【为什么工程名在正中】它是"我在编辑什么 + 改没改"的唯一常驻回答（未落盘时染强调色并带 *）。
## 放中间读起来最省眼，也正好把两侧的按钮组隔开，省掉一条竖分隔线。
## 【为什么用 HUD 层】它常驻、不参与 back()：按 Esc 该取消的是这一笔，不是把工具栏关掉。

signal new_requested
signal open_requested
signal save_requested
signal save_as_requested
## 导出成别的工具能读的格式（当前只有 `.vox`）。**与"保存"分开**：保存是"下次还能接着编辑"
## （.qvx，含修改器链 / 材质 PBR / 相机），导出是"拿去用"（.vox，只剩烘出来的体素与调色板）。
## 两件事的产物与失败原因都不同，合成一个按钮会让用户在"我到底存的是哪个"上犹豫。
signal export_requested
## 批量导出：按"范围"（整个世界 / 每个节点 / 每个模型 / 每个帧）一次产出多个 `.vox`。
## 与"导出"分开而不是并进同一个按钮：单次导出是"挑个文件存下来"（一次交互、一个文件），
## 批量是"挑个目录 + 挑范围 + 起前缀"（参数更多、产出多个），混在一起会让单次那件最常用的事
## 每次都要先回答"我要不要批量"。
signal export_batch_requested
signal undo_requested
signal redo_requested
signal frame_requested
## 视图模式变了（取值见 VIEW_* 常量）。
## 触摸屏没有中键、也没有 Shift+中键，导航 / 平移两个开关就是它们的替代品。
## 发一个"模式"而不是两个布尔，因为它们本就互斥 —— 发两个布尔，调用方还得自己保证不同时为真。
signal view_mode_changed(mode: int)
## 缩放（steps > 0 拉近）—— 触摸下的"滚轮"替代品。
signal zoom_requested(steps: float)
## 帮助（快捷键与手势一览）开关。
signal help_toggled(enabled: bool)
## 日志（刚才发生了什么）开关。
signal log_toggled(enabled: bool)

## 视图模式取值。定义在界面这一层：它是"界面提供给用户的一种操作姿态"，不是算法概念 ——
## 换成 Dock 内嵌视口时它依然成立（两种形态下鼠标中键都可用，触摸屏则都只能靠这个开关）。
const VIEW_PAINT := 0
const VIEW_ORBIT := 1
const VIEW_PAN := 2

var _project: Label
var _undo: Button
var _redo: Button
var _nav: Button
var _pan: Button
var _help: Button
var _log: Button
## 尚无文件名时的占位。**是"未命名"的唯一来源**：Label 初值留空，由 _sync_project 统一填。
var _project_name := "未命名"
var _project_dirty := false
var _view := VIEW_PAINT


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = QVoxelUi.bar_height()

	# 应用栏贴屏幕顶边，故圆角留空、只做上下的层次（描边留给左右两侧的浮层面板）。
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
			QVoxelUi.box(QVoxelUi.BAR, Color(0, 0, 0, 0), 0, 0, QVoxelUi.space_m(), 0))
	# 非容器父节点下的子控件不会自动撑满：不写这一句，栏底只会包住按钮那一段宽度，
	# 而工程名（靠 EXPAND_FILL 抢剩余空间）会因为没有剩余空间被压成 1 像素宽 —— 看不见。
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bar)

	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	bar.add_child(row)

	# ── 文件组 ──
	row.add_child(_action("新建", "清空并新建一个模型", func(): new_requested.emit()))
	row.add_child(_action("打开", "打开一个 .qvx 工程（也可直接把文件拖进窗口）",
			func(): open_requested.emit()))
	# 保存是主操作：整条栏里唯一带强调描边与强调字的按钮（样式见 QVoxelUi.VARIATION_ACCENT）。
	row.add_child(_action("保存", "保存工程（Ctrl+S）", func(): save_requested.emit(),
			QVoxelUi.VARIATION_ACCENT))
	row.add_child(_action("另存", "另存为新文件（Ctrl+Shift+S）", func(): save_as_requested.emit()))
	row.add_child(_action("导出", "导出为 MagicaVoxel 的 .vox（其它体素工具都能打开）",
			func(): export_requested.emit()))
	row.add_child(_action("批量", "一次导出多个 .vox：按范围切开（整个世界 / 每个节点 / 每个模型 / 每个帧）",
			func(): export_batch_requested.emit()))

	_project = QVoxelUi.label("", QVoxelUi.FONT_M, QVoxelUi.TEXT_DIM)
	_project.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_project.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_project.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 窄屏（竖起来的平板）先压缩的应该是名字，不是按钮 —— 按钮被裁掉就没法点，名字被裁掉只是难看。
	_project.clip_text = true
	_project.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_project)

	# ── 历史组 ──
	_undo = _action("撤销", "撤销上一步（Ctrl+Z）", func(): undo_requested.emit())
	_redo = _action("重做", "重做（Ctrl+Shift+Z）", func(): redo_requested.emit())
	row.add_child(_undo)
	row.add_child(_redo)

	# 历史与视图是两类东西（改数据 / 只看不改），隔一条线比让它们连成一片好读。
	# 左侧不再加线：居中的工程名本身就是文件组与历史组之间的分隔。
	row.add_child(QVoxelUi.vdivider())
	row.add_child(_view_group())
	_sync_project()


## 视图组：导航 / 取景 / 缩放。触摸屏上这三件分别顶替中键、Home 键与滚轮。
func _view_group() -> HBoxContainer:
	var g := QVoxelUi.hbox(QVoxelUi.SPACE_XS)

	# 导航 / 平移同组互斥，且允许"再按一次取消" —— 于是"不用视角工具"也是一个能走到的状态，
	# 不必为它再加第三个按钮。
	var group := ButtonGroup.new()
	group.allow_unpress = true
	_nav = _mode_toggle("导航", "单指 / 左键拖动 = 转视角（触摸屏上代替中键）", group, VIEW_ORBIT)
	_pan = _mode_toggle("平移", "单指 / 左键拖动 = 平移画面（触摸屏上代替 Shift+中键）", group, VIEW_PAN)
	g.add_child(_nav)
	g.add_child(_pan)

	g.add_child(_action("取景", "把模型正好框进画面（Home）", func(): frame_requested.emit()))
	g.add_child(_action("−", "缩小", func(): zoom_requested.emit(-1.0)))
	g.add_child(_action("+", "放大", func(): zoom_requested.emit(1.0)))

	_help = _action("?", "查看鼠标与触摸的操作说明", func(): pass, QVoxelUi.VARIATION_TOOL)
	_help.toggle_mode = true
	_help.toggled.connect(func(on: bool): help_toggled.emit(on))
	g.add_child(_help)

	# 日志与说明并列在栏尾：两者都是"查一下"（都不改数据），也都开在右上角的浮层里。
	_log = _action("日志", "刚才发生了什么 —— 导入 / 导出 / 求值失败的原因都在这里",
			func(): pass, QVoxelUi.VARIATION_TOOL)
	_log.toggle_mode = true
	_log.toggled.connect(func(on: bool): log_toggled.emit(on))
	g.add_child(_log)
	return g


## 视图模式开关：同组的按钮彼此互斥（含"全都不按 = 绘制"）。
func _mode_toggle(text: String, tooltip: String, group: ButtonGroup, mode: int) -> Button:
	var b := _action(text, tooltip, func(): pass, QVoxelUi.VARIATION_TOOL)
	b.toggle_mode = true
	b.button_group = group
	b.toggled.connect(func(_on: bool): _emit_view_mode.call_deferred())
	return b


## 延到帧末再读状态：同组按钮切换时是"旧的先弹起、新的再按下"两次信号，
## 当场读会读到中间的空白态并多发一次 VIEW_PAINT（表现为提示闪一下"回绘制"）。
## 攒到帧末只读一次终态，恰好也是 App 需要的语义。
func _emit_view_mode() -> void:
	var m := view_mode()
	if m != _view:
		_view = m
		view_mode_changed.emit(m)


# 对外：状态同步（只由 App 调用）

## 工程名 + 是否有未落盘改动。改动时染强调色 —— 关窗前扫一眼就知道该不该存。
func set_project(file_name: String, dirty: bool) -> void:
	_project_name = file_name
	_project_dirty = dirty
	_sync_project()


## 撤销 / 重做可用性。禁用而不是隐藏：按钮位置固定，用户不必到处找。
func set_history(can_undo: bool, can_redo: bool) -> void:
	_undo.disabled = not can_undo
	_redo.disabled = not can_redo


## 视图模式的**显示**（Esc 关掉说明、或程序化复位时同步用）。不回发信号，避免自激。
func set_view_mode(mode: int) -> void:
	_view = mode
	_nav.set_pressed_no_signal(mode == VIEW_ORBIT)
	_pan.set_pressed_no_signal(mode == VIEW_PAN)


func view_mode() -> int:
	if _nav.button_pressed:
		return VIEW_ORBIT
	if _pan.button_pressed:
		return VIEW_PAN
	return VIEW_PAINT


func set_help(on: bool) -> void:
	_help.set_pressed_no_signal(on)


func set_log(on: bool) -> void:
	_log.set_pressed_no_signal(on)


# 内部

## 应用栏按钮的统一形态：文字 + 提示 + 回调，命中高度顶满整条栏。
## 宽度也钉在 MIN_TOUCH 以上 —— "−/+/?" 这类单字按钮若按文字宽度算只有 22~32 像素，
## 鼠标够用、手指却点不准；钉住下限后所有栏内按钮都是 ≥44×44 的可点面。
func _action(text: String, tooltip: String, cb: Callable, variation := &"") -> Button:
	var b := QVoxelUi.button(text, tooltip, variation)
	b.custom_minimum_size = Vector2(QVoxelUi.hit_size(), QVoxelUi.bar_height() - QVoxelUi.space_s())
	b.pressed.connect(cb)
	return b




func _sync_project() -> void:
	if _project == null:
		return
	_project.text = "%s%s" % [_project_name, "  *" if _project_dirty else ""]
	# 常态用正文色而不是弱色：它是这条栏上唯一"是什么"的信息，此前弱色让它读起来像占位符。
	# 变脏才升到强调色 —— 于是强调色仍然只承担"状态"这一件事。
	_project.add_theme_color_override("font_color",
			QVoxelUi.ACCENT if _project_dirty else QVoxelUi.TEXT)
