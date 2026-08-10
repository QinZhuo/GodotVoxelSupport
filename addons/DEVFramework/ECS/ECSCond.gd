class_name ECSCond
extends RefCounted

## 规则条件构建器 —— 由 ECSQuery.where() 创建。
## 选择比较操作符后返回所属查询, 继续链式调用。

var _query: ECSQuery
var _field: StringName


func _init(p_query: ECSQuery, p_field: StringName) -> void:
	_query = p_query
	_field = p_field


func less_than(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.LESS_THAN, "value": value})
	return _query


func less_or_equal(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.LESS_OR_EQUAL, "value": value})
	return _query


func greater_than(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.GREATER_THAN, "value": value})
	return _query


func greater_or_equal(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.GREATER_OR_EQUAL, "value": value})
	return _query


func equal(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.EQUAL, "value": value})
	return _query


func not_equal(value) -> ECSQuery:
	_query.conditions.append({"comp": _query.anchor, "field": _field,
			"op": ECSWorld.CondOp.NOT_EQUAL, "value": value})
	return _query
