## 通用 3D 拖拽视图基类，提供完整的拖拽生命周期管理。
## 继承自 ButtonView3D，子类可自由扩展拖拽行为（排序、出售等）。
## [br][br]
## 拖拽生命周期：[br]
##   按下左键 → [code]_start_drag()[/code] → [code]_on_drag_started()[/code] (虚)[br]
##   拖动鼠标 → [code]_drag()[/code] → [code]_on_drag_move()[/code] (虚)[br]
##   释放左键 → [code]_end_drag()[/code] → [code]_on_drag_ended()[/code] (虚) → 归位动画[br]
##   按下右键 → [code]_cancel_drag()[/code] → [code]_on_drag_cancelled()[/code] (虚) → 回到起点
class_name DragView3D extends ButtonView3D

## 希望拖拽时产生缩放动画的节点，为空则使用自身
@export var drag_visual_node: Node3D

## 拖拽时沿相机前方的 Z 偏移量，避免与其它物体重叠
@export var drag_z_offset: float = -0.04

## 拾起时的目标缩放比例
@export var drag_pickup_scale: float = 1.1

## 归位动画时长（秒）
@export var drag_return_duration: float = 0.2

## 拖拽排序吸附阈值比例（与相邻卡牌间距的比例，超过此比例才触发换位）
@export var drag_snap_threshold_ratio: float = 0.1

## ---------------------------------------------------- 信号
signal drag_started()
signal drag_ended()
signal drag_cancelled()

## ---------------------------------------------------- 拖拽状态
## 是否正在拖拽中（由 dragging_item 推导）
var is_dragging: bool:
	get: return ButtonView3D.dragging_item == self
var drag_offset: Vector3 = Vector3.ZERO
var drag_start_global_pos: Vector3 = Vector3.ZERO
var drag_plane: Plane
## 拖拽容器（SlotArrayView3D 及其子类）用于排序时重新排列数据
var drag_container: SlotArrayView3D = null

## ---------------------------------------------------- 输入事件衔接

func _mouse_down():
	super._mouse_down()
	_start_drag()

func _mouse_up():
	super._mouse_up()
	if is_dragging:
		_end_drag()

func _unhandled_input(event: InputEvent):
	if not is_dragging:
		return
	if event is InputEventMouseMotion:
		_drag(event)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_drag()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_cancel_drag()

## ---------------------------------------------------- 拖拽核心流程

## 开始拖拽：保存起始位置，创建拖拽平面，计算偏移，播放拾起动画
func _start_drag():
	if not _can_drag():
		return
	ButtonView3D.dragging_item = self
	drag_start_global_pos = global_position

	var camera: Camera3D = get_viewport().get_camera_3d()
	var camera_forward: Vector3 = -camera.global_basis.z.normalized()

	# 沿相机前方微移，避免与其它物品重叠
	global_position = drag_start_global_pos + camera_forward * drag_z_offset

	# 创建与相机前方垂直的拖拽平面
	drag_plane = Plane(camera_forward, global_position)

	# 计算鼠标位置与物体位置的初始偏移
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var intersection: Variant = drag_plane.intersects_ray(ray_origin, ray_dir)
	drag_offset = global_position - intersection if intersection else Vector3.ZERO

	# 拾起动画
	_play_pickup_animation()

	drag_started.emit()
	_on_drag_started()

## 拖拽过程：射线与平面求交，更新全局位置，限制只能水平移动
func _drag(_event: InputEventMouseMotion):
	if not is_dragging:
		return

	var camera: Camera3D = get_viewport().get_camera_3d()
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()

	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)

	var intersection: Variant = drag_plane.intersects_ray(ray_origin, ray_dir)
	if not intersection:
		return

	var new_position: Vector3 = intersection + drag_offset
	var up_dir: Vector3 = -camera.global_basis.y.normalized()
	var up_distance: float = (new_position - drag_start_global_pos).dot(up_dir)
	if up_distance > 0:
		# 只保留水平分量，禁止向上拖出平面
		var horizontal_offset: Vector3 = new_position - drag_start_global_pos
		var horizontal_projection: Vector3 = horizontal_offset - horizontal_offset.dot(up_dir) * up_dir
		new_position = drag_start_global_pos + horizontal_projection

	global_position = new_position
	_on_drag_move()

## 结束拖拽：通知子类处理下落逻辑，然后归位
func _end_drag():
	if not is_dragging:
		return

	_on_drag_ended()

	# 子类可能已通过 _cleanup_drag_state() 标记跳过清理（如出售后节点即将移除）
	if not is_dragging or not is_instance_valid(self):
		return

	_restore_position()
	_restore_scale()
	_cleanup_drag_state()
	drag_ended.emit()

## 取消拖拽（右键）：回到起始位置并归位
func _cancel_drag():
	if not is_dragging:
		return

	_on_drag_cancelled()

	if not is_dragging or not is_instance_valid(self):
		return

	global_position = drag_start_global_pos
	_restore_position()
	_restore_scale()
	_cleanup_drag_state()
	drag_cancelled.emit()

## ---------------------------------------------------- 工具方法

