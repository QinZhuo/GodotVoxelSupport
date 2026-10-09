@tool
class_name QVoxelierTimelineSection
extends QVoxelierSection
## 右侧抽屉·时间轴分组 —— 帧条 / 播放头 / 逐帧时长 / 标签 / 播放预览（QVoxelSpec §12.6）。
##
## 【本分组只报意图，不写数据】与颜色分组同一约定：UI 说"用户想干什么"，App 说"怎么写才可撤销"。
## 帧的增 / 删 / 重排 / 改时长在 §12.6 里全部归 `QVoxelPropertyCommand`（`frames` 就是属性），
## 而"包进命令"需要 begin 时先抓旧值 —— 那个时机只有 App 手里的命令对象知道。于是本文件里
## 一处 `set`/`append` 都没有，撤销语义因此只有 App 一处知识，换面板也不用重写。
##
## 【为什么播放预览由本面板自己驱动，而不是 App 的状态】播放是**呈现**（"让我看一眼动起来"），
## 它不写数据、也不该进撤销栈。做成 App 的状态就得回答"播放中还能不能落笔、撤销要不要停播放"，
## 而那些问题的答案全是"会污染 active_frame 这个唯一编辑游标"。放在面板里：播放只是
## 按帧时长反复发 `frame_selected`，播放结束游标停在哪就是哪，栈上干干净净。
##
## 【为什么刷新要分 bind() 与 _sync() 两级】播放每推进一帧都会走一次 App 的整面板刷新。
## 若每次都重建帧条，播放期间每秒要重建十几次控件（还会打断按钮的按下动画）。
## 于是 bind() 只在**帧数变了**时重建，其余（播放头 / 时长 / 帧率 / 标签）都只是改值。

## 切帧。**只动游标、不入撤销栈**（active_frame 是"正在看第几帧"，不是数据）。
signal frame_selected(index: int)
## 在**当前帧之后**插入一帧：`duplicate = true` 时新帧是当前帧的副本，否则是空帧。
signal insert_requested(duplicate: bool)
## 删除第 index 帧。
signal remove_requested(index: int)
## 把 from 帧挪到 to 帧。
signal move_requested(from: int, to: int)
## 改本帧时长的三段手势（与颜色分组同构：App 把整段夹进一条 QVoxelPropertyCommand）。
signal duration_edit_began(index: int)
signal duration_changed(index: int, ms: int)
signal duration_edit_ended(index: int)
## 时间轴元数据（写进 NODE 条目的 `anim` 键，§12.3）。
signal fps_changed(fps: int)
signal loop_toggled(on: bool)
signal tags_changed(tags: Array)

## 时长滑条上限：逐帧 1 秒已经够长（超过就该调帧率了）。
const _MAX_MS := 1000

var _model: QVoxelModel = null
## 帧条的重建判据（当前只有帧数）。与 QVoxelierApp 的"签名不变就不重建"同一思路。
var _strip_sig := -1
## 回写闸：App 把值写进控件时会触发 value_changed / text_changed，闸门一挡避免自激。
var _syncing := false
var _editing_duration := false
## 播放内核：时长兜底 / 循环 / 标签区间 / 回绕方向的**唯一**实现，与运行时 VoxelAnimator 共用。
## 【为什么面板不自己算下一帧】本面板过去用的是 `(active+1) % n`，于是 §12.3 的
## `tags[].direction` 只存不读——它是"能存能读但没人消费"的死数据。运行时播放器一旦再写一份
## 循环规则就会有第二份真相（预览看着对、运行时表现不一致）。抽成内核后，本面板只负责
## "把内核的当前帧号发出去"，规则本身只存在于 QVoxelFrameClock 一处。
var _clock := QVoxelFrameClock.new()
## 本次排给计时器的毫秒数。tick 时按"排了多少"推进内核，而不是读真实时钟：预览是呈现，
## 不该因为系统调度抖动而跳帧，这样预览节奏与逐帧时长严格一致。
var _pending_ms := 0
## 内核配置签名（帧时长 / 帧率 / 循环 / 标签）。**签名不变就不重灌内核**：bind() 在播放期间每推进
## 一帧都会被 App 调一次，无条件重灌会把内核的播放态（当前帧 / 已流逝时长 / 折返方向）清掉，
## 表现成"按了播放只跳一帧就停"。与本文件里 _strip_sig 同一思路。
var _clock_sig := ""

