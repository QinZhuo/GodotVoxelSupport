class_name ECSRuleQuery
extends RefCounted

## 声明规则查询构建器 —— 链式: 遍历 → 条件 → 动作 → 执行。
## 由 ECSRuleContext.for_each() 创建, 用户不直接实例化。

var world: ECSWorld
var anchor  # 锚组件(Script 或类名)
var conditions: Array = []   # [{comp, field, op, value}]
var actions: Array = []      # [{type, field, amount/value, ...}]
var _executed := false


func _init(p_world: ECSWorld = null, p_anchor = null) -> void:
	world = p_world
	anchor = p_anchor


## 由 ECSRuleContext.for_each 经 ClassDB 实例化后调用(替代 _init 传参)
func _init_rule(p_world: ECSWorld, p_anchor) -> ECSRuleQuery:
	world = p_world
	anchor = p_anchor
	return self


# ---------- 条件(可多个, AND 语义) ----------

## 指定条件字段, 后续用 less_than / greater_than 等比较
func where(field: StringName) -> ECSRuleCond:
	return ECSRuleCond.new(self, field)

## 直接指定完整条件(等价 where().xxx())
func where_cond(field: StringName, op: int, value) -> ECSRuleQuery:
	conditions.append({"comp": anchor, "field": field, "op": op, "value": value})
	return self


# ---------- 动作(可多个, 顺序执行) ----------

## 动作: 给字段加值
func add(field: StringName, amount) -> ECSRuleQuery:
	actions.append({"type": "add", "field": field, "amount": amount})
	return self

## 动作: 给字段设置值(改名 set_value 避免与 Object.set 冲突)
func set_value(field: StringName, value) -> ECSRuleQuery:
	actions.append({"type": "set", "field": field, "value": value})
	return self


## 执行规则(返回处理实体数)。未显式调用时链尾自动执行。
func execute() -> int:
	if _executed:
		return _last_count
	_executed = true
	_last_count = _run()
	return _last_count


var _last_count := 0


func _run() -> int:
	if world == null:
		return 0
	var total := 0
	for act in actions:
		match act.type:
			"add":
				total += world.batch_add_value_if(anchor, [], anchor, act.field,
						act.amount, conditions)
			"set":
				total += world.batch_set_value_if(anchor, [], anchor, act.field,
						act.value, conditions)
	return total
