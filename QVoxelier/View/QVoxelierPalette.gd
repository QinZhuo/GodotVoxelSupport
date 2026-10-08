@tool
class_name QVoxelierPalette
extends QVoxelierPanel
## 底部调色板 —— 材质色块条。**颜色本身就是内容**，故块面取自材质而不是主题色。
##
## 【为什么调色板必须有 UI】此前材质只能靠数字键 1..8 选，且工程里到底有几个材质、
## 分别是什么颜色，界面上完全看不到。打开一个别人做的 256 色工程时，那等于没有色板。
##
## 【为什么面板宽度按内容算】色块数量由世界决定（8 个起步，导入的工程可能上百）。
## 让面板只占它真正需要的宽度（上限 PALETTE_MAX_W 后转横向滚动），两侧留白直接透给
## 3D 视口 —— 底边是唯一一条"最不想被拦住"的区域，全宽色板会在平板上平白吃掉一截画布。
##
## 【为什么选中靠描边而不是变色】色块颜色就是"这个材质长什么样"，若用变色表示选中，
## 用户就看不出自己选的是什么颜色了。于是选中态用一圈加粗强调描边（见 QVoxUi.swatch）。
##
## 【与热键同源】数字键 1..8 与点击色块走的是同一个状态（App 的 _material_id），
## 由 App 在两边都调用 set_current() 回写 —— 不存在"点了色块但下次按键又跳回去"。

signal material_selected(material_id: int)

## 色板条最大宽度，超出转横向滚动。
const PALETTE_MAX_W := 520.0

var _scroll: ScrollContainer
var _row: HBoxContainer
var _current: Label
var _group := ButtonGroup.new()
var _swatches := {}         # material_id → Button
var _need := 0.0            # 色块行完整展开所需的宽度


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_left = QVoxUi.space_m()
	offset_right = -QVoxUi.space_m()
	offset_bottom = -(QVoxUi.status_height() + QVoxUi.space_s())
	# 面板高度 = 色块行 + 上下内边距。此前多留了 20px，是给左侧那个竖排的"材质"小标题
	# 兜底的；现在标题与色块同一行，这 20px 只剩一片空白。
	offset_top = offset_bottom - (QVoxUi.hit_size() + 2 * QVoxUi.space_s())

	# 中间层只负责"把调色板摆在底边正中"：它自己不吃事件，故色板两侧的底边
	# 仍然是可点击的视口区域。
	var center := QVoxUi.hbox()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := QVoxUi.panel(QVoxUi.space_s())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var row := QVoxUi.hbox(QVoxUi.space_s())
	panel.add_child(row)

	# 当前材质：数字键与点击色块共用的状态回显。放在最左与色板相邻 —— 此前它孤零零挂在
	# 整排色块的最右端，与"选中了哪个"隔着一整排，读起来像另一件事的读数。
	# 宽度定死：面板是居中的，一旦从 9 切到 10 文字变宽，整排色块会被推着平移。
	_current = QVoxUi.label("材质 —", QVoxUi.FONT_M, QVoxUi.TEXT)
	_current.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_current.custom_minimum_size.x = 60
	row.add_child(_current)

	_group.allow_unpress = false
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = QVoxUi.hit_size()
	row.add_child(_scroll)

	_row = QVoxUi.hbox(QVoxUi.SPACE_XS)
	_scroll.add_child(_row)


func _notification(what: int) -> void:
	# 视口尺寸变化（平板横竖屏切换、桌面改窗口大小）时重算色板可用宽度。
	if what == NOTIFICATION_RESIZED:
		_clamp_width()


# ----------------------------------------------------------------------------
# 对外：状态同步（只由 App 调用）
# ----------------------------------------------------------------------------

## 重建色板。colors 的**下标即材质 ID**（0 位是空气占位，直接跳过）。
func set_palette(colors: Array[Color]) -> void:
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	_swatches.clear()

	for id in range(1, colors.size()):
		var b := QVoxUi.swatch(colors[id], "材质 %d · %s" % [id, colors[id].to_html(false)])
		b.button_group = _group
		var captured := id
		b.toggled.connect(func(on: bool): if on: material_selected.emit(captured))
		_swatches[id] = b
		_row.add_child(b)

	_need = maxf(float(colors.size() - 1) * (QVoxUi.hit_size() + QVoxUi.SPACE_XS) - QVoxUi.SPACE_XS, QVoxUi.hit_size())
	_clamp_width()


## 高亮当前材质（点击与数字键共用同一条回写路径）。
func set_current(material_id: int) -> void:
	_current.text = "材质 %d" % material_id
	for id in _swatches:
		var b: Button = _swatches[id]
		b.set_pressed_no_signal(id == material_id)
	_scroll_into_view(material_id)


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _clamp_width() -> void:
	if _scroll == null:
		return
	# 色板条可用宽度 = 面板总宽 − 左侧"材质 N"标签 − 面板左右内边距 − 标签与色板间的间距。
	# **这四样都得减掉**：只减内边距的话，面板会比可用宽度更宽，被顶出屏幕右缘（色块被裁一截）。
	# 再取 PALETTE_MAX_W 为上限 —— 宽屏上色板也不该铺满整条底边（底边要尽量透给 3D 视口）。
	var chrome := 3.0 * QVoxUi.space_s() + _current.custom_minimum_size.x
	var avail := maxf(size.x - chrome, 200.0)
	_scroll.custom_minimum_size.x = minf(_need, minf(PALETTE_MAX_W, avail))


## 选中的色块滚进可见范围：用键盘切材质时，色板也要跟着走，
## 否则"按了 9 但屏幕上什么都没动"，用户会以为没生效。
func _scroll_into_view(material_id: int) -> void:
	if not _swatches.has(material_id) or _scroll == null:
		return
	var b: Button = _swatches[material_id]
	await get_tree().process_frame
	if is_instance_valid(b) and is_instance_valid(_scroll):
		_scroll.ensure_control_visible(b)
