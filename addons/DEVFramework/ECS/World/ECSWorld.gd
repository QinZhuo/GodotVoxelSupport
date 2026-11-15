class_name ECSWorld
extends RefCounted

## ECS 世界 —— 用户主入口。运行时持有 C++ 核心(ECSCore), 提供:
##   - 组件注册 / 实体创建与销毁
##   - 系统注册与按优先级调度(tick)
##   - 系统级并行执行(冲突检测分批, 多线程并行)
##   - 批量查询与列访问(高频路径)

## —— 批量运算操作符(传给 batch_apply / batch_apply_where 的 op 参数) ——
enum BatchOp {
	ADD_VALUE = 0,       # 加值:   col += addend
	MULTIPLY_ADD = 1,    # 乘加:   col = col * factor + addend
	SET_VALUE = 2,       # 赋值:   col = addend
}

## —— 条件比较符(传给 batch_apply_where / batch_count_where 的 conditions.op) ——
enum CondOp {
	LESS_THAN = 0,        # <   小于
	LESS_OR_EQUAL = 1,    # <=  小于等于
	GREATER_THAN = 2,     # >   大于
	GREATER_OR_EQUAL = 3, # >=  大于等于
	EQUAL = 4,            # ==  等于
	NOT_EQUAL = 5,        # !=  不等于
}

## —— 列间运算操作符(传给 batch_apply_col 的 op 参数) ——
enum ColOp {
	COL_ADD = 0,  # 目标列 += 源列(可缩放)
	COL_SUB = 1,  # 目标列 -= 源列(可缩放)
	COL_MUL = 2,  # 目标列 *= 源列(可缩放)
	COL_DIV = 3,  # 目标列 /= 源列(可缩放, 除零跳过)
	COL_SET = 4,  # 目标列 = 源列(可缩放)
}

# ---------------- 核心句柄 ----------------
var _core: Object = null                 # ECSCore 原生实例

# ---------------- 组件注册表 ----------------
var _component_registered := {}          # Script -> bool (避免重复注册)
var _component_names := {}               # Script -> StringName
var _components: Array[Script] = []

# ---------------- 系统调度(状态全在 ECSScheduler) ----------------
var _scheduler: ECSScheduler = null

## 系统级并行开关(转发给调度器)。关闭后回退纯串行。
var parallel_enabled: bool:
	get:
		return scheduler().parallel_enabled
	set(value):
		scheduler().parallel_enabled = value

## 并行线程数(0=自动; 转发给调度器)。
var parallel_threads: int:
	get:
		return scheduler().parallel_threads
	set(value):
		scheduler().parallel_threads = value


## 调度器懒创建(它要回指本世界: 解析组件名、取原生核心、作上下文宿主)。
func scheduler() -> ECSScheduler:
	if _scheduler == null:
		_scheduler = ECSScheduler.new(self)
	return _scheduler
var _cache_mutex := Mutex.new()           # 查询缓存
var _event_mutex := Mutex.new()           # 事件队列
var _cmd_mutex := Mutex.new()             # 命令缓冲
var _struct_mutex := Mutex.new()          # 立即结构变更(create/destroy/add/remove)

# ---------------- 组件生命周期钩子 ----------------
##   - add 钩子: 实体获得组件后(立即版 add_component 或命令缓冲 flush 后)
##   - remove 钩子: 实体失去组件后(立即版 remove_component、destroy 或 flush 后)
var _component_hooks := {}
var _entity_destroyed_hooks: Array = []   # Array[Callable], func(entity: int)
var _has_any_component_hooks := false     # 快速判断: 是否需要枚举实体组件
# 父子关系索引: parent实体 -> Array[int] children(由 set_parent 等维护, 实体销毁自动清理)
var _parent_children := {}

# ---------------- 变化检测 ----------------
## 注意: get_column 返回共享引用后原地修改不经过写 API, 不会被标记。
var _frame_count := 0                     # 本世界已 tick 帧数
# ---------------- 调试统计(实体/系统查看器用) ----------------
var _component_by_name := {}                   # 组件类名(StringName) -> 脚本
var _component_schemas := {}                   # 组件类名 -> [{name, type}] 字段列表
var _dirty_comps := {}                    # compName -> 帧号(该帧被写)
var _dirty_mutex := Mutex.new()

# ---------------- 事件队列 ----------------
var _event_queues := {}                  # type(StringName) -> Array[Variant]
var _event_subscribers := {}             # type(StringName) -> Array[Callable]

# ---------------- 查询缓存(增量失效) ----------------
var _query_cache := {}
var _comp_versions := {}                  # 组件名 -> 结构版本(该组件实体集合变化的代数)
var _world_version := 0                   # 全局结构版本(destroy/批量结构变更时 +1)

func _init(p_use_shared_core: bool = true) -> void:
	# 默认使用全局共享核心(游戏通常只有一个世界);
	if p_use_shared_core:
		_core = ECSNative.get_instance()
	else:
		_core = ClassDB.instantiate(&"ECSCore")
	if _core == null:
		push_error("ECSWorld: ECSCore 原生库不可用! 请确认 res://addons/DEVFramework/Native/dev.gdextension 已加载(框架强依赖 C++, 无回退)。")

## 原生实例(高级用法直接调用)
func native() -> Object:
	return _core

# ============================================================

