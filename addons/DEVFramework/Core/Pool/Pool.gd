## 通用节点池：只负责实例复用，实例怎么造由 [member factory] 决定。
class_name Pool extends RefCounted

## 池空时创建新实例；返回 null 视为无法创建（pool_get 返回 null）
var factory: Callable

## 空闲实例的父节点（由 PoolTool 注入）
var idle_parent: Node

## 空闲上限（0 = 不限）。
var max_idle: int = 0

## 池空导致的现场创建数（= 没有命中复用）
var created_count: int = 0

## 命中复用的借出次数（= 池化真正省下的 instantiate 次数）
var reused_count: int = 0

var _idle: Array[Node] = []
## 借出中的实例 id → weakref（唯一真相：只有这里记录的是"借出未还"）。
var _in_use: Dictionary = {}

## 摊还清理：每借出/归还这么多次顺手剪一遍失效条目，不必逐帧扫
const PRUNE_EVERY := 64
var _since_prune: int = 0

## 取一个实例：优先复用空闲的，池空则调 factory 新建。
func pool_get() -> Node:
	_maybe_prune()
	var item := _pop_idle()
	if item != null:
		reused_count += 1
	elif factory.is_valid():
		item = factory.call()
		if item == null:
			return null
		created_count += 1
	else:
		return null
	_in_use[item.get_instance_id()] = weakref(item)
	_set_visible(item, true)
	if item.has_method(&"on_pool_get"):
		item.call(&"on_pool_get")
	return item

## 归还实例。
func pool_return(item: Node) -> void:
	if not is_instance_valid(item):
		return
	if not _in_use.erase(item.get_instance_id()):
		return
	_maybe_prune()
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

## 剪掉已失效的借出条目：场景卸载 / 外部 queue_free 都不会走 pool_return
func _prune() -> void:
	for id in _in_use.keys():
		if (_in_use[id] as WeakRef).get_ref() == null:
			_in_use.erase(id)

func _maybe_prune() -> void:
	_since_prune += 1
	if _since_prune >= PRUNE_EVERY:
		_since_prune = 0
		_prune()

func _pop_idle() -> Node:
	while not _idle.is_empty():
		# 必须先用**无类型**变量接住: 空闲队列里可能残留已被外部释放的节点,
		var raw: Variant = _idle.pop_back()
		if not is_instance_valid(raw):
			continue
		var item := raw as Node
		if item == null:
			continue
		_reparent(item, null)
		return item
	return null

func _push_idle(item: Node) -> void:
	## 钩子与隐藏必须在摘除前：视图要靠父节点/全局变换收尾（Trail3D 清轨迹要读变换）
	if item.has_method(&"on_pool_return"):
		item.call(&"on_pool_return")
	_set_visible(item, false)
	_reparent(item, idle_parent)
	_idle.append(item)

## 纯视图（MeshInstance3D / Control）没有 on_pool_return 替它藏。
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
