@tool
class_name BakedPool2D extends Node2D

func _ready():
	if not Engine.is_editor_hint():
		visible = false
	_add_performance_monitors()
	# 池内待命的实例不启动动画（子节点 _ready 先于父节点，此时动画刚起播）
	for item in get_children():
		_park(item)

## 让实例进入待命态：停掉还在播的动画/粒子，否则会一直播到下次被取用
func _park(item: Node) -> void:
	if item.has_method(&"on_pool_push"):
		item.call(&"on_pool_push")

## 把实例加入池中待命
## 动态补充池成员必须走本方法而非 add_child：池已入树时 _ready 早已跑完，
## 新成员的 _ready 会起播动画且再无守卫拦停，播完自毁就把池悄悄掏空
func pool_add(item: Node2D) -> void:
	add_child(item)
	_park(item)

func _exit_tree():
	_remove_performance_monitors()

var need_count: int

var used_items: Array[Node2D]

func pool_get() -> Node2D:
	if get_child_count():
		need_count = 0
		var item := get_child(0)
		remove_child(item)
		used_items.append(item)
		# 取出不等于重新入树，_ready 不会重跑，这里补一次恢复
		if item.has_method(&"on_pool_get"):
			item.call(&"on_pool_get")
		return item
	else:
		need_count += 1
		printerr('对象池[', name, ']不足 还需 ', need_count)
		return null

func pool_push(item: Node2D):
	# 已停放在池中：属于重复归还，忽略
	## 归还可能因释放逻辑被重入而调用两次，第一次已把实例放回池，第二次不该再走销毁分支
	if item.get_parent() == self:
		return
	if !used_items.has(item):
		## 外来节点（池耗尽时 view_scene 兜底实例化的）直接摘除再释放：
		## queue_free 是延迟的，不先摘除会让它在槽位里多留一帧（同一帧重填该槽位会重名被引擎改名 + 视觉重叠）
		if item.get_parent() != null:
			item.get_parent().remove_child(item)
		item.queue_free()
		return
	used_items.erase(item)
	if item.get_parent() != null:
		item.get_parent().remove_child(item)
	pool_add(item)

func _add_performance_monitors():
	var prefix := "BakedPool/{0}/".format([name])
	_add_monitor(prefix + "Active", _get_used_count)
	_add_monitor(prefix + "Idle", _get_available_count)
	_add_monitor(prefix + "Miss", _get_need_count)

func _remove_performance_monitors():
	var prefix := "BakedPool/{0}/".format([name])
	_remove_monitor(prefix + "Active")
	_remove_monitor(prefix + "Idle")
	_remove_monitor(prefix + "Miss")

func _add_monitor(id: String, callable: Callable) -> void:
	if not Performance.has_custom_monitor(id):
		Performance.add_custom_monitor(id, callable)

func _remove_monitor(id: String) -> void:
	if Performance.has_custom_monitor(id):
		Performance.remove_custom_monitor(id)

func _get_used_count() -> float:
	return used_items.size()

func _get_available_count() -> float:
	return get_child_count()

func _get_need_count() -> float:
	return need_count
