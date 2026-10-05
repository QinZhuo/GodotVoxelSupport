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

## ------- 拆出的零状态协议层模块(preload, 非 class_name) -------
## 这三个模块只有静态方法、不持有状态, 且与本文件是**单向**依赖(它们不引用本文件),
## 所以拆出去是安全的。引用方式上的两条硬约束, 都是踩坑换来的:
##
##   1. 三个模块**必须带 @tool**(与本文件一致)。
##      缺 @tool 时编辑器**跳过完整语义分析**, 于是模块里的解析期错误不会被发现,
##      lint 也会静默跳过它们 —— 表现为"静态检查全绿, 运行时才炸"。真实的一次:
##      MCPToolSchema 误用了 Godot 3 的 Dictionary.merge_in(Godot 4 只有返回新字典的
##      merge), 编译失败 → GDScript 没有成员表 → preload 拿到的脚本 is_tool() 为 false、
##      get_script_method_list() 为空 → MCPResult.ok / MCPToolSchema.logs 全部报
##      "Nonexistent function 'xxx' in base 'GDScript'"(方法确实存在于磁盘源码中)。
##      又因为**每个 handler 都经 _ok/_err 收口**, 一处不可达就等于全服务器工具同时返回
##      空结果, 表现为"每个调用都返回一段警告文本"。
##      排查这类"方法明明存在却说没有"的空壳脚本, 用这三招(eval_code 里直接跑):
##        S.is_tool()                  # false = 没被当成 tool 脚本分析
##        S.get_script_method_list()   # []    = 没编译出任何成员
##        S.reload()                   # 返回非 0 = 解析/编译失败, 详细错误在编辑器输出
##   2. 引用必须用 preload 而不是 class_name: 本文件既是 autoload 又是被插件 load() 动态
##      加载, 新建的 class_name 未必已进全局类缓存, 标识符会解析不到; 反过来若模块内
##      声明 class_name, 这里的同名 const 又会触发 "hides a global script class"。
##      故三个模块一律不声明 class_name。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")
const MCPToolMeta := preload("res://addons/DEVFramework/MCP/MCPToolMeta.gd")
const MCPArgCheck := preload("res://addons/DEVFramework/MCP/MCPArgCheck.gd")
const MCPScriptSync := preload("res://addons/DEVFramework/MCP/MCPScriptSync.gd")
const MCPToolAudit := preload("res://addons/DEVFramework/MCP/MCPToolAudit.gd")
## 输出整形层(序列化转义兜底 + 统一输出上限截断)。与其它 preload 的区别: 它既不注册工具也不
## 提供协议端点, 而是**全部工具共用的一道关口**, 详见该文件顶部注释。
const MCPFormat := preload("res://addons/DEVFramework/MCP/MCPFormat.gd")

## ------- 工具域文件 -------
## 每个域收编一组工具的「注册 + schema + handler + 专属辅助函数」, 统一暴露
## `static func register(add_tool: Callable) -> void`; 本文件只负责把 _add_tool 传进去。
##
## 依赖严格单向: 本文件 -> 域文件, 域文件不引用本文件, 也不持有服务器状态。域内 handler 一律
## static, 因此 MCPToolAudit 靠 get_method() 做的入参一致性自检照常有效(改用 lambda 注册会
## 让 get_method() 返回空串, 那批工具将静默跳过自检 —— 见 MCPToolAudit 开头)。
##
## **但接缝不止 register 一种形态 —— 照着"域 = 一个 register"去接线一定会漏。**
## 下面这份表是**实测**的各域导出(不是设计意图), 新增域时按它补一行:
##   MCPValidateTools / MCPResourceTools / MCPSceneTools / MCPFileTools / MCPCodeIndex
##       register
##   MCPLogTools        register + bind_logger(logger)
##                      —— get_game_logs / get_game_errors 复用日志捕获器, 游戏进程侧漏注入时
##                         它们显式返回"日志捕获器未就绪"(这条是显式的, 不会静默)
##   MCPDevTools        register + set_eval_ctx_provider(provider)
##                      —— game_eval / auto_verify 的新鲜度闸门要用 _mode 与游戏启动时刻。
##                         漏注入**不报错**, 守卫静默全放行且运行期错误捕获不到, 症状是
##                         "game_eval 的问题查不出来"
##   MCPProjectTools    register + set_session_facts_provider(provider)
##   MCPScreenshotTools **没有 register**: take_screenshot 的默认模式 text 必须经本文件的
##                      _call_runtime_proxy 转发到游戏进程(内部挂 _pending / debugger_plugin),
##                      静态化不了。它只暴露 spec()(desc/schema 单副本) + capture_editor_side(),
##                      由本文件在 _register_runtime_tools 里那一处注册点调用。
##   MCPEditorEnv       **不是工具域**: 跨域共享的编辑器环境辅助, 无 register 也不注册工具。
##                      它原本是本文件的实例方法 _edited_root(), 被三个域同时用, 不属于任何
##                      单一域, 所以提到共享层而不是让每域留一份私有副本(副本分叉的症状从
##                      调用栈看不出根因)。
const MCPCodeIndex := preload("res://addons/DEVFramework/MCP/MCPCodeIndex.gd")
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")
const MCPDevTools := preload("res://addons/DEVFramework/MCP/MCPDevTools.gd")
const MCPFileTools := preload("res://addons/DEVFramework/MCP/MCPFileTools.gd")
const MCPLogTools := preload("res://addons/DEVFramework/MCP/MCPLogTools.gd")
const MCPProjectTools := preload("res://addons/DEVFramework/MCP/MCPProjectTools.gd")
const MCPResourceTools := preload("res://addons/DEVFramework/MCP/MCPResourceTools.gd")
const MCPSceneTools := preload("res://addons/DEVFramework/MCP/MCPSceneTools.gd")
const MCPScreenshotTools := preload("res://addons/DEVFramework/MCP/MCPScreenshotTools.gd")
const MCPTestTools := preload("res://addons/DEVFramework/MCP/MCPTestTools.gd")
const MCPUITools := preload("res://addons/DEVFramework/MCP/MCPUITools.gd")
const MCPValidateTools := preload("res://addons/DEVFramework/MCP/MCPValidateTools.gd")

##   3. **改上面几个模块后, refresh_tools 不足以让改动生效** —— 但**解法不是 reload 本文件**
##      (见第 4 条, 那会杀死服务器)。实测有效的链路只有一条, 分两种情况:
##
##      **A. 改的是 MCPToolMeta / MCPToolSchema / MCPResult / MCPArgCheck / MCPScriptSync**
##         (即除本文件外的 preload 依赖) —— 用 eval_code 原地重载, 再 refresh_tools:
##           for n in ["MCPToolMeta", "MCPToolSchema"]:
##               load("res://addons/DEVFramework/MCP/%s.gd" % n).reload(true)
##         之所以有效: const 持有的是 GDScript **对象**, 而 reload() 是**原地重新编译**同一个
##         对象, 故 const 引用自动指向新代码, 无需重载本文件。
##
##      **B. 改的是本文件自身**(工具描述/schema 字面量都在这里) —— 无法热生效, 只能重启:
##         在编辑器「插件」里取消勾选 DEVFramework 再重新勾选(或重启编辑器)。
##
##      为什么不能直接 reload 本文件: 本文件正承载着 HTTP 服务器(_http 字段), 原地重载会
##      终止该服务器, 之后 MCP 端口不再监听、所有调用返回"无法连接", 且**无法再靠 MCP 工具
##      自救**(restart_editor / refresh_tools 都调不到了), 只能去编辑器里重新启用插件。实测踩过。
##      边界: 本文件内另外两处 reload()(两个 eval 入口)编译的都是 eval_code 用的**临时**脚本
##      (GDScript.new(), 无资源路径, 不进 Resource 缓存), 与此无关; 第三条编译路径(脚本校验)
##      搬去了 MCPValidateTools.gd, 同样不碰本文件。
##      这条边界原先还带一个洞: MCPScriptSync._guard_editor 会对磁盘有改动的每个 .gd 做
##      CACHE_MODE_REPLACE 重载, 而集合里**包含本文件** —— 改完本文件而服务器实例尚未重建时,
##      eval_code 的守卫路径会顺手把本文件也重载掉, 于是 eval 执行到一半服务已死、端口失联。
##      现已兜住: 本文件在编辑器进程的 _ready 里把自己登记进 MCPScriptSync._unreloadable,
##      _guard_editor 会先分流 —— 显式阻止并指引重启, 而不是静默重载。
##
##      判据: 改完量一次 tools/list 字符数, 未变即未生效 —— 别把"refresh_tools 报告成功且
##      契约自检 pass"当成生效证据, 它在未生效时同样返回成功。

## ------- 配置项(ProjectSettings) -------
const SETTING_ENABLED := "dev_framework/mcp/enabled"
const SETTING_PORT := "dev_framework/mcp/port"
const SETTING_TOKEN := "dev_framework/mcp/token"
const SETTING_MAX_OUTPUT_CHARS := "dev_framework/mcp/max_output_chars"
const SETTING_LOG_TOOL_RESULTS := "dev_framework/mcp/log_tool_results"

## 统一输出上限默认值(字符)。超限则**截断**返回并附续读提示, 而非整条拒绝。
##
## 取值 24000 的推导(两级约束, 取更严的那个):
##
##   1. 客户端侧对单次工具输出另有约 51200 字符的硬上限, 超出后**静默**截断, 调用方拿不到
##      任何"数据不完整"的信号。原默认值 90000 高于它, 实测 get_scene_tree 无参调用返回
##      60453 字符时本层直接放行, 随后被无声切掉 9253 字符 —— AI 拿着残缺场景树以为看全了。
##   2. **同一份内容会被写两遍**: MCPResult 出于兼容同时输出顶层 text 与规范要求的
##      content[0].text(实测两者长度完全相同)。所以 24000 字符的正文在响应体里是 48000,
##      必须连双写一起算, 否则限了等于没限 —— 这也是先取 30000 时实测响应仍有 64797
##      字符(其中 60000 是同一内容的两份拷贝)的原因。
##
## 24000 × 2 = 48000 < 51200, 留出协议包装层余量。
const DEFAULT_MAX_OUTPUT_CHARS := 24000


## ------- MCP 常量 -------
## PROTOCOL_VERSION 是**回落版本**: 客户端既没在 HTTP 头声明、也没在 _meta 声明时用它。
## 保持它在 2025-03-26 是刻意的 —— 现役客户端(Claude Code / Cursor 等)全部按旧握手走,
## 抬高回落值会让它们在 initialize 阶段就看到不认识的版本号。
const PROTOCOL_VERSION := "2025-03-26"

## 支持的协议版本, 新到旧。用于 initialize 的版本回显与 -32022 的 supported 列表。
##
## 维护多版本是必需的, 不是过度设计: 版本号是"最后一次**向后不兼容**变更"的日期, 而
## 客户端各自锁定的日期不同(它声明什么, 我们就必须能接住)。规范里也写明服务端可以
## 同时支持多个版本。只认最新版会让所有老客户端直接失联。
##
## 但"支持多版本"**不等于为每版写一套实现** —— 差异其实只有一处: 新字段要不要发。
## 见 _decorate_result: 新字段只发给 SUPPORTED_PROTOCOL_VERSIONS[0], 旧版一律不发。
## 新字段对老客户端是未知的会被忽略, 反过来给老版塞新字段才是破坏兼容。
##
## 2025-06-18 在列表里但无行为差异(它与 2025-03-26 的唯一区别是 structuredContent,
## 而本服务器对所有版本都发 structuredContent), 列出来是为了不拒掉恰好要这一版的客户端。
## 2025-11-25 是**握手式协议(2026-07-28 之前)的最后一版**, 各家 SDK 普遍把它标为
## latestInitializationProtocolVersion / 最新支持版。它带来的是 Tasks 持久化状态机、
## Sampling 里的 Tool use、增强版 Elicitation —— 这些本服务器一概没有, 故与 2025-06-18
## 一样无行为差异; 列它是为了让恰好要这一版的客户端能**精确命中**。此前列表漏了它,
## 结果这类客户端会被 _negotiate_version 一路降级到 2025-06-18 才停下 —— 多数客户端能接受,
## 但严格锁版的客户端就会因版本号对不上而断连。
const SUPPORTED_PROTOCOL_VERSIONS := ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

## 2026-07-28 起, 版本改为**逐请求**声明, 且 HTTP 传输必须同时带同名头。
const META_VERSION_KEY := "io.modelcontextprotocol/protocolVersion"
const META_CLIENT_CAPS_KEY := "io.modelcontextprotocol/clientCapabilities"
## 首个"逐请求声明版本"的协议版本。自该版本起规范要求每个请求的 _meta 同时声明
## protocolVersion 与 clientCapabilities, 缺任一即为 malformed request(必须回 -32602)。
## 更早的版本是握手式, _meta 里本就没有这两个字段 —— 所以这个要求**只对声明了
## META_REQUIRED_SINCE 的请求生效**, 否则会把现有旧版客户端全部拒掉。
const META_REQUIRED_SINCE := "2026-07-28"
const HEADER_VERSION := "mcp-protocol-version"

