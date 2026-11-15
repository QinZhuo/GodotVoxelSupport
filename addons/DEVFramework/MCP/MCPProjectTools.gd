@tool
extends RefCounted

## ======= 项目信息域 =======
## 刻意只调用不复制实现。**必须带 @tool 且不声明 class_name**, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")
const MCPCodeIndex := preload("res://addons/DEVFramework/MCP/MCPCodeIndex.gd")

## 编辑根节点的读取走**跨域共享件**: 用点跨三个域, 留私有副本等于埋一份会静默分叉的复制粘贴
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")

## 会话事实的提供器(无参 Callable)。与 dev 域的 _eval_ctx_provider 同构。
static var _session_facts_provider: Callable = Callable()

## 漏接缝只告警一次的闸。static 而非成员: 只有 static 能活过热重载。
static var _warned_no_provider := false


## 注入会话事实的提供器。以最后一次为准, 无需保留旧的。服务器须在**编辑器进程**调一次(与
## 接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。三个域给了三种不同答案,
## 且都正确, 不要为了"看起来统一"而改: log 域注入(漏调显式报错)、validate 域域内自建(漏调会让
##   1. 没有自建选项: 四个字段都无引擎级静态等价物(见文件末"唯一的状态缝")。
##   2. 不能整体报错: 这两个工具另有大量与状态无关的载荷(项目名/版本/settings 段、
static func set_session_facts_provider(provider: Callable) -> void:
	_session_facts_provider = provider
	_warned_no_provider = false


## ======= 域注册入口 =======
static func register(add_tool: Callable) -> void:
	add_tool.call("get_project_info",
		"项目信息统一入口。section=basic: 名称/版本/当前编辑场景/主场景/运行模式; section=settings: 关键配置(主场景/autoload/输入映射/图层命名); section=classes: 已注册全局类清单(类名/路径/基类, 确认新 class_name 是否生效)。",
		{"type": "object", "properties": {
			"section": {"type": "string", "enum": ["basic", "settings", "classes"], "description": "信息分区, 默认 basic"}
		}},
		_handle_get_project_info)

	add_tool.call("get_editor_activity",
		"编辑器状态(打开场景/选中节点/运行游戏/文件系统选中项), 感知用户在编辑器做了什么避免踩踏。",
		MCPToolSchema.no_arg(),
		_handle_get_editor_activity)


## ======= 实现 =======

static func _handle_get_project_info(args: Dictionary) -> Dictionary:
	var section := VariantTool.get_string(args, "section", "basic")
	if section == "settings":
		return _project_settings_info()
	if section == "classes":
		return MCPCodeIndex.global_classes_info()
	if section != "basic":
		return MCPResult.fail("未知 section: %s (可选 basic/settings/classes)" % section)
	var root := MCPEditorEnv.edited_root()
	var info := {
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"godot_version": Engine.get_version_info(),
		"editor": Engine.is_editor_hint(),
		"debug_build": OS.is_debug_build(),
		"current_scene": root.get_scene_file_path() if root else null,
		"mode": _mode(),
		"mcp_port": _mcp_port(),
	}
	_apply_session_facts(info)
	return MCPResult.ok_json(info)


## 感知编辑器当前状态(用于 AI 与人类协作): 打开场景/选中节点/运行状态等
static func _handle_get_editor_activity(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var out := {
		"mode": "editor",
	}
	# 打开的场景与选中节点
	var root := MCPEditorEnv.edited_root()
	if root:
		out["open_scene"] = root.get_scene_file_path()
		out["scene_name"] = str(root.name)
	var selection := EditorInterface.get_selection()
	if selection != null:
		var selected: Array[Node] = []
		for n in selection.get_selected_nodes():
			selected.append(n)
		out["selected_nodes"] = selected.map(func(n: Node): return str(n.get_path()))
	_apply_session_facts(out)
	return MCPResult.ok_json(out)


static func _project_settings_info() -> Dictionary:
	var root := MCPEditorEnv.edited_root()
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
	return MCPResult.ok_json(info)


## 收集 autoload 单例(名字 -> 路径)
static func _autoloads() -> Dictionary:
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
static func _input_actions() -> Array:
	var out := []
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with("input/"):
			out.append(name.trim_prefix("input/"))
	return out


## 读取图层命名
static func _named_layers(setting_key: String) -> Dictionary:
	var out := {}
	for key in ProjectSettings.get_property_list():
		var name: String = str(key.get("name", ""))
		if name.begins_with(setting_key + "/"):
			var idx := name.trim_prefix(setting_key + "/")
			out[int(idx)] = ProjectSettings.get_setting(name)
	return out


## ======= 会话事实(本域唯一的接缝) =======

## 把宿主侧才知道的会话事实写进载荷。两个工具共用, 故两个工具永远给出同一组值。
static func _apply_session_facts(info: Dictionary) -> void:
	var facts := _facts()
	info["mcp_running"] = facts.get("mcp_running")
	info["game_running"] = facts.get("game_running")
	info["bridge_ready"] = facts.get("bridge_ready")
	# session_active 与 game_running 同源(见 set_session_facts_provider 注释), 不由外部注入。
	info["session_active"] = facts.get("game_running")
	# 多实例身份: 只在宿主注入了才出现(旧宿主/运行时进程没有这几个键), 缺省不写 null ——
	for key in ["instance_id", "instance_role", "mcp_port", "instance_note"]:
		if facts.has(key):
			info[key] = facts.get(key)
	if not facts.is_empty():
		return
	# 漏调: 下面两条是"可见性"的全部依据, 缺任一条本域就退化成静默失效。
	info["session_facts"] = "unavailable"
	#  2) push_warning 告警一次 —— 零新依赖。已核实: push_warning 走 Logger 的 error 通道
	if not _warned_no_provider:
		_warned_no_provider = true
		push_warning("MCPProjectTools: 会话事实未注入 —— get_project_info 的 basic 段与 \
get_editor_activity 的 game_running/bridge_ready/mcp_running/session_active 恒为 null。\
宿主侧须在 _register_project_tools() 内调 set_session_facts_provider(...)")


## 现取现用一份会话事实。provider 缺失或返回非字典时返回空字典(由调用方转成 null + 告警)。
static func _facts() -> Dictionary:
	if not _session_facts_provider.is_valid():
		return {}
	var facts = _session_facts_provider.call()
	return facts if facts is Dictionary else {}


## ======= 本域辅助 =======

## 进程形态。本域只在编辑器进程注册, 故这是编译期可证的常量而非状态读取。
static func _mode() -> String:
	return "editor"


## MCP 中枢端口(默认值即机器级通用端口 9988)。
## 设置键与默认值在此**重复**一次(唯一定义处是 MCPDevServer.SETTING_HUB_PORT /
static func _mcp_port() -> int:
	return int(ProjectSettings.get_setting("dev_framework/mcp/hub_port", 9988))


## ======= 唯一的状态缝: 为什么这几个字段不自取、也不推导 =======
## 引擎层没有可替代的静态 API: EditorDebuggerPlugin.get_sessions() 必须有插件实例才能调;
## 也不能**推导**掉: 推导一个错基准恰好是闸门静默失效的经典形态(自己编一个"看起来合理"的默认,
## ======= 主文件侧接线(以及"别留同名"的坑) =======
## _input_actions / _named_layers 任一份, 切出来的就会是不该被检查的那份。故搬完必须