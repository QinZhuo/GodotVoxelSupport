## 信号任务实体 — 由 SignalTaskDef 驱动，任一信号触发即完成。
class_name SignalTask extends Task

## 激活后接入完成信号监听
func activate(data) -> void:
	super(data)
	if is_active:
		_connect_signals(data)

## 断开全部信号监听并清掉回调
func _teardown() -> void:
	if _handler.is_valid() and def is SignalTaskDef:
		for s in (def as SignalTaskDef).signals:
			if s:
				s.disconnect_signal(_data, _handler)
	_handler = Callable()

## 读档后重建信号监听(存档状态为 ACTIVE 且已有上下文时)
func _resume_from_save() -> void:
	if _status == TaskDef.Status.ACTIVE and _data != null:
		_connect_signals(_data)

func _connect_signals(data) -> void:
	var task_def := def as SignalTaskDef
	if not task_def or task_def.signals.is_empty():
		return
	# 兼容任意参数宽度的信号：无参(如 Button.pressed)、单参(自定义 data 回调)、
	# 或多参(如 card_levelup_requested(card, options)) 均可，多余实参由 rest 兜底收集。
	_handler = func(_signal_data = null, ..._extra):
		if not is_active or is_completed:
			return
		complete()
	for s in task_def.signals:
		if s:
			s.connect_signal(data, _handler)
