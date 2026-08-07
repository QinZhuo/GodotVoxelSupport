@tool
class_name MultiplyValueDef extends ValueDef

@export var value: ValueDef
@export var multiplier: ValueDef

func get_float(data) -> float:
	return value.get_float(data) * multiplier.get_float(data)

func get_desc(data) -> String:
	return str(value.get_desc(data), 'x', multiplier.get_desc(data))

func _to_string():
	return str(value, "×", multiplier)