## 注册组件类(ECSComponent 子类)。重复注册幂等。
##   · ECSComponent 子类: 反射其全部脚本变量(@export 数据字段)
##   · 普通脚本(如 Entity2D 子类/任意 Node): 反射其 @export 纯数据变量
func register_component(component_class: Script) -> bool:
	if _component_registered.get(component_class, false):
		return true
	var probe: Variant = ECSNative.instantiate_script(component_class)
	if probe == null:
		return false
	# 普通脚本(非 ECSComponent)只收 @export 纯数据, ECSComponent 收集全部脚本变量
	var schema: Dictionary = ECSNative.collect_schema(probe, not probe.has_method("get_schema"))
	var fields: Array = schema.get("fields", [])
	var fnames := PackedStringArray()
	var ftypes := PackedInt32Array()
	var fdefaults: Array = []
	for f in fields:
		fnames.append(f.name)
		ftypes.append(f.type)
		fdefaults.append(f.default)
	var name: StringName = schema.get("name", &"")
	if name == &"":
		return false
	if _core.call(&"register_component", name, fnames, ftypes, fdefaults) < 0:
		return false
	_component_registered[component_class] = true
	_component_names[component_class] = name
	_component_by_name[name] = component_class
	var sch: Array = []
	for fi in fnames.size():
		sch.append({"name": fnames[fi], "type": ftypes[fi]})
	_component_schemas[name] = sch
	_components.append(component_class)
	# 日志: 组件名 + 注册的属性(含类型)
	var field_desc := PackedStringArray()
	for fi in fnames.size():
		field_desc.append("%s(%s)" % [fnames[fi], type_string(ftypes[fi])])
	LogTool.log("ECS", "注册组件 %s: [%s]" % [name, ", ".join(field_desc)])
	return true

## 返回组件类名(StringName)
func component_name(component_class: Script) -> StringName:
	return _component_names.get(component_class, &"")

## 已注册组件类列表
func registered_components() -> Array[Script]:
	return _components

# ============================================================

## 创建实体, 返回实体 id(int32: index|version<<24)
## 注意: 新实体无组件, 不影响任何查询结果 → 不失效查询缓存。
func create_entity() -> int:
	var e: int = -1
	_struct_mutex.lock()
	e = _core.create_entity()
	_struct_mutex.unlock()
	return e

func is_alive(entity: int) -> bool:
	return _core.is_alive(entity)

## 销毁实体(从所有组件移除, 复用 id 防悬垂)
func destroy_entity(entity: int) -> void:
	_cleanup_relations(entity)   # 关系清理: 解除该实体的父/子关联(索引 + 对端 target)
	var pending_comps: Array = []
	if _has_any_component_hooks or not _entity_destroyed_hooks.is_empty():
		pending_comps = _core.get_entity_components(entity)
	_struct_mutex.lock()
	_core.destroy_entity(entity)
	_world_version += 1
	_struct_mutex.unlock()
	for c in pending_comps:
		_fire_component_remove(c, entity)
	_fire_entity_destroyed(entity)

# ============================================================

## 设置 child 的父实体为 parent(自动维护关系索引)。child/parent 需存活。
func set_parent(child: int, parent: int) -> void:
	if child == parent or not is_alive(child) or not is_alive(parent):
		return
	var old := get_parent(child)
	if old != -1 and old != parent:
		_remove_child_index(old, child)
	if has_component(child, ECSParent):
		set_field(child, ECSParent, &"target", parent)
	else:
		add_component(child, ECSParent, {"target": parent})
	if not _parent_children.has(parent):
		_parent_children[parent] = []
	var arr: Array = _parent_children[parent]
	if child not in arr:
		arr.append(child)

## 返回 entity 的父实体 ID(-1 = 无父)。
func get_parent(entity: int) -> int:
	if not has_component(entity, ECSParent):
		return -1
	return int(get_field(entity, ECSParent, &"target"))

## 返回 parent 的所有子实体 ID 列表(副本)。
func get_children(parent: int) -> Array:
	var arr: Array = _parent_children.get(parent, [])
	return arr.duplicate()

## 解除 child 与其父实体的关联(保留 ECSParent 组件, target 置 -1)。
func clear_parent(child: int) -> void:
	var old := get_parent(child)
	if old != -1:
		_remove_child_index(old, child)
	if has_component(child, ECSParent):
		set_field(child, ECSParent, &"target", -1)

## 从关系索引移除 child(parent 的 children 数组)。
func _remove_child_index(parent: int, child: int) -> void:
	var arr: Array = _parent_children.get(parent, [])
	arr.erase(child)
	if arr.is_empty():
		_parent_children.erase(parent)

## 实体销毁时的关系清理: 作为子 → 从父索引移除; 作为父 → 清所有子实体的 target。
func _cleanup_relations(entity: int) -> void:
	var old := get_parent(entity)
	if old != -1:
		_remove_child_index(old, entity)
	var children: Array = _parent_children.get(entity, [])
	if not children.is_empty():
		for c in children:
			if is_alive(c) and has_component(c, ECSParent):
				set_field(c, ECSParent, &"target", -1)
		_parent_children.erase(entity)

## 给实体附加组件。component 支持三种传法:
##   · Script(ECSComponent 子类/普通 Node 脚本)
##   · 类名 StringName/String
##   · 实例(一参数模式): 传组件实例/节点实例, 自动反射其 @export 数据字段作为初值
func add_component(entity: int, component, def_data: Dictionary = {}) -> bool:
	# 一参数实例模式: 传入实例(非 Script/名字), 自动反射其 @export 数据字段为初值
	if not (component is Script or component is String or component is StringName):
		if def_data.is_empty():
			def_data = ECSNative.collect_values(component, true)
		var inst_script: Script = component.get_script()
		if inst_script == null:
			return false
		component = inst_script
	# 自动注册: 未注册的脚本组件先注册(用户无需手动 register_component)
	if component is Script and not _component_registered.get(component, false):
		if not register_component(component):
			return false
	var name := resolve_component_name(component)
	if name == &"":
		return false
	_struct_mutex.lock()
	var ok: bool = _core.add_component(entity, name)
	if ok:
		_bump_comp(name)
		# 附加后用 def_data 覆盖默认值(可选, 数据驱动兼容)
		for k in def_data:
			_core.set_field(entity, name, StringName(k), def_data[k])
	_struct_mutex.unlock()
	if ok:
		_fire_component_add(name, entity)
	return ok

func has_component(entity: int, component) -> bool:
	var name := resolve_component_name(component)
	return name != &"" and _core.has_component(entity, name)

