@tool
class_name SubtractValueDef extends ValueDef

@export var value: ValueDef
@export var subtrahend: ValueDef

func get_float(data) -> float:
    return value.get_float(data) - subtrahend.get_float(data)

func _to_string():
    return str(value, "-", subtrahend)
