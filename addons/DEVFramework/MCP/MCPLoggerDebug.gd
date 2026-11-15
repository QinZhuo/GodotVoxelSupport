@tool
## MCP 日志与错误捕获器 — 继承 Godot 4.5+ 的 Logger
class_name MCPLogger extends Logger

const CAPACITY := 2000        # 环形缓冲容量(日志条目数)
const ERROR_CAPACITY := 500   # 错误条目容量(含栈追踪, 占空间)

## 日志条目结构: {"time":int毫秒, "message":String, "is_error":bool}
var _messages: Array = []
var _errors: Array = []
var _base_index := 0          # 已从 _messages 头部丢弃的逻辑消息数
var _err_base_index := 0      # 已从 _errors 头部丢弃的逻辑错误数
var _mutex := Mutex.new()


func _init() -> void:
	pass


## 由 _log_message 调用 — 捕获普通 print / printerr(text流)
func _log_message(message: String, error: bool) -> void:
	_mutex.lock()
	if error:
		# printerr 输出也计入错误列表末尾, 方便统一查看
		_push_error({"time": Time.get_ticks_msec(), "message": _strip_ansi(message), "is_error": true, "type": "stderr", "stack": []})
	else:
		_messages.append({"time": Time.get_ticks_msec(), "message": _strip_ansi(message), "is_error": false})
		if _messages.size() > CAPACITY:
			_messages.pop_front()
			_base_index += 1
	_mutex.unlock()


## 由 _log_error 调用(捕获 push_error/脚本错误/assert 等, 含栈追踪)
func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		editor_notify: bool,
		error_type: int,
		script_backtraces: Array[ScriptBacktrace]
) -> void:
	var bt_texts: Array = []
	for bt in script_backtraces:
		var lines: Array = []
		for i in bt.get_frame_count():
			var label: String = bt.get_frame_function(i)
			var src: String = bt.get_frame_file(i)
			var ln: int = bt.get_frame_line(i)
			lines.append("    at %s (%s:%d)" % [label, src, ln])
		bt_texts.append({"language": bt.get_language_name(), "frames_raw": bt.format(), "lines": lines})
	_mutex.lock()
	_push_error({
		"time": Time.get_ticks_msec(),
		"message": rationale if not rationale.is_empty() else code,
		"type": _error_type_name(error_type),
		"function": function,
		"file": file,
		"line": line,
		"code": code,
		"stack": bt_texts,
	})
	_mutex.unlock()


func _error_type_name(t: int) -> String:
	match t:
		Logger.ErrorType.ERROR_TYPE_WARNING: return "warning"
		Logger.ErrorType.ERROR_TYPE_SCRIPT: return "script_error"
		Logger.ErrorType.ERROR_TYPE_SHADER: return "shader_error"
	return "error"


func _push_error(entry: Dictionary) -> void:
	_errors.append(entry)
	if _errors.size() > ERROR_CAPACITY:
		_errors.pop_front()
		_err_base_index += 1


## 剥离 ANSI 转义序列(颜色码等)。这些控制字符会被 JSON.stringify 原样输出,
func _strip_ansi(text: String) -> String:
	if not text.contains(String.chr(27)):
		return text
	var out := ""
	var i := 0
	var len := text.length()
	while i < len:
		var c := text.unicode_at(i)
		if c == 27:
			i += 1
			if i < len and text.unicode_at(i) == 91:
				# CSI 序列: ESC [ 参数… 最终字节(0x40-0x7E)
				i += 1
				while i < len:
					var cc := text.unicode_at(i)
					if cc >= 64 and cc <= 126:
						i += 1
						break
					i += 1
			# 其它 ESC 起始序列直接跳过 ESC 本身
			continue
		out += String.chr(c)
		i += 1
	return out


## 合并连续重复的条目为一条, 减少 JSON 体积节省 token。
func merge_duplicates(entries: Array) -> Array:
	if entries.is_empty():
		return entries
	var out: Array = []
	var i := 0
	while i < entries.size():
		var e: Dictionary = entries[i]
		var key := _entry_key(e)
		var count := 1
		var last_time: int = int(e.get("time", 0))
		var j := i + 1
		while j < entries.size():
			var nxt: Dictionary = entries[j]
			if _entry_key(nxt) != key:
				break
			count += 1
			last_time = int(nxt.get("time", 0))
			j += 1
		if count > 1:
			e["repeat"] = count
			e["first_time"] = int(e.get("time", 0))
			e["last_time"] = last_time
		out.append(e)
		i = j
	return out


