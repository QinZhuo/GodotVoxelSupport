## 通用节点池：只负责实例复用，实例怎么造由 [member factory] 决定。
##
## 空闲实例挂在 [member idle_parent] 下（常驻隐藏节点，不属于任何视图），池被丢弃也不会漏节点。
## ⚠️ 别想用 _notification 收尾：RefCounted 进 PREDELETE 时脚本成员已经清空了，那里读不到东西。
class_name Pool extends RefCounted

## 池空时创建新实例；返回 null 视为无法创建（pool_get 返回 null）
var factory: Callable

## 空闲实例的父节点（由 PoolService 注入）
var idle_parent: Node

## 空闲上限（0 = 不限）。超出上限的归还直接销毁，避免池无限膨胀
var max_idle: int = 0

## 是否调用实例的 on_pool_get() / on_pool_return()：视图靠它起停动画
var lifecycle_hooks: bool = true

## 池空导致的现场创建数（= 没有命中复用）
var created_count: int = 0

var _idle: Array[Node] = []
## 借出中的实例 id（唯一真相：只有这里记录的是"借出未还"）
var _in_use: Dictionary = {}

## 取一个实例：优先复用空闲的，池空则调 factory 新建。返回的实例无父节点
func pool_get() -> Node:
	var item := _pop_idle()
	if item == null:
		if not factory.is_valid():
			return null
		item = factory.call()
		if item == null:
			return null
		created_count += 1
	_in_use[item.get_instance_id()] = true
	_set_visible(item, true)
	if lifecycle_hooks and item.has_method(&"on_pool_get"):
		item.call(&"on_pool_get")
	return item

## 归还实例。重复归还、已失效、非本池取出的一律忽略（不是本池的东西本池不负责销毁）
func pool_return(item: Node) -> void:
	if not is_instance_valid(item):
		return
	if not _in_use.erase(item.get_instance_id()):
		return
	if max_idle > 0 and _idle.size() >= max_idle:
		_discard(item)
		return
	_push_idle(item)

## 预建 count 个空闲实例：把创建成本从运行期挪到加载期
func prewarm(count: int) -> void:
	if not factory.is_valid():
		return
	for i in count:
		if max_idle > 0 and _idle.size() >= max_idle:
			return
		var item = factory.call()
		if item == null:
			return
		created_count += 1
		_push_idle(item)

func is_in_use(item: Node) -> bool:
	return is_instance_valid(item) and _in_use.has(item.get_instance_id())

func in_use_count() -> int:
	return _in_use.size()

func idle_count() -> int:
	return _idle.size()

## 释放所有空闲实例（借出的不归池管，等它归还）
func clear() -> void:
	for item in _idle:
		if is_instance_valid(item):
			item.free()
	_idle.clear()

func _pop_idle() -> Node:
	while not _idle.is_empty():
		var item: Node = _idle.pop_back()
		if is_instance_valid(item):
			_reparent(item, null)
			return item
	return null

func _push_idle(item: Node) -> void:
	## 钩子与隐藏必须在摘除前：视图要靠父节点/全局变换收尾（Trail3D 清轨迹要读变换）
	if lifecycle_hooks and item.has_method(&"on_pool_return"):
		item.call(&"on_pool_return")
	_set_visible(item, false)
	_reparent(item, idle_parent)
	_idle.append(item)

## 纯视图（MeshInstance3D / Control）没有 on_pool_return 替它藏，
## 不处理就会以上一次的变换留在场景里，看起来像多出来的幽灵模型
func _set_visible(item: Node, visible: bool) -> void:
	if item is Node3D:
		(item as Node3D).visible = visible
	elif item is CanvasItem:
		(item as CanvasItem).visible = visible

func _reparent(item: Node, parent: Node) -> void:
	if item.get_parent() == parent:
		return
	if item.get_parent() != null:
		item.get_parent().remove_child(item)
	if parent != null:
		parent.add_child(item)

## queue_free 是延迟的：带父节点会多在槽位里留一帧，先摘再放
func _discard(item: Node) -> void:
	_reparent(item, null)
	item.queue_free()
