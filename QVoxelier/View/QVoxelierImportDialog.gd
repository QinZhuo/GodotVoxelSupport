@tool
class_name QVoxelierImportDialog
extends ConfirmationDialog
## 导入模型的参数：分辨率 / 替换还是追加 / 实心还是空壳。

## 可选分辨率 = 模型最长边的体素数（其余轴按比例）。
const RESOLUTIONS := [32, 64, 96, 128, 192, 256]

var _resolution: OptionButton
var _resolution_row: HBoxContainer
var _append: CheckBox
var _fill: CheckBox
var _choosing_file := true

## 体素文件（`.vox`）只需问"追加还是替换"：分辨率与实心是三角网格体素化才有的参数。
func set_world_only(on: bool) -> void:
	_resolution_row.visible = not on
	_fill.visible = not on
	title = "导入体素" if on else "导入模型"

func _init() -> void:
	title = "导入模型"
	cancel_button_text = "取消"
	# 对话框是独立 Window，不会从父链继承主题（同 QVoxelierApp._build_dialogs 的说明）。
	theme = QVoxelUi.theme()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", QVoxelUi.SPACE_XS)
	add_child(box)

	_resolution = OptionButton.new()
	_resolution.focus_mode = Control.FOCUS_NONE
	_resolution.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for r: int in RESOLUTIONS:
		_resolution.add_item("最长边 %d 体素" % r)
	_resolution_row = _row("分辨率", _resolution)
	box.add_child(_resolution_row)

	_append = _check("追加到当前工程（不勾选 = 替换整个工程）")
	box.add_child(_append)
	_fill = _check("填充内部（不勾选 = 只留表面一层壳）")
	_fill.button_pressed = true
	box.add_child(_fill)
	_sync_ok_text()

## 打开前同步当前设置：分辨率吸附到最近的一档。
func set_defaults(resolution: int, append: bool, fill: bool, choosing_file: bool) -> void:
	_choosing_file = choosing_file
	var best := 0
	for i in RESOLUTIONS.size():
		if absi(int(RESOLUTIONS[i]) - resolution) < absi(int(RESOLUTIONS[best]) - resolution):
			best = i
	_resolution.select(best)
	_append.button_pressed = append
	_fill.button_pressed = fill
	_sync_ok_text()

## 本次导入参数。
func options() -> Dictionary:
	return {
		"resolution": int(RESOLUTIONS[maxi(0, _resolution.selected)]),
		"append": _append.button_pressed,
		"fill": _fill.button_pressed,
	}

func _sync_ok_text() -> void:
	ok_button_text = "选择文件…" if _choosing_file else "导入"

func _row(text: String, c: Control) -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	var l := QVoxelUi.label(text, QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.custom_minimum_size.x = 64
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	row.add_child(c)
	return row

func _check(text: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	return c
