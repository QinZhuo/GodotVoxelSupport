@tool
class_name ContentEntryDef extends Resource
## 加权表项 — 内容生成的基础单元（可放物品 / 事件 / 怪物等任意条目）

@export var name := "条目"
@export_range(0.0, 1000.0, 0.1) var weight := 1.0

func _to_string() -> String:
	return name
