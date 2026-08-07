class_name GoapAction extends Entity

## GOAP 行动实例 — 由 GoapActionDef 通过 create_entity() 创建。
## 每次规划都会创建一批新的行动实例（RefCounted，轻量），
## 生命周期由 GoapAgent 管理。
##
## 生命周期: begin(agent) -> execute(agent) -> end(agent)
##   - begin(): 行动开始前调用，可覆写做初始化（如绑定目标引用）
##   - execute(): 触发执行逻辑（配置的 perform_method）
##   - end():    行动结束(成功/失败/中断)后必定调用，负责清理资源。
##               框架在此自动清空 target，防止目标引用残留导致
##               "世界状态与实际世界脱节 -> replan 死循环"。

var def: GoapActionDef
var _performing := false

## 行动目标上下文（如要走向的草、要追踪的猎物）。由 begin() 设置，
## end() 时框架自动清空。规划时用世界状态描述需求，执行时用此引用
## 绑定真实对象，二者由 Agent 负责保持一致。
var target: Object = null


static func create(action_def: GoapActionDef) -> GoapAction:
	return action_def.create_entity()


## 运行时检查：前提是否满足 + 附加条件（condition）是否通过
func can_run(world_state: GoapWorldState, agent: GoapAgent) -> bool:
	if not world_state.matches(def.preconditions):
		return false
	if def.condition:
		return def.condition.is_met(agent)
	return true


func get_cost() -> float:
	return def.cost


## 行动开始钩子：框架会先调用 agent.begin_<行动名>(action)（若存在，用于绑定目标
## 等初始化），再触发执行。约定: perform_method 形如 "perform_find_food"，对应的
## begin 方法为 "begin_find_food"（去掉 perform_ 前缀）。基类无需覆写; end() 负责清理。
func begin(agent: GoapAgent) -> void:
	_performing = true
	if def.perform_method.is_empty():
		return
	var short_name := def.perform_method.trim_prefix("perform_")
	var begin_method := "begin_" + short_name
	if agent.has_method(begin_method):
		agent.call(begin_method, self)


## 触发执行。
## 无 perform_method      → 纯配置行动，直接完成并应用 effects
## perform_method 返回 bool → 同步完成 / 同步失败（方法应声明 -> bool）
## perform_method 返回 null → 异步，等待 agent.notify_action_finished(success)
##                            （异步方法请声明 -> Variant 或不声明返回类型）
func execute(agent: GoapAgent) -> void:
	_performing = true
	if def.perform_method.is_empty():
		agent.notify_action_finished(true)
		return
	var result = agent.call(def.perform_method, self)
	if result is bool:
		agent.notify_action_finished(result)


## 行动结束钩子：无论成功 / 失败 / 中断都必定调用（由 GoapAgent 统一触发）。
## 可覆写做清理；基类默认清空 target 引用，防止失效对象被长期持有。
func end(_agent: GoapAgent) -> void:
	_performing = false
	target = null


## 行动成功后，把 effects 应用到世界状态
func apply_effects(world_state: GoapWorldState) -> void:
	world_state.apply(def.effects)
