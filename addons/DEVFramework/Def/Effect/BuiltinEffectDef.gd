@tool
class_name BuiltinEffectDef extends EffectDef

## 翻译描述(从翻译文件读取, 不存储)
@export_multiline var tr_desc: String:
	get():
		var def := get_root_def()
		return tr(str(def.name, '_desc')) if def else super._to_string()

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
