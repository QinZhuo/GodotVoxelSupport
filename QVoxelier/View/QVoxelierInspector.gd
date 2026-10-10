@tool
class_name QVoxelierInspector
extends VBoxContainer
## 通用属性编辑器：按对象的 @export 属性自动生成控件。
## 【为什么按反射生成，而不是给每个算子手写一份面板】算子参数的种类是**开放**的（SDF 与体素算子
## 共 30+ 个类，还在长），手写面板等于"每加一个算子就要改一次 UI"，且一定会漏。反射生成让新算子
## 零 UI 成本接入 —— 这与插件侧"算子零改动接入"（QVoxelDomain 的能力探测）是同一条原则。
## 【为什么不用 Godot 自带的 EditorInspector】它属于编辑器插件上下文（EditorPlugin / 编辑器专属），
## 而 QVoxelier 要能作为独立程序运行。运行时没有现成的属性编辑器，故自建。
## 【手势协议 —— 与 QVoxelPropertyCommand 同构】连续型控件（滑条）在拖动期间会反复改值，若每次都
## 记一条命令，撤销栈会被一次拖拽淹掉。故本类**只发意图、从不写数据**：
##     edit_began(target, prop) → value_changed(target, prop, v) × N → edit_ended(target, prop)
## 调用方把这一段夹成一条命令（begin 抓 before、value_changed 直接写、end 封口采集 after）。
## 离散型控件（勾选、下拉、输入框）把三个信号**连续发一次**，调用方无需区分这两种手势。
## 【为什么信号要带 target】算子可以嵌算子（`SdfUnion.a` 本身又是一个 Sdf），参数因此分布在一棵
## 树上。带上传者就不需要"路径"这第二套寻址方式：谁被改了就报谁，任意深度都成立。

signal edit_began(target: Object, prop: StringName)
signal value_changed(target: Object, prop: StringName, value: Variant)
signal edit_ended(target: Object, prop: StringName)


## Resource 自带的簿记属性：露出来只会干扰，且改它们没有意义。
const _SKIP: Array[StringName] = [&"script", &"resource_local_to_scene", &"resource_path",
		&"resource_name", &"resource_scene_unique_id"]

## 嵌套算子的展开层数上限。SdfUnion.a.center 已到第 3 层，再深就是"链套链"，
## 平铺下去只会让人迷失，故到顶后只显示类型名。
const MAX_DEPTH := 3

## 数值兜底范围：没有 range 提示的 int / float 用它，避免 SpinBox 默认的 0..100 把参数夹死。
const FALLBACK_MIN := -4096.0
const FALLBACK_MAX := 4096.0

var target: Object

var _label_width := 0
var _dragging: Object = null


## 绑定到 target 并重建控件。label_width < 0 表示按密度档自动取值。
func bind(t: Object, label_width := -1) -> void:
	target = t
	_label_width = QVoxelUi.hit_size() * 2 if label_width < 0 else label_width
	_rebuild()


## 是否正处在一次连续手势中（调用方据此避免重建面板 —— 重建会把正在拖的滑条销毁）。
func is_editing() -> bool:
	if _dragging != null:
		return true
	for c in get_children():
		if c is QVoxelierInspector and (c as QVoxelierInspector).is_editing():
			return true
	return false


