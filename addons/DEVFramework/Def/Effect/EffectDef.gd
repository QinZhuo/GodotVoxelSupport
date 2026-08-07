@tool
@abstract class_name EffectDef extends Def

@abstract func apply(context)

func revert(context):
	printerr("cannot revert ", self)

func get_desc(context) -> String:
	return _to_string()

func _to_string() -> String:
	return get_script().get_global_name()

func find_effect(condition: Callable) -> EffectDef:
	if condition.call(self):
		return self
	if "effect" in self and self.get("effect") is EffectDef:
		return self.effect.find_effect(condition)
	if "effects" in self and self.get("effects") is Array:
		for e in self.effects:
			var result: EffectDef = e.find_effect(condition)
			if result:
				return result
	return null
