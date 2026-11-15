@tool
## 一段对话 — 行数组 + 最小策略。
class_name DialogueScriptDef extends Resource

@export var lines: Array[DialogueLineDef] = []
## 播完是否从头再来
@export var loop := false


func is_empty() -> bool:
	return lines.is_empty()
