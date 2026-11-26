@tool
class_name QVoxelierDock
extends QVoxelierPanel
## 右侧抽屉 —— **上：属性（单页，随选中自动切换） / 下：层级（Outliner，常驻）**。

## 上下两半的容器：`VSplitContainer`（引擎自带拖动条）。
var _root: VSplitContainer
var _prop_scroll: ScrollContainer
var _prop_host: VBoxContainer
var _out_scroll: ScrollContainer
var _out_host: VBoxContainer
var _prop_sections: Array[QVoxelierSection] = []
var _active := -1
## 底部让位高度（动画面板展开时它占住窗口下方，右列要缩短）。
var bottom_reserved := 0.0

func _build() -> void:
	# 贴窗口右缘、上下贯通 —— 这一列**自己就是**右侧栏，外面不再套底板。
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = 0.0
	offset_top = QVoxelUi.bar_height()
	offset_left = offset_right - float(QVoxelUi.dock_width())

	# 整列**一块背景**（各分组自己不再带背景），中间一条分割线把"层级 / 属性"两半分开。
	var bg := PanelContainer.new()
	bg.add_theme_stylebox_override("panel", QVoxelUi.side_panel(SIDE_RIGHT, QVoxelUi.space_s()))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_root = VSplitContainer.new()
	_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bg.add_child(_root)

	# 上：层级。
	_out_scroll = QVoxelUi.scroll(true)
	_out_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_out_scroll)
	_out_host = QVoxelUi.vbox(QVoxelUi.space_s())
	_out_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_out_scroll.add_child(_out_host)

	# 下：属性（随选中自动切换）。
	_prop_scroll = QVoxelUi.scroll(true)
	_prop_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_prop_scroll)
	_prop_host = QVoxelUi.vbox(QVoxelUi.space_s())
	_prop_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prop_scroll.add_child(_prop_host)

	_prop_host.resized.connect(_fit)
	_out_host.resized.connect(_fit)
	get_viewport().size_changed.connect(_fit)

## 右列矩形：纵向吃满可用高度（上到下都贴住邻居），横向取所有组里最宽的。
func _fit() -> void:
	if _root == null:
		return
	var avail := get_viewport_rect().size.y - offset_top - QVoxelUi.status_height() - bottom_reserved
	offset_bottom = offset_top + maxf(avail, 120.0)
	var want_w := 0.0
	for s in _prop_sections:
		want_w = maxf(want_w, s.custom_minimum_size.x)
	for c in _out_host.get_children():
		if c is QVoxelierSection:
			want_w = maxf(want_w, (c as QVoxelierSection).custom_minimum_size.x)
	# 宽度：用户拖过就以拖的为准（拖窄了内容会被横向裁掉，那是他自己的选择）；
	var target := float(QVoxelUi.dock_width())
	if not QVoxelUi.dock_width_custom():
		target = maxf(target, want_w)
	offset_left = offset_right - target

## 外部改了目标宽度（拖动条拖过）之后重排一次。
func refit() -> void:
	_fit()

## 追加一个**属性页**组（只在装配时调用）。
func add_property(s: QVoxelierSection) -> void:
	_prop_host.add_child(s)
	# 必须在 add_child 之后 —— 组自己的面板是在 _ready（add_child 触发）里建出来的。
	s.set_flat(true)
	_prop_sections.append(s)
	if _active < 0:
		show_property(s)
	else:
		s.visible = false
	_fit()

## 追加一个**常驻**的层级组（Outliner）。
func add_outliner(s: QVoxelierSection) -> void:
	_out_host.add_child(s)
	s.set_flat(true)
	_fit()

func show_property(s: QVoxelierSection) -> void:
	var idx := _prop_sections.find(s)
	if idx < 0:
		return
	_active = idx
	for i in _prop_sections.size():
		_prop_sections[i].visible = i == idx
	_fit()

## 按标题切属性页（App 在"选择了材质 / 节点 / 修改器"时调用，实现自动切换）。
func show_property_by_title(title: String) -> void:
	for s in _prop_sections:
		if s.section_title() == title:
			show_property(s)
			return

## 层级分组（QVoxelierTreeSection）的宿主容器 —— App 在动画面板展开 / 收起时搬进 / 搬出。
func outliner_host() -> VBoxContainer:
	return _out_host

## 底部让位（动画面板高度）。
func set_bottom_reserved(h: float) -> void:
	if is_equal_approx(h, bottom_reserved):
		return
	bottom_reserved = h
	_fit()
