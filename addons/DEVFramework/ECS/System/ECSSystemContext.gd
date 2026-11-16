class_name ECSSystemContext
extends RefCounted

## 系统执行上下文 —— 系统内部访问世界数据的唯一通道。

var world: ECSWorld
var _pending: Array = []   # 本系统创建的查询(系统 _run 结束后自动执行未显式 execute 的)
var _query_pool: Array = []  # 查询对象池(复用, 免每帧 new/load ECSQuery)
var _pool_idx := 0


func _init(p_world: ECSWorld) -> void:
	world = p_world

## 单实体读写(低频路径, 避免在循环内使用)
func get_field(entity: int, component, field: StringName):
	return world.get_field(entity, component, field)

func set_field(entity: int, component, field: StringName, value) -> void:
	world.set_field(entity, component, field, value)

## 投递事件(帧末统一派发, 同 world.emit_event)
func emit_event(type: StringName, payload = null) -> void:
	world.emit_event(type, payload)

## 统一查询链入口(与 ECSQuery 同一套遍历→条件→动作构建器)。
func for_each(anchor, must: Array = [], without: Array = []) -> ECSQuery:
	# 查询对象池复用: 系统 _run 每帧构建的查询链结构固定, 复用对象免 new/load 开销
	var q: ECSQuery
	if _pool_idx < _query_pool.size():
		q = _query_pool[_pool_idx]
		q._reset(world, anchor, must, without)
	else:
		q = load("res://addons/DEVFramework/ECS/System/ECSQuery.gd").new()
		q._init_rule(world, anchor, must, without)
		_query_pool.append(q)
	_pool_idx += 1
	_pending.append(q)
	return q

## 批量收集便捷: 单次遍历匹配实体同时判定多组条件, 返回各行集(Array[PackedInt32Array])。
func collect_batch(anchor, groups: Array, must: Array = [], without: Array = []) -> Array:
	return world.batch_collect(anchor, must, without, groups)

## 对行集做标量动作(跳过收集)。rows 来自 collect_batch(anchor 行号)。
func apply_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float) -> int:
	return world.batch_apply_rows(anchor, rows, op_comp, op_field, op, factor, addend)

## 对行集做列间动作(跳过收集)。rows 来自 collect_batch(anchor 行号)。
func apply_col_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		src_comp, src_field: StringName, op: int, factor: float, addend: float) -> int:
	return world.batch_apply_col_rows(anchor, rows, op_comp, op_field, src_comp, src_field, op, factor, addend)

## 系统 _run 结束后由 ECSWorld 调用: 自动执行本系统未显式 execute 的查询。
func _auto_execute() -> void:
	if _pending.is_empty():
		return
	# 按 (anchor, must, without) 分组
	var groups := {}
	for q in _pending:
		if q == null or q._executed:
			continue
		var key := "%s|%s|%s" % [q._comp_name(q.anchor), str(q.must), str(q.without)]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(q)
	for key in groups:
		var qs: Array = groups[key]
		# 无条件查询(conds 空)用缓存全量行集; 条件查询走 batch_collect 一次收集
		var uncond: Array = []
		var cond_qs: Array = []
		for q in qs:
			if q.conditions.is_empty():
				uncond.append(q)
			else:
				cond_qs.append(q)
		if not uncond.is_empty():
			# 走统一的行集入口(带 must/without): 原来用"无条件全量行集"会忽略 must,
			# 让带 must 但无条件的查询也遍历全部 anchor 行。
			var rows: PackedInt32Array = world.query_rows(qs[0].anchor, qs[0].must, qs[0].without)
			for q in uncond:
				q._apply_rows(rows)
		if not cond_qs.is_empty():
			var conds_groups: Array = []
			for q in cond_qs:
				conds_groups.append(q.get_norm_conditions())
			var rowsets: Array = world.batch_collect_norm(qs[0].anchor, qs[0].must, qs[0].without, conds_groups)
			for i in cond_qs.size():
				cond_qs[i]._apply_rows(rowsets[i])
	_pending.clear()
	_pool_idx = 0
