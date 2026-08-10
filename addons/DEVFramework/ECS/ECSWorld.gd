class_name ECSWorld
extends RefCounted

## ECS 世界 —— 用户主入口。运行时持有 C++ 核心(ECSCore), 提供:
##   - 组件注册 / 实体创建与销毁
##   - 系统注册与按优先级调度(tick)
##   - 系统级并行执行(冲突检测分批, 多线程并行)
##   - 批量查询与列访问(高频路径)
##   - 批量事件队列(替代信号风暴)
##
## 用法(场景驱动, 推荐):
##   场景里放一个 World 节点, 在 Inspector 配置 systems(要注册的系统)即可自动创建世界并注册,
##   无需手写 world = ECSWorld.new() / register_system(...)。
##   代码用法: var world = ECSWorld.new(); world.register_system(HealSystem.new())。
##
## 系统级并行(默认开启, 无需任何配置即可自动生效):
##   - 首帧自动串行预热, 采集各系统实际访问的组件集合
##   - 之后每帧按"组件访问冲突"贪心分批: 访问同一组件或有 before/after
##     依赖的系统自动串行, 互不干扰的系统在多个线程上并行执行
##   - 不可并行的系统(如访问场景树/节点)需覆写 ECSSystem.can_run_parallel()
##     返回 false(参考 ECSSyncSystem)
##   - 并行系统内请用 Command Buffer 排队结构变更(cmd_*),
##     且 read_components()/write_components() 声明尽量准确
##   - 关闭并行: world.parallel_enabled = false(回退纯串行, 与旧版行为一致)
##   - 线程数: world.parallel_threads = N(0=自动); 最小并行系统数:
##     world.parallel_min_systems = N

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

# ---------------- 系统调度 ----------------
var _systems: Array[ECSSystem] = []
var _system_priorities: Array[int] = []
var _system_before: Array = []   # 每系统: 必须在其后执行的系统引用数组
var _system_after: Array = []    # 每系统: 必须在其前执行的系统引用数组
var _sorted: Array[ECSSystem] = []
var _dirty_schedule := true

# ---------------- 系统级并行调度 ----------------
## 全局开关: 是否启用系统级并行执行。关闭后回退纯串行(行为与旧版完全一致)。
var parallel_enabled: bool = true
## 并行线程数。0=自动(硬件核数-1, 上限8)。同一并行批内最多并行这么多系统。
var parallel_threads: int = 0

var _tracking := false                    # 本帧是否追踪组件访问(并行打开且系统数达标)
var _preheated := false                   # 是否已完成首帧串行预热(此后才允许并行)
var _parallel_batch_active := false       # 本帧正处于并行批(禁用查询缓存, 防陈旧结果)
var _access_sets := {}                    # ECSSystem -> {compName:true} 上一帧累积的访问记录
var _pending_access := {}                 # ECSSystem -> {compName:true} 本帧访问缓冲
var _access_target: Dictionary = {}       # 当前任务的访问目标集(读写全在 _access_mutex 内, 防并行竞争)
var _access_target_active := false        # 当前是否有活动任务在记录访问
var _system_access_declared := {}         # ECSSystem -> {compName:true} 声明的读写组件(静态缓存)
var _access_mutex := Mutex.new()
var _cache_mutex := Mutex.new()           # 查询缓存
var _event_mutex := Mutex.new()           # 事件队列
var _cmd_mutex := Mutex.new()             # 命令缓冲
var _struct_mutex := Mutex.new()          # 立即结构变更(create/destroy/add/remove)

# ---------------- 组件生命周期钩子 ----------------
## 组件钩子表: compName(StringName) -> {add: Array[Callable], remove: Array[Callable]}
## 触发时机:
##   - add 钩子: 实体获得组件后(立即版 add_component 或命令缓冲 flush 后)
##   - remove 钩子: 实体失去组件后(立即版 remove_component、destroy 或 flush 后)
## 回调签名: func(entity: int)
var _component_hooks := {}
var _entity_destroyed_hooks: Array = []   # Array[Callable], func(entity: int)
var _has_any_component_hooks := false     # 快速判断: 是否需要枚举实体组件
# 父子关系索引: parent实体 -> Array[int] children(由 set_parent 等维护, 实体销毁自动清理)
var _parent_children := {}

# ---------------- 变化检测 ----------------
## 写路径(通过框架写 API 的字段修改)会标记对应组件"本帧被写"。
## 注意: get_column 返回共享引用后原地修改不经过写 API, 不会被标记。
var _frame_count := 0                     # 本世界已 tick 帧数
# ---------------- 调试统计(实体/系统查看器用) ----------------
var _system_times := {}                        # ECSSystem -> 本帧耗时 ms(并行安全)
var _system_runs := {}                          # ECSSystem -> 累计运行次数
var _system_times_lock := Mutex.new()
var _component_by_name := {}                   # 组件类名(StringName) -> 脚本
var _component_schemas := {}                   # 组件类名 -> [{name, type}] 字段列表
var _dirty_comps := {}                    # compName -> 帧号(该帧被写)

# ---------------- 事件队列 ----------------
var _event_queues := {}                  # type(StringName) -> Array[Variant]
var _event_subscribers := {}             # type(StringName) -> Array[Callable]

# ---------------- 查询缓存(增量失效) ----------------
# 缓存条目: {result, deps: PackedStringArray, comp_v: {组件->版本}, world_v: int}
# 命中条件: 全局版本一致 且 每条依赖组件的版本一致 —— 只失效真正受影响组件的缓存,
#           create_entity 不再失效任何缓存, add/remove 组件只失效该组件的缓存。
var _query_cache := {}
var _comp_versions := {}                  # 组件名 -> 结构版本(该组件实体集合变化的代数)
var _world_version := 0                   # 全局结构版本(destroy/批量结构变更时 +1)

func _init(p_use_shared_core: bool = true) -> void:
	# 默认使用全局共享核心(游戏通常只有一个世界);
	# 需要多个隔离世界(如性能对比/沙盒)时传 false 创建独立核心。
	if p_use_shared_core:
		_core = ECSNative.get_instance()
	else:
		_core = ClassDB.instantiate(&"ECSCore")
	if _core == null:
		push_error("ECSWorld: ECSCore 原生库不可用! 请确认 devecs.gdextension 已加载(框架强依赖 C++, 无回退)。")