## ======= 错误码: 本文件唯一的错误码事实来源 =======
##
## 收敛前 -32602/-32700/-32601/-32603/-32000 全部以裸字面量散落在各处, 只有两个 2026-07-28
## 的新码被提成了常量。结果是"同一个错误在两处用不同写法", 改错误码语义/对齐规范时要逐处
## 搜索漏改, 而漏改的那一处不会报错, 只会在客户端那边表现为莫名奇妙的报错分类。
## 标准 JSON-RPC 2.0 的码不是 MCP 私有约定, 但集中在文件头声明一次, 至少让它们可被静态检查。
## 请求体不是合法 JSON。进 JSON-RPC 之前就失败, 无 req_id 可回。
const ERR_PARSE := -32700
## JSON-RPC 层: 方法名不在 _handlers 里。
const ERR_METHOD_NOT_FOUND := -32601
## JSON-RPC 层: 参数结构/取值不合法(同参数重试无意义, 故不可重试)。
const ERR_INVALID_PARAMS := -32602
## JSON-RPC 层: 服务端内部状态异常(通常是 handler 未产出结果)。
const ERR_INTERNAL := -32603
## 传输层拒绝: 请求根本没进 JSON-RPC(方法不支持 / 鉴权失败 / Origin 被拦)。
## 规范把 -32000~-32099 定为"实现自用", MCP 自己没给这三种场景分配码, 故共用一个。
const ERR_TRANSPORT_REJECTED := -32000
## 2026-07-28 新增错误码(规范 baseline 里 -32000 段由 MCP 自用)。
## HTTP 头声明的版本与 _meta 声明的不一致。
const ERR_HEADER_MISMATCH := -32020
## 协商完成后仍发来不受支持的版本。
const ERR_UNSUPPORTED_VERSION := -32022

## tools/list 等可缓存结果建议的缓存时长。工具清单在进程生命周期内是静态的
## (_tool_defs 只在初始化/refresh_tools 时填充), 故给一个较长的 TTL。
##
## TTL 只是**兜底上限**, 不是"改了会自动通知"的机制: 本服务器是一次请求一个连接的短连接
## HTTP, 推不出 notifications/tools/list_changed(capabilities 里已如实报 listChanged:false),
## 客户端缓存一旦建立就只能等它自己过期或被 IDE 侧重连刷新。写"refresh_tools 后客户端会
## 重新拉取"是错的 —— 那不是本服务器能保证的事, 别再让文案暗示它。
const LIST_TTL_MS := 600000

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
## 是否已与某个客户端完成过 initialize 版本协商(进程级单标志)。
## 用途: 在协商完成之前, 对不认识的协议版本一律**降级**而不是拒绝 —— 因为握手期的严格
## 只会换来失联(客户端不会重试、也不会换版本), 而此时我们还不知道客户端要干什么,
## 猜错版本顶多导致响应形状差一点, 远好过整个连不上。协商完成后再严格, 此时客户端理应
## 已经改用协商好的版本, 还在发陌生版本就说明它跳过了握手或中途换了版本, 该拒。
var _version_negotiated := false
var _tool_handlers := {} # 工具名 -> Callable
var _tool_defs := [] # 工具定义列表(MCP 格式)
var _tool_schemas := {} # 工具名 -> inputSchema。tools/list 要的是数组(协议规定),而入参校验
	# 要的是按名直查 —— 遍历数组去找会得到**注册顺序上的第一个同名项**, 一旦将来出现同名
	# 注册(先注册的后覆盖), 校验就会拿错 schema 且毫无征兆。故两份索引分开存, 各按各的形状用。
var _mode := MODE_EDITOR # editor / runtime

## 编辑器模式: 指向 MCPDebuggerPlugin(由 plugin.gd 注入)
var debugger_plugin: MCPDebuggerPlugin = null
## 编辑器模式: 游戏进程 MCP 桥接是否就绪(收到 dev_mcp:ready)
var _game_ready := false
## 当前游戏调试会话的启动时刻(unix 秒); 0 = 没有游戏在运行。
## 用途: 作为游戏侧新鲜度判据的基准(见 MCPScriptSync.guard_eval), 记录在会话建立/结束时更新
var _game_started_at: int = 0
## 编辑器模式: 等待游戏响应的请求表 req_id -> 结果(未就绪为 null)
var _pending := {}
var _next_req_id := 1
## 编辑器模式: 游戏是否处于断点暂停状态(脚本错误/断点导致主循环暂停)
var _game_breaked := false
## 断点暂停时仍可安全执行的工具(只读缓冲, 不依赖游戏主循环):
## 游戏被暂停时 EngineDebugger 调试线程仍活着, 这类工具仅读本地缓冲即返回, 不会挂起。
const _BREAK_SAFE_TOOLS := ["get_game_errors", "get_game_logs"]

## 逐条 JSON-RPC 请求日志的开关(现场可 set, 不必重启编辑器)。
static var _log_rpc := false

## verify_fix 会话(editor 侧): 按 session_id 存验证配置, 支持 start/continue/status/abort 多会话
var _verify_sessions: Dictionary = {}

## 最近一次工具契约自检的问题列表(空 = 通过)。由 _audit_tools 写入,
## 供 refresh_tools 响应回给 AI —— 否则自检结果只能翻编辑器日志, 等于没有。
## 工具名 -> "入参自检该切哪个 handler"。与 _tool_handlers 的差别: _tool_handlers 存的是
## **实际被调用的**那一份, 而转发型工具注册进去的是纯转发 lambda(编辑器侧经调试线转发到游戏
## 进程), 转发器不读任何入参键, 自检切它只能得到空结论 —— 那等于把"没查"报成"通过"。
## 这里存的是同一工具的**具体实现**, 即真正读入参的那份代码。
var _tool_audit_handlers := {}

var _tool_audit_issues: Array[String] = []


## ------- 生命周期(autoload) -------
func _ready() -> void:
	instance = self
	_enabled = ProjectSettings.get_setting(SETTING_ENABLED, true)
	_port = int(ProjectSettings.get_setting(SETTING_PORT, 8931))
	if Engine.is_editor_hint():
		# 编辑器进程: 生命周期完全由 plugin.gd 控制(启用时 start_editor()/停用时 stop())。
		# 这里仅登记 instance, 不自动启动, 避免与插件开关产生端口/生命周期冲突。
		# 顺带把自己登记为"不可热重载"(见文件顶部 B 条): 原地重载本文件会终止 HTTP 服务器,
		# 且之后所有工具都调不到。登记后 MCPScriptSync._guard_editor 会先分流、显式阻止并
		# 指引重启, 而不是静默重载把整条 MCP 通道关掉。
		MCPScriptSync.register_unreloadable(get_script().resource_path, "承载 MCP HTTP 服务器")
		return
	# 游戏进程: 仅注册调试线消息捕获器, 供编辑器经 EngineDebugger wire 调用运行时工具。
	# 不开启任何端口; 正常手动运行/发布版无调试线, 捕获器注册后无消息到达, 无副作用。
	if not _enabled:
		return
	_mode = MODE_RUNTIME
	# 游戏侧新鲜度基准(见 MCPScriptSync.guard_eval)。必须在游戏进程内自己记一份 ——
	# 编辑器侧的同名变量由会话回调赋值, 游戏进程没有那些回调, 漏设会让判据退化成
	# "无基准=全部放行", 等于闸门失效。取 autoload 就绪时刻而非调试线就绪时刻:
	# autoload 先于主场景加载, 取早了不会误报(加载时读到的就是磁盘最新版本)。
	_game_started_at = int(Time.get_unix_time_from_system())
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
	## 长任务(游戏用例)运行期间: 需要主循环的工具会被用例拖慢, 多数会干等到超时才报错。
	## 这里立即返回 busy, 让调用方先读进度 —— 读缓冲类工具与用例自身仍放行。
	if _game_tests_running and tool_name != "run_game_tests" and not _BREAK_SAFE_TOOLS.has(tool_name):
		result = _err("游戏用例正在运行, 工具 %s 需要主循环, 现在调用既会拖慢用例也大概率超时。\n请先反复调用 run_game_tests 读进度直到 running=false, 或用 game_control(action=stop) 终止用例。" % tool_name,
			"busy", true, "run_game_tests读进度至running=false后再调用; 或game_control(action=stop)终止用例")
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
			# 覆盖"会话建立 → 就绪"这段时间内的改动, 把闸门的误报窗口压到最小
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
## 等待中的 _call_runtime_proxy 能立即读到(而不是干等超时)。
## 注意: 填充后不能 clear(), 否则代理读不到结果会退回 20s 超时。
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
## 此时运行时工具若发请求会干等超时, 应立即填充未决请求为明确错误, 让 AI 知道是"游戏被调试器暂停"而非无响应。
func _on_session_breaked(_session_id: int, can_debug: bool) -> void:
	_game_breaked = true
	LogTool.log("MCP", "游戏已进入断点暂停(调试循环=%s)。运行时工具会立即返回明确错误, 可用 game_control(action=continue) 让游戏继续。" % str(can_debug))
	var msg := "游戏被断点暂停(脚本错误/断点)。get_game_errors/get_game_logs仍可用, 先查错误; 再game_control(action=continue)继续; 要修脚本则game_control(action=stop)后改代码重跑。"
	for req_id in _pending:
		if _pending[req_id] == null:
			_pending[req_id] = _err_game_breaked(msg)


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


## 当前真正持有监听端口的实例(进程内至多一个)。
##
## 编辑器进程里其实有**两个** MCPDevServer: project.godot 里的 autoload 行, 以及 plugin.gd
## 用 MCPDevServer.new() 建的子节点(真正在监听的是后者)。所以"该不该启动/自愈"必须按
## **实例身份**判断, 不能只看 _http 是不是 null —— 否则 autoload 那个从不监听的实例会
## 误以为服务器挂了, 反复去 bind 已被占用的端口, 每 5 秒刷一条绑定失败。
##
## 更关键的是脚本热重载会把**实例**成员变量全部重置为默认值: _http 变成 null, 它持有的
## TCPServer 随之被 GC 释放、监听端口关闭, MCP 服务器就此静默死亡 —— 现象是"AI 突然连不上",
## 日志里却没有任何报错, 只能靠重启编辑器恢复。
##
## 这里用 static 而非成员变量: 只有 static 能活过热重载。换成成员变量的话, "本来在跑但被
## 重载清掉"和"本来就没在跑"就都成了 null, 恰好分不出该自愈的那种情况。
static var _owner = null
static var _last_autostart := 0


## 每帧驱动 HTTP 服务器, 并在它意外消失时自动拉起
func _process(_delta: float) -> void:
	if _http:
		_http.poll()
		return
	# 自愈只在"这个实例本来就该监听"时发生: 热重载把 _http 清成 null 后端口已被释放,
	# 而用户和插件都没主动停过, 该自动重开, 否则每次改框架脚本都得重启编辑器才能继续用 MCP。
	# 启动本身仍可能失败(端口被别的进程占着), 故按时间节流, 免得每帧都去 bind 刷错误日志。
	if _owner != self or not Engine.is_editor_hint():
		return
	var now := Time.get_ticks_msec()
	if now - _last_autostart < 5000:
		return
	_last_autostart = now
	LogTool.log("MCP", "检测到 MCP 服务器已停止(通常是脚本热重载清掉了状态), 正在自动重新启动…")
	start_editor()


## tools/list 内容指纹: 把当前注册表压成一个短十六进制串。
##
## 存在的理由: "改完生效了吗"在这套架构里**无法从返回值判断**。refresh_tools 改的是正在
## 运行的实例, 它自己的执行必然是"新"的, 于是无论工具表实际变没变, 返回的都是成功; 而
## 客户端是否同步又是另一件事(短连接推不出通知)。两边都只能靠猜, 猜错就会拿着**旧 schema**
## 继续改代码 —— 那比没改更糟, 因为它看起来是验证过的。
##
## 有了指纹, 这件事变成可测量的: 改代码 → refresh_tools → 指纹变了 = 工具表真的变了;
## 指纹没变 = 注册表压根没重建成功(典型如改了 MCPDevServer.gd 自身而实例没重启)。
##
## 用 JSON.stringify 而非 str(): 后者对嵌套 Dictionary 的键序不保证稳定, 指纹会随内容
## 不变而变, 比对立刻失去意义。
func _schema_fingerprint() -> String:
	return "%08x" % (JSON.stringify(_tool_defs).hash() & 0xFFFFFFFF)


