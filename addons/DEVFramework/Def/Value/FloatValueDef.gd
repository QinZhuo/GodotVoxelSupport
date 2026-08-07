@tool
class_name FloatValueDef extends ValueDef

@export var value: float = 1

func get_float(_data) -> float:
	return value

func _to_string():
	return str(value)
