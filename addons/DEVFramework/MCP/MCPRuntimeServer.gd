@tool
extends Node

## ======= 运行时建模 MCP 服务器(发布版可用) =======
##
## 【定位】现有 MCPDevServer 是**编辑器耦合**的: 它引用 `EditorInterface`/`EditorUndoRedoManager`,
## 一旦打进正式包会在解析期失败(发布模板里没有这些编辑器类), 故插件在导出时用 `_PackMcpFilter`
## 把它的 autoload 整个删掉 —— 结果是**打包后没有任何 MCP 入口**。
##
## 本文件是它面向"建模应用/发布版"的**运行时孪生**: **只依赖运行时可编译的组件**
##   · 传输  MCPTcpHttpServer(0 处编辑器引用)
##   · 结果  MCPResult / 注解 MCPToolMeta(0 处编辑器引用)
## 且**绝不出现任何编辑器类标识符**(GDScript 的标识符是编译期解析的, 出现即整脚本编不过)。
##
## 【怎么用】作为 autoload 装载, 只在**非编辑器进程**启动并监听 127.0.0.1:port; 具体建模工具
## 由**项目侧**以 provider 脚本提供(本项目: QVoxelMCPTools), 经项目设置
## `dev_framework/mcp/runtime_providers` 声明。框架只管"机制"(传输+协议+工具注册), 不认体素
## —— 与 DEVFramework/VoxelSupport 的分层($框架=机制, 项目=内容)一致。
##
## 【安全】默认只听 127.0.0.1, 且**不提供任何 eval/任意代码执行工具** —— 发布包里开放 eval 等于
## 把远程代码执行接口随游戏一起分发。要扩展能力就加具体工具, 不要加 eval。

const MCPTcpHttpServer := preload("res://addons/DEVFramework/MCP/MCPTcpHttpServer.gd")
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolMeta := preload("res://addons/DEVFramework/MCP/MCPToolMeta.gd")

const SERVER_NAME := "voxel-runtime-mcp"
const SERVER_VERSION := "1.0.0"
const PROTOCOL_VERSION := "2025-03-26"
const SUPPORTED_PROTOCOL_VERSIONS := ["2025-11-25", "2025-06-18", "2025-03-26"]

const SETTING_ENABLED := "dev_framework/mcp/runtime_enabled"
const SETTING_PORT := "dev_framework/mcp/runtime_port"
const SETTING_PROVIDERS := "dev_framework/mcp/runtime_providers"
const DEFAULT_PORT := 18931

var _http: MCPTcpHttpServer
var _tool_defs: Array = []
var _tool_schemas := {}
var _tool_handlers := {}
var _port := DEFAULT_PORT
var _session_id := ""


func _ready() -> void:
	# 编辑器进程不启用(那边由插件持有的 MCPDevServer 提供, 避免端口/生命周期冲突)。
	if Engine.is_editor_hint():
		return
	if not bool(ProjectSettings.get_setting(SETTING_ENABLED, true)):
		return
	_port = int(ProjectSettings.get_setting(SETTING_PORT, DEFAULT_PORT))
	_session_id = "runtime-%d" % int(Time.get_unix_time_from_system())
	_register_providers()
	var err := _start()
	if err != OK:
		push_error("[MCPRuntime] 监听 127.0.0.1:%d 失败(错误码 %d)" % [_port, err])
		return
	print("[MCPRuntime] 建模服务器已启动: http://127.0.0.1:%d/  (%d 个工具)" % [_port, _tool_handlers.size()])


func _process(_delta: float) -> void:
	if _http != null:
		_http.poll()


func _exit_tree() -> void:
	if _http != null:
		_http.stop()
		_http = null


func _start() -> Error:
	_http = MCPTcpHttpServer.new()
	var err := _http.listen(_port, "127.0.0.1")
	if err != OK:
		_http = null
		return err
	_http.request_received.connect(_on_request)
	return OK


## provider 脚本须提供 `static func register(add_tool: Callable)`; 逐条以
## (name, desc, schema, handler) 注册。漏配/脚本缺失只告警, 不影响服务器启动。
func _register_providers() -> void:
	var providers: Variant = ProjectSettings.get_setting(SETTING_PROVIDERS, PackedStringArray())
	if not (providers is Array or providers is PackedStringArray):
		return
	for p in providers:
		var script: Variant = load(str(p))
		if script != null and script.has_method("register"):
			script.register(_add_tool)
		else:
			push_warning("[MCPRuntime] provider 无效(需 static register(add_tool)): %s" % str(p))


