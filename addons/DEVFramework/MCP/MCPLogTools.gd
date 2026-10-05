@tool
extends RefCounted

## ======= 日志 / 错误域 =======
##
## 收录"读 / 清**本进程**日志缓冲"这一类能力: get_logs / clear_logs, 外加一个供主服务器进程侧
## 复用的底层件 _call_collect_logs。三个函数沿用主文件里的**原名**不另造名 —— 原名引用点散在主
## 文件多处(尤其 clear_game_errors 与 clear_game_logs 复用同一个 _call_clear_errors)。
##
## ## 进程归属: 只由工具名决定, 不由参数决定
##
## 本文件注册的这一对恒读编辑器进程自己的缓冲, 游戏进程的一律 get_game_*/clear_game_*。
## 旧实现给 get_logs 加了 source=auto 会在游戏运行时静默改读游戏缓冲 —— 编辑器侧 eval_code
## 捕获的错误用 get_logs(kind=error) 查出来就成了游戏的错误。现已全部收掉: 跨进程只剩
## _register_game_play_tool 的 editor lambda 一条通路。
##
## ## 依赖方向: 严格单向
##
## 本文件**不引用** MCPDevServer, 也不持有服务器实例状态。注册靠"把 _add_tool 当 Callable 传
## 进来"完成, 连服务器的类型都不需要认识。
##
## 捕获器用 static 注入的原因: handler 签名由协议定死(只收 args), 而捕获器是 MCPDevServer 的
## 实例字段, 本文件既不认识它也不该自己再造一个(再造一个等于把引擎输出抄到第二个缓冲, 于是
## get_logs 读的那份与主服务器诊断读的那份彼此独立, clear_logs 只清得掉其中一份)。
## 绑定必须发生在**捕获器建好之后**, 两个进程各一次; 漏绑不崩, 只报"日志捕获器未就绪"。
##
## handler 一律 static、禁 lambda: MCPToolAudit 靠 handler.get_method() 拿函数名去源码切函数体,
## lambda 会返回 "<anonymous lambda>", 那批工具会被记成"检查缺失"。
##
## ## 主文件侧调用形式
##
##   register(_add_tool)                    编辑器侧 _register_log_tools() 内
##   bind_logger(_logger)                   两个进程各一次, 漏绑只报"未就绪"
##   _call_collect_logs(args, is_errors)    游戏侧 get_game_logs / get_game_errors 复用
##   _call_clear_errors(args)               clear_game_errors / clear_game_logs 的 handler
##
## **主文件不得保留同名函数**: MCPToolAudit.func_body 按函数名在全目录找第一个命中, 而
## "MCPDevServer.gd" 字典序在 "MCPLogTools.gd" 之前 —— 主文件若还留着同名的一份, 切出来的
## 永远是不该被检查的那份, 入参自检会张冠李戴。
##
## **必须带 @tool 且不声明 class_name**, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 本进程日志捕获器。由 MCPDevServer 建好 _logger 后 bind_logger() 注入; 未注入时报"未就绪"。
static var _logger: MCPLogger = null


## 绑定本进程日志捕获器。以最后一次为准: 热重载会新建捕获器, 重新注册时再绑一次。
##
## **接缝判据(全局统一)**: 接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。
## 本域选注入: 漏调后果是工具返回"日志捕获器未就绪", **显式报错**。validate 域否决接缝(漏调会
## 让 validate 恒返回 valid=true, 静默失效); dev 域也注入但自带告警(漏调后果最隐蔽)。
## 本域专属的否决理由: 捕获器在本进程内只有 MCPDevServer 那一个, 自建副本等于把引擎输出抄到
## 第二个缓冲 —— clear_logs 只清得掉其中一份, 这是**用户可见的语义错误**。
static func bind_logger(logger: MCPLogger) -> void:
	_logger = logger


