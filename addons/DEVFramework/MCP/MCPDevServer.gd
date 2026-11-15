@tool
## MCP 开发服务器(autoload 单例, 编辑器/游戏双角色)
##   - 编辑器进程(Engine.is_editor_hint): 由 plugin.gd 持有节点并 start_editor(),
##   - 游戏进程: 不开启任何端口, 注册 EngineDebugger 消息捕获器("dev_mcp"),
class_name MCPDevServer extends Node

## ------- 拆出的零状态协议层模块(preload, 非 class_name) -------
## 所以拆出去是安全的。引用方式上的两条硬约束, 都是踩坑换来的:
##   1. 三个模块**必须带 @tool**(与本文件一致)。
##   2. 引用必须用 preload 而不是 class_name: 本文件既是 autoload 又是被插件 load() 动态
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPRouter := preload("res://addons/DEVFramework/MCP/MCPRouter.gd")
const MCPRuntime := preload("res://addons/DEVFramework/MCP/MCPRuntime.gd")
const MCPTransport := preload("res://addons/DEVFramework/MCP/MCPTransport.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")
const MCPArgCheck := preload("res://addons/DEVFramework/MCP/MCPArgCheck.gd")
## 输出整形层(序列化转义兜底 + 统一输出上限截断)。与其它 preload 的区别: 它既不注册工具也不
const MCPFormat := preload("res://addons/DEVFramework/MCP/MCPFormat.gd")

## ------- 已拆出的子模块(同样靠 preload 常量引用, 均不声明 class_name) -------

## ------- 工具域文件 -------
## 下面这份表是**实测**的各域导出(不是设计意图), 新增域时按它补一行:
##   · const preload 只允许**零编辑器引用**的模块(下面这些);
##   · 任何含编辑器引用的模块(MCPEditorEnv / MCPDevTools / MCPProjectTools /
##   · 判据回归: 对本文件做 `Select-String "Editor[A-Z]"` 不应命中任何**代码行**(注释除外)。
const MCPCodeIndex := preload("res://addons/DEVFramework/MCP/MCPCodeIndex.gd")
const MCPFileTools := preload("res://addons/DEVFramework/MCP/MCPFileTools.gd")
const MCPLogTools := preload("res://addons/DEVFramework/MCP/MCPLogTools.gd")
const MCPUITools := preload("res://addons/DEVFramework/MCP/MCPUITools.gd")
const MCPValidateTools := preload("res://addons/DEVFramework/MCP/MCPValidateTools.gd")

## MCP 目录(域脚本都在这儿)。供 `_mod()` 按路径动态取用 + refresh 时批量换缓存。
const MCP_DIR := "res://addons/DEVFramework/MCP"

##   3. **域脚本(除本文件外)改动 → refresh_tools 即可, 无需重启**:
##      【为什么不能只重跑注册树】const preload 在**本文件编译期**就把常量绑成了当时那个
##      磁盘版本(均实测)。旧实现只重跑注册树, 因此"往域文件加一个工具"会**静默注册不上**,
##      为什么不能直接 reload 本文件: 本文件正承载着 HTTP 服务器(_http 字段), 原地重载会
##      自救**(restart_editor / refresh_tools 都调不到了), 只能去编辑器里重新启用插件。实测踩过。

## ------- 配置项(ProjectSettings) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_TOKEN := MCPTransport.SETTING_TOKEN
const SETTING_MAX_OUTPUT_CHARS := "dev_framework/mcp/max_output_chars"
const SETTING_LOG_TOOL_RESULTS := "dev_framework/mcp/log_tool_results"
## 游戏调用单次等待上限(毫秒): 编辑器等待游戏经调试线回包(_call_runtime_proxy), 以及
const SETTING_GAME_CALL_TIMEOUT_MS := "dev_framework/mcp/game_call_timeout_ms"
const DEFAULT_GAME_CALL_TIMEOUT_MS := 600000
## 代理 deadline 比"游戏侧等待"多留的余量: 游戏 handler 到点返回后, 结果要经调试线回到编辑器。
const _PROXY_RESPONSE_MARGIN_MS := 10000

## ------- 运行时服务器(导出包/独立运行)配置 -------
const SETTING_RUNTIME_ENABLED := "dev_framework/mcp/runtime_enabled"

## ------- 项目侧 provider(项目自定义 MCP 工具域) -------
const SETTING_PROVIDERS := "dev_framework/mcp/providers"

## ------- 多实例中枢(hub) -------
const SETTING_HUB := "dev_framework/mcp/hub"
const SETTING_HUB_PORT := "dev_framework/mcp/hub_port"
## 中枢端口默认值 —— **全机器唯一的通用端口**。项目一律不写 mcp/hub_port, 全部走这个默认值,
## 【这是一次**破坏性**变更】改这个值, 所有客户端的 MCP 配置 URL 必须同步改。故它只在
const DEFAULT_HUB_PORT := 9988

## 实例身份与中枢布局都由 MCPInstanceHub 负责(本文件只做接线)。这里只留脚本名,
const HUB_SCRIPT := "MCPInstanceHub"


## 统一输出上限默认值(字符)。超限则**截断**返回并附续读提示, 而非整条拒绝。
##      任何"数据不完整"的信号。原默认值 90000 高于它, 实测 get_scene_tree 无参调用返回
##      content[0].text(实测两者长度完全相同)。所以 24000 字符的正文在响应体里是 48000,
##      必须连双写一起算, 否则限了等于没限 —— 这也是先取 30000 时实测响应仍有 64797
const DEFAULT_MAX_OUTPUT_CHARS := 24000


## ------- MCP 常量 -------
const PROTOCOL_VERSION := MCPTransport.PROTOCOL_VERSION

## 支持的协议版本, 新到旧。用于 initialize 的版本回显与 -32022 的 supported 列表。
## 客户端各自锁定的日期不同(它声明什么, 我们就必须能接住)。规范里也写明服务端可以
## 但"支持多版本"**不等于为每版写一套实现** —— 差异其实只有一处: 新字段要不要发。
## 2025-06-18 在列表里但无行为差异(它与 2025-03-26 的唯一区别是 structuredContent,
const SUPPORTED_PROTOCOL_VERSIONS := MCPTransport.SUPPORTED_PROTOCOL_VERSIONS

## 2026-07-28 起, 版本改为**逐请求**声明, 且 HTTP 传输必须同时带同名头。
const META_VERSION_KEY := MCPTransport.META_VERSION_KEY
const META_CLIENT_CAPS_KEY := MCPTransport.META_CLIENT_CAPS_KEY
## 首个"逐请求声明版本"的协议版本。自该版本起规范要求每个请求的 _meta 同时声明
## protocolVersion 与 clientCapabilities, 缺任一即为 malformed request(必须回 -32602)。
## META_REQUIRED_SINCE 的请求生效**, 否则会把现有旧版客户端全部拒掉。
const META_REQUIRED_SINCE := MCPTransport.META_REQUIRED_SINCE
const HEADER_VERSION := MCPTransport.HEADER_VERSION

## ======= 错误码: 本文件唯一的错误码事实来源 =======
const ERR_PARSE := MCPTransport.ERR_PARSE
## JSON-RPC 层: 方法名不在 _handlers 里。
const ERR_METHOD_NOT_FOUND := -32601
## JSON-RPC 层: 参数结构/取值不合法(同参数重试无意义, 故不可重试)。
const ERR_INVALID_PARAMS := MCPTransport.ERR_INVALID_PARAMS
## JSON-RPC 层: 服务端内部状态异常(通常是 handler 未产出结果)。
const ERR_INTERNAL := -32603
## 传输层拒绝: 请求根本没进 JSON-RPC(方法不支持 / 鉴权失败 / Origin 被拦)。
const ERR_TRANSPORT_REJECTED := MCPTransport.ERR_TRANSPORT_REJECTED
## 2026-07-28 新增错误码(规范 baseline 里 -32000 段由 MCP 自用)。
const ERR_HEADER_MISMATCH := MCPTransport.ERR_HEADER_MISMATCH
## 协商完成后仍发来不受支持的版本。
const ERR_UNSUPPORTED_VERSION := MCPTransport.ERR_UNSUPPORTED_VERSION

## tools/list 等可缓存结果建议的缓存时长。工具清单在进程生命周期内是静态的
const LIST_TTL_MS := 600000

const SERVER_NAME := "godot-dev-mcp"
const SERVER_VERSION := "0.3.0"

