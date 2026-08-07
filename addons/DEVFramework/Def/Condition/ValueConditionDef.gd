@tool
class_name ValueConditionDef extends ConditionDef

@export var value: ValueDef

@export var target: ValueDef

@export var mode: Mode

enum Mode {
	Equal,
	NotEqual,
	Greater,
	Less,
	GreaterEqual,
	LessEqual,
}

func is_met(context) -> bool:
	if value == null or target == null:
		return false

	var value_data := value.get_int(context)
	var target_data = target.get_int(context)

	match mode:
		Mode.Equal:
			return value_data == target_data
		Mode.NotEqual:
			return value_data != target_data
		Mode.Greater:
			return value_data > target_data
		Mode.Less:
			return value_data < target_data
		Mode.GreaterEqual:
			return value_data >= target_data
		Mode.LessEqual:
			return value_data <= target_data
		_:
			return false

func _to_string() -> String:
	match mode:
		Mode.Equal:
			return str(value, '=', target)
		Mode.NotEqual:
			return str(value, '!=', target)
		Mode.Greater:
			return str(value, '>', target)
		Mode.Less:
			return str(value, '<', target)
		Mode.GreaterEqual:
			return str(value, '>=', target)
		Mode.LessEqual:
			return str(value, '<=', target)
		_:
			return ''
