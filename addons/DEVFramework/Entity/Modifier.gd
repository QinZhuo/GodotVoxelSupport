class_name Modifier extends RefCounted

enum Mode { VALUE, PERCENT }

var source
var value: int
var mode: Mode

func _init(p_source, p_value: int, p_mode: Mode = Mode.VALUE):
	source = p_source
	value = p_value
	mode = p_mode

func apply(base: int) -> int:
	match mode:
		Mode.VALUE:
			return base + value
		Mode.PERCENT:
			return base * value / 100
	return base

func _to_string():
	return "[Modifier src=%s val=%d mode=%d]" % [source, value, mode]
