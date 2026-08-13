@tool
## MCP 开发服务器(autoload 单例, 编辑器/游戏双角色)
## 以 autoload 形式注册, 在编辑器和游戏进程中都会加载(见 project.godot [autoload]):
##   - 编辑器进程(Engine.is_editor_hint): 由 plugin.gd 持有节点并 start_editor(),
##     在 8932 端口提供编辑器工具(场景树/节点/项目设置/截图等)以及游戏运行时工具。
##   - 游戏进程: 不开启任何端口, 注册 EngineDebugger 消息捕获器("dev_mcp"),
##     通过编辑器↔游戏的调试线(EngineDebugger wire)接收并原生执行运行时工具:
##     take_screenshot(view文本化/game真实截图) / simulate_click / simulate_drag /
##     simulate_key / game_eval / 游戏日志等。因为在游戏进程内, Input.parse_input_event 等引擎 API 直接生效。
## 编辑器↔游戏通信走 Godot 自带调试线(编辑器以调试模式启动游戏时自动建立), 零额外端口。
## 桥接由 MCPDebuggerPlugin(EditorDebuggerPlugin)负责, 生命周期由 plugin.gd 控制。
class_name MCPDevServer extends Node

## ------- 配置项(ProjectSettings) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_TOKEN := "dev_framework/mcp/token"
const SETTING_MAX_MESSAGES := "dev_framework/mcp/max_messages"
const SETTING_MAX_OUTPUT_CHARS := "dev_framework/mcp/max_output_chars"

## 统一输出上限默认值(字符)。所有工具返回的 text 字段超过此值即转为明确错误提示, 防上下文/token 被撑爆。
const DEFAULT_MAX_OUTPUT_CHARS := 90000

## 输出给 AI 的核心属性白名单(过滤编辑器内部数百项属性, 控制上下文开销)
const CORE_PROP_NAMES := ["name", "position", "scale", "rotation", "rotation_degrees", "visible", "modulate", "process_mode", "z_index", "text", "color"]

## ------- MCP 常量 -------
const PROTOCOL_VERSION := "2025-03-26"
const SERVER_NAME := "devframework-godot-mcp"
const SERVER_VERSION := "0.3.0"

## 模式
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## 调试线消息前缀(编辑器↔游戏 EngineDebugger wire)
const DEBUGGER_PREFIX := "dev_mcp"

## 全局唯一实例(编辑器/游戏进程各自持有)
static var instance: MCPDevServer

var _http: MCPTcpHttpServer
var _logger: MCPLogger
var _port := int(ProjectSettings.get_setting(SETTING_PORT, 8931))
var _enabled := true
var _tool_handlers := {} # 工具名 -> Callable
var _tool_defs := [] # 工具定义列表(MCP 格式)
var _mode := MODE_EDITOR # editor / runtime

## 编辑器模式: 指向 MCPDebuggerPlugin(由 plugin.gd 注入)
var debugger_plugin: MCPDebuggerPlugin = null
## 编辑器模式: 游戏进程 MCP 桥接是否就绪(收到 dev_mcp:ready)
var _game_ready := false
## 编辑器模式: 等待游戏响应的请求表 req_id -> 结果(未就绪为 null)
var _pending := {}
var _next_req_id := 1
## 编辑器模式: 游戏是否处于断点暂停状态(脚本错误/断点导致主循环暂停)
var _game_breaked := false
## 断点暂停时仍可安全执行的工具(只读缓冲, 不依赖游戏主循环):
## 游戏被暂停时 EngineDebugger 调试线程仍活着, 这类工具仅读本地缓冲即返回, 不会挂起。
const _BREAK_SAFE_TOOLS := ["get_game_errors", "get_game_logs"]

## verify_fix 会话(editor 侧): 按 session_id 存验证配置, 支持 start/continue/status/abort 多会话
var _verify_sessions: Dictionary = {}


## ------- 生命周期(autoload) -------
func _ready() -> void:
	instance = self
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8931))
	if Engine.is_editor_hint():
		# 编辑器进程: 生命周期完全由 plugin.gd 控制(启用时 start_editor()/停用时 stop())。
		# 这里仅登记 instance, 不自动启动, 避免与插件开关产生端口/生命周期冲突。
		return
	# 游戏进程: 仅注册调试线消息捕获器, 供编辑器经 EngineDebugger wire 调用运行时工具。
	# 不开启任何端口; 正常手动运行/发布版无调试线, 捕获器注册后无消息到达, 无副作用。
	if not _enabled:
		return
	_mode = MODE_RUNTIME
	_logger = MCPLogger.new()
	OS.add_logger(_logger)
	_register_runtime_tools()
	# 防御: 若本单例被实例化多次/热重载等导致 capture 已注册, 跳过而非崩溃
	if not EngineDebugger.has_capture(DEBUGGER_PREFIX):
		EngineDebugger.register_message_capture(DEBUGGER_PREFIX, _on_debugger_message)
	# 通知编辑器侧桥接已就绪(仅在调试线激活时有意义, 未连接时 send_message 无害)
	EngineDebugger.send_message(DEBUGGER_PREFIX + ":ready", [])


## 游戏进程: 处理编辑器经调试线发来的工具调用消息。
## 注意: 游戏侧注册捕获器后, 回调收到的 message 已去掉前缀(见 EngineDebugger 文档),
## 例如编辑器发 "dev_mcp:call", 这里收到的是 "call"。返回 true 表示消息已被消费。
func _on_debugger_message(message: String, data: Array) -> bool:
	if message != "call" or data.size() < 3:
		return false
	var req_id := int(data[0])
	var tool_name := str(data[1])
	var args: Dictionary = data[2] if data[2] is Dictionary else {}
	# 分发到已注册的运行时工具, 结果经调试线回发(不阻塞调用方; fire-and-forget)
	_call_runtime_tool_async(req_id, tool_name, args)
	return true


func _call_runtime_tool_async(req_id: int, tool_name: String, args: Dictionary) -> void:
	var result: Dictionary
	if _tool_handlers.has(tool_name):
		result = await _tool_handlers[tool_name].call(args)
	else:
		result = _fail("未知运行时工具: %s" % tool_name)
	# 统一输出上限: 与编辑器进程一致, 超限转明确错误提示后再回发(避免调试线承载巨型载荷)。
	result = _enforce_output_cap(tool_name, result)
	EngineDebugger.send_message(DEBUGGER_PREFIX + ":result", [req_id, result])


## 编辑器进程: MCPDebuggerPlugin._capture 委托至此(处理 ready/result)。
func _on_debugger_capture(message: String, data: Array) -> bool:
	if not message.begins_with(DEBUGGER_PREFIX + ":"):
		return false
	var kind := message.get_slice(":", 1)
	match kind:
		"ready":
			_game_ready = true
			LogTool.log("MCP", "游戏调试线桥接已就绪")
		"result":
			if data.size() >= 2:
				var req_id := int(data[0])
				_pending[req_id] = data[1]
	return true


## 编辑器进程: 游戏调试会话建立/结束(由 MCPDebuggerPlugin 连接信号调用)
func _on_session_started(session_id: int) -> void:
	LogTool.log("MCP", "游戏调试会话已建立(session=%d)" % session_id)
	_game_ready = false
	# 保留旧的未决失败结果不覆盖; 新会话开始, 旧请求已无意义
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err("游戏调试会话已重启, 原请求被取消", "transient", true, "重新调用该工具即可")
	_pending.clear()


## 游戏会话结束(正常停止/崩溃/被杀)。填充所有未决请求为失败结果,
## 等待中的 _call_runtime_proxy 能立即读到(而不是干等超时)。
## 注意: 填充后不能 clear(), 否则代理读不到结果会退回 20s 超时。
func _on_session_stopped(session_id: int) -> void:
	LogTool.log("MCP", "游戏调试会话已结束(session=%d)" % session_id)
	_game_ready = false
	_game_breaked = false
	var msg := "游戏进程已停止(正常结束或崩溃), 所有未完成的运行时调用被取消。请先 run_game 重新启动游戏后再试。"
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err(msg, "game_stopped", true, "调用 run_game 重新启动游戏, 等待调试线就绪后重试")


## 游戏进入断点暂停(脚本错误/断点触发, 主循环暂停但调试线仍在)。
## 此时运行时工具若发请求会干等超时, 应立即填充未决请求为明确错误, 让 AI 知道是"游戏被调试器暂停"而非无响应。
func _on_session_breaked(_session_id: int, can_debug: bool) -> void:
	_game_breaked = true
	LogTool.log("MCP", "游戏已进入断点暂停(调试循环=%s)。运行时工具会立即返回明确错误, 可用 debug_continue 让游戏继续。" % str(can_debug))
	var msg := "游戏被断点暂停(脚本错误/断点)。get_game_errors/get_game_logs仍可用, 先查错误; 再debug_continue继续; 要修脚本则stop_game后改代码重跑。"
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err(msg, "game_breaked", true, "get_game_errors查错后debug_continue; 或stop_game修复重启")


## 游戏解除断点暂停, 恢复运行
func _on_session_continued(_session_id: int) -> void:
	_game_breaked = false
	LogTool.log("MCP", "游戏已恢复运行(解除断点暂停)")


## 编辑器进程: 编辑器模式显式启动(由 plugin.gd 在启用插件时调用)。
## 尊重 dev_framework/mcp/enabled 主开关: 为 false 时不启动服务器(与游戏进程行为一致)。
func start_editor() -> void:
	if _http:
		return
	_mode = MODE_EDITOR
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	if not _enabled:
		LogTool.log("MCP", "dev_framework/mcp/enabled=false, 编辑器 MCP 服务器已跳过启动")
		return
	if _logger == null:
		_logger = MCPLogger.new()
		OS.add_logger(_logger)
	_register_editor_tools()
	start()


## 每帧驱动 HTTP 服务器
func _process(_delta: float) -> void:
	if _http:
		_http.poll()


## 关闭服务器并移除 Logger(退出时由引擎自动调用)
func _exit_tree() -> void:
	stop()
	if EngineDebugger.is_active() and EngineDebugger.has_capture(DEBUGGER_PREFIX):
		EngineDebugger.unregister_message_capture(DEBUGGER_PREFIX)
	if _logger:
		OS.remove_logger(_logger)
		_logger = null


## ------- 服务器启停 -------
func start() -> void:
	if not _enabled or _http:
		return
	_http = MCPTcpHttpServer.new()
	var err := _http.listen(_port)
	if err != OK:
		printerr("MCPDevServer: 监听端口 %d 失败 (错误码 %d)。已自动跳过, AI 助手将无法连接。" % [_port, err])
		_http = null
		return
	_http.request_received.connect(_on_request)
	LogTool.log("MCP", "MCP 服务器已开启(%s): http://127.0.0.1:%d/mcp" % [_mode, _port])
	LogTool.log("MCP", "可用工具(%s): %s" % [_mode, _tool_defs.map(func(d): return d.name)])


func stop() -> void:
	if _http:
		_http.request_received.disconnect(_on_request)
		_http.stop()
		_http = null


func is_running() -> bool:
	return _http != null and _http.is_listening()


## ------- 工具注册 -------
func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_defs.append({"name": name, "description": desc, "inputSchema": input_schema})


## 无参工具的标准 schema
func _no_arg_schema() -> Dictionary:
	return {"type": "object", "properties": {}}


## 常用 path 参数
func _path_arg(desc: String) -> Dictionary:
	return {"type": "string", "description": desc}


## 常用 code 参数
func _code_arg(desc: String = "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)") -> Dictionary:
	return {"type": "string", "description": desc}


## 游戏操作工具 schema(editor 代理版与 runtime 原生版共用)
func _simulate_click_schema() -> Dictionary:
	return {"type": "object", "properties": {
		"x": {"type": "integer", "description": "屏幕X坐标"},
		"y": {"type": "integer", "description": "屏幕Y坐标"},
	}, "required": ["x", "y"]}


func _simulate_drag_schema() -> Dictionary:
	return {"type": "object", "properties": {
		"from_x": {"type": "integer", "description": "起始X坐标"},
		"from_y": {"type": "integer", "description": "起始Y坐标"},
		"to_x": {"type": "integer", "description": "目标X坐标"},
		"to_y": {"type": "integer", "description": "目标Y坐标"},
	}, "required": ["from_x", "from_y", "to_x", "to_y"]}


func _simulate_key_schema() -> Dictionary:
	return {"type": "object", "properties": {
		"key": {"type": "string", "description": "按键名称, 如 'space', 'enter', 'escape', 'a'-'z', '0'-'9'"},
		"pressed": {"type": "boolean", "description": "true=按下, false=释放, 默认 true"},
	}, "required": ["key"]}


