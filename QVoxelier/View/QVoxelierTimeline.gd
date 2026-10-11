@tool
class_name QVoxelierTimeline
extends QVoxelierPanel
## 底部**动画帧条** —— 与状态栏**同高、同一种横条样式**，紧贴其上方，只显示当前模型的帧。
## 【为什么贴着状态栏、同一样式】两者都是底部常驻的横带，做成同一种无圆角描边、等高的横条，
## 视觉上是一整条底栏。
## 【新建帧放在帧末】帧是一条时间轴，最自然的"往后加一帧"就是**在最后一帧右侧点一下 ＋**
## （新帧默认复制最后一帧）——不必再记"先选帧、再按加"。静态模型点它即自动转成动画，
## 故不再需要单独的「做成动画」按钮。

signal frame_selected(index: int)
## 在末尾新建一帧（复制最后一帧；静态模型会先转成动画）。
signal append_frame_requested()
## 在当前帧后插入一帧（右键菜单用；duplicate = 复制当前帧）。
signal insert_frame_requested(duplicate: bool)
signal remove_frame_requested()
signal move_frame_requested(from: int, to: int)
signal play_toggled(on: bool)
signal loop_toggled(on: bool)

const CELL_W := 26.0

var _model: QVoxelModel
var _ruler: _Ruler
var _play: Button
var _loop: Button
var _frame_label: Label
var _rm: Button


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_bottom = -QVoxelUi.status_height()
	offset_top = offset_bottom - QVoxelUi.strip_height()

	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel",
			QVoxelUi.box(QVoxelUi.BAR, Color(0, 0, 0, 0), 0, 0, QVoxelUi.space_m(), 0))
	bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bar)

	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	bar.add_child(row)

	# 控件高度统一（与帧标尺一致），否则"帧标记"和按钮一高一矮看着乱。
	var bs := QVoxelUi.status_height() - 4

	# 帧标尺：帧格子 + 末尾的 ＋ 新建格。点格切帧、拖格重排、右键增删。
	_ruler = _Ruler.new()
	_ruler.timeline = self
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ruler.custom_minimum_size.y = bs
	row.add_child(_ruler)

	# 右侧：当前帧号 / 播放 / 循环 / 删除当前帧。
	_frame_label = QVoxelUi.label("0", QVoxelUi.FONT_M, QVoxelUi.TEXT)
	_frame_label.custom_minimum_size = Vector2(22, 0)
	_frame_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_frame_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_frame_label)
	_play = QVoxelUi.toggle_button("播放 / 暂停（只动预览游标，不写数据）", QVoxelUi.VARIATION_TOOL, "▶")
	_play.custom_minimum_size = Vector2(bs, bs)
	_play.toggled.connect(func(on: bool) -> void:
		_play.text = "⏸" if on else "▶"
		play_toggled.emit(on))
	row.add_child(_play)
	_loop = QVoxelUi.toggle_button("循环播放（落盘为 anim.loop）", QVoxelUi.VARIATION_TOOL, "⇄")
	_loop.custom_minimum_size = Vector2(bs, bs)
	_loop.toggled.connect(func(on: bool): loop_toggled.emit(on))
	row.add_child(_loop)
	_rm = QVoxelUi.icon_button("－", "删除当前帧（至少留一帧）", bs)
	_rm.pressed.connect(func(): remove_frame_requested.emit())
	row.add_child(_rm)

	_bind_ui()


## 绑定当前模型（App 在切对象 / 刷新时调用）。
func bind(model: QVoxelModel) -> void:
	_model = model
	_bind_ui()


## 回写播放按下态（App 主动停播放时用）。
func set_playing(on: bool) -> void:
	if _play != null and _play.button_pressed != on:
		_play.set_pressed_no_signal(on)
		_play.text = "⏸" if on else "▶"


func _frame_has(f: int) -> bool:
	if _model == null:
		return false
	if not _model.is_animated():
		return _model.count_solid() > 0
	var fr := _model.frame_at(f)
	return fr != null and not fr.is_empty()