## 原生实例(高级用法直接调用)
func native() -> Object:
	return _core

# ============================================================
#  组件注册
# ============================================================

## 注册组件类(ECSComponent 子类)。重复注册幂等。
## 通过当前世界自己的 _core 注册(不依赖全局单例)。
## component_class 支持两类脚本:
##   · ECSComponent 子类: 反射其全部脚本变量(@export 数据字段)
##   · 普通脚本(如 Entity2D 子类/任意 Node): 反射其 @export 纯数据变量
## schema 反射统一走 ECSNative.collect_schema。
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
#  实体
# ============================================================

## 创建实体, 返回实体 id(int32: index|version<<24)
## 注意: 新实体无组件, 不影响任何查询结果 → 不失效查询缓存。
func create_entity() -> int:
	_all_rows_cache.clear()
	var e: int = -1
	_struct_mutex.lock()
	e = _core.create_entity()
	_struct_mutex.unlock()
	return e

func is_alive(entity: int) -> bool:
	return _core.is_alive(entity)

## 销毁实体(从所有组件移除, 复用 id 防悬垂)
## 销毁会移除实体的全部组件(组件未知) → 全局版本失效。
## 若注册了组件 remove 钩子, 会在实体真正销毁前枚举组件并触发 remove;
## 随后触发 on_entity_destroyed 钩子。
func destroy_entity(entity: int) -> void:
	_all_rows_cache.clear()
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
#  关系实体 (entity↔entity 关联: ECSParent{target} + 关系索引)
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
## def_data 可覆盖部分字段初值(其余用 schema 默认值)。
## 只失效该组件相关的查询缓存。成功后触发该组件的 on_component_added 钩子(若有注册)。
func add_component(entity: int, component, def_data: Dictionary = {}) -> bool:
	_all_rows_cache.clear()
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
	var name := _resolve_component_name(component)
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
	var name := _resolve_component_name(component)
	return name != &"" and _core.has_component(entity, name)

func remove_component(entity: int, component) -> void:
	_all_rows_cache.clear()
	var name := _resolve_component_name(component)
	if name != &"":
		_struct_mutex.lock()
		_core.remove_component(entity, name)
		_bump_comp(name)
		_struct_mutex.unlock()
		_fire_component_remove(name, entity)

func _resolve_component_name(component) -> StringName:
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
#  字段访问(低频: 单实体)
# ============================================================

func get_field(entity: int, component, field: StringName):
	var cn := _resolve_component_name(component)
	_record_access(cn)
	return _core.get_field(entity, cn, field)

func set_field(entity: int, component, field: StringName, value) -> void:
	var cn := _resolve_component_name(component)
	_record_access(cn)
	_core.set_field(entity, cn, field, value)
	_mark_dirty(cn)

# ============================================================
#  批量查询与列访问(高频: 系统内)
# ============================================================

## 查询匹配实体(返回 anchor 组件的 dense 行号列表)。
## anchor/must/without 传组件类名或 Script。
## 行号可直接索引 get_column 返回的列 —— 列按行号紧凑存储(缓存友好, 内存紧凑)。
## 注意: 行号属于 anchor 组件; 跨组件访问时, 先 entity_of_row(anchor, row) 取实体ID,
##       再 row_of_entity(other_comp, entity) 得其他组件的行号。
## 需要实体 ID 时用 entity_of_row() 转换。
## 需要"一次拿多组件对齐行号"时改用 query_aligned()(免逐实体转换)。
## 聚合行号(某组件 get_column 的索引) -> 实体 ID(archetype 下跨块聚合顺序)。
## 配合 query_rows(返回聚合行号) 使用: 先 query_rows 拿行号, 再 get_entity_at 转实体 ID,
## 再 get_field(实体ID, ...) 读取。
func get_entity_at(component, row: int) -> int:
	return _core.get_entity_at(_resolve_component_name(component), row)

## 变更检测: 返回该组件所有"写版本 > since"的聚合行号(增量同步/系统只处理变更实体用)。
func get_changed(component, since: int) -> PackedInt32Array:
	return _core.get_changed(_resolve_component_name(component), since)

## 变更检测开关(false 默认: 避免全量写标记开销; 开启后 batch 写递增行版本, get_changed 增量查询有效)。
var change_detection: bool:
	get:
		return _core.is_change_detection()
	set(v):
		_core.set_change_detection(v)

