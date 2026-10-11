@tool
class_name QVoxelierObjectSection
extends QVoxelierSection
## 右侧抽屉·**对象属性**分组：显示当前在层级里选中的那个节点的数据。
## 【为什么要有它】层级树（Outliner）负责"选谁"，本组负责"它是什么"—— 与 Blender 的
## Outliner + Properties 分工一致。选中模型看尺寸 / 体素数，选中组看子模型数；改名与
## 可见 / 锁定也在这里再给一份入口（树上也有，但属性区里能一眼看到当前对象全貌）。
## 【只读信息 + 轻量编辑】尺寸 / 体素数这类是**求值产物**，这里只读展示；改名是低频结构改动，
## 走与树同一条 rename 信号、由 App 记成命令。

signal rename_requested(node: QVoxelNode, new_name: String)
signal visible_changed(node: QVoxelNode, value: bool)
signal locked_changed(node: QVoxelNode, value: bool)
signal offset_changed(node: QVoxelNode, value: Vector3i)
signal resize_requested(node: QVoxelNode, value: Vector3i)
## 世界级旋转：三个轴的欧拉角（度）。轴对齐时为 90 的倍数。
signal rotation_changed(node: QVoxelNode, degrees: Vector3)

var _node: QVoxelNode
var _name: LineEdit
var _vis: Button
var _lock: Button
var _offset_spins: Array[SpinBox] = []
var _size_spins: Array[SpinBox] = []
var _rot_spins: Array[SpinBox] = []
var _info: VBoxContainer


func section_title() -> String:
	return "对象"


