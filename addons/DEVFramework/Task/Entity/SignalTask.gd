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
	# 必须用局部 handler: 连第一个信号就可能"状态兜底"立即回调→完成→_teardown 清空 _handler,
	var handler := _make_handler()
	_handler = handler
	for s in task_def.signals:
		if s == null:
			continue
		s.connect_signal(data, handler)
		if not is_active:
			break   # 连接期已触发完成, 剩余信号不必再连

## 触发回调(子类覆写)。
func _make_handler() -> Callable:
	return func(_signal_data = null, ..._extra):
		if not is_active:
			return
		complete()
