@tool
class_name QVoxelierBrushSection
extends QVoxelierSection
## 右侧抽屉·**自定义笔刷**分组：挑一个做好的模型，把它抓成笔刷图案，再用左列「笔刷」工具到处盖章。
## 【为什么是"抓一个模型"】用户最直观的自定义笔刷来源就是"我已经画好的那个东西"；
## 抓取后图案与手绘完全同构，笔刷就是"把这块体素盖到别处"。

signal capture_requested(model_id: int)

var _pick: OptionButton
var _ids: Array[int] = []
var _info: Label


func section_title() -> String:
	return "笔刷"


func _build_body(body: VBoxContainer) -> void:
	_pick = OptionButton.new()
	_pick.focus_mode = Control.FOCUS_NONE
	_pick.clip_text = true
	_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_pick)

	var cap := QVoxelUi.button("抓取选中模型为笔刷", "把下拉里选的模型抓成笔刷图案（空模型不可用）")
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap.pressed.connect(func() -> void:
		var i := _pick.selected
		if i >= 0 and i < _ids.size():
			capture_requested.emit(_ids[i]))
	body.add_child(cap)

	_info = QVoxelUi.label("尚未抓取笔刷", QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_info)

	body.add_child(QVoxelUi.label("用左列「笔刷」工具在视口里点击盖章。",
			QVoxelUi.FONT_S, QVoxelUi.TEXT_FAINT))


## 刷新模型下拉（App 在换世界 / 增删对象后调用）。
func set_world(world: QVoxelWorld, active_id: int) -> void:
	if _pick == null:
		return
	_pick.clear()
	_ids.clear()
	if world == null:
		return
	var sel := 0
	for m in world.all_models():
		if m == null:
			continue
		if m.model_id == active_id:
			sel = _ids.size()
		_pick.add_item("%s（%d 体素）" % [m.display_name(), m.count_solid()], _ids.size())
		_ids.append(m.model_id)
	_pick.selected = sel


## 回显当前笔刷图案（空 = 没抓）。
func set_pattern(pattern: Dictionary) -> void:
	if _info == null:
		return
	if pattern.is_empty():
		_info.text = "尚未抓取笔刷"
		return
	var size: Vector3i = pattern["size"]
	_info.text = "笔刷尺寸 %d×%d×%d · %d 体素" % [size.x, size.y, size.z, (pattern["cells"] as Array).size()]
