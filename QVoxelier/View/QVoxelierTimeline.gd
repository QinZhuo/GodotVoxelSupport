@tool
class_name QVoxelierTimeline
extends QVoxelierPanel
## 底部统一时间轴：体素帧条 / 播放时钟 / 循环 / 逐帧时长 / 帧率 / 标签。
## 【为什么播放时钟在这里，而不是再养一个隐藏面板】底部帧条就是时间轴本身；
## 播放、时长、帧率、标签都围绕同一条帧轴，放在一起后不再需要"隐藏的 时间轴面板
## 只当内核"这种间接结构。
## 【本面板只报意图，不写数据】帧的增/删/重排/时长/标签全部由 App 包进
## QVoxelPropertyCommand；这里只发信号，撤销语义仍只有 App 一处知识。

signal frame_selected(index: int)
signal append_frame_requested()
signal insert_frame_requested(duplicate: bool)
signal remove_frame_requested()
signal move_frame_requested(from: int, to: int)
signal loop_toggled(on: bool)
signal duration_edit_began(index: int)
signal duration_changed(index: int, ms: int)
signal duration_edit_ended(index: int)
signal fps_changed(fps: int)
signal tags_changed(tags: Array)

const CELL_W := 26.0
const MAX_MS := 1000
## 标签条高度 / 命中高度 / 边缘拖拽容差（像素）。
const TAG_H := 8.0
const TAG_HIT := 11.0
const TAG_EDGE := 5.0

var _model: QVoxelModel
var _ruler: _Ruler
var _play: Button
var _loop: Button
var _frame_label: Label
var _rm: Button
var _settings_btn: Button
var _settings: PopupPanel
var _duration: HSlider
var _duration_label: Label
var _fps: HSlider
var _fps_label: Label
var _tag_pick: OptionButton
var _tag_add: Button
var _tag_edit: Button
var _tag_remove: Button
var _tag_editor: PopupPanel
var _te_name: LineEdit
var _te_from: SpinBox
var _te_to: SpinBox
var _te_dir: OptionButton
var _te_color: ColorPickerButton
var _te_repeat: SpinBox
var _tag_edit_index := -1
var _tag_sig := ""
var _tag_context_index := -1
var _tag_color_popup: PopupPanel
var _tag_color_picker: ColorPicker
var _tag_color_index := -1
## 标签条拖拽预览：拖动期间只改这份副本，松手才发 tags_changed（一次撤销）。
var _drag_tags: Array = []
var _drag_tag_index := -1
var _drag_tag_mode := ""
var _drag_tag_offset := 0
var _drag_tag_moved := false
var _syncing := false
var _editing_duration := false

## 播放内核：逐帧时长 / 循环 / 标签区间 / 方向只在 QVoxelFrameClock 一处实现。
var _clock := QVoxelFrameClock.new()
var _pending_ms := 0
var _clock_sig := ""
var _timer: Timer


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

	var bs := QVoxelUi.status_height() - 4

	_ruler = _Ruler.new()
	_ruler.timeline = self
	_ruler.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ruler.custom_minimum_size.y = bs
	row.add_child(_ruler)

	_frame_label = QVoxelUi.label("0", QVoxelUi.FONT_M, QVoxelUi.TEXT)
	_frame_label.custom_minimum_size = Vector2(26, 0)
	_frame_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_frame_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_frame_label)

	_play = QVoxelUi.toggle_button("播放 / 暂停（只动预览游标，不写数据）",
			QVoxelUi.VARIATION_TOOL, "▶")
	_play.custom_minimum_size = Vector2(bs, bs)
	_play.toggled.connect(_on_play_toggled)
	row.add_child(_play)

	_loop = QVoxelUi.toggle_button("循环播放（模型动画落盘为 anim.loop）",
			QVoxelUi.VARIATION_TOOL, "⇄")
	_loop.custom_minimum_size = Vector2(bs, bs)
	_loop.toggled.connect(func(on: bool): loop_toggled.emit(on))
	row.add_child(_loop)

	_rm = QVoxelUi.icon_button("✕", "删除当前帧（至少留一帧）", bs)
	_rm.pressed.connect(func(): remove_frame_requested.emit())
	row.add_child(_rm)

	_settings_btn = QVoxelUi.icon_button("⚙", "逐帧时长 / 帧率 / 标签", bs)
	_settings_btn.pressed.connect(_open_settings)
	row.add_child(_settings_btn)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_play_tick)
	add_child(_timer)

	_build_settings()
	_bind_ui()


