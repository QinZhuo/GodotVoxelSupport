@tool
class_name MinValueDef extends ValueDef

@export var a: ValueDef
@export var b: ValueDef

func get_float(data) -> float:
    return min(a.get_float(data), b.get_float(data))

func _to_string():
    return str("min(", a, ",", b, ")")