## 播放拾起缩放动画
func _play_pickup_animation():
	var target: Node3D = _get_drag_visual_node()
	if not target or is_zero_approx(drag_pickup_scale - 1.0):
		return
	var t: Tween = create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	t.tween_property(target, "scale", Vector3.ONE * drag_pickup_scale, drag_return_duration * 0.75)

## 播放归位位置动画（回到插槽本地原点）
func _restore_position():
	var t: Tween = create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	t.tween_property(self, "position", _get_rest_position(), drag_return_duration)

## 播放恢复缩放动画
func _restore_scale():
	var target: Node3D = _get_drag_visual_node()
	if not target:
		return
	var t: Tween = create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	t.tween_property(target, "scale", Vector3.ONE, drag_return_duration * 0.75)

## 统一重置拖拽状态（子类出售场景可主动调用以跳过基类清理）
func _cleanup_drag_state():
	ButtonView3D.dragging_item = null
	drag_offset = Vector3.ZERO
	drag_start_global_pos = Vector3.ZERO
	drag_container = null

## ---------------------------------------------------- 可重写的虚方法

## 返回拖拽视觉节点（用于缩放动画），默认返回 drag_visual_node 或 self
func _get_drag_visual_node() -> Node3D:
	if drag_visual_node:
		return drag_visual_node
	return self

## 返回归位时的目标本地位置，默认 (0, 0, 0)
func _get_rest_position() -> Vector3:
	return Vector3.ZERO

## 是否允许拖拽 —— 子类重写以实现权限控制（如仅玩家可拖、非战斗状态可拖）
func _can_drag() -> bool:
	return true

## 拖拽开始回调 —— 自动发现父级 SlotArrayView3D（或其子类）容器
func _on_drag_started():
	drag_container = null
	var p: Node = get_parent()
	if p and p.get_parent() is SlotArrayView3D:
		drag_container = p.get_parent()

## 拖拽移动回调 —— 每帧调用，子类可在此检测碰撞区域等
func _on_drag_move():
	pass

## 拖拽结束回调 —— 默认执行 OffsetArrayView3D 排序逻辑
## [br]子类重写时应先判断是否自行处理（如出售），否则调用 super
func _on_drag_ended():
	if not drag_container:
		return
	var new_index: int = _calculate_sort_index()
	if new_index != -1:
		_apply_sort(new_index)

## 拖拽取消回调 —— 子类可在此重置额外状态
func _on_drag_cancelled():
	pass

## ---------------------------------------------------- 排序逻辑（OffsetArrayView3D 专用）

## 计算拖拽后的排序索引，返回 -1 表示位置未变化
func _calculate_sort_index() -> int:
	var local_pos: Vector3 = drag_container.to_local(global_position)
	var views: Array = drag_container.views
	var current_index: int = views.find(self)
	if current_index < 0:
		return -1

	var new_index: int = current_index

	# OffsetArrayView3D 可提供精确的排列方向与间距，普通 SlotArrayView3D 使用默认阈值
	var offset_vec: Vector3 = drag_container.offset if drag_container is OffsetArrayView3D else Vector3.ZERO
	var is_vertical: bool = abs(offset_vec.y) > abs(offset_vec.x)
	var half_spacing_x: float = abs(offset_vec.x) * drag_snap_threshold_ratio if offset_vec.x != 0 else 0.5
	var half_spacing_y: float = abs(offset_vec.y) * drag_snap_threshold_ratio if offset_vec.y != 0 else 0.5

	for i in range(views.size()):
		if i == current_index:
			continue
		var other_view: Node3D = views[i]
		if not is_instance_valid(other_view):
			continue
		var view_local_pos: Vector3 = drag_container.to_local(other_view.global_position)
		var delta: Vector3 = local_pos - view_local_pos
		if not is_vertical:
			# 水平排列：delta.x > 0 表示当前物品在目标物品右侧
			if delta.x > half_spacing_x:
				new_index = max(new_index, i + 1)
			elif delta.x < -half_spacing_x:
				new_index = min(new_index, i)
		else:
			# 垂直排列：delta.y > 0 表示当前物品在目标物品下方
			if delta.y > half_spacing_y:
				new_index = max(new_index, i + 1)
			elif delta.y < -half_spacing_y:
				new_index = min(new_index, i)

	return new_index if new_index != current_index else -1

## 执行数组排序：移动 data 中的元素并重新绑定视图
func _apply_sort(new_index: int):
	var views: Array = drag_container.views
	var current_index: int = views.find(self)
	if current_index < 0:
		return
	if not drag_container.data or current_index >= drag_container.data.size():
		return

	var dragged_item = drag_container.data[current_index]
	drag_container.data.remove_at(current_index)
	new_index = clampi(new_index, 0, drag_container.data.size())
	drag_container.data.insert(new_index, dragged_item)

	var count: int = mini(drag_container.data.size(), drag_container.views.size())
	for i in count:
		var sorted_view: Node3D = drag_container.views[i]
		if is_instance_valid(sorted_view) and "data" in sorted_view:
			sorted_view.data = drag_container.data[i]