func _call_refresh_tools(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可用")
	_register_editor_tools()
	var count := _tool_defs.size()
	var fp := _schema_fingerprint()
	LogTool.log("MCP", "手动重建工具注册表: %d 个工具, 指纹 %s" % [count, fp])
	# 把契约自检结果一并回给 AI: 否则自检只落到编辑器日志里, 等于没有 —— AI 改完框架脚本
	# 调 refresh_tools, 期望的正是"我这次改动是否引入了契约问题"这一条答案。
	#
	# message 里明说客户端不一定同步: 本服务器推不出 tools/list_changed, 拿"客户端会自动
	# 重新拉取"当前提是错的(见 LIST_TTL_MS 与 _server_capabilities 的说明)。不写清楚的话,
	# 调用方会拿 tools/list 里**会话开始时的旧快照**当权威, 并据此认为改动已生效。
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
## 由 AI 调用 refresh_tools 手动重建注册表, 客户端重新拉取 tools/list 即生效, 无需重启编辑器。
##
## **边界**: 只对"被本服务器 preload 的其他脚本"生效(MCPToolMeta / MCPToolSchema 等)——
## 它们是独立 Script 资源, 编辑器文件系统扫描会重载, 静态函数随之更新。
## 而本文件(MCPDevServer.gd)自身的方法体不会被热替换进**已在运行的实例**, 故改本文件时
## 必须重建服务器实例(禁用再启用插件 / restart_editor)。此时 refresh_tools 依旧返回成功,
## 工具表却原样不变 —— 这个"静默无效"是本条注释存在的唯一理由。


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
	# 只在**监听成功**后才认领 owner: 绑定失败还标记成"该我监听", 会让自愈反复重试
	# 一个根本轮不到自己的端口。
	_owner = self
	_http.request_received.connect(_on_request)
	# 工具名清单不打: 49 个名字会占满日志, 而它是静态的, 客户端随时能用 tools/list 查。
	LogTool.log("MCP", "MCP 服务器已开启(%s): http://127.0.0.1:%d/mcp, 已注册 %d 个工具" % [_mode, _port, _tool_defs.size()])


func stop() -> void:
	if _owner == self:
		_owner = null
	if _http:
		_http.request_received.disconnect(_on_request)
		_http.stop()
		_http = null


func is_running() -> bool:
	return _http != null and _http.is_listening()


## ------- 工具注册 -------
## 协议字段(title/annotations/outputSchema)统一由 MCPToolMeta 生成, 注册点只关心
## "名字 + 说明 + 入参 schema + handler" 四件事。少一个字段不会编译失败、也不会在
## tools/list 里报错, 只会让客户端把它当破坏性工具反复确认 —— 故用单一构建口杜绝漏填。
func _add_tool(name: String, desc: String, input_schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_schemas[name] = input_schema
	_tool_defs.append(MCPToolMeta.build(name, desc, input_schema))


## ======= 工具参数 schema =======
## 直接调用 MCPToolSchema 的工厂, 不在本文件另设转发层。
## 转发层曾用于让拆分可回退, 拆分早已完成并验证通过, 它的可回退价值已经兑现完; 留着它
## 只会让**同一个概念有两个名字**(_path_arg 与 MCPToolSchema.str_arg), 新增工具的人得
## 先猜该用哪个 —— 这正是"接口不统一"的具体代价。各工厂的设计依据见 MCPToolSchema 内的注释。


## 通用游戏操作工具注册: editor 侧 handler 经调试线转发, runtime 侧就地执行
func _register_game_play_tool(name: String, desc: String, schema: Dictionary, runtime_handler: Callable, editor_handler: Callable) -> void:
	# 登记"入参自检该切哪一份"。两个 handler 里必有一个是纯转发 lambda, 而转发器不读任何入参键:
	# 自检切它会因切不出函数体而**静默跳过**(见 MCPToolAudit.audit_handler_params), 于是这批工具
	# 永久退出检查范围且无任何迹象。故把那份具体实现登记下来, 由自检去切它。
	for h in [runtime_handler, editor_handler]:
		var m := String(h.get_method())
		if m != "<anonymous lambda>":
			_tool_audit_handlers[name] = h
			break
	if _mode == MODE_EDITOR:
		_add_tool(name, desc, schema, editor_handler)
	else:
		_add_tool(name, desc, schema, runtime_handler)


func _reset_tools() -> void:
	_tool_handlers.clear()
	_tool_defs.clear()
	# _tool_schemas 与 _tool_audit_handlers 一并清: 三份索引必须同增同减。少清一份当下不会报错
	# (遍历 _tool_defs 走不到残留项), 只会在工具改名/删除后留下一条"按名可查、却不对应任何已注册
	# 工具"的脏记录 —— 而那种残留恰好会在同名工具将来重新注册时静默生效, 比缺字段更难查。
	_tool_schemas.clear()
	_tool_audit_handlers.clear()


func _register_editor_tools() -> void:
	_reset_tools()
	_register_validate_tools()
	_register_log_tools()
	_register_scene_tools()
	_register_project_tools()
	_register_run_tools()
	_register_dev_tools()
	_register_file_tools()
	_register_game_play_tools()

	## 域文件注册。放在各 _register_* 之后: 域文件不认识本服务器, 只能靠传入 _add_tool 完成
	## 注册, 所以它们的工具统一排在主文件工具之后。
	MCPCodeIndex.register(_add_tool)
	# eval_code 的运行时上下文(mode / 游戏启动时刻 / 日志捕获器)全是实例状态, 域文件拿不到,
	# 经 provider 注入。**游戏进程侧也必须注入**(见 _register_runtime_tools): 那边的 game_eval
	# 等宿主工具根本不走 register(), 漏注入时守卫会静默全放行且运行期错误完全捕获不到,
	# 两种都不报错, 只表现为"game_eval 的问题查不出来"。
	MCPDevTools.set_eval_ctx_provider(func(): return {"mode": _mode, "game_started_at": _game_started_at, "logger": _logger})
	MCPDevTools.register(_add_tool)
	MCPResourceTools.register(_add_tool)

	_audit_tools()


## ======= 契约自检 =======
##
## 为什么必须有: 全部工具(主文件 + 各域文件)都是手写注册, 而协议层的失败模式**全部是静默的**
## —— handler 漏注册(调用时报 Unknown tool)、schema 少一个 properties(客户端按 schema 校验后
## 把合法参数当非法)、annotations 名单写了不存在的工具名(白填)。没有任何一种会编译报错。
## 这不是假设: 本框架此前就有 _call_set_node_transform 实现完整却从未注册的死代码,
## 以及 SETTING_MAX_MESSAGES 定义后全项目无读取点的死设置, 两者都是靠人工翻代码发现的。
## 拆分之后这条自检比拆分前更要紧: 域文件的 schema 与 handler 分处两个文件, 一旦主文件
## 忘了把某个域接进来, 上面三种静默失败会有两种同时发生。
##
## 挂在两处注册收尾: 编辑器侧(_register_editor_tools 末)与游戏进程侧(_ready 的 runtime
## 分支末)。各自只跑一次, 不重复告警。
func _audit_tools() -> void:
	# 自检规则本身在 MCPToolAudit 里; 这里只负责喂数据 + 报结果。
	#
	# 传进来的路径只用于**定位目录**: MCPToolAudit 会展开该目录下的全部 .gd, 而不是只扫本文件
	# —— handler 已按域拆到 MCPCodeIndex 等文件, 只扫本文件等于那些域的入参一致性自检静默失效。
	# 刻意不维护"要扫哪些文件"的名单: 名单会漏, 而漏掉的形态就是"那批工具永远通过检查"且无任何
	# 迹象。理由详见 MCPToolAudit 的扫描范围说明。
	# registry_is_full: 只有编辑器进程注册全量工具。游戏进程只注册运行时那部分, 在那里做
	# "名单里的工具名是否都已注册"的反向校验会把分模式注册误报成名单未同步(实测刷 33 条)。
	_tool_audit_issues = MCPToolAudit.audit_tools(_tool_defs, _tool_handlers, get_script().resource_path, _tool_audit_handlers, _mode == MODE_EDITOR)
	# 自检通过是常态, 静默即可; 只在发现问题时报警, 否则每次启动都要宣告一遍"没问题"。
	if not _tool_audit_issues.is_empty():
		LogTool.log("MCP", "工具契约自检发现 %d 个问题:\n  - %s" % [_tool_audit_issues.size(), "\n  - ".join(_tool_audit_issues)])


## ------- 工具实现 =======

## -- 脚本/资源验证 --
## desc / schema / handler 已全部搬进 MCPValidateTools.register —— 契约单副本。
func _register_validate_tools() -> void:
	MCPValidateTools.register(_add_tool)


## -- 日志/错误 --
## 日志类工具的进程归属**只由工具名决定**, 不由参数决定: 本函数注册的这一对只读编辑器进程
## 自己的缓冲, 游戏进程的一律 get_game_*/clear_game_*。这条判据与"旧的 source=auto 三档"
## 为何要收掉的历史理由已搬进 MCPLogTools 顶部, 留一份在这里只会与域文件各说各话而漂移。
func _register_log_tools() -> void:
	# 游戏进程侧的 get_game_logs / get_game_errors / clear_game_errors / clear_game_logs
	# 也复用 MCPLogTools 的底层件, 所以**两个进程都要注入捕获器**。漏注入时那几个工具会
	# 显式返回"日志捕获器未就绪"(不是静默失效), 见 MCPLogTools.bind_logger 的注释。
	MCPLogTools.bind_logger(_logger)
	MCPLogTools.register(_add_tool)


## -- 场景树 / 节点 + 场景编辑 --
## 原先分两组注册(读: _register_scene_tools, 写: _register_scene_edit_tools), 现合并为一次
## MCPSceneTools.register: 9 个工具同属一个域, 拆成两次调用只会让"一个域一次注册"出现两种
## 粒度。desc / schema / handler 全在域文件内, 契约单副本。
func _register_scene_tools() -> void:
	MCPSceneTools.register(_add_tool)


## -- 项目信息 --
## get_project_info / get_editor_activity 迁到 MCPProjectTools。两个 handler 都需要宿主侧的
## 会话事实(mcp_running / game_running / bridge_ready), 那是主服务器的实例状态, 域文件拿不到,
## 故这里注入一个 provider。**必须现取现用而不是注册时拍快照** —— 用户随时启停游戏, 快照过了
## 第一次 refresh_tools 就永久过期, 表现为"游戏正跑着而 get_editor_activity 报 game_running=null",
## 反而会邀请 game_control 去抢占一个正在运行的会话。
func _register_project_tools() -> void:
	MCPProjectTools.set_session_facts_provider(func() -> Dictionary:
		return {
			"mcp_running": is_running(),
			"game_running": _has_game_session(),
			"bridge_ready": _has_game_session() and _game_ready,
		})
	MCPProjectTools.register(_add_tool)


## -- 运行游戏 --
func _register_run_tools() -> void:
	_add_tool("game_control",
		"游戏运行控制。action=start: 以调试模式启动(等效F5, 自动建EngineDebugger调试线; scene缺省用主场景且支持 uid:// 形式; 游戏已在运行时自动停止旧实例后重启); action=stop: 停止运行中的游戏; action=continue: 解除因脚本错误/断点被暂停的游戏(等效Debugger面板Continue)—— 工具报 error_category=game_breaked 时用它恢复, 未暂停时调用是安全的空操作。【副作用】start/stop 会抢占并中断用户手头正在玩的那个游戏进程 —— 执行前先用 get_editor_activity 确认没有正在进行的调试, 执行后游戏不会自动恢复。",
		{"type": "object", "properties": {
			"action": {"type": "string", "enum": ["start", "stop", "continue"], "description": "启动/停止/解除断点暂停"},
			"scene": {"type": "string", "description": "action=start 时可选: 要运行的场景 res:// 或 uid:// 路径"}
		}, "required": ["action"]},
		_call_game_control)

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


## -- 开发辅助(重载编辑器/求值/设置) --
## 原先这个函数是个混装大组(restart_editor / refresh_tools / run_tests / script_status /
## eval_code / open_scene / set_main_scene / project_setting / save_all / reimport /
## create_resource / get_resource_info)。拆分后只剩两个留在这里:
##   - refresh_tools 要重跑 _register_editor_tools 整棵注册树, 并读 _tool_defs /
##     _tool_audit_issues / _schema_fingerprint(), 全是注册表自身状态, 域文件拿不到也不该拿;
##   - run_tests 属测试域, 已拆进 MCPTestTools。
## 其余: eval_code / script_status / restart_editor -> MCPDevTools(见 _register_editor_tools);
## 7 个资源与项目设置类工具 -> MCPResourceTools。
func _register_dev_tools() -> void:
	_add_tool("refresh_tools",
		"手动重建 MCP 工具注册表(免重启编辑器), 响应含工具数、schema_fingerprint 与契约自检结果。**判定'是否真的生效': 跨次对比 schema_fingerprint** —— 指纹不变即工具表没变。【客户端不一定同步】本服务器是短连接 HTTP, 发不出 notifications/tools/list_changed(capabilities 已如实报 listChanged:false), 客户端缓存的旧 tools/list 不会自动刷新, 需在 IDE 侧重连 MCP 才更新; 在此之前, 以 tools/list 直查服务器为准, 勿把会话开始时的快照当权威。【重要: 适用范围】改动**被本服务器 preload 的其他脚本**时有效, 例如 MCPToolMeta.gd 的注解名单(READ_ONLY/DESTRUCTIVE/SIDE_EFFECT/IDEMPOTENT)、MCPToolSchema.gd 的入参构造、具体工具实现的辅助脚本 —— 只需调用本工具。但改动 **MCPDevServer.gd 自身**(新增/修改工具、描述、注册表逻辑)时**本工具无效**: 运行实例的方法体不会被热替换, 必须重建服务器实例(禁用再启用 DEVFramework 插件, 或 restart_editor)。该情况下本工具仍返回成功, 但注册表内容原样不变 —— 正是靠 schema_fingerprint 不变来识别这种'假成功'。",
		MCPToolSchema.no_arg(),
		_call_refresh_tools)

	# run_tests 已搬进 MCPTestTools —— 为何编辑器侧只跑进程无关用例, 见该文件。
	MCPTestTools.register(_add_tool)


## -- 文件操作 --
## desc / schema / handler 与路径守卫(guard_write_path)全部搬进 MCPFileTools。
## "写类工具统一带 dry_run"的使用约定说明也一并搬走 —— 留一份在这里只会与域文件
## 各说一份而漂移。
func _register_file_tools() -> void:
	MCPFileTools.register(_add_tool)


## ======= MCP 协议处理 =======

func _on_request(method: String, path: String, query: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	# MCP 服务器已关闭时忽略请求（编辑器重启期间）
	if _http == null:
		return
	if method == "OPTIONS":
		_http.send_response(stream, 204, _cors_headers(headers), "")
		return
	if method == "GET":
		_serve_sse(stream, headers)
		return
	if method != "POST":
		_send_rpc_error(stream, 405, headers, null, ERR_TRANSPORT_REJECTED, "Method Not Allowed", {}, {"Allow": "POST, GET, OPTIONS"})
		return
	# 鉴权: 可选 Bearer token(dev_framework/mcp/token, 非空时启用)
	var token: String = ProjectSettings.get_setting(SETTING_TOKEN, "")
	if not token.is_empty():
		var auth := str(headers.get("authorization", ""))
		if auth != "Bearer " + token:
			_send_rpc_error(stream, 401, headers, null, ERR_TRANSPORT_REJECTED, "Unauthorized")
			return
	# 校验 Origin: 拦截浏览器/外部站点的跨域调用(eval_code 可执行任意代码, 防本机 RCE)。
	# 无 Origin(本地 CLI/工具)或本机 Origin 放行。
	var origin := str(headers.get("origin", "")).to_lower()
	if not origin.is_empty() and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost") or origin.begins_with("http://0.0.0.0")):
		_send_rpc_error(stream, 403, headers, null, ERR_TRANSPORT_REJECTED, "Forbidden")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		_send_rpc_error(stream, 400, headers, null, ERR_PARSE, "Parse error")
		return
	var req: Dictionary = parsed
	# 协议版本协商(2026-07-28 起逐请求声明)。两处都缺省才回落 PROTOCOL_VERSION ——
	# 旧客户端两个都不发, 走老握手, 行为与改动前完全一致。
	var proto := str(headers.get(HEADER_VERSION, ""))
	var meta_version := ""
	var rparams: Variant = req.get("params", null)
	# meta 提到函数级作用域: 除了版本号, 下面还要查 clientCapabilities 是否存在,
	# 而原先它只在 if 块内可见。
	var meta := {}
	if rparams is Dictionary:
		var raw_meta: Variant = (rparams as Dictionary).get("_meta", null)
		if raw_meta is Dictionary:
			meta = raw_meta
			meta_version = str(meta.get(META_VERSION_KEY, ""))
	if not meta_version.is_empty() and not proto.is_empty() and meta_version != proto:
		# 规范要求二者必须一致, 不一致直接 400: 放行会让"头说 A 体说 B"的请求按错误版本解析。
		# data 里回两个实际收到的值和可用版本: 客户端据此能自行改对后重试, 只给一句
		# message 的话它无从判断该改哪个 —— 而它本来完全有能力自己修好。
		_send_rpc_error(stream, 400, headers, req.get("id", null), ERR_HEADER_MISMATCH,
			"Header mismatch: %s 与 _meta 声明的版本不一致" % HEADER_VERSION,
			{"supported": SUPPORTED_PROTOCOL_VERSIONS, "header": proto, "meta": meta_version})
		return
	# declared 与 effective 必须分开, 两者含义不同:
	#   declared  = 客户端**实际声明**了什么版本。全程只读, 用来做一致性与规范判定。
	#   effective = 本次实际按哪一版解析。降级只改它。
	# 早先把降级结果写回 requested, 于是"服务端决定用 2026-07-28 解析"被当成了"客户端声明了
	# 2026-07-28", 紧接着的 _meta 必填校验据此要求该客户端补 _meta —— 而它声明的是 2099-01-01,
	# 从未说过自己支持 2026-07-28。等于凭空造出一个它无论如何都满足不了的要求, 客户端只会看到
	# "缺 protocolVersion"却查不出自己到底哪错了。
	var declared := proto if not proto.is_empty() else meta_version
	var rpc_method := str(req.get("method", ""))
	var effective := declared
	if not declared.is_empty() and not SUPPORTED_PROTOCOL_VERSIONS.has(declared):
		if rpc_method == "initialize" or not _version_negotiated:
			# 协商降级而不是报错(理由见 _negotiate_version 与 _version_negotiated 的注释)。
			# 握手期报错等于失联: 2025-11-25 及更早的客户端拿到版本错误不会重试。
			effective = _negotiate_version(declared)
			LogTool.log("MCP", "%s 请求的协议版本 %s 不受支持, 协商降级为 %s (支持: %s)" % [rpc_method, declared, effective, str(SUPPORTED_PROTOCOL_VERSIONS)])
		else:
			# 协商完成后仍发陌生版本: 说明它跳过了握手或中途换了版本, 按猜测的版本解析只会错。
			#
			# 这里必须打日志 —— 本分支原本一行日志都不打, 结果是客户端界面显示
			# "MCP error -32022: Unsupported protocol version", 而服务端日志里既没有这条
			# 错误、也没有对应的 POST 记录, 完全看不出客户端到底要哪个版本, 无法定位。
			LogTool.log("MCP", "拒绝 %s: 协议版本 %s 不受支持 (支持: %s)" % [rpc_method, declared, str(SUPPORTED_PROTOCOL_VERSIONS)])
			_send_rpc_error(stream, 400, headers, req.get("id", null), ERR_UNSUPPORTED_VERSION,
				"Unsupported protocol version",
				{"supported": SUPPORTED_PROTOCOL_VERSIONS, "requested": declared})
			return
	# 2026-07-28 起规范要求: 声明了该版本的请求, 其 _meta 必须**同时**带 protocolVersion 与
	# clientCapabilities, 缺任一即为 malformed request, 必须回 ERR_INVALID_PARAMS + HTTP 400。
	#
	# 刻意用 Invalid params 而不是 ERR_UNSUPPORTED_VERSION: 那是另一个问题 —— 请求可能完全合法,
	# 只是没说清自己用的哪一版, 客户端把字段补上就能继续, 不该被当成"版本不受支持"。
	#
	# 两点收窄, 都是为了不误伤现有客户端:
	#   - 只对声明了 META_REQUIRED_SINCE 的请求生效(旧版本是握手式, _meta 里没有这两个字段);
	#   - 跳过 initialize —— 它正是用来协商版本的, 要求它先声明版本是循环依赖。
	# 判定依据是 declared(客户端声明的原始版本)而非 effective: 若按 effective 判定, 上面刚被
	# 降级到这个版本的客户端会被要求补 _meta, 而它降级的原因恰恰是它不认识这一版。
	if declared == META_REQUIRED_SINCE and rpc_method != "initialize":
		var missing: Array[String] = []
		if meta_version.is_empty():
			missing.append(META_VERSION_KEY)
		if not meta.has(META_CLIENT_CAPS_KEY):
			missing.append(META_CLIENT_CAPS_KEY)
		if not missing.is_empty():
			_send_rpc_error(stream, 400, headers, req.get("id", null), ERR_INVALID_PARAMS,
				"Missing required _meta field(s): %s" % ", ".join(missing),
				{"missing": missing, "required": [META_VERSION_KEY, META_CLIENT_CAPS_KEY]})
			return
	# 两处都没声明版本(老客户端)才回落 PROTOCOL_VERSION; 降级过的 effective 本身必是受支持版本
	if effective.is_empty():
		effective = PROTOCOL_VERSION
	# 提前取 sessionId: 旧式 SSE 会话投递的请求要把响应改走 SSE 流, 且日志需与会话对应
	var sid := _query_param(query, "sessionId")
	# 默认只记**首次**版本协商那一条, 且只在全量开关打开时才记其余请求。
	# 不记 tools/list / prompts/list / resources/list / notifications/initialized: 它们每个会话
	# 只发生一次, 逐条打出来是纯噪音 —— 排查握手真正需要的恰恰是"协商成了什么 / 请求有没有落到
	# 正确的 SSE 会话上", 不是这四条记账流水。tools/call 同样不打(结果已由 _log_tool_result 记过)。
	#
	# **initialize 必须用 _version_negotiated 收窄, 不能无条件打**: 客户端每次重连/换会话都会重发
	# initialize, 条件里写死 rpc_method == "initialize" 时 IDE 一抖动就是一串同内容日志, 而协商
	# 结果并不会每次都变。首协商之后该字段为 true, 重连的 initialize 便不再记录。
	# 现场排查要全量时 set 一下即可, 不必重启编辑器(那会顺带踢掉客户端的 SSE 连接)。
	if _log_rpc or (rpc_method == "initialize" and not _version_negotiated):
		LogTool.log("MCP", "POST %s | 版本 %s | 会话 %s" % [rpc_method, effective, sid if not sid.is_empty() else "-"])
	var response := await _handle_jsonrpc(req, effective)
	if rpc_method == "initialize" and not response.is_empty():
		_version_negotiated = true
	# JSON-RPC 通知(无 id)按 MCP 规范回 202 空响应
	if response.is_empty():
		_http.send_response(stream, 202, {}, "")
		return
	var json := MCPFormat.json_safe(JSON.stringify(response))
	# 旧式 SSE 会话投递的请求: 响应必须回写到它开的那条 SSE 流, POST 上只回 202。
	# 若这里直接在 POST 上回 JSON, 旧式客户端永远读不到响应(它不读 POST 的 body),
	# 现象是"显示已连接但所有工具都超时"。会话已失效时才降级回 Streamable HTTP 直回。
	if _http.has_sse_session(sid):
		if _http.send_sse_message(sid, json):
			_http.send_response(stream, 202, {}, "")
			return
		LogTool.log("MCP", "旧式 SSE 会话 %s 已失效, 降级为 Streamable HTTP 直回" % sid)
	_http.send_response(stream, 200, _cors_headers(headers), json)


## GET /mcp → 开启旧式 HTTP+SSE 会话。
##
## 规范(Transports §Backwards Compatibility)要求新旧两个端点并存: POST 走 Streamable HTTP,
## GET 走旧式 SSE。客户端用哪种取决于它的配置 —— 未声明 transportType 的客户端
## (如 CodeBuddy 的 .mcp.json 只写 url 时)默认按旧式 SSE 连接, 会先 GET 等 endpoint 事件。
##
## 之前这里对 GET 一律回 405, 代码注释写的是"客户端会回退纯 POST, 全部工具正常"——
## **实测是错的**: 客户端收到 405 后直接放弃, 一次 POST 都不发, 界面永远停在"连接中"。
## 所以 GET 必须真的把流开出来, 而不是拒掉。
func _serve_sse(stream, headers: Dictionary) -> void:
	var endpoint := _endpoint_url()
	# 已完成握手的客户端走的是 Streamable HTTP(请求全在 POST 上直回), 它此刻 GET 开的
	# 流只是通知/保活通道, 永不承载请求 —— 再套 10s 未使用回收就会把它当废弃流掐断,
	# 客户端随即重开, 形成"断流-重连"死循环, 界面一直停在"连接中"。
	var sid := _http.open_legacy_sse(stream, _sse_headers(headers), endpoint, not _version_negotiated)
	if sid.is_empty():
		# 开不了流(并发已满/连接已断) → 回 405, 客户端仍可退回纯 Streamable HTTP
		_send_rpc_error(stream, 405, headers, null, ERR_TRANSPORT_REJECTED, "Method Not Allowed", {}, {"Allow": "POST, GET, OPTIONS"})
		return
	# 默认**不记**这条: 客户端每次重连/重试都会走一遍这里, 实测 IDE 抖动时就是一串同内容日志,
	# 而"客户端连上了"从插件启用那条就能看出。排查"sessions 握手不通"时才 set 全量开关。
	# 要记就只取 sid 前 8 位 —— 完整 uuid 没有可读价值, 却会挤掉后面的诊断信息。
	if _log_rpc:
		LogTool.log("MCP", "GET /mcp 通告 endpoint=%s, 会话 %s" % [endpoint, sid.substr(0, 8)])


## SSE 响应头。与 _cors_headers 分开是因为语义不同: 那里是"一次 JSON-RPC 往返"的响应头,
## 带 Mcp-Session-Id 指代 Streamable HTTP 的会话; 而这里开的是旧式 SSE 流, 它的身份由
## 通告出去的 endpoint 里的 sessionId 决定, 再附一个 Streamable HTTP 语义的会话头只会误导客户端。
func _sse_headers(headers: Dictionary) -> Dictionary:
	var h := {
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


## 通告给旧式客户端的 POST 地址。用绝对 URL: 部分旧客户端不会拿它与 SSE 的 URL 做相对
## 解析, 而是原样使用, 相对路径会被它当成不可用。
func _endpoint_url() -> String:
	return "http://127.0.0.1:%d/mcp" % _http.get_port()


## 从 query 串取参数值(键名大小写不敏感)。旧式 SSE 传输把 sessionId 放在 query 上。
static func _query_param(query: String, key: String) -> String:
	for pair in query.split("&", false):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == key.to_lower():
			return kv[1].uri_decode()
	return ""


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


## 协议版本协商: 回一个"客户端大概率也认识"的版本。
##
## 规范(initialize 小节)对不支持的版本给出的指令是**回一个自己支持的版本**, 而不是报错:
##   "If the server supports the requested protocol version, it MUST respond with the same
##    version. Otherwise, the server MUST respond with another protocol version it supports."
## 之前这里对不认识的版本直接回 -32022, 等于违背规范: 客户端在握手阶段收到错误不会重试、
## 也不会换一个版本, 只会反复重开连接并最终报 "Unsupported protocol version" 而失联。
##
## 规范建议回"最新的"那个, 但那对更老的客户端仍然是死路(它不认识就断连), 所以这里取
## **不超过 requested 的最新版本** —— 客户端提出的版本只会比它自己新或相等, 往回退一档
## 最可能被它接受; 连这个都没有(客户端比我们还老)就回我们最老的那个, 至少是条活路。
## 版本号是 ISO 日期, 故字典序即时间序, 可直接比字符串。
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
## proto 是本请求协商到的协议版本(由 _on_request 从 HTTP 头 / _meta 解析, 见那里的注释)。
## 它只影响**响应形状**: 2026-07-28 起 result 必须带 resultType, 可缓存结果还必须带
## ttlMs/cacheScope。旧版本一律不发这些字段 —— 新字段对旧客户端是未知的, 会被忽略,
## 但也没必要让旧客户端去读它们。
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
			# 服务端单方面抬高版本号会让不支持该版本的客户端直接失联(它没有前向兼容能力)。
			var agreed := _negotiate_version(requested_proto)
			if not requested_proto.is_empty() and agreed != requested_proto:
				# 标明是**请求体**声明的版本: 外层 _on_request 还会就协议头/_meta 声明的版本
				# 打一条同结构的日志(来源不同: 头 vs body), 不标注会被误认成同一条打了两遍。
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
				},
			}
		"notifications/initialized":
			return {}
		# 2026-07-28 起客户端可在发其他请求前先探知服务端支持哪些版本。规范标为服务端 MUST。
		# 只报版本与身份, 不带 tools —— 工具表另有 tools/list 且可缓存, 在这里重复一遍
		# 会让 38K 的清单被拉两次(而 discover 通常不可缓存)。
		# 注: 规范的 DiscoverResult 完整字段未公开, 这里是按已公开的
		# Result/ServerCapabilities/Implementation 三个接口推导的最小形状;
		# 多报无害(客户端按 schema 取自己认识的), 少报才会被拒。
		"server/discover":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result({
				"protocolVersions": SUPPORTED_PROTOCOL_VERSIONS,
				"protocolVersion": proto,
				"capabilities": _server_capabilities(),
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			}, proto)}
		"tools/list":
			# ttlMs/cacheScope 让客户端缓存这份 38K 的清单而不是每次重拉 —— 它在进程生命周期内
			# 是静态的, 变了也只有 refresh_tools 会变(而那之后客户端本来就会重新拉)。
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"tools": _tool_defs}, proto, true)}
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
			# 两半 —— 一次调用打两行回声, 且都被本进程 MCPLogger 抄进 get_logs 返回给 AI。排查时打开。
			if ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
				# 参数截断: eval_code/game_eval 传的是代码正文(上限 8192 字符), 整段打进日志会撑爆日志。
				var arg_log := str(arguments)
				if arg_log.length() > 300:
					arg_log = arg_log.left(300) + ("…(已截断, 共 %d 字符)" % arg_log.length())
				LogTool.log("MCP", "工具调用(%s): %s, 参数: %s" % [_mode, tool_name, arg_log])
			if not _tool_handlers.has(tool_name):
				return _jsonrpc_error(req_id, ERR_INVALID_PARAMS, "Unknown tool: %s" % tool_name)
			# 入参校验: 拦在 handler **之前**。handler 内部的 VariantTool 是为"健壮"而非"诚实"
			# 设计的(转换失败回落缺省值), 那在协议边界上会把参数错误伪装成合法结果 ——
			# 详见 MCPArgCheck 类注释里 max_depth:"5" 那个例子。
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
			# (get_logs / get_errors / get_game_logs / get_game_errors / 文件读写等巨量内容工具截断显示)。
			# 必须在剥离 text/is_error **之前**记 —— 日志摘要读的就是这两个字段。
			_log_tool_result(tool_name, result)
			# 出协议边界: 剥掉仅供进程内使用的顶层 text / is_error。二者与 content[0].text
			# 逐字节重复, 不剥等于每次调用把同一份正文传两遍(实测占大结果 45%)。详见 MCPResult.for_protocol。
			return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(result)}
		# resources: 静态文档入口。短连接架构发不出推送, 故 subscribe / listChanged 均为 false。
		# 注意 resources/read 的成功与失败**都**放在 result 里(失败时带 isError + content),
		# 而不是走 JSON-RPC error: 规范两种都允许, 而这里选 result 是因为"uri 不对"属于
		# 换掉 uri 就能自纠错的问题, 与 tools/call 的处理方式保持一致。
		"resources/list":
			return {"jsonrpc": "2.0", "id": req_id, "result": _decorate_result(
				{"resources": MCPResourceTools.list_resources()}, proto, true)}
		"resources/read":
			var rparams: Variant = req.get("params", {})
			var rdict: Dictionary = rparams if rparams is Dictionary else {}
			# 成功与失败都在 result 里(失败时是 _err_validation, 自带 content+isError),
			# 故两条路径都要过 for_protocol: 失败那条同样带 text/is_error。
			return {"jsonrpc": "2.0", "id": req_id,
				"result": _decorate_result(MCPResult.for_protocol(MCPResourceTools.read_resource(str(rdict.get("uri", "")))), proto, true)}
		"ping":
			return {"jsonrpc": "2.0", "id": req_id, "result": {}}
		# 声明支持 4 个级别却什么都不做, 比不声明更糟: 模型会据此以为 debug/info 日志已被
		# 过滤掉, 于是不再去 get_logs 里拉, 结果恰恰丢掉了它最需要的东西 —— 这是**误导性
		# 响应**。这里不实现分级过滤(那要贯穿整条日志管线, 是独立的一件事), 但必须如实说明
		# "记下了、不生效", 并指明真正能控制日志量的参数。
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