func _add_tool(name: String, desc: String, schema: Dictionary, handler: Callable) -> void:
	_tool_handlers[name] = handler
	_tool_schemas[name] = schema
	_tool_defs.append(MCPToolMeta.build(name, desc, schema))


# ---------------- HTTP / JSON-RPC ----------------

func _on_request(method: String, _path: String, query: String, headers: Dictionary, body: PackedByteArray, stream) -> void:
	if _http == null:
		return
	if method == "OPTIONS":
		_http.send_response(stream, 204, _cors(headers), "")
		return
	if method == "GET":
		# 少数客户端默认走旧式 HTTP+SSE(先 GET 等 endpoint 事件); 直接 405 会让它放弃连接。
		var sid := _http.open_legacy_sse(stream, _sse_headers(headers), "http://127.0.0.1:%d/mcp" % _port, true)
		if sid.is_empty():
			_http.send_response(stream, 405, _cors(headers), "")
		return
	if method != "POST":
		_http.send_response(stream, 405, _cors(headers), "")
		return
	# 防浏览器跨站调用(即使只读工具也不该被网页触发): 非本机 Origin 一律拒绝。
	var origin := str(headers.get("origin", "")).to_lower()
	if not origin.is_empty() and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost") or origin.begins_with("http://0.0.0.0")):
		_http.send_response(stream, 403, _cors(headers), "")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		_http.send_response(stream, 400, _cors(headers), "")
		return
	var response: Dictionary = await _dispatch(parsed)
	if response.is_empty():
		_http.send_response(stream, 202, _cors(headers), "")
		return
	var json := JSON.stringify(response)
	var sid_q := _query_param(query, "sessionId")
	if not sid_q.is_empty() and _http.has_sse_session(sid_q) and _http.send_sse_message(sid_q, json):
		_http.send_response(stream, 202, _cors(headers), "")
		return
	_http.send_response(stream, 200, _cors_json(headers), json)


func _dispatch(req: Dictionary) -> Dictionary:
	var id: Variant = req.get("id", null)
	var rpc_method := str(req.get("method", ""))
	match rpc_method:
		"initialize":
			var requested := ""
			var params: Variant = req.get("params", {})
			if params is Dictionary:
				requested = str((params as Dictionary).get("protocolVersion", ""))
			var agreed := requested if SUPPORTED_PROTOCOL_VERSIONS.has(requested) else PROTOCOL_VERSION
			print("[MCPRuntime] 客户端初始化: %s (协议 %s -> %s)" % [
				str((params as Dictionary).get("clientInfo", {})) if params is Dictionary else "-", requested, agreed])
			return {"jsonrpc": "2.0", "id": id, "result": {
				"protocolVersion": agreed,
				"capabilities": {"tools": {"listChanged": false}},
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			}}
		"ping":
			return {"jsonrpc": "2.0", "id": id, "result": {}}
		"tools/list":
			return {"jsonrpc": "2.0", "id": id, "result": {"tools": _tool_defs}}
		"tools/call":
			var params: Variant = req.get("params", {})
			var pd: Dictionary = params if params is Dictionary else {}
			var tool_name := str(pd.get("name", ""))
			var raw_args: Variant = pd.get("arguments", {})
			if not (raw_args is Dictionary):
				return _rpc_error(id, -32602, "Invalid params: 'arguments' must be an object")
			if not _tool_handlers.has(tool_name):
				return _rpc_error(id, -32602, "Unknown tool: %s" % tool_name)
			var result: Variant = await _tool_handlers[tool_name].call(raw_args)
			var res: Dictionary = result if result is Dictionary else MCPResult.ok(str(result))
			return {"jsonrpc": "2.0", "id": id, "result": MCPResult.for_protocol(res)}
		_:
			if rpc_method.begins_with("notifications/"):
				return {}
			return _rpc_error(id, -32601, "Method not found: %s" % rpc_method)


static func _rpc_error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _cors(headers: Dictionary) -> Dictionary:
	var h := {
		"Content-Type": "application/json",
		"Mcp-Session-Id": _session_id,
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id, mcp-protocol-version",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


func _cors_json(headers: Dictionary) -> Dictionary:
	return _cors(headers)


func _sse_headers(headers: Dictionary) -> Dictionary:
	var h := {
		"Access-Control-Allow-Methods": "POST, GET, OPTIONS",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Session-Id",
	}
	var origin := str(headers.get("origin", ""))
	if not origin.is_empty():
		h["Access-Control-Allow-Origin"] = origin
	return h


static func _query_param(query: String, key: String) -> String:
	for pair in query.split("&", false):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == key.to_lower():
			return kv[1].uri_decode()
	return ""