## 服务器级"使用说明"(initialize / server:discover 结果的 instructions 字段)。这是给模型的
const BASE_INSTRUCTIONS := "Godot 开发调试 MCP 服务器(编辑器/游戏双模式): 改场景节点前先 get_scene_tree/get_node_info; 不确定 Godot 原生 API 先 classdb_query; get_logs / clear_logs / eval_code 用**必填** process 参数选进程(editor|game; 游戏进程工具需游戏在跑、导出运行时=本进程); simulate_*/take_screenshot(game) 作用于游戏进程(编辑器里调用经调试线转发)。"

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
## 是否已与某个客户端完成过 initialize 版本协商(进程级单标志)。
var _version_negotiated := false
var _tool_handlers := {} # 工具名 -> Callable
var _tool_defs := [] # 工具定义列表(MCP 格式)
var _tool_schemas := {} # 工具名 -> inputSchema。tools/list 要的是数组(协议规定),而入参校验
	# 要的是按名直查 —— 遍历数组去找会得到**注册顺序上的第一个同名项**, 一旦将来出现同名
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
## 编辑器模式: 游戏是否处于断点暂停状态(脚本错误/断点导致主循环暂停)
var _game_breaked := false
## 断点暂停时仍可安全执行的工具(只读缓冲, 不依赖游戏主循环):
const _BREAK_SAFE_TOOLS := ["get_logs", "clear_logs"]

## 逐条 JSON-RPC 请求日志的开关(现场可 set, 不必重启编辑器)。
static var _log_rpc := false

## 最近一次工具契约自检的问题列表(空 = 通过)。由 _audit_tools 写入,
## 供 refresh_tools 响应回给 AI —— 否则自检结果只能翻编辑器日志, 等于没有。
var _tool_audit_handlers := {}

var _tool_audit_issues: Array[String] = []

## 项目 provider 追加的服务器说明(见 _register_providers 的 instructions 收集), 拼进
var _provider_instructions: Array[String] = []

## ------- 多实例中枢状态(仅编辑器进程; 见 MCPInstanceHub 与 Readme §7.3) -------
var _hub: Variant = null
var _hub_enabled := false
var _hub_port := DEFAULT_HUB_PORT
## 上一次心跳的时刻(ms)。心跳在 _process 里按周期触发, 见 _hub_tick。
var _hub_last_beat := 0
## 心跳防重入: 一次心跳里可能连续 await 多个 HTTP 往返, 而 _process 每帧都会调 _hub_tick。
var _hub_beating := false
## "中枢端口被非本框架程序占用"的告警只打一次。它每次心跳都会重新判定成立, 不节流就会
var _hub_port_foreign_warned := false
## 路由 / 运行时 / 传输模块实例（懒创建，见 _router() / _runtime() / _transport()）。
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
	# 新鲜度基准(见 MCPScriptSync.guard_eval)。必须在游戏进程内自己记一份, 取 autoload 就绪
	_game_started_at = int(Time.get_unix_time_from_system())
	_logger = MCPLogger.new()
	OS.add_logger(_logger)
	_mode = MODE_RUNTIME
	# (1) 开发期桥接: "由编辑器启动的游戏进程"注册调试线工具(不占端口)。含 eval_code(process=game)
	if _is_editor_build():
		_register_game_play_tools()
		_register_providers()
		# 防御: 若本单例被实例化多次/热重载等导致 capture 已注册, 跳过而非崩溃
		if not EngineDebugger.has_capture(DEBUGGER_PREFIX):
			EngineDebugger.register_message_capture(DEBUGGER_PREFIX, _on_debugger_message)
		# 通知编辑器侧桥接已就绪(仅在调试线激活时有意义)。
		# 必须判 is_active: 没有调试器时 send_message 会打一条
		if EngineDebugger.is_active():
			EngineDebugger.send_message(DEBUGGER_PREFIX + ":ready", [])
	# (2) 导出包/独立运行: 注册共享域 + 游戏操作工具(不含 eval), 勾选时复用同一端口开服。
	elif bool(ProjectSettings.get_setting(SETTING_RUNTIME_ENABLED, false)):
		_register_runtime_domains()
		_start_runtime_server()


## 是否"编辑器构建"(即: 编辑器进程本身, 或由编辑器启动的游戏进程)。导出模板为 false。
## (实测 os_has_editor=true / class_ei=true), 编辑器类可解析、调试线可用。判据收敛在此一处。
static func _is_editor_build() -> bool:
	return OS.has_feature("editor")


## 游戏进程: 处理编辑器经调试线发来的工具调用消息。
## 注意: 游戏侧注册捕获器后, 回调收到的 message 已去掉前缀(见 EngineDebugger 文档),
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
	## 长任务(游戏用例)运行期间: 需要主循环的工具会被用例拖慢, 多数会干等到超时才报错。
	if _game_tests_running and tool_name != "run_tests" and not _BREAK_SAFE_TOOLS.has(tool_name):
		result = _err("游戏用例正在运行, 工具 %s 需要主循环, 现在调用既会拖慢用例也大概率超时。\n请先反复调用 run_tests(process=game, script=...) 读进度直到 running=false, 或用 game_control(action=stop) 终止用例。" % tool_name,
			"busy", true, "run_tests(process=game, script=...)读进度至running=false后再调用; 或game_control(action=stop)终止用例")
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
			# 运行时桥接就绪 ⟹ 游戏已加载完全部脚本, 此刻才是新鲜度判据最准的基准。
			_mark_script_baseline("调试线就绪")
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
	_mark_script_baseline("调试会话建立")
	# 保留旧的未决失败结果不覆盖; 新会话开始, 旧请求已无意义
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_transient("游戏调试会话已重启, 原请求被取消", "重新调用该工具即可")
	_pending.clear()


## 游戏会话结束(正常停止/崩溃/被杀)。填充所有未决请求为失败结果,
## 注意: 填充后不能 clear(), 否则代理读不到结果会退回配置的超时(_game_call_timeout_ms)。
func _on_session_stopped(session_id: int) -> void:
	LogTool.log("MCP", "游戏调试会话已结束(session=%d)" % session_id)
	_game_ready = false
	_game_breaked = false
	_game_started_at = 0
	var msg := "游戏进程已停止(正常结束或崩溃), 所有未完成的运行时调用被取消。请先 game_control(action=start) 重新启动游戏后再试。"
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_game_stopped(msg, "调用 game_control(action=start) 重新启动游戏, 等待调试线就绪后重试")


## 游戏进入断点暂停(脚本错误/断点触发, 主循环暂停但调试线仍在)。
func _on_session_breaked(_session_id: int, can_debug: bool) -> void:
	_game_breaked = true
	LogTool.log("MCP", "游戏已进入断点暂停(调试循环=%s)。运行时工具会立即返回明确错误, 可用 game_control(action=continue) 让游戏继续。" % str(can_debug))
	var msg := "游戏被断点暂停(脚本错误/断点)。get_logs(process=game) 仍可用, 先查错误; 再game_control(action=continue)继续; 要修脚本则game_control(action=stop)后改代码重跑。"
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_game_breaked(msg)


## 游戏解除断点暂停, 恢复运行
func _on_session_continued(_session_id: int) -> void:
	_game_breaked = false
	LogTool.log("MCP", "游戏已恢复运行(解除断点暂停)")


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
		_logger = MCPLogger.new()
		OS.add_logger(_logger)
	_register_editor_tools()
	# 多实例中枢开着时走"抢 hub 端口 / 退让到临时端口"这条路径, 否则沿用旧的单端口行为。
	_hub_enabled = bool(ProjectSettings.get_setting(SETTING_HUB, true))
	if _hub_enabled:
		_start_hub_mode()
	else:
		start()


## ------- 多实例中枢: 启动与绑定 -------
##   1. 先建身份(项目名 + 绝对路径哈希), 与端口无关 —— 身份必须先于端口确定,
##      临时端口而非"hub_port+1": +1 会与别的软件/另一个实例撞, 而 listen(0) 由内核保证唯一。
## 而"能不能绑上端口"本身就是一次原子的、内核保证的互斥判定。少一个状态源就少一类


## 解析本进程该用的中枢端口。两档:
## "两个端点互相看不见"的状态 —— 实测过(8932 与 9991 各自 role=hub、各自 count=1)。
## 代价是**一次性的破坏性变更**: 所有客户端 MCP 配置里的 URL 必须同步改成 9988。
func _resolve_hub_port() -> int:
	if _project_overrides_setting(SETTING_HUB_PORT):
		return int(ProjectSettings.get_setting(SETTING_HUB_PORT, DEFAULT_HUB_PORT))
	return DEFAULT_HUB_PORT


## project.godot 里是否**显式**写了某个设置项(而不是靠插件注册的默认值)。
## "只是注册了默认值"。而这两者的处理必须不同(见 _resolve_hub_port)。
## 直接读 project.godot 文本是本引擎版本下唯一可靠的判据: 显式设置必定以 "key=value" 的形式
func _project_overrides_setting(setting_key: String) -> bool:
	# 设置名形如 "dev_framework/mcp/hub_port", 文件里写作 "[dev_framework]" 段下的
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
	# 身份: 项目名取 project.godot 的 application/config/name, 路径必须 globalize 成绝对路径
	var project_name := str(ProjectSettings.get_setting("application/config/name", "project"))
	var project_path := ProjectSettings.globalize_path("res://")
	# 显式标类型: `_hub` 是 Variant(动态编译出来的脚本实例), 从它身上取到的返回值静态推断不出类型,
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
	# 措辞刻意是"被占用"而不是"被中枢占用": 此刻还不知道占用者是谁(可能是另一个编辑器,
	LogTool.log("MCP", "MCP 多实例: 中枢端口 %d 已被占用, 本实例退让到临时端口 %d, 即将尝试登记到中枢" % [_hub_port, listening_port()])
	# 首次登记立刻做一次(不等下一个心跳周期), 否则刚打开的项目会在最多 4 秒内不出现在中枢的清单里。
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
		return
	_hub_last_beat = now
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
		# 中枢回包带全机器实例表: 同步过来, 这样成员进程里的 list_instances 也能看到全部,
		if resp.get("instances") is Array:
			_hub.sync_from_snapshot(resp.get("instances"))
		return
	_hub.registered = false
	_hub.fail_streak += 1
	if _hub.fail_streak < 3:
		return
	# 中枢可能已退出: 尝试接管。注意这里**不重置** fail_streak —— 抢不到就继续等,
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