## HTTP 层直接回 JSON-RPC 错误的**唯一出口**。
##
## ## 为什么要有这个函数
##
## 收敛前这里散着 6 处各写各的(4 处手写转义字符串 + 2 处 JSON.stringify), 攒出四重不一致:
##   1. 字段序 —— 手写那几处把 id 排在 error **之后**, 与 _jsonrpc_error 相反。
##   2. CORS —— 405 与 Parse error 两处没走 _cors_headers, 浏览器客户端读不到状态码,
##      只能报"网络错误"而看不到真正的 405/400。
##   3. 净化 —— 6 处**全部绕过 MCPFormat.json_safe**, 而正常响应走了。协议边界必须单一收口,
##      否则日后往 json_safe 加规则时会整类漏掉, 边界就漏了。
##   4. data —— ERR_HEADER_MISMATCH 原本只回一句 message, 客户端既不知道实际收到的两个
##      版本、也不知道可用版本, 无从自行改正; 而它本来完全有能力自己修好。
##
## 与 _jsonrpc_error 的分工: 后者返回字典给 JSON-RPC 层(await 上来后统一序列化);
## 本函数直接发出 HTTP 响应, 服务于"还没进 JSON-RPC 就必须拒绝"的场景(方法/鉴权/
## Origin/解析失败/版本协商)。
func _send_rpc_error(stream, status: int, req_headers: Dictionary, req_id: Variant, code: int, message: String, data: Dictionary = {}, extra_headers: Dictionary = {}) -> void:
	var hdrs := _cors_headers(req_headers)
	for k in extra_headers:
		hdrs[k] = extra_headers[k]
	# data 仅在非空时才出现。规范原文是"客户端需要结构化信息时放在 data",
	# 无信息可给时塞个空对象等于告诉客户端"这里有 data, 但内容你自己看"——比不给更糟。
	var err_obj := {"code": code, "message": message}
	if not data.is_empty():
		err_obj["data"] = data
	_http.send_response(stream, status, hdrs, MCPFormat.json_safe(JSON.stringify({
		"jsonrpc": "2.0", "id": req_id, "error": err_obj,
	})))