## 查询匹配实体, 直接返回实体 ID 数组(archetype 下最直观: 配 get_field/set_field 使用)。
## 例: var ents = world.query_entities(BallComponent); for e in ents: world.get_field(e, BallComponent, &"hp")
func query_entities(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return PackedInt32Array()
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := _resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := _resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	return _core.query_entities(anchor_name, must_names, without_names)

## 全量聚合行号(无条件查询, 结构不变时缓存复用): 返回该组件所有实体的聚合行号(0..N-1)。
var _all_rows_cache := {}

func query_all_rows(anchor) -> PackedInt32Array:
	var cn: StringName = _resolve_component_name(anchor)
	if cn == &"":
		return PackedInt32Array()
	_record_access(cn)
	if _all_rows_cache.has(cn):
		return _all_rows_cache[cn]
	var rows: PackedInt32Array = _core.query_rows(cn, [], [])
	_all_rows_cache[cn] = rows
	return rows

## 带缓存(增量失效): 相同签名查询复用结果, 仅当涉及组件结构变化时才失效。
func query_rows(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return PackedInt32Array()
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := _resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := _resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	# 并行批内跳过查询缓存: 主线程系统可能正在改结构, 用缓存会读到陈旧结果
	if _parallel_batch_active:
		return _core.query_rows(anchor_name, must_names, without_names)
	var key := "r|" + str(anchor_name) + "|" + str(must_names) + "|" + str(without_names)
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
## 返回 Array[int] 数组: [0] = anchor 行号, [1..] = 对应 must[i] 组件的行号。
## 第 k 个匹配实体: anchor 列用 [0][k] 索引, must[i] 列用 [1+i][k] 索引 ——
## 同一 k 直接并行索引各组件列, 免去逐实体 entity_of_row/row_of_entity 跨语言转换。
## 用法:
##   var aligned = world.query_aligned(MoveComponent, [HealthComponent])
##   var pos: PackedVector2Array = world.get_column(MoveComponent, &"pos")
##   var hp: PackedInt32Array = world.get_column(HealthComponent, &"hp")
##   for i in aligned[0].size():
##       pos[aligned[0][i]].x += ...      # 移动组件行
##       hp[aligned[1][i]] -= 5           # 血量组件行(同一实体)
func query_aligned(anchor, must: Array = [], without: Array = []) -> Array:
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return []
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := _resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := _resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	if _parallel_batch_active:
		return _core.query_rows_aligned(anchor_name, must_names, without_names)
	var key := "a|" + str(anchor_name) + "|" + str(must_names) + "|" + str(without_names)
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
## 只返回满足 conditions 的实体; 对齐输出的组件由 comps 显式指定。
## 返回 Array: [0] = anchor 行号(已过滤), [1..] = comps[i] 的对齐行号。
## 不缓存(条件变化无稳定签名)。conditions 格式同 batch_apply_where。
func query_aligned_where(anchor, must: Array = [], without: Array = [],
		conditions: Array = [], comps: Array = []) -> Array:
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return []
	_record_access(anchor_name)
	var must_names := PackedStringArray()
	for m in must:
		var mn := _resolve_component_name(m)
		if mn == &"":
			continue
		must_names.append(mn)
		_record_access(mn)
	var without_names := PackedStringArray()
	for w in without:
		var wn := _resolve_component_name(w)
		if wn == &"":
			continue
		without_names.append(wn)
		_record_access(wn)
	var comps_names := PackedStringArray()
	for c in comps:
		var cn := _resolve_component_name(c)
		if cn == &"":
			continue
		comps_names.append(cn)
		_record_access(cn)
	for c in conditions:
		_record_access(_resolve_component_name(c.get("comp", &"")))
	return _core.query_rows_aligned_where(anchor_name, must_names, without_names,
		_normalize_conds(conditions), comps_names)

## 一次写回多组件多列(与 get_columns 返回结构同构, 一次跨语言替代 N 次 set_column)。
## values: {组件类名: {字段名: PackedArray}} —— 组件类名可用类名(StringName)或 Script。
func set_columns(values: Dictionary) -> void:
	var norm := {}
	for comp in values:
		var cn := _resolve_component_name(comp)
		if cn == &"":
			continue
		_record_access(cn)
		_mark_dirty(cn)
		norm[cn] = values[comp]
	_core.set_columns(norm)

## 借出列(写路径消除 COW): 把内部列移出返回独占引用, 回调内写列 O(1) 无深拷贝。
## 返回 {组件类名: {字段名: PackedArray}}(与 get_columns 同构)。
## 借出期间内部该列为空, 不得被其他路径读取; 必须配 return_columns() 归还。
func borrow_columns(comps_fields: Array) -> Dictionary:
	var norm := []
	for cf in comps_fields:
		var cn := _resolve_component_name(cf.get("comp", &""))
		if cn == &"":
			continue
		_record_access(cn)
		norm.append({"comp": cn, "fields": cf.get("fields", [])})
	return _core.borrow_columns(norm)

## 归还借出列(内部列 = 返回数组, 指针交换 O(1))。
func return_columns(borrowed: Dictionary) -> void:
	_core.return_columns(borrowed)
	for comp in borrowed:
		_mark_dirty(_resolve_component_name(comp))

## 是否有未归还的借出列(调试/防御)。
func is_column_borrowed() -> bool:
	return _core.is_column_borrowed()

## 列间运算: 对满足条件的实体, 用 src 组件字段列对目标字段做运算。
## op: ECSWorld.ColOp(ADD/SUB/MUL/DIV/SET); 目标列 = 目标列 OP (src列 * factor + addend)。
## 支持 INT/FLOAT(含 addend) 与 VECTOR2/VECTOR3(factor 标量缩放, 忽略 addend)。
func batch_apply_col(anchor, must: Array, op_comp, op_field: StringName,
		src_comp, src_field: StringName, op: int, factor: float = 1.0,
		addend: float = 0.0, conditions: Array = []) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	var scn := _resolve_component_name(src_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(scn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(_resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	return _core.batch_apply_col(an, _names(must), ocn, op_field, scn, src_field,
		op, factor, addend, _normalize_conds(conditions))

## 带条件过滤的列钳制: 仅满足条件的实体 col = clamp(col, min, max)。
func batch_clamp_where(anchor, must: Array, op_comp, op_field: StringName,
		min_comp, min_field: StringName, max_comp, max_field: StringName,
		conditions: Array = []) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	var mincn := _resolve_component_name(min_comp)
	var maxcn := _resolve_component_name(max_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(mincn)
	_record_access(maxcn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(_resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	return _core.batch_clamp_where(an, _names(must), ocn, op_field,
		mincn, min_field, maxcn, max_field, _normalize_conds(conditions))

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
	var cn := _resolve_component_name(component)
	_record_access(cn)
	return _core.get_column(cn, field)

## 整列写回(按行号)。
func set_column(component, field: StringName, values) -> void:
	var cn := _resolve_component_name(component)
	_record_access(cn)
	_core.set_column(cn, field, values)
	_mark_dirty(cn)

## 一次取多组件多列(一次跨语言调用替代 N 次 get_column)。
## comps_fields: Array[{comp: 组件类/类名, fields: [字段名...]}]
## 返回 {组件类名: {字段名: PackedArray}} —— 列按该组件 dense 行号索引。
## 例: world.get_columns([{comp: HealthComponent, fields: [&"hp", &"max_hp"]}])
func get_columns(comps_fields: Array) -> Dictionary:
	var norm := []
	for cf in comps_fields:
		var cn := _resolve_component_name(cf.get("comp", &""))
		if cn == &"":
			continue
		_record_access(cn)
		norm.append({"comp": cn, "fields": cf.get("fields", [])})
	return _core.get_columns(norm)

## 行号 -> 实体 id(anchor 组件的 dense 行号转实体)。
func entity_of_row(component, row: int) -> int:
	return _core.entity_of_row(_resolve_component_name(component), row)

## 实体 id -> 行号(某组件的 dense 行号, 用于跨组件列访问)。
func row_of_entity(component, entity: int) -> int:
	return _core.row_of_entity(_resolve_component_name(component), entity)

# ---- 原生API层: 批量运算(纯 C++ 循环, 无 GDScript 解释开销) ----

## 批量数值变换(anchor 组件中同时拥有 must 的实体, 对 op 字段原地运算)。
## op: ECSWorld.BatchOp(ADD=0 加法, MUL_ADD=1 乘加, SET=2 赋值)
func batch_apply(anchor, must: Array, op_comp, op_field: StringName, op: int, factor: float, addend: float) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	for mn in _names(must):
		_record_access(mn)
	_mark_dirty(ocn)
	return _core.batch_apply(an, _names(must), ocn, op_field, op, factor, addend)

## 批量边界钳制: col = clamp(col, min, max), min/max 取自其他组件字段
func batch_clamp(anchor, must: Array, op_comp, op_field: StringName, min_comp, min_field: StringName, max_comp, max_field: StringName) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	var mincn := _resolve_component_name(min_comp)
	var maxcn := _resolve_component_name(max_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(mincn)
	_record_access(maxcn)
	for mn in _names(must):
		_record_access(mn)
	_mark_dirty(ocn)
	return _core.batch_clamp(an, _names(must), ocn, op_field,
		mincn, min_field, maxcn, max_field)

## 批量向量积分: pos += vel * delta (Vector2/3)
func batch_vec_add(anchor, must: Array, pos_comp, pos_field: StringName, vel_comp, vel_field: StringName, delta: float) -> int:
	var an := _resolve_component_name(anchor)
	var pcn := _resolve_component_name(pos_comp)
	var vcn := _resolve_component_name(vel_comp)
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
		out.append(_resolve_component_name(a))
	return out

## 拥有某组件的实体总数。
func count(component) -> int:
	return _core.count_entities(_resolve_component_name(component))

# ============================================================
#  Command Buffer (延迟结构变更)
#  系统内排队 create/destroy/add_component/remove_component,
#  帧末 tick() 末尾统一 flush —— 遍历中不直接改结构(无重入/迭代失效),
#  为系统并行执行铺路。
# ============================================================

## 排队: 创建实体。返回负值占位句柄(-(创建序号+1)),
## 可用于 cmd_add_component/cmd_remove_component 引用, flush 后解析为真实实体。
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
	var name := _resolve_component_name(component)
	if name != &"":
		_cmd_mutex.lock()
		_core.cmd_add_component(entity, name)
		_cmd_ops.append(["add", entity, name])
		_cmd_mutex.unlock()

## 排队: 给实体移除组件(flush 时执行)。
func cmd_remove_component(entity: int, component) -> void:
	var name := _resolve_component_name(component)
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
## 按命令类型精确失效查询缓存: add/remove 组件只失效该组件, destroy 全局失效。
## flush 后在主线程触发对应组件钩子(占位实体经 created_entity_at 解析为真实实体)。
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
#  系统
# ============================================================

## 注册系统。priority 越大越先执行。
## before/after: 依赖声明的系统引用数组(该系统须在 after 之后、before 之前执行)。
func register_system(system: ECSSystem, priority: int = 0, before: Array = [], after: Array = []) -> void:
	if system == null or _systems.has(system):
		return
	# 系统内所需的组件必须在注册前已注册
	for comp in system.required_components():
		register_component(comp)
	_systems.append(system)
	_system_priorities.append(priority)
	_system_before.append(before)
	_system_after.append(after)
	# 预解析声明组件(静态, 供并行冲突检测)
	var declared := {}
	for c in system.read_components():
		var cn := _resolve_component_name(c)
		if cn != &"":
			declared[cn] = true
	for c in system.write_components():
		var cn := _resolve_component_name(c)
		if cn != &"":
			declared[cn] = true
	_system_access_declared[system] = declared
	_dirty_schedule = true
	# 系统初始化钩子(场景配置的 field_rules 等在此应用)
	system._on_registered(self)
	# 日志: 系统名 + 优先级 + 使用组件
	var sname := "?"
	if system.get_script() != null:
		sname = system.get_script().get_global_name()
	var used := PackedStringArray()
	for c in system.required_components():
		if c != null:
			used.append(str(c.get_global_name()))
	LogTool.log("ECS", "注册系统 %s (优先级 %d, 组件: %s)" % [sname, priority, ", ".join(used)])

func remove_system(system: ECSSystem) -> void:
	var i := _systems.find(system)
	if i >= 0:
		_systems.remove_at(i)
		_system_priorities.remove_at(i)
		_system_before.remove_at(i)
		_system_after.remove_at(i)
		_system_access_declared.erase(system)
		_access_sets.erase(system)
		_pending_access.erase(system)
		_dirty_schedule = true

## 每帧驱动全部系统。内部先按依赖图拓扑排序(优先级仅作同层平级次序)。
## 帧末自动 flush Command Buffer(延迟结构变更)。
## 系统级并行: 满足条件时, 按"组件访问冲突检测"把互不冲突的系统分批并行执行;
## 否则回退纯串行(行为与旧版一致)。并行开启时第一帧自动串行预热以采集访问记录。
func tick(delta: float) -> void:
	_frame_count += 1
	_resort()
	# 频率调度: 主线程先对每个系统做 interval/rate/fixed_step 判断, 标记本帧是否运行
	for system in _sorted:
		system._schedule(delta)
	var parallel_now := _should_parallel()
	_tracking = parallel_enabled
	if parallel_now:
		_parallel_batch_active = true
		_parallel_tick(delta)
		_parallel_batch_active = false
	else:
		for system in _sorted:
			if system._frame_delta < 0.0:
				continue
			_run_system(system)
	if _tracking:
		_finalize_access()
	_preheated = true
	_dispatch_events()
	cmd_flush()

## 依赖图拓扑排序: 满足 before/after 约束, 同层按优先级降序。
## 依赖冲突(环)时优先保留 priority 更高者, 弱化为无约束。
func _resort() -> void:
	if not _dirty_schedule:
		return
	_sorted.clear()
	_dirty_schedule = false
	if _systems.is_empty():
		return

	# 1) 建立 "系统 -> 其前置集合(必须先于它执行)" 映射
	var n := _systems.size()
	var prerequisites: Array = []  # 每项: Array[ECSSystem] 必须在其之前
	prerequisites.resize(n)
	# 预计算各系统的读写组件集合(用于自动推断)
	var sys_writes: Array = []   # 每项: Array[StringName] 写入组件
	var sys_reads: Array = []    # 每项: Array[StringName] 读取组件
	for i in n:
		var w: Array[StringName] = []
		for c in _systems[i].write_components():
			var cn: StringName = _resolve_component_name(c)
			if cn != &"":
				w.append(cn)
		sys_writes.append(w)
		var r: Array[StringName] = []
		for c in _systems[i].read_components():
			var cn: StringName = _resolve_component_name(c)
			if cn != &"":
				r.append(cn)
		sys_reads.append(r)
	for i in n:
		var pre: Array = []
		for other in _system_after[i]:
			if other is ECSSystem and _systems.has(other):
				pre.append(other)
		# before[b] = x 表示 x 必须在 b 之前 => 对 x 而言 b 是其 after
		for j in n:
			if _system_before[j].has(_systems[i]):
				pre.append(_systems[j])
		# 自动推断: 若该系统的 after/before 声明为空, 则按读写组件推断
		# 规则: 写某组件的系统, 必须在"读或写同一组件"的系统之前
		if _system_after[i].is_empty() and _system_before[i].is_empty():
			for j in n:
				if j == i:
					continue
				# 若 j 读/写了 i 写入的组件, 则 i 必须先于 j
				var conflict := false
				for ci in sys_writes[i]:
					if sys_reads[j].has(ci) or sys_writes[j].has(ci):
						conflict = true
						break
				if conflict and not pre.has(_systems[j]):
					pre.append(_systems[j])
		prerequisites[i] = pre

	# 2) Kahn 拓扑排序(每次取"前置全满足且优先级最高"者)
	var done := {}
	var result: Array = []
	while result.size() < n:
		var best := -1
		for i in n:
			if done.has(i):
				continue
			var ready := true
			for pre in prerequisites[i]:
				if not done.has(_systems.find(pre)):
					ready = false
					break
			if not ready:
				continue
			if best == -1 or _system_priorities[i] > _system_priorities[best]:
				best = i
		if best == -1:
			# 依赖环: 取剩余中优先级最高者强制执行, 破坏环
			for i in n:
				if done.has(i):
					continue
				if best == -1 or _system_priorities[i] > _system_priorities[best]:
					best = i
		done[best] = true
		result.append(_systems[best])
	_sorted.clear()
	for s in result:
		_sorted.append(s)

# ============================================================
#  系统级并行执行
# ============================================================

## 启用系统的数量(过滤 disabled)。
func _enabled_system_count() -> int:
	var n := 0
	for s in _sorted:
		if s.enabled:
			n += 1
	return n

## 是否进入并行执行。
## 条件: 开关打开 + 已过首帧串行预热(采集访问记录)。单系统也走 worker 线程(不占主线程)。
func _should_parallel() -> bool:
	if not parallel_enabled:
		return false
	return _preheated

## 记录"当前任务"对某组件的访问(供下一帧冲突检测)。
## 读+写全在 _access_mutex 内: 并行 worker 即使短暂共享目标集, 字典写入也被串行化,
## 杜绝"两个线程同时写同一 Dictionary"的内存竞争(C++ 段错误)。归属在极端时序下可能错乱,
## 但只影响冲突检测精度(可并行度), 不影响正确性 —— 真冲突系统由 declared 声明兜底串行化。
func _record_access(comp: StringName) -> void:
	if not _tracking or comp == &"":
		return
	_access_mutex.lock()
	if _access_target_active:
		_access_target[comp] = true
	_access_mutex.unlock()

## 帧末把本帧访问并入累积集(供下一帧分批)。
func _finalize_access() -> void:
	for s in _pending_access:
		_access_sets[s] = _pending_access[s]
	_pending_access.clear()

## 开启/关闭某系统的访问记录任务(锁内切换目标集, 与 _record_access 的锁内读写互斥)。
func _begin_access(system: ECSSystem) -> void:
	_access_mutex.lock()
	if not _pending_access.has(system):
		_pending_access[system] = {}
	_access_target = _pending_access[system]
	_access_target_active = true
	_access_mutex.unlock()

func _end_access() -> void:
	_access_mutex.lock()
	_access_target_active = false
	_access_target = {}
	_access_mutex.unlock()

## 串行执行单个系统(记录访问上下文)。用系统本帧调度后的 _frame_delta 作为 delta。
## 每系统独立 ctx; _run 结束后自动执行该系统未显式 execute 的查询。
func _run_system(system: ECSSystem) -> void:
	var delta: float = system._frame_delta
	if delta < 0.0:
		return
	var t0 := Time.get_ticks_usec()
	var ctx := ECSSystemContext.new(self)
	if not _tracking:
		system._run(ctx, delta)
		ctx._auto_execute()
		_record_system_time(system, t0)
		return
	_begin_access(system)
	system._run(ctx, delta)
	ctx._auto_execute()
	_end_access()
	_record_system_time(system, t0)

## 并行 worker 入口(在线程中执行系统)。
func _parallel_worker(system: ECSSystem) -> void:
	var delta: float = system._frame_delta
	if delta < 0.0:
		return
	var t0 := Time.get_ticks_usec()
	var ctx := ECSSystemContext.new(self)
	_begin_access(system)
	system._run(ctx, delta)
	ctx._auto_execute()
	_end_access()
	_record_system_time(system, t0)

## 记录系统本帧耗时(ms), 线程安全(并行 worker 也调用)。
func _record_system_time(system: ECSSystem, t0: int) -> void:
	_system_times_lock.lock()
	_system_times[system] = (Time.get_ticks_usec() - t0) / 1000.0
	_system_runs[system] = int(_system_runs.get(system, 0)) + 1
	_system_times_lock.unlock()

## 调试: 各系统本帧耗时(ms), 键为系统类名。
func get_system_times() -> Dictionary:
	var out := {}
	_system_times_lock.lock()
	for s in _system_times:
		var nm := "?"
		if s.get_script() != null:
			nm = s.get_script().get_global_name()
		out[nm] = _system_times[s]
	_system_times_lock.unlock()
	return out

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

## 调试: 各系统耗时与累计运行次数 {类名: {ms, runs}}(查看器表格列: 耗时/avg/max/调用)。
func get_system_stats() -> Dictionary:
	var out := {}
	_system_times_lock.lock()
	for s in _system_times:
		var nm := "?"
		if s.get_script() != null:
			nm = s.get_script().get_global_name()
		out[nm] = {"ms": _system_times[s], "runs": int(_system_runs.get(s, 0))}
	_system_times_lock.unlock()
	return out

## 调试: 系统拓扑(当前执行顺序 + 是否可并行)。
func get_topology() -> Dictionary:
	var order := []
	for s in _sorted:
		var nm := "?"
		if s.get_script() != null:
			nm = s.get_script().get_global_name()
		order.append({"name": nm, "parallel": s.can_run_parallel()})
	return {"order": order}

## 系统 a(索引)是否依赖 b(索引): b 必须先于 a 执行。
func _system_depends(a: int, b: int) -> bool:
	return _system_after[a].has(_systems[b]) or _system_before[b].has(_systems[a])

## 系统访问集合与批内已占用组件是否有交集。
func _sig_conflicts(acc: Dictionary, declared: Dictionary, cur_comps: Dictionary) -> bool:
	for c in acc:
		if cur_comps.has(c):
			return true
	for c in declared:
		if cur_comps.has(c):
			return true
	return false

## 输出 cur(合成一批) 与 barrier(各自单批), 按每组首系统在拓扑序中的位置排序,
## 保持相对顺序的同时让互无依赖的可并行系统聚成一批(顺序无关重排)。
func _flush_parallel(groups: Array, cur: Array, barrier: Array) -> void:
	if cur.is_empty() and barrier.is_empty():
		return
	var blocks := []  # Array[Array], 每组一个系统列表
	if not cur.is_empty():
		blocks.append(cur)
	for bs in barrier:
		blocks.append([bs])
	blocks.sort_custom(func(a, b): return _sorted.find(a[0]) < _sorted.find(b[0]))
	for blk in blocks:
		groups.append(blk)

## 基于上一帧访问记录 + 声明组件, 把系统分批:
## 批内任意两系统组件访问集合无交集 且 无 before/after 依赖(可安全并行)。
## 批间保持原拓扑顺序(串行)。
## 顺序无关重排: 不可并行系统(屏障)不打断当前批, 而是挂起——两侧无依赖的
## 可并行系统仍可同批(如 Move/Heal 被 Sync 隔开时也能并行), 屏障随后单独串行。
func _build_parallel_groups() -> Array:
	var groups := []
	var cur: Array = []       # 当前可并行批
	var cur_comps := {}       # cur 的组件占用
	var barrier: Array = []   # 挂起的不可并行系统(屏障, 按 _sorted 序)
	for s in _sorted:
		if not s.enabled or s._frame_delta < 0.0:
			continue
		if not s.can_run_parallel():
			# 屏障: 不打断当前批, 挂起; 后续加入 cur 的系统须与屏障无依赖
			barrier.append(s)
			continue
		var acc: Dictionary = _access_sets.get(s, {})
		var declared: Dictionary = _system_access_declared.get(s, {})
		var conflict := _sig_conflicts(acc, declared, cur_comps)
		if not conflict:
			var si := _systems.find(s)
			for cs in cur:
				var ci := _systems.find(cs)
				if _system_depends(si, ci) or _system_depends(ci, si):
					conflict = true
					break
			if not conflict:
				for bs in barrier:
					var bi := _systems.find(bs)
					if _system_depends(si, bi) or _system_depends(bi, si):
						conflict = true
						break
		if conflict:
			_flush_parallel(groups, cur, barrier)
			cur = []
			cur_comps = {}
			barrier = []
		cur.append(s)
		for c in acc:
			cur_comps[c] = true
		for c in declared:
			cur_comps[c] = true
	_flush_parallel(groups, cur, barrier)
	return groups

## 并行 tick: 按组串行、组内并行执行全部系统。
func _parallel_tick(delta: float) -> void:
	_pending_access.clear()
	var groups: Array = _build_parallel_groups()
	var max_par := _effective_threads()
	for group in groups:
		_run_group(group, delta, max_par)

## 执行一组系统。组内并行(线程数受 max_par 限制), 超量部分拆成子批。
## 不可并行系统(can_run_parallel=false, 如访问场景树)必须主线程串行;
## 可并行系统(含单系统)交给 worker 线程执行(系统逻辑不占主线程)。
func _run_group(group: Array, _delta: float, max_par: int) -> void:
	if group.size() == 1 and not group[0].can_run_parallel():
		_run_system(group[0])
		return
	var start := 0
	while start < group.size():
		var end := mini(start + max_par, group.size())
		_run_parallel_slice(group.slice(start, end))
		start = end

## 并行执行一批系统: 全部交给 C++ 持久 worker 池执行(免每帧临时建线程)。
func _run_parallel_slice(slice: Array) -> void:
	var tasks := []
	for s in slice:
		tasks.append(_parallel_worker.bind(s))
	_core.run_systems_parallel(tasks)

## 有效并行线程数(单个并行批最多并行多少个系统)。0=自动。
func _effective_threads() -> int:
	var n := parallel_threads
	if n <= 0:
		var cores := OS.get_processor_count()
		n = maxi(1, cores - 1)
		n = clampi(n, 1, 8)
	return n

## 是否正在使用并行执行(调试/UI 展示用)。
func is_parallel_active() -> bool:
	return _parallel_batch_active

## 上一帧并行组统计(调试/UI 展示用): {batches: int, max_group: int, parallel_groups: int}
func debug_parallel_stats() -> Dictionary:
	return {
		"parallel_enabled": parallel_enabled,
		"effective_threads": _effective_threads(),
		"tracked_systems": _access_sets.size(),
	}

# ============================================================
#  组件生命周期钩子 (on_add / on_remove / on_destroy)
#  触发时机: 立即版 add_component/remove_component 成功时; destroy_entity 时;
#            命令缓冲 flush 后(主线程, 并行系统内 cmd_* 的钩子安全在此触发)。
#  回调签名: func(entity: int)
# ============================================================

## 注册组件 add 钩子: 实体获得该组件后触发。
func on_component_added(comp, callable: Callable) -> void:
	var cn := _resolve_component_name(comp)
	if cn == &"":
		return
	if not _component_hooks.has(cn):
		_component_hooks[cn] = {"add": [], "remove": []}
	var arr: Array = _component_hooks[cn]["add"]
	if not arr.has(callable):
		arr.append(callable)
	_has_any_component_hooks = true

func off_component_added(comp, callable: Callable) -> void:
	var cn := _resolve_component_name(comp)
	if _component_hooks.has(cn):
		(_component_hooks[cn]["add"] as Array).erase(callable)

## 注册组件 remove 钩子: 实体失去该组件后触发(显式移除或实体销毁时)。
func on_component_removed(comp, callable: Callable) -> void:
	var cn := _resolve_component_name(comp)
	if cn == &"":
		return
	if not _component_hooks.has(cn):
		_component_hooks[cn] = {"add": [], "remove": []}
	var arr: Array = _component_hooks[cn]["remove"]
	if not arr.has(callable):
		arr.append(callable)
	_has_any_component_hooks = true

func off_component_removed(comp, callable: Callable) -> void:
	var cn := _resolve_component_name(comp)
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
#  变化检测 (组件级脏标记)
#  通过框架写 API 的字段修改会标记组件"本帧被写":
#    set_field / set_column / batch_apply / batch_apply_where / batch_clamp / batch_vec_add
#  注意: get_column 返回共享引用后原地修改不经过写 API, 不会被标记。
# ============================================================

## 标记组件本帧被写(写路径内部调用)。
func _mark_dirty(comp: StringName) -> void:
	if comp == &"":
		return
	_access_mutex.lock()
	_dirty_comps[comp] = _frame_count
	_access_mutex.unlock()

## 本帧内该组件是否被任何写 API 修改过(组件级, 非实体级)。
func is_component_dirty(comp) -> bool:
	var cn := _resolve_component_name(comp)
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
#  批量事件(替代信号风暴: 帧内累积, 帧末一次性派发)
# ============================================================

## 投递事件(帧末统一派发给订阅者)。
## payload 可为任意值; 也支持带实体信息的字典 {entity: id, data: ...}。
func emit_event(type: StringName, payload = null) -> void:
	_event_mutex.lock()
	if not _event_queues.has(type):
		_event_queues[type] = []
	_event_queues[type].append(payload)
	_event_mutex.unlock()

## 投递"实体事件": 指定事件的来源/目标实体。
## 订阅者可用 on_entity_event(带组件过滤)只收到相关实体的事件。
func emit_entity_event(type: StringName, entity: int, data = null) -> void:
	var payload := {"entity": entity, "data": data}
	emit_event(type, payload)

## 订阅事件。handler(payload)。
func on_event(type: StringName, handler: Callable) -> void:
	if not _event_subscribers.has(type):
		_event_subscribers[type] = []
	_event_subscribers[type].append(handler)

## 订阅"实体事件"并按组件过滤。
## 只收到: 事件携带 entity_id, 且该实体拥有全部 filter 组件。
## handler(entity_id, data)。
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
## conditions: Array[Dictionary] 同 batch_apply_where 条件格式。
## handler(entity_id, data)。
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
		var comp_name := _resolve_component_name(c.get("comp", &""))
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
#  序列化/存档 (对接 SaveTool)
# ============================================================

## 序列化整个世界的组件数据 → Dictionary, 可交给 SaveTool.save_data 存档。
func serialize() -> Dictionary:
	return _core.serialize()

## 反序列化: 重建实体与数据。
## 返回 Array[int]: 新建实体的真实实体 ID 列表(用它绑定 Component 等)。
## 注意: 组件需先 register_component(名称一致)再调用。
func deserialize(data: Dictionary) -> Array:
	var ids: Array = _core.deserialize(data)
	_world_version += 1  # 批量重建, 无法精确追踪 → 全局失效
	return ids

## 内存统计(调试)
func debug_stats() -> Dictionary:
	return _core.debug_stats()

# ============================================================
#  原生API层: 条件过滤批量(只处理满足条件的实体)
# ============================================================

## 条件过滤批量运算: 仅对满足全部条件的实体执行 op 运算。
## 参数含义:
##   anchor/must: 匹配实体的组件签名(anchor 必含, must 全含)
##   op_comp/op_field: 要修改的目标组件与字段
##   op: ECSWorld.BatchOp(ADD 加 / MUL_ADD 乘加 / SET 赋值)
##   factor: MUL_ADD 时的乘数; addend: ADD/MUL_ADD 时的加数
##   conditions: Array[Dictionary] 过滤条件, 每项 {comp, field, op, value}
##     - comp 可传组件类(Script)或类名(String); field 传字段名
##     - op: ECSWorld.CondOp(LT < / LE <= / GT > / GE >= / EQ == / NE !=)
## 返回处理的实体数。
##
## 示例(给 hp<50 的实体 +10):
##   world.batch_apply_where(HealthComponent, [], HealthComponent, &"hp",
##       ECSWorld.BatchOp.ADD_VALUE, 0.0, 10.0,
##       [{comp: HealthComponent, field: &"hp", op: ECSWorld.CondOp.LESS_THAN, value: 50}])
func batch_apply_where(anchor, must: Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float, conditions: Array) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(_resolve_component_name(c.get("comp", &"")))
	_mark_dirty(ocn)
	return _core.batch_apply_where(an, _names(must),
		ocn, op_field, op, factor, addend, _normalize_conds(conditions))

## 统计满足指定条件的实体数量(纯查询, 不修改任何数据)。
## conditions 格式同 batch_apply_where。
## 示例(统计血量不满的敌人数量):
##   world.batch_count_where(HealthComponent, [],
##       [{comp: HealthComponent, field: &"hp", op: ECSWorld.CondOp.LESS_THAN, value: 100}])
func batch_count_where(anchor, must: Array, conditions: Array) -> int:
	var an := _resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for c in conditions:
		_record_access(_resolve_component_name(c.get("comp", &"")))
	return _core.batch_count(an, _names(must), _normalize_conds(conditions))

## 批量收集: 单次遍历匹配 anchor+must(不含 without)的签名实体, 同时判定多组条件,
## 产出多组 anchor 行号。比逐查询各自 collect 省去 N 次全表扫描。
## groups: Array, 每组 = 条件列表(格式同 batch_apply_where, 空组 = 无条件 = 全部实体)。
## 返回 Array[PackedInt32Array], 第 i 组对应 groups[i] 满足条件的实体 anchor 行号。
func batch_collect(anchor, must: Array, without: Array, groups: Array) -> Array:
	var an := _resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for mn in _names(without):
		_record_access(mn)
	var norm_groups: Array = []
	for g in groups:
		for c in g:
			_record_access(_resolve_component_name(c.get("comp", &"")))
		norm_groups.append(_normalize_conds(g))
	return _core.batch_collect(an, _names(must), _names(without), norm_groups)

## 批量收集(条件已规范化, 跳过 _normalize_conds 开销; 查询链合并内部用, 配合 ECSQuery.get_norm_conditions 缓存)。
func batch_collect_norm(anchor, must: Array, without: Array, norm_groups: Array) -> Array:
	var an := _resolve_component_name(anchor)
	_record_access(an)
	for mn in _names(must):
		_record_access(mn)
	for mn in _names(without):
		_record_access(mn)
	return _core.batch_collect(an, _names(must), _names(without), norm_groups)

## 对预收集的行集做标量批量动作(跳过收集, 复用 batch_collect 的行集)。
## rows: anchor 行号(PackedInt32Array)。op: ECSWorld.BatchOp。支持向量分量字段(如 &"vel.x")。
func batch_apply_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	_record_access(an)
	_record_access(ocn)
	_mark_dirty(ocn)
	return _core.batch_apply_rows(an, rows, ocn, op_field, op, factor, addend)

## 对预收集的行集做列间动作(跳过收集): 目标列 = 目标列 OP (src列 * factor + addend)。
func batch_apply_col_rows(anchor, rows: PackedInt32Array, op_comp, op_field: StringName,
		src_comp, src_field: StringName, op: int, factor: float, addend: float) -> int:
	var an := _resolve_component_name(anchor)
	var ocn := _resolve_component_name(op_comp)
	var scn := _resolve_component_name(src_comp)
	_record_access(an)
	_record_access(ocn)
	_record_access(scn)
	_mark_dirty(ocn)
	return _core.batch_apply_col_rows(an, rows, ocn, op_field, scn, src_field, op, factor, addend)

## 批量执行多个动作(一次跨语言, 免逐动作跨语言调用)。
## actions: Array[Dictionary], 每项 {t:0=col列间,1=scalar标量, of, sf/sc?, op, f, v/add}。
func batch_apply_actions(anchor, rows: PackedInt32Array, actions: Array) -> int:
	var an := _resolve_component_name(anchor)
	_record_access(an)
	_mark_dirty(an)
	return _core.batch_apply_actions(an, rows, actions)

## 规范化条件列表: 把 comp(Script/String) → 类名 String, 便于 C++ 解析
func _normalize_conds(conditions: Array) -> Array:
	var out: Array = []
	for c in conditions:
		var d := {}
		d["comp"] = _resolve_component_name(c.get("comp", &""))
		d["field"] = str(c.get("field", &""))
		d["op"] = int(c.get("op", 0))
		d["value"] = c.get("value", 0.0)
		out.append(d)
	return out

# ============================================================
#  Prefab 预制体 (模板实体 + 批量实例化)
# ============================================================

## 创建 prefab 模板实体(带模板标记, 不参与普通查询/序列化)。
func create_prefab() -> int:
	return _core.create_prefab()

## 该实体是否为 prefab 模板
func is_prefab(entity: int) -> bool:
	return _core.is_prefab(entity)

## 给 prefab 模板添加组件并设置初始字段值。
## values: Dictionary {字段名: 初始值}
func prefab_add(prefab: int, component, values: Dictionary) -> bool:
	register_component(component) if component is Script else null
	var name := _resolve_component_name(component)
	if name != &"":
		_bump_comp(name)
	return _core.prefab_add(prefab, name, values)

## 批量实例化: 复制 prefab 的组件结构与字段值到 count 个新实体。
## overrides: Dictionary {组件类名: {字段名: 覆盖值}}(可选)
## 返回新实体 ID 数组(Array[int])。
func instantiate(prefab: int, count: int, overrides: Dictionary = {}) -> Array:
	# overrides 的 key 可能是 Script, 归一化为类名
	var norm_overrides := {}
	for k in overrides:
		norm_overrides[_resolve_component_name(k)] = overrides[k]
	_world_version += 1  # 批量生成实体 + 组件, 无法精确追踪 → 全局失效
	return _core.instantiate(prefab, count, norm_overrides)

## 便捷: 从 ECSPrefabDef 配置构建 prefab 模板, 返回 prefab 实体 ID。
## 配置用"组件实例数组": 每个实例的 @export 字段 = 该组件初始值。
## 之后可 world.instantiate(prefab, n) 批量生成。
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
## 返回新实体 ID 数组。
func spawn_from_def(def: ECSPrefabDef, count: int = 1, overrides: Dictionary = {}) -> Array:
	var prefab := build_prefab(def)
	if prefab < 0:
		return []
	return instantiate(prefab, count, overrides)

# ============================================================
#  暂停/恢复(对比时暂停未选中的世界)
# ============================================================

## 暂停或恢复世界(暂停 = 不执行任何系统, 用于多世界对比)。
func set_paused(paused: bool) -> void:
	for s in _systems:
		s.enabled = not paused
