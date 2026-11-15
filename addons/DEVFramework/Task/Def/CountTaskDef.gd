@tool
## 计数任务定义 — signals 为"计数信号"(任一触发 +1), 累计到 required 即完成("击杀 5 只怪")。
class_name CountTaskDef extends SignalTaskDef

## 目标数量(下限 1)
@export var required: int = 1:
	set(value):
		required = maxi(value, 1)

func create_entity() -> Task:
	return CountTask.new(self)
