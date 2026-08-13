class_name ECSNative
extends RefCounted

## ECS 原生桥接 —— 懒加载 ECSCore(C++ 库)。
## 原生库由**框架级统一入口** FrameworkNative 管理:
##   res://addons/DEVFramework/Native/devecs.gdextension
## ECS 只声明自己的必需方法集并委托加载, 不直接操作 ClassDB。
## 框架强依赖 C++ 原生库: 库缺失/版本不匹配时明确 push_error 报错(无静默回退)。
## 所有调用走动态 ClassDB 派发, 避免编辑器启动早期静态解析崩溃。
##
## 重要: 组件脚本一律通过 resource_path + load() 实例化, 不使用全局类名 .new()。
## 原因: 新加入的 class_name 脚本在 ClassDB 注册存在时序窗口, 全局类引用实例化
## 可能报 "Nonexistent function 'new' in base 'GDScript'", 而 load(path) 稳定可靠。

static var _required_methods := [
	&"register_component", &"create_entity", &"is_alive", &"destroy_entity",
	&"add_component", &"has_component", &"remove_component", &"count_entities",
	&"query_rows", &"query_rows_aligned", &"query_rows_aligned_where", &"entity_of_row", &"get_field", &"set_field",
	&"get_column", &"set_column", &"get_columns", &"set_columns", &"borrow_columns", &"return_columns", &"get_entity_components",
	&"batch_apply_where", &"batch_count", &"batch_apply_col", &"batch_clamp_where",
	&"run_systems_parallel",
	&"create_prefab", &"is_prefab", &"prefab_add", &"instantiate", &"prefab_get_field",
]

## 获取原生实例(懒加载, 委托框架级 FrameworkNative)。原生库不可用时 push_error 报错并返回 null。
static func get_instance() -> Object:
	return FrameworkNative.get_native(&"ECSCore", _required_methods)

static func is_available() -> bool:
	return get_instance() != null

## 稳定实例化脚本: 通过 resource_path 加载并 new, 规避全局类注册时序问题。
## 若脚本处于半编译状态(can_instantiate()=false), 主动 reload() 强制编译后再 new。
## 返回实例或 null。统一走框架级 FrameworkNative.instantiate_script。
static func instantiate_script(component_class: Script) -> Variant:
	return FrameworkNative.instantiate_script(component_class)

## 注册组件: 反射 component_class 的 schema(统一走 collect_schema)。
## 成功返回组件类名(StringName), 失败返回空 StringName。
static func register(component_class: Script) -> StringName:
	var inst := get_instance()
	if inst == null:
		return &""
	var probe: Variant = instantiate_script(component_class)
	if probe == null:
		return &""
	var schema: Dictionary = collect_schema(probe)
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

## 强制重新检测(清空缓存实例, 委托框架级)
static func refresh() -> void:
	FrameworkNative.refresh(&"ECSCore")


## —— 统一字段反射工具 ——
## 所有"把对象的脚本变量当作组件数据"的地方(get_schema / register_component /
## build_prefab / Entity2D.register_to_ecs)都走这里, 保证反射规则一致。
##
## 清晰规则(Entity 节点脚本):
##   ① 当前脚本直接声明的 @export 或 @export_storage 纯数据变量 = ECS 数据
##   ② 若某字段想 @export(在 Inspector 编辑)但不想进 ECS, 用 const ECS_EXCLUDE 排除
##   ③ 自动排除: 继承基类(Node2D/Entity2D)的原生/桥接属性、非 @export 的显示/内部变量

## 当前脚本直接声明的字段名(排除继承基类脚本变量): {StringName: true}
static func _own_script_field_names(instance) -> Dictionary:
	var own := {}
	var s: Script = instance.get_script()
	if s == null:
		return own
	var base: Script = s.get_base_script()
	var base_names := {}
	if base != null:
		for p in base.get_script_property_list():
			base_names[p.name] = true
	for p in s.get_script_property_list():
		if not base_names.has(p.name):
			own[p.name] = true
	return own


## 读取脚本声明的排除表 `const ECS_EXCLUDE := ["field", ...]`。
## 用于: 字段想 @export(编辑器可调)但不想作为 ECS 数据(如显示配置)。
static func _excluded_fields(instance) -> Dictionary:
	var excluded := {}
	var s: Script = instance.get_script()
	if s == null:
		return excluded
	var consts := s.get_script_constant_map()
	if consts.has("ECS_EXCLUDE"):
		for name in consts.get("ECS_EXCLUDE"):
			excluded[StringName(name)] = true
	return excluded


## 统一反射条件。
## require_export=true 时只收 @export 或 @export_storage 字段(EDITOR 或 STORAGE);
## false 收全部脚本纯变量(ECSComponent 子类)。
static func _is_data_field(p: Dictionary, require_export: bool) -> bool:
	if not (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
		return false
	if p.get("getter", "") != "" or p.get("setter", "") != "":
		return false
	if require_export and not (p.usage & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE)):
		return false
	return true


## 数据字段信息缓存: Script -> {require_export+own_only 组合 -> [{name, type}]}
## 字段集合是脚本静态的(声明/排除表/export 标记不变), 反射一次缓存, 之后只读值 ——
## 避免 Entity 批量 register_to_ecs 时每次 10000 次完整反射(get_property_list 遍历)。
static var _data_fields_cache := {}


## 返回实例脚本的纯数据字段信息 [{name, type}] (静态, 缓存; 值另取)。
static func _data_fields(instance, require_export: bool, own_only: bool) -> Array:
	var s: Script = instance.get_script()
	if s == null:
		return []
	var by_flags: Dictionary = _data_fields_cache.get(s, {})
	var key := str(require_export) + "_" + str(own_only)
	if by_flags.has(key):
		return by_flags[key]
	# 首次: 反射计算字段名+类型(own_only 过滤继承基类 + ECS_EXCLUDE + export 判定)
	var own := _own_script_field_names(instance)
	var excluded := _excluded_fields(instance)
	var infos := []
	for p in instance.get_property_list():
		if own_only and not own.has(p.name):
			continue
		if excluded.has(p.name):
			continue
		if _is_data_field(p, require_export):
			infos.append({"name": p.name, "type": p.type})
	by_flags[key] = infos
	_data_fields_cache[s] = by_flags
	return infos


## 收集实例的纯数据字段 schema: {name, fields:[{name, type, default}]}
static func collect_schema(instance, require_export: bool = false, own_only: bool = true) -> Dictionary:
	var s: Script = instance.get_script()
	var fields := []
	for f in _data_fields(instance, require_export, own_only):
		fields.append({"name": f.name, "type": f.type, "default": instance.get(f.name)})
	return {"name": s.get_global_name() if s != null else &"", "fields": fields}


## 收集实例当前各数据字段的值: {field_name: value}
static func collect_values(instance, require_export: bool = false, own_only: bool = true) -> Dictionary:
	var values := {}
	for f in _data_fields(instance, require_export, own_only):
		values[f.name] = instance.get(f.name)
	return values
