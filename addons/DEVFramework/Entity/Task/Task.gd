@abstract
## 任务实体抽象基类。子类：SignalTask（信号驱动）、GroupTask（分组）。
class_name Task extends Entity

var def: TaskDef:
	set(value):
		def = value
		entity_changed.emit()

signal completed()

var is_completed: bool = false

var _data
var _handler: Callable
var _active: bool = false


static func create(task_def: TaskDef) -> Task:
	return task_def.create_entity()

## 激活（子类覆写具体逻辑）
func activate(data) -> void:
	if _active:
		deactivate()
	_active = true
	_data = data

## 停用
func deactivate() -> void:
	if not _active:
		return
	_active = false
	if _handler.is_valid():
		_handler = Callable()

## 手动完成
func complete() -> void:
	if is_completed:
		return
	is_completed = true
	deactivate()
	completed.emit()

## 当前描述的文本
func get_current_desc() -> String:
	return def.get_desc(null)

## 序列化
func save_data() -> Dictionary:
	return {def = def.name, is_completed = is_completed}

## 反序列化
func load_data(dict: Dictionary) -> void:
	is_completed = dict.get("is_completed", false)
