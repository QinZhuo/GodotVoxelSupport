## 计数任务实体 — 由 CountTaskDef 驱动: 信号累加计数, 达到目标数量完成。
class_name CountTask extends SignalTask

var _count: int = 0


func get_progress() -> Vector2i:
	return Vector2i(_count, get_required())

func get_current_desc() -> String:
	return str(def.get_desc(null), " (%d/%d)" % [_count, get_required()])

## 目标数量(Def 缺失时兜底 1)
func get_required() -> int:
	var task_def := def as CountTaskDef
	return task_def.required if task_def else 1

## 重置计数(可重复任务用)
func reset() -> void:
	_count = 0
	super()
	progress_changed.emit()

func save_data() -> Dictionary:
	var dict := super()
	dict["count"] = _count
	return dict

func load_data(dict: Dictionary, data = null) -> void:
	_count = maxi(int(dict.get("count", 0)), 0)
	super(dict, data)
	progress_changed.emit()


## 触发回调: 任一信号触发 +1, 达到 required 即完成(连接/断开复用基类)
func _make_handler() -> Callable:
	return func(_signal_data = null, ..._extra):
		if not is_active:
			return
		_count += 1
		progress_changed.emit()
		if _count >= get_required():
			complete()
