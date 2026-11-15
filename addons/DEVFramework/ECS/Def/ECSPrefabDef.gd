@tool
class_name ECSPrefabDef
extends Def

## ECSPrefabDef —— ECS 实体预制体配置(继承 Def, 与框架配置体系统一)。

## 组件实例数组: 每个实例的 @export 字段 = 该组件的初始值。
@export var component_instances: Array[ECSComponent] = []

## 便捷: 校验配置是否合法(至少一个组件实例)
func is_valid() -> bool:
	for inst in component_instances:
		if inst == null:
			return false
	return not component_instances.is_empty()

## 便捷: 获取组件类名列表(供调试/日志)
func component_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for inst in component_instances:
		if inst != null:
			names.append(inst.get_script().get_global_name())
	return names

## 描述: 显示组件构成
func get_desc(_data) -> String:
	var parts: Array[String] = []
	for inst in component_instances:
		if inst != null:
			parts.append(inst.get_script().get_global_name())
	return "%s: %s" % [name, " + ".join(parts)] if not parts.is_empty() else name
