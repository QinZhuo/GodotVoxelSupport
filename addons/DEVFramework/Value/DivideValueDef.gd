@tool
class_name DivideValueDef extends ValueDef

@export var value: ValueDef
@export var divisor: ValueDef

func get_float(data) -> float:
    var v = value.get_float(data)
    var d = divisor.get_float(data)
    # 避免除零，可根据需要调整（此处返回 Infinity 或 0）
    if d == 0:
        return INF if v > 0 else -INF if v < 0 else 0
    return v / d

func _to_string():
    return str(value, "/", divisor)