## 接管中枢: 关掉临时端口的监听, 改绑 hub_port。
## 关键细节: **必须先释放自己的临时端口再绑 hub_port 吗?** 不需要 —— 两个端口不同,
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
## 用 MCPDevServer.new() 建的子节点(真正在监听的是后者)。所以"该不该启动/自愈"必须按
## **实例身份**判断, 不能只看 _http 是不是 null —— 否则 autoload 那个从不监听的实例会
static var _owner = null
static var _last_autostart := 0


## 每帧驱动 HTTP 服务器, 并在它意外消失时自动拉起
func _process(_delta: float) -> void:
	if _http:
		_http.poll()
		# 心跳必须**每帧都可能跑**, 不能挂在 "if _http" 之外的那个 return 之后:
		_hub_tick()
		return
	# 自愈只在"这个实例本来就该监听"时发生: 热重载把 _http 清成 null 后端口已被释放,
	# 而用户和插件都没主动停过, 该自动重开, 否则每次改框架脚本都得重启编辑器才能继续用 MCP。
	if _owner != self or not Engine.is_editor_hint():
		return
	var now := Time.get_ticks_msec()
	if now - _last_autostart < 5000:
		return
	_last_autostart = now
	LogTool.log("MCP", "检测到 MCP 服务器已停止(通常是脚本热重载清掉了状态), 正在自动重新启动…")
	# 热重载会把实例成员清空, 包括 _hub: 重建它并恢复身份, 否则重启后会以空身份登记
	_hub = null
	_hub_last_beat = 0
	_hub_beating = false
	start_editor()


## tools/list 内容指纹: 把当前注册表压成一个短十六进制串。
func _schema_fingerprint() -> String:
	return "%08x" % (JSON.stringify(_tool_defs).hash() & 0xFFFFFFFF)


