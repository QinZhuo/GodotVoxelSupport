@tool
class_name QVoxelierTools
extends QVoxelierPanel
## 左侧工具坞 —— 画笔模式 / 笔刷尺寸 / 擦除开关。
## 【工具列表从哪来】直接读 [QVoxelBrushTool.MODES]（表即配置）：加一种笔只需在表里加一行，
## 本面板与 HUD 的提示文案会一起跟着变。界面上**不允许**再抄一份工具名或热键 ——
## 那样迟早出现"按钮写着线笔、提示还在讲盒笔"。
## 【为什么擦除要做成常驻开关】桌面上的擦除是**右键**，而平板没有右键。若不补这个开关，
## 触摸用户就只剩"画"一个动作，擦不掉 —— 这不是少个便利，是功能缺失。
## （鼠标用户仍可用右键，开关只是让两条输入路径汇到同一个状态。）
## 【为什么笔刷是 [−] 数值 [+] 而不是滑块】手指与鼠标在滑块上的定位精度都远不如按钮，
## 而笔刷尺寸是 1..16 的小整数（16 档），加减比拖动更快也更准。不可调的工具（面笔/填充）
## 让整行置灰并给出说明，而不是把行藏起来 —— 位置固定，界面不跳。

## 选中了某个画笔模式（值同 QVoxelBrushTool.Mode）。
signal tool_selected(mode: int)
## 笔刷尺寸加减请求（delta = ±1；钳制与语义归调用方，面板只管按键）。
signal brush_step(delta: int)
## 笔刷尺寸的乘除请求（up = true 表示 ×2，false 表示 ÷2）。
## 与 brush_step 分开是因为语义不同：一个是"细调一格"，一个是"粗调一档"，
## 面板只报方向，钳制与上限一样归 App —— 界面不认识"上限"这个数。
signal brush_scale_requested(up: bool)
## 笔刷截面形态（值同 [enum QVoxelBrushTool.Shape]）。
signal brush_shape_selected(shape: int)
signal erase_toggled(enabled: bool)
## 对称轴开关：axis 0 / 1 / 2 = X / Y / Z。
signal symmetry_toggled(axis: int, on: bool)
## 选区 / 剪贴板动作请求（值 = [constant SELECT_ACTIONS] 里的 id）。
signal selection_action(action: StringName)

## 选区面板的动作表（表即配置，与 [QVoxelBrushTool.MODES] 同一套路数）。
## 【为什么"全选"也在这里】它就是"框选整个网格"的快捷键化 —— 用户不必从一角拖到另一角。
## 五条动作共用一条信号（带 id），面板因此不必为每个动作各开一个信号与一条连接。
const SELECT_ACTIONS := [
	{"id": &"all", "text": "全选", "tip": "选中整个网格（Ctrl+A）"},
	{"id": &"copy", "text": "复制", "tip": "复制选区里的体素（Ctrl+C）"},
	{"id": &"cut", "text": "剪切", "tip": "剪下选区里的体素（Ctrl+X）"},
	{"id": &"paste", "text": "粘贴", "tip": "把剪贴板贴到光标处（Ctrl+V）"},
	{"id": &"clear", "text": "清空", "tip": "挖掉选区里的体素（Delete）"},
]

## 工具坞**面板**的目标宽度取自 [method QVoxelUi.dock_width]（随密度档变）。
## 它不是硬约束：见下面 resized 的处理 —— 它只是"最窄别窄过这个"。

