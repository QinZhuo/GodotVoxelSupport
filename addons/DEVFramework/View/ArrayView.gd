## 泛型数组视图（**流式布局**）：`data` 的每一项实例化一个 `view_scene`，
## 由 FlowContainer 按子节点内容尺寸流动排布、装满一行就换行 —— 适合卡片/标签这类"自适应尺寸"的列表。
## 槽位数固定、需要"一个槽位一个视图"的场景用 SlotArrayView2D / SlotArrayView3D。
##
## ⚠️ 数据项**不需要** `get_view_name()`：定位按「视图当前显示的 data」比对，视图名只用于 Scene Tree 可读。
## 视图全部生成完毕时发 `view_finished`；要"确保已建完"请 `await wait_finished()`。
@tool
class_name ArrayView extends FlowContainer

signal view_finished

## 视图场景（每项实例化一个）
@export var view_scene: PackedScene:
	set(value):
		view_scene = value
		_preview()
## 每帧生成数量，0 表示全部立即生成（默认）。大于 0 时分帧创建子节点，
## 避免大量 UI 节点一次性 instantiate 导致掉帧。
@export var items_per_frame: int = 0
## 仅编辑器：铺几个空视图看排版（owner 为空，不会存进场景）
@export var preview_count: int = 3:
	set(value):
		preview_count = value
		_preview()

var data: Array:
	set(value):
		data = value
		refresh()

## 与 data 一一对应的视图列表。⚠️ 不能直接拿 get_child(index) 当第 index 项：
## 视图走 tween_free 淡出时旧节点还挂在子节点里一会儿，子节点序号会和 data 错位
var views: Array[Node] = []

## 当前生成批次；refresh / clear 都会 +1，用来作废进行中的分帧生成
var _generation_id := 0
## 已完成生成到的批次（== _generation_id 表示"没有待生成的内容"）
var _finished_generation := 0

## 刷新视图，根据当前数据重新显示所有项目
func refresh() -> void:
	_generation_id += 1
	_clear_children()
	if not data or data.is_empty():
		_mark_finished()
		return
	if items_per_frame > 0:
		_generate_in_frames()
	else:
		for i in data.size():
			_insert_view(i, data[i])
		queue_sort()
		_mark_finished()

## 等待全部视图生成完毕；已建完 / data 为空 / 从未刷新过时立即返回
func wait_finished() -> void:
	while _finished_generation != _generation_id:
		await view_finished

func _generate_in_frames() -> void:
	var gen := _generation_id
	await AsyncTool.call_in_frames(data, items_per_frame, add_item, func(): return _generation_id != gen)
	if _generation_id == gen:
		queue_sort()
		_mark_finished()

func _mark_finished() -> void:
	_finished_generation = _generation_id
	view_finished.emit()

## 清除所有子节点（并作废进行中的分帧生成）
func clear() -> void:
	_generation_id += 1
	_clear_children()
	_finished_generation = _generation_id

func _clear_children() -> void:
	for view in get_children():
		ArrayViewTool.free_view(view, null)
	views.clear()

## 创建 item 的视图并放到 index 位置（views 不够长就补空位）
func _insert_view(index: int, item) -> Node:
	if index < 0:
		return null
	while views.size() <= index:
		views.append(null)
	var view := ArrayViewTool.create_view(view_scene, null, item, index)
	if not view:
		return null
	add_child(view)
	if view.get_index() != index:
		move_child(view, index)
	views[index] = view
	return view

## 添加新项目到视图中（追加到末尾）
## [param item] 要添加的数据项
func add_item(item) -> Node:
	return _insert_view(views.size(), item)

## ---- 索引接口（主实现）----
## 索引 == data 的顺序位 == views 的槽位（**不是**子节点序号，见 views 的说明）

## 取第 index 个视图（越界 / 空位返回 null）
func get_view(index: int) -> Node:
	return ArrayViewTool.get_view(views, index)

## 把第 index 项重新绑到视图：没有就补建，并摆到它该在的位置
func refresh_at(index: int) -> Node:
	var item = data[index] if (data and index < data.size()) else null
	if item == null:
		return null
	var view := get_view(index)
	if view == null:
		return _insert_view(index, item)
	ArrayViewTool.rebind(view, item, index)
	return view

## 移除第 index 个视图（**不改 data**）
func remove_at(index: int) -> void:
	ArrayViewTool.free_at(views, index, null)

## ---- 数据项接口（便利重载：① ② ③ 骨架统一在 ArrayViewTool.refresh_item）----

## 刷新单项视图（便利重载）；定位不到时当作新增
## [param item] 要刷新的数据项
func refresh_item(item) -> Node:
	return ArrayViewTool.refresh_item(self, item)

## 从视图中移除指定项目
## [param item] 要移除的数据项
func remove_item(item) -> void:
	ArrayViewTool.remove_item(self, item)

## 找到正在显示 item 的视图（只读查询；没有则 null）
func find_item_view(item) -> Node:
	return get_view(ArrayViewTool.index_of_view(views, item))

## 编辑器预览：铺 preview_count 个空视图（owner 为空 ⇒ 不会存进场景）
func _preview() -> void:
	if not Engine.is_editor_hint():
		return
	clear()
	if view_scene == null:
		return
	for i in preview_count:
		add_child(view_scene.instantiate())
