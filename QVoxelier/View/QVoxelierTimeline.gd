@tool
class_name QVoxelierTimeline
extends QVoxelierPanel
## 底部统一时间轴：帧条 / 播放时钟 / 循环 / 逐帧时长 / 帧率 / 标签 / 节点摆放轨道。
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
signal track_record_requested
signal track_clear_requested

const CELL_W := 26.0
const MAX_MS := 1000

var _model: QVoxelModel
## 摆放轨道的目标节点（当前选中的组/模型）；由 App 在刷新时推入。
var _track_target: QVoxelNode
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
var _tags: LineEdit
var _track_label: Label
var _track_record: Button
var _track_clear: Button
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

	_loop = QVoxelUi.toggle_button("循环播放（落盘为 anim.loop）",
			QVoxelUi.VARIATION_TOOL, "⇄")
	_loop.custom_minimum_size = Vector2(bs, bs)
	_loop.toggled.connect(func(on: bool): loop_toggled.emit(on))
	row.add_child(_loop)

	_rm = QVoxelUi.icon_button("✕", "删除当前帧（至少留一帧）", bs)
	_rm.pressed.connect(func(): remove_frame_requested.emit())
	row.add_child(_rm)

	_settings_btn = QVoxelUi.icon_button("⚙", "逐帧时长 / 帧率 / 标签 / 节点摆放轨道", bs)
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


## 摆放轨道跟随当前选中节点（组或模型），与体素帧共用帧号。
func set_track_target(node: QVoxelNode) -> void:
	_track_target = node
	_sync_track()


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
	_tags = QVoxelUi.text_field("", "如 idle:0-3, walk:4-7",
			"命名区间（Aseprite 的 tag）：名字:起-止[:方向]，逗号分隔。"
			+ "例：idle:0-3, walk:4-7:pingpong（方向缺省 forward）")
	_tags.text_changed.connect(func(_t: String): _on_tags_changed())
	tag_row.add_child(_tags)

	box.add_child(QVoxelUi.divider())
	_track_label = QVoxelUi.label("摆放：跟随静态", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	box.add_child(_track_label)
	var track_row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	box.add_child(track_row)
	_track_record = QVoxelUi.button("记录当前节点摆放到本帧", "与体素帧共用帧号")
	_track_record.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track_record.pressed.connect(func(): track_record_requested.emit())
	track_row.add_child(_track_record)
	_track_clear = QVoxelUi.button("清除本帧摆放")
	_track_clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track_clear.pressed.connect(func(): track_clear_requested.emit())
	track_row.add_child(_track_clear)


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
	_tags.text = "" if m == null else tags_to_text(m.anim_tags)
	_tags.editable = animated
	_sync_track()
	_bind_ui()
	_syncing = false


## 摆放轨道针对当前选中节点；体素帧是否动画不影响整体物件摆放的记录。
func _sync_track() -> void:
	if _track_label == null:
		return
	var target := _track_target
	var active := _active_index()
	var has_track := target != null and active < target.transform_tracks.size() \
			and not target.transform_tracks[active].is_equal_approx(target.local_transform)
	_track_label.text = "%s：%s" % [
		"当前节点" if target == null else target.display_name(),
		"本帧独立" if has_track else "跟随静态",
	]
	_track_record.disabled = target == null
	_track_clear.disabled = target == null or not has_track


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


func _on_tags_changed() -> void:
	if _syncing or _model == null or not _model.is_animated():
		return
	tags_changed.emit(tags_from_text(_tags.text))


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
	var sig := "%s|%d|%s|%s" % [str(durations), fps, str(loop), tags_to_text(tags)]
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


# 标签文本 ↔ anim.tags（与旧时间轴同一语法，保持落盘兼容）

static func tags_to_text(tags: Array) -> String:
	var parts := PackedStringArray()
	for t in tags:
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		var s := "%s:%d-%d" % [String(d.get("name", "")), int(d.get("from", 0)), int(d.get("to", 0))]
		var dir := String(d.get("direction", QVoxelFrameClock.DIR_FORWARD))
		if dir != QVoxelFrameClock.DIR_FORWARD:
			s += ":%s" % dir
		parts.append(s)
	return ", ".join(parts)


static func tags_from_text(text: String) -> Array:
	var out: Array = []
	for raw in text.split(",", false):
		var parts := raw.strip_edges().split(":", false)
		if parts.size() < 2:
			continue
		var tag_name := String(parts[0]).strip_edges()
		if tag_name.is_empty():
			continue
		var rng := String(parts[1]).split("-", false)
		if rng.size() < 2:
			continue
		var from_i := maxi(0, int(String(rng[0]).strip_edges()))
		var to_i := maxi(from_i, int(String(rng[1]).strip_edges()))
		var dir := String(parts[2]).strip_edges() if parts.size() > 2 else QVoxelFrameClock.DIR_FORWARD
		if not QVoxelFrameClock.DIRECTIONS.has(dir):
			dir = QVoxelFrameClock.DIR_FORWARD
		out.append({"name": tag_name, "from": from_i, "to": to_i, "direction": dir})
	return out


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
		var ax := n * CELL_W + CELL_W * 0.5
		var cy2 := (tag_h + h) * 0.5
		draw_line(Vector2(ax - 5, cy2), Vector2(ax + 5, cy2), QVoxelUi.TEXT_DIM, 1.5)
		draw_line(Vector2(ax, cy2 - 5), Vector2(ax, cy2 + 5), QVoxelUi.TEXT_DIM, 1.5)

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton):
			return
		var m: QVoxelModel = timeline._model
		if m == null:
			return
		var n := maxi(m.frame_count(), 1)
		var f := int(event.position.x / CELL_W)
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if f >= n:
					timeline._stop()
					timeline.append_frame_requested.emit()
				else:
					_press = f
					timeline._stop()
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
