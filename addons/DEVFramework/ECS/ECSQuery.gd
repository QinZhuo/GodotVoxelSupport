class_name ECSQuery
extends RefCounted

## 统一查询链 —— 查询链(声明规则)与手写脚本系统共用的"遍历→条件→动作"构建器。
##
## 三种动作模式:
##   1. 标量声明动作(规则层, C++ batch 执行, 最快):
##        for_each(Comp).where(&"x").less_than(50).add(&"x", 10)   # 加
##        ...sub(...) / mul(...) / div(...) / set_value(...)       # 减/乘/除/赋值
##   2. 列间声明动作(规则层, C++ batch 执行, 列与列联动):
##        for_each(Comp).add_from(&"size", Comp, &"hp")             # size += hp
##        ...mul_from(...) / sub_from(...) / div_from(...) / set_from(...)
##        for_each(Comp).clamp_where(&"hp", Comp, &"min_hp", Comp, &"max_hp")
##   3. Callback 动作(手写层, GDScript 执行, 最灵活):
##        for_each(Comp).process(func(rows, data): ...)   # data 预拉列, 自动写回
## 手写层与规则层共享同一查询链: 组件匹配(must/without) + 条件(where) 完全一致。

var world: ECSWorld
var anchor  # 锚组件(Script 或类名)
var must: Array = []       # 必须同时拥有的组件
var without: Array = []    # 不得拥有的组件
var conditions: Array = []   # [{comp, field, op, value}]
var actions: Array = []      # [{type, ...}]
var _with_fields: Array = [] # with() 声明的锚组件遍历字段(顺序 = 回调参数顺序)
var _executed := false
var _norm_conds := []  # 规范化条件缓存(comp 已 resolve 类名, 免每帧 _normalize_conds; 条件固定时可跨帧复用)


func _init(p_world: ECSWorld = null, p_anchor = null) -> void:
	world = p_world
	anchor = p_anchor


## 由 ECSRuleContext / ECSSystemContext.for_each 实例化后调用。
func _init_rule(p_world: ECSWorld, p_anchor, p_must: Array = [], p_without: Array = []) -> ECSQuery:
	world = p_world
	anchor = p_anchor
	must = p_must
	without = p_without
	return self

## 查询对象池复用: 重置查询为可重新构建状态(清空动作/条件/遍历字段)。
func _reset(p_world: ECSWorld, p_anchor, p_must: Array = [], p_without: Array = []) -> void:
	world = p_world
	anchor = p_anchor
	must = p_must
	without = p_without
	conditions.clear()
	actions.clear()
	_with_fields.clear()
	_executed = false
	# 保留 _norm_conds 缓存(条件结构固定时跨帧复用, 免每帧 _normalize_conds)

## 规范化条件(comp 已 resolve 类名), 供批量收集/执行直接使用(首次构建缓存)。
func get_norm_conditions() -> Array:
	if conditions.is_empty():
		return []
	if _norm_conds.is_empty():
		_norm_conds = world._normalize_conds(conditions)
	return _norm_conds


# ---------- 条件(可多个, AND 语义) ----------

## 指定条件字段, 后续用 less_than / greater_than 等比较
func where(field: StringName) -> ECSCond:
	return ECSCond.new(self, field)

## 直接指定完整条件(等价 where().xxx())
func where_cond(field: StringName, op: int, value) -> ECSQuery:
	conditions.append({"comp": anchor, "field": field, "op": op, "value": value})
	return self


# ---------- 标量声明动作(规则层, C++ batch 执行) ----------

## 动作: 给字段加值
func add(field: StringName, amount) -> ECSQuery:
	actions.append({"type": "add", "field": field, "amount": amount})
	return self

## 动作: 给字段减量(等价 add(-amount))
func sub(field: StringName, amount) -> ECSQuery:
	actions.append({"type": "sub", "field": field, "amount": amount})
	return self

## 动作: 给字段乘系数
func mul(field: StringName, factor) -> ECSQuery:
	actions.append({"type": "mul", "field": field, "factor": factor})
	return self

## 动作: 给字段除以除数
func div(field: StringName, divisor) -> ECSQuery:
	actions.append({"type": "div", "field": field, "divisor": divisor})
	return self

## 动作: 给字段设置值
func set_value(field: StringName, value) -> ECSQuery:
	actions.append({"type": "set", "field": field, "value": value})
	return self


# ---------- 列间声明动作(规则层, C++ batch 执行, 列与列联动) ----------
# 参数顺序统一为: (目标字段, 源组件, 源字段)。例: add_from(&"dmg", BattleCell, &"atk") 即 dmg += atk。

