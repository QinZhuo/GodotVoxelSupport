@tool
class_name GoapGoalDef extends EntityDef

## GOAP 目标定义 — 期望达到的世界状态 + 优先级。

@export var goal_state: Dictionary = {}
@export_range(0, 100) var priority: int = 1
@export var active_condition: ConditionDef


func get_desc(_data) -> String:
	var s := tr(name)
	if not goal_state.is_empty():
		s += "\n目标状态: " + str(goal_state)
	return s


func create_entity() -> GoapGoal:
	return GoapGoal.new(self)
