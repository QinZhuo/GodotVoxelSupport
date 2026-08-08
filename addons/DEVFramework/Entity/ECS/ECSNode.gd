class_name ECSNode
extends Node

## ECSNode —— ECS 实体与 Godot 场景节点的高层便利封装。
##
## 架构定位(三层中的"关键实体"层):
##   - 海量实体(10万+): 渲染直读, 不建 Node(ECSPerfLab 点阵)
##   - 关键实体(玩家/NPC/Boss): ECSNode 桥接 ← 本类
##
## 本类内部基于 NodeLink 组件:
##   - 自动给实体挂 NodeLink(记录 node_path, 可序列化)
##   - 位置同步默认交给 ECSSyncSystem(批量), 也可手动/每帧
##   - 提供 get/set_field 便捷 API 供 Godot 逻辑读写 ECS
##
## 用法:
##   var view = ECSNode.spawn(world, player_scene, Vector2(100, 200))
##   view.add_component(HealthComponent)
##   view.bind_pos(ECSDemoMoveComponent, &"pos")
##   view.get_field(HealthComponent, &"hp")
##   view.destroy()
##
## 注意: 使用 ECSSyncSystem 时需先 register_system(ECSSyncSystem.new())

## 绑定的 ECS 世界
var world: ECSWorld

## 对应的 ECS 实体 ID
var entity_id: int = -1

## 表现节点(场景实例)
var node: Node

## 位置组件脚本引用(运行时)
var _pos_comp: Script = null
var _pos_field: StringName = &"pos"
var _pos_use_xy: bool = false
var _x_field: StringName = &"x"
var _y_field: StringName = &"y"

## 同步模式: auto=交给 ECSSyncSystem(推荐, 批量); manual=本节点 _process 自同步
var sync_mode: int = SYNC_AUTO
const SYNC_AUTO: int = 0
const SYNC_MANUAL: int = 1

var _active := true


## 静态工厂: 创建 ECS 实体 + NodeLink + 表现节点。
## world: ECS 世界; scene: PackedScene 或 Node;
## pos: 初始世界坐标(可选); parent: 挂载父节点(默认当前场景根)
static func spawn(world: ECSWorld, scene, pos: Vector2 = Vector2.ZERO, parent: Node = null) -> ECSNode:
	var view := ECSNode.new()
	view.world = world
	view.entity_id = world.create_entity()
	# 实例化表现节点
	if scene is PackedScene:
		view.node = scene.instantiate()
	elif scene is Node:
		view.node = scene
	else:
		view.node = Node2D.new()
	if view.node is Node2D:
		view.node.position = pos
	elif view.node is Node3D:
		view.node.position = Vector3(pos.x, pos.y, 0)
	# 挂载节点
	var p := parent
	if p == null:
		p = _find_parent()
	if p != null and view.node != null and not view.node.is_inside_tree():
		p.add_child(view.node)
	# 自动挂 NodeLink(记录节点路径, 可序列化)
	view._attach_node_link()
	return view


static func _find_parent() -> Node:
	var scene := Engine.get_main_loop() as SceneTree
	if scene and scene.current_scene:
		return scene.current_scene
	return null


## 给实体挂 NodeLink 组件(记录当前节点路径)
func _attach_node_link() -> void:
	if world == null or entity_id < 0 or node == null:
		return
	world.register_component(NodeLink)
	if world.add_component(entity_id, NodeLink):
		world.set_field(entity_id, NodeLink, &"node_path", node.get_path().get_concatenated_names())
		world.set_field(entity_id, NodeLink, &"pos_component", _pos_comp.get_global_name() if _pos_comp else "")
		world.set_field(entity_id, NodeLink, &"pos_field", str(_pos_field))
		world.set_field(entity_id, NodeLink, &"pos_use_xy", _pos_use_xy)


## 给实体附加组件(便捷封装)
func add_component(component, def_data: Dictionary = {}) -> bool:
	if world == null:
		return false
	return world.add_component(entity_id, component, def_data)


func has_component(component) -> bool:
	return world != null and world.has_component(entity_id, component)


func get_field(component, field: StringName):
	return world.get_field(entity_id, component, field) if world else null


func set_field(component, field: StringName, value) -> void:
	if world:
		world.set_field(entity_id, component, field, value)


## 配置位置组件映射(写入 NodeLink 供 SyncSystem 用)
func bind_pos(component: Script, field: StringName = &"pos") -> void:
	_pos_comp = component
	_pos_field = field
	_pos_use_xy = false
	_sync_node_link_config()


## 配置位置组件映射: 两个 float 字段
func bind_pos_xy(component: Script, x_field: StringName = &"x", y_field: StringName = &"y") -> void:
	_pos_comp = component
	_pos_use_xy = true
	_x_field = x_field
	_y_field = y_field
	_sync_node_link_config()


func _sync_node_link_config() -> void:
	if world == null or entity_id < 0:
		return
	if _pos_comp == null:
		return
	# _pos_comp 本身就是 Script, 直接取全局名
	world.set_field(entity_id, NodeLink, &"pos_component", _pos_comp.get_global_name())
	world.set_field(entity_id, NodeLink, &"pos_field", str(_pos_field))
	world.set_field(entity_id, NodeLink, &"pos_use_xy", _pos_use_xy)


## 手动同步一次 ECS → 节点(手动模式或即时刷新用)
func sync_ecs_to_node() -> void:
	if _pos_comp == null or node == null or world == null:
		return
	var p := _ecs_pos2()
	if node is Node2D:
		node.position = p
	elif node is Control:
		node.position = p
	elif node is Node3D:
		node.position = Vector3(p.x, p.y, 0)


## 手动同步一次 节点 → ECS(交互写回)
func sync_node_to_ecs() -> void:
	if _pos_comp == null or node == null or world == null:
		return
	if _pos_use_xy:
		if node is Node2D or node is Control:
			world.set_field(entity_id, _pos_comp, _x_field, node.position.x)
			world.set_field(entity_id, _pos_comp, _y_field, node.position.y)
		elif node is Node3D:
			world.set_field(entity_id, _pos_comp, _x_field, node.position.x)
			world.set_field(entity_id, _pos_comp, _y_field, node.position.z)
	else:
		var p: Vector2
		if node is Node2D or node is Control:
			p = node.position
		elif node is Node3D:
			p = Vector2(node.position.x, node.position.z)
		world.set_field(entity_id, _pos_comp, _pos_field, p)


func _ecs_pos2() -> Vector2:
	if _pos_use_xy:
		return Vector2(world.get_field(entity_id, _pos_comp, _x_field),
				world.get_field(entity_id, _pos_comp, _y_field))
	var v = world.get_field(entity_id, _pos_comp, _pos_field)
	if v is Vector2:
		return v
	if v is Vector3:
		return Vector2(v.x, v.y)
	return Vector2.ZERO


func _process(_delta: float) -> void:
	# 手动模式才自同步(默认交给 ECSSyncSystem 批量)
	if sync_mode == SYNC_MANUAL and _active:
		sync_ecs_to_node()


## 停用(不销毁)
func set_active(v: bool) -> void:
	_active = v
	set_process(v)


## 销毁: 移除 ECS 实体 + 释放表现节点
func destroy() -> void:
	_active = false
	if world != null and entity_id >= 0 and world.is_alive(entity_id):
		world.destroy_entity(entity_id)
	entity_id = -1
	if node != null and is_instance_valid(node):
		node.queue_free()
		node = null


func _exit_tree() -> void:
	_active = false