func _call_refresh_tools(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	# 注册走 _mod()(从源码重编译磁盘版本), 因此域文件里**新增/改动工具**也免重启生效。
	_register_editor_tools()
	var count := _tool_defs.size()
	var fp := _schema_fingerprint()
	LogTool.log("MCP", "手动重建工具注册表: %d 个工具, 指纹 %s" % [count, fp])
	# 把契约自检结果一并回给 AI: 否则自检只落到编辑器日志里, 等于没有 —— AI 改完框架脚本
	if _tool_audit_issues.is_empty():
		return _ok_json({
			"tool_count": count,
			"schema_fingerprint": fp,
			"audit": "pass",
			"message": "服务器侧工具注册表已重建: %d 个工具, 契约自检通过, 指纹 %s。判定'是否真的生效'以本指纹跨次对比为准(指纹不变即注册表没变)。【客户端不一定同步】本服务器是短连接 HTTP, 发不出 notifications/tools/list_changed(capabilities 已如实报 listChanged:false), 因此客户端若缓存了旧的 tools/list, 它手上的 schema 仍是旧的 —— 需在 IDE 侧重连 MCP 才会刷新; 在此之前, 以 tools/list 直查服务器为准, 不要拿会话开始时的快照当权威。" % [count, fp],
		})
	return _ok_json({
		"tool_count": count,
		"schema_fingerprint": fp,
		"audit": "fail",
		"issues": _tool_audit_issues,
		"message": "服务器侧工具注册表已重建: %d 个工具, 但契约自检发现 %d 个问题(见 issues), 指纹 %s。判定'是否真的生效'以本指纹跨次对比为准。【客户端不一定同步】本服务器推不出 tools/list_changed, 客户端缓存的旧 tools/list 要到 IDE 侧重连 MCP 才刷新。" % [count, _tool_audit_issues.size(), fp],
	})


## ------- 工具注册表手动刷新 -------
## 必须重建服务器实例(禁用再启用插件 / restart_editor)。此时 refresh_tools 依旧返回成功,
## 工具表却原样不变 —— 这个"静默无效"是本条注释存在的唯一理由。


## 关闭服务器并移除 Logger(退出时由引擎自动调用)
func _exit_tree() -> void:
	# stop() 里已经做过一次注销(见那里的注释), 这里不再重复 —— 重复发一次无害但没必要。
	stop()
	# 注销调试线捕获。判 has_capture 是必要的: 本 autoload 在**非编辑器构建**里也可能存在
	# 注意这条 ERROR 在 headless 跑测试(--script)时**仍会出现一次**: 引擎 shutdown 阶段会按
	# 无关, 也消不掉 —— 唯一的"解法"是不注销, 但那会让插件停用再启用后的旧捕获器指向已释放
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
	# 只在**监听成功**后才认领 owner: 绑定失败还标记成"该我监听", 会让自愈反复重试
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
## get_project_info 等工具报的就是这个值 —— 中枢上收到成员转发的请求时, 那里报的必须是
## **成员自己的**端口, 否则诊断"它到底在哪个端口"时会指向中枢。
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


## 监听并接管请求。port 传 0 = 让系统分配一个空闲端口(多实例退让路径用,
## 由内核保证唯一, 比 "hub_port+1" 这类自己算的备用端口可靠得多)。
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
func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_schemas[name] = input_schema
	_tool_defs.append(_mod("MCPToolMeta").build(name, desc, input_schema))


## MCP 目录下的域脚本按"当前磁盘版本"动态取用(而非 const preload 的编译期绑定)。
## 之后磁盘新版本与它无关 —— 连 `X.reload()` 也切不动已经编译进本文件的静态调用目标(实测)。
## 【为什么不是 CACHE_MODE_REPLACE】本机实测: 对 .gd 调 load(..., CACHE_MODE_REPLACE) —— 连同
## ScriptServer 有关)。唯一可靠的是"读源码文本 + GDScript.new() 重编译", 这是引擎直接给的能力,
var _mod_cache := {}


func _mod(name: String) -> Variant:
	if _mod_cache.has(name):
		return _mod_cache[name]
	var gd: Variant = _script_from_disk("%s/%s.gd" % [MCP_DIR, name])
	_mod_cache[name] = gd
	return gd


## 按当前磁盘源码重编译一个脚本(绕过 ResourceLoader 缓存)。域文件与项目 provider 共用: 于是
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


## ======= 工具参数 schema =======


## 通用游戏操作工具注册: editor 侧 handler 经调试线转发, runtime 侧就地执行。
func _register_game_play_tool(name: String, desc: String, schema: Dictionary, runtime_handler: Callable, editor_handler := Callable()) -> void:
	var ehandler: Callable = editor_handler
	if not ehandler.is_valid():
		ehandler = func(args: Dictionary) -> Dictionary: return await _call_runtime_proxy(name, args)
	# 登记"入参自检该切哪一份"。转发 lambda 不读任何入参键, 切它会因切不出函数体而**静默跳过**
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
	# _tool_schemas 与 _tool_audit_handlers 一并清: 三份索引必须同增同减。少清一份当下不会报错
	_tool_schemas.clear()
	_tool_audit_handlers.clear()
	# 域脚本的源码编译缓存也必须每轮重建: 否则 refresh_tools 会复用上一轮编译的旧版本。
	_mod_cache.clear()


func _register_editor_tools() -> void:
	_reset_tools()
	_register_shared_domains()
	_register_editor_only_domains()
	_register_game_play_tools()
	_register_providers()
	_audit_tools()


## ======= 域注册 =======

## 注册"编辑器与运行时都可用"的域。走 _mod: 编辑器侧热重载, 运行时侧经 FileAccess/
func _register_shared_domains() -> void:
	# MCPLogTools / MCPDevTools 不再在此注册工具: get_logs / clear_logs / eval_code / run_tests
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
	_register_run_tools()
	_register_refresh_tool()
	_register_instance_tools()


## eval 运行上下文(见 _register_shared_domains)。方法引用即 Callable, 避免三处各写一份 lambda。
func _eval_ctx_provider() -> Dictionary:
	return {"mode": _mode, "game_started_at": _game_started_at, "logger": _logger}


## 会话事实(get_project_info / get_editor_activity 用), 现取现用(理由见 _register_project_tools)。
func _session_facts_provider() -> Dictionary:
	var facts := {
		"mcp_running": is_running(),
		"game_running": _has_game_session(),
		"bridge_ready": _has_game_session() and _game_ready,
	}
	# 多实例身份随会话事实一起报: get_project_info 是 AI 判断"我现在操作的是哪个项目"的第一入口,
	# 多开时它必须能看出差别 —— 否则两个项目的 basic 段除了 project_name 完全一样。
	if _hub != null:
		facts["instance_id"] = _hub.own_instance_id
		facts["instance_role"] = "hub" if bool(_hub.hub_mode) else "member"
		facts["mcp_port"] = listening_port()
		if not bool(_hub.hub_mode):
			facts["instance_note"] = "本实例不是中枢: 端口 %d 是系统分配的临时端口, 客户端应连中枢的固定端口 %d/mcp" % [listening_port(), _hub_port]
	return facts


## 注册项目侧 provider(见 SETTING_PROVIDERS): 加载脚本, 调其 `static register(add_tool)`
## 没有运行的游戏时也必须可用; 需要操作"正在运行的游戏"的项目工具应改用脚本 + eval_code(process=game),
func _register_providers() -> void:
	# 资源注册表与服务器说明都随每轮工具注册一起重建(与 _reset_tools 同节奏), 避免残留。
	var docs: Variant = _mod("MCPResourceDocs")
	docs.clear()
	_provider_instructions = []
	var paths: Variant = ProjectSettings.get_setting(SETTING_PROVIDERS, PackedStringArray())
	if not (paths is Array or paths is PackedStringArray):
		return
	for p in paths:
		var path := str(p).strip_edges()
		if path.is_empty():
			continue
		var script: Variant = _script_from_disk(path)
		if script == null or not (script is GDScript):
			push_warning("[MCP] provider 脚本无效: %s" % path)
			continue
		if script.has_method("register"):
			script.register(_add_tool)
		if script.has_method("resources"):
			docs.register(script.resources())
		if script.has_method("instructions"):
			var line := str(script.instructions()).strip_edges()
			if not line.is_empty():
				_provider_instructions.append(line)
		if not script.has_method("register") and not script.has_method("resources") and not script.has_method("instructions"):
			push_warning("[MCP] provider 脚本既无 static register(add_tool) / resources() / instructions(): %s" % path)


## ======= 契约自检 =======
## 为什么必须有: 全部工具(主文件 + 各域文件)都是手写注册, 而协议层的失败模式**全部是静默的**
func _audit_tools() -> void:
	# 自检规则本身在 MCPToolAudit 里; 这里只负责喂数据 + 报结果。
	# "名单里的工具名是否都已注册"的反向校验会把分模式注册误报成名单未同步(实测刷 33 条)。
	# extra_scripts: 项目侧 provider 脚本在 MCP 目录之外, 须并入源码扫描, 否则其 handler 的
	var provider_paths: Variant = ProjectSettings.get_setting(SETTING_PROVIDERS, PackedStringArray())
	var extra: Array = Array(provider_paths) if (provider_paths is Array or provider_paths is PackedStringArray) else []
	_tool_audit_issues = _mod("MCPToolAudit").audit_tools(_tool_defs, _tool_handlers, get_script().resource_path, _tool_audit_handlers, _mode == MODE_EDITOR, extra)
	# 自检通过是常态, 静默即可; 只在发现问题时报警, 否则每次启动都要宣告一遍"没问题"。
	if not _tool_audit_issues.is_empty():
		LogTool.log("MCP", "工具契约自检发现 %d 个问题:\n  - %s" % [_tool_audit_issues.size(), "\n  - ".join(_tool_audit_issues)])


## ------- 工具实现 =======

## -- 场景树 / 节点 + 场景编辑 --
func _register_scene_tools() -> void:
	_mod("MCPSceneTools").register(_add_tool)


## -- 项目信息 --
## 故这里注入一个 provider。**必须现取现用而不是注册时拍快照** —— 用户随时启停游戏, 快照过了
func _register_project_tools() -> void:
	var project_tools: Variant = _mod("MCPProjectTools")
	project_tools.set_session_facts_provider(_session_facts_provider)
	project_tools.register(_add_tool)


## -- 运行游戏 --
func _register_run_tools() -> void:
	_add_tool("game_control",
		"游戏运行控制。action=start: 以调试模式启动(等效F5, 自动建EngineDebugger调试线; scene缺省用主场景且支持 uid:// 形式; 游戏已在运行时自动停止旧实例后重启); action=stop: 停止运行中的游戏; action=continue: 解除因脚本错误/断点被暂停的游戏(等效Debugger面板Continue)—— 工具报 error_category=game_breaked 时用它恢复, 未暂停时调用是安全的空操作。【副作用】start/stop 会抢占并中断用户手头正在玩的那个游戏进程 —— 执行前先用 get_editor_activity 确认没有正在进行的调试, 执行后游戏不会自动恢复。",
		{"type": "object", "properties": {
			"action": {"type": "string", "enum": ["start", "stop", "continue"], "description": "启动/停止/解除断点暂停"},
			"scene": {"type": "string", "description": "action=start 时可选: 要运行的场景 res:// 或 uid:// 路径"}
		}, "required": ["action"]},
		_call_game_control)


## -- 刷新工具注册表 --
func _register_refresh_tool() -> void:
	_add_tool("refresh_tools",
		"手动重建 MCP 工具注册表(免重启编辑器), 响应含工具数、schema_fingerprint 与契约自检结果。**判定'是否真的生效': 跨次对比 schema_fingerprint** —— 指纹不变即工具表没变。【客户端不一定同步】本服务器是短连接 HTTP, 发不出 notifications/tools/list_changed(capabilities 已如实报 listChanged:false), 客户端缓存的旧 tools/list 不会自动刷新, 需在 IDE 侧重连 MCP 才更新; 在此之前, 以 tools/list 直查服务器为准, 勿把会话开始时的快照当权威。【重要: 适用范围】改动 **MCP 目录下任一域脚本**(MCPResourceTools / MCPSceneTools 等: 新增或修改工具、注解名单、入参构造、handler)时有效 —— 本工具会先把域脚本缓存换成磁盘版本, 再按路径动态注册, 免重启生效。**唯一例外是 MCPDevServer.gd 自身**: 运行实例的方法体不会被热替换, 必须重建服务器实例(禁用再启用 DEVFramework 插件, 或 restart_editor); 该情况下本工具仍返回成功但注册表原样不变 —— 正是靠 schema_fingerprint 不变来识别这种'假成功'。",
		MCPToolSchema.no_arg(),
		_call_refresh_tools)


## -- 多实例中枢: 实例管理工具 --
func _register_instance_tools() -> void:
	_add_tool("list_instances",
		"列出本机当前所有装了本框架的 Godot 编辑器实例(含本进程)。每项: instance_id(如 MyGame@a1b2c3d4)、name、project_path、port、age_ms(心跳多久前, 越小越新)、is_self、is_hub。age_ms 明显大于 4000 说明该实例可能已关闭(会被自动剔除)。**同时打开多个项目时先调它**, 再用 use_instance 选默认目标, 或用工具的 instance 参数单次指定。",
		MCPToolSchema.no_arg(),
		_call_list_instances)

	_add_tool("use_instance",
		"设置**默认目标编辑器实例**。设置后, 之后所有工具调用(未显式传 instance 参数时)都转发到该实例的编辑器进程执行。instance 可填 instance_id(如 MyGame@a1b2c3d4)、唯一前缀(hash 或项目名前缀)、端口号; 传空字符串 = 恢复为「本实例」。设置会跨重启保留(目标编辑器回来后自动接回); 目标不在线时报错, 不会改到别的项目。**同时打开多个项目时, 先调 list_instances 拿 id, 再调本工具选一个**。",
		{"type": "object", "properties": {
			"instance": {"type": "string", "description": "目标实例: instance_id / 唯一前缀 / 端口号; 空字符串=恢复本实例。可用值见 list_instances。"},
		}},
		_call_use_instance)


## ======= MCP 协议处理 =======

func _on_request(method: String, path: String, query: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	_transport().on_request(method, path, query, headers, body, stream)


## GET /mcp → 开启旧式 HTTP+SSE 会话。
## **实测是错的**: 客户端收到 405 后直接放弃, 一次 POST 都不发, 界面永远停在"连接中"。
## 所以 GET 必须真的把流开出来, 而不是拒掉。
func _serve_sse(stream, headers: Dictionary) -> void:
	_transport()._serve_sse(stream, headers)


## SSE 响应头。与 _cors_headers 分开是因为语义不同: 那里是"一次 JSON-RPC 往返"的响应头,
func _sse_headers(headers: Dictionary) -> Dictionary:
	return _transport()._sse_headers(headers)


## 通告给旧式客户端的 POST 地址。用绝对 URL: 部分旧客户端不会拿它与 SSE 的 URL 做相对
func _endpoint_url() -> String:
	return _transport()._endpoint_url()


## 从 query 串取参数值(键名大小写不敏感)。旧式 SSE 传输把 sessionId 放在 query 上。
static func _query_param(query: String, key: String) -> String:
	return MCPTransport.query_param(query, key)


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


## 处理一条 JSON-RPC 请求(MCP), 返回响应字典。
## 它只影响**响应形状**: 2026-07-28 起 result 必须带 resultType, 可缓存结果还必须带
func _handle_jsonrpc(req: Dictionary, proto: String = PROTOCOL_VERSION) -> Dictionary:
	var req_id: Variant = req.get("id", null)
	if req_id == null:
		return {}

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
			# 版本回显而非强推: initialize 的语义是"就客户端提出的版本达成一致",
			var agreed := _negotiate_version(requested_proto)
			if not requested_proto.is_empty() and agreed != requested_proto:
				# 标明是**请求体**声明的版本: 外层 _on_request 还会就协议头/_meta 声明的版本
				LogTool.log("MCP", "initialize 请求体声明的版本 %s 不受支持, 协商降级为 %s (支持: %s)" % [requested_proto, agreed, str(SUPPORTED_PROTOCOL_VERSIONS)])
			LogTool.log("MCP", "客户端初始化: %s (协议: %s -> %s)" % [client_info, requested_proto, agreed])
			# 能力协商: 声明工具列表变更通知与日志能力
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
		# 2026-07-28 起客户端可在发其他请求前先探知服务端支持哪些版本。规范标为服务端 MUST。
		"server/discover":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result({
				"protocolVersions": SUPPORTED_PROTOCOL_VERSIONS,
				"protocolVersion": proto,
				"capabilities": _server_capabilities(),
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
				"instructions": _server_instructions(),
			}, proto)}
		"tools/list":
			# ttlMs/cacheScope 让客户端缓存这份 38K 的清单而不是每次重拉 —— 它在进程生命周期内
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"tools": _hub_tools_for_list()}, proto, true)}
		"tools/call":
			var params: Variant = req.get("params", {})
			var params_dict: Dictionary = params if params is Dictionary else {}
			var tool_name: String = str(params_dict.get("name", ""))
			# 参数类型防护: 客户端传非对象/非法参数时, 返回 无效参数 而非触发运行时类型错误导致无响应挂起
			var raw_args: Variant = params_dict.get("arguments", {})
			var arguments: Dictionary = raw_args if raw_args is Dictionary else {}
			if not (raw_args is Dictionary):
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "Invalid params: 'arguments' must be an object: %s" % str(raw_args))
			# 入参日志与成功结果日志同开关(dev_framework/mcp/log_tool_results): 它们是同一个问题的
			if ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
				# 参数截断: eval_code 传的是代码正文(上限 8192 字符), 整段打进日志会撑爆日志。
				var arg_log := str(arguments)
				if arg_log.length() > 300:
					arg_log = arg_log.left(300) + ("…(已截断, 共 %d 字符)" % arg_log.length())
				LogTool.log("MCP", "工具调用(%s): %s, 参数: %s" % [_mode, tool_name, arg_log])
			if not _tool_handlers.has(tool_name):
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "Unknown tool: %s" % tool_name)
			# 多实例路由: 目标不是本实例时, 把整条 JSON-RPC 请求**原样转发**到目标实例的 MCP 端点,
			var route := _resolve_route(tool_name, arguments)
			if not str(route.get("error", "")).is_empty():
				return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(
					_err_validation(str(route.get("error")), str(route.get("recovery", ""))))}
			if int(route.get("port", 0)) > 0:
				return await _forward_call(req, req_id, tool_name, route, proto)
			# 本实例执行: 摘掉只在路由层有意义的 instance 参数, 不让它进 handler 与日志。
			if not MCPRouter.HUB_TOOLS.has(tool_name):
				arguments.erase("instance")
			# 入参校验: 拦在 handler **之前**。handler 内部的 VariantTool 是为"健壮"而非"诚实"
			var arg_issues := MCPArgCheck.check(_tool_schemas.get(tool_name, {}), arguments)
			if not arg_issues.is_empty():
				return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(_err_validation(
					"参数校验未通过 (%d 项):\n- %s" % [arg_issues.size(), "\n- ".join(arg_issues)],
					"按上述提示修正后重试; 每个参数的合法取值见 tools/list 里该工具的 inputSchema(enum/required)与 description"))}
			# 安全执行: 隔离 handler 运行期错误, 避免 GDScript 无 try/catch 导致协程中止、响应永不发出
			var result := await _safe_call_handler(_tool_handlers[tool_name], arguments)
			# 统一输出上限: 超限转明确错误提示, 避免巨型响应撑爆上下文/拷贝缓冲
			result = MCPFormat.enforce_output_cap(tool_name, result, _output_cap())
			if result.is_empty():
				return _jsonrpc_error(req_id, ERR_INTERNAL, "Internal error: 工具执行未返回结果")
			# 记录返回信息到 MCP 日志, 便于诊断"返回异常/空"等问题。仅打印非原始数据
			# 必须在剥离 text/is_error **之前**记 —— 日志摘要读的就是这两个字段。
			_log_tool_result(tool_name, result)
			# 盖章: 结果里固定带上"本次在哪个项目执行"。多实例下最难查的不是报错, 是
			result = _stamp_target(result)
			# 出协议边界: 剥掉仅供进程内使用的顶层 text / is_error。二者与 content[0].text
			# 逐字节重复, 不剥等于每次调用把同一份正文传两遍(实测占大结果 45%)。详见 MCPResult.for_protocol。
			return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(result)}
		# resources: 静态文档入口(项目侧 provider 声明、**内嵌内容**)。短连接架构发不出推送,
		# 注意 resources/read 的成功与失败**都**放在 result 里(失败时带 isError + content),
		"resources/list":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"resources": _mod("MCPResourceDocs").list_all()}, proto, true)}
		"resources/read":
			var rparams: Variant = req.get("params", {})
			var rdict: Dictionary = rparams if rparams is Dictionary else {}
			# 成功与失败都在 result 里(失败时是 _err_validation, 自带 content+isError),
			return {"jsonrpc": "2.0", "id": req_id,
				"result": _decorate_result(MCPResult.for_protocol(_mod("MCPResourceDocs").read(str(rdict.get("uri", "")))), proto, true)}
		"ping":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		# 声明支持 4 个级别却什么都不做, 比不声明更糟: 模型会据此以为 debug/info 日志已被
		# 响应**。这里不实现分级过滤(那要贯穿整条日志管线, 是独立的一件事), 但必须如实说明
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


