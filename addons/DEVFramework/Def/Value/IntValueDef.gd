@tool
class_name IntValueDef extends ValueDef

@export var value: int = 1

func get_float(_data) -> float:
	return value

func _to_string():
	return str(value)
