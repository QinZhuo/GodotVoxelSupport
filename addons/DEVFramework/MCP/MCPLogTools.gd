@tool
extends RefCounted

## ======= 日志 / 错误域 =======
## 绑定必须发生在**捕获器建好之后**, 两个进程各一次; 漏绑不崩, 只报"日志捕获器未就绪"。
## **主文件不得保留同名函数**: MCPToolAudit.func_body 按函数名在全目录找第一个命中, 而
## **必须带 @tool 且不声明 class_name**, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 本进程日志捕获器。由 MCPDevServer 建好 _logger 后 bind_logger() 注入; 未注入时报"未就绪"。
static var _logger: MCPLogger = null


## 绑定本进程日志捕获器。以最后一次为准: 热重载会新建捕获器, 重新注册时再绑一次。
## **接缝判据(全局统一)**: 接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。
static func bind_logger(logger: MCPLogger) -> void:
	_logger = logger


## ======= 实现 =======

## get_logs: 只读**本进程**(编辑器侧)缓冲, kind=log/warning/error。
static func _call_get_logs(args: Dictionary) -> Dictionary:
	var kind := VariantTool.get_string(args, "kind", "log")
	var is_errors := kind == "error" or kind == "warning"
	# _call_collect_logs 内无 await, 故此处不必 await(对非协程 await 是多余的)。
	var result: Dictionary = _call_collect_logs(args, is_errors)
	if is_errors:
		# 错误必须原样返回, 不能进过滤分支: payload 兜底取的是 result 本身,
		if bool(result.get("is_error", false)):
			return result
		# 按类别过滤: warning 只要 type==warning; error 排除 warning(script_error/shader_error/stderr/error)
		var want_warning := kind == "warning"
		var payload: Dictionary = result.get("structuredContent", result)
		var entries: Array = payload.get("errors", [])
		var filtered := entries.filter(func(e: Dictionary):
			var t := str(e.get("type", ""))
			return (t == "warning") if want_warning else (t != "warning"))
		payload["errors"] = filtered
		payload["count"] = filtered.size()
		return MCPResult.ok_json(payload)
	return result


## 清空**本进程**的日志/错误缓冲(clear_logs 的进程侧实现)。跨进程转发由 MCPDevServer 的路由
static func _call_clear_errors(args: Dictionary) -> Dictionary:
	var scope := VariantTool.get_string(args, "scope", "all")
	if _logger:
		if scope == "all" or scope == "errors":
			_logger.clear_errors()
		if scope == "all" or scope == "logs":
			_logger.clear_messages()
	return MCPResult.ok("已清空%s缓冲区" % ("全部" if scope == "all" else ("错误" if scope == "errors" else "日志")))


## ======= 底层件: get_logs 与游戏侧 get_game_* 共用 =======

## 收集**本进程**的日志/错误: is_errors=true 取错误, false 取日志。刻意不做跨进程代理 ——
## (与 MCPToolSchema.logs() 的描述必须一致)。游戏侧也调本函数: 两个进程读的必须是同一套参数
static func _call_collect_logs(args: Dictionary, is_errors: bool) -> Dictionary:
	if _logger == null:
		return MCPResult.fail("错误捕获器未就绪" if is_errors else "日志捕获器未就绪")
	var max: int = VariantTool.get_int(args, "max", 100 if is_errors else 200)
	# since: 上次拉取返回的 next 游标, 增量拉取新条目以节省上下文(token)。默认 0 = 全量。
	var since: int = VariantTool.get_int(args, "since")
	# merge: 连续重复的同内容条目合并为一条(repeat 计数), 减少 token。默认 true。
	var merge: bool = VariantTool.get_bool(args, "merge", true)
	var result: Dictionary = _logger.take_errors_since(since) if is_errors else _logger.take_logs_since(since)
	var clean: Array = []
	for e in result.entries:
		var c: Dictionary = e.duplicate(is_errors)
		if c.has("message"):
			c.message = _logger.sanitize(str(c.message))
		clean.append(c)
	# contains: 按 message 子串过滤。位置很关键 —— 必须在 merge 之前(先缩小范围再合并更省)
	var contains := VariantTool.get_string(args, "contains").strip_edges()
	if not contains.is_empty():
		clean = clean.filter(func(e: Dictionary): return contains in str(e.get("message", "")))
	var merged: Array = _logger.merge_duplicates(clean) if merge else clean
	var start := maxi(0, merged.size() - max)
	var out: Array = merged.slice(start)
	var type_word := "错误" if is_errors else "日志"
	var hint := "将 next 作为下次调用的 since 参数即可只取新增%s。连续重复的同位置%s已合并为一条并带 repeat 计数, 可用 merge=false 关闭合并。" % [type_word, type_word]
	var payload := {
		"count": out.size(),
		"next": int(result.get("next", 0)),
		"total_raw": clean.size(),
		# 回显过滤条件: 传了 contains 却漏实现时, 至少能从响应里看出来,
		"contains": contains,
		"hint": hint,
	}
	if is_errors:
		payload["errors"] = out
		payload["cleared"] = bool(result.get("cleared", false))
	else:
		payload["logs"] = out
	return MCPResult.ok_json(payload)