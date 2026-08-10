class_name Entity3D extends Node3D

## 3D 节点实体 —— ECS 实体 + Node3D 场景表现。定位: **ECS ↔ Node 桥接**。
## 用法:
##   var e := Entity3D.new()
##   e.world = my_world
##   e.pos = Vector3.ZERO; e.hp = 100
##   e.register_to_ecs()
##   e.sync_from_ecs(&"pos", &"position")   # 同步指定字段: ECS pos → 节点 position
##   e.sync_to_ecs(&"position", &"pos")     # 反向
## 通用字段同步(任意 Node/对象可用): ecs.sync_from / sync_to。

## ECS 桥接(数据在 ECS 列, 懒创建)
var _ecs: ECSLink = null
var ecs: ECSLink:
	get:
		if _ecs == null:
			_ecs = ECSLink.new(self)
		return _ecs
	set(v):
		_ecs = v

## 便捷访问
var world: ECSWorld:
	get:
		return ecs.world
	set(v):
		ecs.world = v

var entity_id: int:
	get:
		return ecs.entity_id
	set(v):
		ecs.entity_id = v


func _exit_tree() -> void:
	ecs.destroy()


## 节点入树后刷新 NodeLink.node_path(路径此时有效)。仅当用过 ECS(懒加载保持)。
func _ready() -> void:
	if _ecs != null:
		_ecs.refresh_node_link()


## —— ECS 实体门面(便捷) ——

func add_component(comp, values: Dictionary = {}) -> bool:
	return ecs.add_component(comp, values)


func has_component(comp) -> bool:
	return ecs.has_component(comp)


func get_field(comp, field: StringName):
	return ecs.get_field(comp, field)


func set_field(comp, field: StringName, value) -> void:
	ecs.set_field(comp, field, value)


func is_bound() -> bool:
	return ecs.is_bound()


func destroy() -> void:
	ecs.destroy()


## —— ECS↔Node 桥接: 注册 + 便捷字段同步 ——

func register_to_ecs() -> bool:
	if ecs.world == null:
		push_warning("Entity3D(%s): 未设置 world, 无法注册到 ECS。" % name)
		return false
	return ecs.add_component(self)


## 便捷: 从实体 ECS 同步指定字段到本节点属性(组件 = 本节点脚本)。
func sync_from_ecs(field: StringName, node_prop: StringName = field) -> void:
	ecs.sync_from(field, node_prop)


## 便捷: 从本节点属性同步到实体 ECS 指定字段(组件 = 本节点脚本)。
func sync_to_ecs(field: StringName, node_prop: StringName = field) -> void:
	ecs.sync_to(field, node_prop)
