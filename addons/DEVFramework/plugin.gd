@tool
extends EditorPlugin

# MCP 服务器由两个开关协作管理:
#   - 插件启用/停用: 决定 autoload 行(project.godot)和编辑器服务器节点的存在
#   - dev_framework/mcp/enabled: 独立主开关, 可在项目设置里单独控制,
#     MCPDevServer 启动时读取它, 为 false 则编辑器/游戏进程都不起服务器
# autoload 行(DevMCP)只对"游戏运行进程"起作用(run_game 时游戏内开启运行时服务器),
# 编辑器本身的服务器由本插件持有的 MCPDevServer 节点提供, 两者互不冲突。

const DEF_TABLE_SCENE := "res://addons/DEVFramework/DefTable/DefTableView.tscn"
## 虚拟机位 3D 视图可视化(仅编辑器加载, 故用路径而非全局类)
const CAMERA_GIZMO_SCRIPT := "res://addons/DEVFramework/Camera/Editor/VirtualCameraGizmo.gd"
## 虚拟机位取景器(底部面板, 预览机位看到的画面)
const CAMERA_VIEWFINDER_SCRIPT := "res://addons/DEVFramework/Camera/Editor/CameraViewfinder.gd"

const AUTOLOAD_NAME := "DevMCP"
const AUTOLOAD_PATH := "res://addons/DEVFramework/MCP/MCPDevServer.gd"
## 导出血 DevMCP autoload 用的键（导出时临时移除，避免编辑器专用脚本进正式包）
const EXPORT_AUTOLOAD_KEY := "autoload/DevMCP"

var _mcp: MCPDevServer
var _debugger_plugin: MCPDebuggerPlugin
var _ecs_debugger: ECSDebuggerPlugin
var _def_table: Control
var _camera_gizmo: EditorNode3DGizmoPlugin
var _camera_viewfinder: Control
var _camera_viewfinder_button: Button
var _pack_mcp_filter: EditorExportPlugin


func _enter_tree() -> void:
	_register("dev_framework/log/enabled", TYPE_BOOL, true)
	_register("dev_framework/log/show_timestamps", TYPE_BOOL, false)
	_register("dev_framework/log/ignored_tags", TYPE_PACKED_STRING_ARRAY, PackedStringArray())
	_register("dev_framework/save_tool/encrypt_salt", TYPE_STRING, ProjectSettings.get_setting("application/config/name", "GodotProject"))
	_register("dev_framework/mcp/enabled", TYPE_BOOL, true)
	_register("dev_framework/mcp/port", TYPE_INT, 8931)
	_register("dev_framework/mcp/token", TYPE_STRING, "")
	_register("dev_framework/mcp/max_output_chars", TYPE_INT, 90000)
	_register("dev_framework/audio/default_sample_rate", TYPE_INT, 44100)
	# 先开启 MCP 调试服务器, 避免后续初始化(工具菜单/DefTable)出错时阻断调试链路
	_set_mcp_enabled(true)
	# 导出时剔除 DevMCP autoload（编辑器专用脚本不进正式包，避免解析崩溃）
	_pack_mcp_filter = _PackMcpFilter.new(EXPORT_AUTOLOAD_KEY)
	add_export_plugin(_pack_mcp_filter)
	# 所有编辑器工具统一由 Tool 目录下 extends EditorScript 的脚本自动注册
	EditorScriptMenuTool.register(self)
	_setup_def_table()
	_setup_camera_gizmo()
	_setup_camera_viewfinder()


func _exit_tree() -> void:
	_teardown_camera_viewfinder()
	_teardown_camera_gizmo()
	_teardown_def_table()
	EditorScriptMenuTool.unregister(self)
	if _pack_mcp_filter:
		remove_export_plugin(_pack_mcp_filter)
		_pack_mcp_filter = null
	# 停用插件: 最后关闭 MCP
	_set_mcp_enabled(false)


## DefTable: 顶部 Main Screen Tab, 查看/复制/粘贴 Def 静态数据
func _setup_def_table() -> void:
	if _def_table != null:
		return
	var scene: PackedScene = load(DEF_TABLE_SCENE)
	if scene == null:
		return
	_def_table = scene.instantiate()
	_def_table.editor_interface = get_editor_interface()
	_def_table.editor_plugin = self
	_def_table.visible = false
	get_editor_interface().get_editor_main_screen().add_child(_def_table)


func _teardown_def_table() -> void:
	if _def_table == null:
		return
	if is_instance_valid(_def_table):
		_def_table.queue_free()
	_def_table = null


