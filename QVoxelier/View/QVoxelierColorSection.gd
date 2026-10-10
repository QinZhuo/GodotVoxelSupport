@tool
class_name QVoxelierColorSection
extends QVoxelierSection
## 右侧抽屉·颜色分组 —— 编辑**当前材质**的颜色与 PBR（金属度 / 粗糙度 / 自发光），
## 并提供调色板级操作。
## 【为什么不在这里再摆一份调色板网格】底部 `QVoxelierPalette` 已经是调色板的常驻视图，
## 再摆一份就要维护两处"哪个格子亮着"的选中状态，迟早不同步。于是这里只回答一个问题：
## **"当前这个材质长什么样、怎么改"** —— 网格负责"选哪个"，本分组负责"改成什么"。
## 【手势即命令 —— 与体素笔同一时间线】滑条拖拽期间反复写数据、松手时才封口入栈
## （见 QVoxelPropertyCommand 的"手势即命令"）。颜色与 PBR 的滑条**共用同一条手势**：
##   edit_began → (color_changed | pbr_changed)(多次) → edit_ended
## App 把整段夹进一条 QVoxelPropertyCommand，撤销栈里就只留"一次改材质"。
## 【为什么滑条与预览的刷新要 _syncing 闸】App 回写材质（撤销 / 切材质）时会 set 滑条值，
## 那又会触发 value_changed —— 反过来再报一次改动，形成自激。闸门一挡即可。

## 一次改材质手势开始（此时数据尚未变，供 undo 抓"改前值"）。
signal edit_began
## 手势进行中：当前颜色（App 实时落到世界，不入栈）。
signal color_changed(color: Color)
## 手势结束：App 据此封口入栈。
signal edit_ended

## PBR 标量通道改动（金属度 / 粗糙度 / 自发光）：与 color_changed 同属一段手势，改的是标量。
signal pbr_changed(field: StringName, value: float)

## 取色器开关（开启后下一次点视口即吸取该处材质色）。
signal eyedropper_toggled(on: bool)
## 追加一个新材质到调色板。
signal add_material_requested
## 调色板导入 / 导出（PNG，256×1，索引即材质 ID）。
signal import_requested
signal export_requested

## PBR 标量行：key = `QVoxelWorld.material_scalar` 的键，label = 中文名。
## **表即配置**：滑条与 App 的取值都从这一张表派生，不再各抄一份键名。
const _PBR := [
	{"key": &"metal", "label": "金属度"},
	{"key": &"rough", "label": "粗糙度"},
	{"key": &"emission", "label": "自发光"},
]

## 行首标签的固定宽：让三字的 PBR 标签左缘对齐。
const _LABEL_W := 42

var _picker: ColorPickerButton
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
	# --- 预览行：取色按钮 + 十六进制 + 材质号 ---
	var head := QVoxelUi.hbox()
	body.add_child(head)

	# 【为什么是取色按钮而不是四根 R/G/B/A 滑条】滑条四根占满一屏、只能逐通道微调，
	# 而 Godot 内置的 ColorPicker 已经把色环、RGB/HSV、滑条模式与吸管都做好了 ——
	# 一个按钮点开全有，还顺带解决了"色块看得见但点不动"的问题。
	# 【手势仍是一次】面板弹出期间的多次 color_changed 归为同一条"改材质"，
	# 关面板（popup_closed）时才 edit_ended，撤销栈里只留一步。
	_picker = ColorPickerButton.new()
	_picker.custom_minimum_size = Vector2(QVoxelUi.hit_size() + QVoxelUi.space_l(), QVoxelUi.hit_size())
	_picker.edit_alpha = true
	_picker.tooltip_text = "改颜色：点开取色器（色环 / RGB / HSV / 吸管，关掉即生效）"
	_picker.color_changed.connect(_on_picker_changed)
	_picker.popup_closed.connect(_on_picker_closed)
	head.add_child(_picker)

	var info := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(info)
	_hex = QVoxelUi.label("#000000", QVoxelUi.FONT_M)
	info.add_child(_hex)
	_id_label = QVoxelUi.label("材质 —", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT)
	info.add_child(_id_label)

	# --- 三条 PBR 标量滑条（金属度 / 粗糙度 / 自发光）---
	for p in _PBR:
		var key := String(p["key"])
		body.add_child(_slider_row(key, String(p["label"]),
				func(_v: float): _on_pbr_changed(key)))

	# --- 操作 ---
	var ops := QVoxelUi.hbox()
	body.add_child(ops)
	_eyedropper = QVoxelUi.toggle_button("取色器：开启后点视口里的体素即吸取其材质色")
	_eyedropper.text = "取色器"
	_eyedropper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_eyedropper.toggled.connect(func(on: bool): eyedropper_toggled.emit(on))
	ops.add_child(_eyedropper)

	var add := QVoxelUi.button("＋ 材质", "在调色板末尾追加一个新材质")
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.pressed.connect(func(): add_material_requested.emit())
	ops.add_child(add)

	var io := QVoxelUi.hbox()
	body.add_child(io)
	var import_btn := QVoxelUi.button("导入", "从 256×1 的 PNG 读入调色板")
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.pressed.connect(func(): import_requested.emit())
	io.add_child(import_btn)
	var export_btn := QVoxelUi.button("导出", "把当前调色板写成 256×1 的 PNG")
	export_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_btn.pressed.connect(func(): export_requested.emit())
	io.add_child(export_btn)


