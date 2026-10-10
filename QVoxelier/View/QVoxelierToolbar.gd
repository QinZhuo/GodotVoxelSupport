@tool
class_name QVoxelierToolbar
extends QVoxelierPanel
## 顶部应用栏 —— 文件 / 历史 / 视图三组操作，**每一件都有按钮**。
## 【为什么必须有按钮】桌面用户习惯 Ctrl+S / Ctrl+Z / 中键转视角，但本应用要同时跑在
## 平板上：那里没有键盘、没有中键、没有滚轮。于是快捷键在本项目里的定位降级为
## **加速器**而不是入口 —— 按钮才是唯一入口，快捷键只让熟练用户少点两下。
## 三处针对触摸的补位：中键转视角 → [导航] 模式开关；滚轮缩放 → [−]/[+]；Home 取景 → [取景]。
## 【为什么工程名在文件组之后】它是"我在编辑什么 + 改没改"的唯一常驻回答（未落盘时染强调色并带 *）。
## 贴着文件组左对齐，读起来像标题；居中会在两侧各留一大片空白，反而像浮在半空。它右侧用一段
## 弹性空白把历史 / 视图两组推到右端 —— 中间的空白因此是"有意的分组间隔"。
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
## 缩放（steps > 0 拉近）—— 触摸下的"滚轮"替代品。
signal zoom_requested(steps: float)
## 镜头切换（true = 正交）。原在视口左下的「视图栏」，随该栏一并移入顶栏。
signal lens_toggled(ortho: bool)
## 网格线显隐。
signal grid_lines_toggled(enabled: bool)
## 帮助（快捷键与手势一览）开关。
signal help_toggled(enabled: bool)
## 日志（刚才发生了什么）开关。
signal log_toggled(enabled: bool)

var _project: Label
var _undo: Button
var _redo: Button
var _lens: Button
var _grid: Button
var _help: Button
var _log: Button
## 尚无文件名时的占位。**是"未命名"的唯一来源**：Label 初值留空，由 _sync_project 统一填。
var _project_name := "未命名"
var _project_dirty := false


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

	# ── 文件组 ──（顶栏是屏幕顶上一条 40px 的带，一屏里要放下十余件操作 ——
	# 文字版实测把工程名挤到看不见，故只留图标，名字与快捷键交给悬浮提示）
	row.add_child(_action(new_requested.emit, "", "new"))
	row.add_child(_action(open_requested.emit, "打开（Ctrl+O）\n打开 .qvx 工程，也可以直接把文件拖进窗口",
			"open"))
	# 保存是主操作：整条栏里唯一带强调描边与强调字的按钮（样式见 QVoxelUi.VARIATION_ACCENT）。
	row.add_child(_action(save_requested.emit, "保存（Ctrl+S）\n存成 .qvx 工程（保留修改器链与相机）",
			"save", QVoxelUi.VARIATION_ACCENT))
	row.add_child(_action(save_as_requested.emit, "另存（Ctrl+Shift+S）\n另存为新文件", "save_as"))
	row.add_child(_action(export_requested.emit, "导出（Ctrl+E）\n导出为 MagicaVoxel 的 .vox，其它体素工具都能打开",
			"export"))
	row.add_child(_action(export_batch_requested.emit, "批量导出\n按范围一次产出多个 .vox：整个世界 / 每个节点 / 每个模型 / 每个帧",
			"batch"))

	_project = QVoxelUi.label("", QVoxelUi.FONT_M, QVoxelUi.TEXT_DIM)
	# 左对齐贴着文件组，而不是居中悬在空档里 —— 居中会让两侧各留一大片空白，读起来像"浮"着。
	_project.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_project.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 窄屏（竖起来的平板）先压缩的应该是名字，不是按钮 —— 按钮被裁掉就没法点，名字被裁掉只是难看。
	_project.clip_text = true
	_project.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# clip_text 的 Label 最小宽为 0，不给下限会被右侧弹性空白压成 1px（名字整段看不见）。
	_project.custom_minimum_size.x = 140
	row.add_child(_project)

	# 名字之后放一段弹性空白，把历史 / 视图两组推到右端；中间的空白因此是"有意的分组间隔"，
	# 而不是居中的名字把空间劈成两半。
	row.add_child(QVoxelUi.spacer())

	# ── 历史组 ──
	_undo = _action(undo_requested.emit, "撤销（Ctrl+Z）\n撤回上一步改动", "undo")
	_redo = _action(redo_requested.emit, "重做（Ctrl+Shift+Z）\n恢复刚撤销的一步", "redo")
	row.add_child(_undo)
	row.add_child(_redo)

	# 历史与视图是两类东西（改数据 / 只看不改），隔一条线比让它们连成一片好读。
	# 左侧不再加线：居中的工程名本身就是文件组与历史组之间的分隔。
	row.add_child(QVoxelUi.vdivider())
	row.add_child(_view_group())
	_sync_project()


