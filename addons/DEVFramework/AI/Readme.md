# GOAP AI 模块

基于 **Goal-Oriented Action Planning（目标导向行为规划）** 思想的通用 AI 决策模块，
完全遵循 DEV Framework 的 Def / Entity / Component 三层模式，可挂接到任意游戏实体上。

## 核心概念

- **世界状态 (World State)**：`GoapWorldState` —— Agent 对世界认知的键值对集合，
  如 `{"has_wood": true, "wood_near": false}`。
- **目标 (Goal)**：`GoapGoalDef` —— 期望达到的世界状态 + 优先级。
- **行动 (Action)**：`GoapActionDef` —— 由 `前提(preconditions)`、`效果(effects)`、
  `代价(cost)` 构成，是规划的基本单元。
- **规划器 (Planner)**：`GoapPlanner` —— A* 反向搜索，从目标状态反推，
  找出从当前世界状态到达目标代价最小的行动序列。
- **智能体 (Agent)**：`GoapAgent` —— 挂在场景上的组件，驱动"选目标 → 规划 → 执行 →
  应用效果 → 重规划"的完整循环。

## 架构

```
addons/DEVFramework/AI/
├── GoapWorldState.gd          # 世界状态（数据容器）
├── Def/
│   ├── GoapActionDef.gd       # 行动定义（.tres 配置）
│   └── GoapGoalDef.gd         # 目标定义（.tres 配置）
├── Entity/
│   ├── GoapAction.gd          # 行动实例（由 Def 创建）
│   └── GoapGoal.gd            # 目标实例（由 Def 创建）
├── Tool/
│   └── GoapPlanner.gd         # A* 规划器（无状态，可复用）
└── Component/
    └── GoapAgent.gd           # 智能体组件（挂到 NPC 节点）
```

## 快速上手

### 1. 定义行动与目标（.tres 配置 或 代码创建）

用 .tres 创建 `GoapActionDef`，配置 `preconditions` / `effects` / `cost`：

```
[resource]
script = ExtResource("goap_action_def")
name = "寻找木材"
preconditions = {}
effects = {"wood_near": true}
cost = 1.0
perform_method = "perform_find_wood"
```

### 2. 挂载 Agent 并配置

场景中给角色节点添加 `GoapAgent`，在 `goals` / `actions` 数组中填入 Def 资源，
在 `perform_method` 指向的方法名对应的 `GoapAgent` 子类（或挂载脚本）中实现行为。

```gdscript
class_name RabbitAgent extends GoapAgent

func _ready_goap() -> void:
	# 代码方式配置（等价于在场景中配置数组）
	var goal := GoapGoalDef.new()
	goal.name = "填饱肚子"
	goal.priority = 20
	goal.goal_state = {"hungry": false}
	goals.append(goal)

	var action := GoapActionDef.new()
	action.name = "寻找食物"
	action.effects = {"has_food": true}
	action.cost = 1.0
	action.perform_method = "perform_find_food"
	actions.append(action)

	# 初始世界状态
	set_state("hungry", true)

# 同步行动：声明 -> bool，返回 true / false 表示完成 / 失败
func perform_find_food(_action: GoapAction) -> bool:
	return true

# 异步行动：声明 -> Variant，返回 null，完成后手动通知
func perform_walk_to_food(_action: GoapAction) -> Variant:
	get_tree().create_timer(1.0).timeout.connect(
		func(): notify_action_finished(true))
	return null
```

### 3. 与外部世界交互

```gdscript
# 世界状态变化（会自动触发重新规划）
agent.set_state("enemy_visible", true)

# 暂停 / 恢复
agent.paused = true

# 手动请求重新规划
agent.replan()
```

## 行动执行模式

`perform_method` 有三种返回值约定：

| 返回值 | 方法声明 | 含义 |
| --- | --- | --- |
| `true` | `-> bool` | 同步完成，自动应用 `effects` 并触发重规划 |
| `false` | `-> bool` | 同步失败，直接重新规划 |
| `null` | `-> Variant` 或不声明 | 异步执行，稍后调用 `agent.notify_action_finished(success)` |

`perform_method` 留空时，行动被当作"纯配置行动"：跳过执行逻辑，
直接应用 `effects` 并完成 —— 适合回合制、资源管理等抽象场景。

## 关键信号

| 信号 | 触发时机 |
| --- | --- |
| `plan_found(goal, plan)` | 找到可行计划 |
| `plan_failed(goal)` | 目标无法达成（返回空计划） |
| `action_started(action)` | 行动开始执行 |
| `action_finished(action, success)` | 行动结束 |
| `plan_completed(success)` | 整个计划结束 |
| `state_changed(key, value)` | 世界状态变化 |

## 扩展点

| 方法 | 用途 |
| --- | --- |
| `_ready_goap()` | 子类初始化（构建 Def / 初始世界状态） |
| `is_goal_active(goal)` | 覆写目标激活判断 |
| `sort_goals(goals)` | 覆写目标优先级排序 |
| `on_action_execute(action)` | `perform_method` 为空时的兜底钩子 |

## 参考实现

设计参考了经典 Tuts+ GOAP 教程与开源实现 godot-goap (viniciusgerevini)：
反向 A* 搜索 + 每行动完成后重规划（Replan-on-Change）模式。

## 内置演示

运行 `res://Scenes/AI/GoapDemo.tscn` 可查看完整示例（2D 生态箱）：
- 配置驱动：行动/目标全部定义在 `res://Assets/Def/Goap/Ecosystem/*.tres`
- 生物行为：
  - 兔（食草）：饥饿时觅食（寻找食物 → 走向食物 → 进食）
  - 狐（捕食）：饥饿时狩猎（寻找猎物 → 追踪猎物 → 捕食）
- 目标优先级：兔的「逃离危险（30）」>「填饱肚子（20）」，感知到狐狸时优先逃跑
- 世界状态驱动的动态重规划：感知 / 饥饿变化自动触发重新规划
- 被捕食的兔与被吃掉的草会在随机位置重生，生态持续运行
- 场景 UI 提供「暂停 / 加速 / 重置世界」调试按钮，日志实时显示每个 Agent 的目标与行动
