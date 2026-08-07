## ArrayViewTool 是数组视图组件的通用工具类。
## 提取 ArrayView / OffsetArrayView3D / SlotView3D 中的重复逻辑，统一管理视图的创建与释放。
class_name ArrayViewTool

## 获取数据项的唯一标识名称。
## 如果数据项实现了 get_view_name 方法则使用其返回值，否则使用 hash 值。
## [param item] 数据项
static func get_item_name(item) -> String:
	if not item:
		return "temp"
	if not item is Object:
		return str(item)
	if "get_view_name" in item:
		return item.get_view_name()
	return str(hash(item))

## 创建并配置一个数据项的视图实例。
## 支持对象池复用，自动设置 data 和 name。
## [param view_scene] 用于实例化的 PackedScene（pool 为空时必填）
## [param pool] 可选的 BakedPool 对象池
## [param item] 数据项
## [returns] 配置好的视图节点，失败返回 null
static func create_view(view_scene: PackedScene, pool, item) -> Node:
	var view: Node
	if pool:
		view = pool.pool_get()
	else:
		if not view_scene:
			LogTool.error("数组视图", "view_scene 未赋值!")
			return null
		view = view_scene.instantiate()
	if item is Node and not item.get_parent():
		view.add_child(item)
	if "data" in view:
		view.data = item
	view.name = get_item_name(item)
	return view

## 释放一个视图节点。
## 优先使用对象池回收，否则尝试 tween_free，最后 queue_free。
## [param view] 要释放的视图节点
## [param pool] 可选的 BakedPool 对象池
static func free_view(view: Node, pool):
	if not is_instance_valid(view):
		return
	if pool:
		pool.pool_push(view)
	else:
		if "tween_free" in view:
			view.tween_free()
		else:
			view.queue_free()

## 从父节点中按名称查找视图。
## [param parent] 父节点
## [param item_name] 数据项名称
## [returns] 找到的视图节点，未找到返回 null
static func find_view(parent: Node, item_name: String) -> Node:
	return parent.get_node_or_null(item_name)
