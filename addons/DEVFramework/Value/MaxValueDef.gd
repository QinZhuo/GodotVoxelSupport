@tool
class_name MaxValueDef extends ValueDef

@export var a: ValueDef
@export var b: ValueDef

func get_float(data) -> float:
    return max(a.get_float(data), b.get_float(data))

func _to_string():
    return str("max(", a, ",", b, ")")
