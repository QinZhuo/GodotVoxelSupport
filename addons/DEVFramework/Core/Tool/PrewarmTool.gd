## 资源预热 — 后台批量预取，把"首次用到才同步 load"的开销挪到空闲期。
class_name PrewarmTool

## 组名 → 路径清单
static var _groups: Dictionary = {}
## 路径 → 资源强引用（不持有会被引用计数归零卸载，预热等于白做）
static var _loaded: Dictionary = {}
## 路径 → 后台加载中
static var _pending: Dictionary = {}
## 已完成（或已尽力）的组
static var _ready: Dictionary = {}
## 组名 → 预热中
static var _running: Dictionary = {}
## 组名 → 开始时间(算已用/剩余时间)
static var _started: Dictionary = {}

## 单组预热的兜底上限（毫秒）
const TIMEOUT_MS := 30000


## 会话级复位：清空登记与缓存（在途加载回调自行结束）
static func reset() -> void:
	_groups.clear()
	_loaded.clear()
	_pending.clear()
	_ready.clear()
	_running.clear()
	_started.clear()


static func register(group: StringName, paths: PackedStringArray) -> void:
	_groups[group] = paths
	_ready.erase(group)


static func prewarm(group: StringName) -> void:
	if _running.has(group) or _ready.has(group) or not _groups.has(group):
		return
	_running[group] = true
	_started[group] = Time.get_ticks_msec()
	_run(group)


static func prewarm_all() -> void:
	for group in _groups:
		prewarm(group)


static func is_ready(group: StringName) -> bool:
	return _ready.has(group)


## 等待某组预热结束；未开始预热也算完成（调用方通常只关心"还要不要等"）
static func await_ready(group: StringName, timeout_ms: int = 8000) -> bool:
	if _running.has(group):
		await AsyncTool.await_until(
			func(): return not _running.has(group), timeout_ms, str("预热 ", group), AsyncTool.TimeBase.REAL_TIME)
	return _ready.has(group)


## 0~1；未注册返回 1
static func get_progress(group: StringName) -> float:
	var paths: PackedStringArray = _groups.get(group, PackedStringArray())
	if paths.is_empty():
		return 1.0
	var done := 0
	for p in paths:
		if _loaded.has(p):
			done += 1
	return float(done) / paths.size()


## 进度 + 已用 + 预计剩余(给加载界面显示"还需 2.3s")。
## eta_ms = -1 表示尚不可估(还没开始/一项都没完成), 0 表示已完成。
static func get_status(group: StringName) -> Dictionary:
	var progress := get_progress(group)
	var elapsed := 0
	var eta := 0 if _ready.has(group) else -1
	if _started.has(group):
		elapsed = Time.get_ticks_msec() - int(_started[group])
		# 已有完成项时按"已用 / 完成比例"线性外推
		if progress > 0.0 and progress < 1.0:
			eta = int(float(elapsed) * (1.0 - progress) / progress)
	return {
		"group": str(group),
		"progress": progress,
		"elapsed_ms": elapsed,
		"eta_ms": eta,
		"eta_text": "未知" if eta < 0 else PerfTool.fmt_ms(float(eta)),
	}


static func _run(group: StringName) -> void:
	var paths: PackedStringArray = _groups.get(group, PackedStringArray())
	var started := Time.get_ticks_msec()
	var timed_out := false
	for p in paths:
		_request(p)
	while _pending_count(paths) > 0:
		## 兜底：驱动/IO 极端情况下别让协程永远挂着
		if Time.get_ticks_msec() - started > TIMEOUT_MS:
			LogTool.warn("预热", "%s 超时(%dms)，放弃剩余 %d 项" % [group, TIMEOUT_MS, _pending_count(paths)])
			for p in paths:
				_pending.erase(p)
			timed_out = true
			break
		await Engine.get_main_loop().process_frame
		for p in paths:
			_poll(p)
	_running.erase(group)
	_started.erase(group)
	## 超时不算预热完成: 否则 is_ready 为 true 但资源其实没加载, 且再也不会重试
	if not timed_out:
		_ready[group] = true
	var elapsed := Time.get_ticks_msec() - started
	# 历史基线: 下次同组预热在开始前就能给出"大概要多久"
	PerfTool.record("prewarm:" + str(group), float(elapsed))
	LogTool.log("预热", "%s 完成: %d 项 %dms" % [group, paths.size(), elapsed])


static func _request(path: String) -> void:
	if _loaded.has(path) or _pending.has(path):
		return
	if ResourceLoader.has_cached(path):
		_loaded[path] = ResourceLoader.load(path)
		return
	if ResourceLoader.load_threaded_request(path, "", true) == OK:
		_pending[path] = true


static func _poll(path: String) -> void:
	if not _pending.has(path):
		return
	match ResourceLoader.load_threaded_get_status(path):
		ResourceLoader.THREAD_LOAD_LOADED:
			_loaded[path] = ResourceLoader.load_threaded_get(path)
			_pending.erase(path)
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			LogTool.warn("预热", "加载失败: ", path)
			_pending.erase(path)


static func _pending_count(paths: PackedStringArray) -> int:
	var n := 0
	for p in paths:
		if _pending.has(p):
			n += 1
	return n