## 服务端能力声明。initialize 与 server/discover 共用 —— 同一份事实写两处,
## 迟早会在只改一处后让客户端对"服务端支持什么"得到互相矛盾的答案。
func _server_capabilities() -> Dictionary:
	return {
		# 工具清单在进程生命周期内是静态的(_tool_defs 只在初始化时填充), 而本服务器
		# 是"一次请求一个连接"(Connection: close)的短连接 HTTP, **发不出任何服务端
		# 推送** —— notifications/tools/list_changed 在此架构下永远无法送达。
		# 声明 true 会让客户端白白订阅一个永不到来的通知(还会挂起等它), 报 false 才是诚实的。
		"tools": {"listChanged": false},
		# resources 只读静态文档, 无订阅能力(短连接发不出推送), 清单也是静态的。
		"resources": {"subscribe": false, "listChanged": false},
		# 旧日志级别机制。2026-07-28 已把通知侧标记为废弃(SEP-2577), 改由每请求
		# _meta 的 logLevel 逐请求开启; 这里保留 setLevel 只为兼容旧客户端。
		"logging": {"supportedLevels": ["debug", "info", "warning", "error"]},
	}


## 按协商到的协议版本给 result 补新版必需字段。
## 2026-07-28 起 Result 必须带 resultType(客户端见到缺省会当 "complete" 处理, 但那是
## 兼容旧服务端的兜底, 不该由新服务端依赖); 可缓存结果还必须带 ttlMs + cacheScope。
## cacheScope 用 public: 工具清单与资源清单是进程级静态定义, 不含任何用户特定数据。
func _decorate_result(result: Dictionary, proto: String, cacheable := false) -> Dictionary:
	if proto != SUPPORTED_PROTOCOL_VERSIONS[0]:
		return result
	result["resultType"] = "complete"
	if cacheable:
		result["ttlMs"] = LIST_TTL_MS
		result["cacheScope"] = "public"
	return result


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
		# 全部命中忽略模式(如 UID 缓存重建期的噪音)时不附加诊断: 模式表与判定都在 MCPDevTools
		if MCPDevTools.is_all_ignored(outcome, MCPDevTools.get_ignored_error_patterns()):
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
## 设置项键名与默认值因此仍只有一处定义, 而格式层得以保持无状态(它的每个分支都对应一种真实
## 事故, 无状态才能离线逐个测)。<=0 表示关闭上限, 与 enforce_output_cap 的约定一致。
## 上限实时读 ProjectSettings(dev_framework/mcp/max_output_chars), 改设置无需重启即生效。
func _output_cap() -> int:
	return int(ProjectSettings.get_setting(SETTING_MAX_OUTPUT_CHARS, DEFAULT_MAX_OUTPUT_CHARS))


