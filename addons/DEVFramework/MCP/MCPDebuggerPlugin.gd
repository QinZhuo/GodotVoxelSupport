@tool
## 编辑器↔游戏 EngineDebugger wire 桥接插件。
## 通过 Godot 自带调试线(编辑器 F5 / play_custom_scene 启动游戏时自动建立的 TCP 连接)
## 在编辑器与游戏进程之间转发 MCP 运行时工具调用, 零额外端口。
##
## 消息协议(前缀 dev_mcp):
##   编辑器 → 游戏:  "dev_mcp:call"    data = [req_id:int, tool_name:String, args:Dictionary]
##   游戏 → 编辑器:  "dev_mcp:result"  data = [req_id:int, result:Dictionary]
##   游戏 → 编辑器:  "dev_mcp:ready"   data = []   (游戏侧捕获器已注册, 桥接就绪)
##
## 由 plugin.gd 创建并 add_debugger_plugin(), server 指向编辑器侧的 MCPDevServer。
class_name MCPDebuggerPlugin extends EditorDebuggerPlugin

const PREFIX := "dev_mcp"

## 编辑器侧 MCP 服务器引用(由 plugin.gd 注入)
var server: MCPDevServer


func _has_capture(capture: String) -> bool:
	return capture == PREFIX


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if server == null:
		return false
	return server._on_debugger_capture(message, data)


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	session.started.connect(func() -> void:
		if server:
			server._on_session_started(session_id)
	)
	session.stopped.connect(func() -> void:
		if server:
			server._on_session_stopped(session_id)
	)
	# 游戏因脚本错误/断点进入断点暂停(break state)时, 调试线仍在但主循环不执行,
	# 若 MCP 不知道会干等到超时。监听 break/continue 事件, 让服务器能即时感知并
	# 给 AI 明确提示(而不是模糊的"响应超时"), 还能提供"继续"能力。
	session.breaked.connect(func(can_debug: bool) -> void:
		if server:
			server._on_session_breaked(session_id, can_debug)
	)
	session.continued.connect(func() -> void:
		if server:
			server._on_session_continued(session_id)
	)


## 是否有已连接(激活)的游戏调试会话
func has_active_session() -> bool:
	return first_active_session() != null


## 当前激活的会话是否处于断点暂停状态(脚本错误/断点触发导致游戏主循环暂停)
func is_breaked() -> bool:
	var session := first_active_session()
	return session != null and session.is_breaked()


## 解除断点暂停, 让游戏继续运行(等效编辑器 Debugger 面板的 Continue 按钮)
func debug_continue() -> bool:
	var session := first_active_session()
	if session == null or not session.is_breaked():
		return false
	# 游戏侧断点循环(RemoteDebugger::debug)监听 "continue" 指令并恢复执行;
	# 与 ScriptEditorDebugger.debug_continue() 发送的命令一致, 无需额外参数。
	session.send_message("continue", [])
	return true


## 返回第一个激活的游戏调试会话(无则 null)
func first_active_session() -> EditorDebuggerSession:
	for session in get_sessions():
		if session.is_active():
			return session
	return null


## 通过调试线向游戏进程发送一条工具调用消息, 返回是否发送成功
func send_call(req_id: int, tool_name: String, args: Dictionary) -> bool:
	var session := first_active_session()
	if session == null:
		return false
	session.send_message(PREFIX + ":call", [req_id, tool_name, args])
	return true
