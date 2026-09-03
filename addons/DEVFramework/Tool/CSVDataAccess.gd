@tool
class_name CSVDataAccess
extends RefCounted

## Load CSV file and return dictionary (ID -> data dictionary)
static func load_csv_data(path: String) -> Dictionary[String, Dictionary]:
	var data: Dictionary[String, Dictionary] = {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		LogTool.error("表格", "无法打开CSV文件:", path)
		return data

	var header_line = file.get_csv_line()
	if header_line.size() < 2:
		LogTool.error("表格", "CSV格式无效: 缺少列标题")
		return data

	var columns: Array[String] = []
	for i in range(1, header_line.size()):
		columns.append(header_line[i])

	while !file.eof_reached():
		var row = file.get_csv_line()
		if row.is_empty() or row[0].strip_edges() == "":
			continue
		var entry: Dictionary = {}
		for i in range(columns.size()):
			if i + 1 < row.size():
				entry[columns[i]] = row[i + 1]
			else:
				entry[columns[i]] = ""
		data[row[0].strip_edges()] = entry

	file.close()
	return data


## Save dictionary to CSV file.
## 优化：先读取现有列顺序（打开写文件之前），再写入，避免截断后读取空文件
static func save_csv_data(path: String, data: Dictionary[String, Dictionary]) -> void:
	if !path.ends_with(".csv"):
		path += ".csv"

	if data.is_empty():
		LogTool.warn("表格", "没有数据可保存到CSV:", path)
		# 优化：数据为空时，只写空列头，保留文件结构
		_write_empty_csv(path)
		return

	# 优化：在打开写文件之前先读取现有列顺序
	var existing_columns := _read_columns(path)

	# 收集所有列，保持现有列顺序
	var all_columns: Array[String] = []

	# 先添加现有列（保持顺序）
	for col in existing_columns:
		if !all_columns.has(col):
			all_columns.append(col)

	# 再添加数据中的新列
	for id in data:
		var entry: Dictionary = data[id]
		for col in entry:
			if !all_columns.has(col):
				all_columns.append(col)

	# 写文件
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		LogTool.error("表格", "无法写入CSV文件:", path)
		return

	# 写列头
	var header = ["id"]
	header.append_array(all_columns)
	file.store_csv_line(header)

	# 写内容（按 ID 排序）
	var sorted_ids: Array[String] = []
	sorted_ids.assign(data.keys())
	sorted_ids.sort()

	for id in sorted_ids:
		var row: Array[String] = [id]
		var values: Dictionary = data[id]
		for col in all_columns:
			row.append(values.get(col, ""))
		file.store_csv_line(row)

	file.close()
	LogTool.log("表格", "CSV文件已保存到:", path)

## 读取 CSV 的列顺序（不含 id）
static func _read_columns(path: String) -> Array[String]:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var header_line = file.get_csv_line()
	file.close()
	if header_line.size() < 2:
		return []
	var columns: Array[String] = []
	for i in range(1, header_line.size()):
		columns.append(header_line[i])
	return columns

## 写入空的 CSV 文件（仅列头）
static func _write_empty_csv(path: String) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_csv_line(PackedStringArray(["id"]))
	file.close()

## 获取单个值
## 优化：改用 get() 而非 get_or_add()，避免误解（get_or_add 会修改临时字典但无意义）
static func get_csv_value(path: String, id: String, column: String, default: String = "") -> String:
	var data := load_csv_data(path)
	var row: Dictionary = data.get(id.strip_edges(), {})
	return row.get(column, default)

## 设置单个值（完整读写一次）
static func set_csv_value(path: String, id: String, column: String, value: String):
	var data := load_csv_data(path)
	data.get_or_add(id.strip_edges(), {})[column] = value
	save_csv_data(path, data)

## 批量更新数据（一次读写，适用于多处修改的场景）
## 用法：update_csv_data(path, func(data) { data["id"]["col"] = "val" })
static func update_csv_data(path: String, modify: Callable) -> void:
	var data := load_csv_data(path)
	modify.call(data)
	save_csv_data(path, data)

## 删除一行
static func remove_row(path: String, id: String) -> void:
	var data := load_csv_data(path)
	if data.erase(id.strip_edges()):
		save_csv_data(path, data)

## 检查 CSV 文件是否包含指定列
## 优化：复用 _read_columns 避免重复打开文件
static func has_column(path: String, column: String) -> bool:
	return _read_columns(path).has(column)

## 获取 CSV 文件的所有列名（不含 id）
static func get_columns(path: String) -> PackedStringArray:
	return PackedStringArray(_read_columns(path))

## 将 locale 映射到 CSV 中匹配度最高的列名
## 使用 Godot 内置的 TranslationServer.compare_locales 进行匹配，无需硬编码映射
static func _locale_to_column(path: String, locale: String) -> String:
	if locale.is_empty():
		return "en"

	var csv_columns := get_columns(path)
	if csv_columns.is_empty():
		return "en"

	# 用 Godot 内置的 compare_locales 找最佳匹配列
	var best := csv_columns[0]
	var best_score := 0
	for col in csv_columns:
		var score := TranslationServer.compare_locales(locale, col)
		if score > best_score:
			best_score = score
			best = col
	return best

## 确保 CSV 文件存在，不存在则创建一个空文件（仅 id 列头）
## 优化：合并文件存在性检查与创建，减少一次文件操作
static func ensure_csv_headers(path: String) -> void:
	if not path.ends_with(".csv"):
		path += ".csv"

	# 用 FileAccess.file_exists 替代 open→close 检查，更轻量
	if FileAccess.file_exists(path):
		return

	# 文件不存在 → 创建
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		LogTool.error("表格", "无法创建CSV文件:", path)
		return
	file.store_csv_line(PackedStringArray(["id"]))
	file.close()
	LogTool.log("表格", "CSV文件已创建:", path)

## 写入翻译值到 CSV（自动将 locale 映射到列名）
## 使用 Godot 内置的 compare_locales 匹配列名，无需硬编码映射表
## 如果 CSV 文件不存在，自动创建
static func set_translation_value(path: String, id: String, locale: String, value: String) -> void:
	ensure_csv_headers(path)
	var col := _locale_to_column(path, locale)
	set_csv_value(path, id, col, value)

## 重新加载 CSV 对应的翻译文件，使修改立即生效
static func apply_translation(csv_path: String, locale: String) -> void:
	# 强制触发 Godot 重导入 CSV（确保 .translation 文件是最新的）
	if ResourceLoader.exists(csv_path):
		ResourceLoader.load(csv_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	# 优先使用 TranslationTool 统一刷新
	if TranslationTool.get_current_locale() != "":
		TranslationTool.set_locale(TranslationTool.get_current_locale())
		return
	# 回退：直接加载对应 .translation 文件到 TranslationServer
	var translation_path := csv_path.get_basename() + "." + locale + ".translation"
	if ResourceLoader.exists(translation_path):
		ResourceLoader.load(translation_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		var t = load(translation_path) as Translation
		if t:
			TranslationServer.add_translation(t)
