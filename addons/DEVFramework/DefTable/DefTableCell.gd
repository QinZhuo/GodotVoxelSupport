@tool
## DefTable 类型化单元格基类。
## 每种显示类型一个子类(Text/Number/Bool/Color/Resource/Array/Dict),
## 通过 make_cell() 工厂创建。单元格本身是 Control, 子节点:
##   - Back   : 背景(斑马纹/行染色)
##   - Sel    : 选中高亮
##   - Content: 内容节点(由子类创建)
## 参考 resources_spreadsheet_view 的 cell_editor 类型化架构。
##
## ⚠ 池化复用与尺寸钳制: 单元格在 View 的两级对象池中跨行/跨目录复用,
##   上一任行的 custom_minimum_size 会把新 size 向上钳制成旧行高(视觉重叠伪影)。
##   约定: 复用侧设 size 前必须先归零 minsize(View 侧 _attach_cell/_fill_row 已处理);
##   本类不自行维护 minsize, 其值始终由 View 的 _fill_cell 按当前行高写入。
class_name DefTableCell
extends Control

## 显示类型(与列无关的展示类别)
enum Kind { TEXT, NUMBER, BOOL, COLOR, RESOURCE, ARRAY, DICT, ENUM }

const ROW_HEIGHT := 32.0
const CELL_MARGIN_L := 4.0
const CELL_MARGIN_R := 2.0
const CELL_MARGIN_T := 2.0
const CELL_MARGIN_B := 2.0

## 当前显示类型
var kind: int = Kind.TEXT

## 背景色(斑马纹), 由 View 设置
var bg_color := Color(0, 0, 0, 0.06):
	set(c):
		bg_color = c
		if is_instance_valid(_back):
			_back.color = c

## 行染色(颜色列的值染色整行, 参考 resources_spreadsheet_view)
var row_tint := Color(1, 1, 1, 0):
	set(c):
		row_tint = c
		if is_instance_valid(_back):
			# 染色只叠加 RGB, 保留背景 alpha(参考 modulate 机制)
			var tinted := bg_color
			if c.a > 0.0:
				tinted = Color(
					lerpf(bg_color.r, c.r, c.a),
					lerpf(bg_color.g, c.g, c.a),
					lerpf(bg_color.b, c.b, c.a),
					bg_color.a)
			_back.color = tinted

var _back: ColorRect
var _sel: ColorRect
var _content: Control


static var _script: GDScript


static func make_cell(kind: int) -> DefTableCell:
	var cell: DefTableCell
	match kind:
		Kind.COLOR:
			cell = _make(Kind.COLOR)
			cell._build_color_cell()
		Kind.RESOURCE:
			cell = _make(Kind.RESOURCE)
			cell._build_resource_cell()
		Kind.NUMBER:
			cell = _make(Kind.NUMBER)
			cell._build_label_cell()
		Kind.BOOL:
			cell = _make(Kind.BOOL)
			cell._build_label_cell()
		Kind.ENUM:
			cell = _make(Kind.ENUM)
			cell._build_label_cell()
		Kind.ARRAY:
			cell = _make(Kind.ARRAY)
			cell._build_label_cell()
		Kind.DICT:
			cell = _make(Kind.DICT)
			cell._build_label_cell()
		_:
			cell = _make(Kind.TEXT)
			cell._build_label_cell()
	return cell


static func _make(kind: int) -> DefTableCell:
	if _script == null:
		_script = load("res://addons/DEVFramework/DefTable/DefTableCell.gd") as GDScript
	var cell: DefTableCell = _script.new()
	cell.kind = kind
	return cell


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(90.0, ROW_HEIGHT)

	_back = ColorRect.new()
	_back.name = &"Back"
	_back.color = bg_color
	_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_back)

	_sel = ColorRect.new()
	_sel.name = &"Sel"
	# 参考 resources_spreadsheet_view: 选中用白色半透明高亮
	_sel.color = Color(1, 1, 1, 0.25)
	_sel.visible = false
	_sel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_sel)

	# 网格线(参考 resources_spreadsheet_view 的分隔逻辑)
	var vline := ColorRect.new()
	vline.name = &"VLine"
	vline.color = Color(0, 0, 0, 0.14)
	vline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vline.anchor_left = 1.0
	vline.anchor_right = 1.0
	vline.anchor_top = 0.0
	vline.anchor_bottom = 1.0
	vline.offset_left = -1
	vline.offset_right = 0
	vline.offset_top = 0
	vline.offset_bottom = 0
	add_child(vline)

	var hline := ColorRect.new()
	hline.name = &"HLine"
	hline.color = Color(0, 0, 0, 0.14)
	hline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hline.anchor_left = 0.0
	hline.anchor_right = 1.0
	hline.anchor_top = 1.0
	hline.anchor_bottom = 1.0
	hline.offset_left = 0
	hline.offset_right = 0
	hline.offset_top = -1
	hline.offset_bottom = 0
	add_child(hline)


