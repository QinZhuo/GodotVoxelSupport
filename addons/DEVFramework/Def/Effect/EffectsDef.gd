@tool
class_name EffectsDef extends EffectDef

@export var effects: Array[EffectDef]

func apply(data):
	for effect in effects:
		await effect.apply(data)

func revert(data):
	# 逆序回滚(undo 栈 LIFO 语义): apply 正序叠加的状态必须倒序撤销才可逆
	for i in range(effects.size() - 1, -1, -1):
		await effects[i].revert(data)

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
