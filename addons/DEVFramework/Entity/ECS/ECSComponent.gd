class_name ECSComponent
extends Resource

## ECS 组件基类 —— 纯数据 schema 声明。
##
## 继承 Resource(而非 RefCounted): 组件实例可作为子资源存进 .tres / Inspector 可视化编辑,
## 支持 @export 字段(int/float/bool/Vector2/Vector3/Color/String)。
## 实例仅用于"描述结构"或"Prefab 配置", 运行时数据实际存储在 C++ SoA 列中。
##
## class_name HealthComponent extends ECSComponent:
##     @export var max_hp: int = 100
##     @export var hp: int = 100
##
## 运行时通过 ECSWorld.add_component(entity, HealthComponent) 附加,
## 数据访问用 world.get_field / world.get_column 等。

## 收集本组件 schema 信息(通过实例反射 @export 字段)。
## 由 ECSNative.register 调用; 不在此处反射, 因为静态函数无法构造子类实例。
func get_schema() -> Dictionary:
	var fields := []
	for p in get_property_list():
		# 只收集脚本变量(排除 Object 内建属性)
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			fields.append({
				"name": p.name,
				"type": p.type,
				"default": get(p.name),
			})
	return {
		"name": get_script().get_global_name(),
		"fields": fields,
	}