var _buttons := {}          # Mode → Button
var _group := ButtonGroup.new()
var _brush_value: Label
var _brush_minus: Button
var _brush_plus: Button
var _brush_half: Button
var _brush_dbl: Button
var _brush_title: Label
var _shape_buttons: Array[Button] = []
var _erase: Button
var _sym: Array[Button] = []
var _select_buttons := {}   # id → Button
var _size := 1


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(QVoxelUi.space_m(), QVoxelUi.bar_height() + QVoxelUi.space_m())
	# 注意用 size 而不是 offset_right：anchors 全 0 时 offset_right 是"右边界坐标"，
	# 直接写宽度会得到"宽度 − 左边距"（差一个左边距）。
	size.x = QVoxelUi.dock_width()

	var panel := QVoxelUi.panel(QVoxelUi.space_s())
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(panel)
	# 非容器父节点下的子控件是"自由摆放"的：这个 Control 自身的矩形会停在 0 高 —— 画得出来，
	# 但任何按矩形度量的东西（调试器、自动化工具、以后的对齐逻辑）都会读到 0。
	# 取"设计宽度 vs 内容实际需要"的较大者：换文案 / 换语言时按钮不会被挤出面板，
	# 同时矩形始终如实反映画出来的东西。此式有唯一不动点，不会来回抖。
	panel.resized.connect(func():
		size = Vector2(maxf(QVoxelUi.dock_width(), panel.size.x), panel.size.y))

	var col := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	panel.add_child(col)

	col.add_child(QVoxelUi.heading("工具"))
	_group.allow_unpress = false
	for row in QVoxelBrushTool.MODES:
		var b := QVoxelUi.toggle_button("%s（%s）" % [row.label, row.hint])
		# 热键字母直接写进按钮文字当"键帽"：既省一层子控件，也让按钮的 text 是可读的
		# （界面上每个按钮都该有能被人和自动化工具读到的名字，空 text 的按钮等于匿名）。
		b.text = "%s   %s" % [String.chr(row.hotkey), row.label]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.button_group = _group
		b.toggled.connect(func(on: bool): if on: tool_selected.emit(row.mode))
		_buttons[row.mode] = b
		col.add_child(b)

	col.add_child(QVoxelUi.divider())
	_brush_title = QVoxelUi.heading("笔刷")
	col.add_child(_brush_title)
	col.add_child(_build_brush_row())
	col.add_child(_build_brush_scale_row())
	col.add_child(_build_shape_row())

	col.add_child(QVoxelUi.divider())
	_erase = QVoxelUi.toggle_button("擦除模式：画的时候挖掉体素（触摸屏上代替右键）")
	_erase.text = "E   擦除"
	_erase.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_erase.toggled.connect(func(on: bool): erase_toggled.emit(on))
	col.add_child(_erase)

	col.add_child(QVoxelUi.divider())
	col.add_child(QVoxelUi.heading("对称"))
	var sym_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	col.add_child(sym_row)
	for i in 3:
		var axis := String.chr("X".unicode_at(0) + i)
		var b := QVoxelUi.toggle_button("沿 %s 轴镜像：画一笔，网格对侧同步出现" % axis)
		b.text = axis
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 用 bind 而不是闭包捕获 i：捕获写法在不同 GDScript 版本下取值时机有歧义，
		# bind 把 i 钉死在参数里，三个按钮各连各的，不会一起变成 Z。
		b.toggled.connect(_on_sym_toggled.bind(i))
		_sym.append(b)
		sym_row.add_child(b)

	col.add_child(QVoxelUi.divider())
	col.add_child(QVoxelUi.heading("选区"))
	col.add_child(_build_selection_rows())


func _on_sym_toggled(on: bool, axis: int) -> void:
	symmetry_toggled.emit(axis, on)


## 选区动作按钮。排成两行（3 + 2）而不是一行 5 个：工具坞宽度固定，五个按钮挤一行时
## 中文字会被压到"复…"这种读不出来的程度。
func _build_selection_rows() -> VBoxContainer:
	var box := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	var rows := [QVoxelUi.hbox(QVoxelUi.SPACE_XS), QVoxelUi.hbox(QVoxelUi.SPACE_XS)]
	for r in rows:
		box.add_child(r)
	for i in SELECT_ACTIONS.size():
		var row: Dictionary = SELECT_ACTIONS[i]
		var b := QVoxelUi.button(row.text, row.tip)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# bind 而不是闭包捕获 i：三个按钮各连各的 id，不会一起变成最后一个（同对称轴的处理）。
		b.pressed.connect(_on_select_action.bind(row.id))
		_select_buttons[row.id] = b
		rows[0 if i < 3 else 1].add_child(b)
	return box


func _on_select_action(id: StringName) -> void:
	selection_action.emit(id)


## 笔刷尺寸步进：减 / 当前值 / 加。数值用 Label 而不是按钮 —— 它无可点击的语义，
## 做成按钮只会让人以为按下去还有下文。
func _build_brush_row() -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_brush_minus = QVoxelUi.icon_button("−", "调小笔刷（[ 或 -）")
	_brush_minus.pressed.connect(func(): brush_step.emit(-1))
	row.add_child(_brush_minus)

	_brush_value = QVoxelUi.label("1", QVoxelUi.FONT_TITLE, QVoxelUi.TEXT)
	_brush_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_brush_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_brush_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_brush_value)

	_brush_plus = QVoxelUi.icon_button("+", "调大笔刷（] 或 =）")
	_brush_plus.pressed.connect(func(): brush_step.emit(1))
	row.add_child(_brush_plus)
	return row


