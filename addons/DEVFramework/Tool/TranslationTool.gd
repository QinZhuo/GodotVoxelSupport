class_name TranslationTool

const TRANSLATION_DIR := "res://Assets/Translation/"

static var _active: String = ""
static var _locales: Dictionary = {}

## 初始化：扫描翻译文件 → 检测系统语言 → 加载对应翻译
static func initialize() -> void:
	if _locales.is_empty():
		_scan()
	if _locales.is_empty():
		push_error("TranslationTool: 未发现任何翻译文件")
		return
	var locale := _best_match(OS.get_locale())
	LogTool.log("翻译", "初始化: ", OS.get_locale(), " → ", locale)
	_load(locale)
	TranslationServer.set_locale(locale)

## 获取支持的语言列表（排序后的 locale 代码数组）
static func get_locales() -> Array[String]:
	var keys: Array[String] = []
	for k: String in _locales.keys():
		keys.append(k)
	keys.sort()
	return keys

## 获取当前语言
static func get_current_locale() -> String:
	return _active

## 获取语言的显示名称（使用 Godot API）
static func get_display_name(locale: String) -> String:
	var name := TranslationServer.get_locale_name(locale)
	if name.is_empty():
		name = TranslationServer.get_language_name(locale)
	return name if not name.is_empty() else locale

## 切换语言并加载翻译
static func set_locale(locale: String) -> void:
	_load(locale)
	TranslationServer.set_locale(locale)

## 加载指定语言的翻译，先卸载当前已加载的
static func _load(locale: String) -> void:
	if _active and _locales.has(_active):
		var prev: Dictionary = _locales[_active]
		for t: Translation in prev.translations:
			TranslationServer.remove_translation(t)
		prev.translations.clear()
	if not _locales.has(locale):
		_active = locale
		return
	var data: Dictionary = _locales[locale]
	for path: String in data.files:
		var t: Translation = load(path) as Translation
		if t:
			TranslationServer.add_translation(t)
			data.translations.append(t)
	_active = locale

## 扫描翻译目录，构建 locale → { files, translations } 映射
static func _scan() -> void:
	var dir := DirAccess.open(TRANSLATION_DIR)
	if not dir:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".translation"):
			var name := f.trim_suffix(".translation")
			var dot := name.find(".")
			if dot >= 0:
				var locale := name.substr(dot + 1)
				if not _locales.has(locale):
					_locales[locale] = {files = [], translations = []}
				_locales[locale].files.append(TRANSLATION_DIR + f)
		f = dir.get_next()
	dir.list_dir_end()

## 用 Godot compare_locales 找最佳匹配语言
static func _best_match(locale: String) -> String:
	var locales: Array[String] = get_locales()
	if locale.is_empty() or locales.is_empty():
		return "en"
	locale = TranslationServer.standardize_locale(locale)
	if _locales.has(locale):
		return locale
	var lang := locale.split("_")[0]
	if _locales.has(lang):
		return lang
	if lang == "zh":
		var parts := locale.split("_")
		if parts.size() > 1 and parts[1].to_lower() in ["tw", "hk", "mo"]:
			for s in locales:
				if "hant" in s.to_lower():
					return s
	var best := locales[0]
	var best_score := 0
	for s in locales:
		var score := TranslationServer.compare_locales(locale, s)
		if score > best_score:
			best_score = score
			best = s
	return best