## 视图组：取景 / 缩放 / 镜头 / 网格线。旋转与平移改由手势驱动（空白处拖动 / 中键 / 双指），
## 故不再有"导航 / 平移"模式开关 —— 顶栏这一组因此清爽许多。
func _view_group() -> HBoxContainer:
	var g := QVoxelUi.hbox(QVoxelUi.SPACE_XS)

	g.add_child(_action(frame_requested.emit, "取景（Home）\n把模型正好框进画面", "fit"))
	g.add_child(_action(func(): zoom_requested.emit(-1.0), "缩小\n配合＋调整视距", "zoom_out"))
	g.add_child(_action(func(): zoom_requested.emit(1.0), "放大\n配合－调整视距", "zoom_in"))

	# 镜头与网格线：原先在视口左下的「视图栏」里，现并到顶栏的视图组 ——
	# 标准视角交给右下角坐标系（点轴切换），这里只留这两件坐标系给不了的开关。
	_lens = _action(func(): pass, "正交 / 透视（小键盘 5）\n正交没有近大远小，量比例、对齐体素用", "lens_persp",
			QVoxelUi.VARIATION_TOOL)
	_lens.toggle_mode = true
	_lens.toggled.connect(func(on: bool): lens_toggled.emit(on))
	g.add_child(_lens)

	_grid = _action(func(): pass, "网格线\n显示底面格线；关掉只剩外框，便于看清形状", "grid",
			QVoxelUi.VARIATION_TOOL)
	_grid.toggle_mode = true
	_grid.set_pressed_no_signal(true)
	_grid.toggled.connect(func(on: bool): grid_lines_toggled.emit(on))
	g.add_child(_grid)

	_help = _action(func(): pass, "操作说明\n鼠标与触摸的全部操作一览", "help",
			QVoxelUi.VARIATION_TOOL)
	_help.toggle_mode = true
	_help.toggled.connect(func(on: bool): help_toggled.emit(on))
	g.add_child(_help)

	# 日志与说明并列在栏尾：两者都是"查一下"（都不改数据），也都开在右上角的浮层里。
	_log = _action(func(): pass, "操作日志\n刚才发生了什么 —— 导入 / 导出 / 求值失败的原因都在这里",
			"log", QVoxelUi.VARIATION_TOOL)
	_log.toggle_mode = true
	_log.toggled.connect(func(on: bool): log_toggled.emit(on))
	g.add_child(_log)
	return g


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


func set_help(on: bool) -> void:
	_help.set_pressed_no_signal(on)


func set_log(on: bool) -> void:
	_log.set_pressed_no_signal(on)


## 回显镜头（按下态 + 图标随透视/正交切换）。正交描边下用方形镜头图标更直观。
func set_lens(ortho: bool) -> void:
	if _lens == null:
		return
	_lens.set_pressed_no_signal(ortho)
	var g := QVoxelUi.icon("lens_ortho" if ortho else "lens_persp")
	if g != null:
		_lens.icon = g


func set_grid_lines(on: bool) -> void:
	if _grid != null:
		_grid.set_pressed_no_signal(on)


# 内部

## 应用栏按钮的统一形态：图标 + 提示 + 回调，命中高度顶满整条栏。
## 命中区**双向钉死**在 hit_size × 栏高：图标只画 24px，按内容算的按钮对手指太小；
## 钉住下限后所有栏内按钮都是 ≥44×44 的可点面，也不会因图标 / 文字切换而宽窄跳动。
## 文字取提示首行并截掉"（快捷键）"——只在图标加载失败时才露出来（QVoxelUi.button 的约定）。
func _action(cb: Callable, tooltip: String, icon_name: String, variation := &"") -> Button:
	var fallback := tooltip.get_slice("\n", 0).get_slice("（", 0)
	var b := QVoxelUi.button(fallback, tooltip, variation, icon_name)
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