func _build_body(body: VBoxContainer) -> void:
	var head := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(head)
	_name = QVoxelUi.text_field("", "名称", "节点名（回车或失焦提交）")
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.text_submitted.connect(func(t: String) -> void:
		if _node != null and t != _node.display_name():
			rename_requested.emit(_node, t))
	_name.focus_exited.connect(func() -> void:
		if _node != null and _name.text != _node.display_name():
			rename_requested.emit(_node, _name.text))
	head.add_child(_name)

	var toggles := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(toggles)
	_vis = QVoxelUi.toggle_button("显示 / 隐藏（沿树继承）")
	_vis.text = "可见"
	_vis.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vis.toggled.connect(func(on: bool) -> void:
		if _node != null: visible_changed.emit(_node, on))
	toggles.add_child(_vis)
	_lock = QVoxelUi.toggle_button("锁定（沿树继承，锁上后整棵子树不可编辑）")
	_lock.text = "锁定"
	_lock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lock.toggled.connect(func(on: bool) -> void:
		if _node != null: locked_changed.emit(_node, on))
	toggles.add_child(_lock)

	# 位置：节点在父画布里的偏移（去链后摆放回到节点本身）。三个轴各自可调。
	var posrow := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(posrow)
	var plabel := QVoxelUi.label("位置", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	plabel.custom_minimum_size.x = 32
	plabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	posrow.add_child(plabel)
	for _axis in 3:
		var sp := SpinBox.new()
		sp.min_value = -4096
		sp.max_value = 4096
		sp.step = 1
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(_on_offset_spin)
		posrow.add_child(sp)
		_offset_spins.append(sp)

	# 旋转：**世界级**的节点欧拉角（度）。轴对齐吸附到 90° 倍数；显示具体数值而非只有按钮。
	var rotrow := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(rotrow)
	var rlabel := QVoxelUi.label("旋转", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	rlabel.custom_minimum_size.x = 32
	rlabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rotrow.add_child(rlabel)
	for _axis in 3:
		var sp := SpinBox.new()
		sp.min_value = -360
		sp.max_value = 360
		sp.step = 90
		sp.suffix = "°"
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(_on_rotation_spin)
		rotrow.add_child(sp)
		_rot_spins.append(sp)

	# 尺寸：每个模型**独立**的分辨率（体素数上限）。改它是结构级操作（会丢盒外的体素），
	# 由 App 包成一条可撤销命令（QVoxelResizeCommand），这里只上报新值。
	var sizerow := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	body.add_child(sizerow)
	var slabel := QVoxelUi.label("尺寸", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	slabel.custom_minimum_size.x = 32
	slabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sizerow.add_child(slabel)
	for _axis in 3:
		var sp := SpinBox.new()
		sp.min_value = 1
		sp.max_value = 1024
		sp.step = 1
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(_on_size_spin)
		sizerow.add_child(sp)
		_size_spins.append(sp)

	_info = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	body.add_child(_info)
	_rebuild()


## 三个轴任一变化 → 合成 Vector3i 上报（App 记成可撤销的改尺寸命令）。
func _on_size_spin(_v: float) -> void:
	if _node == null or not _node.is_model() or _size_spins.size() < 3:
		return
	resize_requested.emit(_node, Vector3i(
			int(_size_spins[0].value), int(_size_spins[1].value), int(_size_spins[2].value)))


## 旋转三个轴任一变化 → 合成欧拉角（度）上报（App 记成可撤销命令）。
func _on_rotation_spin(_v: float) -> void:
	if _node == null or _rot_spins.size() < 3:
		return
	rotation_changed.emit(_node, Vector3(
			_rot_spins[0].value, _rot_spins[1].value, _rot_spins[2].value))


## 三个轴任一变化 → 合成 Vector3i 上报（App 记成可撤销命令）。
func _on_offset_spin(_v: float) -> void:
	if _node == null or _offset_spins.size() < 3:
		return
	offset_changed.emit(_node, Vector3i(
			int(_offset_spins[0].value), int(_offset_spins[1].value), int(_offset_spins[2].value)))


## 绑定选中的节点（App 在树上点选 / 撤销后调用）。
func bind(node: QVoxelNode) -> void:
	_node = node
	_rebuild()


func _rebuild() -> void:
	if _info == null:
		return
	for c in _info.get_children():
		_info.remove_child(c)
		c.queue_free()
	var has := _node != null
	_name.editable = has
	_vis.disabled = not has
	_lock.disabled = not has
	for sp in _offset_spins:
		sp.editable = has
	for sp in _size_spins:
		sp.editable = has and _node != null and _node.is_model()
	for sp in _rot_spins:
		sp.editable = has
	if has:
		_offset_spins[0].set_value_no_signal(_node.offset.x)
		_offset_spins[1].set_value_no_signal(_node.offset.y)
		_offset_spins[2].set_value_no_signal(_node.offset.z)
		var e := _node.local_transform.basis.get_euler()
		_rot_spins[0].set_value_no_signal(roundf(rad_to_deg(e.x)))
		_rot_spins[1].set_value_no_signal(roundf(rad_to_deg(e.y)))
		_rot_spins[2].set_value_no_signal(roundf(rad_to_deg(e.z)))
	if has and _node.is_model():
		var g := (_node as QVoxelModel).grid_size
		_size_spins[0].set_value_no_signal(g.x)
		_size_spins[1].set_value_no_signal(g.y)
		_size_spins[2].set_value_no_signal(g.z)
	if not has:
		_name.text = ""
		_info.add_child(QVoxelUi.label("（未选中对象）", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))
		return
	# 正在输入时不要回写名字（刷新会打断用户打字）。
	if not _name.has_focus():
		_name.text = _node.display_name()
	_vis.set_pressed_no_signal(_node.visible)
	_lock.set_pressed_no_signal(_node.locked)
	if _node.is_model():
		var m := _node as QVoxelModel
		var g := m.grid_size
		_kv("类型", "模型 #%d" % m.model_id)
		_kv("尺度", "%d × %d × %d" % [g.x, g.y, g.z])
		_kv("体素", "%d" % m.count_solid())
		_kv("位置", "%d, %d, %d" % [m.offset.x, m.offset.y, m.offset.z])
	else:
		var grp := _node as QVoxelGroup
		_kv("类型", "组")
		_kv("子模型", "%d" % grp.count_models())
		_kv("位置", "%d, %d, %d" % [grp.offset.x, grp.offset.y, grp.offset.z])


func _kv(k: String, v: String) -> void:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	_info.add_child(row)
	var key := QVoxelUi.label(k, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	key.custom_minimum_size.x = 48
	row.add_child(key)
	var val := QVoxelUi.label(v, QVoxelUi.FONT_S, QVoxelUi.TEXT)
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(val)
