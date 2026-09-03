@tool
## 计数任务定义 — signals 为"计数信号"(任一触发 +1), 累计到 required 即完成("击杀 5 只怪")。
##
## required == 1 时与 SignalTaskDef 等价(信号即完成)。
## 需要条件计数(只统计满足条件的触发)时, 把 signals 配成 ConditionSignalDef —— 条件基于
## activate 传入的上下文求值, 不满足的触发不计入。
## 进度: CountTask.get_progress() → (当前, required); 每次累加发 progress_changed。
class_name CountTaskDef extends SignalTaskDef

## 目标数量(下限 1)
@export var required: int = 1:
	set(value):
		required = maxi(value, 1)

func create_entity() -> Task:
	return CountTask.new(self)
