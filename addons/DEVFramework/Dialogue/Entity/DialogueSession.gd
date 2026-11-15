## 一次对话的运行实例：游标 + 推进。只发信号，不碰 UI。
class_name DialogueSession extends RefCounted

signal line_changed(line: DialogueLineDef, index: int)
signal finished
signal cancelled

var dialogue: DialogueScriptDef
var index := -1
var running := false
## 透传给 view 的上下文（如 actor / step / quest …）
var context := {}


func _init(dialogue_script: DialogueScriptDef = null) -> void:
	dialogue = dialogue_script


func start(ctx: Dictionary = {}) -> bool:
	if dialogue == null or dialogue.is_empty():
		return false
	context = ctx
	index = 0
	running = true
	line_changed.emit(current(), index)
	return true


func current() -> DialogueLineDef:
	if dialogue == null or index < 0 or index >= dialogue.lines.size():
		return null
	return dialogue.lines[index]


## 下一行；没有下一行则结束并返回 false
func next() -> bool:
	if not running:
		return false
	index += 1
	if dialogue != null and index < dialogue.lines.size():
		line_changed.emit(current(), index)
		return true
	if dialogue != null and dialogue.loop and not dialogue.is_empty():
		index = 0
		line_changed.emit(current(), index)
		return true
	running = false
	finished.emit()
	return false


func cancel() -> void:
	if running:
		running = false
		cancelled.emit()
