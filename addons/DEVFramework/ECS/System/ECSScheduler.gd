class_name ECSScheduler
extends RefCounted

## 系统调度器：注册表 + 拓扑排序 + 频率节流 + 串行/并行执行 + 耗时统计。

var world: ECSWorld

# ---------------- 系统注册表 ----------------
var _systems: Array[ECSSystem] = []
var _system_index := {}          # ECSSystem -> _systems 下标(增量维护)
var _system_priorities: Array[int] = []
var _system_before: Array = []   # 每系统: 必须在其后执行的系统
var _system_after: Array = []    # 每系统: 必须在其前执行的系统
var _sorted: Array[ECSSystem] = []
var _sorted_index := {}          # ECSSystem -> _sorted 下标(批分组排序/依赖判定用)
var _dirty_schedule := true

# ---------------- 并行调度 ----------------
var parallel_enabled: bool = true
## 并行线程数。0=自动(硬件核数-1, 上限 8)。
var parallel_threads: int = 0

var _tracking := false                    # 本帧是否追踪组件访问
var _preheated := false                   # 是否已完成首帧串行预热(此后才允许并行)
var _parallel_batch_active := false       # 本帧正处于并行批(查询缓存据此禁用)
var _access_sets := {}                    # ECSSystem -> {compName:true} 上一帧累积访问
var _pending_access := {}                 # ECSSystem -> {compName:true} 本帧访问缓冲
var _access_target: Dictionary = {}       # 当前任务的访问目标集(读写都在锁内)
var _access_target_active := false
var _system_access_declared := {}         # ECSSystem -> {compName:true} 声明的读写组件
var _access_mutex := Mutex.new()

# ---------------- 耗时统计 ----------------
var _times := {}                          # ECSSystem -> 本帧耗时 ms(并行安全)
var _runs := {}                           # ECSSystem -> 累计运行次数
var _times_lock := Mutex.new()


func _init(owner: ECSWorld) -> void:
	world = owner


# ============================================================

## 注册系统。priority 越大越先执行；不传则取 system.priority。
func register(system: ECSSystem, priority = null, before: Array = [], after: Array = []) -> void:
	if system == null or _system_index.has(system):
		return
	var prio := system.priority if priority == null else int(priority)
	# 系统内所需的组件必须在注册前已注册
	for comp in system.required_components():
		world.register_component(comp)
	_system_index[system] = _systems.size()
	_systems.append(system)
	_system_priorities.append(prio)
	_system_before.append(before)
	_system_after.append(after)
	# 预解析声明组件(静态, 供并行冲突检测)
	var declared := {}
	for c in system.read_components():
		var cn := world.resolve_component_name(c)
		if cn != &"":
			declared[cn] = true
	for c in system.write_components():
		var cn := world.resolve_component_name(c)
		if cn != &"":
			declared[cn] = true
	_system_access_declared[system] = declared
	_dirty_schedule = true
	# 系统初始化钩子(需要世界引用的实现在此保存)
	system._on_registered(world)
	# 日志: 系统名 + 优先级 + 使用组件
	var used := PackedStringArray()
	for c in system.required_components():
		if c != null:
			used.append(str(c.get_global_name()))
	LogTool.log("ECS", "注册系统 %s (优先级 %d, 组件: %s)" % [system.get_system_name(), prio, ", ".join(used)])


func remove(system: ECSSystem) -> void:
	var i: int = _system_index.get(system, -1)
	if i < 0:
		return
	_systems.remove_at(i)
	_system_priorities.remove_at(i)
	_system_before.remove_at(i)
	_system_after.remove_at(i)
	_system_index.erase(system)
	# 被删位置之后的元素整体前移一位, 增量重建其下标
	for k in range(i, _systems.size()):
		_system_index[_systems[k]] = k
	_system_access_declared.erase(system)
	_access_sets.erase(system)
	_pending_access.erase(system)
	_dirty_schedule = true


## 已注册系统(副本, 供宿主只读遍历; 不要在遍历中注册/移除)。
func get_systems() -> Array[ECSSystem]:
	return _systems.duplicate()


