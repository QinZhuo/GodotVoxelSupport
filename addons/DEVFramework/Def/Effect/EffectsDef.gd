@tool
class_name EffectsDef extends EffectDef

@export var effects: Array[EffectDef]

func apply(data):
	for effect in effects:
		await effect.apply(data)

func revert(data):
	for effect in effects:
		await effect.revert(data)

func _to_string():
	var effects_str: String = ""
	for effect in effects:
		effects_str += str(effect) + " "
	return effects_str

func get_desc(data) -> String:
	var effects_str: String = ""
	for effect in effects:
		if effect:
			effects_str += effect.get_desc(data) + " "
	return effects_str