## ======= 域注册入口 =======
##
## 由 MCPDevServer._register_log_tools() 调用一次。add_tool 是服务器 `_add_tool` 的 Callable,
## 签名 (name, desc, input_schema, handler)。

static func register(add_tool: Callable) -> void:
	## -- 日志/错误 --
	add_tool.call("get_logs",
		"【编辑器进程】获取**编辑器侧**日志/错误/警告(获取而非打印)。kind=log 取print日志; kind=warning 取push_warning警告; kind=error 取脚本错误(script_error/shader_error/stderr, 含栈追踪)。游戏进程侧请用 get_game_logs / get_game_errors —— 本工具恒读编辑器缓冲, 不会在游戏运行时被静默换成游戏日志。返回next游标作since增量拉取, 连续重复自动合并(repeat计数)节省token。",
		MCPToolSchema.logs("200(log)/100(warning|error)", "条目", {
			"kind": {"type": "string", "enum": ["log", "warning", "error"], "description": "获取类别, 默认 log"},
		}),
		_call_get_logs)

	add_tool.call("clear_logs",
		"【编辑器进程】清空**编辑器侧**日志/错误缓冲(调试复位)。scope=all 全清; scope=logs 只清print日志; scope=errors 只清错误与警告。游戏进程侧请用 clear_game_logs / clear_game_errors。",
		{"type": "object", "properties": {
			"scope": {"type": "string", "enum": ["all", "logs", "errors"], "description": "清理范围, 默认 all"}
		}},
		_call_clear_errors)


## ======= 实现 =======

## get_logs: 只读**本进程**(编辑器侧)缓冲, kind=log/warning/error。
## 不设 source 跨进程取日志 —— 缘由见本文件顶部"进程归属"一节。
static func _call_get_logs(args: Dictionary) -> Dictionary:
	var kind := VariantTool.get_string(args, "kind", "log")
	var is_errors := kind == "error" or kind == "warning"
	# _call_collect_logs 内无 await, 故此处不必 await(对非协程 await 是多余的)。
	var result: Dictionary = _call_collect_logs(args, is_errors)
	if is_errors:
		# 错误必须原样返回, 不能进过滤分支: payload 兜底取的是 result 本身,
		# 对错误结果而言 .get("errors") 恒为 [] —— 于是 game_stopped / transient 这类
		# "取不到日志" 会被渲染成"成功, 0 条错误", 把一个该重试或该重启游戏的故障
		# 报成"一切正常"。这是本函数最容易骗过 AI 的一处, 故在分流点上拦。
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


## 清空**本进程**的日志/错误缓冲。clear_logs 与 clear_game_errors 共用本实现: 差别只在注册于
## 哪一侧, 跨进程转发由 _register_game_play_tool 负责。故必须是 static 且签名与 handler 一致
## (args -> Dictionary), 不能收窄成只吃 scope 字符串, 否则那两处注册会引用不到。
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
## 进程归属由调用它的工具名决定, 跨进程只有 editor lambda 一条通路(内部再代理一次曾让
## source=auto 静默把"查编辑器错误"换成游戏缓冲)。
##
## 处理顺序固定为 contains 过滤 → merge 合并 → max 截断, 故 max 的语义是**合并后**的条数
## (与 MCPToolSchema.logs() 的描述必须一致)。游戏侧也调本函数: 两个进程读的必须是同一套参数
## 语义, 各写一份必然漂移。
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
	# 且在 max 截断之前: 反过来就变成"最近 max 条里的匹配", 目标条目出现得早一点就再也捞不到,
	# 而"捞不到"对调试工具是最严重的失败模式(且它伪装成"日志里没有", 会把人引向错误的结论)
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
		# 而不必把"没捞到"误判成"日志里没有" —— 后者会把排查引向完全错误的方向
		"contains": contains,
		"hint": hint,
	}
	if is_errors:
		payload["errors"] = out
		payload["cleared"] = bool(result.get("cleared", false))
	else:
		payload["logs"] = out
	return MCPResult.ok_json(payload)