## ======= 多实例: 实例管理工具实现 =======

## list_instances: 本机实例清单(含本进程)。中枢会给全量; 成员给"本进程 + 中枢同步来的"。
func _call_list_instances(args: Dictionary) -> Dictionary:
	return await _router().call_list_instances(args)


## use_instance: 设置默认目标实例。传空 = 恢复本实例。
func _call_use_instance(args: Dictionary) -> Dictionary:
	return _router().call_use_instance(args)


## HTTP 层直接回 JSON-RPC 错误的**唯一出口**。
##   3. 净化 —— 6 处**全部绕过 MCPFormat.json_safe**, 而正常响应走了。协议边界必须单一收口,
##      否则日后往 json_safe 加规则时会整类漏掉, 边界就漏了。
## 本函数直接发出 HTTP 响应, 服务于"还没进 JSON-RPC 就必须拒绝"的场景(方法/鉴权/
func _send_rpc_error(stream, status: int, req_headers: Dictionary, req_id: Variant, code: int, message: String, data: Dictionary = {}, extra_headers: Dictionary = {}) -> void:
	var hdrs := _cors_headers(req_headers)
	for k in extra_headers:
		hdrs[k] = extra_headers[k]
	# data 仅在非空时才出现。规范原文是"客户端需要结构化信息时放在 data",
	var err_obj := {"code": code, "message": message}
	if not data.is_empty():
		err_obj["data"] = data
	_http.send_response(stream, status, hdrs, MCPFormat.json_safe(JSON.stringify({
		"jsonrpc": "2.0", "id": req_id, "error": err_obj,
	})))


