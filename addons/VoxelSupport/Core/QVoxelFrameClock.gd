class_name QVoxelFrameClock
extends RefCounted
## 逐帧动画的播放内核（QVX `FRAM` 的时间轴）：纯逻辑、无节点依赖，编辑器预览与运行时播放共用。

## 标签方向（§12.3）。
const DIR_FORWARD := "forward"
const DIR_REVERSE := "reverse"
const DIR_PINGPONG := "pingpong"
const DIR_PINGPONG_REVERSE := "pingpong_reverse"
const DIRECTIONS := [DIR_FORWARD, DIR_REVERSE, DIR_PINGPONG, DIR_PINGPONG_REVERSE]

## 单帧时长下限（毫秒）。
const MIN_FRAME_MS := 1
## 单次 advance() 内最多跨几帧。
const MAX_STEPS := 1024

## 逐帧时长（毫秒，0 = 跟随 fps）。
var _durations := PackedInt32Array()
## 缺省帧率取全仓唯一真值（QVoxelSpec.ANIM_FPS_DEFAULT）；configure() 会立刻覆盖它，
var _fps := QVoxelSpec.ANIM_FPS_DEFAULT
var _loop := QVoxelSpec.ANIM_LOOP_DEFAULT  # 与 ANIM_FPS_DEFAULT 同族：未配置时也不制造第二个缺省
## §12.3 的 tags 数组：[{"name": String, "from": int, "to": int…
var _tags: Array = []

## 当前帧号（**区间内**的绝对帧号，不是区间内偏移 —— 消费者要用它当游标）
var _index := 0
## 当前帧已流逝的毫秒数
var _elapsed := 0.0
var _playing := false
## 播放区间（闭区间）。
var _from := 0
var _to := 0
var _direction := DIR_FORWARD
var _tag_name := ""
## 标签重复次数：0 = 无限；>0 = 播完这么多个完整循环后停。
var _repeat := 0
var _repeat_left := 0
## pingpong 的行进方向（+1 / -1）；另两种方向恒为 +1，由 _step() 的分支直接处理。
var _sign := 1

# 配置

## 配置一段可播放的帧序列。
func configure(durations_ms: PackedInt32Array, fps: int, loop: bool, tags: Array = []) -> void:
	_durations = durations_ms
	_fps = maxi(1, fps)
	_loop = loop
	_tags = tags if tags != null else []
	_index = 0
	_elapsed = 0.0
	_playing = false
	_repeat = 0
	_repeat_left = 0
	_sign = 1
	_resolve("")

## 帧数（0 = 空帧序列，不可播放）。
func count() -> int:
	return _durations.size()

func is_playing() -> bool:
	return _playing

## 当前帧号。
func index() -> int:
	return _index

## 播放区间（闭区间）`Vector2i(from, to)`。
func range() -> Vector2i:
	return Vector2i(_from, _to)

## 当前生效的标签名（整段播放时为 ""）。
func tag_name() -> String:
	return _tag_name

# 播放控制

## 开始播放。
func play(tag_name: String = "") -> void:
	_resolve(tag_name)
	if _to <= _from:
		_playing = false
		return
	# 反向播放从区间末尾进入更符合直觉（用户按下播放，看到的应该是"往回放"）。
	if _direction == DIR_PINGPONG_REVERSE:
		_index = _to
	elif _direction == DIR_REVERSE and (_index < _from or _index > _to):
		_index = _to
	elif _index < _from or _index > _to:
		_index = _from
	_elapsed = 0.0
	_sign = -1 if _direction == DIR_PINGPONG_REVERSE else 1
	_repeat_left = _repeat
	_playing = true

func stop() -> void:
	_playing = false
	_elapsed = 0.0

## 外部同步游标（用户点了帧条 / 应用了撤销）。
func set_index(i: int) -> void:
	_index = clampi(i, 0, maxi(0, _durations.size() - 1))

# 推进

## 推进 `delta_ms` 毫秒，换了帧返回 true（可能一次跨多帧，低帧率/长 delta 时会发生）。
func advance(delta_ms: float) -> bool:
	if not _playing:
		return false
	_elapsed += delta_ms
	var changed := false
	var guard := MAX_STEPS
	while _playing and _elapsed >= float(_ms_at(_index)) and guard > 0:
		_elapsed -= float(_ms_at(_index))
		_step()
		changed = true
		guard -= 1
	if changed:
		# 触顶/停播时余量可能超过一帧长，夹住它，让下一帧从"刚好到期"开始
		_elapsed = minf(_elapsed, float(_ms_at(_index)))
	return changed

## 距下一次换帧还有多少毫秒（调度器排下一次 tick 用）。
func delay_ms() -> int:
	if not _playing:
		return 0
	return maxi(MIN_FRAME_MS, _ms_at(_index) - int(_elapsed))

## 某帧的**实际**时长：逐帧时长优先，0 则回退帧率（§12.3）。
func frame_ms(i: int) -> int:
	if i < 0 or i >= _durations.size():
		return 0
	var ms: int = _durations[i]
	if ms > 0:
		return ms
	return int(round(1000.0 / float(maxi(1, _fps))))

## 找出包含第 `i` 帧的标签名；多个标签命中时取**先声明的那个**（声明顺序即优先级）。
func tag_name_at(i: int) -> String:
	for t in _tags:
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		if i >= int(d.get("from", 0)) and i <= int(d.get("to", 0)):
			return String(d.get("name", ""))
	return ""

# 内部

## 把标签名解析成播放区间与方向。
func _resolve(tag_name: String) -> void:
	_from = 0
	_to = maxi(0, _durations.size() - 1)
	_direction = DIR_FORWARD
	_tag_name = ""
	_repeat = 0
	_sign = 1
	if tag_name.is_empty():
		return
	for t in _tags:
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		if String(d.get("name", "")) != tag_name:
			continue
		_from = clampi(int(d.get("from", 0)), 0, _to)
		_to = clampi(int(d.get("to", _from)), _from, _to)
		var dir := String(d.get("direction", DIR_FORWARD))
		_direction = dir if DIRECTIONS.has(dir) else DIR_FORWARD
		_repeat = maxi(0, int(d.get("repeat", 0)))
		_sign = -1 if _direction == DIR_PINGPONG_REVERSE else 1
		_tag_name = tag_name
		return

## 帧长的内部口径：至少 MIN_FRAME_MS，杜绝"零长帧"把推进变成忙循环。
func _ms_at(i: int) -> int:
	return maxi(MIN_FRAME_MS, frame_ms(i))

## 按当前方向走一步（回绕 / 折返 / 到头停播都在这里）。
func _step() -> void:
	var span := _to - _from
	if span <= 0:
		_playing = false
		return
	match _direction:
		DIR_REVERSE:
			if _index > _from:
				_index -= 1
			elif not _cycle_done(_to):
				_playing = false
		DIR_PINGPONG, DIR_PINGPONG_REVERSE:
			var nxt := _index + _sign
			if nxt > _to:
				# 到顶折返。
				_sign = -1
				nxt = _index - 1
			elif nxt < _from:
				# 回到起点：一次完整往返结束，再决定继续还是停。
				if not _cycle_done(_index):
					_playing = false
					return
				_sign = 1
				nxt = _index + 1
			_index = nxt
		_:
			if _index < _to:
				_index += 1
			elif not _cycle_done(_from):
				_playing = false

## 一次循环/往返结束。
func _cycle_done(next_index: int) -> bool:
	if _repeat > 0:
		_repeat_left -= 1
		if _repeat_left <= 0:
			return false
	if not _loop:
		return false
	_index = next_index
	return true