## 动作: 目标字段 += 源字段列(可乘 factor)。例: add_from(&"dmg", BattleCell, &"atk", 2.0) → dmg += atk*2
func add_from(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_ADD, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 -= 源字段列(可乘 factor)。例: sub_from(&"hp", BattleCell, &"atk", 2.0) → hp -= atk*2
func sub_from(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_SUB, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 *= 源字段列(可标量缩放 factor)。例: mul_from(&"dmg", BattleCell, &"atk", 2.0) → dmg *= atk*2
func mul_from(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_MUL, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 /= 源字段列(除零跳过)。例: div_from(&"cd", BattleCell, &"atk") → cd /= atk
func div_from(field: StringName, src, src_field: StringName, factor: float = 1.0) -> ECSQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_DIV, "factor": factor, "addend": 0.0})
	return self

## 动作: 目标字段 = 源字段列(可标量缩放)。例: set_from(&"size", BattleCell, &"hp", 0.08, 8.0) → size = hp*0.08 + 8
func set_from(field: StringName, src, src_field: StringName, factor: float = 1.0, addend: float = 0.0) -> ECSQuery:
	actions.append({"type": "col", "field": field, "src": src, "src_field": src_field,
			"op": ECSWorld.ColOp.COL_SET, "factor": factor, "addend": addend})
	return self

## 动作: 仅满足条件的实体 目标字段 = clamp(目标字段, min, max)(列间边界)
func clamp_where(field: StringName, min_comp, min_field: StringName,
		max_comp, max_field: StringName) -> ECSQuery:
	actions.append({"type": "clamp", "field": field,
			"min_comp": min_comp, "min_field": min_field,
			"max_comp": max_comp, "max_field": max_field})
	return self


# ---------- Callback 动作(手写层, GDScript 执行) ----------

## 声明要遍历的锚组件字段(数组), 配合 .process(cb) 使用 —— 推荐写法:
##   ctx.for_each(BattleCell).with([&"hp", &"pos"]).process(func(rows, hp, pos):
##       for r in rows:
##           hp[r] -= 1
##           pos[r] += Vector2(1, 0)
##   )
## 回调参数: 第 1 个是 rows(满足条件的行号), 之后按声明顺序对应各字段列。
## 框架借出独占列(写无 COW) → 回调内直接读写列 → 自动写回, 回调内零跨语言。
func with(fields: Array) -> ECSQuery:
	_with_fields = fields
	return self

## 动作: 用 GDScript Callback 自定义遍历逻辑。三种用法:
##   A. 推荐: 先 .with(&"f1", &"f2", ...) 声明字段, 再 process(cb) —— 回调 cb(rows, col1, col2, ...)
##      直接收列参数(顺序对应声明), 无字符串 key, 自动写回。
##   B. process(cb, fields: Dictionary) —— 回调 cb(rows, data), data[组件类名][字段名] 访问。
##      fields = {组件: [字段...]} 组件→字段映射; 适合跨组件多字段。
##   C. process(cb, comps: Array) —— 回调 cb(rows, comp_rows, world); 回调内 get_column/set_column。
func process(cb: Callable, fields = {}) -> ECSQuery:
	if not _with_fields.is_empty():
		# A 模式: with(字段...) 声明 → 回调直接收列参数
		actions.append({"type": "call_with", "callable": cb, "fields": _with_fields})
		_with_fields = []
	elif fields is Dictionary and not fields.is_empty():
		actions.append({"type": "call_fields", "callable": cb, "fields": fields})
	else:
		var comps: Array = fields if fields is Array else []
		actions.append({"type": "call", "callable": cb, "comps": comps})
	return self


## 执行查询(返回处理实体数)。通常无需手动调用 —— 系统 _run 结束后框架自动执行本系统未 execute 的查询;
## 仅当需要立即拿到结果(处理实体数)时才显式调用。已执行过的查询再次调用返回缓存结果。
func execute() -> int:
	if _executed:
		return _last_count
	_executed = true
	_last_count = _run()
	return _last_count


var _last_count := 0


## 用预收集的行集执行本查询的全部动作(跳过收集)。rows 为 anchor 行号。
## 供 ECSSystemContext 自动合并批量查询时调用(同 anchor 多查询一次 batch_collect)。
## 仅当本查询全部动作可"行集化"(标量/列间)时使用; 含 callback/clamp 类动作时整体回退原 _run。
func _apply_rows(rows: PackedInt32Array) -> int:
	if world == null:
		return 0
	# 先整体检查: 含 callback/clamp 等不可行集化动作时, 回退完整收集执行(避免部分执行重复)
	for act in actions:
		if act.type != "add" and act.type != "sub" and act.type != "mul" \
				and act.type != "div" and act.type != "set" and act.type != "col":
			return _run()
	# 批量下发: 一次跨语言执行全部动作(免逐动作跨语言调用)
	var acts := []
	for act in actions:
		match act.type:
			"add":
				acts.append({"t": 1, "of": str(act.field), "op": 0, "f": 0.0, "v": float(act.amount)})
			"sub":
				acts.append({"t": 1, "of": str(act.field), "op": 0, "f": 0.0, "v": -float(act.amount)})
			"mul":
				acts.append({"t": 1, "of": str(act.field), "op": 1, "f": float(act.factor), "v": 0.0})
			"div":
				acts.append({"t": 1, "of": str(act.field), "op": 1, "f": 1.0 / float(act.divisor), "v": 0.0})
			"set":
				acts.append({"t": 1, "of": str(act.field), "op": 2, "f": 0.0, "v": float(act.value)})
			"col":
				var item := {"t": 0, "of": str(act.field), "sf": str(act.src_field),
						"op": act.op, "f": act.factor, "add": act.addend}
				if act.src != anchor:
					item["sc"] = world.component_name(act.src)
				acts.append(item)
	return world.batch_apply_actions(anchor, rows, acts)


func _comp_name(c) -> StringName:
	if c is Script:
		var n: StringName = world.component_name(c)
		if n != &"":
			return n
	return StringName(str(c))


func _run() -> int:
	if world == null:
		return 0
	var total := 0
	for act in actions:
		match act.type:
			"add":
				total += world.batch_apply_where(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.ADD_VALUE, 0.0, float(act.amount), conditions)
			"sub":
				total += world.batch_apply_where(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.ADD_VALUE, 0.0, -float(act.amount), conditions)
			"mul":
				total += world.batch_apply_where(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.MULTIPLY_ADD, float(act.factor), 0.0, conditions)
			"div":
				total += world.batch_apply_where(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.MULTIPLY_ADD, 1.0 / float(act.divisor), 0.0, conditions)
			"set":
				total += world.batch_apply_where(anchor, must, anchor, act.field,
						ECSWorld.BatchOp.SET_VALUE, 0.0, float(act.value), conditions)
			"col":
				total += world.batch_apply_col(anchor, must, anchor, act.field,
						act.src, act.src_field, act.op, act.factor, act.addend, conditions)
			"clamp":
				total += world.batch_clamp_where(anchor, must, anchor, act.field,
						act.min_comp, act.min_field, act.max_comp, act.max_field, conditions)
			"call":
				var aligned: Array = world.query_aligned_where(anchor, must, without,
						conditions, act.comps)
				if aligned.is_empty():
					continue
				var rows: PackedInt32Array = aligned[0]
				if rows.is_empty():
					continue
				var comp_rows := {}
				for i in act.comps.size():
					comp_rows[_comp_name(act.comps[i])] = aligned[i + 1]
				total += rows.size()
				act.callable.call(rows, comp_rows, world)
			"call_fields":
				var comps: Array = []
				for c in act.fields:
					comps.append(c)
				var faligned: Array = world.query_aligned_where(anchor, must, without,
						conditions, comps)
				if faligned.is_empty():
					continue
				var frows: PackedInt32Array = faligned[0]
				if frows.is_empty():
					continue
				var norm := []
				for c in act.fields:
					norm.append({"comp": _comp_name(c), "fields": act.fields[c]})
				# 借出列(独占引用, 回调内写列无 COW 深拷贝) → 回调 → 归还
				var data: Dictionary = world.borrow_columns(norm)
				total += frows.size()
				act.callable.call(frows, data)
				world.return_columns(data)
			"call_with":
				# with(字段...) 声明 → 回调直接收列参数(顺序对应), 零跨语言 + 自动写回
				var waligned: Array = world.query_aligned_where(anchor, must, without,
						conditions, [anchor])
				if waligned.is_empty():
					continue
				var wrows: PackedInt32Array = waligned[0]
				if wrows.is_empty():
					continue
				var wnorm := [{"comp": _comp_name(anchor), "fields": act.fields}]
				var wdata: Dictionary = world.borrow_columns(wnorm)
				var wcols: Dictionary = wdata.get(_comp_name(anchor), {})
				var wargs: Array = [wrows]
				for f in act.fields:
					wargs.append(wcols.get(f))
				total += wrows.size()
				act.callable.callv(wargs)
				world.return_columns(wdata)
	return total
