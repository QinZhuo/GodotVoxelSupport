## 计数任务实体 — 由 CountTaskDef 驱动: 信号累加计数, 达到目标数量完成。
## 计数进度计入存档(save_data/load_data), 断点续玩不丢计数。
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


## 计数信号接入: 任一信号触发 +1, 达到 required 即完成(与 SignalTask 复用同一套断开逻辑)
func _connect_signals(data) -> void:
	var task_def := def as CountTaskDef
	if not task_def or task_def.signals.is_empty():
		return
	# 兼容任意参数宽度的信号(计数信号通常无参, 多余实参由 rest 兜底收集)
	_handler = func(_signal_data = null, ..._extra):
		if not is_active or is_completed:
			return
		_count += 1
		progress_changed.emit()
		if _count >= get_required():
			complete()
	for s in task_def.signals:
		if s:
			s.connect_signal(data, _handler)
