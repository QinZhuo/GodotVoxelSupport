@tool
class_name AddValueDef extends ValueDef

@export var value: ValueDef
@export var addend: ValueDef

func get_float(data) -> float:
	return value.get_float(data) + addend.get_float(data)

func get_desc(data) -> String:
	return str(value.get_desc(data), '+', addend.get_desc(data))

func _to_string():
	return str(value, '+', addend)
