@tool
## MCP 开发服务器(autoload 单例, 编辑器/游戏双角色)
##   · 编辑器进程: 由 plugin.gd 持有节点并 start_editor(), 监听端口。
##   · 游戏进程: 不开端口, 只注册 EngineDebugger 消息捕获器("dev_mcp")。
## 本文件只做: 生命周期、工具注册装配、JSON-RPC 协议处理、路由/转发。
## 工具实现都在同目录的域脚本里。
class_name MCPDevServer extends Node

## ------- 协议层模块(均为 preload) -------
## 硬约束: 不声明 class_name、必须带 @tool —— 否则 autoload 与 plugin.gd 的 load()
## 会拿到不同的脚本代次。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPRouter := preload("res://addons/DEVFramework/MCP/MCPRouter.gd")
const MCPRuntime := preload("res://addons/DEVFramework/MCP/MCPRuntime.gd")
const MCPTransport := preload("res://addons/DEVFramework/MCP/MCPTransport.gd")
const MCPFormat := preload("res://addons/DEVFramework/MCP/MCPFormat.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")

## ------- 工具域文件 -------
## 域脚本 = 一个文件一组工具, 统一暴露 static func register(add_tool) 或 static func tools()。
## 只有**零编辑器引用**的域才能在这里 const preload(否则编辑器类会进导出包解析图);
## 含编辑器引用的域(MCPProjectTools / MCPDevToolsEditor / MCPResourceTools 等)走 _mod()。
## 判据: 域脚本里出现 Editor* 类的代码引用(注释不算)即为越界。
const MCPCodeIndex := preload("res://addons/DEVFramework/MCP/MCPCodeIndex.gd")
const MCPFileTools := preload("res://addons/DEVFramework/MCP/MCPFileTools.gd")
const MCPLogTools := preload("res://addons/DEVFramework/MCP/MCPLogTools.gd")
const MCPUITools := preload("res://addons/DEVFramework/MCP/MCPUITools.gd")
const MCPValidateTools := preload("res://addons/DEVFramework/MCP/MCPValidateTools.gd")

## MCP 目录(域脚本都在这儿), 供 _mod() 按路径取用。
const MCP_DIR := "res://addons/DEVFramework/MCP"

## ------- 配置项(ProjectSettings) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_TOKEN := MCPTransport.SETTING_TOKEN
const SETTING_MAX_OUTPUT_CHARS := "dev_framework/mcp/max_output_chars"
const SETTING_LOG_TOOL_RESULTS := "dev_framework/mcp/log_tool_results"
## 单次"等游戏回包"的上限(毫秒)。编辑器经调试线转发时的等待也用它。
const SETTING_GAME_CALL_TIMEOUT_MS := "dev_framework/mcp/game_call_timeout_ms"
const DEFAULT_GAME_CALL_TIMEOUT_MS := 600000
## 代理 deadline 比游戏侧等待多留的余量: 游戏 handler 到点返回后, 结果还要经调试线回到编辑器。
const _PROXY_RESPONSE_MARGIN_MS := 10000

## ------- 运行时服务器(导出包/独立运行)配置 -------
const SETTING_RUNTIME_ENABLED := "dev_framework/mcp/runtime_enabled"

## ------- 项目侧 provider(项目自定义 MCP 工具域) -------
const SETTING_PROVIDERS := "dev_framework/mcp/providers"

## ------- 多实例中枢(hub) -------
const SETTING_HUB := "dev_framework/mcp/hub"
const SETTING_HUB_PORT := "dev_framework/mcp/hub_port"
## 中枢端口默认值: 全机器唯一的通用端口, 项目一般不覆盖。
## 【破坏性】改它等于改所有客户端的 MCP URL, 故只在明确必要时改。
const DEFAULT_HUB_PORT := 9988

## 实例身份与中枢布局都由 MCPInstanceHub 负责, 本文件只做接线。
const HUB_SCRIPT := "MCPInstanceHub"


## 统一输出上限默认值(字符)。超限**截断**并附续读提示, 而非整条拒绝。
## 响应体双写(content[0].text 与 structuredContent), 故按单份计算, 实际占用翻倍。
const DEFAULT_MAX_OUTPUT_CHARS := 24000


## ------- MCP 常量 -------
const PROTOCOL_VERSION := MCPTransport.PROTOCOL_VERSION

## 支持的协议版本, 新到旧。用于 initialize 回显与 -32022 的 supported 列表。
## 支持多版本 ≠ 为每版写一套实现: 差异只在"新字段要不要发"。
const SUPPORTED_PROTOCOL_VERSIONS := MCPTransport.SUPPORTED_PROTOCOL_VERSIONS

## 2026-07-28 起版本改为**逐请求**声明, 且 HTTP 传输必须同时带同名请求头。
const META_VERSION_KEY := MCPTransport.META_VERSION_KEY
const META_CLIENT_CAPS_KEY := MCPTransport.META_CLIENT_CAPS_KEY
## 首个"逐请求声明版本"的协议版本: 自它起 _meta 必须带 protocolVersion 与
## clientCapabilities, 缺任一即 malformed request(-32602)。
const META_REQUIRED_SINCE := MCPTransport.META_REQUIRED_SINCE
const HEADER_VERSION := MCPTransport.HEADER_VERSION

## ======= 错误码 =======
const ERR_PARSE := MCPTransport.ERR_PARSE
## JSON-RPC: 方法名不在 _handlers 里。
const ERR_METHOD_NOT_FOUND := -32601
## JSON-RPC: 参数结构/取值不合法(同参数重试无意义)。
const ERR_INVALID_PARAMS := MCPTransport.ERR_INVALID_PARAMS
## 服务端内部异常(通常是 handler 未产出结果)。
const ERR_INTERNAL := -32603
## 传输层拒绝: 请求没进 JSON-RPC(方法不支持 / 鉴权失败 / Origin 被拦)。
const ERR_TRANSPORT_REJECTED := MCPTransport.ERR_TRANSPORT_REJECTED
## 逐请求版本与 HTTP 头不一致。
const ERR_HEADER_MISMATCH := MCPTransport.ERR_HEADER_MISMATCH
## 协商完成后仍发来不受支持的版本。
const ERR_UNSUPPORTED_VERSION := MCPTransport.ERR_UNSUPPORTED_VERSION

## tools/list 等可缓存结果的建议缓存时长(工具清单在进程生命周期内静态)。
const LIST_TTL_MS := 600000

const SERVER_NAME := "godot-dev-mcp"
const SERVER_VERSION := "0.3.0"

## 服务器级使用说明(initialize / server:discover 的 instructions 字段), 面向模型。
const BASE_INSTRUCTIONS := "Godot 开发调试 MCP 服务器(编辑器/游戏双模式): 改场景节点前先 get_scene_tree/get_node_info; 不确定 Godot 原生 API 先 classdb_query; get_logs / clear_logs / eval_code 用**必填** process 参数选进程(editor|game; 游戏进程工具需游戏在跑、导出运行时=本进程); simulate_*/take_screenshot(game) 作用于游戏进程(编辑器里调用经调试线转发)。"

## 模式
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## 调试线消息前缀(编辑器↔游戏 EngineDebugger wire)
const DEBUGGER_PREFIX := "dev_mcp"

## 全局唯一实例(编辑器/游戏进程各自持有)
static var instance: MCPDevServer

var _http: MCPTcpHttpServer
var _logger: LogCaptureTool
var _port := int(ProjectSettings.get_setting(SETTING_PORT, 8931))
var _enabled := true
## 是否已完成 initialize 版本协商(进程级单标志)。
var _version_negotiated := false
var _tool_handlers := {} # 工具名 -> Callable
var _tool_defs := [] # 工具定义列表(MCP 格式)
## 工具名 -> inputSchema。入参校验按名直查, 不能遍历 _tool_defs —— 重名时会静默取到
## 注册顺序上的第一个。
var _tool_schemas := {}
## 工具名 -> 自报分类(只有项目侧 provider 会填)。框架自带工具的分类在 MCPToolMeta 三张名单里。
var _tool_kinds := {}
var _mode := MODE_EDITOR # editor / runtime

## 编辑器模式: 指向 MCPDebuggerPlugin(由 plugin.gd 注入)。
var debugger_plugin: Object = null
## 编辑器模式: 游戏进程 MCP 桥接是否就绪(收到 dev_mcp:ready)
var _game_ready := false
## 当前游戏调试会话的启动时刻(unix 秒); 0 = 没有游戏在运行。
var _game_started_at: int = 0
## 编辑器模式: 等待游戏响应的请求表 req_id -> 结果(未就绪为 null)
var _pending := {}
var _next_req_id := 1
## 编辑器模式: 游戏是否被断点暂停(脚本错误/手动断点都会停主循环)
var _game_breaked := false
## 游戏进程推上来的最近错误副本。断点后主循环停摆, 请求式 get_logs 拿不到东西,
## 断点诊断只能靠它。
var _game_error_digest: Array[Dictionary] = []
## 断点期间仍可安全执行的工具(只读缓冲, 不依赖主循环)。
## game_control 必须在内: 它正是解暂停的那把钥匙, 拦它等于把出口锁在里面。
const _BREAK_SAFE_TOOLS := ["get_logs", "clear_logs", "game_control"]
## 错误副本条数上限(见 LogCaptureTool.error_sink)
const GAME_ERROR_DIGEST_KEEP := 20
## 游戏用例运行期间仍放行的工具。用例是长任务, 轮询/取消必须能进来;
## wait_for 也必须在内 —— 用例常"点了等结果"。
const _GAME_TESTS_OPEN_TOOLS := ["run_tests", "job_wait", "job_cancel", "job_list", "wait_for"]

## 逐条 JSON-RPC 请求日志的开关(现场可 set, 不必重启)。
static var _log_rpc := false

## 最近一次工具契约自检的问题列表(空 = 通过), 由 refresh_tools 回给调用方。
var _tool_audit_issues: Array[String] = []
var _tool_audit_handlers := {}

## 项目 provider 追加的服务器说明, 拼进 instructions(见 _register_providers)。
var _provider_instructions: Array[String] = []

