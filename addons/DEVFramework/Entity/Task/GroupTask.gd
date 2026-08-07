## 分组任务实体 — 由 GroupTaskDef 驱动，管理多个子任务完成。
class_name GroupTask extends Task

var _child_entities: Array[Task] = []
var _active_child_index: int = 0
var _completed_count: int = 0


func activate(data) -> void:
	super(data)
	if is_completed:
		return
	_activate_children(data)

func deactivate() -> void:
	for child in _child_entities:
		child.deactivate()
	super()

func get_current_desc() -> String:
	if _active_child_index < _child_entities.size():
		return _child_entities[_active_child_index].get_current_desc()
	return def.get_desc(null)

## 当前活跃子任务的 def
var active_child_def: TaskDef:
	get:
		var group := def as GroupTaskDef
		if not group or _active_child_index >= _child_entities.size():
			return null
		return group.tasks[_active_child_index]

## 当前活跃子任务实体
var active_child_entity: Task:
	get:
		if _active_child_index >= _child_entities.size():
			return null
		return _child_entities[_active_child_index]


func _activate_children(data) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	for i in group.tasks.size():
		var sub_def: TaskDef = group.tasks[i]
		var child := Task.create(sub_def)
		_child_entities.append(child)
		child.completed.connect(_on_child_completed.bind(i))
		if group.mode == GroupTaskDef.Mode.SEQUENTIAL and i > 0:
			continue
		child.activate(data)
		if group.mode == GroupTaskDef.Mode.COMPLETE_ANY:
			break

func _on_child_completed(child_index: int) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	_completed_count += 1
	match group.mode:
		GroupTaskDef.Mode.SEQUENTIAL:
			_active_child_index = child_index + 1
			if _active_child_index < _child_entities.size():
				_child_entities[_active_child_index].activate(_data)
			else:
				complete()
		GroupTaskDef.Mode.ANY_ORDER:
			if _completed_count >= _child_entities.size():
				complete()
		GroupTaskDef.Mode.COMPLETE_ANY:
			complete()
	entity_changed.emit()

func save_data() -> Dictionary:
	var dict: Dictionary = {
		def = def.name,
		is_completed = is_completed,
		children = [],
	}
	for child in _child_entities:
		dict.children.append(child.save_data())
	return dict

func load_data(dict: Dictionary) -> void:
	super(dict)
	var children: Array = dict.get("children", [])
	# 恢复子任务状态
	for i in children.size():
		if i < _child_entities.size():
			_child_entities[i].load_data(children[i])
	# 重新计算进度
	_completed_count = 0
	_active_child_index = 0
	for i in _child_entities.size():
		if _child_entities[i].is_completed:
			_completed_count += 1
			_active_child_index = i + 1
	# 快进到第一个未完成的任务
	if _active_child_index >= _child_entities.size():
		complete()
		return
	# 停用默认激活的子任务，激活正确的
	for child in _child_entities:
		child.deactivate()
	_child_entities[_active_child_index].activate(_data)
	entity_changed.emit()
