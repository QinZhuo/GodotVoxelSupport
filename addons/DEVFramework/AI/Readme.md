# GOAP AI

目标导向行为规划：`GoapPlanner` 做反向 A*，从目标状态反推最小代价行动序列。遵循 Def / Entity / Component 三层模式。

## 怎么用

```gdscript
class_name RabbitAgent extends GoapAgent

func _ready_goap() -> void:      # 子类初始化：构建 Def + 初始世界状态
	var goal := GoapGoalDef.new()
	goal.name = "填饱肚子"
	goal.priority = 20
	goal.goal_state = {"hungry": false}
	goals.append(goal)

	var action := GoapActionDef.new()
	action.name = "寻找食物"
	action.effects = {"has_food": true}     # 还有 preconditions / cost / perform_method
	action.perform_method = "perform_find_food"
	actions.append(action)

	set_state("hungry", true)

func perform_find_food(_action: GoapAction) -> bool:
	return true                             # 同步完成

func perform_walk_to_food(_action: GoapAction) -> Variant:
	get_tree().create_timer(1.0).timeout.connect(func(): notify_action_finished(true))
	return null                             # 异步
```

```gdscript
agent.set_state("enemy_visible", true)   # 状态变化自动触发重新规划
agent.paused = true                      # 暂停/恢复
agent.replan()                           # 手动重规划
```

| `perform_method` 返回值 | 声明 | 含义 |
|---|---|---|
| `true` | `-> bool` | 同步完成，应用 `effects` 并重规划 |
| `false` | `-> bool` | 同步失败，直接重规划 |
| `null` | `-> Variant` 或不声明 | 异步，稍后必须调 `agent.notify_action_finished(success)` |

扩展点：`_ready_goap()` / `is_goal_active(goal)` / `sort_goals(goals)` / `on_action_execute(action)`。
信号：`plan_found` / `plan_failed` / `action_started` / `action_finished` / `plan_completed` / `state_changed`。

## 坑

1. `perform_method` 留空 = 纯配置行动：跳过执行逻辑，直接应用 `effects` 并完成。
2. 异步行动必须声明为 `-> Variant`（或不声明返回类型）并返回 `null`，完成后手动调 `notify_action_finished(success)`，否则智能体卡在该行动。
3. 演示：`res://Scenes/AI/GoapDemo.tscn`，配置在 `res://Assets/Def/Goap/Ecosystem/*.tres`。
