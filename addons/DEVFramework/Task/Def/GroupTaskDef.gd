@tool
## 分组任务定义 — 管理多个子任务的顺序/并行完成。
class_name GroupTaskDef extends TaskDef

## 完成模式
enum Mode {
	SEQUENTIAL, ## 子任务按顺序逐一完成
	ANY_ORDER, ## 子任务任意顺序完成，全部完成才结束
	COMPLETE_ANY, ## 任意一个子任务完成即结束
}

## 子任务列表
@export var tasks: Array[TaskDef]
## 完成模式
@export var mode: Mode = Mode.SEQUENTIAL

func create_entity() -> Task:
	return GroupTask.new(self)

func get_desc(_data) -> String:
	var descs: PackedStringArray = []
	for task in tasks:
		var d := task.get_desc(_data)
		if not d.is_empty():
			descs.append(d)
	return "\n".join(descs)
