class_name Entity2D extends Node2D

## 2D 节点实体 —— ECS 实体 + Node2D 场景表现。定位: **ECS ↔ Node 桥接**。
## 用法:
##   var e := Entity2D.new()
##   e.world = my_world
##   e.hp = 100                        # 设置 @export 数据字段(ECS 数据)
##   e.register_to_ecs()               # 自动注册组件 + 附加 + 写入初值
##   e.sync_from_ecs(&"pos", &"position")   # 同步指定字段: ECS pos → 节点 position
##   e.sync_to_ecs(&"position", &"pos")     # 反向
## 数据字段规则: 当前脚本 @export / @export_storage 纯数据变量 = ECS 数据(可用 ECS_EXCLUDE 排除)。
## 通用字段同步(任意 Node/对象可用): ecs.sync_from / sync_to。

## ECS 桥接(数据在 ECS 列, 懒创建 —— 只有用到 ecs 时才实例化)
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

## 把本节点作为"数据组件"注册进 ECS: 自动注册组件 + 附加 + 写入 @export 初值。
func register_to_ecs() -> bool:
	if ecs.world == null:
		push_warning("Entity2D(%s): 未设置 world, 无法注册到 ECS。" % name)
		return false
	return ecs.add_component(self)


## 便捷: 从实体 ECS 同步指定字段到本节点属性(组件 = 本节点脚本)。
## 用法: e.sync_from_ecs(&"pos", &"position")  —— ECS 的 pos 字段 → 节点 position
func sync_from_ecs(field: StringName, node_prop: StringName = field) -> void:
	ecs.sync_from(field, node_prop)


## 便捷: 从本节点属性同步到实体 ECS 指定字段(组件 = 本节点脚本)。
## 参数同 sync_from: (ECS字段, 节点属性)。用法: e.sync_to_ecs(&"pos", &"position")  —— 节点 position → ECS 的 pos 字段
func sync_to_ecs(field: StringName, node_prop: StringName = field) -> void:
	ecs.sync_to(field, node_prop)
