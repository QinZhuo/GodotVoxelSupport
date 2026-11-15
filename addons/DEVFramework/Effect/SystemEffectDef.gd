@tool
## 系统内置效果：该 Def 的**行为由战斗系统按 Def 名称内置实现**，数据层不承载任何逻辑。
## 判别依据：能用「效果树」表达的效果不要用本类——数据驱动的效果请组合
class_name SystemEffectDef extends EffectDef

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
