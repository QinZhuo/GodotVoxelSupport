@tool
## 教程目标定义 — 描述"当前步骤指哪个节点", 2D/3D 通用。
##
## 定位: 相对教程宿主 root 的节点路径(node_path 必须存在, 否则视为纯提示步骤)。
## 核心能力: 把 Control / Node2D / Node3D 统一换算为屏幕矩形(Rect2),
## 供遮罩挖孔、指示箭头、点击兜底共用; 挖孔尺寸 = 目标自身视觉体量 + padding 外扩。
class_name TutorialTargetDef extends Def

## 目标节点路径(相对教程宿主 root)
@export var node_path: NodePath
## 挖孔外扩像素
@export var padding: float = 0.0
## 显示指示箭头
@export var arrow := true
## 允许孔外点按(拖拽手牌/物品类步骤用: 卡牌可能超出挖孔, 需要放行孔外按下以开始拖拽)
@export var allow_outside_drag := false


## 解析目标节点(root 为教程宿主; 节点缺失返回 null)
func resolve(root: Node) -> Node:
	if root == null:
		return null
	return root.get_node_or_null(node_path)


## 统一换算目标节点为屏幕矩形(含 padding; 失败返回空 Rect2)
static func get_screen_rect(node: Node, target_def: TutorialTargetDef = null) -> Rect2:
	if node == null or not node.is_inside_tree():
		return Rect2()
	var pad := target_def.padding if target_def else 0.0
	var rect := Rect2()
	if node is Node3D:
		rect = _rect_3d(node)
	elif node is CanvasItem:
		# 2D(Control/Node2D): 合并自身与可见子级的画布矩形 —— 多目标同框 = 直接把 node_path 指向其父节点
		var rects: Array[Rect2] = []
		_collect_canvas_rects(node, rects)
		if rects.is_empty():
			var origin := (node as CanvasItem).get_global_transform_with_canvas().origin
			rect = Rect2(origin - Vector2.ONE * 0.5, Vector2.ONE)
		else:
			rect = rects[0]
			for i in range(1, rects.size()):
				rect = rect.merge(rects[i])
	if rect.size == Vector2.ZERO:
		return Rect2()
	return rect.grow(pad)


## Node3D → 屏幕矩形。统一用"可见 mesh 世界 AABB 合并投影"而非顶点投影:
## 顶点 unproject 在运行时不可靠(可能退化为点); AABB 合并跳过隐藏节点,
## 既贴合真实显示内容, 又不会因隐藏大 mesh 而偏大。
static func _rect_3d(node: Node3D) -> Rect2:
	var cam := node.get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var aabb := _visible_mesh_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = _global_aabb(node)  # 无可见网格 → 退回整体 AABB(极小/纯空目标兜底)
	if cam.is_position_behind(aabb.get_center()):
		return Rect2()
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		rect = rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	if rect.size == Vector2.ZERO:
		# 所有角投影重叠(目标极小/极远): 以中心投影点为单位矩形, 交由 padding 外扩兜底
		var c := cam.unproject_position(aabb.get_center())
		return Rect2(c - Vector2.ONE * 0.5, Vector2.ONE)
	return rect


## 汇总"真实显示中"的网格世界 AABB(合并)。收所有可见 MeshInstance3D 与 Label3D;
## 隐藏/父链隐藏节点被跳过, 使挖孔贴合实际显示内容。
static func _visible_mesh_aabb(node: Node3D) -> AABB:
	if not node.is_visible_in_tree():
		return AABB()
	var result := AABB()
	var found := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var a := (node as MeshInstance3D).global_transform * (node as MeshInstance3D).mesh.get_aabb()
		result = a
		found = true
	elif node is Label3D and (node as VisualInstance3D).get_aabb().size != Vector3.ZERO:
		var a := (node as Node3D).global_transform * (node as VisualInstance3D).get_aabb()
		result = a
		found = true
	for child in node.get_children():
		if child is Node3D:
			var a := _visible_mesh_aabb(child)
			if a.size != Vector3.ZERO:
				result = result.merge(a) if found else a
				found = true
	return result


## 汇总节点(含子级)的全局 AABB
static func _global_aabb(node: Node3D) -> AABB:
	if node is VisualInstance3D:
		return (node as VisualInstance3D).global_transform * (node as VisualInstance3D).get_aabb()
	var result := AABB()
	var found := false
	for child in node.get_children():
		if child is Node3D:
			var aabb := _global_aabb(child)
			if aabb.size == Vector3.ZERO and not found:
				continue
			result = result.merge(aabb) if found else aabb
			found = true
	if not found:
		return AABB(node.global_position, Vector3.ZERO)
	return result


## 收集 CanvasItem(含子级, 仅可见)的画布坐标矩形 — 2D 挖孔体量的来源
static func _collect_canvas_rects(item: CanvasItem, result: Array[Rect2]) -> void:
	if not item.visible:
		return
	if item is Control:
		result.append((item as Control).get_global_rect())
	elif item is Sprite2D:
		var local := (item as Sprite2D).get_rect()
		if local.size != Vector2.ZERO:
			result.append(_canvas_rect(item, local))
	for child in item.get_children():
		if child is CanvasItem:
			_collect_canvas_rects(child, result)


## 局部矩形 → 画布坐标包围矩形(Node2D 经 global_transform_with_canvas 投影)
static func _canvas_rect(item: Node2D, local_rect: Rect2) -> Rect2:
	var t := item.get_global_transform_with_canvas()
	var p1 := t * local_rect.position
	var p2 := t * (local_rect.position + local_rect.size)
	return Rect2(
		Vector2(minf(p1.x, p2.x), minf(p1.y, p2.y)),
		Vector2(absf(p2.x - p1.x), absf(p2.y - p1.y)))