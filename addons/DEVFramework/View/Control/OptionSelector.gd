@tool
class_name OptionSelector extends HBoxContainer

signal option_changed(index: int)

enum DisplayMode {SPINNER, TOGGLE}

const _DEFAULT_ARROW := Color(0.35, 0.65, 1, 1)
const _DEFAULT_HIGHLIGHT := Color(1.5, 2.0, 4.0, 1)
const _DEFAULT_DESC := Color(0.55, 0.55, 0.6, 1)
const _DEFAULT_VAL := Color(0.9, 0.9, 0.9, 1)

# ------------------------------------------------------------
# 导出属性
# ------------------------------------------------------------

@export var display_mode: DisplayMode = DisplayMode.SPINNER:
	set(v):
		if display_mode == v:
			return
		display_mode = v
		if _built:
			_rebuild()

@export var options: Array = ["Option A", "Option B", "Option C"]:
	set(v):
		options = v
		if _built:
			_rebuild()

var _current_index: int = 0

@export var current_index: int = 0:
	get: return _current_index
	set(v):
		_current_index = _clamp_index(v)
		_sync_display()
		option_changed.emit(_current_index)

@export var label: String = "Option":
	set(v):
		label = v
		if _description_label:
			_description_label.text = v

@export var wrap_around: bool = true

# ------------------------------------------------------------
# 状态变量
# ------------------------------------------------------------

var highlight_color: Color = _DEFAULT_HIGHLIGHT
var _desc_color: Color = _DEFAULT_DESC
var _description_label: Label
var _group: HBoxContainer
var _built := false
var _applying_theme := false

var _prev_btn: Button  # SPINNER 左箭头
var _value_btn: Button  # SPINNER 中间值
var _next_btn: Button  # SPINNER 右箭头
var _toggle_btns: Array[Button] = []  # TOGGLE 按钮组

# ------------------------------------------------------------
# 生命周期
# ------------------------------------------------------------

func _enter_tree() -> void:
	if _built:
		return
	_built = true

	_description_label = Label.new()
	_description_label.name = "DescriptionLabel"
	add_child(_description_label)

	_group = HBoxContainer.new()
	_group.name = "OptionGroup"
	_group.alignment = BoxContainer.ALIGNMENT_CENTER
	_group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_group)

	_build_content()
	_apply_theme()

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme()

func _ready() -> void:
	current_index = _clamp_index(current_index)

# ------------------------------------------------------------
# 构建 & 重建
# ------------------------------------------------------------

func _rebuild() -> void:
	_clear_group()
	_build_content()
	_apply_theme()

func _clear_group() -> void:
	for c in _group.get_children():
		_group.remove_child(c)
		c.queue_free()
	_prev_btn = null
	_value_btn = null
	_next_btn = null
	_toggle_btns.clear()

func _build_content() -> void:
	match display_mode:
		DisplayMode.SPINNER:
			_build_spinner()
		DisplayMode.TOGGLE:
			_build_toggle()
	_description_label.text = label
	_sync_display()

func _build_spinner() -> void:
	var arrow_btn := func(text: String) -> Button:
		var b := Button.new()
		b.flat = true
		b.text = text
		b.focus_mode = Control.FOCUS_NONE
		return b

	_prev_btn = arrow_btn.call("◀")
	_prev_btn.name = "PrevButton"
	_group.add_child(_prev_btn)

	_value_btn = Button.new()
	_value_btn.name = "ValueButton"
	_value_btn.flat = true
	_value_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_value_btn.focus_mode = Control.FOCUS_ALL
	_group.add_child(_value_btn)

	_next_btn = arrow_btn.call("▶")
	_next_btn.name = "NextButton"
	_group.add_child(_next_btn)

	_prev_btn.pressed.connect(_on_prev)
	_next_btn.pressed.connect(_on_next)
	_value_btn.pressed.connect(_on_next)
	_value_btn.focus_entered.connect(_on_focus_entered)
	_value_btn.focus_exited.connect(_on_focus_exited)
	_value_btn.gui_input.connect(_on_value_gui_input)

func _build_toggle() -> void:
	_toggle_btns.clear()
	for i in options.size():
		var btn := Button.new()
		btn.name = "ToggleBtn_%d" % i
		btn.toggle_mode = true
		btn.text = options[i]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_toggle_pressed.bind(i))
		btn.focus_entered.connect(_on_focus_entered)
		btn.focus_exited.connect(_on_focus_exited)
		_group.add_child(btn)
		_toggle_btns.append(btn)

# ------------------------------------------------------------
# 公开接口
# ------------------------------------------------------------

func get_focus_target() -> Control:
	match display_mode:
		DisplayMode.SPINNER:
			return _value_btn if _value_btn else self
		DisplayMode.TOGGLE:
			return _toggle_btns[0] if _toggle_btns.size() > 0 else self
	return self

func select_index(idx: int) -> void:
	current_index = idx

func set_index_no_signal(idx: int) -> void:
	_current_index = _clamp_index(idx)
	_sync_display()

func get_current_value() -> Variant:
	return options[current_index] if current_index >= 0 and current_index < options.size() else null

# ------------------------------------------------------------
# 输入处理
# ------------------------------------------------------------

func _clamp_index(idx: int) -> int:
	return clampi(idx, 0, max(options.size() - 1, 0)) if options.size() > 0 else 0

