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

	var columns = []
	for i in range(1, header_line.size()):
		columns.append(header_line[i])

	while !file.eof_reached():
		var row = file.get_csv_line()
		if row.is_empty() or row[0].strip_edges() == "":
			continue
		var entry = {}
		for i in range(columns.size()):
			if i + 1 < row.size():
				entry[columns[i]] = row[i + 1]
			else:
				entry[columns[i]] = ""
		data[row[0]] = entry

	file.close()
	return data


## Save dictionary to CSV file
static func save_csv_data(path: String, data: Dictionary[String, Dictionary]) -> void:
	if !path.ends_with(".csv"):
		path += ".csv"

	if data.is_empty():
		LogTool.warn("表格", "没有数据可保存到CSV:", path)
		return

	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		LogTool.error("表格", "无法写入CSV文件:", path)
		return

	# Try to read existing file to preserve column order
	var existing_columns: Array[String] = []
	var existing_file = FileAccess.open(path, FileAccess.READ)
	if existing_file != null:
		var header_line = existing_file.get_csv_line()
		if header_line.size() >= 2:
			for i in range(1, header_line.size()):
				existing_columns.append(header_line[i])
		existing_file.close()

	# Collect all columns, preserving existing order
	var all_columns: Array[String] = []

	# First add existing columns in their original order
	for col in existing_columns:
		if !all_columns.has(col):
			all_columns.append(col)

	# Then add any new columns from the data
	for id in data:
		var entry = data[id]
		for col in entry:
			if !all_columns.has(col):
				all_columns.append(col)

	# Write header
	var header = ["id"]
	for col in all_columns:
		header.append(col)
	file.store_csv_line(header)

	# Write content (sorted by ID)
	var sorted_ids = data.keys()
	sorted_ids.sort()

	for id in sorted_ids:
		var row = [id]
		var values = data[id]
		for col in all_columns:
			row.append(values.get(col, ""))
		file.store_csv_line(row)

	file.close()
	LogTool.log("表格", "CSV文件已保存到:", path)

static func get_csv_value(path: String, id: String, column: String, default: String = "") -> String:
	var data := load_csv_data(path)
	return data.get_or_add(id.strip_edges(), {}).get_or_add(column, default)

static func set_csv_value(path: String, id: String, column: String, value: String):
	var data := load_csv_data(path)
	data.get_or_add(id.strip_edges(), {})[column] = value
	save_csv_data(path, data)
