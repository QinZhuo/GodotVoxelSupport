@tool
class_name QVoxelierSection
extends QVoxelierPanel
## 右侧抽屉里的一段**分组**：抬头一行（小标题）+ 内容。

var _header: Label
var _body: VBoxContainer
var _panel: PanelContainer
var _want_w := 0.0   # 本组内容想要的宽度（只增不减，见 _measure）
var _fill := false   # 面板是否铺满自身矩形（层级展开成底部时间轴时用）

## 子类重写：分组标题（抬头文字）。
func section_title() -> String:
	return "分组"

## 子类重写：往 body 里填内容（此时主题、层级、抬头都已就绪）。
func _build_body(_body: VBoxContainer) -> void:
	pass

## body 容器（子类需要动态增删内容时用）。
func content() -> VBoxContainer:
	return _body

## 隐藏自带抬头（抽屉用别的标题承载时，抬头重复，就把它藏掉）。
func set_header_visible(on: bool) -> void:
	if _header != null:
		_header.visible = on
	if _body != null:
		_body.visible = true

## 让面板铺满自身矩形（层级展开成底部时间轴时用）：面板改为 FULL_RECT，不再按内容定高。
func set_panel_fill(on: bool) -> void:
	_fill = on
	if _panel == null:
		return
	_panel.set_anchors_and_offsets_preset(
			Control.PRESET_FULL_RECT if on else Control.PRESET_TOP_WIDE)

## 去掉本组自己的背景 / 描边（整列统一一块背景时用，组只留内容）。
func set_flat(on: bool) -> void:
	if _panel == null:
		return
	if on:
		_panel.add_theme_stylebox_override("panel",
				QVoxelUi.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0,
						QVoxelUi.space_s(), QVoxelUi.space_s()))
	else:
		_panel.add_theme_stylebox_override("panel",
				QVoxelUi.box(QVoxelUi.SURFACE, QVoxelUi.BORDER, 1, QVoxelUi.RADIUS_M,
						QVoxelUi.space_s(), QVoxelUi.space_s()))

func _build() -> void:
	_panel = QVoxelUi.panel(QVoxelUi.space_s())
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(_panel)
	# 本控件通常是 VBoxContainer 的孩子 —— 容器会覆盖 size，故"我有多高 / 多宽"要用
	_panel.resized.connect(func():
		_measure()
		if not _fill:
			custom_minimum_size.y = _panel.size.y)

	var col := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_panel.add_child(col)

	# 抬头是纯小标题（不可点、不折叠）。
	_header = QVoxelUi.heading(section_title())
	col.add_child(_header)

	_body = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	col.add_child(_body)

	_refresh()
	_build_body(_body)
	_measure()

## 记下内容想要的宽度并报给父容器（抽屉按它定右列的宽度）。
func _measure() -> void:
	if _panel == null or _body == null:
		return
	var pad := QVoxelUi.space_s() * 2.0
	var sb := _panel.get_theme_stylebox("panel")
	if sb != null:
		pad = sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)
	var want := _body.get_combined_minimum_size().x + pad
	if _header != null:
		want = maxf(want, _header.get_combined_minimum_size().x + pad)
	_want_w = maxf(_want_w, want)
	custom_minimum_size.x = _want_w

## 清掉"只增不减"的记忆，让下次 _measure 重新按当前内容量宽（动画轴展开 / 收起这类
func reset_measure() -> void:
	_want_w = 0.0

func _refresh() -> void:
	if _header == null:
		return
	_header.text = section_title()
	if _body != null:
		_body.visible = true
