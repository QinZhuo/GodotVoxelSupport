## 池注册表：按 key 存取。空闲实例统一挂在常驻的隐藏节点 PoolIdle 下，
## 池本身是 RefCounted，丢了也不会带走节点。
class_name PoolService

## key -> Pool
static var _pools: Dictionary = {}

static var _idle_root: Node

static var _monitored := false

## 取池（没有就按工厂建一个）。工厂用 [code]view_scene.instantiate[/code] 即可
static func ensure(key: String, factory: Callable) -> Pool:
	var pool: Pool = _pools.get(key)
	if not is_instance_valid(pool):
		pool = Pool.new()
		pool.idle_parent = _idle_parent_for(key)
		_pools[key] = pool
	pool.factory = factory
	_add_monitors()
	return pool

static func find(key: String) -> Pool:
	var pool: Pool = _pools.get(key)
	return pool if is_instance_valid(pool) else null

## 取一个实例（池不存在返回 null，调用方自行兜底）
static func pool_get(key: String) -> Node:
	var pool := find(key)
	return pool.pool_get() if pool else null

## 归还一个实例；没有对应池时直接销毁
static func pool_return(key: String, item: Node) -> void:
	if not is_instance_valid(item):
		return
	var pool := find(key)
	if pool:
		pool.pool_return(item)
		return
	if item.get_parent() != null:
		item.get_parent().remove_child(item)
	item.queue_free()

## 释放该池的空闲实例并移除注册
static func remove(key: String) -> void:
	var pool := find(key)
	if pool:
		pool.clear()
	_pools.erase(key)

## 清空所有池（借出的实例等它归还不受影响）
static func clear() -> void:
	for pool in _pools.values():
		if is_instance_valid(pool):
			pool.clear()
	_pools.clear()

## 空闲实例的根容器：不参与渲染与处理，只为让节点有父、不出场景树
static func _ensure_idle_root() -> Node:
	if is_instance_valid(_idle_root):
		return _idle_root
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	_idle_root = Node.new()
	_idle_root.name = "PoolIdle"
	_idle_root.process_mode = Node.PROCESS_MODE_DISABLED
	tree.root.add_child(_idle_root)
	return _idle_root

## 每个池一个专属容器：同名池重建时清掉上一轮残留的空闲实例
static func _idle_parent_for(key: String) -> Node:
	var root := _ensure_idle_root()
	if root == null:
		return null
	var parent := root.get_node_or_null(NodePath(key))
	if parent == null:
		parent = Node.new()
		parent.name = key
		root.add_child(parent)
		return parent
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
	return parent

## 池可能有上百个，逐个加监控会把 Monitors 面板刷爆，这里只汇总
static func _add_monitors() -> void:
	if _monitored or Engine.is_editor_hint():
		return
	_monitored = true
	Performance.add_custom_monitor("Pool/InUse", _total_in_use)
	Performance.add_custom_monitor("Pool/Idle", _total_idle)
	Performance.add_custom_monitor("Pool/Created", _total_created)

static func _total_in_use() -> float:
	var total := 0
	for pool in _pools.values():
		if is_instance_valid(pool):
			total += pool.in_use_count()
	return total

static func _total_idle() -> float:
	var total := 0
	for pool in _pools.values():
		if is_instance_valid(pool):
			total += pool.idle_count()
	return total

static func _total_created() -> float:
	var total := 0
	for pool in _pools.values():
		if is_instance_valid(pool):
			total += pool.created_count
	return total
