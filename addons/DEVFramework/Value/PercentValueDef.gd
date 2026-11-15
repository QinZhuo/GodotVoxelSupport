@tool
class_name PercentValueDef extends ValueDef

@export var value: ValueDef
@export var percent: ValueDef

func get_float(data) -> float:
	var percent_val := percent.get_float(data)
	percent_val = ceili(percent_val / 10.0) * 10.0
	var float_value: float = 1 if not value else value.get_float(data)
	return float_value * percent_val / 100.0

func get_desc(data) -> String:
	var percent_val := percent.get_float(data)
	percent_val = ceili(percent_val / 10.0) * 10.0
	if value:
		return str(int(percent_val), "%", value.get_desc(data))
	return str(int(percent_val), "%")

func _to_string():
	if value:
		return str(percent, "%", value)
	return str(percent, "%")
