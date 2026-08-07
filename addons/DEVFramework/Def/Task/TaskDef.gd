@tool
@abstract
## 任务定义抽象基类。子类：SignalTaskDef（信号驱动）、GroupTaskDef（分组）。
class_name TaskDef extends EntityDef

## 创建对应的任务实体
@abstract func create_entity() -> Task

func get_desc(_data) -> String:
	return tr(str(name, "_desc"))

func _to_string() -> String:
	return str(tr(name),get_desc(null))

func get_csv_path() -> String:
	return "res://Assets/Translation/task.csv"