## 一行标量滑条（颜色通道与 PBR 共用）：行首标签 + 滑条 + 右侧数值。
## key 同时是 `_sliders` / `_value_labels` 的键，也是 `_format_value` 的判据。
func _slider_row(key: String, label: String, on_changed: Callable) -> HBoxContainer:
	var row := QVoxelUi.hbox()
	var caption := QVoxelUi.label(label, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	caption.custom_minimum_size = Vector2(_LABEL_W, 0)
	row.add_child(caption)

	var s := QVoxelUi.value_slider(0.0, 1.0, 0.001, 0.0)
	s.value_changed.connect(on_changed)
	s.drag_started.connect(func(): _on_drag_started())
	s.drag_ended.connect(func(_changed: bool): _on_drag_ended(key))
	_sliders[key] = s
	row.add_child(s)

	var v := QVoxelUi.label("0", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.custom_minimum_size = Vector2(34, 0)
	_value_labels[key] = v
	row.add_child(v)
	return row


# 对外

## PBR 标量键（String："metal" / "rough" / "emission"）——App 据此向世界取 / 写值，
## 也用作传给 `bind` 的字典键。键表仍是 `_PBR` 这一份，App 不另抄一遍。
static func pbr_keys() -> Array:
	var out: Array = []
	for p in _PBR:
		out.append(String(p["key"]))
	return out


## 绑定当前材质与颜色 / PBR（App 在切材质 / 切对象 / 撤销后调用）。
## pbr 的键与 `_PBR` 的 key 一致（metal / rough / emission）。
func bind(material_id: int, color: Color, pbr: Dictionary) -> void:
	_active_id = material_id
	var editable := material_id > 0
	if editable:
		_id_label.text = "材质 #%d" % material_id
	else:
		_id_label.text = "未选中材质"
	_syncing = true
	_picker.color = color
	_picker.disabled = not editable
	_hex.text = "#" + color.to_html(false)
	for p in _PBR:
		var key := String(p["key"])
		var ps: HSlider = _sliders[key]
		ps.value = float(pbr.get(key, 0.0))
		ps.editable = editable
		_value_labels[key].text = _format_value(key, ps.value)
	_syncing = false


## 同步取色器按钮的按下态（App 主动关闭时用）。
func set_eyedropper(on: bool) -> void:
	if _eyedropper != null and _eyedropper.button_pressed != on:
		_eyedropper.set_pressed_no_signal(on)


func active_id() -> int:
	return _active_id


func current_color() -> Color:
	return _picker.color


# 内部

## 取色器改色中：**第一次**改动才开手势（此前弹开面板不算改动），此后一路并进同一条"改材质"。
func _on_picker_changed(c: Color) -> void:
	if _syncing:
		return
	if not _editing:
		_editing = true
		edit_began.emit()
	_refresh_preview()
	color_changed.emit(c)


## 关面板即手势结束：补报最终值再封口，于是拖到满意为止也只占撤销栈一步。
func _on_picker_closed() -> void:
	if not _editing:
		return
	_editing = false
	color_changed.emit(_picker.color)
	edit_ended.emit()


func _on_pbr_changed(key: String) -> void:
	if _syncing:
		return
	_refresh_preview()
	var v := float(_sliders[key].value)
	_gesture_report(func(): pbr_changed.emit(StringName(key), v))


## 手势中 → 直接上报；无 drag 手势（点进滑条槽 / 键盘微调）→ 自成一次完整手势。
func _gesture_report(report: Callable) -> void:
	if _editing:
		report.call()
		return
	edit_began.emit()
	report.call()
	edit_ended.emit()


func _on_drag_started() -> void:
	if _editing or _syncing:
		return
	_editing = true
	edit_began.emit()


func _on_drag_ended(key: String) -> void:
	if not _editing:
		return
	# 收尾补一次最终值上报（与手势中的逐次上报同源）。到这里只剩 PBR 走拖动手势。
	pbr_changed.emit(StringName(key), float(_sliders[key].value))
	_editing = false
	edit_ended.emit()


## 只刷新"看"的那几个（十六进制与数值读数）。**不回写 _picker.color** ——
## 颜色由取色器自己维护，回写等于把用户刚拖到的值再喂一遍给它。
func _refresh_preview() -> void:
	var c := current_color()
	_hex.text = "#" + c.to_html(false)
	for key in _sliders:
		_value_labels[key].text = _format_value(String(key), float(_sliders[key].value))


## PBR 数值显示：按百分比（贴近"强度"语义）。颜色本身由取色按钮自己呈现，不再单列渲染。
static func _format_value(_key: String, v: float) -> String:
	return "%d%%" % int(round(v * 100.0))
