@tool
class_name GoapGoalDef extends EntityDef

## GOAP 目标定义 — 期望达到的世界状态 + 优先级。
## goal_state：达成该目标时世界状态需满足的键值对
## priority：  优先级（越大越优先）。Agent 按优先级从高到低尝试，第一个能规划出
##             行动序列的目标被选中
## active_condition：可选的激活条件（复用框架 ConditionDef），不满足时该目标被跳过

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
