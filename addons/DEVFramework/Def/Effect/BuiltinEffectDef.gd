@tool
class_name BuiltinEffectDef extends EffectDef

@export_multiline var zh_desc: String:
	set(value):
		var def := get_root_def()
		if def:
			def._set_zh(str(def.name, '_desc'), value)
	get():
		var def := get_root_def()
		return def._get_zh(str(def.name, '_desc')) if def else super._to_string()

func apply(_data):
	pass

func revert(_data):
	pass

func _to_string() -> String:
	var def := get_root_def()
	if def:
		return tr(str(def.name, '_desc'))
	else:
		return super._to_string()