## 服务端能力声明。initialize 与 server/discover 共用 —— 同一份事实写两处,
func _server_capabilities() -> Dictionary:
	return {
		# 工具清单在进程生命周期内是静态的(_tool_defs 只在初始化时填充), 而本服务器
		"tools": {"listChanged": false},
		# resources 只读静态文档, 无订阅能力(短连接发不出推送), 清单也是静态的。
		"resources": {"subscribe": false, "listChanged": false},
		# 旧日志级别机制。2026-07-28 已把通知侧标记为废弃(SEP-2577), 改由每请求
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


## 安全执行工具 handler: 在执行前后记录/比对错误缓冲, 把运行期错误转换成结构化诊断附加到结果。
## 注意: GDScript 无 try/catch, handler 内硬错误(如类型错误)仍会使 await 协程中止——
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


## 实时读统一输出上限。截断实现搬去 MCPFormat 之后, 这里是**唯一**读该设置的地方 ——
func _output_cap() -> int:
	return int(ProjectSettings.get_setting(SETTING_MAX_OUTPUT_CHARS, DEFAULT_MAX_OUTPUT_CHARS))


## 把工具调用结果记录到 MCP 日志。**成功路径默认不打**, 由 dev_framework/mcp/log_tool_results 开关。
func _log_tool_result(tool_name: String, result: Dictionary) -> void:
	var text: String = str(result.get("text", ""))
	var is_err: bool = result.get("is_error", false)
	if is_err:
		# 用 error 级别而非 log: LogTool 让 ERROR 不受 enabled 开关与 tag 忽略的影响,
		# 否则一旦关掉 MCP 日志或把该 tag 加进忽略列表, 工具错误会被一并吞掉 ——
		LogTool.error("MCP", "[%s] %s 错误: %s" % [_mode, tool_name, text.left(400)])
		return
	if not ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
		return
	# 打全文还是打结构摘要(顶层键 + 数组/字典计数), 只按**长度**判, 不按工具名维护名单。
	# 把最该看的那一行变成键名罗列 —— 实测中真正需要人看的恰恰是这类短状态行。
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
## 引用分类常量请写 MCPResult.CAT_*(唯一定义处已随之迁走)。


func _wrap(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	return MCPResult.make(text, is_error, extra, content_text)


func _ok(text: String) -> Dictionary:
	return MCPResult.ok(text)


func _fail(text: String) -> Dictionary:
	return MCPResult.fail(text)


func _ok_json(data: Dictionary) -> Dictionary:
	return MCPResult.ok_json(data)


## 原 _ok_with_meta(正文与结构化元信息分离的封装) 已随 get_scene_tree 搬进 MCPSceneTools,


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。
## 这里**故意没有** stale_code 的转发: 该类别唯一的用法在新鲜度守卫里是随守卫结果
## 不要为了"看起来对称"先摆一个没人调用的空壳。
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


## 底层结构化错误封装。category 取值见 MCPResult.CAT_*; retryable 由语义化封装固化,
func _err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	return MCPResult.err(text, category, retryable, recovery)


## ======= 统一入参读取: 一律走 VariantTool =======
## 需要值级转换时用 as_*(或 infer / coerce)。统一规则、坑位说明与"为什么"集中在
## VariantTool 顶部, 那里是本规则的**唯一事实来源** —— 不要在这里重新抄一份。
## ======= 两处合法的裸读(不要当漂移收掉) =======
## 注意这是**约定而非守卫**: 契约自检(_audit_tools / MCPToolAudit.audit_handler_params)校验的是


## ------- get_logs / clear_logs: 统一的进程路由(process 必填) -------
##   · *_local  : 服务器就在(游戏)进程内 → 只能 process=game, 本进程即游戏;
##   · *_routed : 服务器在编辑器进程 → editor 读本进程缓冲, game 经调试线转发。

func _call_get_logs_local(args: Dictionary) -> Dictionary:
	return _runtime().call_get_logs_local(args)


func _call_get_logs_routed(args: Dictionary) -> Dictionary:
	return await _runtime().call_get_logs_routed(args)


func _call_clear_logs_local(args: Dictionary) -> Dictionary:
	return _runtime().call_clear_logs_local(args)


func _call_clear_logs_routed(args: Dictionary) -> Dictionary:
	return await _runtime().call_clear_logs_routed(args)


## 读取必填的 process 参数(editor|game)；缺省即由调用方报错。
func _require_process(args: Dictionary) -> String:
	return VariantTool.get_string(args, "process", "").strip_edges()


## run_tests（双进程语义、内联预检、自动起游戏）实现见 MCPRuntime。
func _call_run_tests_local(args: Dictionary) -> Dictionary:
	return await _runtime().call_run_tests_local(args)


func _call_run_tests_routed(args: Dictionary) -> Dictionary:
	return await _runtime().call_run_tests_routed(args)


## 游戏运行控制（start / stop / continue）：实现见 MCPRuntime。
func _call_game_control(args: Dictionary) -> Dictionary:
	return await _runtime().call_game_control(args)


## 编辑器模式且游戏调试线活跃（编辑器进程指向游戏进程的数据/操作要走代理）
func _has_game_session() -> bool:
	return _runtime()._has_game_session()


## 记录"脚本新鲜度基准"的当前时刻（见 MCPScriptSync.guard_eval）。
func _mark_script_baseline(reason: String) -> void:
	_runtime().mark_script_baseline(reason)


func _call_take_screenshot(args: Dictionary) -> Dictionary:
	return await _runtime().call_take_screenshot(args)


func _call_run_game(args: Dictionary) -> Dictionary:
	return await _runtime()._call_run_game(args)


func _call_stop_game(args: Dictionary) -> Dictionary:
	return await _runtime()._call_stop_game(args)


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
	# 仅首次进入时清空(editor 进程已由 _register_editor_tools 清空并注册了编辑/项目工具,
	# 这里只能追加 runtime 工具, 不能 reset 否则会清掉前面分组的注册)。
	if _tool_handlers.is_empty():
		_reset_tools()
	# 绑定日志捕获器: get_logs / clear_logs 复用 MCPLogTools 的底层件(server 侧用 preload 实例,
	# 故必须绑这个对象而非 _mod 出的那份)。
	MCPLogTools.bind_logger(_logger)
	# eval ctx provider: eval_code(process=game) 经 MCPDevTools.eval_code,
	_mod("MCPDevTools").set_eval_ctx_provider(_eval_ctx_provider)
	# 排在 simulate_click 之前注册: 使用顺序就是"先查后点", 工具表按此顺序排能让 AI
	_register_game_play_tool("get_interactables",
		"列出当前画面里可交互的东西 —— **2D 控件(按钮/输入框/滑动条/标签)与 3D 物体(按钮/道具等)** —— 每条带一个短引用 ref(如 e3)。**先查后点**: 拿到 ref 后用 simulate_click(ref=e3) 直接点击, 无需自己换算坐标。2D 元素给两套矩形(viewport_rect 视口坐标 / window_rect 窗口坐标); space=3d 的元素刻意不给矩形(3D 投影点会随相机漂移), 点击由工具在物体自身上激活。用 space=3d 可单独取 3D 子集(数量可能比 UI 还多, 混在默认清单里容易被 max_nodes 截掉)。filter=text 只取带文字的(读数值/提示语), class_filter=Button 按类型筛(对 3D 元素也可按脚本名筛, 如 ButtonView3D), text_contains 按文案筛。ref 由服务端解析成**实时**位置, 界面在查询后有动画或位移也不会点偏; 若报未知 ref 说明界面已变, 重新查一次即可。【只读】不改任何游戏状态。",
		MCPUITools.schema(),
		MCPUITools._handle_get_interactables)

	_register_game_play_tool("simulate_click",
		"在游戏窗口模拟鼠标左键点击(按下+释放)。**推荐先用 get_interactables 拿到元素 ref, 再用 ref=e3 点击** —— 由服务端解析成实时位置, 不必自己换算坐标。ref 指向 3D 物体(space=3d)时改为在该物体自身上激活一次点击、**不注入鼠标事件**(相机可动, 投影坐标必点偏)。ref 指向子视口元素(space=subviewport, 渲染在 SubViewport 里的 UI)时事件直接 push_input 进那个子视口 —— 那块 UI 不在窗口 GUI 层, 只用 x/y 走主窗口**永远点不到**; 此时别怀疑输入被吞, 拿 ref 点即可(x/y 无法指定子视口)。也可直接传 x/y(默认窗口坐标, 传 space=viewport 则按视口坐标换算)。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路 —— 重复调用会重复触发业务逻辑, 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_click(),
		_call_simulate_click)

	_register_game_play_tool("simulate_drag",
		"在游戏窗口模拟拖拽(按下→移动→释放), 测试拖拽交互。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路, 重复调用会重复触发(如重复拾取/重复移动), 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_drag(),
		_call_simulate_drag)

	_register_game_play_tool("simulate_key",
		"在游戏窗口模拟键盘按键(按下/释放), 测试键盘交互。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路, 重复调用会重复触发(重复跳两次/重复扣血), 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_key(),
		_call_simulate_key)

	# take_screenshot 的 name/desc/schema 由 MCPScreenshotTools.spec() 单副本提供, 这里不再各写
	var _shot_spec: Variant = _mod("MCPScreenshotTools").spec()
	_register_game_play_tool(_shot_spec["name"],
		_shot_spec["desc"],
		_shot_spec["schema"],
		_runtime_take_screenshot,
		_call_take_screenshot)

	# eval_code: 统一入口, process 必填(editor|game)。编辑器进程: editor=本进程, game=转发;
	var eval_schema := {
		"type": "object",
		"properties": {
			"process": {"type": "string", "enum": ["editor", "game"], "description": "在哪个进程执行: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。"},
			"code": MCPToolSchema.code_arg(),
			"timeout_ms": MCPToolSchema.code_timeout_arg(),
			"auto_resume": {"type": "boolean", "description": "仅 process=game 有意义: 游戏断点暂停时先 game_control(action=continue) 再执行(默认 false)。"},
		},
		"required": ["process"],
	}
	_register_game_play_tool("eval_code",
		"执行一段 GDScript(方法体内容, 缩进由服务器处理)。process 必填: editor=在编辑器进程执行(可读写编辑态, 新鲜度闸门 + 热重载); game=在游戏进程执行(可读运行状态/改变量/触发逻辑, 需游戏运行; 导出运行时=本进程)。【副作用】执行任意代码, 不可自动重试; 纯查询优先用专用只读工具(如 get_interactables / get_scene_tree / get_logs)。可 return 返回值; 支持 await(timeout_ms 默认 8000/上限 15000)。get_node 相对路径基于 eval 实例, 访问游戏节点用 /root/... 或 get_tree().current_scene.get_node(...)。【新鲜度闸门(process=game)】引擎不热重载游戏进程: 改过 .gd 后执行只会得到旧代码, 工具会先自动热重载, 再对(①已有既存实例的脚本 ②全局类)拒绝并给出 error_category=stale_code; 此时需 game_control(action=start) 重启再验。",
		eval_schema,
		_call_eval_code_local,
		_call_eval_code_routed)

	var tests_schema := {
		"type": "object",
		"properties": {
			"process": {"type": "string", "enum": ["editor", "game", "both"], "description": "在哪个进程跑: editor=编辑器进程(同步跑完才返回; 只跑进程无关用例); game=游戏进程(跑 needs_game_process() 用例; **阻塞到本轮跑完才返回**; 无运行中的游戏时**自动启动**; 导出运行时=本进程); both=先 editor 段再 game 段并合并成一份汇总(跑全量用这个)。必填。"},
			"script": {"type": "string", "description": "必填。二选一(靠内容自动判别): ①测试脚本路径子串(如 'test_game_replay'), 只运行匹配的用例文件; 'all'=全量(**不推荐**: 耗时可能过长)。②**内联 GDScript 源码**——含换行 或 以 'extends ' 开头即判为源码, 需 `extends TestCase` 并定义 test_ 开头的断言方法, 直接编译运行、**不落盘**, 适合临时验证(上限 8192 字符)。单个词(含打错的脚本名)一律按选择器处理。"},
		},
		"required": ["process", "script"],
	}
	_register_game_play_tool("run_tests",
		"运行**指定**的项目单元测试(Scripts/Test/ 下, extends TestCase, test_ 开头方法自动发现; 支持协程用例)。**script 必填**: 传脚本路径子串(或 'all' 全量, 不推荐)按文件跑; 或**直接传内联 GDScript 源码**(含换行/以 'extends ' 开头即视为源码, `extends TestCase` + test_ 方法, 不落盘, 临时验证用)。process 必填: editor=编辑器进程(同步跑完才返回; 只跑进程无关用例); game=游戏进程(跑 needs_game_process() 用例; **阻塞到本轮跑完才返回**; 无运行中的游戏时自动启动一个; 已有会话不重启); both=先 editor 段再 game 段并合并成一份汇总(**跑全量用它**, 游戏段没跑成会记成一条失败而不是静默省略)。**逐条进度**(每个用例方法的开始/结束、长方法的 15s 心跳)只 print 到宿主控制台 —— 编辑器输出面板 / 游戏窗口 / headless stdout, 工具返回值只有最终汇总, 阻塞期间查不到中途进度。**测试整体硬超时 10 分钟**: 到点判失败并停止等待。",
		tests_schema,
		_call_run_tests_local,
		_call_run_tests_routed)

	# 日志读/清: 统一入口, process 必填(editor|game)。编辑器进程: editor=本进程缓冲, game=转发;
	var logs_schema := MCPToolSchema.logs("200(log)/100(warning|error)", "条目", {
		"process": {"type": "string", "enum": ["editor", "game"], "description": "读哪个进程的缓冲: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。"},
		"kind": {"type": "string", "enum": ["log", "warning", "error"], "description": "获取类别, 默认 log"},
	})
	logs_schema["required"] = ["process"]
	_register_game_play_tool("get_logs",
		"获取日志/错误/警告(获取而非打印), process 必填: editor=编辑器进程缓冲, game=游戏进程缓冲(需游戏运行; 导出运行时=本进程; 游戏断点暂停时仍可安全读)。kind=log 取 print; warning 取 push_warning; error 取脚本错误(script_error/shader_error/stderr, 含栈追踪)。返回 next 游标作 since 增量拉取, 连续重复自动合并(repeat 计数)省 token。",
		logs_schema,
		_call_get_logs_local,
		_call_get_logs_routed)

	var clear_schema := {
		"type": "object",
		"properties": {
			"process": {"type": "string", "enum": ["editor", "game"], "description": "清哪个进程的缓冲: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。"},
			"scope": {"type": "string", "enum": ["all", "logs", "errors"], "description": "清理范围, 默认 all"},
		},
		"required": ["process"],
	}
	_register_game_play_tool("clear_logs",
		"清空指定进程的日志/错误缓冲(调试复位)。process 必填: editor/game。scope=all 全清; logs 只清 print 日志; errors 只清错误与警告。",
		clear_schema,
		_call_clear_logs_local,
		_call_clear_logs_routed)


## 运行时: 模拟鼠标左键点击(游戏进程内 Input.parse_input_event 直接生效)
##   x/y —— 调用方自报坐标系(space, 默认 window)。必须自报: Input.parse_input_event 收的是
##   目标左上方约 12%(项目实测比例约 0.88), 且偏移随分辨率变化, 表现为"换台电脑就点不准"。
func _call_simulate_click(args: Dictionary) -> Dictionary:
	var pos := Vector2.ZERO
	var space := ""
	var target_space := "window"
	var sub_vp_path := ""
	var ref := VariantTool.get_string(args, "ref").strip_edges()
	if not ref.is_empty():
		var r := MCPUITools.resolve_ref(ref)
		if not bool(r.get("ok")):
			return _fail(str(r.get("error", "ref 解析失败")))
		target_space = str(r.get("space", "window"))
		if target_space == "3d":
			return _activate_interactable_3d(str(r.get("path", "")), ref)
		pos = r["pos"]
		sub_vp_path = str(r.get("sub_viewport_path", ""))
	else:
		if not args.has("x") or not args.has("y"):
			return _fail("需提供 ref(get_interactables 返回的元素引用), 或 x + y; 可加 space 声明 x/y 属于 window(默认) 还是 viewport")
		space = VariantTool.get_string(args, "space", "window").strip_edges().to_lower()
		if space != "window" and space != "viewport":
			return _fail("space 只能是 window 或 viewport, 收到: %s; 子视口里的 UI(space=subviewport)请改用 ref 点击" % space)
		pos = Vector2(VariantTool.get_int(args, "x"), VariantTool.get_int(args, "y"))
		if space == "viewport":
			pos *= MCPUITools.window_scale()
	# x/y 是调用方自报坐标, 无从知道它指向哪个界面 —— 一律按窗口坐标注入, 与旧行为一致。
	var sub_vp: SubViewport = null
	if not sub_vp_path.is_empty():
		var loop := Engine.get_main_loop() as SceneTree
		sub_vp = loop.root.get_node_or_null(NodePath(sub_vp_path)) as SubViewport
		if sub_vp == null:
			return _fail("ref=%s 所在的子视口已不存在(界面已变化), 请重新调用 get_interactables。" % ref)
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = pos
	down_event.global_position = pos
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = pos
	up_event.global_position = pos
	if sub_vp != null:
		# 子视口元素: 直接投递给那个子视口, 与真人点 3D 平板时 SubView3D 的投递路径同源。
		# 必须先补一个 motion: push_input 是同步处理的, 不先把鼠标"挪到"目标上建立 hover,
		# 紧随其后的 press/release 不会让 BaseButton 进入按下态(实测: 补 motion 必中, 不补不中)。
		var move_event := InputEventMouseMotion.new()
		move_event.position = pos
		move_event.global_position = pos
		sub_vp.push_input(move_event)
		sub_vp.push_input(down_event)
		sub_vp.push_input(up_event)
	else:
		Input.parse_input_event(down_event)
		Input.parse_input_event(up_event)
	return _ok_json({
		"position": {"x": pos.x, "y": pos.y},
		"located_by": ("ref=%s" % ref) if not ref.is_empty() else ("x/y(space=%s)" % space),
		"space": target_space,
		"message": "鼠标左键点击事件已发送" if sub_vp == null else "鼠标左键点击事件已投递到子视口 %s" % sub_vp_path
	})


## 在 3D 物体自身上激活一次点击(不注入鼠标事件)。
func _activate_interactable_3d(path: String, ref: String) -> Dictionary:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return _fail("场景树不可用(游戏未运行?)")
	# 刻意声明为 Variant: activate()/_mouse_down() 不在基类上, 按 Node 静态类型调用过不了编译。
	var node: Variant = loop.root.get_node_or_null(NodePath(path))
	if node == null:
		return _fail("ref=%s 指向的 3D 物体已不存在(界面已变化), 请重新调用 get_interactables。" % ref)
	if node.has_method("activate"):
		node.activate()
	elif node.has_method("_mouse_down") and node.has_method("_mouse_up"):
		node._mouse_down()
		node._mouse_up()
	else:
		return _fail("3D 物体 %s 既无 activate() 也无 _mouse_down/_mouse_up, 无法激活" % node.name)
	return _ok_json({
		"located_by": "ref=%s" % ref,
		"space": "3d",
		"path": path,
		"message": "已在 3D 物体 %s 上激活一次点击(未注入鼠标事件)" % node.name,
	})


## 运行时: 模拟鼠标拖拽(左键按下->移动到目标->释放)
func _call_simulate_drag(args: Dictionary) -> Dictionary:
	var from_x: int = VariantTool.get_int(args, "from_x")
	var from_y: int = VariantTool.get_int(args, "from_y")
	var to_x: int = VariantTool.get_int(args, "to_x")
	var to_y: int = VariantTool.get_int(args, "to_y")
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
	var key_str: String = VariantTool.get_string(args, "key").to_lower()
	var pressed := VariantTool.get_bool(args, "pressed", true)
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


## ======= 运行时: 游戏进程用例(依赖项目单例 / 场景树 / 真实时间轴) =======

## 运行中的测试标志: run_tests(process=game) 阻塞执行期间为 true —— 供 _call_runtime_tool_async
var _game_tests_running := false


## 运行时: 在**游戏进程**里跑需要游戏进程的用例(`TestRunner` MODE_GAME)。**阻塞至跑完才返回**。
func _runtime_run_game_tests(args: Dictionary) -> Dictionary:
	var script := VariantTool.get_string(args, "script").strip_edges()
	if script.is_empty():
		return _fail("必须指定测试脚本(script: 脚本路径子串如 'test_game_replay', 或 'all' 全量, 或内联 GDScript 源码; 不支持默认全跑)")
	if _game_tests_running:
		return _err_validation("已有测试在运行, 请等待其结束或 game_control(action=stop) 终止后再调用",
			"等待当前用例结束(running=false)后再试")
	_game_tests_running = true
	# 传 _logger: 内联源码在游戏进程编译失败时取回该进程的具体解析错行。
	var summary: Dictionary = await TestRunner.run_all(script, TestRunner.MODE_GAME, _logger)
	_game_tests_running = false
	# run_all 已含 script 标签(内联为 "<inline>")/aborted/text 等; 补 done/running 供调用方判定。
	summary["running"] = false
	summary["done"] = true
	return _ok_json(summary)


## 运行时: 捕获游戏视口真实截图(文件名自动生成)
func _runtime_take_screenshot(args: Dictionary) -> Dictionary:
	var filename := ScreenshotTool.make_filename("mcp")
	var dir_path := "user://mcp_screenshots"
	var viewport := get_viewport()
	if viewport == null:
		return _fail("无法获取游戏视口")
	# 统一走 ScreenshotTool: 取图 -> 颜色处理(auto 判定, 出图即所见) -> 缩放 -> 保存。
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
	return _ok_json(result)


## ======= 编辑器模式的运行时工具转发(经 EngineDebugger 调试线) =======

## 编辑器进程: 解除游戏断点暂停(等效编辑器的 Continue 按钮)
func _call_debug_continue(_args: Dictionary) -> Dictionary:
	if not _has_game_session():
		return _fail("没有运行中的游戏, 无需继续")
	if not debugger_plugin.is_breaked():
		return _ok("游戏当前未处于断点暂停状态, 无需继续")
	if debugger_plugin.debug_continue():
		_game_breaked = false
		return _ok("已让游戏继续运行(解除断点暂停)")
	return _err_internal("无法解除断点暂停", "尝试 game_control(action=stop) 后 game_control(action=start) 重启")


## 读取游戏调用单次等待上限并做边界裁剪(实时读取, 改项目设置无需重启)。
func _game_call_timeout_ms() -> int:
	return clampi(int(ProjectSettings.get_setting(SETTING_GAME_CALL_TIMEOUT_MS, DEFAULT_GAME_CALL_TIMEOUT_MS)), 2000, 600000)


## 转发工具调用到游戏进程(经 EngineDebugger 调试线)。仅编辑器模式。
func _call_runtime_proxy(tool_name: String, args: Dictionary) -> Dictionary:
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		return _err_game_stopped("游戏未运行。请先使用 game_control(action=start) 启动游戏", "调用 game_control(action=start) 启动游戏, 等待调试线就绪后重试")
	if _game_breaked and not _BREAK_SAFE_TOOLS.has(tool_name):
		# 断点暂停: 依赖主循环的工具必然挂起; get_logs/clear_logs(process=game) 仍可用; 自动回查错误缓冲拼进响应。
		var diagnose := await _fetch_recent_game_error(tool_name)
		if diagnose != "":
			return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n已自动读取错误:\n%s\n\n修正脚本后 game_control(action=continue) 继续, 或 game_control(action=stop) 重启。" %
				[tool_name, diagnose])
		return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n错误缓冲无内容(可能是手动断点)。get_logs(process=game,kind=error)复核后 game_control(action=continue), 或 game_control(action=stop) 重启。" %
			tool_name, "get_logs(process=game,kind=error)复核后game_control(action=continue); 或game_control(action=stop)修复重启")
	if not _game_ready:
		return _err_transient("游戏调试线尚未就绪", "等待游戏启动完成(可稍后重试, 或 game_control(action=start) 重启)")
	var req_id := _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	debugger_plugin.send_call(req_id, tool_name, args)
	# 轮询等待游戏响应。会话断开时 _on_session_stopped 会填充失败结果;
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
	# 超时主因: eval触发运行期脚本错误导致_mcp_run中止未回发, 或是死循环/卡死。自动回查错误缓冲拼进响应。
	var diagnose := await _fetch_recent_game_error(tool_name)
	var secs := "%.1f" % (timeout_ms / 1000.0)
	if diagnose != "":
		# 同上面的 eval 分支: 原样重发同一工具必然再超时一次, 故 is_retryable=false。
		return _err_validation("游戏进程响应超时(%ss), 工具: %s。已发现运行期脚本错误:\n%s\n\n修正代码后重试; 若无疑错误仍超时再考虑死循环。" %
			[secs, tool_name, diagnose],
			"修正上方脚本错误后重试; 仍超时则 game_control(action=stop) 后 game_control(action=start) 重启")
	return _err("游戏进程响应超时(%ss), 工具: %s。错误缓冲无脚本错误, 可能是死循环/卡死或无响应。" % [secs, tool_name],
		MCPResult.CAT_TRANSIENT, true, "查 eval_code(process=game) 是否死循环; 必要时 game_control(action=stop) 后 game_control(action=start) 重启")


