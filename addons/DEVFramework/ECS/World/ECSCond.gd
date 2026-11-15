class_name ECSCond
extends RefCounted

## 规则条件构建器 —— 由 ECSQuery.where() 创建。
## 使 ECSQuery 能在唯一写入处失效"规范化条件"缓存(避免跨帧复用陈旧条件)。

var _query: ECSQuery
var _field: StringName


func _init(p_query: ECSQuery, p_field: StringName) -> void:
	_query = p_query
	_field = p_field


func less_than(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.LESS_THAN, value)


func less_or_equal(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.LESS_OR_EQUAL, value)


func greater_than(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.GREATER_THAN, value)


func greater_or_equal(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.GREATER_OR_EQUAL, value)


func equal(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.EQUAL, value)


func not_equal(value) -> ECSQuery:
	return _query.where_cond(_field, ECSWorld.CondOp.NOT_EQUAL, value)
