class_name QVoxelFrameClock
extends RefCounted
## 逐帧动画的播放内核（QVX `FRAM` 的时间轴）：纯逻辑、无节点依赖，编辑器预览与运行时播放共用。
##
## 【为什么必须抽成一个对象，而不是各自写一份】"第几帧、什么时候换下一帧"这件事有两个消费者：
## 编辑器面板的播放预览，和运行时的动画播放器。此前编辑器那份直接写在面板里
## （`_on_play_tick` 里的 `(active+1) % n`），于是 `anim.tags[].direction` 只存不读 ——
## 一旦运行时再写一份循环规则，两份迟早对不上：预览看着正常、运行时表现不一致，而两边都没报错。
## 抽成内核后，循环 / 回绕 / 时长兜底 / 标签区间只有一份实现，两个消费者都只是它的**驱动器**。
##
## 【为什么它不是 Node】它不认识 Timer、不认识 QVoxelModel、也不认识 QVoxelAsset；
## 只吃"逐帧时长 + 帧率 + 循环 + 标签"，吐"当前帧号 + 距下次换帧还有多久"。
## 于是它能被单测直接驱动（喂 delta 即可），不必起场景树，也不必等真实时钟走到。
##
## 【为什么"时长 0 回退帧率"写在这里】这是 §12.3 的语义（逐帧时长优先，0 = 跟随帧率），
## 属于格式定义的一部分。放在内核里，两个消费者就都不必各自实现一遍这个回退。

## 标签方向（§12.3）。`forward` 是缺省，另两种都只在**标签区间内**生效。
const DIR_FORWARD := "forward"
const DIR_REVERSE := "reverse"
const DIR_PINGPONG := "pingpong"
const DIRECTIONS := [DIR_FORWARD, DIR_REVERSE, DIR_PINGPONG]

## 单帧时长下限（毫秒）。避免"时长为 0 且帧率非法"时推进变成忙循环。
const MIN_FRAME_MS := 1
## 单次 advance() 内最多跨几帧。帧长至少 1 ms，正常 delta 远不会触顶；
## 触顶说明调用方喂了异常大的 delta（如切后台回来的补帧），此时丢掉余量比死循环安全。
const MAX_STEPS := 1024

## 逐帧时长（毫秒，0 = 跟随 fps）。下标即帧号。
var _durations := PackedInt32Array()
var _fps := 12
var _loop := true
## §12.3 的 tags 数组：[{"name": String, "from": int, "to": int, "direction": String}]
var _tags: Array = []

## 当前帧号（**区间内**的绝对帧号，不是区间内偏移 —— 消费者要用它当游标）
var _index := 0
## 当前帧已流逝的毫秒数
var _elapsed := 0.0
var _playing := false
## 播放区间（闭区间）。无标签时即整段 [0, count-1]。
var _from := 0
var _to := 0
var _direction := DIR_FORWARD
var _tag_name := ""
## pingpong 的行进方向（+1 / -1）；另两种方向恒为 +1，由 _step() 的分支直接处理。
var _sign := 1


# ----------------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------------

## 配置一段可播放的帧序列。`durations` 下标即帧号；`tags` 为 §12.3 结构。
## 配置后处于**停止**态，从第 0 帧起（要不要播、从哪播由 play() 决定）。
func configure(durations_ms: PackedInt32Array, fps: int, loop: bool, tags: Array = []) -> void:
	_durations = durations_ms
	_fps = maxi(1, fps)
	_loop = loop
	_tags = tags if tags != null else []
	_index = 0
	_elapsed = 0.0
	_playing = false
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


# ----------------------------------------------------------------------------
# 播放控制
# ----------------------------------------------------------------------------

## 开始播放。`tag_name` 非空且该标签存在时在它的区间内播放，否则播整段；
## 区间外的游标会被夹进区间（夹法见下）。帧数 < 2 时**不进入播放态**——
## 一帧的"动画"没有时间轴可言，让 is_playing() 如实返回 false，调用方不必特判。
func play(tag_name: String = "") -> void:
	_resolve(tag_name)
	if _to <= _from:
		_playing = false
		return
	# 反向播放从区间末尾进入更符合直觉（用户按下播放，看到的应该是"往回放"）
	if _index < _from or _index > _to:
		_index = _to if _direction == DIR_REVERSE else _from
	_elapsed = 0.0
	_sign = 1
	_playing = true


func stop() -> void:
	_playing = false
	_elapsed = 0.0


## 外部同步游标（用户点了帧条 / 应用了撤销）。播放中同步游标 = 从这一帧接着播。
## **不夹进播放区间**：区间外的游标是合法状态（用户在标签区间之外点了帧，或撤销把游标拉回去了），
## 夹进来就是跟用户的操作对着干；_step() 自己会把游标收敛回区间内（各方向都不会跑飞）。
func set_index(i: int) -> void:
	_index = clampi(i, 0, maxi(0, _durations.size() - 1))


# ----------------------------------------------------------------------------
# 推进
# ----------------------------------------------------------------------------

## 推进 `delta_ms` 毫秒，换了帧返回 true（可能一次跨多帧，低帧率/长 delta 时会发生）。
## 消费方只需在返回 true 时把 `index()` 应用出去 —— 这是它的全部契约。
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


## 距下一次换帧还有多少毫秒（调度器排下一次 tick 用）。不播放时返回 0。
func delay_ms() -> int:
	if not _playing:
		return 0
	return maxi(MIN_FRAME_MS, _ms_at(_index) - int(_elapsed))


## 某帧的**实际**时长：逐帧时长优先，0 则回退帧率（§12.3）。越界返回 0。
func frame_ms(i: int) -> int:
	if i < 0 or i >= _durations.size():
		return 0
	var ms: int = _durations[i]
	if ms > 0:
		return ms
	return int(round(1000.0 / float(maxi(1, _fps))))


## 找出包含第 `i` 帧的标签名；多个标签命中时取**先声明的那个**（声明顺序即优先级）。
## 无命中返回 ""（= 整段播放）。UI 用它实现"点进某个命名区间就预览那个区间"。
func tag_name_at(i: int) -> String:
	for t in _tags:
		if not (t is Dictionary):
			continue
		var d: Dictionary = t
		if i >= int(d.get("from", 0)) and i <= int(d.get("to", 0)):
			return String(d.get("name", ""))
	return ""


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 把标签名解析成播放区间与方向。名字为空或标签非法时退化为整段 + forward。
## 【为什么非法标签直接退化而不是报错】标签是"作者的心智"，不是结构自洽性的一部分：
## 区间越界、名字对不上都不该让动画播不出来，静默退化到"整段正放"是唯一不会让用户卡住的处置。
func _resolve(tag_name: String) -> void:
	_from = 0
	_to = maxi(0, _durations.size() - 1)
	_direction = DIR_FORWARD
	_tag_name = ""
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
			elif _loop:
				_index = _to
			else:
				_playing = false
		DIR_PINGPONG:
			var nxt := _index + _sign
			if nxt > _to:
				# 到顶折返。span >= 1 保证 nxt 回退后仍在区间内。
				_sign = -1
				nxt = _index - 1
			elif nxt < _from:
				# 回到起点：循环则再折返，否则一个来回播完就停
				if _loop:
					_sign = 1
					nxt = _index + 1
				else:
					_playing = false
					return
			_index = nxt
		_:
			if _index < _to:
				_index += 1
			elif _loop:
				_index = _from
			else:
				_playing = false