## ------- 多实例中枢状态(仅编辑器进程, 见 MCPInstanceHub) -------
var _hub: Variant = null
var _hub_enabled := false
var _hub_port := DEFAULT_HUB_PORT
## 上一次心跳的时刻(ms)与防重入标志(一次心跳会连续 await 多个 HTTP 往返,
## 而 _process 每帧都调 _hub_tick)。
var _hub_last_beat := 0
## 登记标志的失效阈值(见 _hub_tick)。
const HUB_BEAT_STALE_MS := 15000
var _hub_beating := false
## 本次登记的开始时刻: 用来识别"协程被热重载掐断导致的死标志"。
var _hub_beat_started_ms := 0
## "中枢端口被非本框架程序占用"的告警只打一次: 该判定每次心跳都成立, 不节流会刷屏。
var _hub_port_foreign_warned := false
## 路由 / 运行时 / 传输模块实例(懒创建, 见 _router() / _runtime() / _transport())。
var _router_obj = null
var _runtime_obj = null
var _transport_obj = null

## ------- 生命周期(autoload) -------
func _ready() -> void:
	instance = self
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8931))
	if Engine.is_editor_hint():
		# 编辑器进程: 生命周期完全由 plugin.gd 控制(启用时 start_editor()/停用时 stop())。
		_mod("MCPScriptSync").register_unreloadable(get_script().resource_path, "承载 MCP HTTP 服务器")
		return
	# 非编辑器进程(开发期游戏进程 / 独立运行 / 导出包)。
	if not _enabled:
		return
	# 新鲜度基准(见 MCPScriptSync.guard_eval): 游戏进程内自记一份, 取 autoload 就绪时刻。
	_game_started_at = int(Time.get_unix_time_from_system())
	_logger = LogCaptureTool.new()
	OS.add_logger(_logger)
	LogCaptureTool.error_sink = _forward_error_to_editor
	_mode = MODE_RUNTIME
	# (1) 开发期桥接: "由编辑器启动的游戏进程"注册调试线工具(不占端口)。含 eval_code(process=game)
	if _is_editor_build():
		_register_game_play_tools()
		_register_providers()
		# 防御: 单例被多次实例化/热重载导致 capture 已注册时跳过, 而非崩溃。
		if not EngineDebugger.has_capture(DEBUGGER_PREFIX):
			EngineDebugger.register_message_capture(DEBUGGER_PREFIX, _on_debugger_message)
		# 通知编辑器侧桥接已就绪; 必须判 is_active —— 没有调试器时 send_message 会报错。
		if EngineDebugger.is_active():
			EngineDebugger.send_message(DEBUGGER_PREFIX + ":ready", [])
	# (2) 导出包/独立运行: 注册共享域 + 游戏操作工具(不含 eval), 勾选时复用同一端口开服。
	elif bool(ProjectSettings.get_setting(SETTING_RUNTIME_ENABLED, false)):
		_register_runtime_domains()
		_start_runtime_server()


## 是否"编辑器构建"(编辑器进程本身, 或由编辑器启动的游戏进程)。导出模板为 false。
## 判据收敛在此一处, 模块也用它。
static func _is_editor_build() -> bool:
	return OS.has_feature("editor")


## 游戏进程: 每产生一条运行期错误就推一份精简副本给编辑器。
## 断点后主循环不再运行, get_logs 不会被执行 —— 只能靠这条单向推送留证。
func _forward_error_to_editor(entry: Dictionary) -> void:
	if not _is_editor_build() or not EngineDebugger.is_active():
		return
	if str(entry.get("type", "")) == "warning":
		return
	EngineDebugger.send_message(DEBUGGER_PREFIX + ":error", [{
		message = str(entry.get("message", "")),
		file = str(entry.get("file", "")),
		line = int(entry.get("line", 0)),
		function = str(entry.get("function", "")),
		type = str(entry.get("type", "")),
	}])


## 游戏进程: 处理编辑器经调试线发来的工具调用消息。
## 注册捕获器后回调收到的 message 已去掉前缀(见 EngineDebugger 文档)。
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
	# 用例运行期间, 需要主循环的工具会被拖慢到超时。
	if _game_tests_running and not _GAME_TESTS_OPEN_TOOLS.has(tool_name) and not _BREAK_SAFE_TOOLS.has(tool_name):
		result = _err("游戏用例正在运行, 工具 %s 需要主循环, 现在调用既会拖慢用例也大概率超时。\n请用 job_wait(job_id) 或 run_tests(process=game, script=...) 读进度直到 running=false, 再调本工具; 要中断用 job_cancel 或 game_control(action=stop)。" % tool_name,
			"busy", true, "job_wait(job_id)读进度至running=false后再调用; 或job_cancel/game_control(action=stop)中断用例")
	elif _tool_handlers.has(tool_name):
		result = await _tool_handlers[tool_name].call(args)
	else:
		result = _fail("未知运行时工具: %s" % tool_name)
	# 统一输出上限: 与编辑器进程一致, 超限转明确错误提示后再回发(避免调试线承载巨型载荷)。
	result = MCPFormat.enforce_output_cap(tool_name, result, _output_cap())
	EngineDebugger.send_message(DEBUGGER_PREFIX + ":result", [req_id, result])


## 编辑器进程: MCPDebuggerPlugin._capture 委托至此(处理 ready/result)。
func _on_debugger_capture(message: String, data: Array) -> bool:
	if not message.begins_with(DEBUGGER_PREFIX + ":"):
		return false
	var kind := message.get_slice(":", 1)
	match kind:
		"ready":
			_game_ready = true
			# 桥接就绪 ⟹ 游戏已加载完全部脚本, 是新鲜度判据最准的基准。
			_mark_script_baseline("调试线就绪")
			LogTool.log("MCP", "游戏调试线桥接已就绪")
		"result":
			if data.size() >= 2:
				var req_id := int(data[0])
				_pending[req_id] = data[1]
		"error":
			if not data.is_empty() and data[0] is Dictionary:
				_game_error_digest.append(data[0])
				if _game_error_digest.size() > GAME_ERROR_DIGEST_KEEP:
					_game_error_digest.pop_front()
	return true


## 编辑器进程: 游戏调试会话建立/结束(由 MCPDebuggerPlugin 连接信号调用)
func _on_session_started(session_id: int) -> void:
	LogTool.log("MCP", "游戏调试会话已建立(session=%d)" % session_id)
	_game_ready = false
	_game_error_digest.clear()
	_mark_script_baseline("调试会话建立")
	# 未决请求置为 transient(已失败的保留), 随后清空。
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_transient("游戏调试会话已重启, 原请求被取消", "重新调用该工具即可")
	_pending.clear()


## 游戏会话结束(正常停止/崩溃/被杀)。填充所有未决请求为失败结果。
## 填充后不能 clear(), 否则代理读不到结果, 会退回配置的超时。
func _on_session_stopped(session_id: int) -> void:
	LogTool.log("MCP", "游戏调试会话已结束(session=%d)" % session_id)
	_game_ready = false
	_game_breaked = false
	_game_started_at = 0
	# 进程已没了, 能说明原因的只有游戏侧之前推上来的错误。
	var msg := _with_game_error("游戏进程已停止(正常结束或崩溃), 所有未完成的运行时调用被取消。请先 game_control(action=start) 重新启动游戏后再试。")
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_game_stopped(msg, "调用 game_control(action=start) 重新启动游戏, 等待调试线就绪后重试")


## 游戏进入断点暂停(脚本错误/断点触发, 主循环暂停但调试线仍在)。
func _on_session_breaked(_session_id: int, can_debug: bool) -> void:
	_game_breaked = true
	LogTool.log("MCP", "游戏已进入断点暂停(调试循环=%s)。运行时工具会立即返回明确错误, 可用 game_control(action=continue) 让游戏继续。" % str(can_debug))
	# 断点后主循环停摆, 能用的只有错误发生当时推过来的副本。
	var msg := _with_game_error("游戏被断点暂停(脚本错误/断点)。get_logs(process=game) 仍可用, 先查错误; 再game_control(action=continue)继续; 要修脚本则game_control(action=stop)后改代码重跑。")
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_game_breaked(msg)


## 游戏解除断点暂停, 恢复运行
func _on_session_continued(_session_id: int) -> void:
	_game_breaked = false
	LogTool.log("MCP", "游戏已恢复运行(解除断点暂停)")


## 把宿主侧状态注入各域(bind 也可重复调用: 域是同一份静态状态)。
func _bind_domains() -> void:
	_mod("MCPDevActions").bind(_rebuild_registry, _runtime)
	_mod("MCPSessionTools").bind(_runtime)
	_mod("MCPInstanceTools").bind(_hub, _router())


## 编辑器进程: 编辑器模式显式启动(由 plugin.gd 在启用插件时调用)。
func start_editor() -> void:
	if _http:
		return
	_mode = MODE_EDITOR
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	if not _enabled:
		LogTool.log("MCP", "dev_framework/mcp/enabled=false, 编辑器 MCP 服务器已跳过启动")
		return
	if _logger == null:
		_logger = LogCaptureTool.new()
		OS.add_logger(_logger)
	_register_editor_tools()
	# 中枢开启时走"抢 hub 端口 / 退让临时端口", 否则单端口。
	_hub_enabled = bool(ProjectSettings.get_setting(SETTING_HUB, true))
	if _hub_enabled:
		_start_hub_mode()
	else:
		start()
	# 中枢先建: 实例域工具要读它。绑定放在本函数而非注册处, 因为注册也可能由 refresh_tools 触发。
	_bind_domains()


## ------- 多实例中枢: 启动与绑定 -------
## 身份(项目名 + 绝对路径哈希)先于端口确定; 监听用 listen(0) 让内核分配唯一端口
## (不用 hub_port+1: 会与别的软件或实例撞), 绑端口本身就是原子的互斥判定。


## 解析本进程该用的中枢端口: project.godot 显式写了就用它, 否则用全机器统一的默认端口。
## 改默认端口是破坏性变更 —— 客户端 MCP 配置里的 URL 必须同步改。
func _resolve_hub_port() -> int:
	if _project_overrides_setting(SETTING_HUB_PORT):
		return int(ProjectSettings.get_setting(SETTING_HUB_PORT, DEFAULT_HUB_PORT))
	return DEFAULT_HUB_PORT


