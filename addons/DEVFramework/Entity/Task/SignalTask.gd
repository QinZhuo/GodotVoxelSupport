## 信号任务实体 — 由 SignalTaskDef 驱动，任一信号触发即完成。
class_name SignalTask extends Task

func activate(data) -> void:
	super(data)
	if is_completed:
		return
	_connect_signals(data)

func deactivate() -> void:
	# 先断信号，再调父类清理 _handler
	if _handler.is_valid() and def is SignalTaskDef:
		var task_def := def as SignalTaskDef
		for s in task_def.signals:
			if s:
				s.disconnect_signal(_data, _handler)
	super()

func _connect_signals(data) -> void:
	var task_def := def as SignalTaskDef
	if not task_def or task_def.signals.is_empty():
		return
	_handler = func(_signal_data):
		if is_completed:
			return
		complete()
	for s in task_def.signals:
		if s:
			s.connect_signal(data, _handler)
