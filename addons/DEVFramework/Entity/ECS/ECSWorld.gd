class_name ECSWorld
extends RefCounted

## ECS 世界 —— 用户主入口。持有 C++ 核心(ECSCore), 提供:
##   - 组件注册 / 实体创建与销毁
##   - 系统注册与按优先级调度(tick)
##   - 批量查询与列访问(高频路径)
##   - 批量事件队列(替代信号风暴)
##
## 用法:
##   var world = ECSWorld.new()
##   world.register_component(HealthComponent)      # 自动反射 schema
##   var e = world.create_entity()
##   world.add_component(e, HealthComponent)
##   world.register_system(HealSystem.new())        # ECSSystem 子类
##   world.tick(delta)                              # 每帧调用(或挂 ECSTick Node)

## —— 批量运算操作符(传给 batch_apply / batch_apply_if 的 op 参数) ——
enum BatchOp {
	ADD_VALUE = 0,       # 加值:   col += addend
	MULTIPLY_ADD = 1,    # 乘加:   col = col * factor + addend
	SET_VALUE = 2,       # 赋值:   col = addend
}

## —— 条件比较符(传给 batch_apply_if / batch_count_if 的 conditions.op) ——
enum CondOp {
	LESS_THAN = 0,        # <   小于
	LESS_OR_EQUAL = 1,    # <=  小于等于
	GREATER_THAN = 2,     # >   大于
	GREATER_OR_EQUAL = 3, # >=  大于等于
	EQUAL = 4,            # ==  等于
	NOT_EQUAL = 5,        # !=  不等于
}

# ---------------- 核心句柄 ----------------
var _core: Object = null                 # ECSCore 原生实例
var _available: bool = false

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

# ---------------- 事件队列 ----------------
var _event_queues := {}                  # type(StringName) -> Array[Variant]
var _event_subscribers := {}             # type(StringName) -> Array[Callable]

# ---------------- 查询缓存 ----------------
var _query_cache := {}                   # 查询签名 -> PackedInt32Array
var _cache_version := 0                  # 结构版本(实体/组件变化时 +1)
var _query_cache_version := -1           # 缓存对应的版本

func _init(use_shared_core: bool = true) -> void:
	# 默认使用全局共享核心(游戏通常只有一个世界);
	# 需要多个隔离世界(如性能对比/沙盒)时传 false 创建独立核心。
	if use_shared_core:
		_core = ECSNative.get_instance()
	else:
		_core = ClassDB.instantiate(&"ECSCore")
	_available = _core != null

## 原生层是否可用(不可用时所有操作静默失败)
func is_native_available() -> bool:
	return _available

## 原生实例(高级用法直接调用)
func native() -> Object:
	return _core

# ============================================================
#  组件注册
# ============================================================

## 注册组件类(ECSComponent 子类)。重复注册幂等。
## 通过当前世界自己的 _core 注册(不依赖全局单例)。
func register_component(component_class: Script) -> bool:
	if not _available:
		return false
	if _component_registered.get(component_class, false):
		return true
	var probe: Variant = ECSNative.instantiate_script(component_class)
	if probe == null:
		return false
	var schema: Dictionary = probe.get_schema()
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
	_components.append(component_class)
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
func create_entity() -> int:
	var e: int = _core.create_entity() if _available else -1
	if e >= 0:
		_cache_version += 1
	return e

func is_alive(entity: int) -> bool:
	return _available and _core.is_alive(entity)

## 销毁实体(从所有组件移除, 复用 id 防悬垂)
func destroy_entity(entity: int) -> void:
	if _available:
		_core.destroy_entity(entity)
		_cache_version += 1

## 给实体附加组件。component 传 ECSComponent 子类或已注册类名。
func add_component(entity: int, component, def_data: Dictionary = {}) -> bool:
	if not _available:
		return false
	var name := _resolve_component_name(component)
	if name == &"":
		return false
	if not _core.add_component(entity, name):
		return false
	_cache_version += 1
	# 附加后用 def_data 覆盖默认值(可选, 数据驱动兼容)
	for k in def_data:
		_core.set_field(entity, name, StringName(k), def_data[k])
	return true

func has_component(entity: int, component) -> bool:
	if not _available:
		return false
	var name := _resolve_component_name(component)
	return name != &"" and _core.has_component(entity, name)

