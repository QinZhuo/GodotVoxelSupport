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

## 按 data 重新对齐所有槽位视图：保证 views[i] 显示 data[i]，且视图名同步为数据名。
## 删除 / 拖拽排序后**必须**调用 —— 框架内部（remove_item / refresh_item / get_item_position）
## 都依赖「槽位索引 == data 索引」和「视图名 == 数据名」两条约定，只重绑 data 而不补洞 / 不改名，
## 会让视图与模型数组（如 Actor.card.cards）错位，表现为卖出/购买后卡牌显示顺序错乱。
## 复用已有视图实例（只改 data / name），不重建节点，避免闪烁。
func resync_views():
	_resize_views()
	for i in views.size():
		var item = data[i] if (data and i < data.size()) else null
		var view = views[i]
		if item == null:
			if is_instance_valid(view):
				_free_slot(i)
			continue
		if is_instance_valid(view) and "data" in view:
			if view.data != item:
				view.data = item
			view.name = ArrayViewTool.get_item_name(item)
		else:
			if is_instance_valid(view):
				_free_slot(i)
			_set_slot_view(i, item)
	_update_slot_visibility()

func refresh_item(item) -> Node3D:
	_resize_views()
	## 已有视图显示该数据：同步视图名后直接返回
	for i in views.size():
		var v = views[i]
		if is_instance_valid(v) and "data" in v and v.data == item:
			v.name = ArrayViewTool.get_item_name(item)
			return v
	## data 中已收录该项（如"买重复卡 → 升级替换"会 erase 后 insert 回中间）：
	## 必须按 data 重新对齐，否则新物品会被塞进第一个空槽（末尾），与模型顺序不一致
	var idx: int = data.find(item) if data else -1
	if idx >= 0:
		resync_views()
		if idx < views.size() and is_instance_valid(views[idx]):
			return views[idx]
	## 兜底：data 未收录该项（独立调用）→ 放到第一个空槽
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
	## 补洞：删除后必须重新对齐，否则槽位索引与 data 索引错位
	resync_views()

func set_item(index: int, item) -> Node3D:
	_resize_views()
	var slot_nodes := get_children()
	if index < 0 or index >= slot_nodes.size():
		return null
	var view = _set_slot_view(index, item)
	_update_slot_visibility()
	return view

func remove_item(item):
	if item == null:
		return
	_resize_views()
	## 按「视图当前显示的数据」定位，而不是按视图名 —— 拖拽排序只重绑 data、名字会滞后，
	## 按名字匹配会释放错槽位（表现为卖掉的卡还在显示、其它卡消失）
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and "data" in view and view.data == item:
			_free_slot(i)
			break
	## 释放后重新对齐（补洞 + 同步视图名），保证 views[i] 与 data[i] 一一对应
	resync_views()

func get_item_position(item) -> Vector3:
	_resize_views()
	for i in views.size():
		var view = views[i]
		if is_instance_valid(view) and "data" in view and view.data == item:
			return view.global_position
	printerr(self, "  无法获取位置 ", item)
	return Vector3.ZERO
