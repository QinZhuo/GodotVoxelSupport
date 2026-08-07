@tool
## Def 静态数据基类
##
## Def 只应包含通过 @export 定义的静态配置数据，
## 不得存储任何运行时缓存或状态信息。
## 运行时状态由外部上下文持有，Def 仅提供对上下文的读写约定。
@abstract class_name Def extends Resource

var name: String:
	get():
		if is_built_in():
			resource_name = get_script().get_global_name()
		else:
			resource_name = resource_path.get_file().get_basename()
		return resource_name
	set(value):
		resource_name = value

func _to_string() -> String:
	if is_built_in():
		return get_script().get_global_name()
	else:
		return tr(name).strip_edges()

func get_desc(_data) -> String:
	return _to_string()

static func get_def_desc(def: Def, data):
	return def.get_desc(data) if def else ""

func _get_zh(key: String) -> String:
	if Engine.is_editor_hint() and not is_built_in():
		return CSVDataAccess.get_csv_value(get_csv_path(), key, "zh", key)
	else:
		return name

func _set_zh(key: String, value: String):
	if Engine.is_editor_hint() and not is_built_in():
		CSVDataAccess.set_csv_value(get_csv_path(), key, "zh", value)

func get_csv_path() -> String:
	var csv_name: String = get_script().get_global_name()
	csv_name = csv_name.trim_suffix("Def").to_snake_case()
	return "res://Assets/Translation/{0}.csv".format([csv_name])

func get_root_def() -> Def:
	if is_built_in():
		return load(resource_path.substr(0, resource_path.find('::')))
	return self

const DEFS_BASE := "res://Assets/Def/"

## 保存时返回相对于 DEFS_BASE 的短路径，减小存档体积
func save_data():
	return resource_path.trim_prefix(DEFS_BASE)

## 从存档数据中加载 Def（兼容旧存档的完整路径格式）
## 文件不存在时返回 null 并输出日志
static func load_data(path: String) -> Def:
	var full_path: String
	if path.begins_with("res://"):
		full_path = path
	else:
		full_path = DEFS_BASE + path
	if ResourceLoader.exists(full_path):
		return load(full_path)
	LogTool.warn("存档", "Def 文件不存在: %s (来源路径: %s)" % [full_path, path])
	return null

func _validate_property(property: Dictionary) -> void:
	if "_init_def" in self:
		call("_init_def")
	if property.name.begins_with("zh_"):
		property.usage = PROPERTY_USAGE_EDITOR ## 中文信息不存储
	elif property.name.begins_with("tr_"):
		property.usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY ## 翻译变量只读且不储存
