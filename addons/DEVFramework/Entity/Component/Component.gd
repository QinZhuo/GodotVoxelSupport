class_name Component extends Node

## 节点组件基类 —— 作为宿主节点实体(Entity2D/Entity3D)的**补充组件**。
##
## 注意区分: `Component`(本类, Node 表现补充) vs `ECSComponent`(纯数据 schema)。
##   - ECSComponent = 数据(列存储), 由 ecs.add_component 附加。
##   - Component    = Node 表现/交互补充, 挂到 Entity2D/Entity3D 下, 补充宿主的 ECS 数据。
##
## 挂到 Entity2D/Entity3D 下(或其子节点), 自动补充宿主实体的 ECS 组件/字段;
## 宿主实体在 _ready 时沿父节点链自动查找, 也可手动 host_entity 指定。
## 无宿主时纯 OOP 挂载(Node), ecs 桥接不可用(会告警一次), 零开销。

## 宿主节点实体(Entity2D/Entity3D)。_ready 自动从父节点链查找, 或手动设置。
var host_entity: Node = null

var _warned_no_host := false


func _ready() -> void:
	if host_entity == null:
		host_entity = _find_host()


func _find_host() -> Node:
	var p := get_parent()
	while p != null:
		if p is Entity2D or p is Entity3D:
			return p
		p = p.get_parent()
	return null


## 当前绑定的 ECSLink(宿主实体的); 无宿主返回 null(并告警一次)。
func _link() -> ECSLink:
	var l: ECSLink = null
	if host_entity is Entity2D:
		l = (host_entity as Entity2D).ecs
	elif host_entity is Entity3D:
		l = (host_entity as Entity3D).ecs
	if l == null and not _warned_no_host:
		_warned_no_host = true
		push_warning("Component(%s): 未找到宿主 Entity2D/Entity3D, ecs 桥接不可用。请将本组件挂到 Entity2D/Entity3D 下, 或手动设置 host_entity。" % name)
	return l


## —— ECS↔Node 桥接: 把本组件作为数据组件注册到宿主实体 ——
## 反射本组件脚本的 @export 纯数据变量作为 schema, 附加到宿主实体并写入当前值。
## 需挂到 Entity2D/Entity3D 下(宿主已存在)。
func register_to_host() -> bool:
	var l := _link()
	if l == null or l.world == null:
		return false
	return l.add_component(self)   # add_component 自动注册组件


## 便捷: 从宿主 ECS 同步指定字段到本组件属性(组件 = 本组件脚本)。
func sync_from_host(field: StringName, obj_prop: StringName = field) -> void:
	var l := _link()
	if l != null:
		l.sync_from_comp(get_script(), field, obj_prop)


## 便捷: 从本组件属性同步到宿主 ECS 指定字段(组件 = 本组件脚本)。
func sync_to_host(field: StringName, obj_prop: StringName = field) -> void:
	var l := _link()
	if l != null:
		l.sync_to_comp(get_script(), field, obj_prop)


## 给宿主实体附加 ECS 数据组件(需挂到 Entity2D/Entity3D 下)
func add_component(comp: Script, values: Dictionary = {}) -> bool:
	var l := _link()
	return l.add_component(comp, values) if l != null else false


func has_component(comp) -> bool:
	var l := _link()
	return l.has_component(comp) if l != null else false


func get_field(comp, field: StringName):
	var l := _link()
	return l.get_field(comp, field) if l != null else null


func set_field(comp, field: StringName, value) -> void:
	var l := _link()
	if l != null:
		l.set_field(comp, field, value)


func is_bound() -> bool:
	var l := _link()
	return l.is_bound() if l != null else false
