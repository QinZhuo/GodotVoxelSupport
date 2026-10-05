@tool
## 槽位数组视图：**Node2D 子节点 = 槽位**（其他类型子节点忽略），`data[i]` 的视图挂在槽位 i 下。
##
## 契约：① `views[i]` 显示 `data[i]`（定位按视图当前的 `data` 比对，视图名只用于 Scene Tree 可读，
## 数据项不需要实现 `get_view_name()`）；② `data[i] == null` = 空槽位（跳过但占索引）；
## ③ `data` 多于槽位 = 多余项不显示并报错；④ `add_item()` 槽位满时落到最后一格。
##
## 算法实现在 ArrayViewTool（与 Node3D 版共用同一份），本类只负责类型与宿主钩子。
class_name SlotArrayView2D extends Node2D

## 视图场景（每个数据项实例化一个）
@export var view_scene: PackedScene:
	set(value):
		view_scene = value
		_preview_setup()

## 数据数组（赋值即刷新）
var data: Array:
	set(value):
		data = value
		refresh()

## 空槽位是否连槽位本身一起隐藏（只显示有视图的槽位）
@export var auto_hide_empty: bool = false:
	set(value):
		auto_hide_empty = value
		_update_slot_visibility()

## 可选对象池：只需实现 pool_get() / pool_push()，BakedPool 与 BakedPool2D 都兼容
##（框架侧按鸭子类型调用，见 ArrayViewTool）。留空则每次现场实例化 view_scene。
## ⚠️ BakedPoolManager.find_pool() 只返回 3D 的 BakedPool，要用统一注册需自行建池节点后注入
var pool

## 与 data 一一对应的视图列表（框架每次刷新都会把长度对齐到槽位数；业务侧只读）
var views: Array[Node2D] = []

func _ready():
	_resize_views()
	_preview_setup()

## 槽位 = 本节点的 Node2D 子节点（按顺序）。
## 承载动画 / 辅助节点的普通 Node 不算槽位，可以放心挂在本节点下。
func _get_slots() -> Array[Node2D]:
	var slots: Array[Node2D] = []
	for child in get_children():
		if child is Node2D:
			slots.append(child)
	return slots

## ---- 公开接口（实现见 ArrayViewTool.slot_*）----

## 按 data 重建全部槽位视图
func refresh() -> void:
	ArrayViewTool.slot_refresh(self)

## 清空所有槽位视图（不改 data）
func clear() -> void:
	ArrayViewTool.slot_clear(self)

## 按 data 重新对齐全部槽位（拖拽排序 / 删项后调用；复用已有实例，不重建节点）
func resync_views() -> void:
	ArrayViewTool.slot_resync(self)

## 把第 index 项对齐到 data[index]（含整体重排；下标越界 / 空数据位返回 null）
func refresh_at(index: int) -> Node2D:
	return ArrayViewTool.slot_refresh_at(self, index) as Node2D

## 刷新某个数据项：不在 data 里时按"已有视图重绑"或"新增一项"处理
func refresh_item(item) -> Node2D:
	return ArrayViewTool.refresh_item(self, item) as Node2D

## 追加一项到第一个空槽（满槽则落到最后一格）
func add_item(item) -> Node2D:
	return ArrayViewTool.slot_add_item(self, item) as Node2D

## 把 item 放到指定槽位（不读 data，用于"这一格临时改显示别的"）；越界返回 null。
## ⚠️ data 才是唯一真相：之后的 refresh / resync_views / refresh_item 会按 data 把它纠回来
func set_item(index: int, item) -> Node2D:
	return ArrayViewTool.slot_set_item(self, index, item) as Node2D

## 槽位数量（= 本节点的 Node2D 子节点数；业务侧按容器容量裁剪数据时用它）
func get_slot_count() -> int:
	return _get_slots().size()

## 移除第 index 个视图（不改 data）并补洞重排
func remove_at(index: int) -> void:
	ArrayViewTool.slot_remove_at(self, index)

## 移除某个数据项的视图（item 为 null 时不动：null 是空槽位的合法值）
func remove_item(item) -> void:
	ArrayViewTool.remove_item(self, item)

## 取第 index 槽位上的视图（越界 / 空槽返回 null）
func get_view(index: int) -> Node2D:
	return ArrayViewTool.get_view(views, index) as Node2D

## 某个数据项所在槽位的全局位置（找不到时报错并返回原点）
func get_item_position(item) -> Vector2:
	_resize_views()
	var view := get_view(ArrayViewTool.index_of_item(data, views, item))
	if view:
		return view.global_position
	printerr(self, "  无法获取位置 ", item)
	return Vector2.ZERO

## ---- 宿主钩子（ArrayViewTool.slot_* 调用）----

func _resize_views() -> void:
	ArrayViewTool.resize_views(views, _get_slots().size(), pool)

func _update_slot_visibility() -> void:
	ArrayViewTool.update_slot_visibility(_get_slots(), views, auto_hide_empty)

func _preview_setup() -> void:
	ArrayViewTool.slot_preview_setup(self)
