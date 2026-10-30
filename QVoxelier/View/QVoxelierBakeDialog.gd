@tool
class_name QVoxelierBakeDialog
extends PopupPanel
## 把当前骨骼/摆放动画烘焙成体素帧的选项弹窗。
## 【为什么是弹窗而不是常驻面板】烘焙是一次性动作，参数也只在这一刻有意义；
## 常驻会白占右列空间，而这个项目的右列已经排满。
## 【选项只描述"怎么烘"，不碰数据】真正写生在 App 里调用 QVoxelRigBaker，
## 本类只负责把用户选择收成一个 options 字典。

signal bake_requested(root: QVoxelNode, options: Dictionary)

var _root: QVoxelNode = null
var _root_label: Label
var _step: OptionButton
var _fps: SpinBox
var _padding: SpinBox
var _gaps: CheckBox
var _gap_need: SpinBox
var _hidden: CheckBox
var _root_motion: CheckBox
var _hide_source: CheckBox
var _name: LineEdit


func _ready() -> void:
	theme = QVoxelUi.theme()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var box := QVoxelUi.vbox(QVoxelUi.space_s())
	box.custom_minimum_size.x = 380
	margin.add_child(box)
	box.add_child(QVoxelUi.heading("烘焙体素帧"))
	_root_label = QVoxelUi.label("", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	box.add_child(_root_label)

	_step = OptionButton.new()
	_step.add_item("每帧（on ones）", 1)
	_step.add_item("每 2 帧（on twos）", 2)
	_step.add_item("每 3 帧（on threes）", 3)
	box.add_child(_row("采样", _step))

	_fps = _spin(1, 60, 1, 12)
	box.add_child(_row("源帧率", _fps))

	_padding = _spin(0, 8, 1, 1)
	box.add_child(_row("四周留白", _padding))

	_gaps = CheckBox.new()
	_gaps.text = "关节补洞"
	_gaps.tooltip_text = "空格 6 邻域达到阈值的用多数材质填上，减少旋转后的缝隙"
	_gaps.button_pressed = true
	_gaps.toggled.connect(func(on: bool): _gap_need.editable = on)
	box.add_child(_gaps)

	_gap_need = _spin(1, 6, 1, 3)
	box.add_child(_row("补洞阈值", _gap_need))

	_hidden = CheckBox.new()
	_hidden.text = "包含隐藏模型"
	box.add_child(_hidden)

	_root_motion = CheckBox.new()
	_root_motion.text = "根节点运动也烘进体素"
	_root_motion.tooltip_text = "默认开启：运行时不消费组的 transform_tracks，留在节点上的运动会丢。\n只有运行时会自己驱动根节点时才取消。"
	_root_motion.button_pressed = true
	box.add_child(_root_motion)

	_hide_source = CheckBox.new()
	_hide_source.text = "烘焙后隐藏源 rig"
	_hide_source.tooltip_text = "避免源模型和烘焙结果重叠；隐藏的节点不会进入运行时导入"
	_hide_source.button_pressed = true
	box.add_child(_hide_source)

	_name = QVoxelUi.text_field("Baked", "Baked", "烘焙产物名")
	box.add_child(_row("名称", _name))

	var buttons := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(buttons)
	var cancel := QVoxelUi.button("取消", "关闭，不烘焙")
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(hide)
	buttons.add_child(cancel)
	var bake := QVoxelUi.button("烘焙", "把当前动画采样成 ANIM 体素帧",
			QVoxelUi.VARIATION_ACCENT)
	bake.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake.pressed.connect(_emit)
	buttons.add_child(bake)


## 打开弹窗并回显默认值。root 为空时禁用烘焙。
func open(root: QVoxelNode, defaults: Dictionary = {}) -> void:
	_root = root
	_root_label.text = "烘焙根：%s" % (root.display_name() if root != null else "（未选择）")
	_step.select(_step.get_item_index(int(defaults.get("frame_step", 1))))
	_fps.value = float(defaults.get("source_fps", 12))
	_padding.value = float(defaults.get("padding", 1))
	_gaps.button_pressed = bool(defaults.get("fill_gaps", true))
	_gap_need.value = float(defaults.get("gap_min_neighbors", 3))
	_gap_need.editable = _gaps.button_pressed
	_hidden.button_pressed = bool(defaults.get("include_hidden", false))
	_root_motion.button_pressed = not bool(defaults.get("exclude_root_motion", false))
	_hide_source.button_pressed = bool(defaults.get("hide_source", true))
	_name.text = str(defaults.get("name", "Baked"))
	popup_centered(Vector2i(420, 0))


func _emit() -> void:
	if _root == null:
		return
	var options := {
		"frame_step": _step.get_selected_id(),
		"source_fps": int(_fps.value),
		"padding": int(_padding.value),
		"fill_gaps": _gaps.button_pressed,
		"gap_min_neighbors": int(_gap_need.value),
		"include_hidden": _hidden.button_pressed,
		"exclude_root_motion": not _root_motion.button_pressed,
		"hide_source": _hide_source.button_pressed,
		"name": _name.text.strip_edges(),
	}
	hide()
	bake_requested.emit(_root, options)


func _spin(minimum: int, maximum: int, step: int, value: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = minimum
	s.max_value = maximum
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _row(label: String, control: Control) -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	var l := QVoxelUi.label(label, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.custom_minimum_size.x = 96
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row
