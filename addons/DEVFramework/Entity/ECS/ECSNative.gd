class_name ECSNative
extends RefCounted

## GDExtension 原生桥接 —— 检测 ECSCore(C++ 库)是否可用并懒加载。
## 无原生库/版本不匹配时返回 null, 由上层决定回退策略(暂未提供纯 GDScript 回退实现)。
## 所有调用走动态 ClassDB 派发, 避免编辑器启动早期静态解析崩溃。
##
## 重要: 组件脚本一律通过 resource_path + load() 实例化, 不使用全局类名 .new()。
## 原因: 新加入的 class_name 脚本在 ClassDB 注册存在时序窗口, 全局类引用实例化
## 可能报 "Nonexistent function 'new' in base 'GDScript'", 而 load(path) 稳定可靠。

static var _available: int = -1  # -1=未检测, 0=不可用, 1=可用
static var _inst: Object = null

static var _required_methods := [
	&"register_component", &"create_entity", &"is_alive", &"destroy_entity",
	&"add_component", &"has_component", &"remove_component", &"count_entities",
	&"query_rows", &"entity_of_row", &"get_field", &"set_field",
	&"get_column", &"set_column",
	&"batch_apply_where", &"batch_count",
	&"create_prefab", &"is_prefab", &"prefab_add", &"instantiate", &"prefab_get_field",
]

## 获取原生实例(懒初始化 + 自动重试)。返回 null 表示不可用。
static func get_instance() -> Object:
	if _available == 0:
		_available = -1  # 自动重试: 编辑器启动早期可能尚未加载 GDExtension
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if not ClassDB.class_exists(&"ECSCore"):
		_available = 0
		return null
	for m in _required_methods:
		if not ClassDB.class_has_method(&"ECSCore", m, false):
			_available = 0
			return null
	_inst = ClassDB.instantiate(&"ECSCore")
	_available = 1 if _inst != null else 0
	return _inst

static func is_available() -> bool:
	return get_instance() != null

## 稳定实例化脚本: 通过 resource_path 加载并 new, 规避全局类注册时序问题。
## 若脚本处于半编译状态(can_instantiate()=false), 主动 reload() 强制编译后再 new。
## 返回实例或 null。
static func instantiate_script(component_class: Script) -> Variant:
	if component_class == null:
		return null
	var path: String = component_class.resource_path
	if path == "":
		return null
	var script: Variant = load(path)
	if script == null:
		return null
	if not script.can_instantiate():
		script.reload()  # 强制编译: 修复首次加载半编译竞态
	return script.new()

## 注册组件: 反射 component_class 的 schema。
## 成功返回组件类名(StringName), 失败返回空 StringName。
static func register(component_class: Script) -> StringName:
	var inst := get_instance()
	if inst == null:
		return &""
	var probe: Variant = instantiate_script(component_class)
	if probe == null:
		return &""
	var schema: Dictionary = probe.get_schema()
	var fields: Array = schema.get("fields", [])
	var fnames := PackedStringArray()
	var ftypes := PackedInt32Array()
	var fdefaults: Array = []
	for f in fields:
		fnames.append(f.name)
		ftypes.append(f.type)
		fdefaults.append(f.default)
	var name: StringName = schema.get("name", &"")
	if name == &"":
		return &""
	var r: int = inst.call(&"register_component", name, fnames, ftypes, fdefaults)
	if r < 0:
		return &""
	return name

## 强制重新检测
static func refresh() -> void:
	_available = -1
	_inst = null