## 超时诊断: 回查游戏错误缓冲, 返回最近一条脚本错误描述(无则返回 "")
func _fetch_recent_game_error(tool_name: String) -> String:
	# 用内部 req_id 再发一次 get_logs(process=game, kind=error)(短超时), 避免二次长期挂起
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
	# 保留来源侧的 content[].text(错误响应里是 _err 拼的结构化 JSON): 代理归一化的只是
	var content_text := text
	if result.get("content") is Array:
		var c: Array = result["content"]
		if not c.is_empty() and c[0] is Dictionary:
			content_text = str(c[0].get("text", text))
	return _wrap(text, is_err, extra, content_text)


## eval_code 的 runtime 侧(服务器位于游戏进程内): process 只能是 game。
## **必须 await**: eval 代码含 await 时 _call_eval_code 会挂起, 漏 await 会把协程句柄当结果返回,
func _call_eval_code_local(args: Dictionary) -> Dictionary:
	if _require_process(args) != "game":
		return _fail("导出运行时没有独立的编辑器进程; eval_code 的 process 只能是 'game'")
	return await _mod("MCPDevTools")._call_eval_code(args)


## eval_code 的 editor 侧: process=editor 在编辑器进程执行; process=game 经预检 + 调试线转发。
## **必须 await**(同上): 否则 eval 含 await 时返回协程句柄, 客户端报 -32600。
func _call_eval_code_routed(args: Dictionary) -> Dictionary:
	if _require_process(args) == "game":
		return await _call_game_eval_proxy(args)
	return await _mod("MCPDevTools")._call_eval_code(args)


## 编辑器侧 eval_code(process=game) 的转发: 先本地预编译 + 静态检查, 通过后才发到游戏进程。
## 语法错误/被禁止的代码在编辑器内拦截, 避免污染游戏进程(运行时解析错误可能中断游戏)。
func _call_game_eval_proxy(args: Dictionary) -> Dictionary:
	var precheck: String = _mod("MCPDevTools").precheck_eval_code(VariantTool.get_string(args, "code"), _logger)
	if precheck != "":
		return _err_validation("eval_code(process=game) 被编辑器侧预检拦截: %s" % precheck, "修正代码后重新调用 eval_code(语法错误无法通过重试解决, 需修改代码)")
	## auto_resume: 调用方明确要求时先解除断点暂停再执行(默认不开, 避免掩盖真错误)
	if VariantTool.get_bool(args, "auto_resume") and _game_breaked:
		var resumed := await _call_debug_continue({})
		if bool(resumed.get("is_error", false)):
			return resumed
	return await _call_runtime_proxy("eval_code", args)