var _playhead: Label
var _play_btn: Button
var _loop_btn: Button
var _strip: HFlowContainer
var _frames: Array[Button] = []
var _remove_btn: Button
var _move_left: Button
var _move_right: Button
var _duration: HSlider
var _duration_label: Label
var _fps: HSlider
var _fps_label: Label
var _tags: LineEdit
var _timer: Timer


func section_title() -> String:
	return "时间轴"


func _build_body(body: VBoxContainer) -> void:
	# --- 播放头读数：当前帧 / 总帧数 / 本帧实际时长 ---
	_playhead = QVoxelUi.label("静态模型", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	body.add_child(_playhead)

	# --- 播放控制 ---
	var play_row := QVoxelUi.hbox()
	body.add_child(play_row)
	_play_btn = QVoxelUi.toggle_button("按每帧时长循环预览；只动预览游标，不写数据")
	_play_btn.text = "▶ 播放"
	_play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play_btn.toggled.connect(_on_play_toggled)
	play_row.add_child(_play_btn)

	_loop_btn = QVoxelUi.toggle_button("循环播放（落盘为 anim.loop）")
	_loop_btn.text = "循环"
	_loop_btn.toggled.connect(func(on: bool): loop_toggled.emit(on))
	play_row.add_child(_loop_btn)

	# --- 帧条：一个帧一个按钮，按下态即播放头（触摸下没有 hover，必须常驻可见） ---
	_strip = HFlowContainer.new()
	_strip.add_theme_constant_override("h_separation", QVoxelUi.SPACE_XS)
	_strip.add_theme_constant_override("v_separation", QVoxelUi.SPACE_XS)
	body.add_child(_strip)

	# --- 结构编辑：增 / 复制 / 删 / 左移 / 右移 ---
	var ops := QVoxelUi.hbox()
	body.add_child(ops)
	var add := QVoxelUi.icon_button("＋", "在当前帧之后插入一个空帧（静态模型上即把现有内容做成第 0 帧）")
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.pressed.connect(func(): insert_requested.emit(false))
	ops.add_child(add)

	var dup := QVoxelUi.icon_button("⧉", "复制当前帧到其后（逐帧作画的常用起点）")
	dup.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup.pressed.connect(func(): insert_requested.emit(true))
	ops.add_child(dup)

	_remove_btn = QVoxelUi.icon_button("－", "删除当前帧（最后一帧不删：删掉它就等于静默清空模型）")
	_remove_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remove_btn.pressed.connect(func(): remove_requested.emit(_active_index()))
	ops.add_child(_remove_btn)

	_move_left = QVoxelUi.icon_button("◀", "把当前帧前移一位")
	_move_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_move_left.pressed.connect(func(): move_requested.emit(_active_index(), _active_index() - 1))
	ops.add_child(_move_left)

	_move_right = QVoxelUi.icon_button("▶", "把当前帧后移一位")
	_move_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_move_right.pressed.connect(func(): move_requested.emit(_active_index(), _active_index() + 1))
	ops.add_child(_move_right)

	# --- 逐帧时长 / 帧率 / 标签 ---
	var dur_row := QVoxelUi.hbox()
	body.add_child(dur_row)
	dur_row.add_child(QVoxelUi.label("时长", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_duration = QVoxelUi.value_slider(0, _MAX_MS, 10, 0)
	_duration.tooltip_text = "本帧时长（毫秒）；0 = 跟随帧率"
	_duration.value_changed.connect(func(_v: float): _on_duration_changed())
	_duration.drag_started.connect(_on_duration_drag_started)
	_duration.drag_ended.connect(func(_c: bool): _on_duration_drag_ended())
	dur_row.add_child(_duration)
	_duration_label = _value_label()
	dur_row.add_child(_duration_label)

	var fps_row := QVoxelUi.hbox()
	body.add_child(fps_row)
	fps_row.add_child(QVoxelUi.label("帧率", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_fps = QVoxelUi.value_slider(1, 60, 1, 12)
	_fps.tooltip_text = "缺省帧率：某帧时长为 0 时用它（落盘为 anim.fps）"
	_fps.value_changed.connect(func(_v: float): _on_fps_changed())
	fps_row.add_child(_fps)
	_fps_label = _value_label()
	fps_row.add_child(_fps_label)

	var tag_row := QVoxelUi.hbox()
	body.add_child(tag_row)
	tag_row.add_child(QVoxelUi.label("标签", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_tags = QVoxelUi.text_field("", "名字:起-止[:方向]，逗号分隔",
			"命名区间（Aseprite 的 tag）。例：idle:0-3, walk:4-7:pingpong（方向缺省 forward）")
	_tags.text_changed.connect(func(_t: String): _on_tags_changed())
	tag_row.add_child(_tags)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_play_tick)
	add_child(_timer)


# ----------------------------------------------------------------------------
# 对外
# ----------------------------------------------------------------------------

## 绑定当前模型（App 在切对象 / 撤销 / 落盘后调用）。帧数没变则不重建帧条，只同步各控件。
func bind(model: QVoxelModel) -> void:
	_model = model
	var n := 0 if model == null else model.frame_count()
	if n != _strip_sig:
		_strip_sig = n
		_rebuild_strip(n)
	_configure_clock()
	_sync()


## 播放按钮的按下态（App 主动停播放时用）。
func set_playing(on: bool) -> void:
	if _play_btn != null and _play_btn.button_pressed != on:
		_play_btn.set_pressed_no_signal(on)


## 外部请求停播放（落笔 / 换对象）。**必须同时收计时器与按钮态**：只收计时器的话
## 按钮还亮着"正在播放"，用户会以为它坏了；只收按钮态的话帧会继续自己往前走。
func stop_playback() -> void:
	if not _clock.is_playing():
		return
	_stop()
	_sync()


## 标签文本 ↔ §12.3 的 `anim.tags` 结构。**双向且有单测钉住** —— 文本形式是 UI 的呈现选择，
## 但"用户打进去的字"与"落盘的结构"必须是同一份语义，否则存回去的标签会悄悄变样。
##
## 语法：`名字:起-止[:方向]`，多项用逗号分隔；方向 ∈ forward / reverse / pingpong，缺省 forward。
## 【为什么是文本而不是一行一个的增删表格】标签是稀疏的少量命名区间；为它铺一套"每行 3 个
## 输入框 + 1 个下拉 + 删除键"要吃掉右列半屏，换来的只是少打几个字。文本形式把成本压到一行，
## 而解析规则只有这十几行、可单测、非法项明确丢弃（不猜区间——猜错比丢掉更难查）。
static func tags_to_text(tags: Array) -> String:
	var parts := PackedStringArray()
	for t in tags:
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		var s := "%s:%d-%d" % [String(d.get("name", "")), int(d.get("from", 0)), int(d.get("to", 0))]
		# 方向与缺省相同时不写出来（文本形式只表达"与缺省不同"的部分，读写才对称）
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
		var name := String(parts[0]).strip_edges()
		if name.is_empty():
			continue
		var rng := String(parts[1]).split("-", false)
		if rng.size() < 2:
			continue
		var from_i := maxi(0, int(String(rng[0]).strip_edges()))
		var to_i := maxi(from_i, int(String(rng[1]).strip_edges()))
		var dir := String(parts[2]).strip_edges() if parts.size() > 2 else QVoxelFrameClock.DIR_FORWARD
		if not QVoxelFrameClock.DIRECTIONS.has(dir):
			dir = QVoxelFrameClock.DIR_FORWARD
		out.append({"name": name, "from": from_i, "to": to_i, "direction": dir})
	return out


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _value_label() -> Label:
	var l := QVoxelUi.label("", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.custom_minimum_size = Vector2(52, 0)
	return l


## 当前帧下标（模型不可用时为 0，让"增 / 删"这类操作至少有个确定的目标）。
func _active_index() -> int:
	if _model == null:
		return 0
	return clampi(_model.active_frame, 0, maxi(_model.frame_count() - 1, 0))


func _rebuild_strip(n: int) -> void:
	for b in _frames:
		# 先摘再排队释放：queue_free 要等这一帧结束才生效，直接换掉的话新旧帧条会同屏叠着
		_strip.remove_child(b)
		b.queue_free()
	_frames.clear()
	for i in n:
		var b := QVoxelUi.toggle_button()
		b.text = str(i)
		b.custom_minimum_size = Vector2(QVoxelUi.hit_size(), QVoxelUi.hit_size())
		# bind 而不是 lambda 捕获：闭包捕获循环变量在不同版本上的取值时机有坑，
		# 而 bind 把 i 直接钉进调用参数里，没有"到底是哪一个 i"的余地。
		b.pressed.connect(_on_frame_pressed.bind(i))
		_strip.add_child(b)
		_frames.append(b)


func _on_frame_pressed(index: int) -> void:
	# 点的是已经亮着的那一帧：把它按回去，别让它变成"没选中"的错觉
	if index == _active_index():
		set_playing(false)
		_stop()
		_sync()
		return
	_stop()
	frame_selected.emit(index)


func _sync() -> void:
	_syncing = true
	var n := 0 if _model == null else _model.frame_count()
	var animated := n > 0
	var active := _active_index()
	# 游标就是内核的"当前帧"：用户点帧条 / 撤销改了 active_frame 之后，播放从这一帧接着走
	_clock.set_index(active)

	for i in _frames.size():
		var b := _frames[i]
		b.set_pressed_no_signal(i == active)
		b.tooltip_text = "第 %d 帧 · %d ms" % [i, _frame_ms(i)]

	if not animated:
		_playhead.text = "静态模型（＋ 做成动画）"
	else:
		_playhead.text = "第 %d / %d 帧 · %d ms" % [active + 1, n, _frame_ms(active)]

	_duration.value = 0 if not animated else _model.frame_at(active).duration_ms
	_duration.editable = animated
	_duration_label.text = _duration_text()
	_fps.value = 12 if _model == null else _model.anim_fps
	_fps.editable = animated
	_fps_label.text = "%d fps" % int(_fps.value)
	_loop_btn.set_pressed_no_signal(true if _model == null else _model.anim_loop)
	_loop_btn.disabled = not animated
	_tags.text = "" if _model == null else tags_to_text(_model.anim_tags)
	_tags.editable = animated

	_remove_btn.disabled = n <= 1
	_move_left.disabled = active <= 0
	_move_right.disabled = not animated or active >= n - 1
	_play_btn.disabled = not animated
	_syncing = false


## 把模型的帧表 / 帧率 / 循环 / 标签灌进播放内核。所有"模型数据变了"的路径都经由 bind() 走到这里，
## 于是改帧时长、改帧率、改标签之后内核立刻跟着变，不必每条写路径各自再调一次。
func _configure_clock() -> void:
	var n := 0 if _model == null else _model.frame_count()
	var durations := PackedInt32Array()
	durations.resize(n)
	for i in n:
		durations[i] = _model.frame_at(i).duration_ms
	var fps := 12 if _model == null else _model.anim_fps
	var loop := true if _model == null else _model.anim_loop
	var tags: Array = [] if _model == null else _model.anim_tags
	var sig := "%s|%d|%s|%s" % [str(durations), fps, str(loop), tags_to_text(tags)]
	if sig == _clock_sig:
		return
	_clock_sig = sig
	_clock.configure(durations, fps, loop, tags)


## 某帧的实际时长：逐帧时长优先，0 则回退帧率（§12.3）。
## **实现只有一份**（在 QVoxelFrameClock 里），这里只取它的答案——UI 与播放各算一套必然漂移。
func _frame_ms(index: int) -> int:
	return _clock.frame_ms(index)


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
	# 点进滑条槽：没有 drag 手势，自成一次完整手势（与颜色通道同一处置）
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
	# 帧率只影响"时长为 0"的帧，播放头读数因此要跟着重算
	_playhead.text = "第 %d / %d 帧 · %d ms" % [_active_index() + 1, _model.frame_count(), _frame_ms(_active_index())]


func _on_tags_changed() -> void:
	if _syncing or _model == null or not _model.is_animated():
		return
	tags_changed.emit(tags_from_text(_tags.text))


# --- 播放预览 ---

func _on_play_toggled(on: bool) -> void:
	if on:
		_playhead.tooltip_text = "预览中：只动 active_frame，不写数据"
		_start_playback()
	else:
		_playhead.tooltip_text = ""
		_stop()


## 开始预览。**优先在当前帧所属的标签区间里播** —— 标签就是命名循环（Aseprite 的心智）：
## 点进 walk 区间再按播放，看到的就该是 walk 的循环与它自己的方向；不在任何标签里则播整段。
func _start_playback() -> void:
	if _model == null or not _model.is_animated():
		_stop()
		return
	_configure_clock()
	_clock.set_index(_active_index())
	_clock.play(_clock.tag_name_at(_active_index()))
	if not _clock.is_playing():
		# 区间内只有一帧：没有时间轴可播。如实停住，而不是让计时器空转
		_stop()
		return
	_schedule()


## 排下一次推进。间隔由内核给出，于是逐帧时长不同 / 标签区间不同 / 反向播放都自动对。
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
	# 推进量用"排了多少"而不是读真实时钟：预览是呈现，节奏该与逐帧时长严格一致
	if _clock.advance(float(_pending_ms)):
		frame_selected.emit(_clock.index())
	if not _clock.is_playing():
		# 播到区间尽头（非循环 / 标签区间走完）自动停：按钮要跟着灭，否则看起来还在播
		set_playing(false)
		return
	# 信号是同步的：App 已把 active_frame 挪到新帧并调过 bind()，这里排的是新帧剩余的时长
	_schedule()
