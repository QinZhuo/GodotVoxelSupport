class_name GoapGoal extends Entity

## GOAP 目标实例 — 由 GoapGoalDef 创建，表示一个"想要达到的世界状态"。

var def: GoapGoalDef


static func create(goal_def: GoapGoalDef) -> GoapGoal:
	return goal_def.create_entity()


## 目标是否处于激活状态（复用框架 ConditionDef，context 为 Agent）
func is_active(agent: GoapAgent) -> bool:
	if def.active_condition:
		return def.active_condition.is_met(agent)
	return true


func get_priority() -> int:
	return def.priority
