@tool
class_name QVoxelierDock
extends QVoxelierPanel
## 右侧抽屉 —— 顶部一排**页签**（颜色 / 层级 / 参数 / 时间轴 / 快照），一次只显示一组。
## 【为什么是页签而不是竖着堆的折叠组】五组竖堆时，收起留下的一排抬头 + 组间空隙全是白地，
## 展开又要占满整列 —— 纵向空间怎么分都不划算。页签把"选哪组"和"看哪组"合成一行宽度，
## 于是任何时刻只画一组，右列高度随当前组自适应（Blender 的 Properties 页签、PS 的面板组同思路）。
## 【为什么贴右上】左上与底部都已占（工具坞 / 视图栏 / 调色板 / 朝向指示器）。
## 右上还顺带贴着"应用栏"的下沿，于是纵向只有一条连续的面板带，视线不必来回横跳。
## 【宽度随密度档】触摸档要更宽（滑块更好点、文字更大），桌面档收窄把视口让出来。

var _root: VBoxContainer
var _tabs: HBoxContainer
var _scroll: ScrollContainer
var _col: VBoxContainer
var _group := ButtonGroup.new()
var _sections: Array[QVoxelierSection] = []
var _buttons: Array[Button] = []
var _active := -1


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = -QVoxelUi.space_m()
	offset_top = QVoxelUi.bar_height() + QVoxelUi.space_m()
	var w := float(QVoxelUi.dock_width()) + QVoxelUi.space_l()
	offset_left = offset_right - w

	# 根竖排：页签条固定在顶，下面一条可滚动的组内容。本控件不是容器，故显式让它填满我
	# （矩形由 _fit 写回：调试器/自动化工具要读到真实尺寸）。
	_root = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_group.allow_unpress = false   # 页签永远有一个是"当前"，不允许点成"全都没选"
	_tabs = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_root.add_child(_tabs)

	_scroll = QVoxelUi.scroll(true)
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_scroll)

	_col = QVoxelUi.vbox(QVoxelUi.space_s())
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_col)
	# 高度 = min(内容, 可用高度)：内容短时贴着内容，内容长时定高并在其中滚动。
	# 本控件（它的矩形会被调试器/自动化工具读到）因此始终如实反映画出来的东西。
	_col.resized.connect(_fit)
	_tabs.resized.connect(_on_tabs_resized)
	get_viewport().size_changed.connect(_fit)


## 右列的矩形：高度 = min(页签高 + 当前组内容高, 可用高度)；宽度 = 所有组 / 页签里最宽的那个。
## 【高度】可用高度 = 视口高 − 顶边位置 − 底部状态栏 − 一点边距（状态栏是全局栏，不该被盖住）。
## 【宽度为什么取"所有组"的最宽】切页签时若宽度跟着当前组变，右列与视口会一起横向弹跳；
## 取最大宽度让右列在整个会话里稳定。页签条本身也要算进去，否则页签会被裁掉右半。
func _fit() -> void:
	if _col == null:
		return
	var inner := _col.get_combined_minimum_size()
	var want_w := maxf(inner.x, _tabs.get_combined_minimum_size().x)
	for s in _sections:
		want_w = maxf(want_w, s.custom_minimum_size.x)
	var tabs_h := _tabs.get_combined_minimum_size().y + QVoxelUi.SPACE_XS
	var avail := get_viewport_rect().size.y - offset_top - QVoxelUi.status_height() - QVoxelUi.space_s()
	offset_bottom = offset_top + maxf(0.0, minf(tabs_h + inner.y, avail))
	offset_left = offset_right - maxf(float(QVoxelUi.dock_width()) + QVoxelUi.space_l(), want_w)


func _on_tabs_resized() -> void:
	_fit()


## 追加一组页签（**只在 App 装配时调用**，顺序即页签顺序）。
## 第二参数保留以兼容调用方，页签模式下不再有"一进来先收起"这回事。
func add_section(s: QVoxelierSection, _collapsed := false) -> void:
	_col.add_child(s)
	# 抬头收进页签：组自己的 ▾ 标题与页签重复，隐藏它。
	s.set_header_visible(false)
	var idx := _sections.size()
	_sections.append(s)

	var b := QVoxelUi.toggle_button(s.section_title(),
			QVoxelUi.VARIATION_TOOL, s.section_title())
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.button_group = _group
	b.toggled.connect(func(on: bool): if on: _select(idx))
	_tabs.add_child(b)
	_buttons.append(b)

	if _active < 0:
		_select(idx)
	else:
		s.visible = false
	_fit()


func _select(idx: int) -> void:
	if idx < 0 or idx >= _sections.size():
		return
	_active = idx
	for i in _sections.size():
		_sections[i].visible = i == idx
	if idx < _buttons.size():
		_buttons[idx].set_pressed_no_signal(true)
	_fit()
