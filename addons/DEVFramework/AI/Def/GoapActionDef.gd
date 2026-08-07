@tool
class_name GoapActionDef extends EntityDef

## GOAP 行动定义 — 静态配置，用 .tres 或代码创建。
##
## preconditions：执行前世界状态必须满足的条件（键值对）
## effects：      执行成功后对世界状态产生的影响（键值对）
## cost：         执行代价，规划器会寻找总代价最小的行动序列
## perform_method：Agent 上执行该行动的方法名。方法签名：
##                 func 方法名(action: GoapAction) -> bool     （同步）
##                 func 方法名(action: GoapAction) -> Variant  （异步）
##                 返回 true    → 同步完成
##                 返回 false   → 同步失败（触发重新规划）
##                 返回 null    → 异步执行，稍后调用 agent.notify_action_finished(success)
##                 留空        → 纯配置行动：直接应用 effects 并完成（适合回合制/抽象逻辑）

@export var preconditions: Dictionary = {}
@export var effects: Dictionary = {}
@export_range(0.0, 100.0, 0.1) var cost: float = 1.0
@export var perform_method: String = ""
## 可选的运行时附加条件（复用框架 ConditionDef），如距离/冷却等动态判断
@export var condition: ConditionDef

## 描述中追加前提与效果，便于调试与展示
func get_desc(_data) -> String:
	var s := tr(name)
	if not preconditions.is_empty():
		s += "\n前提: " + str(preconditions)
	if not effects.is_empty():
		s += "\n效果: " + str(effects)
	return s


func create_entity() -> GoapAction:
	return GoapAction.new(self)
