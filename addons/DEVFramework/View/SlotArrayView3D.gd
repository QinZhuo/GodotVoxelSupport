@tool
class_name SlotArrayView3D extends Node3D

@export var view_scene: PackedScene:
	set(value):
		view_scene = value
		_preview_setup()

var pool: BakedPool
var data: Array:
	set(value):
		data = value
		refresh()

@export var auto_hide_empty: bool = false:
	set(value):
		auto_hide_empty = value
		_update_slot_visibility()

var views: Array[Node3D] = []

func _resize_views():
	var count = get_child_count()
	while views.size() < count:
		views.append(null)
	while views.size() > count:
		var view = views.pop_back()
		if is_instance_valid(view):
			ArrayViewTool.free_view(view, pool)

func _ready():
	_resize_views()
	_preview_setup()

func _preview_setup():
	if not Engine.is_editor_hint():
		return
	_resize_views()
	clear()
	var slot_nodes := get_children()
	if not view_scene or slot_nodes.is_empty():
		return
	for i in slot_nodes.size():
		_set_slot_view(i, null)
	_update_slot_visibility()

func _update_slot_visibility():
	if not auto_hide_empty:
		return
	var slot_nodes := get_children()
	for i in slot_nodes.size():
		var slot = slot_nodes[i] as Node3D
		if not slot:
			continue
		slot.visible = i < views.size() and is_instance_valid(views[i])

# --- 核心私有方法 ---

# 在指定插槽设置 view（释放旧 view → 创建新 view → 挂载到插槽）
func _set_slot_view(slot_index: int, item) -> Node3D:
	var slot_nodes := get_children()
	if slot_index < 0 or slot_index >= slot_nodes.size():
		return null
	var view = ArrayViewTool.create_view(view_scene, pool, item)
	if view:
		slot_nodes[slot_index].add_child(view)
		views[slot_index] = view
	return view

# 释放指定插槽的 view
func _free_slot(slot_index: int):
	if slot_index < 0 or slot_index >= views.size():
		return
	if is_instance_valid(views[slot_index]):
		ArrayViewTool.free_view(views[slot_index], pool)
	views[slot_index] = null

# 查找第一个空插槽索引，全满则返回最后一个（溢出兜底）
func _find_slot_index() -> int:
	if views.is_empty():
		return -1
	for i in views.size():
		if not is_instance_valid(views[i]):
			return i
	return views.size() - 1

# --- 公开方法 ---

func refresh():
	_resize_views()
	clear()
	var slot_nodes := get_children()
	if not data or data.is_empty() or slot_nodes.is_empty():
		return
	var last_index = slot_nodes.size() - 1
	for i in data.size():
		if data[i] == null:
			continue
		_set_slot_view(mini(i, last_index), data[i])
	_update_slot_visibility()

func clear():
	for i in views.size():
		_free_slot(i)
	_update_slot_visibility()

func refresh_item(item) -> Node3D:
	_resize_views()
	var item_name = ArrayViewTool.get_item_name(item)
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and view.name == item_name:
			if "data" in view:
				view.data = item
			return view
	var view = _set_slot_view(_find_slot_index(), item)
	_update_slot_visibility()
	return view

func add_item(item) -> Node3D:
	_resize_views()
	var view = _set_slot_view(_find_slot_index(), item)
	_update_slot_visibility()
	return view

func remove_at(index: int):
	_resize_views()
	if index < 0 or index >= views.size():
		return
	_free_slot(index)
	_update_slot_visibility()

func set_item(index: int, item) -> Node3D:
	_resize_views()
	var slot_nodes := get_children()
	if index < 0 or index >= slot_nodes.size():
		return null
	var view = _set_slot_view(index, item)
	_update_slot_visibility()
	return view

func remove_item(item):
	_resize_views()
	var item_name = ArrayViewTool.get_item_name(item)
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and view.name == item_name:
			_free_slot(i)
			_update_slot_visibility()
			return

func get_item_position(item) -> Vector3:
	_resize_views()
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and "data" in view and view.data == item:
			return view.global_position
	printerr(self, "  无法获取位置 ", item)
	return Vector3.ZERO
