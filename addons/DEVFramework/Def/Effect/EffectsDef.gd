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
	## 用单空格 join（跳过空描述）：
	## 原来逐个 `+= desc + " "` 会留下尾随空格，子效果描述自身带前导/尾随空格时
	## 还会拼出双空格（如「获得2格挡  重复2次」）
	var parts: PackedStringArray = []
	for effect in effects:
		if effect == null:
			continue
		var part: String = str(effect.get_desc(data)).strip_edges()
		if part.is_empty():
			continue
		parts.append(part)
	return " ".join(parts)