func remove_component(entity: int, component) -> void:
	var name := resolve_component_name(component)
	if name != &"":
		_struct_mutex.lock()
		_core.remove_component(entity, name)
		_bump_comp(name)
		_struct_mutex.unlock()
		_fire_component_remove(name, entity)

## 统一的组件名解析入口(全框架唯一实现): Script -> 注册名 / 反射类名; String(Name) 原样返回。
func resolve_component_name(component) -> StringName:
	if component is Script:
		var n: StringName = _component_names.get(component, &"")
		if n != &"":
			return n
		# 未注册: 尝试从 resource_path 稳定获取类名(统一走 ECSNative.collect_schema)
		var probe: Variant = ECSNative.instantiate_script(component)
		if probe != null:
			return ECSNative.collect_schema(probe).get("name", &"")
		return &""
	if component is StringName or component is String:
		return StringName(component)
	return &""

# ============================================================

func get_field(entity: int, component, field: StringName):
	var cn := resolve_component_name(component)
	_record_access(cn)
	return _core.get_field(entity, cn, field)

func set_field(entity: int, component, field: StringName, value) -> void:
	var cn := resolve_component_name(component)
	_record_access(cn)
	_core.set_field(entity, cn, field, value)
	_mark_dirty(cn)

# ============================================================

## 查询匹配实体(返回 anchor 组件的 dense 行号列表)。
## 注意: 行号属于 anchor 组件; 跨组件访问时, 先 entity_of_row(anchor, row) 取实体ID,
func get_entity_at(component, row: int) -> int:
	return _core.get_entity_at(resolve_component_name(component), row)

## 变更检测: 返回该组件所有"写版本 > since"的聚合行号(增量同步/系统只处理变更实体用)。
func get_changed(component, since: int) -> PackedInt32Array:
	return _core.get_changed(resolve_component_name(component), since)

## 变更检测开关(false 默认: 避免全量写标记开销; 开启后 batch 写递增行版本, get_changed 增量查询有效)。
var change_detection: bool:
	get:
		return _core.is_change_detection()
	set(v):
		_core.set_change_detection(v)