## 某系统的注册优先级(0 = 未注册)。
func get_priority(system: ECSSystem) -> int:
	var i: int = _system_index.get(system, -1)
	return _system_priorities[i] if i >= 0 else 0


## 暂停/恢复全部系统。⚠️ 会覆盖各系统自己的 enabled(恢复时一律置 true)。
func set_paused(paused: bool) -> void:
	for s in _systems:
		s.enabled = not paused


# ============================================================

## 驱动一帧：排序 → 频率判定 → 串行或并行执行 → 并入访问记录。
func tick(delta: float) -> void:
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


## 记录"当前任务"对某组件的访问(供下一帧冲突检测)。竞态只影响可并行度, 不影响正确性。
func record_access(comp: StringName) -> void:
	if not _tracking or comp == &"":
		return
	_access_mutex.lock()
	if _access_target_active:
		_access_target[comp] = true
	_access_mutex.unlock()


## 是否正在使用并行执行(调试/UI 用)。
func is_parallel_active() -> bool:
	return _parallel_batch_active


## 并行统计(调试/UI 用)。
func debug_parallel_stats() -> Dictionary:
	return {
		"parallel_enabled": parallel_enabled,
		"effective_threads": _effective_threads(),
		"tracked_systems": _access_sets.size(),
	}


# ============================================================

## 各系统本帧耗时(ms), 键为系统名。
func get_system_times() -> Dictionary:
	var out := {}
	_times_lock.lock()
	for s in _times:
		out[s.get_system_name()] = _times[s]
	_times_lock.unlock()
	return out


## 各系统耗时与累计运行次数 {名字: {ms, runs}}(查看器表格用)。
func get_system_stats() -> Dictionary:
	var out := {}
	_times_lock.lock()
	for s in _times:
		out[s.get_system_name()] = {"ms": _times[s], "runs": int(_runs.get(s, 0))}
	_times_lock.unlock()
	return out


## 当前执行顺序 + 是否可并行。
func get_topology() -> Dictionary:
	var order := []
	for s in _sorted:
		order.append({"name": s.get_system_name(), "parallel": s.can_run_parallel()})
	return {"order": order}


# ============================================================

## 依赖图拓扑排序: 满足 before/after 约束, 同层按优先级降序。依赖环时优先保留高优先级者。
func _resort() -> void:
	if not _dirty_schedule:
		return
	_sorted.clear()
	_sorted_index.clear()
	_dirty_schedule = false
	if _systems.is_empty():
		return

	# 1) 建立 "系统 -> 其前置集合(必须先于它执行)" 映射
	var n := _systems.size()
	var prerequisites: Array = []
	prerequisites.resize(n)
	var sys_writes: Array = []   # 每项: Array[StringName] 写入组件
	var sys_reads: Array = []    # 每项: Array[StringName] 读取组件
	for i in n:
		var w: Array[StringName] = []
		for c in _systems[i].write_components():
			var cn: StringName = world.resolve_component_name(c)
			if cn != &"":
				w.append(cn)
		sys_writes.append(w)
		var r: Array[StringName] = []
		for c in _systems[i].read_components():
			var cn: StringName = world.resolve_component_name(c)
			if cn != &"":
				r.append(cn)
		sys_reads.append(r)
	for i in n:
		var pre: Array = []
		for other in _system_after[i]:
			if other is ECSSystem and _system_index.has(other):
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
				if not done.has(_system_index.get(pre, -1)):
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
	_sorted_index.clear()
	for k in result.size():
		var s: ECSSystem = result[k]
		_sorted.append(s)
		_sorted_index[s] = k


## 是否进入并行执行: 开关打开 + 已过首帧串行预热(采集访问记录)。
func _should_parallel() -> bool:
	if not parallel_enabled:
		return false
	return _preheated


## 帧末把本帧访问并入累积集(供下一帧分批)。
func _finalize_access() -> void:
	for s in _pending_access:
		_access_sets[s] = _pending_access[s]
	_pending_access.clear()


## 开启某系统的访问记录任务(锁内切换目标集, 与 record_access 的锁内读写互斥)。
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


