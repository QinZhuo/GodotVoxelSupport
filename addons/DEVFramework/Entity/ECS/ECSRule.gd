class_name ECSRule
extends RefCounted

## 声明规则 —— 用"遍历→条件→动作"声明式定义数值逻辑, C++ 批量执行。
##
## 声明规则层(介于 原生API层 和 手写脚本层 之间):
##   - 比手写脚本层快(规则在 C++ 批量执行, 无 GDScript 循环)
##   - 比原生API层好读(声明式, 不用手拼 batch 参数)
##
## 用法:
##   class_name HealRule extends ECSRule:
##       func _define(ctx: ECSRuleContext) -> void:
##           ctx.for_each(HealthComponent)       # 遍历所有有血量的实体
##               .where(&"hp").less_than(50)     # 条件: hp < 50
##               .add(&"hp", 10)                 # 动作: hp + 10
##
##   world.register_rule(HealRule.new(), 10)     # 注册规则(自动每帧执行)

## 规则启停
var enabled: bool = true

## 本规则需要的组件(用于自动注册, 可覆写)
func required_components() -> Array[Script]:
	return []

## 定义规则逻辑(遍历→条件→动作)
func _define(_ctx: ECSRuleContext) -> void:
	pass


## 执行规则(由 ECSRuleSystem 调用)
func _execute(world: ECSWorld) -> void:
	if not enabled or world == null:
		return
	# 用 load 实例化上下文(规避全局类 .new() 的解析问题)
	var ctx = load("res://addons/DEVFramework/Entity/ECS/ECSRuleContext.gd").new()
	ctx.world = world
	_define(ctx)
	# 定义完自动执行所有查询(遍历→条件→动作)
	ctx._execute_all()