## project.godot 里是否**显式**写了某个设置项(而非插件注册的默认值)。
## 直接读文本是唯一可靠的判据: 显式设置必定以 "key=value" 出现在文件里。
func _project_overrides_setting(setting_key: String) -> bool:
	# 设置名形如 "dev_framework/mcp/hub_port", 文件里写作 "[dev_framework]" 段的 "mcp/hub_port"。
	var parts := setting_key.split("/")
	if parts.size() < 2:
		return false
	var file_key := "%s/%s" % [parts[parts.size() - 2], parts[parts.size() - 1]]
	var src := FileAccess.get_file_as_string("res://project.godot")
	if src.is_empty():
		return false
	for line in src.split("\n"):
		var t := line.strip_edges()
		# 必须连等号一起比: "mcp/port=" 是 "mcp/hub_port=" 的子串, 只比前缀会把前者误判成后者。
		if t.begins_with(file_key + "="):
			return true
	return false


func _start_hub_mode() -> void:
	if _hub == null:
		_hub = _mod(HUB_SCRIPT).new()
	_hub_enabled = true
	_hub_port = clampi(_resolve_hub_port(), 1024, 65535)
	_hub.auth_token = str(ProjectSettings.get_setting(SETTING_TOKEN, ""))
	# 身份: 项目名取 project.godot 的 application/config/name; 路径必须 globalize 成绝对路径。
	var project_name := str(ProjectSettings.get_setting("application/config/name", "project"))
	var project_path := ProjectSettings.globalize_path("res://")
	# 显式标类型: `_hub` 是 Variant(动态编译出来的脚本实例), 从它身上取到的返回值静态推断不出类型。
	var instance_id: String = str(_hub.make_instance_id(project_name, project_path))
	var uid := "%s#%d" % [instance_id, OS.get_process_id()]
	_hub.set_self(uid, instance_id, project_name, project_path)

	# (2) 抢中枢端口
	var err := _start(_hub_port)
	if err == OK:
		_hub.set_hub_mode(true)
		_hub.set_self_port(listening_port())
		_owner = self
		LogTool.log("MCP", "MCP 中枢已就绪(%s): http://127.0.0.1:%d/mcp —— 本实例是中枢, 其余实例会登记到这里" % [instance_id, _hub_port])
		return
	# (3) 退让: 系统分配临时端口, 再登记到中枢
	err = _start(0)
	if err != OK:
		printerr("MCPDevServer: 无法监听任何端口(中枢端口 %d 被占且临时端口也失败, 错误码 %d)。AI 助手将无法连接本实例。" % [_hub_port, err])
		return
	_hub.set_hub_mode(false)
	_hub.set_self_port(listening_port())
	_owner = self
	# 措辞是"被占用"而非"被中枢占用": 此刻还不知道占用者是谁。
	LogTool.log("MCP", "MCP 多实例: 中枢端口 %d 已被占用, 本实例退让到临时端口 %d, 即将尝试登记到中枢" % [_hub_port, listening_port()])
	# 首次登记立刻做一次, 否则刚打开的项目最多 4 秒内不出现在中枢清单里。
	_hub_last_beat = 0


## 中枢心跳(_process 里按周期调用)。
##   · 中枢: 什么都不用发, 只更新自己的 last_seen(成员会主动来登记)。
##   · 成员: 向中枢登记(登记即续约); 连续失败达到阈值时**尝试接管** —— 抢绑 hub_port。
func _hub_tick() -> void:
	if _hub == null:
		return
	var now := Time.get_ticks_msec()
	_hub.touch_self()
	if now - _hub_last_beat < _hub.heartbeat_ms():
		return
	if _hub_beating:
		# 标志位会漏: register_to 的 await 可能被脚本热重载掐断(协程随旧脚本实例一起失效),
		# 之后没有任何代码把它改回 false, 本实例就永远不再心跳、从中枢清单里消失。
		# 以时间戳判活: 一次正常的登记最多 2s 连接 + 3s 请求, 超过 STALE 必然已失效。
		if now - _hub_beat_started_ms < HUB_BEAT_STALE_MS:
			return
		_hub_beating = false
	_hub_last_beat = now
	_hub_beat_started_ms = now
	if bool(_hub.hub_mode):
		return
	_hub_beating = true
	var resp: Dictionary = await _hub.register_to(_hub_port, _hub.register_payload())
	_hub_beating = false
	if bool(resp.get("ok", false)):
		if not _hub.registered:
			LogTool.log("MCP", "MCP 多实例: 已登记到中枢 %s" % str(resp.get("hub", {}).get("instance_id", "?")))
		_hub.registered = true
		_hub.fail_streak = 0
		_hub.hub_instance_id = str(resp.get("hub", {}).get("instance_id", ""))
		# 中枢回包带全机器实例表: 同步过来, 成员进程的 list_instances 才能看到全部。
		if resp.get("instances") is Array:
			_hub.sync_from_snapshot(resp.get("instances"))
		return
	_hub.registered = false
	_hub.fail_streak += 1
	if _hub.fail_streak < 3:
		return
	# 中枢可能已退出: 尝试接管。不重置 fail_streak —— 抢不到就继续等。
	if _take_over_hub():
		return
	if _hub.fail_streak < 3:
		return
	# 走到这里 = 既连不上中枢、又抢不到中枢端口。分两种情形, 报错必须分开写:
	#   · 从未见过中枢, 且端口抢不到 —— **端口被别的程序占着**(不是本框架的实例)。
	#     这是统一端口方案唯一的单点故障: 客户端配的是 hub_port, 而它上面坐着一个外人,
	#   · 见过中枢(记录过它的 id) —— 那就是中枢卡住或正在重启, 等着就行, 不用报错。
	if _hub.hub_instance_id.is_empty() and not _hub_port_foreign_warned:
		_hub_port_foreign_warned = true
		LogTool.log("MCP", "MCP 多实例【端口冲突】: 中枢端口 %d 已被**非本框架**的程序占用(能连上但不应答 /hub/*, 且抢不到)。本实例已退让到临时端口 %d —— 但客户端配置写的是 %d, 因此**现在连不上本实例的 MCP**。\n处理方式: ① 找出占用 %d 的程序并关掉, 或 ② 把本机所有项目的 dev_framework/mcp/hub_port 一起改成别的空闲端口, 并同步改客户端 MCP 配置里的 URL。" % [
			_hub_port, listening_port(), _hub_port, _hub_port])
	elif _hub.fail_streak == 3:
		LogTool.log("MCP", "MCP 多实例: 中枢 %s 暂时无响应, 接管失败(可能它正忙或另一个实例已先接管), 继续按成员运行并在下个周期重试" % _hub.hub_instance_id)


## 接管中枢: 关掉临时端口的监听, 改绑 hub_port(两个端口不同, 无需先释放)。
func _take_over_hub() -> bool:
	# 显式标类型: _hub 是 Variant(动态编译的脚本实例), `:=` 从它取到的值无法静态推断类型。
	var old_port: int = int(_hub.own_port)
	_stop_listening()
	var err := _start(_hub_port)
	if err != OK:
		# 回滚: 恢复临时端口, 否则本实例连成员都不是了(彻底从注册表消失, 且不自愈)。
		if _start(old_port) != OK:
			printerr("MCPDevServer: 接管中枢失败且无法恢复临时端口 %d, 本实例 MCP 已停止" % old_port)
		return false
	_hub.set_hub_mode(true)
	_hub.set_self_port(listening_port())
	_hub.registered = true
	_hub.fail_streak = 0
	_owner = self
	LogTool.log("MCP", "MCP 多实例: 原中枢已退出, 本实例接管为中枢: http://127.0.0.1:%d/mcp" % _hub_port)
	return true


## 当前真正持有监听端口的实例(进程内至多一个)。
## 真正监听的是 MCPDevServer.new() 建的子节点, 故"该不该启动/自愈"必须按**实例身份**
## 判断, 不能只看 _http 是否为 null —— 否则 autoload 那个从不监听的实例也会去抢。
static var _owner = null
static var _last_autostart := 0


## 每帧驱动 HTTP 服务器, 并在它意外消失时自动拉起。
func _process(_delta: float) -> void:
	if _http:
		_http.poll()
		# 心跳必须每帧都可能跑, 不能挂在下面的 return 之后。
		_hub_tick()
		return
	# 自愈只在"这个实例本来就该监听"时发生: 热重载把 _http 清成 null 后端口已释放,
	# 而用户和插件都没主动停过, 该自动重开, 否则改框架脚本都得重启编辑器。
	if _owner != self or not Engine.is_editor_hint():
		return
	var now := Time.get_ticks_msec()
	if now - _last_autostart < 5000:
		return
	_last_autostart = now
	LogTool.log("MCP", "检测到 MCP 服务器已停止(通常是脚本热重载清掉了状态), 正在自动重新启动…")
	# 热重载会清空实例成员(含 _hub): 重建并恢复身份, 否则重启后会以空身份登记。
	_hub = null
	_hub_last_beat = 0
	_hub_beating = false
	start_editor()


## tools/list 内容指纹: 把当前注册表压成一个短十六进制串。
func _schema_fingerprint() -> String:
	return "%08x" % (JSON.stringify(_tool_defs).hash() & 0xFFFFFFFF)


## 重建注册表并返回 {count, fingerprint, issues}; 结果文案由 MCPDevActions 统一拼。
func _rebuild_registry() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"count": 0, "fingerprint": "", "issues": ["仅在编辑器模式可用"]}
	# 注册走 _mod()(从源码重编译磁盘版本), 因此域文件里新增/改动的工具也免重启生效。
	_register_editor_tools()
	var count := _tool_defs.size()
	var fp := _schema_fingerprint()
	LogTool.log("MCP", "手动重建工具注册表: %d 个工具, 指纹 %s" % [count, fp])
	return {"count": count, "fingerprint": fp, "issues": _tool_audit_issues.duplicate()}


## 关闭服务器并移除 Logger(退出时由引擎自动调用)
func _exit_tree() -> void:
	# stop() 已注销过, 这里不重复。
	stop()
	# 注销调试线捕获。判 has_capture 是必要的: 本 autoload 在非编辑器构建里也可能存在。
	# headless 跑测试时引擎 shutdown 阶段仍会打一条 ERROR, 与本函数无关; 不注销则插件
	# 停用再启用后, 旧捕获器会指向已释放对象, 代价更大。
	if EngineDebugger.is_active() and EngineDebugger.has_capture(DEBUGGER_PREFIX):
		EngineDebugger.unregister_message_capture(DEBUGGER_PREFIX)
	if _logger:
		OS.remove_logger(_logger)
		_logger = null


