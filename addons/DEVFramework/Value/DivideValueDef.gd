@tool
class_name DivideValueDef extends ValueDef

## 除法计算: value / divisor, 作为公式节点用(可嵌套其它 ValueDef)。
## 与 FractionValueDef 的区别: 这个是"算一个除法", 除零按极限给 ±INF; 那个是"表示分数/比例", 除零回 0。
## 两者语义不同, 不要互相替代。

@export var value: ValueDef
@export var divisor: ValueDef

func get_float(data) -> float:
	var v := value.get_float(data)
	var d := divisor.get_float(data)
	if d == 0:
		return INF if v > 0 else -INF if v < 0 else 0
	return v / d

func _to_string():
	return str(value, "/", divisor)