func _on_prev() -> void:
	if options.is_empty():
		return
	if current_index > 0:
		current_index -= 1
	elif wrap_around:
		current_index = options.size() - 1

func _on_next() -> void:
	if options.is_empty():
		return
	if current_index < options.size() - 1:
		current_index += 1
	elif wrap_around:
		current_index = 0

func _on_toggle_pressed(idx: int) -> void:
	current_index = idx

func _on_value_gui_input(event: InputEvent) -> void:
	if not _value_btn or not event:
		return
	if event.is_action_pressed("ui_left"):
		_on_prev()
		_value_btn.accept_event()
	elif event.is_action_pressed("ui_right"):
		_on_next()
		_value_btn.accept_event()

# ------------------------------------------------------------
# 聚焦高亮
# ------------------------------------------------------------

func _on_focus_entered() -> void:
	if _description_label:
		_description_label.add_theme_color_override("font_color", highlight_color)

func _on_focus_exited() -> void:
	await get_tree().process_frame
	if not _description_label or not _group:
		return
	for c in _group.get_children():
		if c is Control and c.has_focus():
			return
	_description_label.add_theme_color_override("font_color", _desc_color)

# ------------------------------------------------------------
# 主题
# ------------------------------------------------------------

func _apply_theme() -> void:
	if not _built or _applying_theme:
		return
	_applying_theme = true

	var arrow := _read_color("arrow_color", _DEFAULT_ARROW)
	highlight_color = _read_color("highlight_color", _DEFAULT_HIGHLIGHT)
	var desc := _read_color("description_color", _DEFAULT_DESC)
	var val := _read_color("value_color", _DEFAULT_VAL)
	_desc_color = desc

	if _description_label:
		_description_label.add_theme_color_override("font_color", _desc_color)

	match display_mode:
		DisplayMode.SPINNER:
			if _prev_btn:
				_prev_btn.add_theme_color_override("font_color", arrow)
				_next_btn.add_theme_color_override("font_color", arrow)
				_value_btn.add_theme_color_override("font_color", val)
				_value_btn.add_theme_color_override("font_pressed_color", highlight_color)
				_value_btn.add_theme_color_override("font_hover_color", highlight_color)
		DisplayMode.TOGGLE:
			var hover_style := get_theme_stylebox("hover", "Button") if has_theme_stylebox("hover", "Button") else null
			for btn in _toggle_btns:
				if not btn:
					continue
				btn.add_theme_color_override("font_color", val)
				btn.add_theme_color_override("font_pressed_color", highlight_color)
				btn.add_theme_color_override("font_hover_color", highlight_color)
				if hover_style:
					btn.add_theme_stylebox_override("pressed", hover_style)

	_description_label.custom_minimum_size = Vector2(_read_const("description_min_width", 80), 0)

	var arrow_sz := _read_const("arrow_min_size", 28)
	if _prev_btn:
		_prev_btn.custom_minimum_size = Vector2(arrow_sz, arrow_sz)
		_next_btn.custom_minimum_size = Vector2(arrow_sz, arrow_sz)

	var btn_w := _read_const("button_min_width", 0)
	var btn_h := _read_const("button_min_height", 0)
	if btn_w > 0 or btn_h > 0:
		var bsz := Vector2(max(btn_w, 0), max(btn_h, 0))
		match display_mode:
			DisplayMode.SPINNER:
				if _value_btn:
					_value_btn.custom_minimum_size = bsz
			DisplayMode.TOGGLE:
				for btn in _toggle_btns:
					if btn:
						btn.custom_minimum_size = bsz

	add_theme_constant_override("separation", _read_const("spacing", 12))
	_group.add_theme_constant_override("separation", _read_const("group_spacing", 4))

	var fsz := _read_font_size()
	if fsz > 0 and _description_label:
		_description_label.add_theme_font_size_override("font_size", fsz)
		match display_mode:
			DisplayMode.SPINNER:
				if _prev_btn:
					_prev_btn.add_theme_font_size_override("font_size", fsz)
					_value_btn.add_theme_font_size_override("font_size", fsz)
					_next_btn.add_theme_font_size_override("font_size", fsz)
			DisplayMode.TOGGLE:
				for btn in _toggle_btns:
					if btn:
						btn.add_theme_font_size_override("font_size", fsz)

	_applying_theme = false

func _read_color(name: String, fallback: Color) -> Color:
	return get_theme_color(name, "OptionSelector") if has_theme_color(name, "OptionSelector") else fallback

func _read_const(name: String, fallback: int) -> int:
	return get_theme_constant(name, "OptionSelector") if has_theme_constant(name, "OptionSelector") else fallback

func _read_font_size() -> int:
	return get_theme_font_size("font_size", "OptionSelector") if has_theme_font_size("font_size", "OptionSelector") else -1

# ------------------------------------------------------------
# 显示同步
# ------------------------------------------------------------

func _sync_display() -> void:
	if not _built:
		return
	match display_mode:
		DisplayMode.SPINNER:
			if _value_btn:
				_value_btn.text = options[current_index] if not options.is_empty() else ""
		DisplayMode.TOGGLE:
			for i in _toggle_btns.size():
				if _toggle_btns[i]:
					_toggle_btns[i].button_pressed = (i == current_index)