## 把工具调用结果记录到 MCP 日志。**成功路径默认不打**, 由 dev_framework/mcp/log_tool_results 开关。
##
## 为什么成功路径默认关闭(这不是"少打点日志"的口味问题, 有两个硬后果):
##   1. **它会把自己抄进 get_logs 的返回值里。** 本项目的日志捕获器是 OS.add_logger 装的
##      MCPLogger, 走引擎 print 通道 —— 而本函数用的正是 LogTool.log → print_rich。所以每一条
##      "[editor] xxx 返回: ..." 都会进环形缓冲, 被 get_logs 原样返回给 AI。等于 MCP 每被调一次,
##      就往 AI 的上下文里塞一条自己写的回声, 而项目自己的日志被挤在中间。
##   2. **失败才是需要留在输出面板的东西。** "这次调用返回了什么"对 AI 是权威(它拿到的是响应
##      本体), 对人类只有"报错了"才有价值 —— 那条已经走 LogTool.error 且不受 enabled 开关影响。
## 需要排查"返回空/返回怪"时临时把该开关打开, 排查完关掉即可。
func _log_tool_result(tool_name: String, result: Dictionary) -> void:
	var text: String = str(result.get("text", ""))
	var is_err: bool = result.get("is_error", false)
	if is_err:
		# 用 error 级别而非 log: LogTool 让 ERROR 不受 enabled 开关与 tag 忽略的影响,
		# 否则一旦关掉 MCP 日志或把该 tag 加进忽略列表, 工具错误会被一并吞掉 ——
		# 而"工具报错"恰恰是最需要它在日志里留下痕迹的时刻。
		LogTool.error("MCP", "[%s] %s 错误: %s" % [_mode, tool_name, text.left(400)])
		return
	if not ProjectSettings.get_setting(SETTING_LOG_TOOL_RESULTS, false):
		return
	# 打全文还是打结构摘要(顶层键 + 数组/字典计数), 只按**长度**判, 不按工具名维护名单。
	#
	# 原来是一份"巨型内容工具"名单(get_logs / read_file / take_screenshot / get_scene_tree ...)。
	# 名单是本项目要消灭的那类东西: 新增一个返回大内容的工具就会漏登记 → 日志被撑爆;
	# 而名单里的工具绝大多数时候返回的是短输出(get_project_info 一次几百字符), 白瞎了摘要,
	# 把最该看的那一行变成键名罗列 —— 实测中真正需要人看的恰恰是这类短状态行。
	# 按长度判是自适应的: 长的必压(不会出现撑爆), 短的必全(查状态时看到的就是真内容)。
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
## 下面这层转发是刻意的: 实现已拆到 MCPResult.gd(协议边界, 零状态依赖, 可独立单测),
## 但保留同名转发可让 50+ 个调用点零改动, 也让这次拆分可回退 —— 把转发换回实现即可。
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
## 主文件这边随迁走后已无调用点, 故整块删除。需要该封装时直接调 MCPResult.ok_with_meta。


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。
## 这是新增代码的推荐入口(它把"该不该重试"这个判断从调用点收敛到一处)。
##
## 这里**故意没有** stale_code 的转发: 该类别唯一的用法在新鲜度守卫里是随守卫结果
## 动态透传的(str(guard.get("category", MCPResult.CAT_STALE_CODE))), 类别要到运行时
## 才知道, 静态封装用不上。MCPResult.err_stale_code 仍在原处(它是协议边界的一部分,
## 不该因本文件暂无静态调用点而缺项); 等这里真的出现第一个静态调用点再补转发 ——
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
## 仅当它需按上下文动态决定(如新鲜度守卫结果的 category 透传)时才直接调用。
func _err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	return MCPResult.err(text, category, retryable, recovery)


## ======= 统一入参读取: 一律走 VariantTool =======
##
## 本文件不再保留任何私有参数读取副本: handler 的键值经 VariantTool.get_* 读取,
## 需要值级转换时用 as_*(或 infer / coerce)。统一规则、坑位说明与"为什么"集中在
## VariantTool 顶部, 那里是本规则的**唯一事实来源** —— 不要在这里重新抄一份。
##
## ======= 两处合法的裸读(不要当漂移收掉) =======
## set_node_property 与 set_project_setting 的 "value" 走裸 args.get("value", null"),
## 因为它们的**目标类型事先未知**: 前者要靠 node.get(property) 的 typeof() 反推, 后者由用户
## 任意指定。这两处接 VariantTool.infer(猜类型) / VariantTool.coerce(对齐目标类型),
## 强行套进 get_* 反而会丢信息。除这两处外, handler 里的 args.get( 一律是漂移。
##
## 注意这是**约定而非守卫**: 契约自检(_audit_tools / MCPToolAudit.audit_handler_params)校验的是
## "schema 声明了哪些键、schema 与 handler 声明是否一致", 不校验 handler 是否绕过
## VariantTool 裸读。新增 handler 时只能靠自律 —— 这点必须写明, 否则后人会误以为
## 已经有检查兜着。想让它变成真守卫, 需在 MCPToolAudit.audit_handler_params 加一条: handler 源码中
## 出现 args.get( 且该键不在 VariantTool.get_* 调用列表中 → 报问题。
##
## 历史教训(留着提醒别走回头路): 本文件此前同时存在 `_to_bool`(支持 "true"/数字)与 9 处
## 绕过它的裸转, 而 `_arg_int` 更是长期零调用 —— 入口摆在那里却一行防护都没生效。
## "同一个参数两种读法"长期共存, 每处裸转都是一个潜在的静默反转。


## get_game_logs 的进程侧实现: 只读本进程 print 日志。与 _call_get_errors 一样直接调
## MCPLogTools._call_collect_logs, 不经 get_logs 的 handler —— 后者曾按 source 转发, 而 args
## 原样带走 source, 于是"编辑器 get_logs(source=game) -> 游戏 get_game_logs -> 再次命中
## source=game -> 又转发"形成自我转发, 而游戏进程 debugger_plugin 恒为 null, 于是恒定报
## "游戏未运行"(游戏明明在跑)。
## source 参数现已整体删除, 该类自我转发不再可能发生; 独立出来另有一利: 本函数只读 schema
## 声明过的参数, 入参契约自检自然通过, 不靠白名单绕过。
func _call_get_game_logs(args: Dictionary) -> Dictionary:
	# 不要写 await: 底层件不是协程(内部无 await), await 只会换来 redundant-await 警告。
	return MCPLogTools._call_collect_logs(args, false)


## 游戏运行控制: start(支持 uid:// 场景, 已在运行时自动停止旧实例后重启)/stop/continue
##
## continue 并入本工具而非独立成工具, 理由见 _call_debug_continue 上方那段注释 —— 简言之:
## 客户端决定映射哪些工具, 恢复路径必须落在**一定被映射**的那个工具上。
func _call_game_control(args: Dictionary) -> Dictionary:
	match VariantTool.get_string(args, "action"):
		"continue":
			return _call_debug_continue({})
		"start":
			# 已在运行时自动停旧实例再启动, 不要求调用方手动先 stop。
			# 旧实例持有的是它启动时固化的脚本, 而"改完脚本 → 重启 → 验证"是最高频组合;
			# 多要求一步就多一次"忘了重启"的机会。新鲜度闸门拦下时给出的恢复动作正是 start,
			# 若这里还要再调一次 stop, 那道提示等于没给出出路
			if _has_game_session():
				_call_stop_game({})
				if not await _wait_game_stopped(5.0):
					return _fail("旧游戏实例 5 秒内未停止, 无法重启。请用 game_control(action=stop) 确认状态后重试。")
			return await _call_run_game(args)
		"stop":
			return await _call_stop_game({})
	return _fail("未知 action: %s (可选 start/stop/continue)" % VariantTool.get_string(args, "action"))


func _call_get_errors(args: Dictionary) -> Dictionary:
	return MCPLogTools._call_collect_logs(args, true)


## 编辑器模式且游戏调试线活跃(编辑器进程指向游戏进程的数据/操作要走代理)
func _has_game_session() -> bool:
	return _mode == MODE_EDITOR and debugger_plugin != null and debugger_plugin.has_active_session()


## 记录"脚本新鲜度基准"的当前时刻(见 MCPScriptSync.guard_eval)。
##
## 基准点必须不晚于脚本加载完成的时刻才安全, 故一律取"此刻"而非任何已有的时间戳 ——
## 原名 _active_session_started_at 声称"引擎会话给出的启动时刻", 但实现只是读当前时钟,
## 名字会让人以为它读的是引擎会话数据而在别处被误用。reason 只进日志: 便于事后核对
## 判据基准是否选得过晚(基准越晚, 越可能漏报"游戏加载后才改的文件")。
func _mark_script_baseline(reason: String) -> void:
	_game_started_at = int(Time.get_unix_time_from_system())
	LogTool.log("MCP", "脚本新鲜度基准更新(%s): %d" % [reason, _game_started_at])


func _call_take_screenshot(args: Dictionary) -> Dictionary:
	# text(文本化截图) 与 game(真实截图) 都分析游戏运行画面: 编辑器模式经调试线转发到游戏进程
	var capture_type: String = VariantTool.get_string(args, "capture_type", "text")
	if capture_type == "text" or capture_type == "game":
		if _mode == MODE_EDITOR:
			return await _call_runtime_proxy("take_screenshot", args)
		# 运行时模式: 直接处理
		return await _runtime_take_screenshot(args)

	# editor / scene 两模式只取编辑器进程自己的像素, 整段搬进了 MCPScreenshotTools
	# (含 SubViewport 渲染、frame_post_draw 那三条禁令、sRGB 校正与 1280 降采样)。
	# 本函数必须留在主文件的只有上面 text/game 那段: 它要 _call_runtime_proxy 与
	# _runtime_take_screenshot, 两者都依赖 _pending / debugger_plugin, 静态化不了。
	# 那边**刻意不叫 _call_take_screenshot**: 跨文件同名会让"按函数名取实现"(grep、审计切源码)
	# 有机会取到错误那一份, 域文件那边把理由写全了。
	return await MCPScreenshotTools.capture_editor_side(capture_type, args)


