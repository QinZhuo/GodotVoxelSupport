@tool
class_name ECSPrefabDef
extends Def

## ECSPrefabDef —— ECS 实体预制体配置(继承 Def, 与框架配置体系统一)。
##
## 采用"组件实例数组"方案: 每个元素是一个 ECSComponent 实例,
## 实例的 @export 字段就是配置值 —— 在 Inspector 里可视化编辑,
## 字段名/类型由 Godot 的 @export 系统保证, 不会手写出错。
##
## 继承 Def 获得: name 自动派生、翻译(zh_*)、存档短路径、get_desc,
## 与其他 Def(AttributeDef/BuffDef/GoapActionDef)完全同一体系。
##
## 用法:
##   1. 创建 .tres 资源(放在 res://Assets/Def/ECS/ 下), 在 Inspector 里
##      向 component_instances 添加组件实例(如 HealthComponent), 直接填字段值
##   2. 代码生成实体:
##   var def = load("res://Assets/Def/ECS/Soldier.tres")
##   var prefab = world.build_prefab(def)          # 配置 → prefab 模板实体
##   var units = world.instantiate(prefab, 100)    # 批量生成 100 个
##
##   也可一行完成: world.spawn_from_def(def, 100)

## 组件实例数组: 每个实例的 @export 字段 = 该组件的初始值。
## Inspector 中可视化编辑, 类型安全, 字段名不会拼错。
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
