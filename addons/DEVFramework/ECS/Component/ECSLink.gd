class_name ECSLink extends RefCounted

## ECS 桥接对象 —— 让普通对象(Node/RefCounted)把数据放进 ECS。

var world: ECSWorld
var entity_id: int = -1

## 持有者(Entity2D/Entity3D/Entity 等)。sync 系列默认以持有者为目标对象,
var owner: Object = null


func _init(new_owner: Object = null) -> void:
	owner = new_owner


## 懒创建 ECS 实体(首次使用时绑定), 返回实体 ID。
func ensure_entity() -> int:
	if entity_id < 0 and world != null:
		entity_id = world.create_entity()
		_auto_node_link()
	return entity_id


## owner 是节点时自动挂 NodeLink(无需手动 attach_node_link)。
func _auto_node_link() -> void:
	if owner == null or not (owner is Node) or world == null or entity_id < 0:
		return
	world.add_component(entity_id, NodeLink)
	refresh_node_link()


## 刷新 NodeLink.node_path(节点入树后路径有效)。持有方在 _ready 调用。
func refresh_node_link() -> void:
	if owner == null or not (owner is Node) or world == null or entity_id < 0:
		return
	var node := owner as Node
	if not node.is_inside_tree():
		return
	world.add_component(entity_id, NodeLink)
	if world.has_component(entity_id, NodeLink):
		world.set_field(entity_id, NodeLink, &"node_path", str(node.get_path()))


## 是否已绑定一个活实体。
func is_bound() -> bool:
	return entity_id >= 0 and world != null and world.is_alive(entity_id)


## 给实体附加 ECS 数据组件(数据只在 ECS 列)。
func add_component(comp, values: Dictionary = {}) -> bool:
	if world == null:
		push_warning("ECSLink: 未设置 world, 无法附加组件。请先 ecs.world = ...")
		return false
	return world.add_component(ensure_entity(), comp, values)


func has_component(comp) -> bool:
	return entity_id >= 0 and world != null and world.has_component(entity_id, comp)


## 读 ECS 字段(实体不存在返回 null, 不创建)。
func get_field(comp, field: StringName):
	if entity_id < 0:
		return null
	return world.get_field(entity_id, comp, field)


## 写 ECS 字段(懒创建: 使用到时才创建实体, 并自动附加该组件)。
func set_field(comp, field: StringName, value) -> void:
	if world == null:
		push_warning("ECSLink: 未设置 world, 无法写入字段。请先 ecs.world = ...")
		return
	var e := ensure_entity()
	if not world.has_component(e, comp):
		world.add_component(e, comp)
	world.set_field(e, comp, field, value)


## 销毁绑定的 ECS 实体(生命周期清理)。
func destroy() -> void:
	if entity_id >= 0 and world != null and world.is_alive(entity_id):
		world.destroy_entity(entity_id)
	entity_id = -1


## —— 通用字段同步(ECS ↔ 持有者, 只传两个字符串) ——

## ECS → 持有者: 把持有者脚本组件 field 字段同步到持有者 obj_prop 属性。
func sync_from(field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	owner.set(obj_prop, get_field(owner.get_script(), field))


## 持有者 → ECS: 把持有者 obj_prop 属性同步到持有者脚本组件 field 字段。
func sync_to(field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	set_field(owner.get_script(), field, owner.get(obj_prop))


## 显式指定组件的版本(组件非持有者自身脚本时, 如 Entity 挂外部组件)。
func sync_from_comp(comp, field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	owner.set(obj_prop, get_field(comp, field))


func sync_to_comp(comp, field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	set_field(comp, field, owner.get(obj_prop))
