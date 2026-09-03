@tool
class_name EditorScriptMenuTool
extends RefCounted

## 在 项目→工具 下添加子菜单, 自动注册所有 Tool 目录下 extends EditorScript 的编辑器工具。
## 由 EditorPlugin 调用 register()/unregister()。菜单显示名经独立翻译模块 EditorTranslationTool
## 按编辑器语言取词(以脚本文件名为 ID, 数据在框架自带翻译目录), 未命中回退 class_name / 文件名。
## 监听编辑器语言设置变化并自动重建子菜单, 语言切换即时生效, 无需重载插件。
## 子菜单标题的翻译 key(在 FRAMEWORK_TRANSLATION_DIR 的 csv 中取词, 展示为当前编辑器语言的标题)
const SUBMENU_NAME := "EditorScript"
const SCAN_ROOT := "res://"

## 框架自带的编辑器工具多语翻译目录(csv 数据由 EditorTranslationTool 通用接口读取)
const FRAMEWORK_TRANSLATION_DIR := "res://addons/DEVFramework/Translation"

const META_MENU := "_editor_script_menu"
const META_TOOLS := "_editor_script_tools"
const META_LANG := "_editor_script_lang"
const META_TITLE := "_editor_script_title"


## 扫描并注册(由 EditorPlugin._enter_tree() 调用), 并挂起语言设置监听
static func register(plugin: EditorPlugin) -> void:
	if plugin.has_meta(META_MENU):
		return
	EditorTranslationTool.clear_cache()
	_rebuild(plugin)
	plugin.set_meta(META_LANG, EditorTranslationTool.editor_locale())
	var settings: EditorSettings = EditorTranslationTool.editor_settings()
	if settings != null and not settings.settings_changed.is_connected(_on_settings_changed.bind(plugin)):
		settings.settings_changed.connect(_on_settings_changed.bind(plugin))


## 移除子菜单并断开监听(由 EditorPlugin._exit_tree() 调用)
static func unregister(plugin: EditorPlugin) -> void:
	var settings: EditorSettings = EditorTranslationTool.editor_settings()
	if settings != null and settings.settings_changed.is_connected(_on_settings_changed.bind(plugin)):
		settings.settings_changed.disconnect(_on_settings_changed.bind(plugin))
	_teardown(plugin)


static func _rebuild(plugin: EditorPlugin) -> void:
	var tools: Array[String] = []
	_scan_tool_dirs(DirAccess.open(SCAN_ROOT), SCAN_ROOT, false, tools)
	var menu := PopupMenu.new()
	if tools.is_empty():
		LogTool.log("EditorScript", "未发现 EditorScript 编辑器工具")
	for path in tools:
		menu.add_item(_menu_label(path))
	menu.id_pressed.connect(_on_tool_pressed.bind(plugin, tools))
	var title := _menu_title()
	plugin.set_meta(META_TITLE, title)
	plugin.add_tool_submenu_item(title, menu)
	plugin.set_meta(META_MENU, menu)
	plugin.set_meta(META_TOOLS, tools)


static func _teardown(plugin: EditorPlugin) -> void:
	if not plugin.has_meta(META_MENU):
		return
	var menu: PopupMenu = plugin.get_meta(META_MENU)
	var tools: Array = plugin.get_meta(META_TOOLS)
	var title: String = plugin.get_meta(META_TITLE, SUBMENU_NAME)
	plugin.remove_tool_menu_item(title)
	if is_instance_valid(menu):
		menu.id_pressed.disconnect(_on_tool_pressed.bind(plugin, tools))
		menu.free()
	plugin.remove_meta(META_MENU)
	plugin.remove_meta(META_TOOLS)
	plugin.remove_meta(META_LANG)
	plugin.remove_meta(META_TITLE)


## 编辑器设置变化: 仅当语言真正变化时重建菜单使其即时生效
static func _on_settings_changed(plugin: EditorPlugin) -> void:
	var lang := EditorTranslationTool.editor_locale()
	if lang == plugin.get_meta(META_LANG, ""):
		return
	EditorTranslationTool.clear_cache()
	_teardown(plugin)
	_rebuild(plugin)
	plugin.set_meta(META_LANG, lang)


## 子菜单标题: 以 SUBMENU_NAME 为 key 经翻译模块取词; 未命中回退该 key
static func _menu_title() -> String:
	var t := EditorTranslationTool.editor_text(FRAMEWORK_TRANSLATION_DIR, SUBMENU_NAME)
	return t if t != "" else SUBMENU_NAME


## 菜单显示名: 以脚本文件名(ID)经独立翻译模块取词; 未命中回退 class_name / 文件名
static func _menu_label(path: String) -> String:
	var name := path.get_file().trim_suffix(".gd")
	var text := EditorTranslationTool.editor_text(FRAMEWORK_TRANSLATION_DIR, name)
	if text != "":
		return text
	var script := load(path) as Script
	if script != null:
		var gname := script.get_global_name()
		if gname != "":
			return gname
	return name


## 递归遍历目录树, 仅当 is_tool_root 为真时收集其中的 EditorScript 脚本;
## 遇到名为 Tool 的子目录则作为新的工具根(is_tool_root=true)继续下钻, 从而覆盖所有 Tool 文件夹。
static func _scan_tool_dirs(dir: DirAccess, dir_path: String, is_tool_root: bool, out: Array) -> void:
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != ".." and not entry.begins_with("."):
				_scan_tool_dirs(DirAccess.open(full), full, entry == "Tool", out)
		elif is_tool_root and entry.ends_with(".gd") and _is_editor_tool_script(full):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


static func _is_editor_tool_script(path: String) -> bool:
	var script := load(path) as Script
	if script == null:
		return false
	return script.get_instance_base_type() == &"EditorScript"


static func _on_tool_pressed(id: int, plugin: EditorPlugin, tools: Array) -> void:
	if id < 0 or id >= tools.size():
		return
	var path: String = tools[id]
	var script := load(path) as Script
	if script == null:
		printerr("EditorScript: 加载失败 ", path)
		return
	var inst := script.new() as EditorScript
	if inst == null:
		printerr("EditorScript: 无法实例化 EditorScript ", path)
		return
	LogTool.log("EditorScript", "运行: ", path)
	inst._run()