## 笔刷的 ×2 / ÷2（MagicaVoxel 的粗调档）。[−]/[+] 是逐格细调，这两个是按倍数跳 ——
## 从 1 调到 16 要按 15 下，而 ×2 只要 4 下。两行并排，细调在上、粗调在下，位置固定。
## 未知上限（归 App），故只有"减半"在 size == 1 时置灰 —— 那是唯一能本地判定的边界。
func _build_brush_scale_row() -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_brush_dbl = QVoxelUi.button("2X", "笔刷尺寸翻倍")
	_brush_dbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_dbl.pressed.connect(func(): brush_scale_requested.emit(true))
	row.add_child(_brush_dbl)

	_brush_half = QVoxelUi.button("1÷2", "笔刷尺寸减半")
	_brush_half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_half.pressed.connect(func(): brush_scale_requested.emit(false))
	row.add_child(_brush_half)
	return row


## 笔刷截面形态（球 / 平面）。读 [constant QVoxelBrushTool.SHAPES]（表即配置，与 MODES 同一套路数），
## 与尺寸行一样**位置固定、不支持时置灰**而不是把行藏起来 —— 界面不跳。
func _build_shape_row() -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for entry in QVoxelBrushTool.SHAPES:
		var b := QVoxelUi.toggle_button(entry.tip)
		b.text = entry.text
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_group = group
		# bind 而不是闭包捕获：与对称轴 / 选区动作同一条理由 —— 每个按钮各钉各的值，
		# 不会一起变成最后一个（捕获写法在不同 GDScript 版本下取值时机有歧义）。
		b.toggled.connect(_on_shape_toggled.bind(int(entry.shape)))
		_shape_buttons.append(b)
		row.add_child(b)
	return row


func _on_shape_toggled(on: bool, shape: int) -> void:
	if on:
		brush_shape_selected.emit(shape)


# 对外：状态同步（只由 App 调用）

## 高亮当前工具。用 set_pressed_no_signal 是必须的 —— 否则回写会再触发一次
## tool_selected，形成"App 设界面、界面又通知 App"的回环。
func set_tool(mode: int) -> void:
	var b: Button = _buttons.get(mode)
	if b != null:
		b.set_pressed_no_signal(true)


## 刷新笔刷显示。supported = false（面笔 / 填充不吃笔刷）时整行置灰并说明原因。
func set_brush(size: int, supported: bool) -> void:
	_size = size
	_brush_value.text = str(size)
	_brush_value.add_theme_color_override("font_color",
			QVoxelUi.TEXT if supported else QVoxelUi.TEXT_FAINT)
	_brush_minus.disabled = not supported or size <= 1
	_brush_plus.disabled = not supported
	_brush_half.disabled = not supported or size <= 1
	_brush_dbl.disabled = not supported
	_brush_title.text = "笔刷" if supported else "笔刷（此工具不用）"


## 回写形态的按下态（App 在切对象 / 撤销后调用；no_signal 避免"App 设界面、界面又通知 App"的回环）。
## 与 set_brush 一样**置灰而非隐藏**：形态只对吃尺寸的笔有意义，但位置恒定。
func set_brush_shape(shape: int, supported: bool) -> void:
	for i in QVoxelBrushTool.SHAPES.size():
		if i >= _shape_buttons.size():
			break
		var b := _shape_buttons[i]
		if int(QVoxelBrushTool.SHAPES[i].shape) == shape:
			b.set_pressed_no_signal(true)
		b.disabled = not supported


func set_erase(on: bool) -> void:
	_erase.set_pressed_no_signal(on)


## 回写对称轴状态（App 在切对象 / 撤销后调用；同样用 no_signal 避免回环）。
func set_symmetry(mask: Vector3i) -> void:
	var flags := [mask.x, mask.y, mask.z]
	for i in 3:
		if i < _sym.size():
			_sym[i].set_pressed_no_signal(flags[i] != 0)


## 回写选区 / 剪贴板的可用性。**置灰而不是隐藏** —— 位置固定，界面不跳（同笔刷行的原则）。
## "全选"恒可用：它不依赖任何既有状态。
func set_selection_state(has_selection: bool, has_clipboard: bool) -> void:
	_set_action_enabled(&"all", true)
	_set_action_enabled(&"copy", has_selection)
	_set_action_enabled(&"cut", has_selection)
	_set_action_enabled(&"paste", has_clipboard)
	_set_action_enabled(&"clear", has_selection)


func _set_action_enabled(id: StringName, on: bool) -> void:
	var b: Button = _select_buttons.get(id)
	if b != null:
		b.disabled = not on


func erase_mode() -> bool:
	return _erase.button_pressed
