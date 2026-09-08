@tool
## 更新日志工具 —— 只提供版本判定 / 条目过滤 / 已见版本记录，不包含任何 UI。
##
## 已见版本**不单独存储文件**，由项目并入自己的游戏存档统一持久化：
## [codeblock]
## # 读档（游戏启动加载存档后、判断更新前）
## ChangelogTool.load_seen_version(save_data.get("changelog_version", ""))
## if ChangelogTool.has_update():
##     var entries := ChangelogTool.get_pending_entries()  # 待展示条目
##     changelog_popup.show_entries(entries)               # 项目自建弹窗
##     ChangelogTool.mark_seen()                           # 展示后记录已见版本
## # 存档时
## save_data["changelog_version"] = ChangelogTool.get_seen_version()
## [/codeblock]
## 若项目不把已见版本并入存档，状态仅存内存：重启后视为首次运行（不弹窗）。
class_name ChangelogTool

## 当前版本号：Godot 内置项目设置（项目设置 → Application → Config → Version）
const SETTING_VERSION := "application/config/version"

## 更新日志 Def 扫描目录（对齐 Def.DEFS_BASE）
const DEFS_DIR := "res://Assets/Def/"

## 玩家上次已见版本（首次运行 / 未并入存档时为空 ""）
static var _seen_version := ""


# ============================================================
# 查询
# ============================================================

## 当前项目版本：读内置项目设置；未配置时回退到日志 Def 中的最高版本；都为空返回 ""
static func get_current_version() -> String:
	var v: String = ProjectSettings.get_setting(SETTING_VERSION, "")
	if not v.is_empty():
		return v
	return get_max_def_version()

## 玩家上次已见版本
static func get_seen_version() -> String:
	return _seen_version

## 是否存在玩家可见的新版本更新（当前 > 已见，且有可展示条目）
static func has_update() -> bool:
	if not SaveTool.is_version_newer(get_current_version(), get_seen_version()):
		return false
	return not get_pending_entries().is_empty()

## 待展示条目：seen < v <= current、player_visible；按版本从新到旧排序
static func get_pending_entries() -> Array[ChangelogEntryDef]:
	var cur := get_current_version()
	var seen := get_seen_version()
	if cur.is_empty() or not SaveTool.is_version_newer(cur, seen):
		return []
	var result: Array[ChangelogEntryDef] = []
	for entry in _collect_entries():
		if not entry or not entry.player_visible:
			continue
		if entry.version.is_empty():
			continue
		if not SaveTool.is_version_newer(entry.version, seen):
			continue
		if SaveTool.is_version_newer(entry.version, cur):
			continue
		result.append(entry)
	result.sort_custom(func(a, b): return SaveTool.is_version_newer(a.version, b.version))
	return result


# ============================================================
# 状态记录（内存态，由项目并入存档持久化）
# ============================================================

## 记录已展示到的版本（默认记录当前版本；可传 version 覆盖，便于模拟旧已见版本）
static func mark_seen(version := "") -> void:
	var v := version if not version.is_empty() else get_current_version()
	if not v.is_empty():
		_seen_version = v

## 重置已见版本（便于测试 / 重置玩家记录）
## 注意：不要命名为 reset_state —— Resource 基类已有同名核心方法，类级静态调用会被其抢占。
static func reset_seen_version() -> void:
	_seen_version = ""

## 从存档恢复已见版本（先于 [method has_update] 调用）
static func load_seen_version(seen: Variant) -> void:
	_seen_version = str(seen) if seen is String or seen is int or seen is float else ""


# ============================================================
# 内部
# ============================================================

## 收集全部日志 Def 的条目（按 Def 内声明顺序）
static func _collect_entries() -> Array[ChangelogEntryDef]:
	var result: Array[ChangelogEntryDef] = []
	for def in _load_defs():
		result.append_array(def.entries)
	return result

static func _load_defs() -> Array[ChangelogDef]:
	var result: Array[ChangelogDef] = []
	var defs: Array[Def] = SaveTool.load_defs(DEFS_DIR, func(res): return res is ChangelogDef)
	for def in defs:
		result.append(def)
	return result

## 所有日志 Def 中的最高版本号（项目设置未配置时的回退）
static func get_max_def_version() -> String:
	var max_v := ""
	for def in _load_defs():
		var v := def.get_max_version()
		if not v.is_empty() and (max_v.is_empty() or SaveTool.is_version_newer(v, max_v)):
			max_v = v
	return max_v