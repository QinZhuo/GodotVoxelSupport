@tool
@abstract class_name ValueDef extends Def

@abstract func get_float(data) -> float

func get_int(data) -> int:
	return ceili(get_float(data))

func get_desc(data) -> String:
	return str(get_int(data))

@abstract func _to_string() -> String