func _call_run_game(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("仅在编辑器模式可运行游戏")
	if _has_game_session():
		return _fail("游戏已在运行(活跃调试会话)。如需重启请用 game_control(action=start)(会自动停掉旧实例)。")
	var raw := VariantTool.get_string(args, "scene")
	var source := "参数 scene"
	if raw.is_empty():
		# 未指定时用主场景(项目里通常配置为 uid:// 形式)
		raw = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		source = "项目主场景(application/run/main_scene)"
		if raw.is_empty():
			return _err_validation(
				"必须提供 scene(要运行的场景 res:// 路径), 例如 res://Scenes/Main/Main.tscn",
				"传入 scene 参数后重试。")
	# uid:// → res://。解析失败时模块会先重扫重建 UID 缓存再重试一次, 因为编辑器重启后
	# 第一次启动必然撞上缓存未就绪 —— 那正是"改代码 → restart_editor → 验证"的第一个动作
	var scene := await MCPScriptSync.resolve_scene_path(raw)
	if scene.is_empty():
		return _err_validation("无法把%s解析为项目内资源路径: %s" % [source, raw],
			"确认该资源已导入; 也可绕过 uid 解析 —— 直接传 res:// 路径形式。")
	if not ResourceLoader.exists(scene):
		return _err_validation("启动场景不存在: %s" % scene,
			"传入存在的场景路径后重试。")
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
	var scene := VariantTool.get_string(args, "scene")
	# 自动接管: 已运行的游戏先停止再重跑(本工具自行管理启停, 对齐 Playwright 等托管生命周期工具惯例)。
	if _has_game_session():
		EditorInterface.stop_playing_scene()
		_game_ready = false
		var waited := 0.0
		while _has_game_session() and waited < 5.0:
			await get_tree().create_timer(0.1).timeout
			waited += 0.1
	var retries := VariantTool.get_int(args, "retries")
	var backoff_ms := VariantTool.get_int(args, "retry_backoff_ms", 500)
	# 可选: 调用方提供的上次依赖快照({path: mtime}), 用于检测本次执行前代码是否变化
	var prev_snapshot: Dictionary = VariantTool.get_dict(args, "prev_snapshot")
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
	var action := VariantTool.get_string(args, "action", "start").to_lower()
	var session_id := VariantTool.get_string(args, "session_id", "default")
	# abort: 清除指定会话(或全部)
	if action == "abort":
		if VariantTool.get_bool(args, "all"):
			_verify_sessions.clear()
			return _ok_json({"action": "abort", "session_active": false, "message": "全部 verify_fix 会话已清除"})
		_verify_sessions.erase(session_id)
		return _ok_json({"action": "abort", "session_id": session_id, "session_active": false, "message": "verify_fix 会话已清除: %s" % session_id})
	# status: 只查不跑
	if action == "status":
		if _verify_sessions.is_empty():
			return _ok_json({"action": "status", "session_active": false, "session_count": 0, "message": "无活跃会话。用 action=start 创建。"})
		if VariantTool.get_bool(args, "all"):
			return _ok_json({"action": "status", "session_active": true, "session_count": _verify_sessions.size(), "sessions": _verify_sessions})
		if not _verify_sessions.has(session_id):
			return _ok_json({"action": "status", "session_id": session_id, "session_active": false, "message": "会话不存在: %s" % session_id})
		return _ok_json({"action": "status", "session_id": session_id, "session_active": true, "session": _verify_sessions[session_id]})
	# start / continue
	if action == "start":
		_verify_sessions[session_id] = {
			"scene": VariantTool.get_string(args, "scene"),
			"operations": VariantTool.get_array(args, "operations"),
			"duration": VariantTool.get_float(args, "duration", 4.0),
			"retries": VariantTool.get_int(args, "retries"),
			"retry_backoff_ms": VariantTool.get_int(args, "retry_backoff_ms", 500),
			"stop_on_error": VariantTool.get_bool(args, "stop_on_error", true),
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
	# 错误响应不能当成功结果读: 错误结果的 sc 里没有 verdict / deps_changed 字段,
	# 读它会让 verdict 被 `sc.get("verdict", "unknown")` 静默读成 "unknown"(而非明确的
	# "error"), 并让 deps_changed 取默认 true —— 于是"本轮根本没跑起来"这一事实被
	# "依赖有变化, 重跑有意义"这个乐观结论盖掉。故先分流, 错误时 sc 保持 null。
	# (MCPResult.err 现在会填 structuredContent, 见该函数的说明)
	var sc: Variant = null
	if not bool(result.get("is_error", false)):
		sc = result.get("structuredContent", null)
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


## 快照依赖文件的修改时间(path -> mtime)。mtime 变化即认为代码/资源被改动。
func _snapshot_deps_mtime(scene: String) -> Dictionary:
	var snap := {}
	var deps := MCPCodeIndex.collect_scene_deps(scene)
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


## 等待游戏调试会话结束(供 start 前自动停止旧实例用), 超时返回 false
func _wait_game_stopped(timeout_sec: float = 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		if not _has_game_session():
			return true
		await get_tree().create_timer(0.1).timeout
	return not _has_game_session()


## 等待游戏进程的调试线桥接就绪(session 已激活 且 收到 dev_mcp:ready), 超时返回 false
func _wait_game_ready(timeout_sec: float = 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		if _game_ready and _has_game_session():
			return true
		await get_tree().create_timer(0.1).timeout
	return false


## ======= 运行时工具(游戏进程内原生执行) =======

func _register_runtime_tools() -> void:
	# 仅游戏进程首次进入时清空(editor 进程已由 _register_editor_tools 清空并注册了编辑/项目工具,
	# 这里只能追加 runtime 工具, 不能 reset 否则会清掉前面分组的注册)。
	if _tool_handlers.is_empty():
		_reset_tools()
	# 游戏进程侧同样要注入日志捕获器: get_game_logs / get_game_errors / clear_game_errors /
	# clear_game_logs 复用 MCPLogTools 的底层件, 漏注入时它们显式返回"日志捕获器未就绪"。
	MCPLogTools.bind_logger(_logger)
	# eval ctx provider: 游戏侧的 game_eval / auto_verify / 轮询探针都经 MCPDevTools.eval_code,
	# 而新鲜度闸门要用 _mode 与游戏启动时刻、日志捕获器。漏注入不报错, 但守卫会静默全放行且
	# 运行期错误完全捕获不到 —— 症状是"game_eval 的问题查不出来"。
	MCPDevTools.set_eval_ctx_provider(func(): return {"mode": _mode, "game_started_at": _game_started_at, "logger": _logger})
	# 排在 simulate_click 之前注册: 使用顺序就是"先查后点", 工具表按此顺序排能让 AI
	# 先看到定位手段再看到执行手段。
	_register_game_play_tool("get_interactables",
		"列出当前画面里可交互的东西 —— **2D 控件(按钮/输入框/滑动条/标签)与 3D 物体(主菜单按钮/卡牌/媒体按钮都是 3D)** —— 每条带一个短引用 ref(如 e3)。**先查后点**: 拿到 ref 后用 simulate_click(ref=e3) 直接点击, 无需自己换算坐标。2D 元素给两套矩形(viewport_rect 视口坐标 / window_rect 窗口坐标); space=3d 的元素刻意不给矩形(3D 投影点会随相机漂移), 点击由工具在物体自身上激活。用 space=3d 可单独取 3D 子集(本项目实测可见 75 个, 常比 UI 还多, 混在默认清单里容易被 max_nodes 截掉)。filter=text 只取带文字的(读血量/分数/提示语), class_filter=Button 按类型筛(对 3D 元素也可按脚本名筛, 如 GameButtonView3D), text_contains 按文案筛。ref 由服务端解析成**实时**位置, 界面在查询后有动画或位移也不会点偏; 若报未知 ref 说明界面已变, 重新查一次即可。【只读】不改任何游戏状态。",
		MCPUITools.schema(),
		MCPUITools._handle_get_interactables,
		func(args): return await _call_runtime_proxy("get_interactables", args))

	_register_game_play_tool("simulate_click",
		"在游戏窗口模拟鼠标左键点击(按下+释放)。**推荐先用 get_interactables 拿到元素 ref, 再用 ref=e3 点击** —— 由服务端解析成实时位置, 不必自己换算坐标。ref 指向 3D 物体(space=3d)时改为在该物体自身上激活一次点击、**不注入鼠标事件**(相机可动, 投影坐标必点偏)。也可直接传 x/y(默认窗口坐标, 传 space=viewport 则按视口坐标换算)。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路 —— 重复调用会重复扣血/重复触发, 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_click(),
		_call_simulate_click,
		func(args): return await _call_runtime_proxy("simulate_click", args))

	_register_game_play_tool("simulate_drag",
		"在游戏窗口模拟拖拽(按下→移动→释放), 测试拖拽交互。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路, 重复调用会重复触发(如重复拾取/重复移动), 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_drag(),
		_call_simulate_drag,
		func(args): return await _call_runtime_proxy("simulate_drag", args))

	_register_game_play_tool("simulate_key",
		"在游戏窗口模拟键盘按键(按下/释放), 测试键盘交互。【副作用】注入的是**真实输入事件**, 会打进用户此刻正在玩的那个游戏窗口并走完整业务链路, 重复调用会重复触发(重复跳两次/重复扣血), 故不可自动重试; 游戏未在运行时调用会失败。",
		MCPToolSchema.simulate_key(),
		_call_simulate_key,
		func(args): return await _call_runtime_proxy("simulate_key", args))

	# take_screenshot 的 name/desc/schema 由 MCPScreenshotTools.spec() 单副本提供, 这里不再各写
	# 一份 —— 两处各写必然漂移, 而 desc 漂移不会编译报错, 只在客户端表现为"参数说明对不上"。
	# 两个 handler 都要留在主文件: _runtime_take_screenshot 要 Node 上下文(get_viewport/get_tree),
	# _call_take_screenshot 的 text/game 分支要 _call_runtime_proxy(内部挂 _pending/debugger_plugin)。
	var _shot_spec := MCPScreenshotTools.spec()
	_register_game_play_tool(_shot_spec["name"],
		_shot_spec["desc"],
		_shot_spec["schema"],
		_runtime_take_screenshot,
		_call_take_screenshot)

	_register_game_play_tool("game_eval",
		"在游戏进程执行GDScript代码, 可访问游戏场景树(get_tree()/get_node()/get_viewport()等), 读运行状态/改变量/触发逻辑。【副作用】执行的是**任意 GDScript 代码**并会先热重载游戏脚本: 可改运行状态(血量/场景/存档)或停掉游戏, 故不可自动重试; 纯查询类需求优先用 take_screenshot(capture_type='text') 或 get_game_logs。可return返回值。支持await: 代码含await时等待协程完成后回传最终结果(超时协程继续后台执行, timeout_ms 上限见参数)。get_node相对路径基于eval实例, 访问场景节点用绝对路径/root/场景名/子路径或get_tree().current_scene.get_node(...)。【新鲜度闸门】引擎不热重载游戏进程, 所以改过 .gd 后执行只会得到旧代码的无效结果。本工具会先自动热重载, 再按两类原因拒绝执行(error_category=stale_code): ①该脚本在游戏里已有既存实例(引擎不允许热替换实例类型)——消息会给出具体脚本与节点路径; ②该脚本是全局类(class_name)——实测全局类引用不随脚本缓存刷新, 且游戏进程无 EditorInterface 无法刷全局类表。因此改过 .gd 后仍需 game_control(action=start) 重启再验证。",
		{"type": "object", "properties": {"code": MCPToolSchema.code_arg(), "timeout_ms": MCPToolSchema.code_timeout_arg(), "auto_resume": {"type": "boolean", "description": "可选: 游戏处于断点暂停时先自动 game_control(action=continue) 再执行(默认 false —— 默认不自动跳过, 以免掩盖真错误; 确认只是瞬态暂停时可传 true)"}}},
		MCPDevTools._call_eval_code,
		func(args): return await _call_game_eval_proxy(args))

	_register_game_play_tool("run_game_tests",
		"在**游戏进程**里跑需要游戏进程的用例(Scripts/Test/ 下声明 needs_game_process() 返回 true 的用例; 依赖 MonitorGame/场景树/真实时间轴)。发射即返回+读进度: 首次调用启动, 之后反复调用读同一份报告直到 running=false(不要带 filter 中途重启)。与编辑器侧的 run_tests 互补: run_tests 会把这些用例列为 skipped, 两类合起来才是全量。需游戏已运行(game_control start)。",
		{"type": "object", "properties": {
			"filter": {"type": "string", "description": "可选: 用例文件路径子串过滤(仅启动时生效)"},
			"wait_ms": {"type": "integer", "description": "本次最多等待毫秒(默认 8000, 上限 15000), 超时返回当前进度"}
		}},
		_runtime_run_game_tests,
		func(args): return await _call_runtime_proxy("run_game_tests", args))

	# 以下 4 个是**游戏进程侧**的日志/清理入口。游戏进程内不注册 get_logs/clear_logs,
	# 它们是那里唯一的通道, 故不可合并掉; 但也**不该**在编辑器侧跟 get_logs/clear_logs 合并
	# —— 那正是 source=auto 静默串缓冲的由来。现在两侧各自按名字自洽: 带 game_ 的读游戏
	# 缓冲, 不带的读本进程; 跨进程只由下面这个 lambda 转发, 各 handler 内部一律不自行代理。
	_register_game_play_tool("get_game_logs",
		"【游戏进程】获取游戏进程的日志(print/printerr)。编辑器进程自己的日志用 get_logs —— 两者读的是不同缓冲, 不会互相串。返回next游标, 增量用其作since避免重复。连续重复的同内容日志自动合并为一条(repeat 计数)以节省token。",
		MCPToolSchema.logs("200", "日志"),
		_call_get_game_logs,
		func(args): return await _call_runtime_proxy("get_game_logs", args))

	_register_game_play_tool("get_game_errors",
		"【游戏进程】获取游戏进程捕获的错误(脚本错误/assert/push_error), 含文件/行号/类型/栈追踪。编辑器进程自己的错误用 get_logs(kind=error)。游戏被断点暂停时本工具与 get_game_logs 仍可安全调用。返回next游标, 增量用其作since。连续重复的同位置错误自动合并为一条(repeat 计数)以节省token。",
		MCPToolSchema.logs("100", "错误"),
		_call_get_errors,
		func(args): return await _call_runtime_proxy("get_game_errors", args))

	_register_game_play_tool("clear_game_errors",
		"【游戏进程】清空游戏进程的错误缓冲。编辑器进程自己的缓冲用 clear_logs。",
		{"type": "object", "properties": {"scope": {"type": "string", "enum": ["all", "logs", "errors"], "description": "清理范围, 默认 all"}}},
		MCPLogTools._call_clear_errors,
		func(args): return await _call_runtime_proxy("clear_game_errors", args))

	_register_game_play_tool("clear_game_logs",
		"【游戏进程】清空游戏进程的日志缓冲。编辑器进程自己的缓冲用 clear_logs。",
		{"type": "object", "properties": {"scope": {"type": "string", "enum": ["all", "logs", "errors"], "description": "清理范围, 默认 all"}}},
		MCPLogTools._call_clear_errors,
		func(args): return await _call_runtime_proxy("clear_game_logs", args))

	_register_game_play_tool("auto_verify",
		"自动验证闭环: 启动场景后按 operations 序列模拟玩家行为, 每步后增量查错。【副作用: 会接管用户正在玩的游戏】若已有游戏在运行, 本工具会**先将其停止**再启动本工具指定的场景, 结束后再停掉游戏 —— 用户手头的游戏进程会被中断且不会自动恢复。执行前先用 get_editor_activity 确认没有正在进行的调试。操作各字段格式见 operations 参数(不在此复述); 其中 poll 的探测期 eval 出错**不计入**失败判定。retries>0 时曾失败但最终通过会标 was_flaky=true(警惕被时序掩盖的潜在bug), 返回retry_history。返回verdict=pass/fail+逐步明细+first_error_step。注意: duration 是单次总时长上限, 操作总耗时(含wait/poll)不能超过它; duration建议<=15s(代理超时20s)。",
		MCPToolSchema.auto_verify(),
		_runtime_auto_verify,
		func(args): return await _call_auto_verify(args))

	# 游戏进程侧自检: 这里注册的是 runtime 工具子集, 与编辑器侧完整集合不同 —— 名单里若有
	# 本模式不存在的名字, 只有各自自检才抓得到。
	# 用 _mode 判定而非无条件执行: 编辑器侧经 _register_game_play_tools 也会走到这里, 若
	# 同样跑一次就会与 _register_editor_tools 末尾的全量自检重复告警(内容完全相同的两次
	# 打印), 而编辑器侧那次才是权威的全量结果。
	if _mode == MODE_RUNTIME:
		_audit_tools()


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
		elif node is Polygon2D:
				var polygon := node as Polygon2D
				info["polygon_count"] = polygon.polygon.size()
		result.append(info)
	for child in node.get_children():
		_collect_visible_nodes(child, viewport, result, max_nodes, depth + 1, max_depth)


## 运行时: 模拟鼠标左键点击(游戏进程内 Input.parse_input_event 直接生效)
##
## 三条定位路径, 优先 ref:
##   ref + space=window/subviewport —— 由 MCPUITools 解析成**实时**坐标。界面在查询与点击之间
##   动过也不会点偏。
##   ref + space=3d —— **不投递鼠标事件**, 改为在物体自身上激活, 见 _activate_interactable_3d。
##   x/y —— 调用方自报坐标系(space, 默认 window)。必须自报: Input.parse_input_event 收的是
##   **窗口坐标**, 而 Control.global_position / get_interactables 的 viewport_rect 是**视口坐标**,
##   两者差一个 content_scale。旧版描述写"坐标为游戏视口坐标"是错的 —— 照它传值会稳定点在
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
			return _fail("space 只能是 window 或 viewport, 收到: %s" % space)
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
		# 走全局输入是点不到的 —— 那块 UI 在 3D 平板上, 窗口坐标落在它上面也不会被它收到。
		#
		# 必须先补一个 motion: push_input 是同步处理的, 不先把鼠标"挪到"目标上建立 hover,
		# 紧随其后的 press/release 不会让 BaseButton 进入按下态(实测: 补 motion 必中, 不补不中)。
		# 窗口那条路不需要, 因为 Input.parse_input_event 走的是 OS 事件队列, hover 会被顺带更新。
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
##
## 为什么不用射线命中: 3D 物体投影到屏幕是个点, 而本项目相机带鼠标跟随视角(PlayerCamera 的
## rotation_offset 按鼠标相对屏幕中心的偏移 lerp, max 5°, 实测能让屏幕元素位移 66~176px),
## 于是"投影坐标 → 注入点击"这条回路必然脱靶, 且脱靶量随鼠标位置变化。activate() 是物体
## 自己提供的确定性入口(ButtonView3D.activate 内部就是 _mouse_down + _mouse_up), 与真人
## 操作、手柄焦点导航(InputTool._activate_3d)走的是同一条路径。
##
## 代价: 绕过遮挡判定 —— 被别的物体挡住时这里照样会触发。对"点它一下会发生什么"正是想要的,
## 但要知道它**不等价于**"点在屏幕上那个位置"。
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


## ======= 运行时: 游戏进程用例(依赖 MonitorGame / 场景树 / 真实时间轴) =======

## 游戏用例会话状态: `run_game_tests` 首次调用启动, 后续调用读进度 ——
## 一个完整的游戏用例(真实战斗 + 真实回放)远超工具单次超时, 不能靠一次调用等完。
var _game_tests_running := false
var _game_tests_report: Dictionary = {}


## 运行时: 在**游戏进程**里跑需要游戏进程的用例(`TestRunner` MODE_GAME)。
## 用法: 首次调用启动, 之后反复调用读进度 —— 流程与断言全在用例里, 调用方不需要任何编排。
func _runtime_run_game_tests(args: Dictionary) -> Dictionary:
	var filter := VariantTool.get_string(args, "filter")
	var wait_ms: int = clampi(VariantTool.get_int(args, "wait_ms", 8000), 0, 15000)
	var started := false
	if not _game_tests_running:
		_game_tests_running = true
		_game_tests_report = {}
		started = true
		_run_game_tests_async(filter)  # 有意不 await(见上方状态说明)
	if wait_ms > 0:
		var tree := get_tree()
		if tree:
			var deadline := Time.get_ticks_msec() + wait_ms
			while _game_tests_running and Time.get_ticks_msec() < deadline:
				await tree.create_timer(0.2).timeout
	var out: Dictionary = _game_tests_report.duplicate(true)
	out.running = _game_tests_running
	if started:
		out.started = true
	if _game_tests_running:
		out.hint = "用例仍在运行: 再次调用 run_game_tests 读进度即可(带 filter 会等本轮结束后重启)"
	return _ok_json(out)


func _run_game_tests_async(filter: String) -> void:
	var summary: Dictionary = await TestRunner.run_all(filter, TestRunner.TESTS_DIR, TestRunner.MODE_GAME)
	_game_tests_report = summary
	_game_tests_running = false


## 运行时: 捕获游戏视口截图(文件名自动生成)
func _runtime_take_screenshot(args: Dictionary) -> Dictionary:
	var capture_type: String = VariantTool.get_string(args, "capture_type", "text")
	# 纯文本化截图模式(text): 不保存图片, 直接返回可见节点布局快照。
	# 适合点击游玩模拟与无法识别图像的 AI, 大幅节省 token。默认模式。
	if capture_type == "text":
		var text_max_nodes := VariantTool.get_int(args, "text_max_nodes", 50)
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
	var viewport := get_viewport()
	if viewport == null:
		return _fail("无法获取游戏视口")
	# 统一走 ScreenshotTool: 取图 -> sRGB 校正(保证颜色正确) -> 缩放 -> 保存。
	# 缺省降采样到 1280 宽以控制体积, 传更大的 max_width 可保留更高分辨率。
	var shot: Dictionary = await ScreenshotTool.capture(viewport, {
		"path": "%s/%s" % [dir_path, filename],
		"max_width": VariantTool.get_int(args, "max_width", ScreenshotTool.DEFAULT_MAX_WIDTH),
		"srgb": VariantTool.get_bool(args, "srgb", true),
		"capture_type": "game",
	})
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
	}
	# 整合文本化截图快照(text): 截图同时返回画面可见节点布局,
	# 供 AI 在无图像输入时也能理解画面。可用 include_text=false 关闭, text_max_nodes 控制节点数。
	if VariantTool.get_bool(args, "include_text", true):
		var text_max_nodes := VariantTool.get_int(args, "text_max_nodes", 50)
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
	var operations: Array = VariantTool.get_array(args, "operations")
	if operations.is_empty():
		return _fail("必须提供 operations 操作序列")
	var duration := VariantTool.get_float(args, "duration", 4.0)
	var stop_on_error := VariantTool.get_bool(args, "stop_on_error", true)
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
				var r4: Dictionary = await MCPDevTools._call_eval_code({"code": str(op.get("code", ""))})
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
		var r: Dictionary = await MCPDevTools._call_eval_code({"code": code})
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


## 编辑器进程: 解除游戏断点暂停(等效编辑器的 Continue 按钮)
##
## **入口是 game_control(action=continue), 不是一个独立工具** —— 这不是命名偏好, 是被工具列表
## 逼出来的: 协议层的 tools/list 由**客户端**决定把哪些工具映射成本会话里可调用的入口, 而那个
## 名单不受服务端控制。曾把它注册成独立工具 debug_continue, 服务端 tools/list 里确实有(50 个),
## 但客户端映射里没有, 于是 game_breaked 类错误的 recovery("...后 debug_continue")指向一个
## **AI 看得见名字、却调不到**的工具: 恢复路径在最需要它的时刻断开, 而这类错误恰恰只在
## 游戏出错时出现, 也就是说它在开发中后期才暴露。
func _call_debug_continue(_args: Dictionary) -> Dictionary:
	if not _has_game_session():
		return _fail("没有运行中的游戏, 无需继续")
	if not debugger_plugin.is_breaked():
		return _ok("游戏当前未处于断点暂停状态, 无需继续")
	if debugger_plugin.debug_continue():
		_game_breaked = false
		return _ok("已让游戏继续运行(解除断点暂停)")
	return _err_internal("无法解除断点暂停", "尝试 game_control(action=stop) 后 game_control(action=start) 重启")


## 转发工具调用到游戏进程(经 EngineDebugger 调试线)。仅编辑器模式。
func _call_runtime_proxy(tool_name: String, args: Dictionary) -> Dictionary:
	if debugger_plugin == null or not debugger_plugin.has_active_session():
		return _err_game_stopped("游戏未运行。请先使用 game_control(action=start) 启动游戏", "调用 game_control(action=start) 启动游戏, 等待调试线就绪后重试")
	if _game_breaked and not _BREAK_SAFE_TOOLS.has(tool_name):
		# 断点暂停: 依赖主循环的工具必然挂起; get_game_errors/get_game_logs仍可用; 自动回查错误缓冲拼进响应。
		var diagnose := await _fetch_recent_game_error(tool_name)
		if diagnose != "":
			return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n已自动读取错误:\n%s\n\n修正脚本后 game_control(action=continue) 继续, 或 game_control(action=stop) 重启。" %
				[tool_name, diagnose])
		return _err_game_breaked("游戏被断点暂停, 工具 %s 需要主循环无法执行。\n错误缓冲无内容(可能是手动断点)。get_game_errors复核后 game_control(action=continue), 或 game_control(action=stop) 重启。" %
			tool_name, "get_game_errors复核后game_control(action=continue); 或game_control(action=stop)修复重启")
	if not _game_ready:
		return _err_transient("游戏调试线尚未就绪", "等待游戏启动完成(可稍后重试, 或 game_control(action=start) 重启)")
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
			return _err_game_stopped("游戏进程已停止/崩溃(工具 %s 请求被取消)。先 game_control(action=start) 重启。" % tool_name,
				"game_control(action=start)重启后重试")
		await get_tree().process_frame
	if _pending.has(req_id):
		_pending.erase(req_id)
	# 超时主因: eval触发运行期脚本错误导致_mcp_run中止未回发, 或是死循环/卡死。自动回查错误缓冲拼进响应。
	var diagnose := await _fetch_recent_game_error(tool_name)
	if diagnose != "":
		# 同上面的 eval 分支: 原样重发同一工具必然再超时一次, 故 is_retryable=false。
		# 有效路径是先按 recovery 改代码或重启游戏 —— 那属于"改参数后重试"。
		return _err_validation("游戏进程响应超时(20s), 工具: %s。已发现运行期脚本错误:\n%s\n\n修正代码后重试; 若无疑错误仍超时再考虑死循环。" %
			[tool_name, diagnose],
			"修正上方脚本错误后重试; 仍超时则 game_control(action=stop) 后 game_control(action=start) 重启")
	return _err("游戏进程响应超时(20s), 工具: %s。错误缓冲无脚本错误, 可能是死循环/卡死或无响应。" % tool_name,
		MCPResult.CAT_TRANSIENT, true, "查game_eval是否死循环; 必要时 game_control(action=stop) 后 game_control(action=start) 重启")


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
	# 保留来源侧的 content[].text(错误响应里是 _err 拼的结构化 JSON): 代理归一化的只是
	# 外层形状, 不该顺手把内层承载的信息降级成纯文本 —— 那样游戏侧 _err 拼好的
	# category / recovery 到 AI 那里又看不见了, 代理反而成了信息黑洞
	var content_text := text
	if result.get("content") is Array:
		var c: Array = result["content"]
		if not c.is_empty() and c[0] is Dictionary:
			content_text = str(c[0].get("text", text))
	return _wrap(text, is_err, extra, content_text)


## 编辑器侧 game_eval 转发: 先本地预编译 + 静态检查, 通过后才发到游戏进程。
## 语法错误/被禁止的代码在编辑器内拦截, 避免污染游戏进程(运行时解析错误可能中断游戏)。
##
## 新鲜度**不在这里**判定: 编辑器只知道"哪些文件变了", 不知道"游戏里是否已存在
## 这些脚本的实例", 而后者才是能否热替换的关键。只有游戏进程能遍历自己的场景树,
## 所以判定统一交给游戏侧的 guard_eval —— 它会先尝试热重载, 再按"有既存实例"
## 与"是全局类"两类原因分别上报(后者是引擎限制, 游戏进程刷不了全局类表)。
func _call_game_eval_proxy(args: Dictionary) -> Dictionary:
	var precheck := MCPDevTools.precheck_eval_code(VariantTool.get_string(args, "code"))
	if precheck != "":
		return _err_validation("game_eval 被编辑器侧预检拦截: %s" % precheck, "修正代码后重新调用 game_eval(语法错误无法通过重试解决, 需修改代码)")
	## auto_resume: 调用方明确要求时先解除断点暂停再执行(默认不开, 避免掩盖真错误)
	if VariantTool.get_bool(args, "auto_resume") and _game_breaked:
		var resumed := await _call_debug_continue({})
		if bool(resumed.get("is_error", false)):
			return resumed
	return await _call_runtime_proxy("game_eval", args)