## 串行执行单个系统。用本帧调度后的 _frame_delta 作为 delta。
func _run_system(system: ECSSystem) -> void:
	var delta: float = system._frame_delta
	if delta < 0.0:
		return
	var t0 := Time.get_ticks_usec()
	var ctx := ECSSystemContext.new(world)
	if not _tracking:
		system._run(ctx, delta)
		ctx._auto_execute()
		_record_time(system, t0)
		return
	_begin_access(system)
	system._run(ctx, delta)
	ctx._auto_execute()
	_end_access()
	_record_time(system, t0)


## 并行 worker 入口(在线程中执行系统)。
func _parallel_worker(system: ECSSystem) -> void:
	var delta: float = system._frame_delta
	if delta < 0.0:
		return
	var t0 := Time.get_ticks_usec()
	var ctx := ECSSystemContext.new(world)
	_begin_access(system)
	system._run(ctx, delta)
	ctx._auto_execute()
	_end_access()
	_record_time(system, t0)


## 记录系统本帧耗时(ms), 线程安全(并行 worker 也调用)。
func _record_time(system: ECSSystem, t0: int) -> void:
	_times_lock.lock()
	_times[system] = (Time.get_ticks_usec() - t0) / 1000.0
	_runs[system] = int(_runs.get(system, 0)) + 1
	_times_lock.unlock()


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


## 输出 cur(合成一批) 与 barrier(各自单批), 按每组首系统在拓扑序中的位置排序。
func _flush_parallel(groups: Array, cur: Array, barrier: Array) -> void:
	if cur.is_empty() and barrier.is_empty():
		return
	var blocks := []
	if not cur.is_empty():
		blocks.append(cur)
	for bs in barrier:
		blocks.append([bs])
	blocks.sort_custom(func(a, b): return _sorted_index.get(a[0], -1) < _sorted_index.get(b[0], -1))
	for blk in blocks:
		groups.append(blk)


## 基于上一帧访问记录 + 声明组件, 把系统分批(批内无交集、无依赖; 批间保持拓扑顺序)。
func _build_parallel_groups() -> Array:
	var groups := []
	var cur: Array = []
	var cur_comps := {}
	var barrier: Array = []
	for s in _sorted:
		if not s.enabled or s._frame_delta < 0.0:
			continue
		if not s.can_run_parallel():
			barrier.append(s)
			continue
		var acc: Dictionary = _access_sets.get(s, {})
		var declared: Dictionary = _system_access_declared.get(s, {})
		var conflict := _sig_conflicts(acc, declared, cur_comps)
		if not conflict:
			var si: int = _system_index.get(s, -1)
			for cs in cur:
				var ci: int = _system_index.get(cs, -1)
				if _system_depends(si, ci) or _system_depends(ci, si):
					conflict = true
					break
			if not conflict:
				for bs in barrier:
					var bi: int = _system_index.get(bs, -1)
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
func _parallel_tick(_delta: float) -> void:
	_pending_access.clear()
	var groups: Array = _build_parallel_groups()
	var max_par := _effective_threads()
	for group in groups:
		_run_group(group, max_par)


## 执行一组系统。不可并行系统(如访问场景树)必须主线程串行。
func _run_group(group: Array, max_par: int) -> void:
	if group.size() == 1 and not group[0].can_run_parallel():
		_run_system(group[0])
		return
	var start := 0
	while start < group.size():
		var end := mini(start + max_par, group.size())
		_run_parallel_slice(group.slice(start, end))
		start = end


## 并行执行一批系统: 交给 C++ 持久 worker 池(免每帧临时建线程)。
func _run_parallel_slice(slice: Array) -> void:
	var tasks := []
	for s in slice:
		tasks.append(_parallel_worker.bind(s))
	world.native().run_systems_parallel(tasks)


## 有效并行线程数(单个并行批最多并行多少个系统)。0=自动。
func _effective_threads() -> int:
	var n := parallel_threads
	if n <= 0:
		n = maxi(1, OS.get_processor_count() - 1)
		n = clampi(n, 1, 8)
	return n
