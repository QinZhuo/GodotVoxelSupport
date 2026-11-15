@abstract class_name Entity extends RefCounted

## 运行时实体基类 —— 也是 **ECS 桥接的重点**。

signal entity_changed()

## ECS 桥接(数据可放 ECS 列, 懒创建 —— 只有用到 ecs 时才实例化)
var _ecs: ECSLink = null
var ecs: ECSLink:
	get:
		if _ecs == null:
			_ecs = ECSLink.new(self)
		return _ecs
	set(v):
		_ecs = v


func _init(init_def: Def = null):
	if init_def:
		if "def" in self:
			set("def", init_def)


## —— ECS 实体门面(用户直接调用) ——

## 给本实体附加 ECS 数据组件(懒创建 ECS 实体)
func add_component(comp: Script, values: Dictionary = {}) -> bool:
	return ecs.add_component(comp, values)


func has_component(comp) -> bool:
	return ecs.has_component(comp)


## 读 ECS 字段
func get_field(comp, field: StringName):
	return ecs.get_field(comp, field)


## 写 ECS 字段
func set_field(comp, field: StringName, value) -> void:
	ecs.set_field(comp, field, value)


## 是否已绑定活 ECS 实体
func is_bound() -> bool:
	return ecs.is_bound()


## 销毁绑定的 ECS 实体
func destroy() -> void:
	ecs.destroy()


func _to_string():
	if "def" in self:
		return str(get("def"))
	return str(hash(self))


## —— ECS↔对象桥接: 把本实体(脚本)作为数据组件注册进 ECS ——
func register_to_ecs() -> bool:
	if ecs.world == null:
		push_warning("Entity(%s): 未设置 world, 无法注册到 ECS。" % to_string())
		return false
	return ecs.add_component(self)   # add_component 自动注册组件


## 便捷: 从实体 ECS 同步指定字段到本对象属性(组件 = 本实体脚本)。
func sync_from_ecs(field: StringName, obj_prop: StringName = field) -> void:
	ecs.sync_from(field, obj_prop)


## 便捷: 从本对象属性同步到实体 ECS 指定字段(组件 = 本实体脚本)。
func sync_to_ecs(field: StringName, obj_prop: StringName = field) -> void:
	ecs.sync_to(field, obj_prop)


func get_desc(data):
	if "def" in self:
		return get("def").get_desc(data)
	return _to_string()