## 退出时通知中枢把自己摘掉(best-effort, 不等待响应)。
func _hub_notify_exit() -> void:
	if _hub == null or bool(_hub.hub_mode) or not _hub.registered:
		return
	var body := JSON.stringify({"uid": _hub.own_uid})
	var head := "POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: application/json\r\n" % [_hub.unregister_path(), _hub_port]
	if not _hub.auth_token.is_empty():
		head += "Authorization: Bearer %s\r\n" % _hub.auth_token
	head += "Content-Length: %d\r\nConnection: close\r\n\r\n" % body.to_utf8_buffer().size()
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", _hub_port) != OK:
		return
	peer.poll()
	peer.put_data((head + body).to_utf8_buffer())
	peer.disconnect_from_host()


## ------- 服务器启停 -------
func start() -> void:
	if not _enabled or _http:
		return
	var err := _start(_port)
	if err != OK:
		printerr("MCPDevServer: 监听端口 %d 失败 (错误码 %d)。已自动跳过, AI 助手将无法连接。" % [_port, err])
		return
	# 只在**监听成功**后才认领 owner: 否则自愈会认为该自己监听而反复重试。
	_owner = self
	# 工具名清单不打: 几十个名字会占满日志, 而它是静态的, 客户端随时能用 tools/list 查。
	LogTool.log("MCP", "MCP 服务器已开启(%s): http://127.0.0.1:%d/mcp, 已注册 %d 个工具" % [_mode, _port, _tool_defs.size()])


func stop() -> void:
	# 停用插件也走这里: 先向中枢注销, 否则中枢会对着本实例转发到超时(最多等满 TTL)。
	_hub_notify_exit()
	if _owner == self:
		_owner = null
	_stop_listening()


## 只停监听(不动 _owner/不注销 logger), 供接管切换与自愈共用。
func _stop_listening() -> void:
	if _http:
		if _http.request_received.is_connected(_on_request):
			_http.request_received.disconnect(_on_request)
		_http.stop()
		_http = null


func is_running() -> bool:
	return _http != null and _http.is_listening()


## 当前实际监听端口(中枢=固定端口 / 成员=系统分配的临时端口)。未监听时返回 0。
## get_project_info 报的就是这个值 —— 成员转发到中枢时必须报**成员自己的**端口。
func listening_port() -> int:
	return _http.get_port() if _http else 0


## ------- 运行时服务器(导出包/独立运行) -------
func _start_runtime_server() -> void:
	# 运行时用**项目级**端口: 它表达"这个产品监听在哪", 与"本机开发入口"是两件事。
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8931))
	var err := _start(_port)
	if err != OK:
		push_error("[MCP] 运行时服务器监听 127.0.0.1:%d 失败(错误码 %d)" % [_port, err])
		return
	print("[MCP] 运行时服务器已启动: http://127.0.0.1:%d/ (%d 个工具)" % [_port, _tool_defs.size()])


## 监听并接管请求。port 传 0 = 由内核分配空闲端口(多实例退让路径)。
func _start(port: int = -1) -> Error:
	var want := _port if port < 0 else port
	_http = MCPTcpHttpServer.new()
	var err := _http.listen(want, "127.0.0.1")
	if err != OK:
		_http = null
		return err
	_http.request_received.connect(_on_request)
	return OK


## ------- 工具注册 -------
## 第 5 个参数 kind 供项目侧 provider 自报分类("read_only" / "non_destructive" /
## "destructive"): 它们的工具名不在框架的三张名单里, 不自报就只能按破坏性兜底。
func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable, kind := "") -> void:
	_tool_handlers[name] = handler
	_tool_schemas[name] = input_schema
	var k := str(kind)
	if not k.is_empty():
		_tool_kinds[name] = k
	_tool_defs.append(_mod("MCPToolMeta").build(name, desc, input_schema, k))


## MCP 目录下的域脚本按"当前磁盘版本"动态取用(而非 const preload 的编译期绑定)。
## 已编译进本文件的静态调用目标连 `X.reload()` 也换不掉, 故只能从源码重编译。
var _mod_cache := {}


func _mod(name: String) -> Variant:
	if _mod_cache.has(name):
		return _mod_cache[name]
	var gd: Variant = _script_from_disk("%s/%s.gd" % [MCP_DIR, name])
	_mod_cache[name] = gd
	return gd


## 按当前磁盘源码重编译一个脚本(绕过 ResourceLoader 缓存)。域文件与项目 provider 共用。
func _script_from_disk(path: String) -> Variant:
	var src := FileAccess.get_file_as_string(path)
	if src.is_empty():
		return ResourceLoader.load(path)
	var gd := GDScript.new()
	gd.source_code = src
	if gd.reload() != OK:
		push_error("[MCP] 脚本 %s 重编译失败, 回退缓存版本" % path)
		gd = ResourceLoader.load(path)
	return gd


## 通用游戏操作工具注册: editor 侧 handler 经调试线转发, runtime 侧就地执行。
func _register_game_play_tool(name: String, desc: String, schema: Dictionary, runtime_handler: Callable, editor_handler := Callable()) -> void:
	var ehandler: Callable = editor_handler
	if not ehandler.is_valid():
		ehandler = func(args: Dictionary) -> Dictionary: return await _call_runtime_proxy(name, args)
	# 登记"入参自检该切哪一份"。转发 lambda 不读入参, 切不出函数体会被**静默跳过**。
	for h in [runtime_handler, ehandler]:
		var m := String(h.get_method())
		if m != "<anonymous lambda>":
			_tool_audit_handlers[name] = h
			break
	if _mode == MODE_EDITOR:
		_add_tool(name, desc, schema, ehandler)
	else:
		_add_tool(name, desc, schema, runtime_handler)


func _reset_tools() -> void:
	_tool_handlers.clear()
	_tool_defs.clear()
	# _tool_schemas 与 _tool_audit_handlers 一并清: 三份索引必须同增同减(漏清当下不会报错)。
	_tool_schemas.clear()
	_tool_kinds.clear()
	_tool_audit_handlers.clear()
	# 域脚本的源码编译缓存也必须每轮重建: 否则 refresh_tools 会复用上一轮编译的旧版本。
	_mod_cache.clear()


func _register_editor_tools() -> void:
	_reset_tools()
	# 绑定必须在 _reset_tools 之后、各域 tools() 之前: _reset_tools 会清 _mod_cache,
	# 域类随之重编译, 上一轮的静态绑定就失效了。
	_bind_domains()
	_register_shared_domains()
	_register_editor_only_domains()
	_register_game_play_tools()
	_register_providers()
	_audit_tools()


## ======= 域注册 =======

## 注册"编辑器与运行时都可用"的域。走 _mod: 编辑器侧热重载, 运行时侧也能读源码。
func _register_shared_domains() -> void:
	# MCPLogTools / MCPDevTools 不在此注册工具(get_logs / eval_code 等在游戏侧域注册)。
	_mod("MCPValidateTools").register(_add_tool)
	_mod("MCPFileTools").register(_add_tool)
	_mod("MCPCodeIndex").register(_add_tool)


## 注册**编辑器专属**的域与工具(依赖 EditorInterface / 编辑器会话), 不进导出包解析图。
func _register_editor_only_domains() -> void:
	_register_scene_tools()
	_register_project_tools()
	# restart_editor / script_status(依赖编辑器类); eval_code 留在导出安全的 MCPDevTools 里。
	_mod("MCPDevToolsEditor").register(_add_tool)
	_mod("MCPResourceTools").register(_add_tool)
	# 运维域(游戏运行/重建注册表/构建原生扩展)与多实例域, 只提供工具表, 状态由宿主经 bind 注入。
	for t in _mod("MCPDevActions").tools():
		_add_tool(t["name"], t["desc"], t["schema"], t["handler"])
	for t in _mod("MCPInstanceTools").tools():
		_add_tool(t["name"], t["desc"], t["schema"], t["handler"])


## eval 运行上下文(见 _register_shared_domains)。方法引用即 Callable, 避免三处各写一份 lambda。
func _eval_ctx_provider() -> Dictionary:
	return {"mode": _mode, "game_started_at": _game_started_at, "logger": _logger}


## 会话事实(get_project_info / get_editor_activity 用), 现取现用。
func _session_facts_provider() -> Dictionary:
	var facts := {
		"mcp_running": is_running(),
		"game_running": _has_game_session(),
		"bridge_ready": _has_game_session() and _game_ready,
		# 断点暂停是**必须能看见**的状态: 游戏在跑但主循环停摆, 依赖帧的工具都会挂起。
		"game_breaked": _has_game_session() and debugger_plugin != null and debugger_plugin.is_breaked(),
	}
	# 多实例身份随会话事实一起报, 否则多开时两个项目的 basic 段除 project_name 完全一样。
	if _hub != null:
		facts["instance_id"] = _hub.own_instance_id
		facts["instance_role"] = "hub" if bool(_hub.hub_mode) else "member"
		facts["mcp_port"] = listening_port()
		if not bool(_hub.hub_mode):
			facts["instance_note"] = "本实例不是中枢: 端口 %d 是系统分配的临时端口, 客户端应连中枢的固定端口 %d/mcp" % [listening_port(), _hub_port]
	return facts


