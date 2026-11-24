@tool
## 焦点几何 — 把节点(Node2D / Control / 3D 体 / 子视口里的东西)换算成主视口屏幕矩形.
##
## 契约:
##   · 全部 static, 不持有节点引用、不登记任何状态, @tool 编辑器里也能直接调.
##   · 换算不出来就返回空 Rect2 / 零 AABB, 由调用方决定兜底, 这里不报错、不 push_warning.
##   · 依赖实例状态的部分(SubView3D 面板兜底 _promoted、命中区合并 _hit_rects、视口尺寸)
##     留在 FocusMask —— 那是状态不是几何, 搬进来就得跟着状态布局走.
class_name FocusRectTool extends RefCounted


## 目标自己的圆角(取样式盒四角最大值; 不是 StyleBoxFlat 就是 0 = 用全局默认)
static func _corner_radius_of(node: Node) -> float:
	var control := node as Control
	if control == null:
		return 0.0
	var box := _style_box_of(control)
	if box is StyleBoxFlat:
		var flat := box as StyleBoxFlat
		return float(maxi(maxi(flat.corner_radius_top_left, flat.corner_radius_top_right),
				maxi(flat.corner_radius_bottom_left, flat.corner_radius_bottom_right)))
	return 0.0


## 取控件"实际生效"的样式盒(用来还原它的形状)
static func _style_box_of(control: Control) -> StyleBox:
	if control is Button:
		var btn := control as Button
		for name in ["normal", "pressed", "hover"]:
			var box := btn.get_theme_stylebox(name)
			if box:
				return box
	elif control is Panel:
		var panel_box := (control as Panel).get_theme_stylebox("panel")
		if panel_box:
			return panel_box
	var fallback := control.get_theme_stylebox("panel")
	return fallback


## 本视口尺寸算不出来时(headless/未排版)的设计分辨率兜底
static func _design_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 648)))


# ------------------------------------------------------------
# 目标 → 屏幕矩形(2D 控件 / Node2D 精灵 / 3D 模型 / 子视口贴面通用)
# ------------------------------------------------------------

## 节点在屏幕上的可见矩形(失败返回空 Rect2)
static func screen_rect(node: Node) -> Rect2:
	if node == null or not node.is_inside_tree():
		return Rect2()
	var rect := Rect2()
	if node is Node3D:
		rect = _rect_3d(node as Node3D)
	elif node is CanvasItem:
		rect = _rect_2d(node as CanvasItem)
	if rect.size == Vector2.ZERO:
		return Rect2()
	# UI 或 3D 画在子视口里(贴图面渲染到 3D 屏幕等)时, 换回主视口坐标
	return _sub_view_screen_rect(node.get_viewport(), rect)


## CanvasItem → 画布矩形: 合并自身与可见子级(父节点可作为"多目标同框"的目标)
static func _rect_2d(item: CanvasItem) -> Rect2:
	var rects: Array[Rect2] = []
	_collect_canvas_rects(item, rects)
	if rects.is_empty():
		var origin := item.get_global_transform_with_canvas().origin
		return Rect2(origin - Vector2.ONE * 0.5, Vector2.ONE)
	var rect := rects[0]
	for i in range(1, rects.size()):
		rect = rect.merge(rects[i])
	return rect


## 子视口内的矩形 → 屏幕矩形。
## 逐层往上映射: 子视口 → 承载它的 SubView3D → 该面板所在视口 → … → 主视口。
## (嵌套子视口只映射一层会得到"外层视口坐标"而不是屏幕坐标, 高亮就会跑到左上角)
static func _sub_view_screen_rect(viewport: Viewport, rect: Rect2) -> Rect2:
	var current := rect
	var vp: Viewport = viewport
	var guard := 0
	while vp is SubViewport and guard < 8:
		var panel := _find_panel(vp)
		if panel == null:
			break
		current = panel.viewport_rect_to_screen(current)
		vp = panel.get_viewport()
		guard += 1
	return current