func _logs_schema(default_max: int, unit: String) -> Dictionary:
	return {"type": "object", "properties": {
		"max": {"type": "integer", "description": "最多条数(合并后), 默认 %d" % default_max},
		"since": {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的%s, 默认 0=全量" % unit},
		"merge": {"type": "boolean", "description": "是否合并连续重复%s, 默认 true" % unit},
	}}


## auto_verify 参数 schema
func _auto_verify_schema() -> Dictionary:
	return {"type": "object", "properties": {
		"scene": {"type": "string", "description": "要启动的场景 res:// 路径, 缺省用主场景"},
		"duration": {"type": "number", "description": "单次运行总时长上限(秒), 默认 4, 超过判失败"},
		"stop_on_error": {"type": "boolean", "description": "任一步出错立即停止(true=hard)还是跑完再汇总(false=soft), 默认 true"},
		"retries": {"type": "integer", "description": "失败后的重试次数(总执行=1+retries)。每轮独立重启场景, 用于排除 flaky/时序性失败。默认 0"},
		"retry_backoff_ms": {"type": "integer", "description": "重试间隔毫秒, 默认 500"},
		"prev_snapshot": {"type": "object", "description": "可选: 上次的 scene_deps 快照(由本工具返回), 传入后检测本次执行前脚本/资源/配置是否变化, 结果含 deps_changed(兼容 code_changed)。供 verify_fix 复用。"},
		"operations": {"type": "array", "description": "操作序列(模拟玩家行为+延迟+断言)。每步格式: {'action': wait/click/drag/key/eval/poll/screenshot, ...}. wait 带 ms; click 带 x/y; drag 带 from_x/from_y/to_x/to_y; key 带 key; eval 带 code(GDScript, 可return); poll 带 code+timeout_ms(轮询直到返回 true); screenshot 可带 capture_type。操作间自动串行执行。"},
	}}


## 通用游戏操作工具注册: editor 侧 handler 经调试线转发, runtime 侧就地执行
func _register_game_play_tool(name: String, desc: String, schema: Dictionary, runtime_handler: Callable, editor_handler: Callable) -> void:
	if _mode == MODE_EDITOR:
		_add_tool(name, desc, schema, editor_handler)
	else:
		_add_tool(name, desc, schema, runtime_handler)


func _reset_tools() -> void:
	_tool_handlers.clear()
	_tool_defs.clear()


func _register_editor_tools() -> void:
	_reset_tools()
	_register_validate_tools()
	_register_log_tools()
	_register_screenshot_tools()
	_register_scene_tools()
	_register_scene_edit_tools()
	_register_project_tools()
	_register_run_tools()
	_register_dev_tools()
	_register_file_tools()
	_register_game_play_tools()


## ------- 工具实现 =======

## -- 脚本/资源验证 --
func _register_validate_tools() -> void:
	_add_tool("validate_script",
		"验证GDScript脚本语法/可编译性。传path(res://)读磁盘脚本, 或传code源码。返回是否有效与错误明细。",
		{"type": "object", "properties": {"path": _path_arg("脚本 res:// 路径, 与 code 二选一"), "code": {"type": "string", "description": "GDScript 源码文本, 与 path 二选一"}}},
		_call_validate_script)

	_add_tool("validate_resource",
		"验证资源/场景能否被引擎加载, 返回是否可加载及错误信息。排查.tres/.tscn损坏或依赖缺失。",
		{"type": "object", "properties": {"path": _path_arg("资源 res:// 路径")}},
		_call_validate_resource)

	_add_tool("list_dir",
		"列出res://或user://目录下的文件/子目录。",
		{"type": "object", "properties": {"path": _path_arg("目录路径, 默认 res://"), "recursive": {"type": "boolean", "description": "是否递归列出子目录, 默认 false"}}},
		_call_list_dir)

	_add_tool("classdb_query",
		"查询Godot类API(方法/属性/信号/枚举)。search模糊搜类名, class_name查指定类成员。写脚本前确认API签名用。返回JSON。",
		{"type": "object", "properties": {
			"class_name": {"type": "string", "description": "要查询的类名(如 CharacterBody2D/Button), 提供后返回该类的成员清单"},
			"search": {"type": "string", "description": "按关键字模糊搜索类名(如 'body' 匹配 CharacterBody2D/RigidBody2D 等)"},
			"methods": {"type": "boolean", "description": "是否返回方法清单, 默认 true"},
			"properties": {"type": "boolean", "description": "是否返回属性清单, 默认 true"},
			"signals": {"type": "boolean", "description": "是否返回信号清单, 默认 true"}
		}},
		_call_classdb_query)


## -- 日志/错误 --
func _register_log_tools() -> void:
	_add_tool("get_logs",
		"获取print/printerr日志, 含时间戳/错误流。返回next游标, 增量用其作since避免重复。连续重复的同内容日志自动合并为一条(repeat 计数)以节省token。游戏运行时返回游戏日志, 否则编辑器日志。",
		{"type": "object", "properties": {
			"max": {"type": "integer", "description": "最多返回条数(合并后), 默认 200"},
			"since": {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的日志, 默认 0=全量"},
			"merge": {"type": "boolean", "description": "是否合并连续重复日志, 默认 true"}
		}},
		_call_get_logs)

	_add_tool("get_errors",
		"获取捕获的错误(脚本错误/assert/push_error), 含文件/行号/类型/栈追踪。返回next游标, 增量用其作since。连续重复的同位置错误自动合并为一条(repeat 计数)以节省token。游戏运行时返回游戏错误, 否则编辑器错误。",
		{"type": "object", "properties": {
			"max": {"type": "integer", "description": "最多返回条数(合并后), 默认 100"},
			"since": {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的错误, 默认 0=全量"},
			"merge": {"type": "boolean", "description": "是否合并连续重复错误, 默认 true"}
		}},
		_call_get_errors)

	_add_tool("clear_errors",
		"清空错误缓冲, 便于新一轮调试。游戏运行时清空游戏错误。",
		_no_arg_schema(),
		_call_clear_errors)


## -- 截图 --
func _register_screenshot_tools() -> void:
	# take_screenshot 由 _register_runtime_tools 统一注册(_register_game_play_tool 按 mode 分流),
	# editor 版经 _call_take_screenshot 支持 text/game/editor/scene 四模式。
	pass


## -- 场景树 / 节点 --
func _register_scene_tools() -> void:
	_add_tool("get_scene_tree",
		"获取当前编辑场景的节点树结构(路径/名称/类型)。理解场景结构用。",
		{"type": "object", "properties": {"max_depth": {"type": "integer", "description": "最大展开深度, 默认 8"}, "include_properties": {"type": "boolean", "description": "是否附带每个节点的关键属性, 默认 false"}}},
		_call_get_scene_tree)

	_add_tool("get_node_info",
		"获取编辑场景中指定节点的属性及当前值。path传节点名或路径(如Main/Player)。",
		{"type": "object", "properties": {"path": _path_arg("节点路径(编辑场景内), 如 'Main' 或 'Main/Player'")}},
		_call_get_node_info)

	_add_tool("set_node_property",
		"修改编辑场景中节点属性(调试用), UndoRedo提交可按Ctrl+Z撤。仅改内存, 需save_scene写回.tscn。",
		{"type": "object", "properties": {"path": _path_arg("节点路径(编辑场景内)"), "property": {"type": "string", "description": "属性名"}, "value": {"description": "新值(支持数字/字符串/布尔; Vector2 等可传 '1,2' 字符串)"}}},
		_call_set_node_property)

	_add_tool("call_node_method",
		"调用编辑场景中节点的方法(调试触发逻辑, 如播放动画/切换状态)。args以数组传参。",
		{"type": "object", "properties": {"path": _path_arg("节点路径(编辑场景内)"), "method": {"type": "string", "description": "方法名"}, "args": {"type": "array", "description": "参数数组"}}},
		_call_call_node_method)


## -- 场景编辑 --
func _register_scene_edit_tools() -> void:
	_add_tool("add_node",
		"在当前编辑场景添加节点或实例化子场景。node_type为类名或.tscn的res://路径。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"parent": {"type": "string", "description": "父节点路径(编辑场景内), 缺省为场景根"}, "node_type": {"type": "string", "description": "节点类型类名或子场景 res:// 路径"}, "name": {"type": "string", "description": "新节点名称(可选)"}}},
		_call_add_node)

	_add_tool("save_scene",
		"保存当前编辑场景到.tscn(set_node_property/add_node改动需save后写回)。",
		_no_arg_schema(),
		_call_save_scene)

	_add_tool("remove_node",
		"从当前编辑场景删除指定节点(含子树)。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"path": _path_arg("节点路径(编辑场景内)")}, "required": ["path"]},
		_call_remove_node)

	_add_tool("duplicate_node",
		"复制当前编辑场景中的节点(含子树), 可作为兄弟节点。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"path": _path_arg("要复制的节点路径(编辑场景内)"), "new_name": {"type": "string", "description": "新节点名称(可选, 默认原名+_copy)"}}, "required": ["path"]},
		_call_duplicate_node)

	_add_tool("set_node_transform",
		"设置编辑场景中节点的位置/旋转/缩放(3D用position/rotation/scale, 2D用position)。值支持 '1,2' 等 Vector 格式。",
		{"type": "object", "properties": {
			"path": _path_arg("节点路径(编辑场景内)"),
			"property": {"type": "string", "description": "属性名: position/rotation/scale(3D), position(2D)"},
			"value": {"description": "新值, Vector 用 'x,y' 或 'x,y,z' 字符串"}
		}, "required": ["path", "property", "value"]},
		_call_set_node_transform)

	_add_tool("connect_signal",
		"在编辑场景节点上连接信号到方法(运行时连接, 随场景保存)。source_path源节点, signal信号名(如 'pressed'), method目标方法名, target_path目标节点(缺省为源节点所在场景根)。",
		{"type": "object", "properties": {
			"source_path": {"type": "string", "description": "发出信号的节点路径"},
			"signal": {"type": "string", "description": "信号名(如 pressed)"},
			"method": {"type": "string", "description": "要连接的方法名"},
			"target_path": {"type": "string", "description": "目标节点路径(缺省为源节点)"}
		}, "required": ["source_path", "signal", "method"]},
		_call_connect_signal)


## -- 项目信息 --
func _register_project_tools() -> void:
	_add_tool("get_project_info",
		"项目基本信息(名称/版本/当前场景/运行模式/插件开关)。",
		_no_arg_schema(),
		_call_get_project_info)

	_add_tool("get_project_settings",
		"项目关键配置(主场景/autoload/输入映射/图层命名), 助理解项目约定。",
		_no_arg_schema(),
		_call_get_project_settings)

	_add_tool("get_editor_activity",
		"编辑器状态(打开场景/选中节点/运行游戏/文件系统选中项), 感知用户在编辑器做了什么避免踩踏。",
		_no_arg_schema(),
		_call_get_editor_activity)


## -- 运行游戏 --
func _register_run_tools() -> void:
	_add_tool("run_game",
		"以调试模式启动游戏(等效F5, 自动建EngineDebugger调试线)。scene可选缺省主场景。启动后运行时工具(take_screenshot/simulate_*/game_eval/get_game_logs等)可用。",
		{"type": "object", "properties": {"scene": {"type": "string", "description": "要运行的场景 res:// 路径, 缺省用主场景"}}},
		_call_run_game)

	_add_tool("stop_game",
		"停止运行中的游戏(等效编辑器停止运行)。",
		_no_arg_schema(),
		_call_stop_game)

	_add_tool("verify_fix",
		"有状态验证修复会话: 按 session_id 记住验证配置(操作序列/场景/参数), AI 改完代码后 continue 即自动重跑。continue 时检测场景依赖的脚本/资源/配置是否变化(deps_changed=false 表示没改过依赖, 重跑结果大概率相同)。action: start(默认, 存配置并跑第一轮) / continue(复用配置重跑) / status(查会话, all=true 查全部) / abort(清除会话, all=true 清全部)。返回 round/rounds_done/verdict/was_flaky/deps_changed + 每轮结果。适合'改代码→验→修→再验'循环。",
		{"type": "object", "properties": {
			"action": {"type": "string", "description": "start(默认)/continue/status/abort"},
			"session_id": {"type": "string", "description": "会话标识(可并行多个验证任务), 默认 'default'"},
			"scene": {"type": "string", "description": "要启动的场景 res:// 路径, start 时提供"},
			"operations": {"type": "array", "description": "操作序列(同 auto_verify), start 时提供"},
			"duration": {"type": "number", "description": "单轮运行时长上限(秒), 默认 4"},
			"retries": {"type": "integer", "description": "单轮内失败重试次数, 默认 0"},
			"retry_backoff_ms": {"type": "integer", "description": "单轮内重试间隔毫秒, 默认 500"},
			"stop_on_error": {"type": "boolean", "description": "hard(true)/soft(false), 默认 true"},
			"all": {"type": "boolean", "description": "status/abort 时 true=操作全部会话, 默认 false"}
		}},
		_call_verify_fix)


## -- 开发辅助(重载/求值/设置) --
func _register_dev_tools() -> void:
	_add_tool("reload_project",
		"重扫项目: 重建全局类缓存(class_name立即生效)+重扫资源。新脚本/资源不生效时调用。",
		_no_arg_schema(),
		_call_reload_project)

	_add_tool("eval_code",
		"在编辑器进程执行GDScript(查值/调工具/验证逻辑)。可return返回值, print进get_logs。包装为Node方法, 可用get_tree()/get_node()。缩进自动归一化。字符串内换行用char(10)勿用'\\n'(JSON会拆行)。",
		{"type": "object", "properties": {"code": {"type": "string", "description": "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"}}},
		_call_eval_code)

	_add_tool("get_global_classes",
		"列出已注册的class_name全局类(名称/脚本路径/基类), 确认新脚本进入类缓存。",
		_no_arg_schema(),
		_call_get_global_classes)

	_add_tool("search_symbols",
		"跨脚本与场景/资源配置搜索符号。.gd 支持函数/变量/类定义与引用; .tscn/.tres 支持节点定义(node)、资源关联(ext_resource)、引用。改签名/改节点名/查某资源在哪些场景被用, 或找某功能实现位置。",
		{"type": "object", "properties": {
			"query": {"type": "string", "description": "要搜索的标识符(如 _generate / player_pos / Player 节点名 / MyClass / 资源路径)"},
			"kind": {"type": "string", "description": "过滤: function/variable/class(仅.gd)/node(节点名)/resource(ext_resource)/ref(引用)/all(默认)"},
			"path": _path_arg("限定搜索目录(res://子路径), 默认 res:// 全项目"),
			"include_resources": {"type": "boolean", "description": "是否搜索 .tscn/.tres 文件, 默认 true"},
			"max_results": {"type": "integer", "description": "最多返回条数, 默认 100"}
		}, "required": ["query"]},
		_call_search_symbols)

	_add_tool("find_resource_users",
		"查任意资源的双向依赖: users=谁引用该资源(反向), deps=该资源依赖谁(正向依赖链, 含脚本/配置/场景/资产类型标签)。兼容 Godot4 的 res://路径 与 uid://xxx 两种引用形式。改名/删除/移动资源前查完整影响面。",
		{"type": "object", "properties": {
			"path": _path_arg("目标资源路径(如 res://Scenes/Main.tscn 或 Scenes/Main.tscn)"),
			"max_results": {"type": "integer", "description": "最多返回引用文件数, 默认 100"},
			"include_script_refs": {"type": "boolean", "description": "是否包含 .gd 脚本里的 preload/load 引用, 默认 true"}
		}, "required": ["path"]},
		_call_find_resource_users)

	_add_tool("open_scene",
		"在编辑器打开场景(res://路径)。",
		{"type": "object", "properties": {"path": _path_arg("场景 res:// 路径")}},
		_call_open_scene)

	_add_tool("set_main_scene",
		"设置项目主场景并保存project.godot。",
		{"type": "object", "properties": {"path": _path_arg("主场景 res:// 路径")}},
		_call_set_main_scene)

	_add_tool("get_project_setting",
		"读取任意项目设置项(如application/config/name)。",
		{"type": "object", "properties": {"name": {"type": "string", "description": "设置项名称"}}},
		_call_get_project_setting)

	_add_tool("set_project_setting",
		"修改任意项目设置项并保存, value传JSON值。",
		{"type": "object", "properties": {"name": {"type": "string", "description": "设置项名称"}, "value": {"description": "新值"}}},
		_call_set_project_setting)

	_add_tool("save_all",
		"保存全部打开的场景与项目设置。",
		_no_arg_schema(),
		_call_save_all)

	_add_tool("reimport",
		"重新导入资源(重建.godot/imported缓存), 资源显示异常/导入配置变更后使用。",
		{"type": "object", "properties": {"path": _path_arg("要重新导入的资源 res:// 路径")}},
		_call_reimport)

	_add_tool("create_resource",
		"创建 .tres 资源配置: 指定脚本(class_name 或 res://脚本路径)与属性字典, 写入 res:// 或 user:// 路径。配置驱动开发时创建 Def 资源用。注意: 新建脚本 class_name 需先 reload_project 才能被引擎识别, 若创建失败请先 reload。",
		{"type": "object", "properties": {
			"path": _path_arg("要创建的 .tres 完整路径(如 res://Assets/Def/PCG/MyDef.tres)"),
			"script": {"type": "string", "description": "脚本 class_name 或 res:// 脚本路径(如 GridGenDef 或 res://addons/.../GridGenDef.gd)"},
			"properties": {"type": "object", "description": "属性字典(键=导出属性名, 值=属性值), 可嵌套资源/数组"}
		}, "required": ["path", "script"]},
		_call_create_resource)

	_add_tool("get_resource_info",
		"读取 .tres/.tscn 资源的完整属性树(递归), 便于理解配置结构。返回类型/导出属性/嵌套子资源/引用的脚本。排查配置或了解 Def 资源用。",
		{"type": "object", "properties": {
			"path": _path_arg("资源 res:// 路径(如 res://Assets/Def/PCG/Grid_Cave.tres)"),
			"max_depth": {"type": "integer", "description": "嵌套资源最大展开深度, 默认 5"}
		}, "required": ["path"]},
		_call_get_resource_info)


## -- 文件操作 --
func _register_file_tools() -> void:
	_add_tool("read_file",
		"读取文件内容(UTF-8)。返回内容与大小。",
		{"type": "object", "properties": {
			"path": _path_arg("文件路径(res:// 或 user://)")
		}, "required": ["path"]},
		_call_read_file)

	_add_tool("write_file",
		"写入内容到文件(不存在则创建, 含目录; 存在则覆盖)。",
		{"type": "object", "properties": {
			"path": _path_arg("文件路径(res:// 或 user://)"),
			"content": {"type": "string", "description": "要写入的内容"}
		}, "required": ["path", "content"]},
		_call_write_file)

	_add_tool("append_file",
		"追加内容到文件(不存在则创建)。",
		{"type": "object", "properties": {
			"path": _path_arg("文件路径(res:// 或 user://)"),
			"content": {"type": "string", "description": "要追加的内容"}
		}, "required": ["path", "content"]},
		_call_append_file)

	_add_tool("delete_file",
		"删除文件或空目录。",
		{"type": "object", "properties": {
			"path": _path_arg("文件或目录路径(res:// 或 user://)")
		}, "required": ["path"]},
		_call_delete_file)

	_add_tool("file_exists",
		"检查文件或目录是否存在。",
		{"type": "object", "properties": {
			"path": _path_arg("文件或目录路径(res:// 或 user://)")
		}, "required": ["path"]},
		_call_file_exists)


## ======= MCP 协议处理 =======

func _on_request(method: String, path: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	# MCP 服务器已关闭时忽略请求（编辑器重启期间）
	if _http == null:
		return
	if method == "OPTIONS":
		_http.send_response(stream, 204, _cors_headers(headers), "")
		return
	if method != "POST":
		_http.send_response(stream, 405, {"Allow": "POST, OPTIONS", "Content-Type": "application/json"}, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Method Not Allowed\"},\"id\":null}")
		return
	# 鉴权: 可选 Bearer token(dev_framework/mcp/token, 非空时启用)
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	if not token.is_empty():
		var auth := str(headers.get("authorization", ""))
		if auth != "Bearer " + token:
			_http.send_response(stream, 401, _cors_headers(headers), JSON.stringify({"jsonrpc": "2.0", "error": {"code": - 32000, "message": "Unauthorized"}, "id": null}))
			return
	# 校验 Origin: 拦截浏览器/外部站点的跨域调用(eval_code 可执行任意代码, 防本机 RCE)。
	# 无 Origin(本地 CLI/工具)或本机 Origin 放行。
	var origin := str(headers.get("origin", "")).to_lower()
	if not origin.is_empty() and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost") or origin.begins_with("http://0.0.0.0")):
		_http.send_response(stream, 403, _cors_headers(headers), JSON.stringify({"jsonrpc": "2.0", "error": {"code": - 32000, "message": "Forbidden"}, "id": null}))
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		_http.send_response(stream, 400, {"Content-Type": "application/json"}, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}")
		return
	var req: Dictionary = parsed
	var response := await _handle_jsonrpc(req)
	# JSON-RPC 通知(无 id)按 MCP 规范回 202 空响应
	if response.is_empty():
		_http.send_response(stream, 202, {}, "")
		return
	var json := JSON.stringify(response)
	_http.send_response(stream, 200, _cors_headers(headers), json)


## CORS 响应头
func _cors_headers(headers: Dictionary) -> Dictionary:
	var h := {
		"Content-Type": "application/json",
		"Mcp-Session-Id": _make_session_id(headers),
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


func _make_session_id(headers: Dictionary) -> String:
	return headers.get("mcp-session-id", "dev-framework-default-session")


## 处理一条 JSON-RPC 请求(MCP), 返回响应字典
func _handle_jsonrpc(req: Dictionary) -> Dictionary:
	var req_id: Variant = req.get("id", null)
	if req_id == null:
		return {}

	var method: String = req.get("method", "")
	match method:
		"initialize":
			var client_info := ""
			var params0: Variant = req.get("params", {})
			if params0 is Dictionary:
				var ci: Variant = params0.get("clientInfo", null)
				if ci is Dictionary:
					client_info = "%s v%s" % [ci.get("name", "unknown"), ci.get("version", "?")]
			LogTool.log("MCP", "客户端初始化: %s (协议: %s)" % [client_info, str(req.get("params", {}).get("protocolVersion", "")) if req.get("params", {}) is Dictionary else ""])
			# 能力协商: 声明工具列表变更通知与日志能力
			return {
				"jsonrpc": "2.0",
				"id": req_id,
				"result": {
					"protocolVersion": PROTOCOL_VERSION,
					"capabilities": {
						"tools": {"listChanged": true},
						"logging": {"supportedLevels": ["debug", "info", "warning", "error"]},
					},
					"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
				},
			}
		"notifications/initialized":
			return {}
		"tools/list":
			return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": _tool_defs}}
		"tools/call":
			var params: Variant = req.get("params", {})
			var params_dict: Dictionary = params if params is Dictionary else {}
			var tool_name: String = str(params_dict.get("name", ""))
			# 参数类型防护: 客户端传非对象/非法参数时, 返回 无效参数 而非触发运行时类型错误导致无响应挂起
			var raw_args: Variant = params_dict.get("arguments", {})
			var arguments: Dictionary = raw_args if raw_args is Dictionary else {}
			if not (raw_args is Dictionary):
				return _jsonrpc_error(req_id, -32602, "Invalid params: 'arguments' must be an object: %s" % str(raw_args))
			LogTool.log("MCP", "工具调用(%s): %s, 参数: %s" % [_mode, tool_name, str(arguments)])
			if not _tool_handlers.has(tool_name):
				return _jsonrpc_error(req_id, -32602, "Unknown tool: %s" % tool_name)
			# 安全执行: 隔离 handler 运行期错误, 避免 GDScript 无 try/catch 导致协程中止、响应永不发出
			var result := await _safe_call_handler(_tool_handlers[tool_name], arguments)
			# 统一输出上限: 超限转明确错误提示, 避免巨型响应撑爆上下文/拷贝缓冲
			result = _enforce_output_cap(tool_name, result)
			if result.is_empty():
				return _jsonrpc_error(req_id, -32603, "Internal error: 工具执行未返回结果")
			# 记录返回信息到 MCP 日志, 便于诊断"返回异常/空"等问题。仅打印非原始数据
			# (get_logs / get_errors / get_game_logs / get_game_errors / 文件读写等巨量内容工具截断显示)。
			_log_tool_result(tool_name, result)
			return {"jsonrpc": "2.0", "id": req_id, "result": result}
		"ping":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		"logging/setLevel":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		_:
			return _jsonrpc_error(req_id, -32601, "Method not found: %s" % method)


func _jsonrpc_error(req_id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


## 安全执行工具 handler: 在执行前后记录/比对错误缓冲, 把运行期错误转换成结构化诊断附加到结果。
## 注意: GDScript 无 try/catch, handler 内硬错误(如类型错误)仍会使 await 协程中止——
## 但参数类型防护(见 tools/call)已消除最常见的崩溃源; 此处负责把"执行中 push_error 但没崩"的
## 可恢复错误带上诊断文本返回, 并保证返回空字典时向上层报 internal error 而非无响应。
func _safe_call_handler(handler: Callable, arguments: Dictionary) -> Dictionary:
	var err_before: int = _logger.get_error_cursor() if _logger else 0
	var result: Variant = await handler.call(arguments)
	if not (result is Dictionary):
		return {}
	if _logger and _logger.get_error_count() > err_before:
		var outcome := _collect_runtime_error(err_before)
		var base: Dictionary = result
		var new_text := str(base.get("text", "")) + "\n[警告] 执行过程中捕获运行期错误:\n%s" % outcome
		base["text"] = new_text
		# 同步更新 MCP 标准 content 数组, 保证官方 SDK 客户端也能看到诊断信息
		if base.get("content") is Array and not base["content"].is_empty() and base["content"][0] is Dictionary:
			base["content"][0]["text"] = new_text
	return result


## 读取自 err_before 起最新的运行期错误条目, 组成诊断文本
func _collect_runtime_error(err_before: int) -> String:
	if _logger == null:
		return "(无诊断数据)"
	var taken: Dictionary = _logger.take_errors_since(err_before)
	var entries: Array = taken.get("entries", [])
	if entries.is_empty():
		return "(无诊断数据)"
	var e: Dictionary = entries[entries.size() - 1]
	var msg := str(e.get("message", ""))
	var f := str(e.get("file", ""))
	var ln := str(e.get("line", ""))
	var fn := str(e.get("function", ""))
	return "%s  (%s:%s %s)" % [msg, f, ln, fn]


## 统一输出上限: 所有工具(编辑器进程与游戏进程)的返回 text 不得超过上限字符。
## 超限时不发送完整巨型 JSON, 而是返回明确错误提示(附体积与应对建议), 避免上下文/token 被撑爆。
## 上限实时读 ProjectSettings(dev_framework/mcp/max_output_chars), 改设置无需重启即生效;
## <=0 表示关闭上限。
## 注意: 游标类工具(get_logs/get_errors)超限会丢失 next, AI 应调低 max/加 since 分页重试以恢复游标。
func _enforce_output_cap(tool_name: String, result: Dictionary) -> Dictionary:
	var cap := int(ProjectSettings.get_setting(SETTING_MAX_OUTPUT_CHARS, DEFAULT_MAX_OUTPUT_CHARS))
	if cap <= 0:
		return result
	var text := str(result.get("text", ""))
	if text.length() <= cap:
		return result
	# 用字符串拼接而非 % 格式化, 避免任何格式化歧义(括号包住以保证多行续行被正确解析)
	var msg := ("工具 " + tool_name + " 返回内容超过统一输出上限(" + str(cap) + " 字符, 实际 " + str(text.length()) +
		" 字符), 为避免耗尽上下文, 未发送完整内容。\n开头预览: " + text.left(200) +
		"\n\n应对: 用更精确参数缩小范围后重试(如 get_logs/get_errors 调低 max 或传 since; read_file 先确认文件大小; classdb_query 用更具体类名; list_dir 关闭 recursive; get_scene_tree 减小 max_depth)。")
	return _err(msg, "validation", true, "按提示用更精确参数(参考各工具的 max/since/merge 等)缩小范围后重试")


## 把工具调用结果摘要记录到 MCP 日志, 便于诊断"返回异常/空"等问题。
## 巨型内容工具(get_logs/get_errors/get_game_logs/get_game_errors/read_file/take_screenshot 等)
## 只打印结构摘要, 避免日志被撑爆。
func _log_tool_result(tool_name: String, result: Dictionary) -> void:
	var text: String = str(result.get("text", ""))
	var is_err: bool = result.get("is_error", false)
	var head := "[%s] %s 返回: " % [_mode, tool_name]
	var big := tool_name in ["get_logs", "get_errors", "get_game_logs", "get_game_errors",
			"read_file", "take_screenshot", "get_scene_tree", "get_global_classes",
			"classdb_query", "get_node_info", "get_project_info", "get_project_settings",
			"get_editor_activity", "list_dir", "get_project_setting"]
	if is_err:
		LogTool.log("MCP", "%s错误: %s" % [head, text.left(400)])
		return
	if big:
		# 只打顶层结构(键/计数), 不打全文
		var summary := ""
		var t := text.strip_edges()
		if t.begins_with("{") or t.begins_with("["):
			var parsed: Variant = JSON.parse_string(t)
			if parsed is Dictionary:
				for key in parsed.keys():
					var v = parsed[key]
					var vdesc: String = str(v)
					if v is Array:
						vdesc = "Array[%d]" % v.size()
					elif v is Dictionary:
						vdesc = "Dict{%d}" % v.size()
					summary += "%s=%s " % [key, vdesc]
		if summary.is_empty():
			summary = t.left(200)
		LogTool.log("MCP", "%s%s" % [head, summary])
	else:
		LogTool.log("MCP", "%s%s" % [head, text.left(400)])


## 统一工具结果封装
## 同时输出 MCP 标准字段(content 数组 + 驼峰 isError)与自定义字段(text/is_error),
## 兼容官方 SDK 客户端(读 content/isError)与旧式客户端/内部逻辑(读 text/is_error)。
## extra 用于追加结构化字段(structuredContent / error_category 等)。
func _wrap(text: String, is_error: bool, extra: Dictionary = {}) -> Dictionary:
	var out := {
		"text": text,
		"is_error": is_error,
		"isError": is_error,
		"content": [ {"type": "text", "text": text}],
	}
	for key in extra:
		out[key] = extra[key]
	return out


func _ok(text: String) -> Dictionary:
	return _wrap(text, false)


func _fail(text: String) -> Dictionary:
	return _wrap(text, true)


## 结构化结果封装: 数据同时以 MCP 标准 structuredContent(2025-06-18+) 与
## content[].text(序列化 JSON, 向后兼容) 输出, 兼容最新官方 SDK 与旧式客户端。
## 注意: 数据先经 JSON 往返(serialize→parse), 把 NodePath/Vector2/Color 等 Variant
## 转成 JSON 兼容类型, 保证 structuredContent 是纯 JSON 对象(官方 SDK 客户端可安全解析)。
func _ok_json(data: Dictionary) -> Dictionary:
	var json := JSON.stringify(data)
	var safe_data: Variant = JSON.parse_string(json)
	if not safe_data is Dictionary:
		safe_data = data
	return _wrap(json, false, {"structuredContent": safe_data})


## 结构化错误封装(MCP 工具执行错误)。category 语义:
##   validation  - 输入/代码问题, 修正后重试即可(同参数重试永远失败)
##   transient   - 暂时性故障(超时/未就绪), 等待后重试可能成功
##   game_stopped- 游戏进程已结束/崩溃, 必须 run_game 重启后才能继续
##   internal    - 服务器内部错误, 不应重试同参数
## retryable=true 表示"等待/修正后重试有机会成功"。
func _err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	return _wrap(text, true, {
		"error_category": category,
		"is_retryable": retryable,
		"recovery": recovery,
	})


## 辅助函数：将 Variant 转换为 bool（支持 bool、String("true"/"True")、数字等）
func _to_bool(value: Variant) -> bool:
	if value is bool:
		return value
	if value is String:
		return value.to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return false


## ======= 工具 Callable 实现 =======

func _call_validate_script(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var code: String = str(args.get("code", ""))
	if path.is_empty() and code.is_empty():
		return _fail("必须提供 path 或 code 之一")
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			return _fail("脚本文件不存在: %s" % path)
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return _fail("无法读取脚本文件: %s" % path)
		code = file.get_as_text()
		file.close()
	var script := _make_tmp_script(code)
	var outcome := _compile_and_collect(script)
	# 剔除误报: GDScript.new() 临时脚本默认无路径, 引擎会因 class_name 已全局注册
	# 且注册路径 != 本脚本路径而报 "hides a global class"——当验证对象正是该 class_name
	# 的注册文件本身(或其修改版本)时, 此冲突并非真实语法错误, 应剔除后再判定有效性。
	outcome.real_errors = _filter_class_conflicts(outcome.real_errors, path, code)
	if outcome.real_errors.is_empty():
		return _ok_json({
			"valid": true,
			"message": "脚本语法有效" + ("(含 %d 条可忽略警告)" % outcome.warnings.size() if outcome.warnings.size() > 0 else ""),
			"error_latin": 0,
			"error_text": "",
			"warnings": outcome.warnings,
		})
	var text := "; ".join(outcome.real_errors)
	return _ok_json({
		"valid": false,
		"message": "解析失败: %s" % text,
		"error_line": 0,
		"error_text": text,
		"errors": outcome.real_errors,
		"warnings": outcome.warnings,
	})


## 构造一个用于预编译的临时 GDScript(无资源路径, 不触碰 Resource 缓存)。
func _make_tmp_script(code: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = code
	return script


## 编译临时脚本并收集时的新增错误/警告。返回 {"real_errors", "warnings"}。
func _compile_and_collect(script: GDScript) -> Dictionary:
	var n0: int = _logger.get_error_cursor() if _logger else 0
	script.reload()
	var new_errs: Array = []
	if _logger:
		new_errs = _logger.take_errors_since(n0).entries
	var real: Array = []
	var warns: Array = []
	for e in new_errs:
		var msg: String = str(e.get("message", ""))
		if msg.contains("Warning treated as error") or msg.contains("inferred from a Variant"):
			warns.append(msg)
		else:
			real.append(msg)
	return {"real_errors": real, "warnings": warns}


## 逐个过滤 class 冲突: 保留真实冲突, 剔除"验证该 class_name 注册文件本身"造成的误报。
func _filter_class_conflicts(errors: Array, path: String, code: String) -> Array:
	var kept: Array = []
	for e in errors:
		var msg := str(e)
		if msg.contains("hides a global script class"):
			var cls := _class_from_conflict(msg)
			if not _is_class_conflict_false_positive(cls, path, code):
				kept.append(e)
		else:
			kept.append(e)
	return kept


## 从冲突错误文本解析出冲突的 class_name(形如 "Class \"Foo\" hides a global class.")。
func _class_from_conflict(msg: String) -> String:
	var start := msg.find("\"")
	if start < 0:
		return ""
	var end := msg.find("\"", start + 1)
	if end < 0:
		return ""
	return msg.substr(start + 1, end - start - 1)


## 判定一条 class 冲突是否为误报:
## - 冲突的 class_name 尚未全局注册        → 缓存滞后, 误报
## - 注册路径 == 本次被验证 path            → 验证注册文件自身, 误报
## - 无 path 但 code 声明了同名 class_name  → 新定义源, 误报
## - 解析不出 class_name                    → 无法判断, 保守不判误报(可能真是语法错误)
func _is_class_conflict_false_positive(cls: String, path: String, code: String) -> bool:
	if cls.is_empty():
		return false
	var reg := _global_class_path(cls)
	if reg.is_empty():
		return true
	if not path.is_empty() and _same_path(reg, path):
		return true
	if path.is_empty() and _extract_class_name(code) == cls:
		return true
	return false


## 查询一个 class_name 在全局类缓存中的注册路径(res://…); 未注册返回 ""。
func _global_class_path(target_class: String) -> String:
	var classes: Array = ProjectSettings.get_setting("_global_script_classes", [])
	for c in classes:
		if c is Dictionary and str(c.get("class", "")) == target_class:
			return str(c.get("path", ""))
	return ""


## 简化路径比较(处理分隔符/大小写, 避免 Windows 盘符差异导致误判)。
func _same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").to_lower() == b.replace("\\", "/").to_lower()


## 扫描脚本头部(class_name 仅允许在 extends 之前), 返回声明的类名; 未声明返回 ""。
func _extract_class_name(code: String) -> String:
	for line in code.split("\n"):
		var t := line.strip_edges()
		if t.is_empty() or t.begins_with("#") or t.begins_with("@"):
			continue
		if t.begins_with("class_name "):
			return t.trim_prefix("class_name ").split(" ")[0].replace("\t", "").strip_edges()
		if not t.begins_with("extends"):
			break
	return ""


func _call_validate_resource(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		return _fail("资源加载失败: %s" % path)
	return _ok_json({
		"valid": true,
		"type": res.get_class(),
		"message": "资源可正常加载",
	})


## 查询 Godot 类的 API(方法/属性/信号)。用于 AI 写脚本前确认原生 API 用法。
func _call_classdb_query(args: Dictionary) -> Dictionary:
	var query_class: String = str(args.get("class_name", ""))
	var search: String = str(args.get("search", ""))
	var want_methods: bool = args.get("methods", true)
	var want_props: bool = args.get("properties", true)
	var want_signals: bool = args.get("signals", true)

	# 模糊搜索类名
	if search != "":
		var matches: Array = []
		var all_classes := ClassDB.get_class_list()
		for c in all_classes:
			if str(c).to_lower().contains(search.to_lower()):
				matches.append(c)
		matches.sort()
		if matches.size() > 50:
			matches = matches.slice(0, 50)
		return _ok_json({"mode": "search", "query": search, "match_count": matches.size(), "classes": matches})

	if query_class == "":
		return _fail("必须提供 class_name 或 search")
	if not ClassDB.class_exists(query_class):
		return _fail("类不存在: %s(请用 search 模糊搜索)" % query_class)

	var out := {"class_name": query_class, "inherits": _class_inheritance_chain(query_class)}
	if want_methods:
		var methods: Array = []
		for m in ClassDB.class_get_method_list(query_class, true):
			var arg_sig := ""
			var arg_names: Array = m.get("args", [])
			if arg_names.size() > 0:
				var parts := PackedStringArray()
				for a in arg_names:
					parts.append("%s:%s" % [a.get("name", "?"), a.get("type", "?")])
				arg_sig = "(" + ", ".join(parts) + ")"
			else:
				arg_sig = "()"
			var ret: int = int(m.get("return", {}).get("type", 0)) if m.get("return", {}) is Dictionary else 0
			methods.append("%s%s -> %s" % [m.get("name", "?"), arg_sig, _type_name(ret)])
		out["methods"] = methods
	if want_props:
		var props: Array = []
		for p in ClassDB.class_get_property_list(query_class, true):
			props.append("%s : %s" % [p.get("name", "?"), _type_name(int(p.get("type", 0)))])
		out["properties"] = props
	if want_signals:
		var signals: Array = []
		var sigs: Array = _instance_signal_list(query_class)
		for s in sigs:
			var arg_sig := ""
			var arg_names: Array = s.get("args", [])
			if arg_names.size() > 0:
				var parts := PackedStringArray()
				for a in arg_names:
					parts.append("%s:%s" % [a.get("name", "?"), a.get("type", "?")])
				arg_sig = "(" + ", ".join(parts) + ")"
			else:
				arg_sig = "()"
			signals.append("%s%s" % [s.get("name", "?"), arg_sig])
		out["signals"] = signals
	return _ok_json(out)


## 获取类的信号列表: ClassDB.class_get_signal_list 对内置类返回空,
## 改为实例化后调 get_signal_list()(实例仅用于读 API, 无需入树)。
func _instance_signal_list(cname: String) -> Array:
	if not ClassDB.can_instantiate(cname):
		return []
	var inst := ClassDB.instantiate(cname)
	if inst == null:
		return []
	var sigs: Array = inst.get_signal_list()
	inst.free()
	return sigs


## 返回类的继承链(从基类到最终祖先)
func _class_inheritance_chain(cname: String) -> Array:
	var chain: Array = []
	var cur := cname
	while cur != "" and ClassDB.class_exists(cur):
		chain.append(cur)
		cur = ClassDB.get_parent_class(cur)
	return chain


## 将 Godot 类型枚举值转为可读类型名
func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_NIL: return "null"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_OBJECT: return "Object"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		_:
			if type_id >= TYPE_OBJECT:
				return "Object/%s" % type_id
			return "type_%d" % type_id
func _call_list_dir(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "res://"))
	var recursive: bool = _to_bool(args.get("recursive", false))
	if not path.ends_with("/"):
		path += "/"
	var dir := DirAccess.open(path)
	if dir == null:
		return _fail("无法打开目录: %s" % path)
	var dirs: Array = []
	var files: Array = []
	if recursive:
		_collect_dir(path, dirs, files)
	else:
		dir.list_dir_begin()
		var f := dir.get_next()
		while not f.is_empty():
			if dir.current_is_dir() and f != "." and f != "..":
				dirs.append(f)
			elif not dir.current_is_dir():
				files.append(f)
			f = dir.get_next()
		dir.list_dir_end()
	return _ok_json({"path": path, "dirs": dirs, "files": files})


## 递归收集目录内容(供 list_dir 使用)
func _collect_dir(base: String, dirs: Array, files: Array) -> void:
	var d := DirAccess.open(base)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while not f.is_empty():
		if d.current_is_dir() and f != "." and f != "..":
			dirs.append(base + f + "/")
			_collect_dir(base + f + "/", dirs, files)
		elif not d.current_is_dir():
			files.append(base + f)
		f = d.get_next()
	d.list_dir_end()


func _call_get_logs(args: Dictionary) -> Dictionary:
	return await _call_collect_logs(args, false)


func _call_get_errors(args: Dictionary) -> Dictionary:
	return await _call_collect_logs(args, true)


## 编辑器模式且游戏调试线活跃(编辑器进程指向游戏进程的数据/操作要走代理)
func _has_game_session() -> bool:
	return _mode == MODE_EDITOR and debugger_plugin != null and debugger_plugin.has_active_session()


## 统一收集日志/错误: is_errors=true 取错误, false 取日志
func _call_collect_logs(args: Dictionary, is_errors: bool) -> Dictionary:
	var tool_name := "get_game_errors" if is_errors else "get_game_logs"
	# 编辑器模式且游戏调试线活跃: 真正取游戏进程的日志/错误。
	if _has_game_session():
		return await _call_runtime_proxy(tool_name, args)
	if _logger == null:
		return _fail("错误捕获器未就绪" if is_errors else "日志捕获器未就绪")
	var max: int = int(args.get("max", 100 if is_errors else 200))
	# since: 上次拉取返回的 next 游标, 增量拉取新条目以节省上下文(token)。默认 0 = 全量。
	var since: int = int(args.get("since", 0))
	# merge: 连续重复的同内容条目合并为一条(repeat 计数), 减少 token。默认 true。
	var merge: bool = args.get("merge", true)
	var result: Dictionary = _logger.take_errors_since(since) if is_errors else _logger.take_logs_since(since)
	var clean: Array = []
	for e in result.entries:
		var c: Dictionary = e.duplicate(is_errors)
		if c.has("message"):
			c.message = _logger.sanitize(str(c.message))
		clean.append(c)
	var merged: Array = _logger.merge_duplicates(clean) if merge else clean
	var start := maxi(0, merged.size() - max)
	var out: Array = merged.slice(start)
	var type_word := "错误" if is_errors else "日志"
	var hint := "将 next 作为下次调用的 since 参数即可只取新增%s。连续重复的同位置%s已合并为一条并带 repeat 计数, 可用 merge=false 关闭合并。" % [type_word, type_word]
	var payload := {
		"count": out.size(),
		"next": int(result.get("next", 0)),
		"total_raw": clean.size(),
		"hint": hint,
	}
	if is_errors:
		payload["errors"] = out
		payload["cleared"] = bool(result.get("cleared", false))
	else:
		payload["logs"] = out
	return _ok_json(payload)


func _call_clear_errors(_args: Dictionary) -> Dictionary:
	# 编辑器模式且游戏调试线活跃: 清游戏错误(与 _call_get_errors 的"游戏优先"一致)。
	if _has_game_session():
		return await _call_runtime_proxy("clear_game_errors", _args)
	if _logger:
		_logger.clear_errors()
	return _ok("已清空错误缓冲区")


func _call_take_screenshot(args: Dictionary) -> Dictionary:
	# text(文本化截图) 与 game(真实截图) 都分析游戏运行画面: 编辑器模式经调试线转发到游戏进程
	var capture_type: String = str(args.get("capture_type", "text"))
	if capture_type == "text" or capture_type == "game":
		if _mode == MODE_EDITOR:
			return await _call_runtime_proxy("take_screenshot", args)
		# 运行时模式: 直接处理
		return await _runtime_take_screenshot(args)

	var filename := "mcp_%s" % Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	# 清理文件名中的非法字符(Windows 不支持 : / \ * ? " < > |)
	filename = filename.replace("/", "_").replace("\\", "_").replace("*", "_").replace("?", "_") \
		.replace("\"", "_").replace("<", "_").replace(">", "_").replace("|", "_")
	if not filename.ends_with(".png"):
		filename += ".png"
	# 保存到 .godot 目录下，不会被 Godot 扫描为资源，也不会被版本控制
	var dir_path := "res://.godot/mcp_screenshots"
	var dir := DirAccess.open("res://")
	if dir:
		dir.make_dir_recursive(".godot/mcp_screenshots")
	var img: Image = null
	match capture_type:
		"scene":
			img = await _capture_scene_thumbnail(args)
			if img == null or img.is_empty():
				return _fail("场景缩略图生成失败: 无法渲染场景或场景为空")
		_: # "editor"
			img = await _capture_editor_viewport()
			if img == null or img.is_empty():
				return _fail("截图失败: 编辑器视口纹理为空")
	# 缺省降采样到 1280 宽以控制截图体积(大视口/高分屏尤其明显), 传更大的 max_width 可保留更高分辨率。
	var max_width := int(args.get("max_width", 1280))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	var img_err := img.save_png(path)
	if img_err != OK:
		return _fail("保存截图失败: 错误码 %d" % img_err)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	return _ok_json({
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": bytes.size() if bytes else 0,
		"capture_type": capture_type,
	})


## 捕获编辑器视口截图
func _capture_editor_viewport() -> Image:
	if not Engine.is_editor_hint():
		return null
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return null
	var viewport := base.get_viewport()
	var tree := base.get_tree()
	if viewport == null or tree == null:
		return null
	await _wait_frames(tree, 3, 2500)
	# 编辑器进程的 RenderingServer.frame_post_draw 不一定按时触发(与游戏的标准帧循环不同),
	# 等待其会永久挂起。编辑器主循环由 process_frame 驱动, 等帧后直接读纹理即可。
	# 也不要调用 RenderingServer.force_draw(): 在线程化渲染下同步阻塞可能卡住编辑器。
	return viewport.get_texture().get_image()


## 生成当前编辑场景的缩略图
func _capture_scene_thumbnail(_args: Dictionary) -> Image:
	if not Engine.is_editor_hint():
		return null
	var thumbnail_size := 256
	var root := _edited_root()
	if root == null:
		return null
	var scene_path := root.get_scene_file_path()
	if scene_path.is_empty():
		return null
	if not ResourceLoader.exists(scene_path):
		return null
	var scene_res: Resource = ResourceLoader.load(scene_path)
	if not scene_res is PackedScene:
		return null
	var scene_instance: Node = scene_res.instantiate()
	if scene_instance == null:
		return null
	var viewport := SubViewport.new()
	viewport.size = Vector2i(thumbnail_size, thumbnail_size)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.add_child(scene_instance)
	scene_instance.owner = viewport
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		viewport.queue_free()
		return null
	var tree := base.get_tree()
	if tree == null:
		viewport.queue_free()
		return null
	tree.root.add_child(viewport)
	await _wait_frames(tree, 5, 3000)
	var img: Image = viewport.get_texture().get_image()
	viewport.queue_free()
	return img


## 等待若干帧, 带超时上限(毫秒, 0 表示不限)
func _wait_frames(tree: SceneTree, frames: int, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	for i in frames:
		if timeout_msec > 0 and Time.get_ticks_msec() > deadline:
			break
		await tree.process_frame


func _call_get_scene_tree(args: Dictionary) -> Dictionary:
	var max_depth: int = int(args.get("max_depth", 8))
	var include_props: bool = _to_bool(args.get("include_properties", false))
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var lines: Array = []
	_walk_scene_tree(root, 0, max_depth, include_props, lines)
	return _ok("\n".join(lines))


## 递归展开场景树(供 get_scene_tree 使用)
func _walk_scene_tree(node: Node, depth: int, max_depth: int, include_props: bool, lines: Array) -> void:
	if depth > max_depth:
		return
	var indent := "  ".repeat(depth)
	lines.append("%s%s [%s]" % [indent, node.name, node.get_class()])
	if include_props and depth < 3:
		var props := _collect_essential_props(node)
		if not props.is_empty():
			lines.append("%s    props: %s" % [indent, JSON.stringify(props)])
	for child in node.get_children():
		_walk_scene_tree(child, depth + 1, max_depth, include_props, lines)


func _call_get_node_info(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	var info := {
		"name": node.name,
		"class": node.get_class(),
		"path": node.get_path(),
		"properties": _collect_essential_props(node),
	}
	return _ok_json(info)


## 提取对 AI 调试最有用的核心属性
func _collect_essential_props(node: Node) -> Dictionary:
	var out := {}
	for p in node.get_property_list():
		var pname: String = str(p.name)
		if pname.begins_with("theme_override") or pname.begins_with("accessibility_") \
				or pname.begins_with("focus_") or pname == "editor_description" or pname == "script":
			continue
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE or pname in CORE_PROP_NAMES:
			var v: Variant = node.get(pname)
			if v != null and not (v is Object or v is Resource):
				out[pname] = v
	return out


func _call_set_node_property(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var property: String = str(args.get("property", ""))
	var value: Variant = args.get("value", null)
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	var current: Variant = node.get(property)
	if current == null and not node.has_method(property):
		return _fail("节点 %s 没有属性: %s" % [path, property])
	var typed: Variant = _auto_convert_arg(value)
	if typed is String and current != null:
		typed = _coerce_value(value, typeof(current))
	if typed == null and value != null:
		return _fail("无法转换值 %s 为属性类型" % str(value))
	# 经 UndoRedo 提交, 使 AI 的修改可用 Ctrl+Z 撤销(Ctrl+Z 作用于当前编辑场景)
	var undo := _editor_undo_redo()
	if undo:
		undo.create_action("MCP: set %s.%s" % [node.name, property])
		undo.add_do_property(node, property, typed)
		undo.add_undo_property(node, property, current)
		undo.commit_action()
	else:
		node.set(property, typed)
	return _ok("已设置 %s.%s = %s" % [path, property, str(node.get(property))])


func _call_call_node_method(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var method: String = str(args.get("method", ""))
	var args_arr: Array = args.get("args", [])
	var node := _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	if not node.has_method(method):
		return _fail("节点 %s 没有方法: %s" % [path, method])
	var converted_args: Array = []
	for arg in args_arr:
		converted_args.append(_auto_convert_arg(arg))
	var result: Variant = node.callv(method, converted_args)
	return _ok("已调用 %s.%s() -> %s" % [path, method, str(result)])


func _call_add_node(args: Dictionary) -> Dictionary:
	var parent_path := str(args.get("parent", ""))
	var node_type := str(args.get("node_type", ""))
	var new_name := str(args.get("name", ""))
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var parent := root
	if not parent_path.is_empty():
		parent = _resolve_node(parent_path)
		if parent == null:
			return _fail("找不到父节点: %s" % parent_path)
	var new_node: Node
	if node_type.begins_with("res://"):
		if not ResourceLoader.exists(node_type):
			return _fail("子场景不存在: %s" % node_type)
		var packed: PackedScene = ResourceLoader.load(node_type)
		if packed == null:
			return _fail("子场景加载失败: %s" % node_type)
		new_node = packed.instantiate()
	else:
		if not ClassDB.class_exists(node_type):
			return _fail("未知节点类型: %s" % node_type)
		new_node = ClassDB.instantiate(node_type)
		if new_node == null:
			return _fail("无法实例化节点类型: %s" % node_type)
	if not new_name.is_empty():
		new_node.name = new_name
	var owner_root: Node = root
	var undo := _editor_undo_redo()
	if undo and is_inside_tree():
		# 经 UndoRedo 提交, 使 AI 新增节点可用 Ctrl+Z 移除。
		# do/undo 回调挂在 parent 场景节点上, 让 action 进场景历史(而非全局历史)。
		undo.create_action("MCP: add %s" % new_node.name)
		undo.add_do_method(parent, "add_child", new_node, true)
		undo.add_undo_method(parent, "remove_child", new_node)
		undo.add_do_property(new_node, "owner", owner_root)
		undo.add_undo_property(new_node, "owner", null)
		undo.commit_action()
	else:
		parent.add_child(new_node, true)
		_assign_owner_recursive(new_node, owner_root)
	return _ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])


## 递归把节点及其子树 owner 设为场景根, 保证新增节点可随场景保存
func _assign_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owner_recursive(child, root)


## 删除节点(含子树)
func _call_remove_node(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var root: Node = _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	if node == root:
		return _fail("不能删除场景根节点")
	var parent: Node = node.get_parent()
	if parent == null:
		return _fail("节点没有父节点: %s" % path)
	# 直接删除: 节点删除的 UndoRedo 会保留已删节点引用, 保存场景时触发
	# "No path can be resolved ... not inside tree" 警告(Godot 已知问题)。
	# 为干净起见, remove 不做 undo(删除操作本身幂等, 风险低)。
	parent.remove_child(node)
	node.owner = null
	node.queue_free()
	return _ok("已删除节点 %s" % node.name)


## 复制节点(含子树)为兄弟
func _call_duplicate_node(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var new_name := str(args.get("new_name", ""))
	var root: Node = _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	var dup: Node = node.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS)
	if dup == null:
		return _fail("节点复制失败: %s" % path)
	if new_name.is_empty():
		new_name = node.name + "_copy"
	dup.name = new_name
	var parent: Node = node.get_parent()
	if parent == null:
		return _fail("节点没有父节点: %s" % path)
	var owner_root: Node = root
	var undo: EditorUndoRedoManager = _editor_undo_redo()
	if undo and is_inside_tree():
		undo.create_action("MCP: duplicate %s" % new_name)
		undo.add_do_method(parent, "add_child", dup, true)
		undo.add_undo_method(parent, "remove_child", dup)
		undo.add_do_property(dup, "owner", owner_root)
		undo.add_undo_property(dup, "owner", null)
		undo.commit_action()
	else:
		parent.add_child(dup, true)
		_assign_owner_recursive(dup, owner_root)
	return _ok("已复制节点 %s → %s" % [node.name, dup.name])


## 设置节点位置/旋转/缩放(2D/3D)
func _call_set_node_transform(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var property := str(args.get("property", ""))
	var value: Variant = args.get("value", null)
	var root: Node = _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("找不到节点: %s" % path)
	if not node is Node2D and not node is Node3D:
		return _fail("仅支持 Node2D/Node3D 节点(当前 %s)" % node.get_class())
	var converted: Variant = _auto_convert_arg(value)
	if not node.has_method("set"):
		return _fail("节点不可写属性: %s" % path)
	var undo: EditorUndoRedoManager = _editor_undo_redo()
	if undo and is_inside_tree():
		var old: Variant = node.get(property)
		undo.create_action("MCP: set %s.%s" % [node.name, property])
		undo.add_do_property(node, property, converted)
		undo.add_undo_property(node, property, old)
		undo.commit_action()
	else:
		node.set(property, converted)
	return _ok("已设置 %s.%s = %s" % [node.name, property, str(converted)])


## 连接信号到方法
func _call_connect_signal(args: Dictionary) -> Dictionary:
	var source_path := str(args.get("source_path", ""))
	var signal_name := str(args.get("signal", ""))
	var method := str(args.get("method", ""))
	var target_path := str(args.get("target_path", ""))
	var root: Node = _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var source: Node = _resolve_node(source_path)
	if source == null:
		return _fail("找不到源节点: %s" % source_path)
	if not source.has_signal(signal_name):
		return _fail("节点 %s 没有信号 %s" % [source.name, signal_name])
	var target: Node = source
	if not target_path.is_empty():
		target = _resolve_node(target_path)
		if target == null:
			return _fail("找不到目标节点: %s" % target_path)
	if not target.has_method(method):
		return _fail("目标节点 %s 没有方法 %s" % [target.name, method])
	# 场景内连接的信号, 随场景保存
	var undo: EditorUndoRedoManager = _editor_undo_redo()
	if undo and is_inside_tree():
		undo.create_action("MCP: connect %s.%s -> %s.%s" % [source.name, signal_name, target.name, method])
		undo.add_do_method(source, "connect", signal_name, Callable(target, method))
		undo.add_undo_method(source, "disconnect", signal_name, Callable(target, method))
		undo.commit_action()
	else:
		source.connect(signal_name, Callable(target, method))
	return _ok("已连接 %s.%s → %s.%s" % [source.name, signal_name, target.name, method])


func _call_save_scene(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var root := _edited_root()
	if root == null:
		return _fail("当前没有打开的场景")
	var err := EditorInterface.save_scene()
	if err != OK:
		return _fail("保存场景失败(错误码 %d)" % err)
	return _ok("已保存场景 %s" % root.get_scene_file_path())


func _call_get_project_info(_args: Dictionary) -> Dictionary:
	var session_active: bool = _has_game_session()
	var info := {
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"godot_version": Engine.get_version_info(),
		"editor": Engine.is_editor_hint(),
		"debug_build": OS.is_debug_build(),
		"current_scene": _edited_root().get_scene_file_path() if _edited_root() else null,
		"mode": _mode,
		"mcp_port": _port,
		"mcp_running": is_running(),
		"game_running": session_active,
		"bridge_ready": session_active and _game_ready,
		"session_active": session_active,
	}
	return _ok_json(info)


## 感知编辑器当前状态(用于 AI 与人类协作): 打开场景/选中节点/运行状态等
func _call_get_editor_activity(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var out := {
		"mode": "editor",
		"game_running": _has_game_session(),
		"bridge_ready": debugger_plugin != null and _game_ready,
	}
	# 打开的场景与选中节点
	var root := _edited_root()
	if root:
		out["open_scene"] = root.get_scene_file_path()
		out["scene_name"] = str(root.name)
	var selection := EditorInterface.get_selection()
	if selection != null:
		var selected: Array[Node] = []
		for n in selection.get_selected_nodes():
			selected.append(n)
		out["selected_nodes"] = selected.map(func(n: Node): return str(n.get_path()))
	out["mcp_running"] = is_running()
	return _ok_json(out)


func _call_get_project_settings(_args: Dictionary) -> Dictionary:
	var root := _edited_root()
	var info := {
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"autoloads": _autoloads(),
		"input_actions": _input_actions(),
		"layers_2d": _named_layers("layer_names/2d_physics"),
		"layers_2d_render": _named_layers("layer_names/2d_render"),
		"layers_3d": _named_layers("layer_names/3d_physics"),
		"layers_3d_render": _named_layers("layer_names/3d_render"),
		"current_scene": root.get_scene_file_path() if root else null,
	}
	return _ok_json(info)


## 收集 autoload 单例(名字 -> 路径)
func _autoloads() -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("autoload/") and name.count("/") == 1:
			var keyname := name.trim_prefix("autoload/")
			var val = ProjectSettings.get_setting(name)
			if val is String and not (val.begins_with("*") or val.begins_with("&")):
				out[keyname] = val
	return out


## 收集输入映射动作名
func _input_actions() -> Array:
	var out := []
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("input/"):
			out.append(name.trim_prefix("input/"))
	return out


## 读取图层命名
func _named_layers(setting_key: String) -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with(setting_key + "/"):
			var idx := name.trim_prefix(setting_key + "/")
			out[int(idx)] = ProjectSettings.get_setting(name)
	return out


func _call_run_game(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可运行游戏")
	if _has_game_session():
		return _fail("游戏已在运行(活跃调试会话)。如需重启请先 stop_game。")
	var scene := str(args.get("scene", ""))
	if scene.is_empty():
		# 未指定时用主场景
		scene = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		if scene.is_empty():
			return _fail("必须提供 scene(要运行的场景 res:// 路径), 例如 res://Scenes/Main/Main.tscn")
	if not scene.begins_with("res://"):
		scene = "res://" + scene
	if not ResourceLoader.exists(scene):
		return _fail("启动场景不存在: %s" % scene)
	var scene_res: Resource = ResourceLoader.load(scene)
	if not scene_res is PackedScene:
		return _fail("不是有效场景文件: %s(类型: %s)" % [scene, scene_res.get_class() if scene_res else "null"])
	# 以调试模式启动(等效编辑器 F5): 编辑器自动建立 EngineDebugger 调试线,
	# 游戏进程内的 autoload 注册消息捕获器并回发 ready, 之后运行时工具经调试线可用。
	EditorInterface.play_custom_scene(scene)
	var ready := await _wait_game_ready(15.0)
	if not ready:
		return _ok("已启动游戏(场景=%s), 但调试线 %d 秒内未就绪, 稍后重试运行时工具。" % [scene, int(15.0)])
	return _ok("已启动游戏(调试模式, 场景=%s), 运行时工具已就绪。" % scene)


func _call_stop_game(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可停止游戏")
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		return _fail("当前没有运行中的游戏")
	EditorInterface.stop_playing_scene()
	_game_ready = false
	return _ok("已停止游戏")


## 编辑器侧: 自动验证闭环。启动场景 → 清错误缓冲 → 代理到游戏进程执行操作序列 → 停止。
## retries>0 时失败自动重跑(每轮独立重启场景, 排除 flaky/时序性失败), 返回含重试历史。
func _call_auto_verify(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var scene := str(args.get("scene", ""))
	if _has_game_session():
		return _fail("游戏已在运行。auto_verify 会自行启动/停止场景, 请先 stop_game 或直接传 scene 参数。")
	var retries := int(args.get("retries", 0))
	var backoff_ms := int(args.get("retry_backoff_ms", 500))
	# 可选: 调用方提供的上次依赖快照({path: mtime}), 用于检测本次执行前代码是否变化
	var prev_snapshot: Dictionary = args.get("prev_snapshot", {}) if args.get("prev_snapshot") is Dictionary else {}
	var history: Array = []
	var attempts := 0
	while true:
		attempts += 1
		var result: Dictionary = await _run_auto_verify_once(scene, args)
		# 单轮执行硬错误(启动失败/清错失败等)直接返回
		if result.get("is_error", false):
			return result
		var sc: Variant = result.get("structuredContent", null)
		var verdict := "pass"
		if sc is Dictionary:
			verdict = str(sc.get("verdict", "pass"))
		# 记录本轮摘要(错误数/首个出错步, 供 retry 历史诊断)
		var summary := {
			"attempt": attempts,
			"verdict": verdict,
			"error_count": int(sc.get("error_count", 0)) if sc is Dictionary else 0,
			"first_error_step": int(sc.get("first_error_step", -1)) if sc is Dictionary else -1,
		}
		history.append(summary)
		# 通过或重试次数用完 → 收尾返回
		if verdict == "pass" or attempts > retries:
			if verdict == "pass":
				# 曾失败但最终通过 = flaky: 附 was_flaky 标记 + 完整重试历史,
				# 避免把"偶发失败"当干净通过(可能有被时序掩盖的潜在 bug)。
				var had_failure := false
				for h in history:
					if str(h.get("verdict", "")) != "pass":
						had_failure = true
						break
				if sc is Dictionary:
					sc["attempts"] = attempts
					sc["retry_history"] = history
					sc["was_flaky"] = had_failure
					_attach_code_change_info(sc, scene, prev_snapshot)
					return _ok_json(sc)
				return result
			# 全部失败: 在结果里附加重试历史
			if sc is Dictionary:
				sc["attempts"] = attempts
				sc["retry_history"] = history
				sc["was_flaky"] = false
				_attach_code_change_info(sc, scene, prev_snapshot)
				return _ok_json(sc)
			return result
		# 等待重试间隔后重跑
		if backoff_ms > 0:
			await get_tree().create_timer(backoff_ms / 1000.0).timeout
	# 不可达
	return _fail("auto_verify 内部异常")


## 在验证结果里附加依赖变化信息: 当前依赖快照 vs prev_snapshot。
## deps_changed=true 表示自上次快照以来场景依赖的脚本/资源/配置有改动。
func _attach_code_change_info(sc: Dictionary, scene: String, prev_snapshot: Dictionary) -> void:
	var current := _snapshot_deps_mtime(scene)
	sc["scene_deps"] = current
	var changed := true
	if not prev_snapshot.is_empty():
		# 新增/删除/内容变化都算变化
		changed = current.size() != prev_snapshot.size()
		if not changed:
			for path in prev_snapshot:
				if not current.has(path) or current[path] != prev_snapshot[path]:
					changed = true
					break
	sc["deps_changed"] = changed
	# 兼容旧字段名(verify_fix 旧客户端/旧会话仍读 code_changed)
	sc["code_changed"] = changed


## 有状态验证修复会话: 按 session_id 记住验证配置, AI 改完代码后 continue 即重跑。
## action: start(存配置并跑第一轮) / continue(复用配置重跑, 检测代码是否变化) /
## status(查会话, 不跑) / abort(清除会话)。
## 返回含 round/rounds_done/verdict/was_flaky/code_changed + 该轮完整结果。
func _call_verify_fix(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var action := str(args.get("action", "start")).to_lower()
	var session_id := str(args.get("session_id", "default"))
	# abort: 清除指定会话(或全部)
	if action == "abort":
		if str(args.get("all", false)) == "true":
			_verify_sessions.clear()
			return _ok_json({"action": "abort", "session_active": false, "message": "全部 verify_fix 会话已清除"})
		_verify_sessions.erase(session_id)
		return _ok_json({"action": "abort", "session_id": session_id, "session_active": false, "message": "verify_fix 会话已清除: %s" % session_id})
	# status: 只查不跑
	if action == "status":
		if _verify_sessions.is_empty():
			return _ok_json({"action": "status", "session_active": false, "session_count": 0, "message": "无活跃会话。用 action=start 创建。"})
		if str(args.get("all", false)) == "true":
			return _ok_json({"action": "status", "session_active": true, "session_count": _verify_sessions.size(), "sessions": _verify_sessions})
		if not _verify_sessions.has(session_id):
			return _ok_json({"action": "status", "session_id": session_id, "session_active": false, "message": "会话不存在: %s" % session_id})
		return _ok_json({"action": "status", "session_id": session_id, "session_active": true, "session": _verify_sessions[session_id]})
	# start / continue
	if action == "start":
		_verify_sessions[session_id] = {
			"scene": str(args.get("scene", "")),
			"operations": args.get("operations", []),
			"duration": float(args.get("duration", 4.0)),
			"retries": int(args.get("retries", 0)),
			"retry_backoff_ms": int(args.get("retry_backoff_ms", 500)),
			"stop_on_error": bool(args.get("stop_on_error", true)),
			"rounds": [],
			"deps_snapshot": {},
		}
	elif action == "continue":
		if not _verify_sessions.has(session_id):
			return _fail("无活跃 verify_fix 会话: %s。先调用 action=start 创建(传 scene+operations)。" % session_id)
	else:
		return _fail("action 无效: %s (可选: start/continue/status/abort)" % action)
	var session: Dictionary = _verify_sessions[session_id]
	if session.get("operations", []).is_empty():
		return _fail("会话缺少 operations 操作序列。start 时需提供。")
	var verify_args := {
		"scene": str(session.get("scene", "")),
		"operations": session.get("operations", []),
		"duration": float(session.get("duration", 4.0)),
		"retries": int(session.get("retries", 0)),
		"retry_backoff_ms": int(session.get("retry_backoff_ms", 500)),
		"stop_on_error": bool(session.get("stop_on_error", true)),
	}
	# 依赖变化检测由 auto_verify 统一完成: 传上次快照, 从结果读 deps_changed + 更新 scene_deps
	var prev_snapshot: Dictionary = session.get("deps_snapshot", {}) if session.get("deps_snapshot") is Dictionary else {}
	if not prev_snapshot.is_empty():
		verify_args["prev_snapshot"] = prev_snapshot
	var result: Dictionary = await _call_auto_verify(verify_args)
	# 用 auto_verify 返回的最新依赖快照更新会话(供下次 continue 比对)
	var sc: Variant = result.get("structuredContent", null)
	var deps_changed := true
	if sc is Dictionary:
		deps_changed = bool(sc.get("deps_changed", sc.get("code_changed", true)))
		if sc.has("scene_deps") and sc.get("scene_deps") is Dictionary:
			session["deps_snapshot"] = sc.get("scene_deps")
	# 记录本轮摘要到会话
	var rounds: Array = session.get("rounds", [])
	rounds.append({
		"verdict": str(sc.get("verdict", "unknown")) if sc is Dictionary else "error",
		"was_flaky": bool(sc.get("was_flaky", false)) if sc is Dictionary else false,
		"error_count": int(sc.get("error_count", 0)) if sc is Dictionary else 0,
		"first_error_step": int(sc.get("first_error_step", -1)) if sc is Dictionary else -1,
	})
	session["rounds"] = rounds
	# 构造返回: 会话摘要 + 本轮完整结果
	var round_summary := {
		"session_id": session_id,
		"round": rounds.size(),
		"rounds_done": rounds.size(),
		"verdict": str(sc.get("verdict", "error")) if sc is Dictionary else "error",
		"was_flaky": bool(sc.get("was_flaky", false)) if sc is Dictionary else false,
		"deps_changed": deps_changed,
		"code_changed": deps_changed,  # 兼容旧字段名
		"rounds": rounds,
		"session_active": true,
		"hint": "deps_changed=false 表示自上次轮次以来场景依赖的脚本/资源/配置均未变化, continue 重跑结果大概率相同; 若确实改过请确认保存并检查场景依赖。",
	}
	if sc is Dictionary:
		round_summary["steps"] = sc.get("steps", [])
		round_summary["error_count"] = sc.get("error_count", 0)
		round_summary["first_error_step"] = sc.get("first_error_step", -1)
		if sc.has("retry_history"):
			round_summary["retry_history"] = sc.get("retry_history")
	return _ok_json(round_summary)


## 收集场景依赖链的全部资源文件(递归: 场景依赖 → 资源依赖), 含脚本/配置/图片/音频/字体等。
## 排除 .godot 缓存与 .import 元数据, 只看用户资源。
func _collect_scene_deps(scene: String) -> Dictionary:
	var deps := {}
	var visited := {}
	_collect_deps_recursive(scene, deps, visited)
	return deps


func _collect_deps_recursive(path: String, deps: Dictionary, visited: Dictionary) -> void:
	if visited.has(path):
		return
	visited[path] = true
	# 排除引擎缓存/导入元数据(这些被改动不代表用户资源变化)
	if path.contains("/.godot/") or path.ends_with(".import"):
		return
	if path.ends_with(".gd") or path.ends_with(".tres") or path.ends_with(".tscn") or path.ends_with(".res") \
		or path.ends_with(".png") or path.ends_with(".jpg") or path.ends_with(".svg") or path.ends_with(".webp") \
		or path.ends_with(".wav") or path.ends_with(".ogg") or path.ends_with(".mp3") \
		or path.ends_with(".ttf") or path.ends_with(".otf") or path.ends_with(".glb") or path.ends_with(".gltf"):
		deps[path] = true
	if not ResourceLoader.exists(path):
		return
	var sub := ResourceLoader.get_dependencies(path)
	for dep in sub:
		var dep_str := String(dep)
		# 格式: path 或 uid::<空>::path
		var real := dep_str
		if dep_str.contains("::"):
			real = dep_str.get_slice("::", 2)
		if real.is_empty():
			continue
		_collect_deps_recursive(real, deps, visited)


## 快照依赖文件的修改时间(path -> mtime)。mtime 变化即认为代码/资源被改动。
func _snapshot_deps_mtime(scene: String) -> Dictionary:
	var snap := {}
	var deps := _collect_scene_deps(scene)
	for path in deps:
		if not FileAccess.file_exists(String(path)):
			continue
		snap[String(path)] = FileAccess.get_modified_time(String(path))
	return snap


## 单次验证执行: 启动场景 → 等就绪 → 清错误 → 代理执行 → 停止游戏
func _run_auto_verify_once(scene: String, args: Dictionary) -> Dictionary:
	# 1) 启动场景(缺省用主场景)
	var run_res := await _call_run_game({"scene": scene})
	if run_res.get("is_error", false):
		return run_res
	# 2) 等待调试线就绪, 清空游戏错误缓冲(保证验证期间的错误都是本次触发)
	if not await _wait_game_ready(2.0):
		await _call_stop_game({})
		return _fail("游戏启动后调试线未就绪, auto_verify 中止。已停止游戏。")
	var ok_clear := await _call_runtime_proxy("clear_game_errors", {})
	if ok_clear.get("is_error", false):
		await _call_stop_game({})
		return _fail("清空游戏错误缓冲失败: %s" % str(ok_clear.get("text", "")))
	# 3) 代理到游戏进程执行操作序列
	var result := await _call_runtime_proxy("auto_verify", args)
	# 4) 收尾: 停止游戏(无论结果如何都要停)
	await _call_stop_game({})
	if result.get("is_error", false):
		return result
	return result


## 等待游戏进程的调试线桥接就绪(session 已激活 且 收到 dev_mcp:ready), 超时返回 false
func _wait_game_ready(timeout_sec: float = 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		if _game_ready and _has_game_session():
			return true
		await get_tree().create_timer(0.1).timeout
	return false


## ======= 开发辅助工具实现 =======

func _call_reload_project(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	fs.scan_sources()
	fs.scan()
	return _ok("已触发项目重载(重建类缓存+重扫资源), 后台进行。")


func _call_eval_code(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	if code.is_empty():
		return _fail("必须提供 code")
	# 静态安全扫描(禁止逃逸 API)
	var forbidden := _eval_forbidden_scan(code)
	if forbidden != "":
		return _err(forbidden, "validation", false, "移除被禁止的 API 调用后重新调用 eval")
	# 预编译检查(语法错误在到达解释器前拦截)
	var precheck := _precheck_eval_code(code)
	if precheck != "":
		return _err(precheck, "validation", false, "修正代码语法后重新调用 eval(语法错误无法通过重试解决)")
	var script := GDScript.new()
	var body := _indent_method_body(code)
	# 包装为挂到场景树的 Node 方法, 让用户代码可直接 get_tree()/get_node() 访问当前场景
	script.source_code = "extends Node\nfunc _mcp_run():\n%s" % body
	var err := script.reload()
	if err != OK:
		var text := error_string(err)
		var hint := ""
		if text.contains("hides a global script class"):
			hint = " (class_name 与全局类冲突: 请勿在 eval_code 中声明类, 或先 reload_project)"
		return _err("代码解析失败: %s%s\n解析详情已输出到编辑器控制台, 可用 get_logs 查看。" % [text, hint],
			"validation", false, "修正代码后重新调用 eval")
	# 执行前记录错误游标, 以便捕获本次 eval 运行期错误(用逻辑游标, 环形缓冲满后仍正确)
	var err_before: int = _logger.get_error_cursor() if _logger else 0
	var inst: Node = script.new()
	if inst == null:
		return _err("无法实例化求值脚本", "internal", false, "重新调用 eval, 或检查服务器日志")
	var root := get_tree().root
	if root:
		root.add_child(inst)
	var result: Variant = inst.call("_mcp_run")
	if root:
		inst.queue_free()
	# 收集本次运行产生的运行期错误(若代码 halt, 也会反映为错误入队)
	var runtime_errors: Array = []
	if _logger:
		var taken: Dictionary = _logger.take_errors_since(err_before)
		runtime_errors = taken.get("entries", [])
	var shown := str(result)
	if result is Dictionary or result is Array:
		shown = JSON.stringify(result)
	# 运行期错误(如 get_node 访问 null 字段)应作为错误即时返回, 而非"成功+警告",
	# 否则编辑器侧只能等 20s 超时再回查错误缓冲, AI 无法及时定位。
	if not runtime_errors.is_empty():
		var msgs := PackedStringArray()
		var max_show := mini(runtime_errors.size(), 5)
		for i in range(max_show):
			var e: Dictionary = runtime_errors[i]
			msgs.append("%s@%s:%s" % [e.get("message", ""), e.get("file", "?"), e.get("line", "?")])
		return _err(
			"eval 执行返回: %s\n执行中捕获 %d 条运行期错误(前 %d 条):\n%s\n\n提示: get_node() 相对路径基于 eval 脚本实例, 找不到节点常因路径写错, 建议用绝对路径(/root/场景名/...) 或 get_tree().current_scene.get_node(...)。完整错误列表可用 get_game_errors。" %
			[shown, runtime_errors.size(), max_show, "\n".join(msgs)],
			"validation", true, "修正 eval 代码中的错误后重试")
	return _ok("执行成功, 返回: %s" % shown)


## 把用户 eval_code 规范成方法体缩进
func _indent_method_body(code: String) -> String:
	var lines := code.split("\n")
	var out := PackedStringArray()
	for line in lines:
		var norm := _normalize_indent(line, 4)
		out.append("    " + norm)
	return "\n".join(out)


func _normalize_indent(line: String, tab_w: int) -> String:
	var i := 0
	var spaces := 0
	while i < line.length():
		var c := line.unicode_at(i)
		if c == 9:
			spaces += tab_w
			i += 1
		elif c == 32:
			spaces += 1
			i += 1
		else:
			break
	var prefix := ""
	for j in spaces:
		prefix += " "
	return prefix + line.substr(i)


func _call_get_global_classes(_args: Dictionary) -> Dictionary:
	var list := ProjectSettings.get_global_class_list()
	var out: Array = []
	for c in list:
		out.append({
			"name": c.get("name", ""),
			"path": c.get("path", ""),
			"base": c.get("base", ""),
			"class": c.get("class", ""),
		})
	return _ok_json({"count": out.size(), "classes": out})


## 跨脚本与场景/资源配置搜索符号(函数/变量/类定义与引用)
func _call_search_symbols(args: Dictionary) -> Dictionary:
	var query := str(args.get("query", ""))
	var kind := str(args.get("kind", "all"))
	var search_path := str(args.get("path", ""))
	var include_resources := bool(args.get("include_resources", true))
	var max_results := int(args.get("max_results", 100))
	if query.is_empty():
		return _fail("必须提供 query")
	var base_dir := "res://"
	if not search_path.is_empty():
		if not search_path.begins_with("res://"):
			search_path = "res://" + search_path.trim_prefix("/")
		base_dir = search_path
		if not DirAccess.dir_exists_absolute(base_dir):
			return _fail("目录不存在: %s" % base_dir)
	var allowed_kinds := ["all", "function", "variable", "class", "node", "resource", "ref"]
	if kind not in allowed_kinds:
		return _fail("kind 无效: %s (可选: all/function/variable/class/node/resource/ref)" % kind)
	# query 若是资源路径/uid, 补充另一形态(uid 或 res://路径)以便双向匹配
	var needles: Array = [query]
	if query.begins_with("res://"):
		var uid := ResourceLoader.get_resource_uid(query)
		if uid >= 0:
			needles.append(ResourceUID.id_to_text(uid))
	elif query.begins_with("uid://"):
		var rpath := ResourceUID.uid_to_path(query)
		if not rpath.is_empty():
			needles.append(rpath)
	# 收集文件(仅 .gd 或含 .tscn/.tres)
	var code_files: Array = []
	var extensions := PackedStringArray([".gd"])
	if include_resources:
		extensions = PackedStringArray([".gd", ".tscn", ".tres"])
	_collect_files(base_dir, code_files, extensions)
	# 逐文件扫描
	var defs: Array = []
	var refs: Array = []
	for fpath in code_files:
		var is_scene: bool = fpath.ends_with(".tscn") or fpath.ends_with(".tres")
		var matcher := func(line: String, line_num: int) -> Variant:
			var m: Variant
			if is_scene:
				m = _match_scene_symbol(line, needles)
			else:
				m = _match_symbol(line, needles)
			if m == null:
				return null
			m["line"] = line_num
			m["text"] = line.strip_edges()
			return m
		for hit in _scan_file_lines(fpath, matcher):
			var entry := {
				"file": fpath,
				"line": hit.get("line", 0),
				"text": hit.get("text", ""),
				"type": hit.get("type", "ref"),
				"symbol": hit.get("symbol", query),
			}
			if kind != "all" and String(entry.get("type")) != kind:
				continue
			if entry.get("type") == "ref":
				if refs.size() < max_results:
					refs.append(entry)
			elif defs.size() < max_results:
				defs.append(entry)
			if defs.size() + refs.size() >= max_results * 2:
				break
		if defs.size() + refs.size() >= max_results * 2:
			break
	return _ok_json({
		"query": query,
		"definitions": defs,
		"references": refs,
		"definition_count": defs.size(),
		"reference_count": refs.size(),
		"files_scanned": code_files.size(),
	})


## 递归收集 res:// 下匹配扩展名的文件(如 .gd/.tscn/.tres)
func _collect_files(dir_path: String, out: Array, extensions: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if fname == "." or fname == "..":
			fname = dir.get_next()
			continue
		var full := dir_path.path_join(fname)
		if dir.current_is_dir():
			# 跳过隐藏/构建目录
			if not fname.begins_with(".") and fname != "build" and fname != "Native":
				_collect_files(full, out, extensions)
		elif _has_any_ext(fname, extensions):
			out.append(full)
		fname = dir.get_next()
	dir.list_dir_end()


func _has_any_ext(fname: String, extensions: PackedStringArray) -> bool:
	for ext in extensions:
		if fname.ends_with(ext):
			return true
	return false


## 逐行扫描文件, matcher(line, line_num) 返回字典即命中(含 type 等), 返回 null 跳过。收集全部命中行。
func _scan_file_lines(fpath: String, matcher: Callable) -> Array:
	var hits: Array = []
	if not FileAccess.file_exists(fpath):
		return hits
	var file := FileAccess.open(fpath, FileAccess.READ)
	if file == null:
		return hits
	var line_num := 0
	while not file.eof_reached():
		var line := file.get_line()
		line_num += 1
		var result: Variant = matcher.call(line, line_num)
		if result != null:
			hits.append(result)
	file.close()
	return hits


## 匹配一行里的符号定义或引用, needles[0] 为原始 query。返回 {type, symbol} 或 null
func _match_symbol(line: String, needles: Array) -> Variant:
	var stripped := line.strip_edges()
	if stripped.begins_with("#"):
		return null
	var query := String(needles[0])
	# 定义: func 名字(
	if RegEx.create_from_string("\\bfunc\\s+(" + _regex_escape(query) + ")\\s*\\(").search(stripped):
		return {"type": "function", "symbol": query}
	# 定义: class_name 名字 或 class 名字
	if RegEx.create_from_string("\\bclass(?:_name)?\\s+(" + _regex_escape(query) + ")\\b").search(stripped):
		return {"type": "class", "symbol": query}
	# 定义: var 名字 / @export var 名字 / const 名字
	if RegEx.create_from_string("\\b(?:var|const)\\s+(" + _regex_escape(query) + ")\\s*(?::|=)").search(stripped):
		return {"type": "variable", "symbol": query}
	# 引用: 任一 needle 命中
	for needle in needles:
		if stripped.contains(String(needle)):
			return {"type": "ref", "symbol": String(needle)}
	return null


func _regex_escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace(".", "\\.").replace("(", "\\(").replace(")", "\\)").replace("[", "\\[").replace("]", "\\]").replace("{", "\\{").replace("}", "\\}").replace("*", "\\*").replace("+", "\\+").replace("?", "\\?").replace("|", "\\|").replace("^", "\\^").replace("$", "\\$")


## 匹配 .tscn/.tres 文件行的符号定义或引用, needles[0] 为原始 query
func _match_scene_symbol(line: String, needles: Array) -> Variant:
	var stripped := line.strip_edges()
	if stripped.is_empty():
		return null
	var query := String(needles[0])
	var is_path_query := query.begins_with("res://") or query.begins_with("uid://")
	# 节点定义: [node name="查询" (仅标识符查询时)
	if not is_path_query and stripped.begins_with("[node"):
		var name_idx := stripped.find("name=\"")
		if name_idx != -1:
			var name_part := stripped.substr(name_idx + 6)
			var name_end := name_part.find("\"")
			if name_end != -1 and name_part.substr(0, name_end) == query:
				return {"type": "node", "symbol": query}
	# ext_resource / sub_resource 定义(资源/脚本关联)
	if stripped.begins_with("[ext_resource") or stripped.begins_with("[sub_resource"):
		for needle in needles:
			if stripped.contains(String(needle)):
				return {"type": "resource", "symbol": String(needle)}
	# 普通引用: 任一 needle 命中(含属性值引用, 如 script=ExtResource(...) 等)
	for needle in needles:
		if stripped.contains(String(needle)):
			return {"type": "ref", "symbol": String(needle)}
	return null


func _call_find_resource_users(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not path.begins_with("res://"):
		path = "res://" + path.trim_prefix("/")
	if not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	var include_script_refs := bool(args.get("include_script_refs", true))
	var max_results := int(args.get("max_results", 100))
	# 目标资源的 UID 与归一化路径
	var target_uid := ResourceLoader.get_resource_uid(path)
	var needles: Array = [ResourceUID.ensure_path(path)]
	if target_uid >= 0:
		needles.append(ResourceUID.id_to_text(target_uid))
	var target_res_path := String(needles[0])
	# 收集全部代码/资源配置文件
	var files: Array = []
	var extensions := PackedStringArray([".gd", ".tscn", ".tres", ".res"])
	_collect_files("res://", files, extensions)
	var users: Array = []
	var files_scanned := 0
	for fpath in files:
		if fpath == target_res_path:
			continue
		# .gd 脚本: preload/load 引用走文本匹配
		if fpath.ends_with(".gd"):
			if not include_script_refs:
				continue
			var matcher := func(line: String, _line_num: int) -> Variant:
				if line.begins_with("#"):
					return null
				for needle in needles:
					if line.contains(String(needle)):
						return {"needle": String(needle)}
				return null
			var hits := _scan_file_lines(fpath, matcher)
			if not hits.is_empty():
				var hit: Dictionary = hits[0]
				var entry := {"file": fpath, "kind": "script"}
				if hit.has("needle"):
					entry["via"] = hit["needle"]
				users.append(entry)
				if users.size() >= max_results:
					break
			continue
		# 其他资源文件: 引擎级依赖解析(准确处理 uid::path 引用)
		var deps := ResourceLoader.get_dependencies(fpath)
		files_scanned += 1
		var matched := false
		for dep in deps:
			var dep_str := String(dep)
			if dep_str.contains("::"):
				# uid::<空>::path 三段格式
				if target_uid >= 0 and dep_str.get_slice("::", 0) == str(target_uid):
					matched = true
					break
				if dep_str.get_slice("::", 2) == target_res_path:
					matched = true
					break
			elif dep_str == target_res_path:
				matched = true
				break
		if matched:
			users.append({"file": fpath, "kind": "resource"})
			if users.size() >= max_results:
				break
	var uid_text := String(needles[1]) if needles.size() > 1 else ""
	# 正向依赖链: 该资源依赖谁(场景/脚本/配置/资产), 与 users(谁引用它)互为反向
	var deps_list: Array = []
	var deps_map := _collect_scene_deps(target_res_path)
	for dpath in deps_map:
		if String(dpath) == target_res_path:
			continue
		deps_list.append({"path": String(dpath), "type": _resource_type_label(String(dpath))})
	deps_list.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.get("path", "")) < str(b.get("path", "")))
	return _ok_json({
		"target": target_res_path,
		"uid": uid_text,
		"user_count": users.size(),
		"files_scanned": files_scanned,
		"users": users,
		"dep_count": deps_list.size(),
		"deps": deps_list,
		"hint": "users=谁引用该资源(反向), deps=该资源依赖谁(正向)。改/删资源前看两边评估影响面。",
	})


## 按扩展名分类资源: script/config/scene/asset
func _resource_type_label(path: String) -> String:
	if path.ends_with(".gd"):
		return "script"
	if path.ends_with(".tscn"):
		return "scene"
	if path.ends_with(".tres") or path.ends_with(".res"):
		return "config"
	return "asset"


func _call_open_scene(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("场景不存在: %s" % path)
	EditorInterface.open_scene_from_path(path)
	return _ok("已打开场景 %s" % path)


func _call_set_main_scene(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return _fail("场景不存在: %s" % path)
	ProjectSettings.set_setting("application/run/main_scene", path)
	ProjectSettings.save()
	return _ok("已设置主场景: %s" % path)


func _call_get_project_setting(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if name.is_empty():
		return _fail("必须提供 name")
	if not ProjectSettings.has_setting(name):
		return _fail("不存在设置项: %s" % name)
	return _ok_json({"name": name, "value": ProjectSettings.get_setting(name)})


func _call_set_project_setting(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", ""))
	if name.is_empty():
		return _fail("必须提供 name")
	var value: Variant = args.get("value", null)
	ProjectSettings.set_setting(name, value)
	ProjectSettings.save()
	return _ok("已设置 %s = %s 并保存" % [name, str(value)])


func _call_save_all(_args: Dictionary) -> Dictionary:
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	var ps := ProjectSettings.save()
	return _ok("已保存全部场景, 项目设置(err=%d)" % ps)


func _call_reimport(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return _fail("编辑器文件系统不可用")
	fs.reimport_files([path])
	return _ok("已触发重新导入: %s" % path)


## 创建 .tres 资源配置
func _call_create_resource(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var script_ref := str(args.get("script", ""))
	var properties: Dictionary = args.get("properties", {})
	if path.is_empty() or script_ref.is_empty():
		return _fail("必须提供 path 和 script")
	if not path.ends_with(".tres"):
		return _fail("路径必须以 .tres 结尾: %s" % path)
	# 解析脚本: class_name 或 res:// 脚本路径
	var script: Script = null
	if script_ref.begins_with("res://"):
		script = load(script_ref) as Script
	elif script_ref.begins_with("class:"):
		script = load(script_ref.trim_prefix("class:")) as Script
	else:
		# 全局类名(如 GridGenDef): 查全局类列表找脚本路径
		var all_classes := ProjectSettings.get_global_class_list()
		for c in all_classes:
			if str(c.get("class", "")) == script_ref:
				script = load(str(c.get("path", ""))) as Script
				break
		if script == null:
			# 兜底: 尝试当作 res:// 相对路径
			script = load("res://" + script_ref) as Script
	if script == null:
		return _fail("找不到脚本 %s (新建脚本请先 reload_project)" % script_ref)
	if not script.can_instantiate():
		return _fail("脚本 %s 不可实例化(abstract/@tool 缺失?)" % script_ref)
	var res: Resource = script.new() as Resource
	if res == null:
		return _fail("脚本实例化失败: %s" % script_ref)
	# 设置属性(逐项, 用自动类型转换)
	for key in properties:
		if not res.has_method("set") and not (key in res):
			return _fail("属性不存在: %s" % key)
		var v: Variant = _auto_convert_arg(properties[key])
		res.set(key, v)
	# 确保目录存在并保存
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var dir := DirAccess.open(dir_path)
		if dir == null:
			var err := DirAccess.make_dir_recursive_absolute(dir_path)
			if err != OK:
				return _fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return _fail("保存资源失败: %s (错误码: %d)" % [path, err])
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
	return _ok_json({
		"path": path,
		"script": script_ref,
		"properties": properties,
		"message": "资源配置创建成功(建议 reload_project 让编辑器识别新资源)"
	})


## 读取资源的完整属性树
func _call_get_resource_info(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var max_depth := int(args.get("max_depth", 5))
	if path.is_empty():
		return _fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return _fail("资源不存在: %s" % path)
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		return _fail("资源加载失败: %s" % path)
	var info := {
		"path": path,
		"type": res.get_class(),
		"script": res.get_script().resource_path if res.get_script() else null,
		"name": res.resource_name if res is Resource else "",
		"properties": _resource_property_tree(res, 0, max_depth),
	}
	return _ok_json(info)


## 递归收集资源导出属性(含嵌套子资源)
func _resource_property_tree(res: Resource, depth: int, max_depth: int) -> Dictionary:
	var out := {}
	if depth > max_depth:
		return {"_note": "达到最大深度, 停止展开"}
	for p in res.get_property_list():
		var pname: String = str(p.name)
		# 跳过内置元数据与脚本引用(避免噪音)
		if pname.begins_with("_") or pname in ["resource_path", "resource_name", "script", "resource_local_to_scene"]:
			continue
		var val: Variant = res.get(pname)
		if val is Resource:
			if val == res:
				out[pname] = {"_self_ref": true}
			else:
				out[pname] = _resource_property_tree(val, depth + 1, max_depth)
		elif val is Dictionary:
			out[pname] = {"_dict_size": (val as Dictionary).size()}
		elif val is Array:
			out[pname] = {"_array_size": (val as Array).size(), "_type": _value_type(val)}
		else:
			out[pname] = {"value": val, "type": _value_type(val)}
	return out


func _value_type(v: Variant) -> String:
	return type_string(typeof(v))


## ======= 文件操作实现 =======

func _call_read_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return _fail("文件不存在: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	# 仅支持 UTF-8(引擎默认编码)。此前声明的 gbk/gb2312 实际未实现解码, 已移除以免误导。
	var content := file.get_as_text()
	var size := file.get_length()
	file.close()
	return _ok_json({
		"path": path,
		"size": size,
		"encoding": "utf-8",
		"content": content
	})


func _call_write_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var content: String = str(args.get("content", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
			var dir := DirAccess.open(dir_path)
			if dir == null:
				var err := DirAccess.make_dir_recursive_absolute(dir_path)
				if err != OK:
					return _fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	var size := file.get_length()
	file.close()
	return _ok_json({
		"path": path,
		"size": size,
		"message": "文件写入成功"
	})


func _call_append_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var content: String = str(args.get("content", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return _call_write_file(args)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return _fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.seek_end()
	file.store_string(content)
	var new_size := file.get_length()
	file.close()
	return _ok_json({
		"path": path,
		"size": new_size,
		"message": "内容追加成功"
	})


func _call_delete_file(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	if not FileAccess.file_exists(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return _fail("文件或目录不存在: %s" % path)
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			return _fail("无法删除目录: %s (错误码: %d)。注意: 只能删除空目录" % [path, err])
		return _ok_json({"path": path, "message": "目录删除成功"})
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return _fail("无法删除文件: %s (错误码: %d)" % [path, err])
	return _ok_json({"path": path, "message": "文件删除成功"})


func _call_file_exists(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", ""))
	if path.is_empty():
		return _fail("必须提供 path")
	var exists := FileAccess.file_exists(path)
	var is_dir := false
	if not exists:
		var dir := DirAccess.open(path)
		is_dir = dir != null
	return _ok_json({
		"path": path,
		"exists": exists or is_dir,
		"is_directory": is_dir,
		"message": "文件存在" if exists else ("目录存在" if is_dir else "文件不存在")
	})


## ======= 辅助 =======

## 当前正在编辑的场景根节点(编辑器模式)或运行中场景(运行时模式)
func _edited_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := get_tree()
	return tree.current_scene if tree else null


## 在场景内解析节点(名称/相对路径/绝对路径)
func _resolve_node(path: String) -> Node:
	var root := _edited_root()
	if root == null:
		return null
	if path == "root" or path == "/" or path == str(root.name):
		return root
	if path.begins_with("@"):
		return root.find_child(path.substr(1), true, false)
	if path.begins_with("/"):
		var rel := path.trim_prefix("/")
		return root.get_node_or_null(rel)
	var n := root.get_node_or_null(path)
	if n:
		return n
	return root.find_child(path, true, false)


## 获取编辑器 UndoRedo 管理器(仅编辑器模式)。所有场景变异工具经它提交,
## 使 AI 的修改可被用户 Ctrl+Z 撤销。非编辑器/不可用时返回 null(调用方应兜底直接修改)。
func _editor_undo_redo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()


## 自动推断并转换参数类型(无需知道目标类型)
## 支持: Vector2/Vector2i/Vector3/Vector3i/Color/Rect2/数字/布尔等
func _auto_convert_arg(value: Variant) -> Variant:
	if not value is String:
		return value
	var s: String = value
	# 检测 Vector2 格式: "x,y" 或 "(x, y)"
	if s.count(",") == 1 and not s.contains("Color") and not s.contains("Rect"):
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 2:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			if _is_numeric(x) and _is_numeric(y):
				return Vector2(float(x), float(y))
	# 检测 Vector2i 格式
	if s.count(",") == 1 and s.contains("i"):
		var parts := s.replace("(", "").replace(")", "").replace("i", "").split(",")
		if parts.size() == 2:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			if _is_numeric(x) and _is_numeric(y):
				return Vector2i(int(x), int(y))
	# 检测 Vector3 格式: "x,y,z"
	if s.count(",") == 2:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 3:
			var x := parts[0].strip_edges()
			var y := parts[1].strip_edges()
			var z := parts[2].strip_edges()
			if _is_numeric(x) and _is_numeric(y) and _is_numeric(z):
				return Vector3(float(x), float(y), float(z))
	# 检测 Color 格式: "r,g,b" 或 "r,g,b,a"
	if s.count(",") >= 2 and s.count(",") <= 3:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() >= 3 and parts.size() <= 4:
			var all_numeric := true
			for p in parts:
				if not _is_numeric(p.strip_edges()):
					all_numeric = false
					break
			if all_numeric:
				var r := float(parts[0].strip_edges())
				var g := float(parts[1].strip_edges())
				var b := float(parts[2].strip_edges())
				var a := float(parts[3].strip_edges()) if parts.size() == 4 else 1.0
				return Color(r, g, b, a)
	# 检测 Rect2 格式: "x,y,w,h"
	if s.count(",") == 3:
		var parts := s.replace("(", "").replace(")", "").split(",")
		if parts.size() == 4:
			var all_numeric := true
			for p in parts:
				if not _is_numeric(p.strip_edges()):
					all_numeric = false
					break
			if all_numeric:
				return Rect2(float(parts[0].strip_edges()), float(parts[1].strip_edges()),
					float(parts[2].strip_edges()), float(parts[3].strip_edges()))
	# 检测纯数字
	if _is_numeric(s):
		if s.contains("."):
			return float(s)
		else:
			return int(s)
	# 检测布尔值
	if s == "true":
		return true
	elif s == "false":
		return false
	# 检测 null
	if s == "null" or s == "nil":
		return null
	return value


## 检查字符串是否为有效数字
func _is_numeric(s: String) -> bool:
	if s.is_empty():
		return false
	var i := 0
	if s[0] == "-" or s[0] == "+":
		i = 1
	var has_dot := false
	while i < s.length():
		var c := s[i]
		if c == ".":
			if has_dot:
				return false
			has_dot = true
		else:
			var code := c.unicode_at(0)
			if code < 48 or code > 57: # '0'-'9'
				return false
		i += 1
	return true


## 将传入值转换为目标类型(处理 Vector2/Vector3/Color 等字符串)
func _coerce_value(value: Variant, target_type: int) -> Variant:
	if value is String:
		var s: String = value
		match target_type:
			TYPE_VECTOR2:
				if s.count(",") == 1:
					var parts := s.split(",")
					return Vector2(float(parts[0]), float(parts[1]))
			TYPE_VECTOR2I:
				if s.count(",") == 1:
					var parts := s.split(",")
					return Vector2i(int(parts[0]), int(parts[1]))
			TYPE_VECTOR3:
				if s.count(",") == 2:
					var parts := s.split(",")
					return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
			TYPE_VECTOR3I:
				if s.count(",") == 2:
					var parts := s.split(",")
					return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			TYPE_VECTOR4:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Vector4(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_VECTOR4I:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Vector4i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
			TYPE_COLOR:
				if s.count(",") >= 2:
					var parts := s.split(",")
					if parts.size() == 3:
						return Color(float(parts[0]), float(parts[1]), float(parts[2]), 1.0)
					elif parts.size() >= 4:
						return Color(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_RECT2:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_RECT2I:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Rect2i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
			TYPE_PLANE:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Plane(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_QUATERNION:
				if s.count(",") == 3:
					var parts := s.split(",")
					return Quaternion(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
			TYPE_AABB:
				if s.count(",") == 5:
					var parts := s.split(",")
					return AABB(Vector3(float(parts[0]), float(parts[1]), float(parts[2])),
					           Vector3(float(parts[3]), float(parts[4]), float(parts[5])))
			TYPE_INT:
				return int(s)
			TYPE_FLOAT:
				return float(s)
			TYPE_BOOL:
				return s == "true"
	return value


## ======= 运行时工具(游戏进程内原生执行) =======

func _register_runtime_tools() -> void:
	# 仅游戏进程首次进入时清空(editor 进程已由 _register_editor_tools 清空并注册了编辑/项目工具,
	# 这里只能追加 runtime 工具, 不能 reset 否则会清掉前面分组的注册)。
	if _tool_handlers.is_empty():
		_reset_tools()
	_register_game_play_tool("simulate_click",
		"在游戏窗口模拟鼠标左键点击(按下+释放), 坐标为游戏视口坐标。自动化测试按钮/UI等交互。",
		_simulate_click_schema(),
		_call_simulate_click,
		func(args): return await _call_runtime_proxy("simulate_click", args))

	_register_game_play_tool("simulate_drag",
		"在游戏窗口模拟拖拽(按下→移动→释放), 测试拖拽交互。",
		_simulate_drag_schema(),
		_call_simulate_drag,
		func(args): return await _call_runtime_proxy("simulate_drag", args))

	_register_game_play_tool("simulate_key",
		"在游戏窗口模拟键盘按键(按下/释放), 测试键盘交互。",
		_simulate_key_schema(),
		_call_simulate_key,
		func(args): return await _call_runtime_proxy("simulate_key", args))

	_register_game_play_tool("take_screenshot",
		"画面感知工具。默认'text'文本化截图(推荐): 返回游戏画面可见节点布局(名称/类型/坐标/尺寸/文本), 无需真图省token, 适合点击模拟与无识图AI。capture_type='game'真实截图(保存PNG返回路径, 附带text快照可include_text=false关)。'editor'编辑器视口截图,'scene'场景缩略图。仅当你能看到图片(多模态识图)时才用非text模式, 纯文本AI禁用game/editor/scene。",
		{"type": "object", "properties": {
			"capture_type": {"type": "string", "description": "模式: 'text' 文本化截图(默认, 推荐, 需游戏运行), 'game' 真实游戏截图(需游戏运行), 'editor' 编辑器视口截图, 'scene' 当前场景缩略图"},
			"max_width": {"type": "integer", "description": "仅真实截图生效: 最大宽度, 超过则等比缩小。默认 1280, 传 0 或更大值可保留原始分辨率"},
			"include_text": {"type": "boolean", "description": "仅真实截图生效: 是否附带文本化截图(text 字段), 默认 true"},
			"text_max_nodes": {"type": "integer", "description": "文本化截图最多节点数, 默认 50"}
		}},
		_runtime_take_screenshot,
		_call_take_screenshot)

	_register_game_play_tool("game_eval",
		"在游戏进程执行GDScript代码, 可访问游戏场景树(get_tree()/get_node()/get_viewport()等), 读运行状态/改变量/触发逻辑。可return返回值。get_node相对路径基于eval实例, 访问场景节点用绝对路径/root/场景名/子路径或get_tree().current_scene.get_node(...)。",
		{"type": "object", "properties": {"code": _code_arg()}},
		_call_eval_code,
		func(args): return await _call_game_eval_proxy(args))

	_register_game_play_tool("get_game_logs",
		"获取游戏进程的日志(print/printerr)。返回next游标, 增量用其作since避免重复。连续重复的同内容日志自动合并为一条(repeat 计数)以节省token。",
		_logs_schema(200, "日志"),
		_call_get_logs,
		func(args): return await _call_runtime_proxy("get_game_logs", args))

	_register_game_play_tool("get_game_errors",
		"获取游戏进程捕获的错误(脚本错误/assert/push_error), 含文件/行号/类型/栈追踪。返回next游标, 增量用其作since。连续重复的同位置错误自动合并为一条(repeat 计数)以节省token。",
		_logs_schema(100, "错误"),
		_call_get_errors,
		func(args): return await _call_runtime_proxy("get_game_errors", args))

	_register_game_play_tool("clear_game_errors",
		"清空游戏进程的错误缓冲。",
		_no_arg_schema(),
		_call_clear_errors,
		func(args): return await _call_runtime_proxy("clear_game_errors", args))

	_register_game_play_tool("auto_verify",
		"自动验证闭环: 启动场景后按操作序列模拟玩家行为, 每步后增量查错。操作: wait(延迟)/click/drag/key(输入)/eval(执行GDScript可return)/poll(轮询直到code返回true, 探测期eval错误不计入)/screenshot。soft模式(stop_on_error=false)跑完全部步骤再汇总, hard模式任一步出错即停。retries>0时失败自动重启场景重跑(排除flaky), 曾失败但最终通过会标 was_flaky=true(警惕被时序掩盖的潜在bug), 返回retry_history。返回verdict=pass/fail+逐步明细+first_error_step。注意: duration为单次总时长上限(默认4s), 操作总耗时(含wait/poll)不能超过它; duration建议<=15s(代理超时20s)。",
		_auto_verify_schema(),
		_runtime_auto_verify,
		func(args): return await _call_auto_verify(args))


## 递归收集可见节点信息(运行时模式, 游戏进程内坐标天然正确)
func _collect_visible_nodes(node: Node, viewport: Viewport, result: Array, max_nodes: int, depth: int, max_depth: int) -> void:
	if result.size() >= max_nodes:
		return
	if depth > max_depth:
		return
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	if node.name != "" and not str(node.name).begins_with("@"):
		var screen_pos := Vector2.ZERO
		var screen_size := Vector2.ZERO
		var z_index := 0
		if node is CanvasItem:
			var canvas_item := node as CanvasItem
			if node is Control:
				var control := node as Control
				var global_rect := control.get_global_rect()
				screen_pos = global_rect.position
				screen_size = global_rect.size
			elif node is Node2D:
				var node2d := node as Node2D
				screen_pos = canvas_item.get_global_transform_with_canvas() * Vector2.ZERO
				if node is Sprite2D:
					var sprite := node as Sprite2D
					if sprite.texture:
						screen_size = Vector2(sprite.texture.get_width(), sprite.texture.get_height())
				elif node is Polygon2D:
					var polygon := node as Polygon2D
					if polygon.polygon.size() > 0:
						var rect := Rect2(polygon.polygon[0], Vector2.ZERO)
						for p in polygon.polygon:
							rect = rect.expand(p)
						screen_size = rect.size
			z_index = canvas_item.z_index if canvas_item is Node2D else 0
		var class_name_str := node.get_class()
		var script_class_str: String = ""
		var nscript: Script = node.get_script()
		if nscript != null:
			script_class_str = nscript.get_global_name()
		var info := {
			"name": str(node.name),
			"class": class_name_str,
			"script_class": script_class_str,
			"screen_position": {"x": int(screen_pos.x), "y": int(screen_pos.y)},
			"screen_size": {"x": int(screen_size.x), "y": int(screen_size.y)},
			"z_index": z_index,
			"visible": true
		}
		if node is Button:
			info["text"] = (node as Button).text
			info["disabled"] = (node as Button).disabled
		elif node is Label:
			info["text"] = (node as Label).text
		elif node is Sprite2D:
			var sprite := node as Sprite2D
			if sprite.texture:
				info["texture_size"] = {"x": sprite.texture.get_width(), "y": sprite.texture.get_height()}
		elif node is Control:
			var control := node as Control
			info["rect"] = {"x": int(control.position.x), "y": int(control.position.y), "w": int(control.size.x), "h": int(control.size.y)}
		elif node is Polygon2D:
				var polygon := node as Polygon2D
				info["polygon_count"] = polygon.polygon.size()
		result.append(info)
	for child in node.get_children():
		_collect_visible_nodes(child, viewport, result, max_nodes, depth + 1, max_depth)


## 运行时: 模拟鼠标左键点击(游戏进程内 Input.parse_input_event 直接生效)
func _call_simulate_click(args: Dictionary) -> Dictionary:
	var x: int = int(args.get("x", 0))
	var y: int = int(args.get("y", 0))
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = Vector2(x, y)
	down_event.global_position = Vector2(x, y)
	Input.parse_input_event(down_event)
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = Vector2(x, y)
	up_event.global_position = Vector2(x, y)
	Input.parse_input_event(up_event)
	return _ok_json({
		"position": {"x": x, "y": y},
		"message": "鼠标左键点击事件已发送"
	})


## 运行时: 模拟鼠标拖拽(左键按下->移动到目标->释放)
func _call_simulate_drag(args: Dictionary) -> Dictionary:
	var from_x: int = int(args.get("from_x", 0))
	var from_y: int = int(args.get("from_y", 0))
	var to_x: int = int(args.get("to_x", 0))
	var to_y: int = int(args.get("to_y", 0))
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = Vector2(from_x, from_y)
	down_event.global_position = Vector2(from_x, from_y)
	Input.parse_input_event(down_event)
	var steps := 15
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var current_x := lerpf(float(from_x), float(to_x), t)
		var current_y := lerpf(float(from_y), float(to_y), t)
		var move_event := InputEventMouseMotion.new()
		move_event.position = Vector2(current_x, current_y)
		move_event.global_position = Vector2(current_x, current_y)
		move_event.relative = Vector2(current_x - from_x, current_y - from_y) if i > 0 else Vector2.ZERO
		move_event.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(move_event)
		if i < steps:
			await get_tree().create_timer(0.016).timeout
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = Vector2(to_x, to_y)
	up_event.global_position = Vector2(to_x, to_y)
	Input.parse_input_event(up_event)
	return _ok_json({
		"from": {"x": from_x, "y": from_y},
		"to": {"x": to_x, "y": to_y},
		"message": "拖拽事件已发送"
	})


## 运行时: 模拟键盘按键
func _call_simulate_key(args: Dictionary) -> Dictionary:
	var key_str: String = str(args.get("key", "")).to_lower()
	var pressed: bool = _to_bool(args.get("pressed", true))
	var key_code: Key
	match key_str:
		"space": key_code = KEY_SPACE
		"enter": key_code = KEY_ENTER
		"escape": key_code = KEY_ESCAPE
		"tab": key_code = KEY_TAB
		"backspace": key_code = KEY_BACKSPACE
		"delete": key_code = KEY_DELETE
		"up": key_code = KEY_UP
		"down": key_code = KEY_DOWN
		"left": key_code = KEY_LEFT
		"right": key_code = KEY_RIGHT
		"shift": key_code = KEY_SHIFT
		"ctrl": key_code = KEY_CTRL
		"alt": key_code = KEY_ALT
		_:
			if key_str.length() == 1:
				key_code = key_str.to_upper().unicode_at(0)
			else:
				return _fail("未知的按键: %s" % key_str)
	var event := InputEventKey.new()
	event.keycode = key_code
	event.pressed = pressed
	Input.parse_input_event(event)
	return _ok_json({
		"key": key_str,
		"pressed": pressed,
		"message": "按键事件已发送"
	})


## 运行时: 捕获游戏视口截图(文件名自动生成)
func _runtime_take_screenshot(args: Dictionary) -> Dictionary:
	var capture_type: String = str(args.get("capture_type", "text"))
	# 纯文本化截图模式(text): 不保存图片, 直接返回可见节点布局快照。
	# 适合点击游玩模拟与无法识别图像的 AI, 大幅节省 token。默认模式。
	if capture_type == "text":
		var text_max_nodes := int(args.get("text_max_nodes", 50))
		var text_data := _build_game_view_snapshot(text_max_nodes)
		return _ok_json({
			"capture_type": "text",
			"is_text_view": true,
			"text": text_data,
			"hint": "文本化截图(text, 默认): 用于点击/拖拽游玩模拟与无图像输入的AI, 省token。大部分场景用此模式即可; 仅需查看具体画面表现时才用 capture_type='game' 真实截图。",
		})
	var filename := "mcp_%s" % Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	filename += ".png"
	var dir_path := "user://mcp_screenshots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var viewport := get_viewport()
	if viewport == null:
		return _fail("无法获取游戏视口")
	# 等待渲染线程完成本帧绘制后再读纹理。
	# 不要用 RenderingServer.force_draw(): 它在线程化渲染 + vsync 下会阻塞主线程等渲染线程,
	# 可导致窗口"未响应"、渲染帧停止(已实测复现)。
	await RenderingServer.frame_post_draw
	var img: Image = viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return _fail("游戏截图失败: 视口纹理为空")
	# 缺省降采样到 1280 宽以控制体积, 传更大的 max_width 可保留更高分辨率。
	var max_width := int(args.get("max_width", 1280))
	if max_width > 0 and max_width < img.get_width():
		var scale := float(max_width) / float(img.get_width())
		img.resize(max_width, int(img.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path := "%s/%s" % [dir_path, filename]
	var img_err := img.save_png(path)
	if img_err != OK:
		return _fail("保存截图失败: 错误码 %d" % img_err)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	var result: Dictionary = {
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": bytes.size() if bytes else 0,
		"capture_type": "game",
	}
	# 整合文本化截图快照(text): 截图同时返回画面可见节点布局,
	# 供 AI 在无图像输入时也能理解画面。可用 include_text=false 关闭, text_max_nodes 控制节点数。
	if bool(args.get("include_text", true)):
		var text_max_nodes := int(args.get("text_max_nodes", 50))
		result["text"] = _build_game_view_snapshot(text_max_nodes)
	return _ok_json(result)


## 收集游戏画面文本化视图(可见节点布局快照, 即"文本化的截图")
func _build_game_view_snapshot(max_nodes: int) -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {}
	var viewport := get_viewport()
	if viewport == null:
		return {}
	var viewport_size := viewport.get_visible_rect().size
	var nodes_info: Array = []
	# 从场景树根的所有子节点遍历(current_scene + autoload + 其他根),
	# autoload 下的 UI(如 HUD) 是 root 直属子节点, 仅遍历 current_scene 会漏掉它们
	for child in tree.root.get_children():
		_collect_visible_nodes(child, viewport, nodes_info, max_nodes, 0, 10)
	return {
		"viewport_size": {"x": int(viewport_size.x), "y": int(viewport_size.y)},
		"node_count": nodes_info.size(),
		"nodes": nodes_info,
	}


## ======= 自动验证闭环(auto_verify) =======

## 运行时侧执行器: 在游戏进程内逐步执行操作序列, 每步后增量查错。
## operations 元素: {action, ...}; action 取值:
##   wait  {ms}            显式延迟(操作间间隔)
##   click {x, y}          模拟点击
##   drag  {from_x..to_y}  模拟拖拽
##   key   {key, pressed?} 模拟按键
##   eval  {code}          执行 GDScript(可 return, 结果记入 step)
##   poll  {code, timeout_ms, interval_ms} 轮询直到 code 返回 true 或超时
##   screenshot {capture_type?} 截图(结果记入 step)
func _runtime_auto_verify(args: Dictionary) -> Dictionary:
	var operations: Array = args.get("operations", [])
	if operations.is_empty():
		return _fail("必须提供 operations 操作序列")
	var duration := float(args.get("duration", 4.0))
	var stop_on_error: bool = _to_bool(args.get("stop_on_error", true))
	var err_cursor: int = _logger.get_error_cursor() if _logger else 0
	var steps: Array = []
	var all_errors: Array = []
	var first_error_step := -1
	var total_waited_ms := 0
	var deadline := Time.get_ticks_msec() + int(duration * 1000.0)
	for i in range(operations.size()):
		if Time.get_ticks_msec() >= deadline:
			break
		var op: Dictionary = operations[i]
		var action := str(op.get("action", "wait"))
		var step := {"index": i, "action": action, "status": "ok", "errors": []}
		# 执行动作
		match action:
			"wait":
				var ms := int(op.get("ms", 200))
				total_waited_ms += ms
				await get_tree().create_timer(ms / 1000.0).timeout
			"click":
				var r: Dictionary = await _call_simulate_click(op)
				if r.get("is_error", false):
					step["status"] = "action_error"
					step["message"] = str(r.get("text", ""))
			"drag":
				var r2: Dictionary = await _call_simulate_drag(op)
				if r2.get("is_error", false):
					step["status"] = "action_error"
					step["message"] = str(r2.get("text", ""))
			"key":
				var r3: Dictionary = _call_simulate_key(op)
				if r3.get("is_error", false):
					step["status"] = "action_error"
					step["message"] = str(r3.get("text", ""))
			"eval":
				var r4: Dictionary = _call_eval_code({"code": str(op.get("code", ""))})
				step["result"] = str(r4.get("text", ""))
				if r4.get("is_error", false):
					step["status"] = "action_error"
					step["message"] = str(r4.get("text", ""))
			"poll":
				# poll 期间 eval 探测的错误不算验证错误: 先快照, poll 后把游标推进到当前(丢弃探测期错误)
				var poll_err_before: int = _logger.get_error_cursor() if _logger else err_cursor
				var polled := await _poll_until(op, deadline)
				if _logger:
					err_cursor = _logger.get_error_cursor()
				step["poll"] = polled
				if not polled:
					step["status"] = "timeout"
					step["message"] = "轮询超时: 条件未在限定时间内满足"
			"screenshot":
				var r5: Dictionary = await _runtime_take_screenshot(op)
				if r5.get("is_error", false):
					step["status"] = "action_error"
					step["message"] = str(r5.get("text", ""))
				else:
					var sc: Variant = r5.get("structuredContent", null)
					if sc is Dictionary:
						step["screenshot"] = {"path": str(sc.get("path", "")), "res_path": str(sc.get("res_path", ""))}
			_:
				step["status"] = "invalid_action"
				step["message"] = "未知操作: %s(可选: wait/click/drag/key/eval/poll/screenshot)" % action
		# 每步后增量查错(捕捉该操作触发的运行时错误)
		if _logger:
			var taken := _logger.take_errors_since(err_cursor)
			err_cursor = int(taken.get("next", err_cursor))
			var new_errors: Array = taken.get("entries", [])
			if not new_errors.is_empty():
				step["errors"] = new_errors
				if step["status"] == "ok":
					step["status"] = "error"
				if first_error_step < 0:
					first_error_step = i
				all_errors.append_array(new_errors)
		steps.append(step)
		# hard 模式: 任一步出错立即停
		if stop_on_error and step["status"] != "ok":
			break
	# 汇总判定: fail = 任一错误 或 任一步非 ok(poll 超时/动作失败/非法操作) 或 预算耗尽未跑完
	var failed := not all_errors.is_empty()
	for s in steps:
		if str(s.get("status", "ok")) != "ok":
			failed = true
			break
	# 预算耗尽/提前中断导致部分操作未执行完 → fail(除非是 hard 模式在出错步骤主动停)
	if steps.size() < operations.size():
		var hard_stopped := stop_on_error and not steps.is_empty() and str(steps[steps.size() - 1].get("status", "ok")) != "ok"
		if not hard_stopped:
			failed = true
	var verdict := "fail" if failed else "pass"
	var out := {
		"verdict": verdict,
		"steps": steps,
		"step_count": steps.size(),
		"operation_count": operations.size(),
		"error_count": all_errors.size(),
		"first_error_step": first_error_step,
		"total_waited_ms": total_waited_ms,
		"stop_on_error": stop_on_error,
		"hint": "verdict=fail 时 first_error_step 指向出错操作下标, 对应 steps[i].status/errors。poll 超时/动作报错/运行期错误都会导致 fail。",
	}
	if not all_errors.is_empty():
		out["errors"] = all_errors
	return _ok_json(out)


## 轮询直到 code 返回 true 或超时。code 为 GDScript 表达式(经 eval 执行, 可 return bool)。
## 轮询期间 eval 产生的错误属于"正在探测的条件", 不计入验证错误(调用方在 poll 前已快照错误游标)。
## 默认固定 interval_ms(无递增退避, 保持语义可预期)。
func _poll_until(op: Dictionary, deadline: int) -> bool:
	var code := str(op.get("code", ""))
	if code.is_empty():
		return false
	var timeout_ms := int(op.get("timeout_ms", 5000))
	var interval_ms := int(op.get("interval_ms", 200))
	var start := Time.get_ticks_msec()
	var poll_deadline := mini(deadline, start + timeout_ms)
	while Time.get_ticks_msec() < poll_deadline:
		var r: Dictionary = _call_eval_code({"code": code})
		if not r.get("is_error", false):
			if _eval_returned_true(str(r.get("text", ""))):
				return true
		await get_tree().create_timer(interval_ms / 1000.0).timeout
	return false


## 解析 eval 返回文本, 判断是否返回 true
func _eval_returned_true(text: String) -> bool:
	var idx := text.find("返回: ")
	if idx == -1:
		return false
	var val := text.substr(idx + 4).strip_edges().to_lower()
	return val == "true" or val == "1" or val == "yes"


## ======= 编辑器模式的运行时工具转发(经 EngineDebugger 调试线) =======

func _register_game_play_tools() -> void:
	# 运行时工具(游戏操作/截图): 由 _register_runtime_tools 统一注册,
	# _register_game_play_tool 按 _mode 分流 handler(editor 代理转发 / runtime 就地执行)。
	_register_runtime_tools()

	_add_tool("debug_continue",
		"让因脚本错误/断点被暂停的游戏继续运行(等效Debugger面板Continue)。当工具报错'游戏处于断点暂停'时调用。",
		_no_arg_schema(),
		_call_debug_continue)


## 编辑器进程: 解除游戏断点暂停(等效编辑器的 Continue 按钮)
func _call_debug_continue(_args: Dictionary) -> Dictionary:
	if not _has_game_session():
		return _fail("没有运行中的游戏, 无需继续")
	if not debugger_plugin.is_breaked():
		return _ok("游戏当前未处于断点暂停状态, 无需继续")
	if debugger_plugin.debug_continue():
		_game_breaked = false
		return _ok("已让游戏继续运行(解除断点暂停)")
	return _err("无法解除断点暂停", "internal", false, "尝试 stop_game 后重新 run_game")


## 转发工具调用到游戏进程(经 EngineDebugger 调试线)。仅编辑器模式。
func _call_runtime_proxy(tool_name: String, args: Dictionary) -> Dictionary:
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		return _err("游戏未运行。请先使用 run_game 启动游戏", "game_stopped", true, "调用 run_game 启动游戏, 等待调试线就绪后重试")
	if _game_breaked and not _BREAK_SAFE_TOOLS.has(tool_name):
		# 断点暂停: 依赖主循环的工具必然挂起; get_game_errors/get_game_logs仍可用; 自动回查错误缓冲拼进响应。
		var diagnose := await _fetch_recent_game_error(tool_name)
		if diagnose != "":
			return _err("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n已自动读取错误:\n%s\n\n修正脚本后 debug_continue 继续, 或 stop_game 重启。" %
				[tool_name, diagnose],
				"game_breaked", true, "get_game_errors查错后debug_continue; 或stop_game修复重启")
		return _err("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n错误缓冲无内容(可能是手动断点)。get_game_errors复核后 debug_continue, 或 stop_game 重启。" %
			tool_name,
			"game_breaked", true, "get_game_errors复核后debug_continue; 或stop_game修复重启")
	if not _game_ready:
		return _err("游戏调试线尚未就绪", "transient", true, "等待游戏启动完成(可稍后重试, 或重新 run_game)")
	var req_id := _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	debugger_plugin.send_call(req_id, tool_name, args)
	# 轮询等待游戏响应。会话断开时 _on_session_stopped 会填充失败结果;
	# 同时每帧检测会话是否仍活跃, 一旦消失立即返回(不再干等 20s)。
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if _pending.has(req_id) and _pending[req_id] != null:
			var result: Dictionary = _pending[req_id]
			_pending.erase(req_id)
			return _normalize_wire_result(result, tool_name)
		if not debugger_plugin.has_active_session():
			_pending.erase(req_id)
			return _err("游戏进程已停止/崩溃(工具 %s 请求被取消)。先 run_game 重启。" % tool_name,
				"game_stopped", true, "run_game重启后重试")
		await get_tree().process_frame
	if _pending.has(req_id):
		_pending.erase(req_id)
	# 超时主因: eval触发运行期脚本错误导致_mcp_run中止未回发, 或是死循环/卡死。自动回查错误缓冲拼进响应。
	var diagnose := await _fetch_recent_game_error(tool_name)
	if diagnose != "":
		return _err("游戏进程响应超时(20s), 工具: %s。已发现运行期脚本错误:\n%s\n\n修正代码后重试; 若无疑错误仍超时再考虑死循环。" %
			[tool_name, diagnose],
			"validation", true, "修正上方脚本错误后重试; 仍超时则stop_game后重新run_game")
	return _err("游戏进程响应超时(20s), 工具: %s。错误缓冲无脚本错误, 可能是死循环/卡死或无响应。" % tool_name,
		"transient", true, "查game_eval是否死循环; 必要时stop_game后重新run_game")


## 超时诊断: 回查游戏错误缓冲, 返回最近一条脚本错误描述(无则返回 "")
func _fetch_recent_game_error(tool_name: String) -> String:
	# 用内部 req_id 再发一次 get_game_errors(短超时), 避免二次长期挂起
	var req_id := _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	if not debugger_plugin.send_call(req_id, "get_game_errors", {}):
		return ""
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if _pending.has(req_id) and _pending[req_id] != null:
			var result: Dictionary = _pending[req_id]
			_pending.erase(req_id)
			if not result.get("is_error", false):
				var text := str(result.get("text", ""))
				var parsed: Variant = JSON.parse_string(text)
				if parsed is Dictionary:
					var entries: Array = parsed.get("errors", [])
					if not entries.is_empty():
						var e: Dictionary = entries[entries.size() - 1]
						var msg := str(e.get("message", ""))
						var f := str(e.get("file", ""))
						var ln := str(e.get("line", ""))
						var fn := str(e.get("function", ""))
						return "  错误: %s\n  位置: %s:%s (函数: %s)" % [msg, f, ln, fn]
			return ""
		if not debugger_plugin.has_active_session():
			_pending.erase(req_id)
			return ""
		await get_tree().process_frame
	if _pending.has(req_id):
		_pending.erase(req_id)
	return ""


## 归一化来自游戏的 wire 结果, 保留结构化错误元数据供 AI 决策
func _normalize_wire_result(result: Dictionary, _tool_name: String) -> Dictionary:
	var text: String = str(result.get("text", ""))
	if text.is_empty() and result.get("content") is Array:
		var c: Array = result["content"]
		if not c.is_empty() and c[0] is Dictionary:
			text = str(c[0].get("text", ""))
	var is_err: bool = bool(result.get("is_error", false))
	if result.has("isError"):
		is_err = bool(result.get("isError", is_err))
	var extra := {}
	if result.get("structuredContent") is Dictionary:
		extra["structuredContent"] = result.get("structuredContent")
	if result.get("error_category", "") != "":
		extra["error_category"] = result.get("error_category")
		extra["is_retryable"] = bool(result.get("is_retryable", false))
		extra["recovery"] = str(result.get("recovery", ""))
	return _wrap(text, is_err, extra)


## 编辑器侧 game_eval 转发: 先本地预编译 + 静态检查, 通过后才发到游戏进程。
## 语法错误/被禁止的代码在编辑器内拦截, 避免污染游戏进程(运行时解析错误可能中断游戏)。
func _call_game_eval_proxy(args: Dictionary) -> Dictionary:
	var code: String = str(args.get("code", ""))
	var precheck := _precheck_eval_code(code)
	if precheck != "":
		return _err("game_eval 被编辑器侧预检拦截: %s" % precheck, "validation", false, "修正代码后重新调用 game_eval(语法错误无法通过重试解决, 需修改代码)")
	return await _call_runtime_proxy("game_eval", args)


## 预检 eval 代码: 返回 "" 表示通过, 否则返回错误描述。
## 1) 静态扫描被禁止的 API(防代码逃逸编辑器/游戏沙箱); 2) GDScript 语法预编译。
func _precheck_eval_code(code: String) -> String:
	if code.is_empty():
		return "必须提供 code"
	if code.length() > MAX_EVAL_LENGTH:
		return "代码过长: %d 字符, 超过上限 %d。请拆分逻辑后重试。" % [code.length(), MAX_EVAL_LENGTH]
	var forbidden := _eval_forbidden_scan(code)
	if forbidden != "":
		return forbidden
	var script := GDScript.new()
	var body := _indent_method_body(code)
	script.source_code = "extends Node\nfunc _mcp_run():\n%s" % body
	var err := script.reload()
	if err != OK:
		var text := error_string(err)
		var hint := ""
		if text.contains("hides a global script class"):
			hint = " (class_name 与全局类冲突: 请勿在 eval_code 中声明类, 或先 reload_project)"
		return "代码解析失败: %s%s" % [text, hint]
	return ""


## 静态扫描 eval 代码中被禁止的 API, 返回 "" 表示通过。
## 黑名单分两类: 精确成员访问(点号匹配) 与 危险类名(前缀匹配, 防绕过点号约束)。
## 注意: 此扫描是"事故防护围栏", 不替代信任模型——eval 代码本身就能访问当前场景任意节点。
## 它拦不住有恶意意图的攻击者(AI 可换等价 API), 主要价值是防止"被提示注入诱导"的自动执行
## 顺手触发危险副作用(删文件/发请求/弹 shell), 用一层廉价检查把事故概率压下去。
## 若要强隔离必须把 eval 放进独立沙箱进程, 远超 GDScript 静态扫描的能力, 属设计取舍。
const _EVAL_FORBIDDEN := [
	# -- 精确成员访问(阻止系统/进程逃逸) --
	["OS.execute", "调用系统命令"],
	["OS.create_process", "启动外部进程"],
	["OS.shell_open", "调用 shell 打开外部程序"],
	["OS.kill", "终止进程"],
	["OS.get_environment", "读取环境变量"],
	["DisplayServer.shell_open", "调用 shell"],
	["Engine.get_main_loop", "绕过作用域访问主循环"],
	["Engine.get_physics_frames", "读取引擎内部状态"],
	["Engine.get_singleton", "获取 OS/DisplayServer 等单例以绕过点号黑名单"],
	# -- 危险类名前缀(网络/文件/时间戳副作用) --
	["HTTPRequest", "发起网络请求"],
	["TCPServer", "监听网络端口"],
	["StreamPeerTCP", "TCP 连接"],
	["StreamPeerTLS", "TLS 连接"],
	["UDPServer", "UDP 监听"],
	["PackedScene.new", "新建场景"],
	["FileAccess", "读写文件"],
	["DirAccess", "操作文件系统"],
	["ResourceLoader.load", "加载任意资源"],
	["ProjectSettings.set_setting", "修改项目设置"],
	["DirAccess.open", "打开目录"],
]

## eval 代码长度上限(字符), 防止超长脚本导致编辑/运行进程缓慢或冻结。超限以 validation 错误拒绝。
const MAX_EVAL_LENGTH := 8192


## 判断是否为"空标识符"字符(数字开头等非法用途, 防止 `123execute` 之类绕过)
func _is_eval_id_char(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


## 静态扫描 eval 代码中被禁止的 API, 返回 "" 表示通过。
func _eval_forbidden_scan(code: String) -> String:
	# 词法级扫描: 跳过字符串字面量/注释/预处理器, 只扫描真实代码 token, 避免误报。
	# 同时做标识符边界检查, 防止 `fooProcess`/`executefield` 之类拼接绕过。
	var i := 0
	var length := code.length()
	while i < length:
		var c := code[i]
		# 跳过字符串字面量 ' " (含转义) 和 """ 长字符串
		if c == '"' or c == "'":
			var quote := code[i]
			if i + 2 < length and code[i + 1] == quote and code[i + 2] == quote:
				i += 3
				while i + 2 < length and not (code[i] == quote and code[i + 1] == quote and code[i + 2] == quote):
					i += 1
				i += 3
				continue
			i += 1
			while i < length:
				if code[i] == '\\':
					i += 2
					continue
				if code[i] == quote:
					break
				i += 1
			i += 1
			continue
		# 跳过 '#' 注释到行尾
		if c == '#':
			while i < length and code[i] != '\n':
				i += 1
			continue
		# 跳过 @onready/@export 等注解(不匹配代码, 但避免误认其中的单词)
		if c == '@':
			while i < length and (_is_eval_id_char(code[i])):
				i += 1
			continue
		# 扫描一个标识符 token
		if _is_eval_id_char(c):
			var start := i
			while i < length and _is_eval_id_char(code[i]):
				i += 1
			var token := code.substr(start, i - start)
			# 单 token 危险类名(前缀匹配类名本身)
			for item in _EVAL_FORBIDDEN:
				var name: String = item[0]
				if "." in name:
					continue
				if token == name:
					return "代码包含被禁止的 API: %s (%s)。出于安全考虑不允许在 eval 中执行。" % [name, item[1]]
			# 成员访问: 检查后续是否为 .成员名(如 OS.execute), 支持空格与换行
			for item in _EVAL_FORBIDDEN:
				var name: String = item[0]
				if "." not in name:
					continue
				var parts := name.split(".")
				if token != parts[0]:
					continue
				# 跳过 . 与空白
				var j := i
				while j < length and (code[j] == ' ' or code[j] == '\t' or code[j] == '\n' or code[j] == '\r'):
					j += 1
				if j < length and code[j] == '.':
					j += 1
					var k := j
					while k < length and _is_eval_id_char(code[k]):
						k += 1
					if code.substr(j, k - j) == parts[1]:
						return "代码包含被禁止的 API: %s (%s)。出于安全考虑不允许在 eval 中执行。" % [name, item[1]]
			continue
		# 非标识符字符: 继续
		i += 1
	return ""
