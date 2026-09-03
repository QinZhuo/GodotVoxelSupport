@tool
## 信号任务定义 — 由 signals 驱动，任一信号触发时自动完成。
class_name SignalTaskDef extends TaskDef

## 触发信号列表（任一触发即完成）
@export var signals: Array[SignalDef]

func create_entity() -> Task:
	return SignalTask.new(self)
