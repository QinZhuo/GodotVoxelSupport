class_name ECSLink extends RefCounted

## ECS 桥接对象 —— 让普通对象(Node/RefCounted)把数据放进 ECS。
##
## 隐式启用: 调用 add_component/get_field/set_field 等时自动创建并绑定一个 ECS 实体,
## 无需任何布尔开关。不使用 ecs.* API 则保持纯 OOP, 零开销。
## 数据单一源 = ECS 列; 持有方(Node 组件 / 实体对象)只做门面。
##
## 用法(在 Entity / Component 内建, 子类直接用):
##   ecs.world = my_world                       # 绑定世界(由使用方设置)
##   ecs.add_component(ECSAttribute, {"atk": 10})   # 数据进 ECS 列
##   ecs.set_field(ECSAttribute, &"atk", 20)    # 读写 ECS
##   ecs.destroy()                              # 销毁实体

var world: ECSWorld
var entity_id: int = -1

## 持有者(Entity2D/Entity/Component/Node 等)。sync 系列默认以持有者为目标对象,
## 组件 = 持有者脚本(自身组件); 也可用 sync_*_comp 显式指定组件。
var owner: Object = null


func _init(new_owner: Object = null) -> void:
	owner = new_owner


## 懒创建 ECS 实体(首次使用时绑定), 返回实体 ID。
## owner 是节点(Entity2D/3D)时, 自动附加 NodeLink(实体↔节点关联, 供 ECSSyncSystem 同步)。
func ensure_entity() -> int:
	if entity_id < 0 and world != null:
		entity_id = world.create_entity()
		_auto_node_link()
	return entity_id


## owner 是节点时自动挂 NodeLink(无需手动 attach_node_link)。
## node_path 在节点入树后有效, 由持有方 _ready 调 refresh_node_link() 刷新。
func _auto_node_link() -> void:
	if owner == null or not (owner is Node) or world == null or entity_id < 0:
		return
	world.add_component(entity_id, NodeLink)
	refresh_node_link()


## 刷新 NodeLink.node_path(节点入树后路径有效)。持有方在 _ready 调用。
## 若实体尚无 NodeLink(如手动设 entity_id 的场景), 这里确保挂载。
## 节点未入树时跳过(路径无效), 入树后由持有方 _ready 再次调用。
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
## comp 支持 Script/类名, 或**实例(一参数模式)** —— 传组件实例/节点实例时自动反射其 @export 字段为初值。
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
## 目标对象 = owner(持有者), 组件 = owner 的脚本(自身组件)。用于单实体/低频。

## ECS → 持有者: 把持有者脚本组件 field 字段同步到持有者 obj_prop 属性。
## 用法: ecs.sync_from(&"pos", &"position")
func sync_from(field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	owner.set(obj_prop, get_field(owner.get_script(), field))


## 持有者 → ECS: 把持有者 obj_prop 属性同步到持有者脚本组件 field 字段。
## 用法: ecs.sync_to(&"position", &"pos")
func sync_to(field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	set_field(owner.get_script(), field, owner.get(obj_prop))


## 显式指定组件的版本(组件非持有者自身脚本时, 如 Entity 挂外部组件)。
## 用法: ecs.sync_from_comp(ECSDemoMoveComponent, &"pos", &"position")
func sync_from_comp(comp, field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	owner.set(obj_prop, get_field(comp, field))


func sync_to_comp(comp, field: StringName, obj_prop: StringName = field) -> void:
	if owner == null:
		return
	set_field(comp, field, owner.get(obj_prop))