## 注册项目侧 provider(见 SETTING_PROVIDERS): 加载脚本, 调其 `static register(add_tool, ctx)`。
## ctx 携带契约工厂 {"schema": MCPToolContract, "result": MCPResult} —— provider 别再按路径 load 框架内部文件:
## 那层绑定在契约改名/合并时不会报错, 只会让 provider 静默不注册(tools/list 安静地少掉它的工具)。
## 老 provider 只收一个参数, 按方法签名自适应。
## 没有运行的游戏时也必须可用; 需要操作"正在运行的游戏"的项目工具应改用脚本 + eval_code(process=game)。
func _register_providers() -> void:
	# 资源注册表与服务器说明都随每轮工具注册一起重建(与 _reset_tools 同节奏), 避免残留。
	var docs: Variant = _mod("MCPResourceDocs")
	docs.clear()
	# 内置长文(工具描述里按 devframework://docs/... 引用)。必须在 clear 之后注册,
	# 否则会被清掉; 放在 provider 之前, 让 provider 同 uri 时能覆盖内置版本。
	docs.register_builtin()
	_provider_instructions = []
	var paths: Variant = ProjectSettings.get_setting(SETTING_PROVIDERS, PackedStringArray())
	if not (paths is Array or paths is PackedStringArray):
		return
	# tool_kinds 是能力标记: 老版 provider 只收 add_tool 一个参数, 不看它;
	# 新版据此决定要不要给 add_tool 多传第 5 个参数(分类), 避免在老版框架上报参数过多。
	var ctx := {"schema": _mod("MCPToolContract"), "result": _mod("MCPResult"), "tool_kinds": true}
	for p in paths:
		var path := str(p).strip_edges()
		if path.is_empty():
			continue
		var script: Variant = _script_from_disk(path)
		if script == null or not (script is GDScript):
			push_warning("[MCP] provider 脚本无效: %s" % path)
			continue
		if script.has_method("register"):
			var before := _tool_handlers.size()
			if _provider_register_takes_ctx(script):
				script.register(_add_tool, ctx)
			else:
				script.register(_add_tool)
			# 注册 0 个工具基本都不是"这个 provider 本来就没工具", 而是它依赖的契约/条件没满足。
			# 静默是本域最贵的失败模式(要到调用时才撞 Unknown tool), 所以这里升级成告警。
			if _tool_handlers.size() == before:
				push_warning("[MCP] provider 注册了 0 个工具: %s —— 检查它的 register() 是否因契约缺失/条件不满足而提前返回" % path)
		if script.has_method("resources"):
			docs.register(script.resources())
		if script.has_method("instructions"):
			var line := str(script.instructions()).strip_edges()
			if not line.is_empty():
				_provider_instructions.append(line)
		if not script.has_method("register") and not script.has_method("resources") and not script.has_method("instructions"):
			push_warning("[MCP] provider 脚本既无 static register(add_tool) / resources() / instructions(): %s" % path)


## provider 的 register 是否收第二个 ctx 参数(新协议)。只看签名, 不靠"有没有默认值"猜。
func _provider_register_takes_ctx(script: Variant) -> bool:
	if not (script is GDScript) or not script.has_script_method("register"):
		return false
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == "register":
			var args: Variant = m.get("args", [])
			return args is Array and (args as Array).size() >= 2
	return false


## ======= 契约自检 =======
## 全部工具都是手写注册, 而协议层的失败模式**全部是静默的**, 故必须有。
func _audit_tools() -> void:
	# 自检规则本身在 MCPToolAudit 里; 这里只负责喂数据 + 报结果。
	# 不做"名单里的工具名是否都已注册"的反向校验: 分模式注册会被误报成名单未同步。
	# extra_scripts: provider 脚本在 MCP 目录之外, 须并入源码扫描, 否则其 handler 切不到。
	var provider_paths: Variant = ProjectSettings.get_setting(SETTING_PROVIDERS, PackedStringArray())
	var extra: Array = Array(provider_paths) if (provider_paths is Array or provider_paths is PackedStringArray) else []
	_tool_audit_issues = _mod("MCPToolAudit").audit_tools(_tool_defs, _tool_handlers, get_script().resource_path, _tool_audit_handlers, _mode == MODE_EDITOR, extra, _tool_kinds)
	# 自检通过是常态, 静默即可; 只在发现问题时报警, 否则每次启动都要宣告一遍"没问题"。
	if not _tool_audit_issues.is_empty():
		LogTool.log("MCP", "工具契约自检发现 %d 个问题:\n  - %s" % [_tool_audit_issues.size(), "\n  - ".join(_tool_audit_issues)])


## ------- 工具实现 =======

func _register_scene_tools() -> void:
	_mod("MCPSceneTools").register(_add_tool)


## -- 项目信息 --
## 注入 provider 且**现取现用**(不拍快照): 用户随时启停游戏, 快照会过期。
func _register_project_tools() -> void:
	var project_tools: Variant = _mod("MCPProjectTools")
	project_tools.set_session_facts_provider(_session_facts_provider)
	project_tools.register(_add_tool)


## ======= MCP 协议处理 =======

func _on_request(method: String, path: String, query: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	_transport().on_request(method, path, query, headers, body, stream)


## GET /mcp → 开启旧式 HTTP+SSE 会话。
## 必须真的把流开出来: 回 405 时旧客户端会直接放弃, 一次 POST 都不发。
func _serve_sse(stream, headers: Dictionary) -> void:
	_transport()._serve_sse(stream, headers)


## SSE 响应头(语义不同于一次 JSON-RPC 往返的 _cors_headers)。
func _sse_headers(headers: Dictionary) -> Dictionary:
	return _transport()._sse_headers(headers)


## 通告给旧式客户端的 POST 地址。用绝对 URL: 部分旧客户端不会相对 SSE 的 URL 解析。
func _endpoint_url() -> String:
	return _transport()._endpoint_url()


## CORS 响应头
func _cors_headers(headers: Dictionary) -> Dictionary:
	return _transport()._cors_headers(headers)


func _make_session_id(headers: Dictionary) -> String:
	return _transport()._make_session_id(headers)


## 协议版本协商: 回一个"客户端大概率也认识"的版本。
static func _negotiate_version(requested: String) -> String:
	if requested.is_empty():
		return PROTOCOL_VERSION
	if SUPPORTED_PROTOCOL_VERSIONS.has(requested):
		return requested
	for v in SUPPORTED_PROTOCOL_VERSIONS: # 已按新→旧排序
		if v < requested:
			return v
	return SUPPORTED_PROTOCOL_VERSIONS[SUPPORTED_PROTOCOL_VERSIONS.size() - 1]


## 处理一条 JSON-RPC 请求(MCP), 返回响应字典。proto 只影响**响应形状**
## (2026-07-28 起 result 必须带 resultType, 可缓存结果还必须带 ttlMs + cacheScope)。
func _handle_jsonrpc(req: Dictionary, proto: String = PROTOCOL_VERSION) -> Dictionary:
	var req_id: Variant = req.get("id", null)
	if req_id == null:
		return {}
	# JSON 数字经 JSON.parse_string 一律变 float, 回包会成 {"id":777.0}, 严格客户端认不出。
	# 整数值的 float 收回 int, 非整数 id 原样回。
	if req_id is float and float(int(req_id)) == float(req_id):
		req_id = int(req_id)

	var method: String = req.get("method", "")
	match method:
		"initialize":
			var client_info := ""
			var requested_proto := ""
			var params0: Variant = req.get("params", {})
			if params0 is Dictionary:
				var ci: Variant = params0.get("clientInfo", null)
				if ci is Dictionary:
					client_info = "%s v%s" % [ci.get("name", "unknown"), ci.get("version", "?")]
				requested_proto = str(params0.get("protocolVersion", ""))
			# 版本回显而非强推: initialize 的语义是"就客户端提出的版本达成一致"。
			var agreed := _negotiate_version(requested_proto)
			if not requested_proto.is_empty() and agreed != requested_proto:
				# 标明是**请求体**声明的版本; 外层 _on_request 还会就协议头/_meta 的版本另行判定。
				LogTool.log("MCP", "initialize 请求体声明的版本 %s 不受支持, 协商降级为 %s (支持: %s)" % [requested_proto, agreed, str(SUPPORTED_PROTOCOL_VERSIONS)])
			LogTool.log("MCP", "客户端初始化: %s (协议: %s -> %s)" % [client_info, requested_proto, agreed])
			# 能力协商(声明工具列表变更通知与日志能力)
			return {
				"jsonrpc": "2.0",
				"id": req_id,
				"result": {
					"protocolVersion": agreed,
					"capabilities": _server_capabilities(),
					"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
					"instructions": _server_instructions(),
				},
			}
		"notifications/initialized":
			return {}
		# 2026-07-28 起客户端可在发其他请求前探知服务端支持的版本(服务端 MUST)。
		"server/discover":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result({
				"protocolVersions": SUPPORTED_PROTOCOL_VERSIONS,
				"protocolVersion": proto,
				"capabilities": _server_capabilities(),
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
				"instructions": _server_instructions(),
			}, proto)}
		"tools/list":
			# ttlMs/cacheScope 让客户端缓存这份清单, 而不必每次重拉(进程生命周期内静态)。
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"tools": _hub_tools_for_list()}, proto, true)}
		"tools/call":
			var params: Variant = req.get("params", {})
			var params_dict: Dictionary = params if params is Dictionary else {}
			var tool_name: String = str(params_dict.get("name", ""))
			# 参数类型防护: 非对象的 arguments 直接回无效参数, 而非触发类型错误导致响应挂起。
			var raw_args: Variant = params_dict.get("arguments", {})
			var arguments: Dictionary = raw_args if raw_args is Dictionary else {}
			if not (raw_args is Dictionary):
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "Invalid params: 'arguments' must be an object: %s" % str(raw_args))
			# 入参日志与结果日志同开关(dev_framework/mcp/log_tool_results)。
			if ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
				# 参数截断: eval_code 传的是代码正文(上限 8192 字符), 整段打进日志会撑爆日志。
				var arg_log := str(arguments)
				if arg_log.length() > 300:
					arg_log = arg_log.left(300) + ("…(已截断, 共 %d 字符)" % arg_log.length())
				LogTool.log("MCP", "工具调用(%s): %s, 参数: %s" % [_mode, tool_name, arg_log])
			if not _tool_handlers.has(tool_name):
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "Unknown tool: %s" % tool_name)
			# 多实例路由: 目标不是本实例时, 把整条请求**原样转发**到目标实例的 MCP 端点。
			var route := _resolve_route(tool_name, arguments)
			if not str(route.get("error", "")).is_empty():
				return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(
					_err_validation(str(route.get("error")), str(route.get("recovery", ""))))}
			if int(route.get("port", 0)) > 0:
				return await _forward_call(req, req_id, tool_name, route, proto)
			# 本实例执行: 摘掉只在路由层有意义的 instance 参数, 不让它进 handler 与日志。
			if not MCPRouter.HUB_TOOLS.has(tool_name):
				arguments.erase("instance")
			# 入参校验: 拦在 handler **之前**(handler 内的 VariantTool 为健壮而非诚实)。
			var arg_issues := MCPToolContract.check(_tool_schemas.get(tool_name, {}), arguments)
			if not arg_issues.is_empty():
				return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(_err_validation(
					"参数校验未通过 (%d 项):\n- %s" % [arg_issues.size(), "\n- ".join(arg_issues)],
					"按上述提示修正后重试; 每个参数的合法取值见 tools/list 里该工具的 inputSchema(enum/required)与 description"))}
			# 安全执行: 隔离 handler 运行期错误 —— GDScript 无 try/catch, 协程中止则响应永不发出。
			var result := await _safe_call_handler(_tool_handlers[tool_name], arguments)
			# 统一输出上限: 超限转明确错误提示, 避免巨型响应撑爆上下文。
			result = MCPFormat.enforce_output_cap(tool_name, result, _output_cap())
			if result.is_empty():
				return _jsonrpc_error(req_id, ERR_INTERNAL, "Internal error: 工具执行未返回结果")
			# 记日志便于诊断"返回异常/空"; 必须在剥离 text/is_error **之前**记, 摘要读的就是这两个字段。
			_log_tool_result(tool_name, result)
			# 盖章: 带上"本次在哪个项目执行"(多实例下最难查的是执行在了别的项目)。
			result = _stamp_target(result)
			# 出协议边界: 剥掉仅供进程内使用的 text / is_error —— 它们与 content[0].text 重复。
			# 详见 MCPResult.for_protocol。
			return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(result)}
		# resources: 静态文档入口(内嵌内容)。短连接架构发不出推送。
		# 注意 resources/read 的成功与失败**都**放在 result 里(失败时带 isError + content)。
		"resources/list":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"resources": _mod("MCPResourceDocs").list_all()}, proto, true)}
		"resources/read":
			var rparams: Variant = req.get("params", {})
			var rdict: Dictionary = rparams if rparams is Dictionary else {}
			# 成功与失败都在 result 里(失败时是 _err_validation, 自带 content+isError)。
			return {"jsonrpc": "2.0", "id": req_id,
				"result": _decorate_result(MCPResult.for_protocol(_mod("MCPResourceDocs").read(str(rdict.get("uri", "")))), proto, true)}
		"ping":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		# 不做分级过滤(那要贯穿整条日志管线), 但级别取值必须校验并如实回 applied=false。
		"logging/setLevel":
			var lparams: Variant = req.get("params", {})
			var ldict: Dictionary = lparams if lparams is Dictionary else {}
			var level := str(ldict.get("level", "info"))
			if level not in ["debug", "info", "warning", "error"]:
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "level 无效: %s (可选: debug/info/warning/error)" % level)
			return {"jsonrpc": "2.0", "id": req_id, "result": {
				"ok": true,
				"level": level,
				"applied": false,
				"note": "已记录 level=" + level + ", 但本服务器当前不按级别过滤日志, 日志仍会全部保留。控制日志量请用 get_logs 的 since(增量)/max(限量)/contains(过滤)。",
			}}
		_:
			return _jsonrpc_error(req_id, ERR_METHOD_NOT_FOUND, "Method not found: %s" % method)