## 找到承载某个子视口的 SubView3D(沿祖先链)
static func _find_panel(viewport: Viewport) -> SubView3D:
	var node := viewport.get_parent()
	while node:
		if node is SubView3D and (node as SubView3D).viewport == viewport:
			return node as SubView3D
		node = node.get_parent()
	return null


## Node3D → 屏幕矩形。统一用"可见 mesh 世界 AABB 合并投影"而非顶点投影
static func _rect_3d(node: Node3D) -> Rect2:
	var cam := node.get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var aabb := _visible_mesh_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = _global_aabb(node)  # 无可见网格 → 退回整体 AABB
	if aabb.size == Vector3.ZERO:
		aabb = _collision_aabb(node)  # 只有碰撞盒的交互体(Area3D 之类): 用碰撞形状估矩形
	if cam.is_position_behind(aabb.get_center()):
		return Rect2()
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		rect = rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	if rect.size == Vector2.ZERO:
		# 所有角投影重叠(目标极小/极远): 以中心投影点为单位矩形兜底
		var c := cam.unproject_position(aabb.get_center())
		return Rect2(c - Vector2.ONE * 0.5, Vector2.ONE)
	return rect


## 汇总"真实显示中"的网格世界 AABB(合并), 收所有可见 MeshInstance3D 与 Label3D
static func _visible_mesh_aabb(node: Node3D) -> AABB:
	if not node.is_visible_in_tree():
		return AABB()
	var result := AABB()
	var found := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		result = (node as MeshInstance3D).global_transform * (node as MeshInstance3D).mesh.get_aabb()
		found = true
	elif node is Label3D and (node as VisualInstance3D).get_aabb().size != Vector3.ZERO:
		result = (node as Node3D).global_transform * (node as VisualInstance3D).get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var aabb := _visible_mesh_aabb(child)
			if aabb.size != Vector3.ZERO:
				result = result.merge(aabb) if found else aabb
				found = true
	return result


## 只有碰撞盒、没有可见网格的交互体(Area3D/StaticBody3D 之类):
## 用它子级 CollisionShape3D 的形状拼出世界 AABB, 否则目标会退化成 1x1 ⇒ 看起来"没高亮"
static func _collision_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var found := false
	for child in node.find_children("*", "CollisionShape3D", true, false):
		var box := _shape_aabb(child as CollisionShape3D)
		if box.size == Vector3.ZERO:
			continue
		result = result.merge(box) if found else box
		found = true
	return result


## 单个 CollisionShape3D 的世界 AABB(按形状尺寸取 8 角投影)
static func _shape_aabb(shape_node: CollisionShape3D) -> AABB:
	var shape := shape_node.shape
	if shape == null:
		return AABB()
	var size := Vector3.ZERO
	if shape is BoxShape3D:
		size = (shape as BoxShape3D).size
	elif shape is SphereShape3D:
		size = Vector3.ONE * (shape as SphereShape3D).radius * 2.0
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		size = Vector3(capsule.radius * 2.0, capsule.height, capsule.radius * 2.0)
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		size = Vector3(cylinder.radius * 2.0, cylinder.height, cylinder.radius * 2.0)
	if size == Vector3.ZERO:
		return AABB()
	var xform := shape_node.global_transform
	var local := AABB(-size * 0.5, size)
	var result := AABB(xform * local.position, Vector3.ZERO)
	for i in 8:
		result = result.expand(xform * local.get_endpoint(i))
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


## 收集 CanvasItem(含子级, 仅可见)的画布坐标矩形
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


# ------------------------------------------------------------
# 辅助
# ------------------------------------------------------------

static func _collect_lights(node: Node) -> Array[Light3D]:
	var result: Array[Light3D] = []
	if node is Light3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_lights(child))
	return result


## 目标自身及子级里所有真实参与绘制的实例(Area3D 本身不画, 画的是它的 mesh 子节点)
static func _visuals_of(node: Node) -> Array[VisualInstance3D]:
	var result: Array[VisualInstance3D] = []
	if node is VisualInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_visuals_of(child))
	return result
