@tool
class_name QVoxelierColorSection
extends QVoxelierSection
## 右侧抽屉·颜色分组 —— 编辑**当前材质**的颜色，并提供调色板级操作。
##
## 【为什么不在这里再摆一份调色板网格】底部 `QVoxelierPalette` 已经是调色板的常驻视图，
## 再摆一份就要维护两处"哪个格子亮着"的选中状态，迟早不同步。于是这里只回答一个问题：
## **"当前这个材质是什么色、怎么改"** —— 网格负责"选哪个"，本分组负责"改成什么"。
##
## 【手势即命令 —— 与体素笔同一时间线】滑条拖拽期间反复写数据、松手时才封口入栈
## （见 QVoxPropertyCommand 的"手势即命令"）。所以本分组只报告三段信号：
##   edit_began → color_changed(多次) → edit_ended
## App 把整段夹进一条 QVoxPropertyCommand，撤销栈里就只留"一次改色"。
##
## 【为什么滑条与预览的刷新要 _syncing 闸】App 回写颜色（撤销 / 切材质）时会 set 滑条值，
## 那又会触发 value_changed —— 反过来再报一次 color_changed，形成自激。闸门一挡即可。

## 一次改色手势开始（此时数据尚未变，供 undo 抓"改前值"）。
signal edit_began
## 手势进行中：当前颜色（App 实时落到世界，不入栈）。
signal color_changed(color: Color)
## 手势结束：App 据此封口入栈。
signal edit_ended

## 取色器开关（开启后下一次点视口即吸取该处材质色）。
signal eyedropper_toggled(on: bool)
## 追加一个新材质到调色板。
signal add_material_requested
## 调色板导入 / 导出（PNG，256×1，索引即材质 ID）。
signal import_requested
signal export_requested

const _CHANNELS := ["R", "G", "B", "A"]

var _preview: ColorRect
var _hex: Label
var _id_label: Label
var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _eyedropper: Button
var _active_id := 0
var _syncing := false
var _editing := false


func section_title() -> String:
	return "颜色"


func _build_body(body: VBoxContainer) -> void:
	# --- 预览行：色块 + 十六进制 + 材质号 ---
	var head := QVoxUi.hbox()
	body.add_child(head)

	_preview = ColorRect.new()
	_preview.custom_minimum_size = Vector2(QVoxUi.hit_size() + QVoxUi.space_l(), QVoxUi.hit_size())
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_preview)

	var info := QVoxUi.vbox(QVoxUi.SPACE_XS)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(info)
	_hex = QVoxUi.label("#000000", QVoxUi.FONT_M)
	info.add_child(_hex)
	_id_label = QVoxUi.label("材质 —", QVoxUi.FONT_S, QVoxUi.TEXT_FAINT)
	info.add_child(_id_label)

	# --- 四条通道滑条 ---
	for ch in _CHANNELS:
		body.add_child(_channel_row(ch))

	# --- 操作 ---
	var ops := QVoxUi.hbox()
	body.add_child(ops)
	_eyedropper = QVoxUi.toggle_button("取色器：开启后点视口里的体素即吸取其材质色")
	_eyedropper.text = "取色器"
	_eyedropper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_eyedropper.toggled.connect(func(on: bool): eyedropper_toggled.emit(on))
	ops.add_child(_eyedropper)

	var add := QVoxUi.button("＋ 材质", "在调色板末尾追加一个新材质")
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.pressed.connect(func(): add_material_requested.emit())
	ops.add_child(add)

	var io := QVoxUi.hbox()
	body.add_child(io)
	var import_btn := QVoxUi.button("导入", "从 256×1 的 PNG 读入调色板")
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.pressed.connect(func(): import_requested.emit())
	io.add_child(import_btn)
	var export_btn := QVoxUi.button("导出", "把当前调色板写成 256×1 的 PNG")
	export_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_btn.pressed.connect(func(): export_requested.emit())
	io.add_child(export_btn)


func _channel_row(ch: String) -> HBoxContainer:
	var row := QVoxUi.hbox()
	row.add_child(QVoxUi.label(ch, QVoxUi.FONT_S, QVoxUi.TEXT_DIM))

	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.001
	s.focus_mode = Control.FOCUS_NONE
	s.custom_minimum_size = Vector2(0, QVoxUi.hit_size())
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(_v: float): _on_channel_changed())
	s.drag_started.connect(_on_drag_started)
	s.drag_ended.connect(func(_changed: bool): _on_drag_ended())
	_sliders[ch] = s
	row.add_child(s)

	var v := QVoxUi.label("0", QVoxUi.FONT_S, QVoxUi.TEXT_DIM)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.custom_minimum_size = Vector2(34, 0)
	_value_labels[ch] = v
	row.add_child(v)
	return row


# ----------------------------------------------------------------------------
# 对外
# ----------------------------------------------------------------------------

## 绑定当前材质与颜色（App 在切材质 / 切对象 / 撤销后调用）。
func bind(material_id: int, color: Color) -> void:
	_active_id = material_id
	var editable := material_id > 0
	if editable:
		_id_label.text = "材质 #%d" % material_id
	else:
		_id_label.text = "未选中材质"
	_syncing = true
	_preview.color = color
	_hex.text = "#" + color.to_html(false)
	for ch in _CHANNELS:
		var s: HSlider = _sliders[ch]
		s.value = _channel_value(color, ch)
		s.editable = editable
		_value_labels[ch].text = str(int(round(_channel_value(color, ch) * 255.0)))
	_syncing = false


## 同步取色器按钮的按下态（App 主动关闭时用）。
func set_eyedropper(on: bool) -> void:
	if _eyedropper != null and _eyedropper.button_pressed != on:
		_eyedropper.set_pressed_no_signal(on)


func active_id() -> int:
	return _active_id


func current_color() -> Color:
	return Color(
		float(_sliders["R"].value), float(_sliders["G"].value),
		float(_sliders["B"].value), float(_sliders["A"].value))


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _on_channel_changed() -> void:
	if _syncing:
		return
	_refresh_preview()
	if _editing:
		color_changed.emit(current_color())
	else:
		# 点进滑条槽 / 键盘微调：没有 drag 手势，自成一次完整手势。
		edit_began.emit()
		color_changed.emit(current_color())
		edit_ended.emit()


func _on_drag_started() -> void:
	if _editing or _syncing:
		return
	_editing = true
	edit_began.emit()


func _on_drag_ended() -> void:
	if not _editing:
		return
	color_changed.emit(current_color())
	_editing = false
	edit_ended.emit()


func _refresh_preview() -> void:
	var c := current_color()
	_preview.color = c
	_hex.text = "#" + c.to_html(false)
	for ch in _CHANNELS:
		_value_labels[ch].text = str(int(round(float(_sliders[ch].value) * 255.0)))


## 通道取值：Color 不支持下标运算，故显式分发（唯一一处，避免四处写 .r/.g/.b/.a）。
static func _channel_value(color: Color, ch: String) -> float:
	match ch:
		"R":
			return color.r
		"G":
			return color.g
		"B":
			return color.b
		_:
			return color.a