## 绑定当前模型。帧数变了才重建标尺；播放中不重置播放状态。
func bind(model: QVoxelModel) -> void:
	_model = model
	_configure_clock()
	_sync()


func set_playing(on: bool) -> void:
	if _play != null and _play.button_pressed != on:
		_play.set_pressed_no_signal(on)
		_play.text = "⏸" if on else "▶"


func play(on: bool) -> void:
	_on_play_toggled(on)
	set_playing(on)


func stop_playback() -> void:
	_stop()


func is_playing() -> bool:
	return _clock.is_playing()


# 构建：设置弹窗

func _build_settings() -> void:
	_settings = PopupPanel.new()
	_settings.theme = QVoxelUi.theme()
	add_child(_settings)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_settings.add_child(margin)
	var box := QVoxelUi.vbox(QVoxelUi.space_s())
	box.custom_minimum_size.x = 340
	margin.add_child(box)

	box.add_child(QVoxelUi.heading("动画设置"))
	_duration_label = _value_label()
	var dur_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(dur_row)
	dur_row.add_child(QVoxelUi.label("本帧时长", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_duration = QVoxelUi.value_slider(0, MAX_MS, 10, 0)
	_duration.tooltip_text = "0 = 跟随帧率；单位毫秒"
	_duration.value_changed.connect(func(_v: float): _on_duration_changed())
	_duration.drag_started.connect(_on_duration_drag_started)
	_duration.drag_ended.connect(func(_c: bool): _on_duration_drag_ended())
	dur_row.add_child(_duration)
	dur_row.add_child(_duration_label)

	_fps_label = _value_label()
	var fps_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(fps_row)
	fps_row.add_child(QVoxelUi.label("缺省帧率", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_fps = QVoxelUi.value_slider(1, 60, 1, 4)
	_fps.tooltip_text = "某帧时长为 0 时用它（落盘为 anim.fps）"
	_fps.value_changed.connect(func(_v: float): _on_fps_changed())
	fps_row.add_child(_fps)
	fps_row.add_child(_fps_label)

	var tag_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(tag_row)
	tag_row.add_child(QVoxelUi.label("标签", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_tag_pick = OptionButton.new()
	_tag_pick.focus_mode = Control.FOCUS_NONE
	_tag_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tag_pick.item_selected.connect(_on_tag_pick)
	tag_row.add_child(_tag_pick)
	_tag_add = QVoxelUi.icon_button("+", "新建标签")
	_tag_add.pressed.connect(_on_tag_add)
	tag_row.add_child(_tag_add)
	_tag_edit = QVoxelUi.icon_button("✎", "编辑当前标签")
	_tag_edit.pressed.connect(_on_tag_edit)
	tag_row.add_child(_tag_edit)
	_tag_remove = QVoxelUi.icon_button("−", "删除当前标签")
	_tag_remove.pressed.connect(_on_tag_remove)
	tag_row.add_child(_tag_remove)

	_build_tag_editor()
	_build_tag_color_popup()


func _build_tag_color_popup() -> void:
	_tag_color_popup = PopupPanel.new()
	_tag_color_popup.theme = QVoxelUi.theme()
	add_child(_tag_color_popup)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_tag_color_popup.add_child(margin)
	var box := QVoxelUi.vbox(QVoxelUi.space_s())
	margin.add_child(box)
	box.add_child(QVoxelUi.heading("标签颜色"))
	_tag_color_picker = ColorPicker.new()
	_tag_color_picker.edit_alpha = false
	_tag_color_picker.custom_minimum_size = Vector2(280, 300)
	box.add_child(_tag_color_picker)
	var buttons := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	var cancel := QVoxelUi.button("取消")
	cancel.pressed.connect(func(): _tag_color_popup.hide())
	buttons.add_child(cancel)
	var ok := QVoxelUi.button("确定")
	ok.pressed.connect(_on_tag_color_ok)
	buttons.add_child(ok)


func _build_tag_editor() -> void:
	_tag_editor = PopupPanel.new()
	_tag_editor.theme = QVoxelUi.theme()
	add_child(_tag_editor)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_tag_editor.add_child(margin)
	var box := QVoxelUi.vbox(QVoxelUi.space_s())
	box.custom_minimum_size.x = 320
	margin.add_child(box)

	box.add_child(QVoxelUi.heading("编辑标签"))
	_te_name = QVoxelUi.text_field("", "标签名")
	box.add_child(_te_name)

	var range_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(range_row)
	range_row.add_child(QVoxelUi.label("帧范围", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_te_from = _spin(0, 9999)
	_te_to = _spin(0, 9999)
	range_row.add_child(_te_from)
	range_row.add_child(QVoxelUi.label("→", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	range_row.add_child(_te_to)

	var dir_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(dir_row)
	dir_row.add_child(QVoxelUi.label("方向", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_te_dir = OptionButton.new()
	_te_dir.focus_mode = Control.FOCUS_NONE
	_te_dir.add_item("正向", 0)
	_te_dir.add_item("反向", 1)
	_te_dir.add_item("乒乓", 2)
	_te_dir.add_item("乒乓反向", 3)
	dir_row.add_child(_te_dir)
	_te_repeat = _spin(0, 999)
	_te_repeat.tooltip_text = "0 = 无限循环"
	dir_row.add_child(QVoxelUi.label("重复(0=∞)", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	dir_row.add_child(_te_repeat)

	var color_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(color_row)
	color_row.add_child(QVoxelUi.label("颜色", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_te_color = ColorPickerButton.new()
	_te_color.focus_mode = Control.FOCUS_NONE
	_te_color.custom_minimum_size = Vector2(QVoxelUi.hit_size() * 2, QVoxelUi.hit_size())
	color_row.add_child(_te_color)

	var buttons := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(buttons)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var cancel := QVoxelUi.button("取消")
	cancel.pressed.connect(func(): _tag_editor.hide())
	buttons.add_child(cancel)
	var ok := QVoxelUi.button("确定")
	ok.pressed.connect(_on_tag_editor_ok)
	buttons.add_child(ok)


func _spin(lo: int, hi: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = lo
	return s


func _open_settings() -> void:
	if _settings == null:
		return
	_settings.popup_centered(Vector2i(380, 0))


# 同步

func _bind_ui() -> void:
	if _ruler == null:
		return
	var m := _model
	var n := maxi(m.frame_count(), 1) if m != null else 0
	var active := clampi(m.active_frame, 0, maxi(n - 1, 0)) if m != null else 0
	_frame_label.text = str(active) if n > 0 else "—"
	_rm.disabled = n <= 1
	_play.disabled = n <= 1 or m == null or not m.is_animated()
	_loop.disabled = m == null or not m.is_animated()
	_loop.set_pressed_no_signal(m != null and m.anim_loop)
	_ruler.custom_minimum_size.x = float((maxi(n, 1) + 1) * CELL_W)
	_ruler.queue_redraw()


func _sync() -> void:
	_syncing = true
	var m := _model
	var n := 0 if m == null else m.frame_count()
	var animated := n > 0
	var active := _active_index()
	_clock.set_index(active)

	_duration.value = 0 if not animated else m.frame_at(active).duration_ms
	_duration.editable = animated
	_duration_label.text = _duration_text()
	_fps.value = 4 if m == null else m.anim_fps
	_fps.editable = animated
	_fps_label.text = "%d fps" % int(_fps.value)
	_loop.set_pressed_no_signal(true if m == null else m.anim_loop)
	_loop.disabled = not animated
	_sync_tags(animated)
	_bind_ui()
	_syncing = false


func _sync_tags(animated: bool) -> void:
	if _tag_pick == null:
		return
	_tag_pick.disabled = not animated
	_tag_add.disabled = not animated
	_tag_edit.disabled = not animated
	_tag_remove.disabled = not animated
	if not animated:
		_tag_pick.clear()
		_tag_pick.add_item("整段")
		_tag_pick.select(0)
		return
	var tags: Array = _model.anim_tags
	var sig := str(tags)
	if sig != _tag_sig:
		_tag_sig = sig
		_tag_pick.clear()
		_tag_pick.add_item("整段")
		for t in tags:
			if t is Dictionary:
				_tag_pick.add_item(String(t.get("name", "")))
	if _tag_pick.get_popup().visible:
		return
	var want := 0
	for i in tags.size():
		var t: Variant = tags[i]
		if not (t is Dictionary):
			continue
		if _model.active_frame >= int(t.get("from", 0)) \
				and _model.active_frame <= int(t.get("to", 0)):
			want = i + 1
			break
	_tag_pick.select(want)
	_tag_edit.disabled = want <= 0
	_tag_remove.disabled = want <= 0


func _active_index() -> int:
	if _model == null:
		return 0
	return clampi(_model.active_frame, 0, maxi(_model.frame_count() - 1, 0))


func _frame_has(f: int) -> bool:
	if _model == null:
		return false
	if not _model.is_animated():
		return _model.count_solid() > 0
	var fr := _model.frame_at(f)
	return fr != null and not fr.is_empty()


func _value_label() -> Label:
	var l := QVoxelUi.label("", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.custom_minimum_size = Vector2(58, 0)
	return l


# 时长 / 帧率 / 标签

func _duration_text() -> String:
	if _model == null or _model.frame_count() == 0:
		return "—"
	return "跟随帧率" if int(_duration.value) <= 0 else "%d ms" % int(_duration.value)


func _on_duration_changed() -> void:
	_duration_label.text = _duration_text()
	if _syncing or _model == null or not _model.is_animated():
		return
	if _editing_duration:
		duration_changed.emit(_active_index(), int(_duration.value))
		return
	duration_edit_began.emit(_active_index())
	duration_changed.emit(_active_index(), int(_duration.value))
	duration_edit_ended.emit(_active_index())


func _on_duration_drag_started() -> void:
	if _editing_duration or _syncing or _model == null or not _model.is_animated():
		return
	_editing_duration = true
	duration_edit_began.emit(_active_index())


func _on_duration_drag_ended() -> void:
	if not _editing_duration:
		return
	_editing_duration = false
	duration_changed.emit(_active_index(), int(_duration.value))
	duration_edit_ended.emit(_active_index())


func _on_fps_changed() -> void:
	_fps_label.text = "%d fps" % int(_fps.value)
	if _syncing or _model == null or not _model.is_animated():
		return
	fps_changed.emit(int(_fps.value))
	_frame_label.text = str(_active_index())


func _on_tag_pick(index: int) -> void:
	if _syncing or _model == null or not _model.is_animated():
		return
	if index <= 0:
		_preview_tag("")
		return
	var tags: Array = _model.anim_tags
	if index - 1 >= tags.size():
		return
	var t: Variant = tags[index - 1]
	if t is Dictionary:
		_preview_tag(String(t.get("name", "")))


## 直接预览一个标签（空名 = 整段）：跳到起点并开始播放该区间。
func _preview_tag(tag_name: String) -> void:
	if _model == null or not _model.is_animated():
		return
	_configure_clock()
	var start := 0
	if not tag_name.is_empty():
		for t in _model.anim_tags:
			if t is Dictionary and String(t.get("name", "")) == tag_name:
				var dir := String(t.get("direction", QVoxelFrameClock.DIR_FORWARD))
				start = int(t.get("to", 0)) \
						if dir in [QVoxelFrameClock.DIR_REVERSE,
								QVoxelFrameClock.DIR_PINGPONG_REVERSE] \
						else int(t.get("from", 0))
				break
	_clock.set_index(start)
	frame_selected.emit(start)
	_clock.play(tag_name)
	if _clock.is_playing():
		set_playing(true)
		_schedule()
	else:
		set_playing(false)


func _on_tag_add() -> void:
	if _model == null or not _model.is_animated():
		return
	var n := _model.frame_count()
	_tag_edit_index = -1
	_te_name.text = _unique_tag_name("tag")
	_te_from.max_value = maxi(n - 1, 0)
	_te_to.max_value = maxi(n - 1, 0)
	_te_from.value = clampi(_model.active_frame, 0, maxi(n - 1, 0))
	_te_to.value = mini(_te_from.value + 3, maxi(n - 1, 0))
	_te_dir.selected = 0
	_te_repeat.value = 0
	_te_color.color = tag_color({})
	_tag_editor.popup_centered(Vector2i(360, 0))


func _on_tag_edit() -> void:
	_open_tag_editor(_selected_tag_index())


func _open_tag_editor(idx: int) -> void:
	if _model == null or not _model.is_animated():
		return
	if idx < 0 or idx >= _model.anim_tags.size():
		return
	_tag_edit_index = idx
	var t: Dictionary = _model.anim_tags[idx]
	var n := _model.frame_count()
	_te_name.text = String(t.get("name", ""))
	_te_from.max_value = maxi(n - 1, 0)
	_te_to.max_value = maxi(n - 1, 0)
	_te_from.value = int(t.get("from", 0))
	_te_to.value = int(t.get("to", _te_from.value))
	var dir := String(t.get("direction", QVoxelFrameClock.DIR_FORWARD))
	_te_dir.selected = maxi(0, QVoxelFrameClock.DIRECTIONS.find(dir))
	_te_repeat.value = int(t.get("repeat", 0))
	_te_color.color = tag_color(t)
	_tag_editor.popup_centered(Vector2i(360, 0))


func _on_tag_remove() -> void:
	_remove_tag_at(_selected_tag_index())


func _remove_tag_at(idx: int) -> void:
	if _model == null or not _model.is_animated():
		return
	if idx < 0 or idx >= _model.anim_tags.size():
		return
	var tags: Array = _model.anim_tags.duplicate(true)
	tags.remove_at(idx)
	tags_changed.emit(tags)


func _tag_context(idx: int, at: Vector2) -> void:
	if _model == null or not _model.is_animated():
		return
	if idx < 0 or idx >= _model.anim_tags.size():
		return
	_tag_context_index = idx
	_tag_pick.select(idx + 1)
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("预览标签", 0)
	menu.add_item("编辑标签...", 1)
	menu.add_item("改颜色...", 2)
	menu.add_item("删除标签", 3)
	menu.id_pressed.connect(_on_tag_menu)
	menu.popup_hide.connect(func() -> void: menu.queue_free())
	menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_tag_menu(id: int) -> void:
	var idx := _tag_context_index
	match id:
		0:
			if idx >= 0 and idx < _model.anim_tags.size():
				_preview_tag(String(_model.anim_tags[idx].get("name", "")))
		1:
			_open_tag_editor(idx)
		2:
			_open_tag_color(idx)
		3:
			_remove_tag_at(idx)


func _open_tag_color(idx: int) -> void:
	if _model == null or not _model.is_animated():
		return
	if idx < 0 or idx >= _model.anim_tags.size():
		return
	_tag_color_index = idx
	_tag_color_picker.color = tag_color(_model.anim_tags[idx])
	_tag_color_popup.popup_centered(Vector2i(330, 430))


func _on_tag_color_ok() -> void:
	if _model == null or _tag_color_index < 0 or _tag_color_index >= _model.anim_tags.size():
		return
	var tags: Array = _model.anim_tags.duplicate(true)
	var t: Dictionary = tags[_tag_color_index]
	t["color"] = "#" + _tag_color_picker.color.to_html(false)
	tags[_tag_color_index] = t
	_tag_color_popup.hide()
	_tag_sig = ""
	tags_changed.emit(tags)


func _on_tag_editor_ok() -> void:
	if _model == null or not _model.is_animated():
		return
	var n := _model.frame_count()
	if n <= 0:
		return
	var from_i := clampi(int(_te_from.value), 0, n - 1)
	var to_i := clampi(int(_te_to.value), 0, n - 1)
	if from_i > to_i:
		var tmp := from_i
		from_i = to_i
		to_i = tmp
	var tag_name := _te_name.text.strip_edges()
	if tag_name.is_empty():
		tag_name = _unique_tag_name("tag")
	var tag := {
		"name": tag_name,
		"from": from_i,
		"to": to_i,
		"direction": QVoxelFrameClock.DIRECTIONS[clampi(_te_dir.selected, 0,
				QVoxelFrameClock.DIRECTIONS.size() - 1)],
		"color": "#" + _te_color.color.to_html(false),
		"repeat": maxi(0, int(_te_repeat.value)),
	}
	var tags: Array = _model.anim_tags.duplicate(true)
	if _tag_edit_index >= 0 and _tag_edit_index < tags.size():
		tags[_tag_edit_index] = tag
	else:
		tags.append(tag)
	_tag_editor.hide()
	_tag_sig = ""
	tags_changed.emit(tags)


func _selected_tag_index() -> int:
	if _tag_pick == null or _tag_pick.selected <= 0:
		return -1
	return _tag_pick.selected - 1


func _unique_tag_name(base: String) -> String:
	if _model == null:
		return base
	var names := {}
	for t in _model.anim_tags:
		if t is Dictionary:
			names[String(t.get("name", ""))] = true
	if not names.has(base):
		return base
	var i := 2
	while names.has("%s %d" % [base, i]):
		i += 1
	return "%s %d" % [base, i]


static func tag_color(t: Dictionary, fallback := QVoxelUi.ACCENT) -> Color:
	var c: Variant = t.get("color", "")
	if c is String and not (c as String).is_empty():
		return Color.from_string(c, fallback)
	if c is Color:
		return c
	return fallback


## 只包含影响播放的字段（颜色变化不该让正在播的时钟重置）。
static func tags_playback_signature(tags: Array) -> String:
	var parts := PackedStringArray()
	for t in tags:
		if not (t is Dictionary):
			continue
		parts.append("%s:%d-%d:%s:%d" % [
			String(t.get("name", "")),
			int(t.get("from", 0)),
			int(t.get("to", 0)),
			String(t.get("direction", QVoxelFrameClock.DIR_FORWARD)),
			int(t.get("repeat", 0)),
		])
	return "|".join(parts)


# 播放

func _on_play_toggled(on: bool) -> void:
	if on:
		_start_playback()
	else:
		_stop()


func _start_playback() -> void:
	if _model == null or not _model.is_animated():
		_stop()
		return
	_configure_clock()
	_clock.set_index(_active_index())
	_clock.play(_clock.tag_name_at(_active_index()))
	if not _clock.is_playing():
		_stop()
		return
	_play.text = "⏸"
	_schedule()


func _schedule() -> void:
	if not _clock.is_playing():
		return
	_pending_ms = _clock.delay_ms()
	_timer.start(maxf(0.02, float(_pending_ms) / 1000.0))


func _stop() -> void:
	_clock.stop()
	_pending_ms = 0
	_timer.stop()
	set_playing(false)


func _on_play_tick() -> void:
	if _model == null or not _model.is_animated():
		_stop()
		return
	if _clock.advance(float(_pending_ms)):
		frame_selected.emit(_clock.index())
	if not _clock.is_playing():
		set_playing(false)
		return
	_schedule()


func _configure_clock() -> void:
	var n := 0 if _model == null else _model.frame_count()
	var durations := PackedInt32Array()
	durations.resize(n)
	for i in n:
		durations[i] = _model.frame_at(i).duration_ms
	var fps := 4 if _model == null else _model.anim_fps
	var loop := true if _model == null else _model.anim_loop
	var tags: Array = [] if _model == null else _model.anim_tags
	var sig := "%s|%d|%s|%s" % [str(durations), fps, str(loop),
			tags_playback_signature(tags)]
	if sig == _clock_sig:
		return
	_clock_sig = sig
	_clock.configure(durations, fps, loop, tags)


# 帧菜单

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


# 标签条拖拽（Aseprite 式：拖左右边改范围，拖中间整体平移）

func _display_tags() -> Array:
	if _drag_tag_index >= 0 and not _drag_tags.is_empty():
		return _drag_tags
	return [] if _model == null else _model.anim_tags


func _tag_at(pos: Vector2) -> int:
	if _model == null or not _model.is_animated() or pos.y > TAG_HIT:
		return -1
	var tags: Array = _display_tags()
	for i in range(tags.size() - 1, -1, -1):
		var t: Variant = tags[i]
		if not (t is Dictionary):
			continue
		var x0 := int(t.get("from", 0)) * CELL_W
		var x1 := (int(t.get("to", 0)) + 1) * CELL_W
		if pos.x >= x0 and pos.x <= x1:
			return i
	return -1


func _tag_edge_mode(index: int, pos: Vector2) -> String:
	var tags: Array = _display_tags()
	if index < 0 or index >= tags.size() or not (tags[index] is Dictionary):
		return "move"
	var t: Dictionary = tags[index]
	var x0 := int(t.get("from", 0)) * CELL_W
	var x1 := (int(t.get("to", 0)) + 1) * CELL_W
	var dl := absf(pos.x - x0)
	var dr := absf(pos.x - x1)
	if dl <= TAG_EDGE and dl <= dr:
		return "from"
	if dr <= TAG_EDGE:
		return "to"
	return "move"


func _tag_drag_begin(index: int, mode: String, frame: int) -> void:
	if _model == null or not _model.is_animated():
		return
	var tags: Array = _display_tags()
	if index < 0 or index >= tags.size() or not (tags[index] is Dictionary):
		return
	_stop()
	_drag_tags = _model.anim_tags.duplicate(true)
	_drag_tag_index = index
	_drag_tag_mode = mode
	var t: Dictionary = _drag_tags[index]
	_drag_tag_offset = frame - int(t.get("from", 0))
	_drag_tag_moved = false
	_ruler.queue_redraw()


func _tag_drag_update(frame: int) -> void:
	if _model == null or _drag_tag_index < 0 or _drag_tag_index >= _drag_tags.size():
		return
	var n := maxi(_model.frame_count(), 1)
	var t: Dictionary = _drag_tags[_drag_tag_index]
	var from_i := int(t.get("from", 0))
	var to_i := int(t.get("to", from_i))
	match _drag_tag_mode:
		"from":
			from_i = clampi(frame, 0, to_i)
		"to":
			to_i = clampi(frame, from_i, n - 1)
		_:
			var span := to_i - from_i
			from_i = clampi(frame - _drag_tag_offset, 0, maxi(n - 1 - span, 0))
			to_i = from_i + span
	t["from"] = from_i
	t["to"] = to_i
	_drag_tags[_drag_tag_index] = t
	_drag_tag_moved = true
	_ruler.queue_redraw()


func _tag_drag_name() -> String:
	if _drag_tag_index < 0 or _drag_tag_index >= _drag_tags.size():
		return ""
	var t: Variant = _drag_tags[_drag_tag_index]
	return String(t.get("name", "")) if t is Dictionary else ""


func _tag_drag_end() -> void:
	if _drag_tag_index < 0:
		return
	var moved: bool = _drag_tag_moved
	var tags: Array = _drag_tags.duplicate(true)
	_drag_tags = []
	_drag_tag_index = -1
	_drag_tag_mode = ""
	_drag_tag_moved = false
	_ruler.queue_redraw()
	if moved:
		_tag_sig = ""
		tags_changed.emit(tags)


## 帧标尺：tag 条 + 帧格 + 末尾＋格。点切帧 / 拖重排 / 右键增删 / 点＋新建。
class _Ruler extends Control:
	var timeline: QVoxelierTimeline
	var _press := -1

	func _draw() -> void:
		var m: QVoxelModel = timeline._model
		if m == null:
			return
		var n := maxi(m.frame_count(), 1)
		var h := size.y
		var active := clampi(m.active_frame, 0, n - 1)
		var tag_h := QVoxelierTimeline.TAG_H
		if m != null and m.is_animated():
			var tags: Array = timeline._display_tags()
			for ti in tags.size():
				var t: Variant = tags[ti]
				if not (t is Dictionary):
					continue
				var from_i := clampi(int(t.get("from", 0)), 0, n - 1)
				var to_i := clampi(int(t.get("to", from_i)), from_i, n - 1)
				var x0 := from_i * CELL_W
				var w := (to_i - from_i + 1) * CELL_W
				var col := QVoxelierTimeline.tag_color(t)
				draw_rect(Rect2(x0 + 1, 0, maxf(w - 2, 1), tag_h), Color(col, 0.32))
				if timeline._drag_tag_index == ti:
					draw_rect(Rect2(x0 + 0.5, 0.5, maxf(w - 1, 1), tag_h - 1),
							Color(1, 1, 1, 0.65), false, 1.0)
				if w > 30:
					var label := String(t.get("name", ""))
					match String(t.get("direction", QVoxelFrameClock.DIR_FORWARD)):
						QVoxelFrameClock.DIR_REVERSE:
							label += " ◀"
						QVoxelFrameClock.DIR_PINGPONG:
							label += " ↔"
						QVoxelFrameClock.DIR_PINGPONG_REVERSE:
							label += " ◀▶"
					var rep := int(t.get("repeat", 0))
					if rep > 0:
						label += " ×%d" % rep
					draw_string(ThemeDB.fallback_font, Vector2(x0 + 4, tag_h - 1),
							label, HORIZONTAL_ALIGNMENT_LEFT, int(w) - 6, 9,
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
		var ax := n * CELL_W + CELL_W * 0.5
		var cy2 := (tag_h + h) * 0.5
		draw_line(Vector2(ax - 5, cy2), Vector2(ax + 5, cy2), QVoxelUi.TEXT_DIM, 1.5)
		draw_line(Vector2(ax, cy2 - 5), Vector2(ax, cy2 + 5), QVoxelUi.TEXT_DIM, 1.5)

	func _gui_input(event: InputEvent) -> void:
		var m: QVoxelModel = timeline._model
		if m == null:
			return
		var n := maxi(m.frame_count(), 1)
		var f := int(event.position.x / CELL_W)

		if event is InputEventMouseMotion:
			if timeline._drag_tag_index >= 0:
				timeline._tag_drag_update(clampi(f, 0, n - 1))
				accept_event()
			else:
				var ti: int = timeline._tag_at(event.position)
				if ti >= 0:
					mouse_default_cursor_shape = Control.CURSOR_HSIZE \
							if timeline._tag_edge_mode(ti, event.position) != "move" \
							else Control.CURSOR_MOVE
				else:
					mouse_default_cursor_shape = Control.CURSOR_ARROW
			return

		if not (event is InputEventMouseButton):
			return
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				var ti: int = timeline._tag_at(event.position)
				if ti >= 0:
					timeline._tag_drag_begin(ti, timeline._tag_edge_mode(ti, event.position),
							clampi(f, 0, n - 1))
					accept_event()
					return
				if f >= n:
					timeline._stop()
					timeline.append_frame_requested.emit()
				else:
					_press = f
					timeline._stop()
					timeline.frame_selected.emit(f)
				accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				var ti: int = timeline._tag_at(event.position)
				if ti >= 0:
					timeline._tag_context(ti, get_global_mouse_position())
					accept_event()
				elif f < n:
					timeline._frame_context(f, get_global_mouse_position())
					accept_event()
		else:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if timeline._drag_tag_index >= 0:
					var tag_name: String = timeline._tag_drag_name()
					var moved: bool = timeline._drag_tag_moved
					timeline._tag_drag_end()
					if not moved:
						timeline._preview_tag(tag_name)
					_press = -1
					accept_event()
					return
				if _press >= 0:
					if f != _press and f < n:
						timeline.move_frame_requested.emit(_press, f)
					_press = -1
					accept_event()