func _jsonrpc_error(req_id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


## ======= 多实例: tools/list 整形与路由 =======
## 这三处(本节 + _hub_tools_for_list / _resolve_route / _serve_hub_path)的**唯一**前置条件是
##   · 编辑器进程        → _hub 非 null, 多实例全功能可用;
##   · F5 游戏进程       → _hub 为 null(走调试线分支, 不开端口), 不注入、不路由;
##   · 导出包/独立运行   → _hub 为 null(见 _start_runtime_server), 同上;

## tools/list 的出口整形：交给路由层（每个工具多一个可选 `instance` 参数）。
func _hub_tools_for_list() -> Array:
	return _router().tools_for_list(_tool_defs)


## 路由模块的唯一入口（懒创建：它要回指本服务器）。
func _router():
	if _router_obj == null:
		_router_obj = MCPRouter.new(self)
	return _router_obj


## 运行时（游戏进程）模块的唯一入口（懒创建：它要回指本服务器）。
func _runtime():
	if _runtime_obj == null:
		_runtime_obj = MCPRuntime.new(self)
	return _runtime_obj


## 传输层模块的唯一入口（懒创建）。
func _transport():
	if _transport_obj == null:
		_transport_obj = MCPTransport.new(self)
	return _transport_obj


## 本服务器是否跑在编辑器进程（常量不在实例上，模块需要这个判据）。
func is_editor_mode() -> bool:
	return _mode == MODE_EDITOR


## 解析本条 tools/call 该由谁执行（优先级与失败策略见 MCPRouter）。
func _resolve_route(tool_name: String, args: Dictionary) -> Dictionary:
	return _router().resolve_route(tool_name, args)


## 转发一条 tools/call 到目标实例，返回可直接回给客户端的 JSON-RPC 响应。
func _forward_call(req: Dictionary, req_id: Variant, tool_name: String, route: Dictionary, proto: String) -> Dictionary:
	return await _router().forward(req, req_id, tool_name, route, proto, _PROXY_RESPONSE_MARGIN_MS)


## ======= 多实例: /hub/* 内部端点 =======

## 实例间内部端点。只有中枢应答; 成员收到时回 404 并说明原因(便于诊断"客户端配错了端口")。
## 本机任何进程塞一个好端口就能把后续的工具调用导向自己 —— 在有 token 的部署里必须同样受管。
func _serve_hub_path(method: String, path: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	if not token.is_empty():
		if str(headers.get("authorization", "")) != "Bearer " + token:
			_http.send_response(stream, 401, _cors_headers(headers), "{\"ok\":false,\"error\":\"Unauthorized\"}")
			return
	if _hub == null or not bool(_hub.hub_mode):
		_http.send_response(stream, 404, _cors_headers(headers),
			"{\"ok\":false,\"error\":\"本实例不是中枢(hub_mode=false); /hub/* 端点只在中枢上可用。若你在配置里写死了端口, 请改成中枢所在实例。\"}")
		return
	var rpc_body := {}
	if not body.is_empty():
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary:
			rpc_body = parsed
	var res: Dictionary = _hub.handle(method, path, rpc_body)
	_http.send_response(stream, int(res.get("status", 500)), _cors_headers(headers), JSON.stringify(res.get("body", {})))


## HTTP 层直接回 JSON-RPC 错误的**唯一出口**。
## 协议边界必须单一收口(必须经 MCPFormat.json_safe), 否则往 json_safe 加规则时会整类漏掉。
## 本函数直接发出 HTTP 响应, 服务于"还没进 JSON-RPC 就必须拒绝"的场景(方法/鉴权/版本)。
func _send_rpc_error(stream, status: int, req_headers: Dictionary, req_id: Variant, code: int, message: String, data: Dictionary = {}, extra_headers: Dictionary = {}) -> void:
	var hdrs := _cors_headers(req_headers)
	for k in extra_headers:
		hdrs[k] = extra_headers[k]
	# data 仅在非空时才出现。规范原文是"客户端需要结构化信息时放在 data"。
	var err_obj := {"code": code, "message": message}
	if not data.is_empty():
		err_obj["data"] = data
	_http.send_response(stream, status, hdrs, MCPFormat.json_safe(JSON.stringify({
		"jsonrpc": "2.0", "id": req_id, "error": err_obj,
	})))


## 服务端能力声明。initialize 与 server/discover 共用 —— 同一份事实写两处。
func _server_capabilities() -> Dictionary:
	return {
		# 工具清单在进程生命周期内静态(_tool_defs 只在初始化时填), 且本服务器发不出 listChanged 通知。
		"tools": {"listChanged": false},
		# resources 只读静态文档, 无订阅能力(短连接发不出推送), 清单也是静态的。
		"resources": {"subscribe": false, "listChanged": false},
		# 旧日志级别机制: 2026-07-28 起通知侧已废弃(SEP-2577), 级别改由每请求声明。
		"logging": {"supportedLevels": ["debug", "info", "warning", "error"]},
	}


## 服务器级 instructions(BASE + 项目 provider 追加)。initialize / server:discover 都发它。
func _server_instructions() -> String:
	var parts: Array[String] = []
	if not BASE_INSTRUCTIONS.is_empty():
		parts.append(BASE_INSTRUCTIONS)
	parts.append_array(_provider_instructions)
	return "\n".join(parts)


## 按协商到的协议版本给 result 补新版必需字段。
## 2026-07-28 起 Result 必须带 resultType(客户端见到缺省会当 "complete" 处理, 但那是
## 兼容旧服务端的兜底, 不该由新服务端依赖); 可缓存结果还必须带 ttlMs + cacheScope。
func _decorate_result(result: Dictionary, proto: String, cacheable := false) -> Dictionary:
	if proto != SUPPORTED_PROTOCOL_VERSIONS[0]:
		return result
	result["resultType"] = "complete"
	if cacheable:
		result["ttlMs"] = LIST_TTL_MS
		result["cacheScope"] = "public"
	return result


## 给 tools/call 的结果盖上"本次在哪个项目执行"的章。
func _stamp_target(result: Dictionary) -> Dictionary:
	if _hub == null:
		return result
	return _router().stamp(result, str(_hub.own_instance_id), str(_hub.own_project_path),
			"hub" if bool(_hub.hub_mode) else "member")


## 安全执行工具 handler: 比对执行前后的错误缓冲, 把运行期错误转成结构化诊断附加到结果。
## GDScript 无 try/catch, handler 内的硬错误仍会使 await 协程中止, 这一点拦不住。
func _safe_call_handler(handler: Callable, arguments: Dictionary) -> Dictionary:
	var err_before: int = _logger.get_error_cursor() if _logger else 0
	var result: Variant = await handler.call(arguments)
	if not (result is Dictionary):
		return {}
	if _logger and _logger.get_error_count() > err_before:
		var outcome := _collect_runtime_error(err_before)
		# 全部命中忽略模式(如 UID 缓存重建期的噪音)时不附加诊断: 模式表与判定都在 MCPDevTools
		# (含编辑器引用, 导出包不加载) —— 只在编辑器构建里做忽略判定, 否则直接附加诊断。
		if _is_editor_build():
			var dev_tools: Variant = _mod("MCPDevTools")
			if dev_tools.is_all_ignored(outcome, dev_tools.get_ignored_error_patterns()):
				return result
		var base: Dictionary = result
		var new_text := str(base.get("text", "")) + "\n[警告] 执行过程中捕获运行期错误:\n%s" % outcome
		base["text"] = new_text
		# 同步更新 MCP 标准 content 数组, 保证官方 SDK 客户端也能看到诊断信息
		if base.get("content") is Array and not base["content"].is_empty() and base["content"][0] is Dictionary:
			base["content"][0]["text"] = new_text
	return result


## 自 err_before 起最新的运行期错误条目, 组成诊断文本。
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


## 实时读统一输出上限(设置改动免重启生效)。截断实现在 MCPFormat。
func _output_cap() -> int:
	return int(ProjectSettings.get_setting(SETTING_MAX_OUTPUT_CHARS, DEFAULT_MAX_OUTPUT_CHARS))


## 记录工具调用结果到 MCP 日志。成功路径默认不打, 由 log_tool_results 开关。
func _log_tool_result(tool_name: String, result: Dictionary) -> void:
	var text: String = str(result.get("text", ""))
	var is_err: bool = result.get("is_error", false)
	if is_err:
		# 用 error 级别而非 log: LogTool 的 ERROR 不受 enabled 开关与 tag 忽略影响,
		# 否则关掉 MCP 日志后工具错误会被一并吞掉。
		LogTool.error("MCP", "[%s] %s 错误: %s" % [_mode, tool_name, text.left(400)])
		return
	if not ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
		return
	# 打全文还是打结构摘要(顶层键 + 数组/字典计数)只按**长度**判, 不按工具名维护名单。
	const SUMMARY_THRESHOLD := 600
	const INLINE_LIMIT := 400
	var head := "[%s] %s 返回: " % [_mode, tool_name]
	if text.length() > SUMMARY_THRESHOLD:
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
		LogTool.log("MCP", "%s%s" % [head, text.left(INLINE_LIMIT)])


## ======= 结果封装(薄转发, 实现在 MCPResult) =======
## 分类常量请写 MCPResult.CAT_*。


func _wrap(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	return MCPResult.make(text, is_error, extra, content_text)


func _ok(text: String) -> Dictionary:
	return MCPResult.ok(text)


func _fail(text: String) -> Dictionary:
	return MCPResult.fail(text)


func _ok_json(data: Dictionary) -> Dictionary:
	return MCPResult.ok_json(data)


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。
## 故意不转发 CAT_STALE_CODE: 它唯一的用法在新鲜度守卫里, 不摆没人调用的空壳。
func _err_validation(text: String, recovery: String) -> Dictionary:
	return MCPResult.err_validation(text, recovery)


func _err_transient(text: String, recovery: String) -> Dictionary:
	return MCPResult.err_transient(text, recovery)


func _err_game_stopped(text: String, recovery: String) -> Dictionary:
	return MCPResult.err_game_stopped(text, recovery)


func _err_game_breaked(text: String, recovery: String = "") -> Dictionary:
	return MCPResult.err_game_breaked(text, recovery)


func _err_internal(text: String, recovery: String = "") -> Dictionary:
	return MCPResult.err_internal(text, recovery)


## 底层结构化错误封装。category 取值见 MCPResult.CAT_*; retryable 由语义化封装固化。
func _err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	return MCPResult.err(text, category, retryable, recovery)


## ======= 统一入参读取: 一律走 VariantTool =======
## 需要值级转换时用 as_*(或 infer / coerce)。规则与坑位说明的唯一事实来源是 VariantTool 顶部。
## 两处合法的裸读(不要当漂移收掉): 约定而非守卫 —— 契约自检只校验 VariantTool 的写法。


## 编辑器模式且游戏调试线活跃(指向游戏进程的数据/操作要走代理)。
func _has_game_session() -> bool:
	return _runtime()._has_game_session()


## 读必填的 process 参数(editor|game), 非法值落到空串, 由调用方报错。
func _require_process(args: Dictionary) -> String:
	var p := VariantTool.get_string(args, "process")
	return p if p == "editor" or p == "game" else ""


## 记录"脚本新鲜度基准"的当前时刻(见 MCPScriptSync.guard_eval)。
func _mark_script_baseline(reason: String) -> void:
	_runtime().mark_script_baseline(reason)


## 编辑器进程: 把截图请求交给运行时模块(它决定就地拍还是转去游戏)。
func _call_take_screenshot(args: Dictionary) -> Dictionary:
	return await _runtime().call_take_screenshot(args)


## ======= 运行时工具(游戏进程内原生执行) =======

## 非编辑器(导出包/独立运行)进程的工具注册: 共享域 + 游戏操作宿主工具。
func _register_runtime_domains() -> void:
	_reset_tools()
	_register_shared_domains()
	_register_game_play_tools()
	_register_providers()
	_audit_tools()


## 注册"游戏操作宿主工具"(截图 / UI 交互 / 日志 / 用例 / eval)。三个调用场景:
##   · 编辑器进程: _register_editor_tools 追加在编辑工具之后;
##   · 开发期游戏进程(F5): _ready 里注册(供调试线 eval_code 用);
##   · 导出/独立运行: _register_runtime_domains 里注册。
func _register_game_play_tools() -> void:
	# 仅首次进入时清空: 编辑器进程已由 _register_editor_tools 注册过编辑/项目工具,
	# 这里只能追加, reset 会清掉前面分组的注册。
	if _tool_handlers.is_empty():
		_reset_tools()
	# 绑定日志捕获器: get_logs / clear_logs 复用 MCPLogTools 的底层件。server 侧用的是
	# preload 实例, 故必须绑这个对象而非 _mod 出的那份。
	MCPLogTools.bind_logger(_logger)
	# eval ctx provider: eval_code(process=game) 经 MCPDevTools.eval_code 取运行上下文。
	_mod("MCPDevTools").set_eval_ctx_provider(_eval_ctx_provider)
	# 输入模拟域(先查后点 + 等待条件): 整域一张表, 注册顺序即工具表顺序。
	for t in _mod("MCPSimulateTools").tools():
		_register_game_play_tool(t["name"], t["desc"], t["schema"], t["handler"])

	# take_screenshot 的 name/desc/schema 由 MCPScreenshotTools.spec() 单副本提供。
	var _shot_spec: Variant = _mod("MCPScreenshotTools").spec()
	_register_game_play_tool(_shot_spec["name"],
		_shot_spec["desc"],
		_shot_spec["schema"],
		_runtime_take_screenshot,
		_call_take_screenshot)

	# eval_code: 统一入口, process 必填。编辑器进程里 editor=本进程、game=转发; 运行时只有 game。
	var eval_schema := {
		"type": "object",
		"properties": {
			"process": {"type": "string", "enum": ["editor", "game"], "description": "在哪个进程执行: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。"},
			"code": MCPToolContract.code_arg(),
			"timeout_ms": MCPToolContract.code_timeout_arg(),
			"auto_resume": {"type": "boolean", "description": "仅 process=game 有意义: 游戏断点暂停时先 game_control(action=continue) 再执行(默认 false)。"},
			"allow_stale": {"type": "boolean", "description": "跳过脚本新鲜度闸门，允许在'磁盘已改、进程仍是旧代码'时执行。仅供只读排查；写操作不要用。默认 false。"},
		},
		"required": ["process"],
	}
	_register_game_play_tool("eval_code",
		"执行一段 GDScript(方法体, 缩进由服务器处理; 可 return, 支持 await)。process 必填: editor=编辑器进程; game=游戏进程(需游戏在跑)。**【副作用】执行任意代码, 不可自动重试; 纯观测优先用专用只读工具。** 节点路径用 /root/...。改过 .gd 后 game 侧可能报 stale_code。详见 resources: devframework://docs/eval_code",
		eval_schema,
		_call_eval_code_local,
		_call_eval_code_routed)

	# 会话域(用例/job/性能/日志): 同一张表在两个进程都注册, 进程差异收在域内。
	# 两个进程都用同一个 handler, 不能留空让宿主套上"转发到游戏"的默认包装。
	for t in _mod("MCPSessionTools").tools():
		_register_game_play_tool(t["name"], t["desc"], t["schema"], t["handler"], t["handler"])
	# 游戏进程只走本函数(编辑器走 start_editor), 域不绑就会在 _runtime_provider.call() 上空调用崩溃。
	# 必须在 _reset_tools() 之后: 它清 _mod_cache, 重编译出的域实例会丢掉静态 bind。
	_bind_domains()

## ======= 运行时: 游戏进程用例(依赖项目单例 / 场景树 / 真实时间轴) =======

## 运行中的测试标志: run_tests(process=game) 执行期间为 true, 供 _call_runtime_tool_async 判断。
var _game_tests_running := false


## 运行时: 捕获游戏视口真实截图(文件名自动生成)
func _runtime_take_screenshot(args: Dictionary) -> Dictionary:
	var filename := ScreenshotTool.make_filename("mcp")
	var dir_path := "user://mcp_screenshots"
	var viewport := get_viewport()
	if viewport == null:
		return _fail("无法获取游戏视口")
	# 统一走 ScreenshotTool: 取图 -> 颜色处理(auto) -> 缩放 -> 保存。
	var shot_opts := {
		"path": "%s/%s" % [dir_path, filename],
		"max_width": VariantTool.get_int(args, "max_width", ScreenshotTool.DEFAULT_MAX_WIDTH),
		"capture_type": "game",
	}
	shot_opts.merge(_mod("MCPScreenshotTools").color_opts(args))
	var shot: Dictionary = await ScreenshotTool.capture(viewport, shot_opts)
	if not shot.get("ok", false):
		return _fail(str(shot.get("error", "截图失败")))
	var img_w := int(shot.get("width", 0))
	var img_h := int(shot.get("height", 0))
	var result: Dictionary = {
		"path": shot.get("path", ""),
		"res_path": shot.get("res_path", ""),
		"width": img_w,
		"height": img_h,
		"bytes": int(shot.get("bytes", 0)),
		"capture_type": "game",
		"color_mode": str(shot.get("color_mode", "")),
	}
	# 直接把像素放进 content: 只回路径时调用方还得再读一次图才看得见画面。
	return _mod("MCPResult").attach_image(_ok_json(result), str(shot.get("path", "")))


## ======= 编辑器模式的运行时工具转发(经 EngineDebugger 调试线) =======

## 编辑器进程: 解除游戏断点暂停(等效编辑器的 Continue 按钮)。
func _call_debug_continue(_args: Dictionary) -> Dictionary:
	if not _has_game_session():
		return _fail("没有运行中的游戏, 无需继续")
	if not debugger_plugin.is_breaked():
		return _ok("游戏当前未处于断点暂停状态, 无需继续")
	if debugger_plugin.debug_continue():
		_game_breaked = false
		return _ok("已让游戏继续运行(解除断点暂停)")
	return _err_internal("无法解除断点暂停", "尝试 game_control(action=stop) 后 game_control(action=start) 重启")


## 读游戏调用单次等待上限并裁剪边界(实时读取, 改设置无需重启)。
func _game_call_timeout_ms() -> int:
	return clampi(int(ProjectSettings.get_setting(SETTING_GAME_CALL_TIMEOUT_MS, DEFAULT_GAME_CALL_TIMEOUT_MS)), 2000, 600000)


## 转发工具调用到游戏进程(经 EngineDebugger 调试线)。仅编辑器模式。
func _call_runtime_proxy(tool_name: String, args: Dictionary) -> Dictionary:
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		return _err_game_stopped(_with_game_error("游戏未运行。请先使用 game_control(action=start) 启动游戏"),
			"调用 game_control(action=start) 启动游戏, 等待调试线就绪后重试")
	if _game_breaked and tool_name == "get_logs" and not _game_error_digest.is_empty() \
			and VariantTool.get_string(args, "kind", "log") == "error":
		# 断点期间主循环停摆, 请求式 get_logs 收不到响应: 直接给推上来的错误副本。
		return MCPResult.ok_json({count = _game_error_digest.size(), errors = _game_error_digest,
			source = "game_digest"})
	if _game_breaked and not _BREAK_SAFE_TOOLS.has(tool_name):
		# 断点暂停: 依赖主循环的工具必然挂起; get_logs/clear_logs(process=game) 仍可用。
		var diagnose := await _fetch_recent_game_error(tool_name)
		if diagnose != "":
			return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n已自动读取错误:\n%s\n\n修正脚本后 game_control(action=continue) 继续, 或 game_control(action=stop) 重启。" %
				[tool_name, diagnose])
		return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n错误缓冲无内容(可能是手动断点)。get_logs(process=game,kind=error)复核后 game_control(action=continue), 或 game_control(action=stop) 重启。" %
			tool_name, "get_logs(process=game,kind=error)复核后game_control(action=continue); 或game_control(action=stop)修复重启")
	if not _game_ready:
		# 启动期编译错误会让桥接永远不 ready, 那时只能靠编辑器侧的编译失败记录说明原因。
		if _describe_game_error() != "":
			return _err_validation(_with_game_error("游戏调试线未就绪(启动期大概率有脚本错误)。"),
				"修正上方脚本错误后 game_control(action=stop), 再 game_control(action=start) 重启")
		return _err_transient("游戏调试线尚未就绪", "等待游戏启动完成(可稍后重试, 或 game_control(action=start) 重启)")
	var req_id := _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	debugger_plugin.send_call(req_id, tool_name, args)
	# 轮询等待游戏响应。会话断开时 _on_session_stopped 会填充失败结果。
	var timeout_ms := _game_call_timeout_ms() + _PROXY_RESPONSE_MARGIN_MS
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if _pending.has(req_id) and _pending[req_id] != null:
			var result: Dictionary = _pending[req_id]
			_pending.erase(req_id)
			return _normalize_wire_result(result, tool_name)
		if not debugger_plugin.has_active_session():
			_pending.erase(req_id)
			return _err_game_stopped("游戏进程已停止/崩溃(工具 %s 请求被取消)。先 game_control(action=start) 重启。" % tool_name,
				"game_control(action=start)重启后重试")
		await get_tree().process_frame
	if _pending.has(req_id):
		_pending.erase(req_id)
	# 超时主因: eval 触发运行期错误致协程中止未回发, 或死循环。自动回查错误缓冲拼进响应。
	var diagnose := await _fetch_recent_game_error(tool_name)
	var secs := "%.1f" % (timeout_ms / 1000.0)
	if diagnose != "":
		# 原样重发必然再超时一次, 故 is_retryable=false。
		return _err_validation("游戏进程响应超时(%ss), 工具: %s。已发现运行期脚本错误:\n%s\n\n修正代码后重试; 若无疑错误仍超时再考虑死循环。" %
			[secs, tool_name, diagnose],
			"修正上方脚本错误后重试; 仍超时则 game_control(action=stop) 后 game_control(action=start) 重启")
	return _err("游戏进程响应超时(%ss), 工具: %s。错误缓冲无脚本错误, 可能是死循环/卡死或无响应。" % [secs, tool_name],
		MCPResult.CAT_TRANSIENT, true, "查 eval_code(process=game) 是否死循环; 必要时 game_control(action=stop) 后 game_control(action=start) 重启")


## 超时诊断: 回查游戏错误缓冲, 返回最近一条脚本错误描述(无则返回 "")。
func _fetch_recent_game_error(tool_name: String) -> String:
	# 断点暂停时主循环停着, 下面的调试线请求不会被处理 —— 先用推上来的错误副本。
	var pushed := _describe_game_error()
	if pushed != "":
		return pushed
	# 用内部 req_id 再发一次 get_logs(process=game, kind=error), 短超时避免二次挂起。
	var req_id := _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	if not debugger_plugin.send_call(req_id, "get_logs", {"process": "game", "kind": "error"}):
		return ""
	var deadline := Time.get_ticks_msec() + mini(5000, _game_call_timeout_ms())
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


## 给诊断文本补上"已捕获的错误"(没有则不追加)。三类提示共用同一份措辞。
func _with_game_error(text: String) -> String:
	var detail := _describe_game_error()
	return text + ("\n已捕获的错误:\n" + detail if detail != "" else "")


## 最近一条游戏进程错误的描述(没有则返回 ""): 优先用游戏实时推送的副本;
## 启动期编译错误来不及推, 回落到编辑器侧"脚本仍编译不出来"的记录。
func _describe_game_error() -> String:
	if not _game_error_digest.is_empty():
		var e: Dictionary = _game_error_digest[_game_error_digest.size() - 1]
		var file := str(e.get("file", ""))
		if file.is_empty():
			return "  错误: " + str(e.get("message", "")).strip_edges()
		return "  错误: %s\n  位置: %s:%s (函数: %s)" % [
			str(e.get("message", "")).strip_edges(), file,
			str(e.get("line", "?")), str(e.get("function", "?"))]
	return _editor_side_compile_error()


## 编辑器日志里最近一条"脚本当前仍编译不出来"的解析错误。
## 以"现在还能不能编译"为准, 避免把早已修好的旧错误翻出来。
func _editor_side_compile_error() -> String:
	if _logger == null:
		return ""
	var entries: Array = _logger.take_errors_since(0).get("entries", [])
	for i in range(entries.size() - 1, -1, -1):
		var e: Dictionary = entries[i]
		var msg := str(e.get("message", ""))
		if not (msg.begins_with("Parse Error") or msg.contains("Parser Error") or msg.contains("Failed to load script")):
			continue
		var path := str(e.get("file", ""))
		if path.begins_with("res://") and _script_still_broken(path):
			return "  错误: %s\n  位置: %s:%s" % [msg, path, str(e.get("line", "?"))]
	return ""


## 该脚本现在是否仍编译失败(坏脚本实例化不出来)。
func _script_still_broken(path: String) -> bool:
	var res := ResourceLoader.load(path)
	return res == null or (res is Script and not (res as Script).can_instantiate())


## 归一化来自游戏的 wire 结果, 保留结构化错误元数据供 AI 决策。
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
	# 保留来源侧的 content[].text(错误响应里是 _err 拼的结构化 JSON), 只归一化其余字段。
	var content_text := text
	var extra_blocks: Array = []
	if result.get("content") is Array:
		var c: Array = result["content"]
		if not c.is_empty() and c[0] is Dictionary:
			content_text = str(c[0].get("text", text))
		# 保留文本以外的内容块(截图/预览的 image): 只重建 content[0] 会把刚拍好的像素
		# 丢在转发路上。
		for i in range(1, c.size()):
			if c[i] is Dictionary and str(c[i].get("type", "")) != "text":
				extra_blocks.append(c[i])
	var wrapped := _wrap(text, is_err, extra, content_text)
	if not extra_blocks.is_empty():
		var out_content: Array = wrapped.get("content", [])
		out_content.append_array(extra_blocks)
		wrapped["content"] = out_content
	return wrapped


## eval_code 的 runtime 侧(服务器位于游戏进程内): process 只能是 game。
## **必须 await**: eval 含 await 时会挂起, 漏 await 会把协程句柄当结果返回。
func _call_eval_code_local(args: Dictionary) -> Dictionary:
	if _require_process(args) != "game":
		return _fail("导出运行时没有独立的编辑器进程; eval_code 的 process 只能是 'game'")
	return await _mod("MCPDevTools")._call_eval_code(args)


## eval_code 的 editor 侧: process=editor 就地执行, process=game 经预检 + 调试线转发。
## **必须 await**(同上), 否则客户端报 -32600。
func _call_eval_code_routed(args: Dictionary) -> Dictionary:
	if _require_process(args) == "game":
		return await _call_game_eval_proxy(args)
	return await _mod("MCPDevTools")._call_eval_code(args)


## 编辑器侧 eval_code(process=game) 的转发: 先本地预编译 + 静态检查, 通过后才发到游戏进程。
## 语法错误在编辑器内拦截, 避免污染游戏进程(运行时解析错误可能中断游戏)。
func _call_game_eval_proxy(args: Dictionary) -> Dictionary:
	var precheck: String = _mod("MCPDevTools").precheck_eval_code(VariantTool.get_string(args, "code"), _logger)
	if precheck != "":
		return _err_validation("eval_code(process=game) 被编辑器侧预检拦截: %s" % precheck, "修正代码后重新调用 eval_code(语法错误无法通过重试解决, 需修改代码)")
	# auto_resume: 调用方明确要求时先解除断点暂停再执行(默认不开, 避免掩盖真错误)。
	if VariantTool.get_bool(args, "auto_resume") and _game_breaked:
		var resumed := await _call_debug_continue({})
		if bool(resumed.get("is_error", false)):
			return resumed
	return await _call_runtime_proxy("eval_code", args)