## 条目合并签名: 日志只有 message; 错误叠加 type/file/line/code(栈帧差异不计入, 保证同位置错误可合并)
func _entry_key(e: Dictionary) -> String:
	var key := str(e.get("message", ""))
	if e.has("type"):
		key += "\n" + str(e.get("type", ""))
	if e.has("file"):
		key += "\n" + str(e.get("file", "")) + ":" + str(e.get("line", ""))
	if e.has("code"):
		var code := str(e.get("code", ""))
		if not code.is_empty():
			key += "\n" + code
	return key


## 获取新增日志(自 last_index 起), 返回 [entries, new_index]
func take_logs_since(last_index: int) -> Dictionary:
	_mutex.lock()
	var new_entries: Array = []
	var start := maxi(last_index, _base_index)
	for i in range(start, _base_index + _messages.size()):
		new_entries.append(_messages[i - _base_index])
	var result := {"entries": new_entries, "next": _base_index + _messages.size()}
	_mutex.unlock()
	return result


## 获取新增错误(自 last_index 起的逻辑序号)
func take_errors_since(last_index: int) -> Dictionary:
	_mutex.lock()
	var new_entries: Array = []
	var start := maxi(last_index, _err_base_index)
	for i in range(start, _err_base_index + _errors.size()):
		new_entries.append(_errors[i - _err_base_index])
	var result := {"entries": new_entries, "next": _err_base_index + _errors.size(), "cleared": _errors.is_empty()}
	_mutex.unlock()
	return result


## 当前错误逻辑游标(应在执行序列前快照, 作为 take_errors_since 的 since)。
## 依赖"执行前后新增错误"的工具(validate_script/eval_code 的诊断)必须用游标而非数组大小。
func get_error_cursor() -> int:
	_mutex.lock()
	var c := _err_base_index + _errors.size()
	_mutex.unlock()
	return c


## 把"自 cursor 起新增的引擎报错"格式化成可读详情(每条带行号, 最多 5 条)。
func describe_errors_since(cursor: int) -> String:
	if cursor < 0:
		return "(未提供错误游标, 详细解析错见 get_logs kind=error)"
	var taken := take_errors_since(cursor)
	var entries: Array = taken.get("entries", [])
	var lines := PackedStringArray()
	for e in entries:
		if not (e is Dictionary):
			continue
		var msg := str((e as Dictionary).get("message", "")).strip_edges()
		if msg.is_empty():
			continue
		var ln := str((e as Dictionary).get("line", ""))
		lines.append("- %s%s" % [msg, ("" if ln.is_empty() else "  (行 %s)" % ln)])
		if lines.size() >= 5:
			break
	return "(引擎未提供详细解析错)" if lines.is_empty() else "具体:\n" + "\n".join(lines)


## 清空错误缓冲区(调试复位用)
func clear_errors() -> void:
	_mutex.lock()
	_errors.clear()
	_err_base_index = 0
	_mutex.unlock()


func clear_messages() -> void:
	_mutex.lock()
	_messages.clear()
	_base_index = 0
	_mutex.unlock()


## 供运行游戏日志合并(带来源前缀), 线程安全
func append_external(message: String, prefix: String = "[运行] ") -> void:
	_mutex.lock()
	_messages.append({"time": Time.get_ticks_msec(), "message": prefix + _strip_ansi(message), "is_error": false})
	if _messages.size() > CAPACITY:
		_messages.pop_front()
		_base_index += 1
	_mutex.unlock()


func get_message_count() -> int:
	_mutex.lock()
	var n := _messages.size()
	_mutex.unlock()
	return n


func get_error_count() -> int:
	_mutex.lock()
	var n := _errors.size()
	_mutex.unlock()
	return n


## 公开清洗接口: 供 MCP 工具在输出 JSON 前兜底剥离控制字符
func sanitize(message: String) -> String:
	return _strip_ansi(message)