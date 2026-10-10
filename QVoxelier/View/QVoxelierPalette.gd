@tool
class_name QVoxelierPalette
extends QVoxelierPanel
## 底部调色板 —— 材质色块条。**颜色本身就是内容**，故块面取自材质而不是主题色。
## 【为什么调色板必须有 UI】此前材质只能靠数字键 1..8 选，且工程里到底有几个材质、
## 分别是什么颜色，界面上完全看不到。打开一个别人做的 256 色工程时，那等于没有色板。
## 【为什么面板宽度按内容算】色块数量由世界决定（8 个起步，导入的工程可能上百）。
## 让面板只占它真正需要的宽度（上限 PALETTE_MAX_W 后转横向滚动），两侧留白直接透给
## 3D 视口 —— 底边是唯一一条"最不想被拦住"的区域，全宽色板会在平板上平白吃掉一截画布。
## 【为什么选中靠描边而不是变色】色块颜色就是"这个材质长什么样"，若用变色表示选中，
## 用户就看不出自己选的是什么颜色了。于是选中态用一圈加粗强调描边（见 QVoxelUi.swatch）。
## 【与热键同源】数字键 1..8 与点击色块走的是同一个状态（App 的 _material_id），
## 由 App 在两边都调用 set_current() 回写 —— 不存在"点了色块但下次按键又跳回去"。

signal material_selected(material_id: int)

## 色板条最大宽度，超出转横向滚动。
const PALETTE_MAX_W := 520.0

var _scroll: ScrollContainer
var _row: HBoxContainer
var _current: Label
var _collapse: Button
var _expanded := true
var _group := ButtonGroup.new()
var _swatches := {}         # material_id → Button
var _need := 0.0            # 色块行完整展开所需的宽度
var _sig := PackedStringArray()   # 上一次建好的颜色序列（判重，见 set_palette）


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_left = QVoxelUi.space_m()
	offset_right = -QVoxelUi.space_m()
	offset_bottom = -(QVoxelUi.status_height() + QVoxelUi.space_s())
	# 面板高度 = 色块行 + 上下内边距。此前多留了 20px，是给左侧那个竖排的"材质"小标题
	# 兜底的；现在标题与色块同一行，这 20px 只剩一片空白。
	offset_top = offset_bottom - (QVoxelUi.hit_size() + 2 * QVoxelUi.space_s())

	# 中间层只负责"把调色板摆在底边正中"：它自己不吃事件，故色板两侧的底边
	# 仍然是可点击的视口区域。
	var center := QVoxelUi.hbox()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := QVoxelUi.panel(QVoxelUi.space_s())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var row := QVoxelUi.hbox(QVoxelUi.space_s())
	panel.add_child(row)

	# 折叠开关：底边是最不想被拦住的一条，色板不用时可以收成"▸ 材质 N"一小块。
	_collapse = QVoxelUi.icon_button("▾", "折叠 / 展开调色板（收起后只留当前材质）")
	_collapse.pressed.connect(func(): set_expanded(not _expanded))
	row.add_child(_collapse)

	# 当前材质：数字键与点击色块共用的状态回显。放在最左与色板相邻 —— 此前它孤零零挂在
	# 整排色块的最右端，与"选中了哪个"隔着一整排，读起来像另一件事的读数。
	# 宽度定死：面板是居中的，一旦从 9 切到 10 文字变宽，整排色块会被推着平移。
	_current = QVoxelUi.label("材质 —", QVoxelUi.FONT_M, QVoxelUi.TEXT)
	_current.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_current.custom_minimum_size.x = 60
	row.add_child(_current)

	_group.allow_unpress = false
	_scroll = QVoxelUi.scroll(false, QVoxelUi.hit_size())
	row.add_child(_scroll)

	_row = QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_scroll.add_child(_row)


func _notification(what: int) -> void:
	# 视口尺寸变化（平板横竖屏切换、桌面改窗口大小）时重算色板可用宽度。
	if what == NOTIFICATION_RESIZED:
		_clamp_width()


# 对外：状态同步（只由 App 调用）

## 重建色板。colors 的**下标即材质 ID**（0 位是空气占位，直接跳过）。
## 颜色序列没变就直接返回：本方法是"挂在一处刷新"的（见 QVoxelierApp._refresh_hud），
## 而刷新在每画一笔后都会走一遍 —— 不判重的话每次落笔都要拆掉重建八个按钮。
## 判重也顺手治了"新建 / 打开工程后色板是空的"（此前只有打开工程那条路会喂色板）。
func set_palette(colors: Array[Color]) -> void:
	var sig := PackedStringArray()
	for c in colors:
		sig.append(c.to_html(true))
	if sig == _sig:
		return
	_sig = sig

	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	_swatches.clear()

	for id in range(1, colors.size()):
		var b := QVoxelUi.swatch(colors[id], "材质 %d · %s" % [id, colors[id].to_html(false)])
		b.button_group = _group
		var captured := id
		b.toggled.connect(func(on: bool): if on: material_selected.emit(captured))
		_swatches[id] = b
		_row.add_child(b)

	_need = maxf(float(colors.size() - 1) * (QVoxelUi.hit_size() + QVoxelUi.SPACE_XS) - QVoxelUi.SPACE_XS, QVoxelUi.hit_size())
	_clamp_width()


## 单个色块就地换色（实时改色时用）。整条重建会每帧扔掉八个按钮并清掉 hover，
## 故拖动颜色滑块走这条窄路，松手后的 set_palette 再按指纹收尾。
func set_color(material_id: int, color: Color) -> void:
	var b: Button = _swatches.get(material_id)
	if b == null:
		return
	QVoxelUi.paint_swatch(b, color)
	b.tooltip_text = "材质 %d · %s" % [material_id, color.to_html(false)]
	if material_id < _sig.size():
		_sig[material_id] = color.to_html(true)


## 高亮当前材质（点击与数字键共用同一条回写路径）。
func set_current(material_id: int) -> void:
	_current.text = "材质 %d" % material_id
	for id in _swatches:
		var b: Button = _swatches[id]
		b.set_pressed_no_signal(id == material_id)
	if _expanded:
		_scroll_into_view(material_id)


## 折叠 / 展开色板。收起时只留"▸ 材质 N"，把底边让回给 3D 视口。
func set_expanded(on: bool) -> void:
	if on == _expanded:
		return
	_expanded = on
	_collapse.text = "▾" if on else "▸"
	_scroll.visible = on
	_clamp_width()


# 内部

func _clamp_width() -> void:
	if _scroll == null:
		return
	# 色板条可用宽度 = 面板总宽 − 左侧"材质 N"标签 − 面板左右内边距 − 标签与色板间的间距。
	# **这四样都得减掉**：只减内边距的话，面板会比可用宽度更宽，被顶出屏幕右缘（色块被裁一截）。
	# 再取 PALETTE_MAX_W 为上限 —— 宽屏上色板也不该铺满整条底边（底边要尽量透给 3D 视口）。
	var chrome := 3.0 * QVoxelUi.space_s() + _current.custom_minimum_size.x
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
