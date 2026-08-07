class_name EffectResult extends RefCounted

var def: EntityDef
var value: int
var next: EffectResult

func _init(value_def: EntityDef, effect_value) -> void:
	if not value_def:
		LogTool.error("效果", "def 为空")
	def = value_def
	value = effect_value

func _to_string() -> String:
	return str(def, ' ', value, ' ', next)