func remove_component(entity: int, component) -> void:
	if not _available:
		return
	var name := _resolve_component_name(component)
	if name != &"":
		_core.remove_component(entity, name)
		_cache_version += 1

func _resolve_component_name(component) -> StringName:
	if component is Script:
		var n: StringName = _component_names.get(component, &"")
		if n != &"":
			return n
		# 未注册: 尝试从 resource_path 稳定获取类名
		var probe: Variant = ECSNative.instantiate_script(component)
		if probe != null:
			return probe.get_schema().name
		return &""
	if component is StringName or component is String:
		return StringName(component)
	return &""

# ============================================================
#  字段访问(低频: 单实体)
# ============================================================

func get_field(entity: int, component, field: StringName):
	return _core.get_field(entity, _resolve_component_name(component), field)

func set_field(entity: int, component, field: StringName, value) -> void:
	_core.set_field(entity, _resolve_component_name(component), field, value)

# ============================================================
#  批量查询与列访问(高频: 系统内)
# ============================================================

## 查询匹配实体(返回 anchor 组件的 dense 行号列表)。
## anchor/must/without 传组件类名或 Script。
## 行号可直接索引 get_column 返回的列 —— 列按行号紧凑存储(缓存友好, 内存紧凑)。
## 注意: 行号属于 anchor 组件; 跨组件访问时, 先 entity_of_row(anchor, row) 取实体ID,
##       再 row_of_entity(other_comp, entity) 得其他组件的行号。
## 需要实体 ID 时用 entity_of_row() 转换。
## 带缓存: 相同签名查询复用结果, 实体/组件结构变化时自动失效。
func query_rows(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	if not _available:
		return PackedInt32Array()
	var anchor_name := _resolve_component_name(anchor)
	if anchor_name == &"":
		return PackedInt32Array()
	var must_names := PackedStringArray()
	for m in must:
		must_names.append(_resolve_component_name(m))
	var without_names := PackedStringArray()
	for w in without:
		without_names.append(_resolve_component_name(w))
	var key := str(anchor_name) + "|" + str(must_names) + "|" + str(without_names)
	if _query_cache.has(key) and _query_cache_version == _cache_version:
		return _query_cache[key]
	var result: PackedInt32Array = _core.query_rows(anchor_name, must_names, without_names)
	if _query_cache.size() > 64:
		_query_cache.clear()  # 缓存过大时清空(防内存膨胀)
	_query_cache[key] = result
	_query_cache_version = _cache_version
	return result

## 取整列数据(返回 Packed 数组拷贝, 按 anchor 组件的 dense 行号索引)。
func get_column(component, field: StringName):
	if not _available:
		return null
	return _core.get_column(_resolve_component_name(component), field)

## 整列写回(按行号)。
func set_column(component, field: StringName, values) -> void:
	if _available:
		_core.set_column(_resolve_component_name(component), field, values)

## 行号 -> 实体 id(anchor 组件的 dense 行号转实体)。
func entity_of_row(component, row: int) -> int:
	return _core.entity_of_row(_resolve_component_name(component), row) if _available else -1

## 实体 id -> 行号(某组件的 dense 行号, 用于跨组件列访问)。
func row_of_entity(component, entity: int) -> int:
	return _core.row_of_entity(_resolve_component_name(component), entity) if _available else -1

# ---- 原生API层: 批量运算(纯 C++ 循环, 无 GDScript 解释开销) ----

## 批量数值变换(anchor 组件中同时拥有 must 的实体, 对 op 字段原地运算)。
## op: ECSWorld.BatchOp(ADD=0 加法, MUL_ADD=1 乘加, SET=2 赋值)
func batch_apply(anchor, must: Array, op_comp, op_field: StringName, op: int, factor: float, addend: float) -> int:
	if not _available:
		return 0
	return _core.batch_apply(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(op_comp), op_field, op, factor, addend)

## 批量边界钳制: col = clamp(col, min, max), min/max 取自其他组件字段
func batch_clamp(anchor, must: Array, op_comp, op_field: StringName, min_comp, min_field: StringName, max_comp, max_field: StringName) -> int:
	if not _available:
		return 0
	return _core.batch_clamp(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(op_comp), op_field,
		_resolve_component_name(min_comp), min_field,
		_resolve_component_name(max_comp), max_field)

## 批量向量积分: pos += vel * delta (Vector2/3)
func batch_vec_add(anchor, must: Array, pos_comp, pos_field: StringName, vel_comp, vel_field: StringName, delta: float) -> int:
	if not _available:
		return 0
	return _core.batch_vec_add(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(pos_comp), pos_field,
		_resolve_component_name(vel_comp), vel_field, delta)

func _names(arr: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for a in arr:
		out.append(_resolve_component_name(a))
	return out

## 拥有某组件的实体总数。
func count(component) -> int:
	if not _available:
		return 0
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
	if not _available:
		return -1
	_core.cmd_create()
	_cmd_create_count += 1
	return -_cmd_create_count  # -(序号+1) 负句柄

## 排队: 销毁实体(flush 时执行, 若已死亡则忽略)。
func cmd_destroy(entity: int) -> void:
	if _available and entity >= 0:
		_core.cmd_destroy(entity)

## 排队: 给实体加组件(flush 时执行)。
func cmd_add_component(entity: int, component) -> void:
	if not _available:
		return
	var name := _resolve_component_name(component)
	if name != &"":
		_core.cmd_add_component(entity, name)

## 排队: 给实体移除组件(flush 时执行)。
func cmd_remove_component(entity: int, component) -> void:
	if not _available:
		return
	var name := _resolve_component_name(component)
	if name != &"":
		_core.cmd_remove_component(entity, name)

## 待执行命令数。
func cmd_pending_count() -> int:
	return _core.pending_command_count() if _available else 0

## 立即执行全部排队命令(通常由 tick() 帧末自动调用)。
func flush_commands() -> void:
	if _available:
		_core.flush_commands()
		_cache_version += 1
	_cmd_create_count = 0  # 句柄仅在当帧内有效

var _cmd_create_count: int = 0

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
	_dirty_schedule = true

func remove_system(system: ECSSystem) -> void:
	var i := _systems.find(system)
	if i >= 0:
		_systems.remove_at(i)
		_system_priorities.remove_at(i)
		_system_before.remove_at(i)
		_system_after.remove_at(i)
		_dirty_schedule = true

## 每帧驱动全部系统。内部先按依赖图拓扑排序(优先级仅作同层平级次序)。
## 帧末自动 flush Command Buffer(延迟结构变更)。
func tick(delta: float) -> void:
	if not _available:
		return
	_resort()
	var ctx := ECSSystemContext.new(self)
	for system in _sorted:
		if not system.enabled:
			continue
		system._run(ctx, delta)
	_dispatch_events()
	flush_commands()

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
			if other != null and _systems.has(other):
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
#  批量事件(替代信号风暴: 帧内累积, 帧末一次性派发)
# ============================================================

## 投递事件(帧末统一派发给订阅者)。
## payload 可为任意值; 也支持带实体信息的字典 {entity: id, data: ...}。
func emit_event(type: StringName, payload = null) -> void:
	if not _event_queues.has(type):
		_event_queues[type] = []
	_event_queues[type].append(payload)

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
## conditions: Array[Dictionary] 同 batch_apply_if 条件格式。
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
	return _event_queues.has(type) and not _event_queues[type].is_empty()

## 待派发事件总数(帧末统计用)
func pending_event_count() -> int:
	var total := 0
	for type in _event_queues:
		total += (_event_queues[type] as Array).size()
	return total

## 订阅某事件的处理器数量
func subscriber_count(type: StringName) -> int:
	return (_event_subscribers.get(type, []) as Array).size()

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
	for type in _event_queues:
		var queue: Array = _event_queues[type]
		if queue.is_empty():
			continue
		var handlers: Array = _event_subscribers.get(type, [])
		for payload in queue:
			for h in handlers:
				h.call(payload)
		queue.clear()

# ============================================================
#  序列化/存档 (对接 SaveTool)
# ============================================================

## 序列化整个世界的组件数据 → Dictionary, 可交给 SaveTool.save_data 存档。
func serialize() -> Dictionary:
	return _core.serialize() if _available else {}

## 反序列化: 重建实体与数据。
## 返回 Array[int]: 新建实体的真实实体 ID 列表(用它绑定 ECSNode 等)。
## 注意: 组件需先 register_component(名称一致)再调用。
func deserialize(data: Dictionary) -> Array:
	return _core.deserialize(data) if _available else []

## 内存统计(调试)
func debug_stats() -> Dictionary:
	return _core.debug_stats() if _available else {}

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
##   world.batch_apply_if(HealthComponent, [], HealthComponent, &"hp",
##       ECSWorld.BatchOp.ADD_VALUE, 0.0, 10.0,
##       [{comp: HealthComponent, field: &"hp", op: ECSWorld.CondOp.LESS_THAN, value: 50}])
func batch_apply_if(anchor, must: Array, op_comp, op_field: StringName,
		op: int, factor: float, addend: float, conditions: Array) -> int:
	if not _available:
		return 0
	return _core.batch_apply_where(_resolve_component_name(anchor), _names(must),
		_resolve_component_name(op_comp), op_field, op, factor, addend, _normalize_conds(conditions))

## 便捷: 给满足条件的实体的目标字段增加值 amount。
## 等价于 batch_apply_if(..., BatchOp.ADD_VALUE, 0.0, amount, conditions)。
## 示例(给 hp<50 的实体回血 10):
##   world.batch_add_value_if(HealthComponent, [], HealthComponent, &"hp", 10.0,
##       [{comp: HealthComponent, field: &"hp", op: ECSWorld.CondOp.LESS_THAN, value: 50}])
func batch_add_value_if(anchor, must: Array, op_comp, op_field: StringName,
		amount: float, conditions: Array) -> int:
	return batch_apply_if(anchor, must, op_comp, op_field, BatchOp.ADD_VALUE, 0.0, amount, conditions)

## 便捷: 给满足条件的实体的目标字段设置为 value。
## 等价于 batch_apply_if(..., BatchOp.SET_VALUE, 0.0, value, conditions)。
func batch_set_value_if(anchor, must: Array, op_comp, op_field: StringName,
		value: float, conditions: Array) -> int:
	return batch_apply_if(anchor, must, op_comp, op_field, BatchOp.SET_VALUE, 0.0, value, conditions)

## 统计满足指定条件的实体数量(纯查询, 不修改任何数据)。
## conditions 格式同 batch_apply_if。
## 示例(统计血量不满的敌人数量):
##   world.batch_count_if(HealthComponent, [],
##       [{comp: HealthComponent, field: &"hp", op: ECSWorld.CondOp.LESS_THAN, value: 100}])
func batch_count_if(anchor, must: Array, conditions: Array) -> int:
	if not _available:
		return 0
	return _core.batch_count(_resolve_component_name(anchor), _names(must), _normalize_conds(conditions))

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
	return _core.create_prefab() if _available else -1

## 该实体是否为 prefab 模板
func is_prefab(entity: int) -> bool:
	return _available and _core.is_prefab(entity)

## 给 prefab 模板添加组件并设置初始字段值。
## values: Dictionary {字段名: 初始值}
func prefab_add(prefab: int, component, values: Dictionary) -> bool:
	if not _available:
		return false
	register_component(component) if component is Script else null
	return _core.prefab_add(prefab, _resolve_component_name(component), values)

## 批量实例化: 复制 prefab 的组件结构与字段值到 count 个新实体。
## overrides: Dictionary {组件类名: {字段名: 覆盖值}}(可选)
## 返回新实体 ID 数组(Array[int])。
func instantiate(prefab: int, count: int, overrides: Dictionary = {}) -> Array:
	if not _available:
		return []
	# overrides 的 key 可能是 Script, 归一化为类名
	var norm_overrides := {}
	for k in overrides:
		norm_overrides[_resolve_component_name(k)] = overrides[k]
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
		# 提取该组件实例的所有 @export 字段值(与 schema 反射一致)
		var fields := {}
		for p in inst.get_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				fields[p.name] = inst.get(p.name)
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
#  声明规则层 (ECSRule: 遍历→条件→动作, C++ 批量执行)
# ============================================================

## 注册声明规则(自动包成 ECSRuleSystem 加入世界, 每帧执行)。
## priority 与 register_system 一致(越大越先执行)。
func register_rule(rule: ECSRule, priority: int = 0) -> ECSRuleSystem:
	var system := ECSRuleSystem.new()
	system.add_rule(rule)
	register_system(system, priority)
	return system

# ============================================================
#  暂停/恢复(对比时暂停未选中的世界)
# ============================================================

## 暂停或恢复世界(暂停 = 不执行任何系统, 用于多世界对比)。
func set_paused(paused: bool) -> void:
	if not _available:
		return
	for s in _systems:
		s.enabled = not paused
