class_name ECSSyncSystem
extends ECSSystem

## ECSSyncSystem —— 批量同步 ECS 位置 → Godot 节点位置。
##
## 中期方案的核心 System:
##   不再让每个 ECSNode 自己 _process 同步,
##   而是由本系统一次遍历所有"带 NodeLink 的实体", 批量搬运位置。
##
## 优势:
##   - 同步逻辑回归 ECS(一个 System 处理 N 个实体, 享受依赖排序/批量)
##   - 实体节点数量大时, 性能远优于 N 个 _process 回调
##
## 注意:
##   - 本系统处理"ECS → 节点"方向
##   - "节点 → ECS"(交互写回)由 ECSNode.sync_node_to_ecs() 或业务代码处理

## 场景根节点(查找 NodeLink.node_path 用)。
## 若未设置, 默认取当前场景根。
var scene_root: Node = null

func required_components() -> Array[Script]:
	return [NodeLink]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var w := ctx.world
	if w == null:
		return
	if scene_root == null:
		var tree := Engine.get_main_loop() as SceneTree
		scene_root = tree.current_scene if tree else null
	if scene_root == null:
		return

	# 遍历所有带 NodeLink 的实体
	var rows: PackedInt32Array = w.query_rows(NodeLink, [], [])
	if rows.is_empty():
		return

	# 零拷贝拉取 NodeLink 字段列(路径/开关/组件/字段)
	var paths: PackedStringArray = w.get_column(NodeLink, &"node_path")
	var sync_flags: PackedByteArray = w.get_column(NodeLink, &"sync_position")
	var pos_comps: PackedStringArray = w.get_column(NodeLink, &"pos_component")
	var pos_fields: PackedStringArray = w.get_column(NodeLink, &"pos_field")
	var use_xy: PackedByteArray = w.get_column(NodeLink, &"pos_use_xy")

	for e in rows:
		if not sync_flags[e]:
			continue
		var node := scene_root.get_node_or_null(paths[e])
		if node == null:
			continue
		# 读 ECS 位置(NodeLink 行号 -> 实体ID, 再跨组件访问)
		var eid := w.entity_of_row(NodeLink, e)
		if eid < 0:
			continue
		var pos: Vector2
		var comp_name: String = pos_comps[e]
		if comp_name.is_empty():
			continue
		if use_xy[e]:
			pos = Vector2(w.get_field(eid, StringName(comp_name), &"x"),
					w.get_field(eid, StringName(comp_name), &"y"))
		else:
			var v = w.get_field(eid, StringName(comp_name), StringName(pos_fields[e]))
			pos = v if v is Vector2 else (Vector2(v.x, v.y) if v is Vector3 else Vector2.ZERO)
		# 写节点位置
		if node is Node2D:
			node.position = pos
		elif node is Control:
			node.position = pos
		elif node is Node3D:
			node.position = Vector3(pos.x, pos.y, 0)