func _bind_ui() -> void:
	if _ruler == null:
		return
	var m := _model
	var animated := m != null and m.is_animated()
	var n := maxi(m.frame_count(), 1) if m != null else 0
	var active := clampi(m.active_frame, 0, maxi(n - 1, 0)) if m != null else 0
	_frame_label.text = str(active) if n > 0 else "—"
	_rm.disabled = n <= 1
	_play.disabled = not animated
	_loop.disabled = not animated
	_loop.set_pressed_no_signal(m != null and m.anim_loop)
	# 标尺宽度 = 帧数 + 末尾的新建格。
	_ruler.custom_minimum_size.x = float((maxi(n, 1) + 1) * CELL_W)
	_ruler.queue_redraw()


## 标尺右键菜单：在点中的帧后插入空帧 / 复制 / 删除。
func _frame_context(index: int, at: Vector2) -> void:
	frame_selected.emit(index)
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("在此帧后插入空帧", 0)
	menu.add_item("复制此帧到其后", 1)
	menu.add_item("删除此帧", 2)
	menu.id_pressed.connect(_on_frame_menu)
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_frame_menu(id: int) -> void:
	match id:
		0:
			insert_frame_requested.emit(false)
		1:
			insert_frame_requested.emit(true)
		2:
			remove_frame_requested.emit()


## 帧标尺：顶部 tag 条 + 帧格子 + 末尾新建格。点切帧 / 拖重排 / 右键增删 / 点＋新建。
class _Ruler extends Control:
	var timeline: QVoxelierTimeline
	var _press := -1

	func _draw() -> void:
		var m := timeline._model
		if m == null:
			return
		var n := maxi(m.frame_count(), 1)
		var h := size.y
		var active := clampi(m.active_frame, 0, n - 1)
		var tag_h := 8.0
		if m.is_animated():
			for t in m.anim_tags:
				if not (t is Dictionary):
					continue
				var from_i := clampi(int(t.get("from", 0)), 0, n - 1)
				var to_i := clampi(int(t.get("to", from_i)), from_i, n - 1)
				var x0 := from_i * CELL_W
				var w := (to_i - from_i + 1) * CELL_W
				draw_rect(Rect2(x0 + 1, 0, maxf(w - 2, 1), tag_h), Color(QVoxelUi.ACCENT, 0.32))
				if w > 30:
					draw_string(ThemeDB.fallback_font, Vector2(x0 + 4, tag_h - 1),
							String(t.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, int(w) - 6, 9,
							QVoxelUi.TEXT)
		for f in n:
			var x := (f + 0.5) * CELL_W
			if f == active:
				draw_rect(Rect2(x - CELL_W * 0.5, tag_h, CELL_W, h - tag_h), Color(QVoxelUi.ACCENT, 0.28))
			draw_line(Vector2(x, tag_h + 2), Vector2(x, h - 3), Color(1, 1, 1, 0.09), 1.0)
		for f in n:
			if timeline._frame_has(f):
				var x := (f + 0.5) * CELL_W
				var cy := (tag_h + h) * 0.5
				var d := 4.5
				draw_colored_polygon([
					Vector2(x, cy - d), Vector2(x + d, cy), Vector2(x, cy + d), Vector2(x - d, cy),
				], QVoxelUi.ACCENT if f == active else QVoxelUi.TEXT_DIM)
		# 末尾的新建格：一个 ＋（点它 = 复制最后一帧追加）。
		var ax := n * CELL_W + CELL_W * 0.5
		var cy2 := (tag_h + h) * 0.5
		draw_line(Vector2(ax - 5, cy2), Vector2(ax + 5, cy2), QVoxelUi.TEXT_DIM, 1.5)
		draw_line(Vector2(ax, cy2 - 5), Vector2(ax, cy2 + 5), QVoxelUi.TEXT_DIM, 1.5)

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton):
			return
		var m := timeline._model
		if m == null:
			return
		var n := maxi(m.frame_count(), 1)
		var f := int(event.position.x / CELL_W)
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if f >= n:
					timeline.append_frame_requested.emit()
				else:
					_press = f
					timeline.frame_selected.emit(f)
				accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT and f < n:
				timeline._frame_context(f, get_global_mouse_position())
				accept_event()
		else:
			if event.button_index == MOUSE_BUTTON_LEFT and _press >= 0:
				if f != _press and f < n:
					timeline.move_frame_requested.emit(_press, f)
				_press = -1
				accept_event()
