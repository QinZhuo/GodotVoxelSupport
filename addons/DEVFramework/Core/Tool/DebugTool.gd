@tool
## Debug 工具 —— Debug 模式判定 / 调试分支信息的框架级统一入口。
class_name DebugTool extends RefCounted
## Reset: 进程级（外部注入与分支缓存）

## 调试分支名的项目设置键（支持英文逗号分隔多个分支名，未配置则视为正式分支）
const SETTING_DEBUG_BRANCH := "dev_framework/debug/branch_names"

## 外部注入的 Debug 模式判定（优先级最高；用于特殊平台 / 自定义开关）
static var _custom_checker: Callable = Callable()
## 外部注入的分支探测（优先级最高；默认走 [SteamTool.get_beta_branch_name]）
static var _branch_provider: Callable = Callable()
## 已解析到的分支名（空字符串表示正式分支或未能获取）
static var _branch: String = ""
## 分支名是否已解析成功（平台未就绪时不缓存，下次调用重新尝试）
static var _branch_resolved := false


# ============================================================

## 是否处于 Debug 模式：外部注入判定优先；默认 = 编辑器 或 调试分支
static func is_debug_mode() -> bool:
	if _custom_checker.is_valid():
		return _custom_checker.call()
	return is_editor() or is_debug_branch()


## 注入自定义 Debug 模式判定（无参 Callable 返回 bool；传空 Callable() 恢复默认判定）
static func set_debug_checker(checker: Callable) -> void:
	_custom_checker = checker


## 是否处于编辑器环境
static func is_editor() -> bool:
	return Engine.is_editor_hint() or OS.has_feature("editor")


## 是否运行在配置好的调试分支上
static func is_debug_branch() -> bool:
	var branch := get_debug_branch()
	return not branch.is_empty() and debug_branch_names().has(branch.to_lower())


## 项目设置中配置的调试分支名（小写去空格去重；多个用英文逗号分隔）
static func debug_branch_names() -> PackedStringArray:
	var raw: String = ProjectSettings.get_setting(SETTING_DEBUG_BRANCH, "")
	var names := PackedStringArray()
	for part in raw.split(",", false):
		var name_part := part.strip_edges().to_lower()
		if not name_part.is_empty() and not names.has(name_part):
			names.append(name_part)
	return names


# ============================================================

## 注入分支探测逻辑（无参 Callable 返回当前分支名，空 = 正式分支 / 未知）
static func set_branch_provider(provider: Callable) -> void:
	_branch_provider = provider
	refresh_debug_branch()


## 当前调试分支名，正式分支 / 无法获取时返回空字符串
static func get_debug_branch() -> String:
	if _branch_resolved:
		return _branch
	# 探测来源不可用时不缓存，下次调用重新尝试
	if not _branch_source_ready():
		return ""
	_branch = _query_branch().strip_edges()
	_branch_resolved = true
	return _branch


## 丢弃已缓存的分支名，下次重新查询
static func refresh_debug_branch() -> void:
	_branch = ""
	_branch_resolved = false


## 探测来源是否就绪：自定义探测视为始终可用；内置探测要求 Steam 可用
static func _branch_source_ready() -> bool:
	return _branch_provider.is_valid() or SteamTool.is_available()


## 组装探测结果：自定义探测优先，否则回退到 SteamTool 的内置探测
static func _query_branch() -> String:
	if _branch_provider.is_valid():
		return str(_branch_provider.call())
	return SteamTool.get_beta_branch_name()