## 查询匹配实体, 直接返回实体 ID 数组(archetype 下最直观: 配 get_field/set_field 使用)。
func query_entities(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	var anchor_name := resolve_component_name(anchor)
	if anchor_name == &"":
		return PackedInt32Array()
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	return _core.query_entities(anchor_name, must_names, without_names)

## 全量聚合行号(无条件查询): 返回该组件所有实体的聚合行号(0..N-1)。
var _all_rows_cache := {}

func query_all_rows(anchor) -> PackedInt32Array:
	var cn: StringName = resolve_component_name(anchor)
	if cn == &"":
		return PackedInt32Array()
	_record_access(cn)
	# 并行批内主线程可能正在改结构 → 绕过缓存, 避免读到陈旧行集(与 query_rows 一致)
	if scheduler().is_parallel_active():
		return _core.query_rows(cn, [], [])
	var cv: int = _comp_versions.get(cn, 0)
	var entry: Dictionary = _all_rows_cache.get(cn, {})
	if not entry.is_empty() and entry.comp_v == cv and entry.world_v == _world_version:
		return entry.result
	var rows: PackedInt32Array = _core.query_rows(cn, [], [])
	_all_rows_cache[cn] = {"result": rows, "comp_v": cv, "world_v": _world_version}
	return rows

## 统一解析查询参数: anchor/must/without 的类名解析 + 访问记录(三条查询路径共用)。
func _resolve_query_args(anchor, must: Array, without: Array) -> Array:
	var anchor_name: StringName = resolve_component_name(anchor)
	if anchor_name == &"":
		return []
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	return [anchor_name, must_names, without_names]

## 查询缓存键: 扁平字符串键(字段间用 \u001e, 数组元素间用 \u001f),
const _QKEY_FIELD := "\u001e"
const _QKEY_ITEM := "\u001f"

func _query_cache_key(kind: String, anchor_name: StringName,
		must_names: PackedStringArray, without_names: PackedStringArray) -> String:
	return (kind + _QKEY_FIELD + anchor_name + _QKEY_FIELD
			+ _QKEY_ITEM.join(must_names) + _QKEY_FIELD + _QKEY_ITEM.join(without_names))

## 带缓存(增量失效): 相同签名查询复用结果, 仅当涉及组件结构变化时才失效。
func query_rows(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	var args := _resolve_query_args(anchor, must, without)
	if args.is_empty():
		return PackedInt32Array()
	var anchor_name: StringName = args[0]
	var must_names: PackedStringArray = args[1]
	var without_names: PackedStringArray = args[2]
	# 并行批内跳过查询缓存: 主线程系统可能正在改结构, 用缓存会读到陈旧结果
	if scheduler().is_parallel_active():
		return _core.query_rows(anchor_name, must_names, without_names)
	var key := _query_cache_key("r", anchor_name, must_names, without_names)
	_cache_mutex.lock()
	var entry: Dictionary = _query_cache.get(key, {})
	if not entry.is_empty() and _entry_valid(entry):
		var cached: PackedInt32Array = entry.result
		_cache_mutex.unlock()
		return cached
	var result: PackedInt32Array = _core.query_rows(anchor_name, must_names, without_names)
	_cache_store(key, anchor_name, must_names, without_names, result)
	_cache_mutex.unlock()
	return result

## 对齐行号查询: 一次遍历收集匹配实体, 返回 anchor 与全部 must 组件的对齐 dense 行号。
func query_aligned(anchor, must: Array = [], without: Array = []) -> Array:
	var args := _resolve_query_args(anchor, must, without)
	if args.is_empty():
		return []
	var anchor_name: StringName = args[0]
	var must_names: PackedStringArray = args[1]
	var without_names: PackedStringArray = args[2]
	if scheduler().is_parallel_active():
		return _core.query_rows_aligned(anchor_name, must_names, without_names)
	var key := _query_cache_key("a", anchor_name, must_names, without_names)
	_cache_mutex.lock()
	var entry: Dictionary = _query_cache.get(key, {})
	if not entry.is_empty() and _entry_valid(entry):
		var cached: Array = entry.result
		_cache_mutex.unlock()
		return cached
	var result: Array = _core.query_rows_aligned(anchor_name, must_names, without_names)
	_cache_store(key, anchor_name, must_names, without_names, result)
	_cache_mutex.unlock()
	return result

## 对齐行号 + 条件过滤查询(供 查询链.call 等高级遍历)。
func query_aligned_where(anchor, must: Array = [], without: Array = [],
		conditions: Array = [], comps: Array = []) -> Array:
	var args := _resolve_query_args(anchor, must, without)
	if args.is_empty():
		return []
	var anchor_name: StringName = args[0]
	var must_names: PackedStringArray = args[1]
	var without_names: PackedStringArray = args[2]
	var comps_names := PackedStringArray()
	for c in comps:
		var cn := resolve_component_name(c)
		if cn == &"":
			continue
		comps_names.append(cn)
		_record_access(cn)
	for c in conditions:
		_record_access(resolve_component_name(c.get("comp", &"")))
	return _core.query_rows_aligned_where(anchor_name, must_names, without_names,
		_normalize_conds(conditions), comps_names)

## 一次写回多组件多列(与 get_columns 返回结构同构, 一次跨语言替代 N 次 set_column)。
func set_columns(values: Dictionary) -> void:
	var norm := {}
	for comp in values:
		var cn := resolve_component_name(comp)
		if cn == &"":
			continue
		_record_access(cn)
		_mark_dirty(cn)
		norm[cn] = values[comp]
	_core.set_columns(norm)

## 借出列(写路径消除 COW): 把内部列移出返回独占引用, 回调内写列 O(1) 无深拷贝。
## 借出期间内部该列为空, 不得被其他路径读取; 必须配 return_columns() 归还。
func borrow_columns(comps_fields: Array) -> Dictionary:
	var norm := []
	for cf in comps_fields:
		var cn := resolve_component_name(cf.get("comp", &""))
		if cn == &"":
			continue
		_record_access(cn)
		norm.append({"comp": cn, "fields": cf.get("fields", [])})
	return _core.borrow_columns(norm)

## 归还借出列(内部列 = 返回数组, 指针交换 O(1))。
func return_columns(borrowed: Dictionary) -> void:
	_core.return_columns(borrowed)
	for comp in borrowed:
		_mark_dirty(resolve_component_name(comp))

## 是否有未归还的借出列(调试/防御)。
func is_column_borrowed() -> bool:
	return _core.is_column_borrowed()

## 列间运算: 对满足条件的实体, 用 src 组件字段列对目标字段做运算。
func batch_apply_col(anchor, must: Array, op_comp, op_field: StringName,
		src_comp, src_field: StringName, op: int, factor: float = 1.0,
		addend: float = 0.0, conditions: Array = []) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	var scn := resolve_component_name(src_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(scn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	return _core.batch_apply_col(an, _names(must), ocn, op_field, scn, src_field,
		op, factor, addend, _normalize_conds(conditions))

## 带条件过滤的列钳制: 仅满足条件的实体 col = clamp(col, min, max)。
func batch_clamp_where(anchor, must: Array, op_comp, op_field: StringName,
		min_comp, min_field: StringName, max_comp, max_field: StringName,
		conditions: Array = []) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	var mincn := resolve_component_name(min_comp)
	var maxcn := resolve_component_name(max_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(mincn)
	_record_access(maxcn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	var col = _core.get_column(ocn, op_field)
	if col is PackedInt32Array:
		return _gd_batch_clamp_int(an, must, ocn, op_field, mincn, min_field, maxcn, max_field, conditions)
	return _core.batch_clamp_where(an, _names(must), ocn, op_field,
		mincn, min_field, maxcn, max_field, _normalize_conds(conditions))


## int 列钳制的 GDScript 兜底实现(原生 batch_clamp 仅支持 float 列):
func _gd_batch_clamp_int(an: StringName, must: Array, ocn: StringName, op_field: StringName,
		mincn: StringName, min_field: StringName, maxcn: StringName, max_field: StringName,
		conditions: Array) -> int:
	var comps: Array = [ocn]
	if mincn != ocn:
		comps.append(mincn)
	if maxcn != ocn and maxcn != mincn:
		comps.append(maxcn)
	var aligned: Array = query_aligned_where(an, _names(must), [], _normalize_conds(conditions), comps)
	var rows_op: PackedInt32Array = aligned[0]
	var rows_min: PackedInt32Array = aligned[comps.find(mincn)]
	var rows_max: PackedInt32Array = aligned[comps.find(maxcn)]
	var col: PackedInt32Array = _core.get_column(ocn, op_field)
	var minc = _core.get_column(mincn, min_field)
	var maxc = _core.get_column(maxcn, max_field)
	var changed := 0
	for k in rows_op.size():
		var v := col[rows_op[k]]
		var cv := clampi(v, int(minc[rows_min[k]]), int(maxc[rows_max[k]]))
		if cv != v:
			col[rows_op[k]] = cv
			changed += 1
	if changed > 0:
		_core.set_column(ocn, op_field, col)
		_mark_dirty(ocn)
	return changed

## 缓存条目是否仍有效: 全局版本一致 且 所有依赖组件版本一致。
func _entry_valid(entry: Dictionary) -> bool:
	if entry.world_v != _world_version:
		return false
	for c in entry.deps:
		if entry.comp_v.get(c, 0) != _comp_versions.get(c, 0):
			return false
	return true

## 写入缓存条目(锁内调用)。deps = anchor + must + without 全部组件。
func _cache_store(key: String, anchor_name: StringName, must_names: PackedStringArray,
		without_names: PackedStringArray, result) -> void:
	if _query_cache.size() > 64:
		_query_cache.clear()  # 缓存过大时清空(防内存膨胀)
	var deps := PackedStringArray()
	deps.append(anchor_name)
	for mn in must_names:
		deps.append(mn)
	for wn in without_names:
		deps.append(wn)
	var comp_v := {}
	for c in deps:
		comp_v[c] = _comp_versions.get(c, 0)
	_query_cache[key] = {"result": result, "deps": deps, "comp_v": comp_v, "world_v": _world_version}

## 组件结构版本 +1(该组件实体集合变化)。
func _bump_comp(comp: StringName) -> void:
	_comp_versions[comp] = _comp_versions.get(comp, 0) + 1

## 取整列数据(返回 Packed 数组拷贝, 按 anchor 组件的 dense 行号索引)。
func get_column(component, field: StringName):
	var cn := resolve_component_name(component)
	_record_access(cn)
	return _core.get_column(cn, field)

## 整列写回(按行号)。
func set_column(component, field: StringName, values) -> void:
	var cn := resolve_component_name(component)
	_record_access(cn)
	_core.set_column(cn, field, values)
	_mark_dirty(cn)

## 一次取多组件多列(一次跨语言调用替代 N 次 get_column)。
func get_columns(comps_fields: Array) -> Dictionary:
	var norm := []
	for cf in comps_fields:
		var cn := resolve_component_name(cf.get("comp", &""))
		if cn == &"":
			continue
		_record_access(cn)
		norm.append({"comp": cn, "fields": cf.get("fields", [])})
	return _core.get_columns(norm)

## 行号 -> 实体 id(anchor 组件的 dense 行号转实体)。
func entity_of_row(component, row: int) -> int:
	return _core.entity_of_row(resolve_component_name(component), row)

## 实体 id -> 行号(某组件的 dense 行号, 用于跨组件列访问)。
func row_of_entity(component, entity: int) -> int:
	return _core.row_of_entity(resolve_component_name(component), entity)

# ---- 原生API层: 批量运算(纯 C++ 循环, 无 GDScript 解释开销) ----

## 批量数值变换(anchor 组件中同时拥有 must 的实体, 对 op 字段原地运算)。
func batch_apply(anchor, must: Array, op_comp, op_field: StringName, op: int, factor: float, addend: float) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	for mn in _names(must):
		_record_access(mn)
	_mark_dirty(ocn)
	return _core.batch_apply(an, _names(must), ocn, op_field, op, factor, addend)

## 批量边界钳制: col = clamp(col, min, max), min/max 取自其他组件字段
## 注: 原生实现仅支持 float 列; int 列自动走 GDScript 兜底(否则静默不写回)
func batch_clamp(anchor, must: Array, op_comp, op_field: StringName, min_comp, min_field: StringName, max_comp, max_field: StringName) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	var mincn := resolve_component_name(min_comp)
	var maxcn := resolve_component_name(max_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(mincn)
	_record_access(maxcn)
	for mn in _names(must):
		_record_access(mn)
	_mark_dirty(ocn)
	var col = _core.get_column(ocn, op_field)
	if col is PackedInt32Array:
		return _gd_batch_clamp_int(an, must, ocn, op_field, mincn, min_field, maxcn, max_field, [])
	return _core.batch_clamp(an, _names(must), ocn, op_field,
		mincn, min_field, maxcn, max_field)

## 批量向量积分: pos += vel * delta (Vector2/3)
func batch_vec_add(anchor, must: Array, pos_comp, pos_field: StringName, vel_comp, vel_field: StringName, delta: float) -> int:
	var an := resolve_component_name(anchor)
	var pcn := resolve_component_name(pos_comp)
	var vcn := resolve_component_name(vel_comp)
	_record_access(an)
	_record_access(pcn)
	_record_access(vcn)
	for mn in _names(must):
		_record_access(mn)
	_mark_dirty(pcn)
	return _core.batch_vec_add(an, _names(must), pcn, pos_field, vcn, vel_field, delta)

func _names(arr: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for a in arr:
		out.append(resolve_component_name(a))
	return out

## 拥有某组件的实体总数。
func count(component) -> int:
	return _core.count_entities(resolve_component_name(component))

# ============================================================

## 排队: 创建实体。返回负值占位句柄(-(创建序号+1)),
func cmd_create() -> int:
	_cmd_mutex.lock()
	_core.cmd_create()
	_cmd_create_count += 1
	_cmd_ops.append(["create"])
	_cmd_mutex.unlock()
	return -_cmd_create_count  # -(序号+1) 负句柄

## 排队: 销毁实体(flush 时执行, 若已死亡则忽略)。
func cmd_destroy(entity: int) -> void:
	if entity >= 0:
		_cmd_mutex.lock()
		_core.cmd_destroy(entity)
		_cmd_ops.append(["destroy", entity])
		_cmd_mutex.unlock()

## 排队: 给实体加组件(flush 时执行)。
func cmd_add_component(entity: int, component) -> void:
	var name := resolve_component_name(component)
	if name != &"":
		_cmd_mutex.lock()
		_core.cmd_add_component(entity, name)
		_cmd_ops.append(["add", entity, name])
		_cmd_mutex.unlock()

## 排队: 给实体移除组件(flush 时执行)。
func cmd_remove_component(entity: int, component) -> void:
	var name := resolve_component_name(component)
	if name != &"":
		_cmd_mutex.lock()
		_core.cmd_remove_component(entity, name)
		_cmd_ops.append(["remove", entity, name])
		_cmd_mutex.unlock()

## 待执行命令数。
func cmd_pending_count() -> int:
	_cmd_mutex.lock()
	var n: int = _core.pending_command_count()
	_cmd_mutex.unlock()
	return n

## 立即执行全部排队命令(通常由 tick() 帧末自动调用)。
func cmd_flush() -> void:
	# flush 前收集 destroy 目标的组件(destroy 后无法枚举)
	var destroy_comps := {}
	var need_enum := _has_any_component_hooks or not _entity_destroyed_hooks.is_empty()
	if need_enum:
		for op in _cmd_ops:
			if op[0] == "destroy" and op[1] >= 0:
				destroy_comps[op[1]] = _core.get_entity_components(op[1])
	_cmd_mutex.lock()
	_core.flush_commands()
	_cmd_mutex.unlock()
	# 解析 cmd_create 占位句柄 -> 真实实体(实体在 flush 时才生成, 须 flush 后查)
	var created_map := {}
	var create_idx := 0
	for op in _cmd_ops:
		if op[0] == "create":
			created_map[-(create_idx + 1)] = _core.created_entity_at(create_idx)
			create_idx += 1
	# 精确失效缓存
	var has_destroy := false
	for op in _cmd_ops:
		match op[0]:
			"destroy":
				has_destroy = true
			"add":
				_bump_comp(op[2])
			"remove":
				_bump_comp(op[2])
	if has_destroy:
		_world_version += 1
	# 触发钩子(flush 后, 主线程)
	for op in _cmd_ops:
		match op[0]:
			"add":
				var ae: int = op[1]
				if ae < 0:
					ae = created_map.get(ae, -1)
				if ae >= 0:
					_fire_component_add(op[2], ae)
			"remove":
				var re: int = op[1]
				if re < 0:
					re = created_map.get(re, -1)
				if re >= 0:
					_fire_component_remove(op[2], re)
			"destroy":
				var ee: int = op[1]
				if ee < 0:
					ee = created_map.get(ee, -1)
				if ee >= 0:
					var comps: Array = destroy_comps.get(ee, [])
					for c in comps:
						_fire_component_remove(c, ee)
					_fire_entity_destroyed(ee)
	_cmd_ops.clear()
	_cmd_create_count = 0  # 句柄仅在当帧内有效

var _cmd_create_count: int = 0
var _cmd_ops: Array = []   # 本帧排队的命令操作记录(供 flush 精确失效缓存)

# ============================================================

## 注册系统(委托调度器)。priority 越大越先执行；不传则取 system.priority。
func register_system(system: ECSSystem, priority = null, before: Array = [], after: Array = []) -> void:
	scheduler().register(system, priority, before, after)


func remove_system(system: ECSSystem) -> void:
	scheduler().remove(system)


## 已注册系统(副本, 供宿主只读遍历; 不要在遍历中注册/移除)。
func get_systems() -> Array[ECSSystem]:
	return scheduler().get_systems()


## 记录"当前任务"对某组件的访问(查询/批量路径内部调用, 供下一帧并行分批)。
func _record_access(comp: StringName) -> void:
	scheduler().record_access(comp)

## 每帧驱动全部系统。内部先按依赖图拓扑排序(优先级仅作同层平级次序)。
## 否则回退纯串行(行为与旧版一致)。并行开启时第一帧自动串行预热以采集访问记录。
func tick(delta: float) -> void:
	_frame_count += 1
	scheduler().tick(delta)
	_dispatch_events()
	cmd_flush()

## 调试: 各系统本帧耗时(ms), 键为系统名。
func get_system_times() -> Dictionary:
	return scheduler().get_system_times()

## 调试: 返回实体的组件字段视图 {组件名: {字段: 值}}(实体/组件查看器用)。
func get_entity_view(entity: int) -> Dictionary:
	var view := {}
	if not is_alive(entity):
		return view
	for cn in _core.get_entity_components(entity):
		var fields := {}
		var sch: Array = _component_schemas.get(cn, [])
		for f in sch:
			fields[f["name"]] = _core.get_field(entity, cn, f["name"])
		view[cn] = fields
	return view

## 调试: 设置实体的组件字段值(查看器改值用)。
func set_entity_field(entity: int, comp, field: StringName, value) -> void:
	set_field(entity, comp, field, value)

## 调试: 按 archetype(组件组合)分组枚举实体: [{comps, entities}](查看器分组显示用)。
func get_archetype_groups() -> Array:
	return _core.get_archetype_groups()

## 调试: 各系统耗时与累计运行次数(转发调度器)。
func get_system_stats() -> Dictionary:
	return scheduler().get_system_stats()


## 调试: 系统拓扑(当前执行顺序 + 是否可并行)。
func get_topology() -> Dictionary:
	return scheduler().get_topology()


## 是否正在使用并行执行(调试/UI 展示用)。
func is_parallel_active() -> bool:
	return scheduler().is_parallel_active()


## 并行统计(调试/UI 展示用)。
func debug_parallel_stats() -> Dictionary:
	return scheduler().debug_parallel_stats()

# ============================================================

## 注册组件 add 钩子: 实体获得该组件后触发。
func on_component_added(comp, callable: Callable) -> void:
	var cn := resolve_component_name(comp)
	if cn == &"":
		return
	if not _component_hooks.has(cn):
		_component_hooks[cn] = {"add": [], "remove": []}
	var arr: Array = _component_hooks[cn]["add"]
	if not arr.has(callable):
		arr.append(callable)
	_has_any_component_hooks = true

func off_component_added(comp, callable: Callable) -> void:
	var cn := resolve_component_name(comp)
	if _component_hooks.has(cn):
		(_component_hooks[cn]["add"] as Array).erase(callable)

## 注册组件 remove 钩子: 实体失去该组件后触发(显式移除或实体销毁时)。
func on_component_removed(comp, callable: Callable) -> void:
	var cn := resolve_component_name(comp)
	if cn == &"":
		return
	if not _component_hooks.has(cn):
		_component_hooks[cn] = {"add": [], "remove": []}
	var arr: Array = _component_hooks[cn]["remove"]
	if not arr.has(callable):
		arr.append(callable)
	_has_any_component_hooks = true

func off_component_removed(comp, callable: Callable) -> void:
	var cn := resolve_component_name(comp)
	if _component_hooks.has(cn):
		(_component_hooks[cn]["remove"] as Array).erase(callable)

## 注册实体销毁钩子: 任意实体被 destroy 后触发。
func on_entity_destroyed(callable: Callable) -> void:
	if not _entity_destroyed_hooks.has(callable):
		_entity_destroyed_hooks.append(callable)

func off_entity_destroyed(callable: Callable) -> void:
	_entity_destroyed_hooks.erase(callable)

func _fire_component_add(comp: StringName, entity: int) -> void:
	if not _component_hooks.has(comp):
		return
	var h: Dictionary = _component_hooks[comp]
	for cb in h["add"]:
		cb.call(entity)

func _fire_component_remove(comp: StringName, entity: int) -> void:
	if not _component_hooks.has(comp):
		return
	var h: Dictionary = _component_hooks[comp]
	for cb in h["remove"]:
		cb.call(entity)

func _fire_entity_destroyed(entity: int) -> void:
	for cb in _entity_destroyed_hooks:
		cb.call(entity)

# ============================================================
#  注意: get_column 返回共享引用后原地修改不经过写 API, 不会被标记。

## 标记组件本帧被写(写路径内部调用)。
func _mark_dirty(comp: StringName) -> void:
	if comp == &"":
		return
	_dirty_mutex.lock()
	_dirty_comps[comp] = _frame_count
	_dirty_mutex.unlock()

## 本帧内该组件是否被任何写 API 修改过(组件级, 非实体级)。
func is_component_dirty(comp) -> bool:
	var cn := resolve_component_name(comp)
	if cn == &"":
		return false
	return _dirty_comps.get(cn, -1) == _frame_count

## 本帧被写过的组件名列表(Array[StringName])。
func dirty_components() -> Array:
	var out := []
	for c in _dirty_comps:
		if _dirty_comps[c] == _frame_count:
			out.append(c)
	return out

# ============================================================

## 投递事件(帧末统一派发给订阅者)。
func emit_event(type: StringName, payload = null) -> void:
	_event_mutex.lock()
	if not _event_queues.has(type):
		_event_queues[type] = []
	_event_queues[type].append(payload)
	_event_mutex.unlock()

## 投递"实体事件": 指定事件的来源/目标实体。
func emit_entity_event(type: StringName, entity: int, data = null) -> void:
	var payload := {"entity": entity, "data": data}
	emit_event(type, payload)

## 订阅事件。handler(payload)。
func on_event(type: StringName, handler: Callable) -> void:
	if not _event_subscribers.has(type):
		_event_subscribers[type] = []
	_event_subscribers[type].append(handler)

## 订阅"实体事件"并按组件过滤。
func on_entity_event(type: StringName, filter: Array, handler: Callable) -> void:
	var wrapped := func(payload):
		if not payload is Dictionary or not payload.has("entity"):
			return
		var eid: int = payload["entity"]
		for comp in filter:
			if not has_component(eid, comp):
				return
		handler.call(eid, payload.get("data", null))
	on_event(type, wrapped)

## 订阅"实体事件"并按组件过滤(带 where 条件)。
func on_entity_event_where(type: StringName, filter: Array, conditions: Array, handler: Callable) -> void:
	var wrapped := func(payload):
		if not payload is Dictionary or not payload.has("entity"):
			return
		var eid: int = payload["entity"]
		for comp in filter:
			if not has_component(eid, comp):
				return
		if not _entity_matches_conds(eid, conditions):
			return
		handler.call(eid, payload.get("data", null))
	on_event(type, wrapped)

func off_event(type: StringName, handler: Callable) -> void:
	var arr: Array = _event_subscribers.get(type, [])
	arr.erase(handler)

func has_pending_events(type: StringName) -> bool:
	_event_mutex.lock()
	var b: bool = _event_queues.has(type) and not (_event_queues[type] as Array).is_empty()
	_event_mutex.unlock()
	return b

## 待派发事件总数(帧末统计用)
func pending_event_count() -> int:
	_event_mutex.lock()
	var total := 0
	for type in _event_queues:
		total += (_event_queues[type] as Array).size()
	_event_mutex.unlock()
	return total

## 订阅某事件的处理器数量
func subscriber_count(type: StringName) -> int:
	_event_mutex.lock()
	var n := (_event_subscribers.get(type, []) as Array).size()
	_event_mutex.unlock()
	return n

## 判断实体是否满足条件(复用 batch_count 的过滤逻辑)
func _entity_matches_conds(eid: int, conditions: Array) -> bool:
	if conditions.is_empty():
		return true
	# 用 batch_count 单实体判断: 构造一个临时条件直接查
	for c in conditions:
		var comp_name := resolve_component_name(c.get("comp", &""))
		var field: StringName = c.get("field", &"")
		var op: int = int(c.get("op", 0))
		var value = c.get("value", 0.0)
		var v = get_field(eid, StringName(comp_name), field)
		if v == null:
			return false
		var num := float(v)
		match op:
			CondOp.LESS_THAN:
				if not num < float(value): return false
			CondOp.LESS_OR_EQUAL:
				if not num <= float(value): return false
			CondOp.GREATER_THAN:
				if not num > float(value): return false
			CondOp.GREATER_OR_EQUAL:
				if not num >= float(value): return false
			CondOp.EQUAL:
				if not num == float(value): return false
			CondOp.NOT_EQUAL:
				if not num != float(value): return false
	return true

func _dispatch_events() -> void:
	# 快照拷贝(并行系统可能仍在投递), 主线程统一派发
	_event_mutex.lock()
	var snapshot := {}
	for type in _event_queues:
		var queue: Array = _event_queues[type]
		if queue.is_empty():
			continue
		snapshot[type] = queue.duplicate()
		queue.clear()
	_event_mutex.unlock()
	for type in snapshot:
		var handlers: Array = _event_subscribers.get(type, [])
		for payload in snapshot[type]:
			for h in handlers:
				h.call(payload)

# ============================================================

## 序列化整个世界的组件数据 → Dictionary, 可交给 SaveTool.save_data 存档。
func serialize() -> Dictionary:
	return _core.serialize()

## 反序列化: 重建实体与数据。
## 注意: 组件需先 register_component(名称一致)再调用。
func deserialize(data: Dictionary) -> Array:
	var ids: Array = _core.deserialize(data)
	_world_version += 1  # 批量重建, 无法精确追踪 → 全局失效
	return ids

## 内存统计(调试)
func debug_stats() -> Dictionary:
	return _core.debug_stats()

# ============================================================

## 条件过滤批量运算: 仅对满足全部条件的实体执行 op 运算。
##     - comp 可传组件类(Script)或类名(String); field 传字段名
##     - op: ECSWorld.CondOp(LT < / LE <= / GT > / GE >= / EQ == / NE !=)
func batch_apply_where(anchor, must: Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float, conditions: Array) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	return _core.batch_apply_where(an, _names(must),
		ocn, op_field, op, factor, addend, _normalize_conds(conditions))

## 统计满足指定条件的实体数量(纯查询, 不修改任何数据)。
func batch_count_where(anchor, must: Array, conditions: Array) -> int:
	var an := resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(resolve_component_name(c.get("comp", &"")))
	return _core.batch_count(an, _names(must), _normalize_conds(conditions))

## 批量收集: 单次遍历匹配 anchor+must(不含 without)的签名实体, 同时判定多组条件,
func batch_collect(anchor, must: Array, without: Array, groups: Array) -> Array:
	var an := resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for mn in _names(without):
		_record_access(mn)
	var norm_groups: Array = []
	for g in groups:
		for c in g:
			_record_access(resolve_component_name(c.get("comp", &"")))
		norm_groups.append(_normalize_conds(g))
	return _core.batch_collect(an, _names(must), _names(without), norm_groups)

## 批量收集(条件已规范化, 跳过 _normalize_conds 开销; 查询链合并内部用, 配合 ECSQuery.get_norm_conditions 缓存)。
func batch_collect_norm(anchor, must: Array, without: Array, norm_groups: Array) -> Array:
	var an := resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for mn in _names(without):
		_record_access(mn)
	return _core.batch_collect(an, _names(must), _names(without), norm_groups)

## 对预收集的行集做标量批量动作(跳过收集, 复用 batch_collect 的行集)。
func batch_apply_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	_mark_dirty(ocn)
	return _core.batch_apply_rows(an, rows, ocn, op_field, op, factor, addend)

## 对预收集的行集做列间动作(跳过收集): 目标列 = 目标列 OP (src列 * factor + addend)。
func batch_apply_col_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		src_comp, src_field: StringName, op: int, factor: float, addend: float) -> int:
	var an := resolve_component_name(anchor)
	var ocn := resolve_component_name(op_comp)
	var scn := resolve_component_name(src_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(scn)
	_mark_dirty(ocn)
	return _core.batch_apply_col_rows(an, rows, ocn, op_field, scn, src_field, op, factor, addend)

## 批量执行多个动作(一次跨语言, 免逐动作跨语言调用)。
func batch_apply_actions(anchor, rows: PackedInt32Array, actions: Array) -> int:
	var an := resolve_component_name(anchor)
	_record_access(an)
	_mark_dirty(an)
	return _core.batch_apply_actions(an, rows, actions)

## 规范化条件列表: 把 comp(Script/String) → 类名 String, 便于 C++ 解析
func _normalize_conds(conditions: Array) -> Array:
	var out: Array = []
	for c in conditions:
		var d := {}
		d["comp"] = resolve_component_name(c.get("comp", &""))
		d["field"] = str(c.get("field", &""))
		d["op"] = int(c.get("op", 0))
		d["value"] = c.get("value", 0.0)
		out.append(d)
	return out

# ============================================================

## 创建 prefab 模板实体(带模板标记, 不参与普通查询/序列化)。
func create_prefab() -> int:
	return _core.create_prefab()

## 该实体是否为 prefab 模板
func is_prefab(entity: int) -> bool:
	return _core.is_prefab(entity)

## 给 prefab 模板添加组件并设置初始字段值。
func prefab_add(prefab: int, component, values: Dictionary) -> bool:
	register_component(component) if component is Script else null
	var name := resolve_component_name(component)
	if name != &"":
		_bump_comp(name)
	return _core.prefab_add(prefab, name, values)

## 批量实例化: 复制 prefab 的组件结构与字段值到 count 个新实体。
func instantiate(prefab: int, count: int, overrides: Dictionary = {}) -> Array:
	# overrides 的 key 可能是 Script, 归一化为类名
	var norm_overrides := {}
	for k in overrides:
		norm_overrides[resolve_component_name(k)] = overrides[k]
	_world_version += 1  # 批量生成实体 + 组件, 无法精确追踪 → 全局失效
	return _core.instantiate(prefab, count, norm_overrides)

## 便捷: 从 ECSPrefabDef 配置构建 prefab 模板, 返回 prefab 实体 ID。
func build_prefab(def: ECSPrefabDef) -> int:
	if def == null:
		return -1
	var prefab := create_prefab()
	if prefab < 0:
		return -1
	for inst in def.component_instances:
		if inst == null:
			continue
		var comp_script: Script = inst.get_script()
		if comp_script == null:
			continue
		# 提取该组件实例的所有数据字段值(统一走 ECSNative.collect_values)
		var fields: Dictionary = ECSNative.collect_values(inst)
		prefab_add(prefab, comp_script, fields)
	return prefab

## 便捷: 从配置直接批量生成实体(构建 prefab + 实例化)。
func spawn_from_def(def: ECSPrefabDef, count: int = 1, overrides: Dictionary = {}) -> Array:
	var prefab := build_prefab(def)
	if prefab < 0:
		return []
	return instantiate(prefab, count, overrides)

# ============================================================

## 暂停或恢复世界(暂停 = 不执行任何系统, 用于多世界对比)。
## ⚠️ 会覆盖各系统自己的 enabled: 恢复时一律置 true, 原本手动关掉的系统会被一起打开。
func set_paused(paused: bool) -> void:
	scheduler().set_paused(paused)