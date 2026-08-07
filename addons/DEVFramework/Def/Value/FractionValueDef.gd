@tool
class_name FractionValueDef extends ValueDef

@export var numerator: ValueDef
@export var denominator: ValueDef

func get_float(data) -> float:
	var denom := denominator.get_float(data)
	if denom == 0:
		return 0
	return numerator.get_float(data) / denom

func get_desc(data) -> String:
	return str(numerator.get_desc(data), '/', denominator.get_desc(data))

func _to_string():
	return str(numerator, '/', denominator)