func set_selected(selected: bool) -> void:
	_sel.visible = selected


## 由子类/工厂构建内容节点。基类默认: 无内容。
func _build_content() -> void:
	pass


## 通用文本内容节点(RichTextLabel, 单元格内布局)
func _build_label_cell() -> void:
	var lb := RichTextLabel.new()
	lb.name = &"Content"
	lb.bbcode_enabled = true
	lb.scroll_active = false
	# 清除默认主题背景(否则编辑器主题会给 RichTextLabel 圆角面板背景)
	var sb := StyleBoxEmpty.new()
	lb.add_theme_stylebox_override("normal", sb)
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 单元格内容: 垂直居中 + 水平左对齐(长文本/数字列表时左对齐更易阅读)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.set_anchors_preset(Control.PRESET_FULL_RECT)
	lb.offset_left = CELL_MARGIN_L
	lb.offset_right = -CELL_MARGIN_R
	lb.offset_top = CELL_MARGIN_T
	lb.offset_bottom = -CELL_MARGIN_B
	add_child(lb)
	_content = lb


## 设置内容水平对齐(由 View 按列类型调用: 数值右对齐/bool 居中/文本左对齐)
func set_content_align(align: int) -> void:
	if kind == Kind.RESOURCE:
		var rlb := _content.get_node_or_null(NodePath("Label")) as RichTextLabel
		if rlb:
			rlb.horizontal_alignment = align
		return
	var rtl := _content as RichTextLabel
	if rtl:
		rtl.horizontal_alignment = align


func _build_color_cell() -> void:
	# 色块(填满单元格, 上下留边)
	var sw := ColorRect.new()
	sw.name = &"Content"
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sw.set_anchors_preset(Control.PRESET_FULL_RECT)
	sw.offset_left = CELL_MARGIN_L
	sw.offset_right = -CELL_MARGIN_R
	sw.offset_top = 3
	sw.offset_bottom = -3
	add_child(sw)
	_content = sw


func _build_resource_cell() -> void:
	# 预览图 + 文本
	var box := HBoxContainer.new()
	box.name = &"Content"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = CELL_MARGIN_L
	box.offset_right = -CELL_MARGIN_R
	box.offset_top = CELL_MARGIN_T
	box.offset_bottom = -CELL_MARGIN_B
	box.alignment = BoxContainer.ALIGNMENT_BEGIN

	var tex := TextureRect.new()
	tex.name = &"Preview"
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.custom_minimum_size = Vector2(18, 18)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tex.visible = false
	box.add_child(tex)

	var lb := RichTextLabel.new()
	lb.name = &"Label"
	lb.bbcode_enabled = true
	lb.scroll_active = false
	# 清除默认主题背景
	var sb := StyleBoxEmpty.new()
	lb.add_theme_stylebox_override("normal", sb)
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 资源单元格文本: 垂直居中 + 水平左对齐
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.add_child(lb)

	add_child(box)
	_content = box


## 上次填充的文本(同值跳过守卫): 池复用/滚动重填时避免 RichTextLabel 同文重解析
var _last_text := ""


## 设置内容值。text 为已格式化的展示文本。
func set_value_text(text: String) -> void:
	if kind == Kind.COLOR:
		return
	if _content == null or text == _last_text:
		return
	_last_text = text
	match kind:
		Kind.RESOURCE:
			var lb := _content.get_node_or_null(NodePath("Label")) as RichTextLabel
			if lb:
				lb.text = text
		_:
			var rtl := _content as RichTextLabel
			if rtl:
				rtl.text = text


## 设置颜色值(仅 COLOR 类型)
func set_color_value(color: Color) -> void:
	if kind != Kind.COLOR:
		return
	var sw := _content as ColorRect
	if sw:
		sw.color = color


## 设置资源预览图(仅 RESOURCE 类型, 异步加载后调用)
func set_resource_preview(texture: Texture2D) -> void:
	if kind != Kind.RESOURCE:
		return
	var box := _content as HBoxContainer
	if box == null:
		return
	var tex := box.get_node_or_null(NodePath("Preview")) as TextureRect
	if tex:
		tex.visible = texture != null
		if texture != null:
			tex.texture = texture
# touch
