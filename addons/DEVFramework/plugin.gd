@tool
extends EditorPlugin

# MCP 服务器由两个开关协作管理:
#   - 插件启用/停用: 决定 autoload 行(project.godot)和编辑器服务器节点的存在
#   - dev_framework/mcp/enabled: 独立主开关, 可在项目设置里单独控制,
#     MCPDevServer 启动时读取它, 为 false 则编辑器/游戏进程都不起服务器
# autoload 行(DevMCP)只对"游戏运行进程"起作用(run_game 时游戏内开启运行时服务器),
# 编辑器本身的服务器由本插件持有的 MCPDevServer 节点提供, 两者互不冲突。

const DevProjectSetup = preload("res://addons/DEVFramework/Tool/DevProjectSetup.gd")
const DevAudioExamples = preload("res://addons/DEVFramework/Tool/DevAudioExamples.gd")

const AUTOLOAD_NAME := "DevMCP"
const AUTOLOAD_PATH := "res://addons/DEVFramework/MCP/MCPDevServer.gd"

var _mcp: MCPDevServer
var _debugger_plugin: MCPDebuggerPlugin


func _enter_tree() -> void:
	_register("dev_framework/log/enabled", TYPE_BOOL, true)
	_register("dev_framework/log/show_timestamps", TYPE_BOOL, false)
	_register("dev_framework/log/ignored_tags", TYPE_PACKED_STRING_ARRAY, PackedStringArray())
	_register("dev_framework/save_tool/encrypt_salt", TYPE_STRING, ProjectSettings.get_setting("application/config/name", "GodotProject"))
	_register("dev_framework/mcp/enabled", TYPE_BOOL, true)
	_register("dev_framework/mcp/port", TYPE_INT, 8931)
	_register("dev_framework/mcp/token", TYPE_STRING, "")
	_register("dev_framework/audio/default_sample_rate", TYPE_INT, 44100)
	add_tool_menu_item("创建 DEV 项目结构...", Callable(self, "_on_create_structure"))
	add_tool_menu_item("DEV 音频：生成示例音频定义...", Callable(self, "_on_create_audio_examples"))
	# 启用插件: 开启 MCP
	_set_mcp_enabled(true)


func _exit_tree() -> void:
	remove_tool_menu_item("创建 DEV 项目结构...")
	remove_tool_menu_item("DEV 音频：生成示例音频定义...")
	# 停用插件: 关闭 MCP
	_set_mcp_enabled(false)


func _on_create_structure() -> void:
	DevProjectSetup.create_structure()


func _on_create_audio_examples() -> void:
	var results := DevAudioExamples.create_all()
	LogTool.log("音频", "示例生成完成: ", results)


## 插件开关: enable=true 写 autoload 行并启动编辑器服务器, 否则停止并移除 autoload 行。
## 不触碰 dev_framework/mcp/enabled —— 那是独立的项目设置主开关, 由 MCPDevServer 读取。
func _set_mcp_enabled(enable: bool) -> void:
	_write_autoload_row(enable)
	if enable:
		if _mcp == null:
			_mcp = MCPDevServer.new()
			add_child(_mcp)
		# 建立调试线桥接: 运行时工具经 EngineDebugger wire 转发到游戏进程
		if _debugger_plugin == null:
			_debugger_plugin = MCPDebuggerPlugin.new()
			_debugger_plugin.server = _mcp
			add_debugger_plugin(_debugger_plugin)
		_mcp.debugger_plugin = _debugger_plugin
		_mcp.start_editor()
	else:
		if _debugger_plugin:
			remove_debugger_plugin(_debugger_plugin)
			_debugger_plugin.server = null
			_debugger_plugin = null
		_mcp.debugger_plugin = null
		if _mcp:
			_mcp.stop()
			_mcp.queue_free()
			_mcp = null


## 写入/移除 project.godot 的 autoload 行(供游戏运行进程的运行时服务器使用)
func _write_autoload_row(enable: bool) -> void:
	if enable:
		ProjectSettings.set_setting("autoload/" + AUTOLOAD_NAME, "*" + AUTOLOAD_PATH)
	else:
		ProjectSettings.set_setting("autoload/" + AUTOLOAD_NAME, null)
	ProjectSettings.save()


func _register(name: String, type: int, default) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type})
	ProjectSettings.set_initial_value(name, default)