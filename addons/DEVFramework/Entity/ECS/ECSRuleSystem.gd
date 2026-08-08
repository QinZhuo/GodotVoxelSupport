class_name ECSRuleSystem
extends ECSSystem

## 规则系统 —— 把声明规则(ECSRule)作为系统注册进世界, 每帧执行。
## 一个规则系统可以驱动多个规则。

## 本系统驱动的规则列表
var rules: Array[ECSRule] = []


## 添加规则(返回 self 支持链式)
func add_rule(rule: ECSRule) -> ECSRuleSystem:
	if rule != null and not rules.has(rule):
		rules.append(rule)
	return self


func required_components() -> Array[Script]:
	var comps: Array[Script] = []
	for r in rules:
		for c in r.required_components():
			if not comps.has(c):
				comps.append(c)
	return comps


func _run(ctx: ECSSystemContext, _delta: float) -> void:
	for rule in rules:
		rule._execute(ctx.world)
