@tool
## 系统内置效果：该 Def 的**行为由战斗系统按 Def 名称内置实现**，数据层不承载任何逻辑。
##
## 典型使用者：block / magic_shield / dodge / charge / mana / nimble / luck /
## vulnerability / weakness 这类「系统资源型」Buff（吸收 / 闪避判定 / 回合末减半与清空 /
## 弹药消耗等行为散落在 FightComponent / Actor 等系统代码中，按名称硬编码），
## 以及符号 / 属性 / 装备里行为由系统处理的条目（如符号参与组合、属性驱动经济）。
##
## 因此 apply / revert **刻意为空**：数据层没有可执行的效果体，不存在 apply 的概念。
## 本类真正的职责只有一件事 —— 提供描述：从所属根 Def 的翻译键 <name>_desc
## 读取文本（buff.csv / symbol.csv / equip.csv 等各 Def 翻译表）。
##
## 判别依据：能用「效果树」表达的效果不要用本类——数据驱动的效果请组合
## 具体 EffectDef（可被描述、可被回放、可被 DesignAuditTool 审计）。
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
