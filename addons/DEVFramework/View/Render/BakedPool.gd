@tool
class_name BakedPool extends Node3D

func _ready():
	if not Engine.is_editor_hint():
		visible = false
	_add_performance_monitors()

func _exit_tree():
	_remove_performance_monitors()

var need_count: int

var used_items: Array[Node3D]

func pool_get() -> Node3D:
	if get_child_count():
		need_count = 0
		var item := get_child(0)
		remove_child(item)
		used_items.append(item)
		return item
	else:
		need_count += 1
		printerr('对象池[', name, ']不足 还需 ', need_count)
		return null

func pool_push(item: Node3D):
	if !used_items.has(item):
		item.queue_free()
		return
	used_items.erase(item)
	if item.get_parent() != null:
		item.get_parent().remove_child(item)
	add_child(item)

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