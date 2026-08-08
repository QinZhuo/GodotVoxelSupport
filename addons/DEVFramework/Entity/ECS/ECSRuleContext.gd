class_name ECSRuleContext
extends RefCounted

## 声明规则上下文 —— 用"遍历→条件→动作"链式声明规则, C++ 批量执行。
##
## 用法(在 ECSRule._define 中):
##   ctx.for_each(HealthComponent)          # 遍历所有有 Health 的实体
##       .where(&"hp").less_than(50)        # 条件: hp < 50
##       .add(&"hp", 10)                    # 动作: hp + 10
##       .execute()                         # 执行(可省略, 链尾自动执行)

var world: ECSWorld = null
var _queries: Array = []  # 本规则定义过程中创建的所有查询(供自动执行)

func _init(p_world: ECSWorld = null) -> void:
	world = p_world


## 开始声明规则: 遍历所有拥有 anchor 组件的实体
func for_each(anchor) -> ECSRuleQuery:
	# 用 load 实例化查询构建器(规避全局类 .new() 的解析问题)
	var q = load("res://addons/DEVFramework/Entity/ECS/ECSRuleQuery.gd").new()
	q._init_rule(world, anchor)
	_queries.append(q)
	return q


## 执行本规则定义的所有查询(由 ECSRule._execute 在 _define 后调用)。
func _execute_all() -> int:
	var total := 0
	for q in _queries:
		total += q.execute()
	return total