func _rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_dragging = null
	if target == null:
		add_child(QVoxelUi.label("（未选中修改器）", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		return
	_build_object(target, 0)


## 一个对象的可编辑属性：既要能编辑（EDITOR）又要能存盘（STORAGE），并剔掉 Resource 簿记。
static func editable_properties(o: Object) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in o.get_property_list():
		var usage := int(p["usage"])
		if not (usage & PROPERTY_USAGE_EDITOR) or not (usage & PROPERTY_USAGE_STORAGE):
			continue
		if StringName(p["name"]) in _SKIP:
			continue
		out.append(p)
	return out


func _build_object(o: Object, depth: int) -> void:
	var props := editable_properties(o)
	if props.is_empty():
		add_child(QVoxelUi.label("（无参数）", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		return
	for p in props:
		_build_property(o, p, depth)


func _build_property(o: Object, p: Dictionary, depth: int) -> void:
	var prop := StringName(p["name"])
	var type := int(p["type"])
	var hint := int(p["hint"])
	var hint_string := String(p["hint_string"])
	var value: Variant = o.get(prop)

	if type == TYPE_BOOL:
		_row_toggle(o, prop, value)
	elif hint == PROPERTY_HINT_ENUM:
		_row_enum(o, prop, hint_string, value)
	elif type == TYPE_OBJECT:
		_row_resource(o, prop, hint_string, value, depth)
	elif type == TYPE_STRING or type == TYPE_STRING_NAME:
		_row_string(o, prop, value)
	elif type == TYPE_COLOR:
		_row_color(o, prop, value)
	elif hint == PROPERTY_HINT_RANGE and (type == TYPE_INT or type == TYPE_FLOAT):
		_row_range(o, prop, hint_string, value, type == TYPE_INT)
	elif type == TYPE_VECTOR3 or type == TYPE_VECTOR3I:
		_row_vector(o, prop, value, type == TYPE_VECTOR3I)
	elif type == TYPE_INT or type == TYPE_FLOAT:
		_row_number(o, prop, value, type == TYPE_INT)
	else:
		_row_readonly(prop, value)


# 行的骨架

## 参数名标签：定宽 + 省略号 + tooltip。定宽是为了让同一栏里所有控件左边界对齐 ——
## 参数名长短不一，不对齐就会读成一堆参差的控件。
func _name_label(prop: StringName) -> Label:
	var l := QVoxelUi.label(String(prop), QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.custom_minimum_size.x = _label_width
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.tooltip_text = String(prop)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	return l


## 离散改动：begin / change / end 连发一次，调用方无需区分离散与连续两种手势。
func _emit_discrete(o: Object, prop: StringName, value: Variant) -> void:
	edit_began.emit(o, prop)
	value_changed.emit(o, prop, value)
	edit_ended.emit(o, prop)


## 枚举参数（如合成方式）：hint_string 形如 "Replace:0,Union:1,…"。
func _row_enum(o: Object, prop: StringName, hint_string: String, value: Variant) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.clip_text = true
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# hint_string 的两半是"显示名:取值"；只写显示名时取值就是它的序号（Godot 的默认约定）。
	var ids := PackedInt32Array()
	var parts := hint_string.split(",", false)
	for i in parts.size():
		var part := parts[i]
		var text := part
		var id := i
		var colon := part.rfind(":")
		if colon > 0:
			text = part.substr(0, colon)
			id = int(part.substr(colon + 1))
		opt.add_item(text, id)
		ids.append(id)
	var cur := ids.find(int(value))
	opt.selected = maxi(cur, 0)
	opt.item_selected.connect(func(idx: int) -> void:
		_emit_discrete(o, prop, ids[idx]))
	row.add_child(opt)


func _row_toggle(o: Object, prop: StringName, value: Variant) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	row.add_child(QVoxelUi.spacer())
	var b := QVoxelUi.toggle_button(String(prop))
	b.text = "开" if bool(value) else "关"
	b.custom_minimum_size.x = QVoxelUi.hit_size() * 2
	b.button_pressed = bool(value)
	b.toggled.connect(func(on: bool) -> void:
		b.text = "开" if on else "关"
		_emit_discrete(o, prop, on))
	row.add_child(b)


func _row_string(o: Object, prop: StringName, value: Variant) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	var le := LineEdit.new()
	le.text = String(value)
	le.focus_mode = Control.FOCUS_CLICK
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 输入框不吃视口热键：本应用的键盘默认归视口，只有"点进来"才交出。
	le.text_submitted.connect(func(t: String) -> void:
		_emit_discrete(o, prop, t))
	le.focus_exited.connect(func() -> void:
		# 焦点离开即提交，避免"改了但没按回车"的静默丢失。
		if le.text != String(o.get(prop)):
			_emit_discrete(o, prop, le.text))
	row.add_child(le)


func _row_number(o: Object, prop: StringName, value: Variant, is_int: bool) -> void:
	add_child(_name_label(prop))
	var sp := SpinBox.new()
	sp.min_value = FALLBACK_MIN
	sp.max_value = FALLBACK_MAX
	sp.step = 1.0 if is_int else 0.1
	sp.value = float(value)
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.value_changed.connect(func(v: float) -> void:
		_emit_discrete(o, prop, int(v) if is_int else v))
	add_child(sp)


func _row_range(o: Object, prop: StringName, hint_string: String, value: Variant,
		is_int: bool) -> void:
	add_child(_name_label(prop))
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	var parts := hint_string.split(",")
	var lo := float(parts[0]) if parts.size() > 0 and not parts[0].is_empty() else 0.0
	var hi := float(parts[1]) if parts.size() > 1 and not parts[1].is_empty() else 1.0
	var step := float(parts[2]) if parts.size() > 2 and not parts[2].is_empty() else 0.0
	if hi <= lo:
		hi = lo + 1.0
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step if step > 0.0 else (1.0 if is_int else 0.01)
	sl.value = clampf(float(value), lo, hi)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var readout := QVoxelUi.label(_fmt(sl.value, is_int), QVoxelUi.FONT_S, QVoxelUi.TEXT)
	readout.custom_minimum_size.x = QVoxelUi.hit_size() * 1.5
	# 拖动期间只报值（调用方已开好命令），松手才封口；这样一次拖拽 = 一条命令。
	sl.drag_started.connect(func() -> void:
		_dragging = o
		edit_began.emit(o, prop))
	sl.drag_ended.connect(func(_changed: bool) -> void:
		_dragging = null
		edit_ended.emit(o, prop))
	sl.value_changed.connect(func(v: float) -> void:
		readout.text = _fmt(v, is_int)
		if _dragging == o:
			value_changed.emit(o, prop, int(v) if is_int else v)
		else:
			# 滚轮 / 键盘改值没有 drag_started，按离散改动处理，免得"改了却没入栈"。
			_emit_discrete(o, prop, int(v) if is_int else v))
	row.add_child(sl)
	row.add_child(readout)


func _row_vector(o: Object, prop: StringName, value: Variant, is_int: bool) -> void:
	add_child(_name_label(prop))
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	add_child(row)
	for i in 3:
		var cell := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(QVoxelUi.label(["x", "y", "z"][i], QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		var sp := SpinBox.new()
		sp.min_value = FALLBACK_MIN
		sp.max_value = FALLBACK_MAX
		sp.step = 1.0 if is_int else 0.1
		sp.value = float([value.x, value.y, value.z][i])
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var axis := i
		sp.value_changed.connect(func(v: float) -> void:
			_emit_discrete(o, prop, _with_axis(o.get(prop), axis, v, is_int)))
		cell.add_child(sp)
		row.add_child(cell)


func _row_color(o: Object, prop: StringName, value: Variant) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	var cp := ColorPickerButton.new()
	cp.color = value
	cp.focus_mode = Control.FOCUS_NONE
	cp.edit_alpha = false
	cp.custom_minimum_size = Vector2(0, QVoxelUi.hit_size())
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 取色器的拖动全发生在弹出面板里：开面板 = 起手势，关面板 = 封口，期间 color_changed
	# 只报值。这样一次取色 = 一条命令，而不是每动一帧记一条。
	cp.pressed.connect(func() -> void:
		_dragging = o
		edit_began.emit(o, prop))
	cp.color_changed.connect(func(c: Color) -> void:
		if _dragging == o:
			value_changed.emit(o, prop, c))
	cp.popup_closed.connect(func() -> void:
		_dragging = null
		edit_ended.emit(o, prop))
	row.add_child(cp)


## 资源型参数（算子本身）：类型下拉 + 递归展开它自己的参数。
## 这一行就是"算子参数面板"的全部机制 —— 换算子只是换一个资源实例，面板不用改一行。
func _row_resource(o: Object, prop: StringName, hint_string: String, value: Variant,
		depth: int) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	var cands := candidate_classes(hint_string)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.clip_text = true
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_item("（无）", 0)
	var cur := -1
	if value is Resource:
		var cur_name := QVoxelModifierSerializer.op_type_name(value)
		cur = cands.find(cur_name)
		if cur < 0:
			# 当前类型不在候选里（脚本改了名、或候选表不全）：补进去，否则下拉框会显示错的类型。
			cands.append(cur_name)
			cur = cands.size() - 1
	for i in cands.size():
		opt.add_item(cands[i], i + 1)
	opt.selected = cur + 1
	opt.item_selected.connect(func(idx: int) -> void:
		if idx == 0:
			_emit_discrete(o, prop, null)
		else:
			var inst: Resource = QVoxelModifierSerializer.instantiate_op(cands[idx - 1])
			if inst != null:
				_emit_discrete(o, prop, inst))
	row.add_child(opt)

	if not (value is Resource):
		return
	if depth >= MAX_DEPTH:
		add_child(QVoxelUi.label("（嵌套已到 %d 层，不再展开）" % MAX_DEPTH,
				QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		return
	var box := MarginContainer.new()
	box.add_theme_constant_override("margin_left", QVoxelUi.space_s())
	add_child(box)
	var sub := QVoxelierInspector.new()
	box.add_child(sub)
	# 子编辑器的手势原样上报：它报的 target 已经是子资源，调用方据此写对地方。
	sub.edit_began.connect(func(t: Object, p: StringName) -> void: edit_began.emit(t, p))
	sub.value_changed.connect(func(t: Object, p: StringName, v: Variant) -> void:
		value_changed.emit(t, p, v))
	sub.edit_ended.connect(func(t: Object, p: StringName) -> void: edit_ended.emit(t, p))
	sub.bind(value, maxi(_label_width - QVoxelUi.space_s(), QVoxelUi.hit_size()))


## 兜底：不认识的类型也要让人看见"这里有个参数"，而不是静默消失。
func _row_readonly(prop: StringName, value: Variant) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	add_child(row)
	row.add_child(_name_label(prop))
	var l := QVoxelUi.label(str(value), QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(l)


# 候选类与数值工具

## 候选算子类：以 hint_string（如 "Sdf"）为基类，从全局类表里捞出它的全部后代。
## 【为什么不用 ClassDB.get_inheriters_from_class】它只认引擎原生类；Sdf / PcgModel 都是
## GDScript 类，全局类表（ProjectSettings.get_global_class_list）才是它们的权威来源。
static func candidate_classes(base_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	if base_name.is_empty():
		return out
	var all := ProjectSettings.get_global_class_list()
	var base_of := {}
	for e in all:
		base_of[String(e.get("class", ""))] = String(e.get("base", ""))
	for e in all:
		var cls := String(e.get("class", ""))
		if cls.is_empty():
			continue
		var cur := cls
		var guard := 0
		while base_of.has(cur) and guard < 64:
			cur = base_of[cur]
			guard += 1
			if cur == base_name:
				out.append(cls)
				break
	out.sort()
	return out


static func _with_axis(cur: Variant, axis: int, v: float, is_int: bool) -> Variant:
	var c := [0.0, 0.0, 0.0]
	if cur is Vector3 or cur is Vector3i:
		c = [float(cur.x), float(cur.y), float(cur.z)]
	c[axis] = v
	if is_int:
		return Vector3i(int(c[0]), int(c[1]), int(c[2]))
	return Vector3(c[0], c[1], c[2])


static func _fmt(v: float, is_int: bool) -> String:
	return str(int(round(v))) if is_int else String.num(v, 3)