## Camera 模块: 在 3D 视图中画出 VirtualCamera3D 的视锥, 方便直接摆机位
func _setup_camera_gizmo() -> void:
	if _camera_gizmo != null:
		return
	var script := load(CAMERA_GIZMO_SCRIPT) as Script
	if script == null:
		return
	_camera_gizmo = script.new()
	if _camera_gizmo != null:
		add_node_3d_gizmo_plugin(_camera_gizmo)


func _teardown_camera_gizmo() -> void:
	if _camera_gizmo == null:
		return
	remove_node_3d_gizmo_plugin(_camera_gizmo)
	_camera_gizmo = null


## Camera 模块: 底部面板取景器, 预览选中机位看到的画面
func _setup_camera_viewfinder() -> void:
	if _camera_viewfinder != null:
		return
	var script := load(CAMERA_VIEWFINDER_SCRIPT) as Script
	if script == null:
		return
	_camera_viewfinder = script.new()
	_camera_viewfinder_button = add_control_to_bottom_panel(_camera_viewfinder, "Camera Viewfinder")


func _teardown_camera_viewfinder() -> void:
	if _camera_viewfinder == null:
		return
	remove_control_from_bottom_panel(_camera_viewfinder)
	if is_instance_valid(_camera_viewfinder):
		_camera_viewfinder.queue_free()
	_camera_viewfinder = null
	_camera_viewfinder_button = null


func _get_plugin_name() -> String:
	return "DefTable"


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_def_table):
		_def_table.visible = visible
		if visible:
			_def_table._on_refresh_pressed()


func _get_plugin_icon() -> Texture2D:
	# 直接引用本地白色表格图标, 避免每次动态查找编辑器主题图标
	var tex := load("res://addons/DEVFramework/DefTable/icon_table.png") as Texture2D
	if tex != null:
		return tex
	return get_editor_interface().get_base_control().get_theme_icon("Data", "EditorIcons")


## 插件开关: enable=true 写 autoload 单例行并启动编辑器服务器; false 只停止服务器。
## **单例只添加不自动删除**: 关闭游戏/禁用插件时不动 project.godot, 避免每次关闭游戏产生 git 差异。
## 不触碰 dev_framework/mcp/enabled —— 那是独立的项目设置主开关, 由 MCPDevServer 读取。
func _set_mcp_enabled(enable: bool) -> void:
	if enable:
		_write_autoload_row(true)   # 只添加单例; enable=false 不删除(保持 project.godot 稳定)
	if enable:
		if _mcp == null:
			_mcp = MCPDevServer.new()
			add_child(_mcp)
		# 建立调试线桥接: 运行时工具经 EngineDebugger wire 转发到游戏进程
		if _debugger_plugin == null:
			_debugger_plugin = MCPDebuggerPlugin.new()
			_debugger_plugin.server = _mcp
			add_debugger_plugin(_debugger_plugin)
		# ECS 运行时查看器(系统耗时/实体查看/改值), 独立于 MCP
		if _ecs_debugger == null:
			_ecs_debugger = ECSDebuggerPlugin.new()
			add_debugger_plugin(_ecs_debugger)
		_mcp.debugger_plugin = _debugger_plugin
		_mcp.start_editor()
	else:
		if _debugger_plugin:
			remove_debugger_plugin(_debugger_plugin)
			_debugger_plugin = null
		if _ecs_debugger:
			remove_debugger_plugin(_ecs_debugger)
			_ecs_debugger = null
		if _mcp:
			_mcp.debugger_plugin = null
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


## 导出过滤器：正式打包时临时移除 DevMCP autoload，结束后恢复。
## 背景：MCPDevServer.gd 引用仅编辑器存在的 EditorInterface/EditorUndoRedoManager，
## 若被打进正式包会导致该 autoload 解析失败而崩溃。本过滤器在导出一时移除它，
## 平时测试不受影响（autoload 仍在）。
class _PackMcpFilter extends EditorExportPlugin:
	var _autoload_key: String
	var _removed := false
	var _prev: Variant

	func _init(autoload_key: String) -> void:
		_autoload_key = autoload_key

	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		if ProjectSettings.has_setting(_autoload_key) and ProjectSettings.get_setting(_autoload_key) != null:
			_prev = ProjectSettings.get_setting(_autoload_key)
			ProjectSettings.set_setting(_autoload_key, null)
			ProjectSettings.save()
			_removed = true

	func _export_end() -> void:
		if _removed:
			ProjectSettings.set_setting(_autoload_key, _prev)
			ProjectSettings.save()
			_removed = false
