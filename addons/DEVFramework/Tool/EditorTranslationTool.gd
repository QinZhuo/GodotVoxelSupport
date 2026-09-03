@tool
class_name EditorTranslationTool
extends RefCounted

## 独立模块: 编辑器翻译。
## 从任意目录 CSV 按"编辑器语言"直接取词(不经 TranslationServer), 供编辑器 UI(如工具菜单)
## 等只读场景统一使用; 与运行时翻译 TranslationTool(.translation + TranslationServer) 职责分离。

## 缓存: csv_dir -> {id: {locale: text}}
static var _csv_cache: Dictionary = {}


## 获取 EditorSettings 单例(编辑器进程才可用); 官方方式为 EditorInterface.get_editor_settings()
static func editor_settings() -> EditorSettings:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_settings()


## 当前编辑器语言: 编辑器语言设置非空且非 auto(跟随系统)时用之, 否则回退系统语言
static func editor_locale() -> String:
	var settings := editor_settings()
	if settings != null and settings.has_setting("interface/editor/editor_language"):
		var l := String(settings.get_setting("interface/editor/editor_language")).strip_edges()
		if not l.is_empty() and l.to_lower() not in ["auto", "_auto"]:
			return l
	return OS.get_locale()


## 清空 csv 缓存(语言/数据变化后调用, 强制重新读取)
static func clear_cache() -> void:
	_csv_cache.clear()


## 便捷取词: 取 id 在当前编辑器语言下的文本; 找不到返回空
static func editor_text(csv_dir: String, id: String) -> String:
	return editor_text_for(csv_dir, id, editor_locale())


## 从指定 csv_dir 目录的所有 csv(合并)中, 取 id 在指定 locale 下的文本; 找不到返回空字符串
static func editor_text_for(csv_dir: String, id: String, locale: String) -> String:
	if csv_dir.is_empty() or id.is_empty() or locale.is_empty():
		return ""
	var rows: Dictionary = _csv_entries(csv_dir)
	var row: Dictionary = rows.get(id, {})
	if row.is_empty():
		return ""
	var col := _locale_to_column(row.keys(), locale)
	if col == "":
		return ""
	return str(row.get(col, ""))


static func _csv_entries(csv_dir: String) -> Dictionary:
	if _csv_cache.has(csv_dir):
		return _csv_cache[csv_dir]
	var merged: Dictionary = {}
	var dir := DirAccess.open(csv_dir)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.ends_with(".csv"):
				var data: Dictionary = CSVDataAccess.load_csv_data(csv_dir.path_join(f))
				for id: String in data:
					var row: Dictionary = data[id]
					if not merged.has(id):
						merged[id] = {}
					merged[id].merge(row)
			f = dir.get_next()
		dir.list_dir_end()
	_csv_cache[csv_dir] = merged
	return merged


## 用 Godot 内置 compare_locales 找与目标语言最匹配的列
static func _locale_to_column(columns: Variant, locale: String) -> String:
	var best := ""
	var best_score := 0
	for c in columns:
		var col := str(c)
		var score := TranslationServer.compare_locales(locale, col)
		if score > best_score:
			best_score = score
			best = col
	return best
