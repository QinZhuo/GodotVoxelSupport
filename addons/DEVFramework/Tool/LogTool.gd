## 通用日志工具 — 标签标记、自动配色、项目设置集成
class_name LogTool

const SETTING_ENABLED := "dev_framework/log/enabled"
const SETTING_TIMESTAMPS := "dev_framework/log/show_timestamps"
const SETTING_IGNORED_TAGS := "dev_framework/log/ignored_tags"

enum Level {LOG, WARN, ERROR}

static var _last_ts_usec: int = 0


static func set_enabled(v: bool) -> void:
	ProjectSettings.set_setting(SETTING_ENABLED, v)

static func set_show_timestamps(v: bool) -> void:
	ProjectSettings.set_setting(SETTING_TIMESTAMPS, v)

static func disable_tag(tag: String) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	if tag not in ignored:
		ignored.append(tag)
		ProjectSettings.set_setting(SETTING_IGNORED_TAGS, ignored)

static func enable_tag(tag: String) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	var idx := ignored.find(tag)
	if idx >= 0:
		ignored.remove_at(idx)
		ProjectSettings.set_setting(SETTING_IGNORED_TAGS, ignored)


static func log(tag: String, ...objs: Array) -> void:
	_out(Level.LOG, tag, objs)

static func warn(tag: String, ...objs: Array) -> void:
	_out(Level.WARN, tag, objs)

static func error(tag: String, ...objs: Array) -> void:
	_out(Level.ERROR, tag, objs)


static func _out(level: Level, tag: String, objs: Array) -> void:
	var ignored: PackedStringArray = ProjectSettings.get_setting(SETTING_IGNORED_TAGS, PackedStringArray())
	if (level != Level.ERROR and tag in ignored) or (level != Level.ERROR and not ProjectSettings.get_setting(SETTING_ENABLED, true)):
		return

	var msg := " ".join(objs.map(str))
	# print_rich 会把 [ ] 当 BBCode 解析, 消息里含源码/路径/字典时需转义, 否则 [img] 等误判导致资源加载错误甚至崩溃
	msg = msg.replace("[", "[lb]").replace("]", "[rb]")
	var now := Time.get_ticks_usec()
	var diff_usec := now - _last_ts_usec if _last_ts_usec > 0 else 0
	_last_ts_usec = now
	var ts := "[color=#888888]%+dms [/color]" % [diff_usec / 1000] if diff_usec > 0 else ""
	match level:
		Level.LOG:
			print_rich(_colored_tag(tag), ts, "[color=#dcdcdc]", msg, "[/color]")
		Level.WARN:
			print_rich(_colored_tag(tag), ts, "[color=#ffc800]", msg, "[/color]")
		Level.ERROR:
			print_rich(_colored_tag(tag), ts, "[color=#ff4040]", msg, "[/color]")


static func _colored_tag(tag: String) -> String:
	var hue: float = fmod(absf(tag.hash()), 360.0) / 360.0
	var c: Color = Color.from_hsv(hue, 0.45, 0.82)
	return "[color=#%s][b][%s][/b][/color]" % [c.to_html(false), tag]


## 计时器 — 创建时传入日志信息，调用 stop() 输出自创建起的耗时
class LogTimer:
	var _start: int
	var _tag: String
	var _msg: String
	var _stopped := false

	func _init(tag: String, msg: String):
		_start = Time.get_ticks_usec()
		_tag = tag
		_msg = msg
		_start_timeout_watch()

	func _start_timeout_watch():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return
		var timer := tree.create_timer(5.0)
		timer.timeout.connect(_on_timeout)

	func _on_timeout():
		if _stopped:
			return
		LogTool.error(_tag, str("计时器超时(>5s): ", _msg))

	func stop() -> void:
		_stopped = true
		LogTool.log(_tag, str(_msg, " (", (Time.get_ticks_usec() - _start) / 1000.0, "ms)"))

## 创建计时器，返回 LogTimer 对象，调用 stop() 输出耗时
static func timer(tag: String, msg: String) -> LogTimer:
	return LogTimer.new(tag, msg)
