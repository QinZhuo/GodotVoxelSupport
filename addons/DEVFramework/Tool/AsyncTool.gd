@tool
## 异步工具 — WorkerThreadPool 后台任务 + Signal 等待 + 轮询等待 + 资源异步加载
class_name AsyncTool

## 异步加载资源，返回 Resource 或 null
static func load_resource_async(path: String) -> Resource:
	var _t := LogTool.timer("异步", str("加载资源: ", path.get_file()))
	ResourceLoader.load_threaded_request(path)
	LogTool.log("异步", "开始请求: ", path.get_file())
	await await_until(func():
		return ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_IN_PROGRESS
	)
	var result: Variant = ResourceLoader.load_threaded_get(path) if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED else null
	if result:
		LogTool.log("异步", "加载完成: ", path.get_file())
	else:
		LogTool.warn("异步", "加载失败: ", path.get_file())
	_t.stop()
	return result

## 在后台线程执行 work，通过 Dictionary 容器返回结果（is_task_completed 保证同步，无需 Mutex）
static func thread_call(work: Callable) -> Variant:
	var data := {}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = work.call()
	)
	await await_until(func(): return WorkerThreadPool.is_task_completed(task_id))
	return data.get("result")

## 在后台线程执行 work 并**实时回报进度**。
## work 签名: func(progress: Dictionary) -> Variant, 内部周期性 progress["p"] = 0.0..1.0
## (worker 线程只写纯数据字典, 不调用任何 GDScript 回调 → 线程安全)。
## on_progress 在主线程每帧被回调(进度 0..1)。返回 work 的结果。
## 示例:
##   var result = await AsyncTool.thread_call_with_progress(
##       func(progress):
##           for i in 100:
##               progress["p"] = i / 100.0
##           return "done",
##       func(p): print("进度 ", p))
static func thread_call_with_progress(work: Callable, on_progress: Callable = func(_p: float): pass) -> Variant:
	var data := {"progress": 0.0}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = work.call(data)
	)
	# 主线程每帧轮询进度并回调(worker 线程只写 data 纯数据字段, 主线程读 → 安全)
	# 优先读 work 写的 data["p"](细分进度), 回退 data["progress"]
	while not WorkerThreadPool.is_task_completed(task_id):
		on_progress.call(data.get("p", data.get("progress", 0.0)))
		await Engine.get_main_loop().process_frame
	on_progress.call(data.get("p", data.get("progress", 1.0)))
	return data.get("result")

## 等待计时基准（见 await_until）
enum TimeBase {
	PHYSICS_TICK,  ## 物理 tick：与游戏步长对齐、受 time_scale 影响 —— 游戏逻辑用
	REAL_TIME,     ## 真实时间：与玩家体感一致、不受 time_scale 影响 —— 退出/超时兜底用
}

## poll done() 直到返回 true；带超时检测，超时后强制继续并打印警告日志。
## [param done] 完成检测回调，返回 true 视为完成
## [param timeout_ms] 超时时间（毫秒）。>0 启用超时检测，<=0 表示不限时
## [param log_name] 超时日志标识（可选，便于定位）
## [param base] 计时基准（见 TimeBase）：
##   · PHYSICS_TICK（默认）—— 按**物理 tick**（physics_ticks_per_second，本项目 30Hz 固定步长）计，
##     恢复点落在固定 tick 边界上，否则"这一回合/这一步何时算结束"会随帧率与帧抖动漂移
##     （回放实测：同一份记录会走成不同回合数）；物理 tick 同样受 time_scale 影响 ⇒ 慢动作/暂停语义不变。
##   · REAL_TIME —— 按 `Time.get_ticks_msec()` 计，用于必须与玩家体感时间一致的场景（退出、超时兜底）：
##     物理 tick 受 time_scale 影响，慢动作 0.3 倍速会把 3s 的等待拖成 ~10s。
## [return] 条件是否在超时前成立（未超时返回 true；未启用超时则恒为 true）
static func await_until(done: Callable, timeout_ms: int = -1, log_name: String = "", base: TimeBase = TimeBase.PHYSICS_TICK) -> bool:
	var use_ticks := base == TimeBase.PHYSICS_TICK
	var tick_ms := 1000.0 / float(Engine.physics_ticks_per_second)
	var limit_ticks := int(ceil(float(timeout_ms) / tick_ms)) if (use_ticks and timeout_ms > 0) else -1
	var deadline_ms := Time.get_ticks_msec() + timeout_ms if (not use_ticks and timeout_ms > 0) else -1
	var start_tick := Engine.get_physics_frames()
	while not done.call():
		var expired := (limit_ticks > 0 and Engine.get_physics_frames() - start_tick > limit_ticks) \
			or (deadline_ms > 0 and Time.get_ticks_msec() >= deadline_ms)
		if expired:
			LogTool.warn("异步", "%s 等待超时(>%dms)，强制继续" % [log_name, timeout_ms])
			return false
		if use_ticks:
			await Engine.get_main_loop().physics_frame
		else:
			await Engine.get_main_loop().process_frame
	return true


## 等待所有 Signal 各触发一次；内置超时保护（基于 await_until 的超时检测）。
## 默认内置 8000ms 超时；日志名会自动拼接等待的信号名（如 "await_signals:on_trigger_end,on_trigger_end"）。
## 调用方只需传入信号即可。
static func await_signals(...args) -> void:
	if args.is_empty():
		return
	# 自动拼接等待的信号名，便于超时日志精确定位是哪些信号未触发
	var sig_names := []
	for i in args.size():
		var sig: Signal = args[i]
		sig_names.append(sig.get_name())
	var log_name := "%s:%s" % ["await_signals", ", ".join(sig_names)]
	var remaining := args.size()
	var triggered := {value = 0}
	for i in args.size():
		var sig: Signal = args[i]
		sig.connect(func(..._sig_args):
			triggered.value += 1
			LogTool.log("信号", "已触发[%d/%d]: %s" % [triggered.value, remaining, sig])
		, CONNECT_ONE_SHOT)
	await await_until(func(): return triggered.value >= remaining, -1, log_name)


## 全局回调延迟（秒），MonitorGame 启动时设为 0.1
static var await_emit_delay: float = 0.0

## 将数组分帧处理，每帧处理一批后 yield，避免批量操作集中在一帧导致掉帧。
## [br]  [param items] 要处理的数组
## [br]  [param per_frame_count] 每帧处理多少元素
## [br]  [param process_fn] 处理单个元素的回调，签名 func(item) → void
## [br]  [param cancel_check] 可选的中断检测，每处理一个元素后检查，返回 true 则提前退出
## [codeblock]
## await AsyncTool.call_in_frames(records, 30, func(r): _record_list.add_child(create_row(r)))
## [/codeblock]
static func call_in_frames(items: Array, per_frame_count: int, process_fn: Callable, cancel_check: Callable = func(): return false) -> void:
	var idx := 0
	while idx < items.size():
		var end := mini(idx + per_frame_count, items.size())
		for i in range(idx, end):
			if cancel_check.call():
				return
			process_fn.call(items[i])
		idx = end
		if idx < items.size() and not cancel_check.call():
			await Engine.get_main_loop().process_frame

## 等待协程完成，带超时检测。
## [param action] 要执行的协程函数（Callable），函数内部使用 await 则可被超时保护
## [param timeout_ms] 超时时间（毫秒）。不传或 <=0 时使用统一默认值 await_with_timeout_default_ms
## [param log_name] 日志标识（可选）。为空时自动基于 action 的方法名生成
## [param wait_on_timeout] 超时后是否继续等待：
##     false（默认）= 放弃等待、流程继续（action 留在后台跑完）—— 不会卡死，但它可能与后续流程并行改状态；
##     true = 继续等 action 真正结束 —— 保证串行，但真卡死时会一直等下去。
## 需要"超时即走"的纯轮询（不启动后台协程）请直接用 await_until。
static func await_with_timeout(action: Callable, timeout_ms: int = -1, log_name: String = "", wait_on_timeout: bool = false) -> void:
	var state := {done = false}
	# 启动后台协程执行 action，完成后设置 state.done
	await_call(action, func(): state.done = true)
	# 超时时间：未指定时使用统一默认值
	var t := await_with_timeout_default_ms if timeout_ms <= 0 else timeout_ms
	# 日志名：为空时自动从 action 提取方法名，便于定位
	if log_name.is_empty():
		log_name = action.get_method() if action.is_valid() else "await_with_timeout"
	# 复用 await_until 的超时检测：state.done 置 true 或超时即继续
	await await_until(func(): return state.done, t, log_name)
	# 需要严格串行时：超时只告警，仍等它跑完（避免遗留协程与后续流程并行）
	if wait_on_timeout and not state.done:
		await await_until(func(): return state.done, -1, log_name)

## await_with_timeout 的统一默认等待时间（毫秒），>0 时启用超时检测
static var await_with_timeout_default_ms: int = 5000

## 异步执行协程，完成后调用回调。适合"发后不理"场景。
## [param action] 要执行的协程
## [param callback] 完成后的回调（可选，默认空函数）
static func await_call(action: Callable, on_end: Callable) -> void:
	await action.call()
	on_end.call()

## 手动触发 Signal 所有回调并 await
static func await_emit(s: Signal, ...args) -> void:
	var conns := s.get_connections()
	if conns.is_empty():
		return
	var timer := LogTool.timer("信号", str("同步信号 ", s.get_object().get_class(), ".", s.get_name()))
	for i in conns.size():
		var c = conns[i]
		var cb: Callable = c.callable
		var flags: int = c.flags
		await cb.callv(args)
		if flags & CONNECT_ONE_SHOT:
			s.disconnect(cb)
		if await_emit_delay > 0.0 and i < conns.size() - 1:
			## 按物理 tick 对齐（第 3 参 process_in_physics=true）：这里是符号/卡牌触发链的热路径，
			## 在渲染帧上计时会让每个连接的 0.1s 休息随帧率漂移 ⇒ 回放中的触发时刻/距离判定全部抖动
			await Engine.get_main_loop().create_timer(await_emit_delay, true, true).timeout
	timer.stop()

## 安全等待一个协程句柄(GDScriptFunctionState), 返回其结果。
## 引擎陷阱: await 一个【已完成/已失效】的句柄会永久挂起且无任何报错 ——
## 本方法先经 is_valid() 判定, 仅活跃句柄才真正等待; 失效/非句柄输入返回 null。
static func await_state_safe(fs: Variant) -> Variant:
	if _is_active_function_state(fs):
		return await fs
	return null


# ============================================================
# 协程锁 — 同一把锁下的流程排队串行执行
# ============================================================
# 为什么必须自己实现：Godot 自带的 Mutex/Semaphore 是**线程**同步原语（官方文档：用于在多 Thread 间同步），
# 不能 await，在主线程上等它会直接卡死整帧。协程（await）层面的互斥只能自己写。

## 等锁上限（毫秒）。超过则打错误日志并强行接管：
## 宁可偶发一次并发，也不要因为某个协程异常中断没放锁，把整条流程永久卡死。
## ⚠️ 必须**大于任何一次合法持有时长**，否则正常慢路径也会被接管、反而破坏串行。
## 当前最长的合法持有 = Cloud 写入失败重试 3 次 × 8s 回调超时 = 24s（见 SteamRankAdapter._write_cloud_file），故取 40s。
static var lock_timeout_ms: int = 40000

## 锁名 → 持有者令牌（谁持有的谁才能释放，防止"接管"后旧持有者误放新锁）
static var _lock_owners: Dictionary = {}
static var _lock_token := 0


## 让同一把锁下的流程**排队串行执行**（协程互斥锁），返回 action 的返回值。
##
## 什么时候需要它：GDScript 的信号是**广播**的 —— 一次 emit 会唤醒所有 await 该信号的协程。
## 若两个操作共用同一个回调信号却并发执行，就会互相抢到对方的回调（一个拿到错数据、另一个永远丢结果）；
## 有些原生/网络调用本身也不允许并发。这类"不能同时跑"的流程，用本方法包一层即可。
##
## [param lock_name] 锁名。同名的排队等待，不同名互不影响（如 &"ugc" / &"leaderboard" / &"cloud_write"）
## [param action] 要独占执行的异步闭包，其返回值原样透传
## [codeblock]
## var entries = await AsyncTool.with_lock(&"leaderboard", func():
##     Steam.downloadLeaderboardEntriesForUsers(ids, handle)
##     return await _await_signal(_scores_downloaded, 10000, "按用户下载条目")
## )
## [/codeblock]
static func with_lock(lock_name: StringName, action: Callable) -> Variant:
	var token := await _acquire_lock(lock_name)
	var result: Variant = await action.call()
	# 只由持有者释放：若已被超时接管，旧持有者结束时不至于把新持有者的锁放掉
	if _lock_owners.get(lock_name) == token:
		_lock_owners.erase(lock_name)
	return result


## 该锁当前是否被占用（调试/自检用）
static func is_locked(lock_name: StringName) -> bool:
	return _lock_owners.has(lock_name)


## 排队获取锁，返回持有者令牌
static func _acquire_lock(lock_name: StringName) -> int:
	## 用真实时间等待：锁超时不该被慢动作/暂停拉长（等不到就强行接管，宁可偶发并发也不永久卡死）
	var acquired := await await_until(
		func(): return not _lock_owners.has(lock_name),
		lock_timeout_ms, "锁[%s]" % lock_name, TimeBase.REAL_TIME)
	if not acquired:
		LogTool.error("异步", "锁[%s]等待超过 %dms，强行接管（可能发生一次并发执行）" % [lock_name, lock_timeout_ms])
	_lock_token += 1
	_lock_owners[lock_name] = _lock_token
	return _lock_token


## 幂等连接信号：若该回调（对象 + 方法）尚未连接则 connect，防止重复 connect 报错 ERR_INVALID_PARAMETER。## ⚠️ 前提：接收者必须是「每个逻辑监听者独享的对象」。若多张卡/效果共享同一个 Resource 实例
## （如同一 SignalDef .tres）并以它作接收者，这里的去重会把不同监听者合并成一条连接——
## 表现为同信号的多张被动只触发先注册的那张（实例：复苏壁垒 + 盾牌循环，SignalEffectDef
## 已用 signal_def.duplicate() 让每个效果实例持有私有副本规避）。
## [param sig] 目标信号（如 obj.my_signal）
## [param callable] 连接的回调
## [param flags] 透传给 connect（如 CONNECT_ONE_SHOT）
##
## 关于去重：Godot 的 Callable 相等性**只比较「对象 + 方法」**，bind() 绑定的参数不参与比较
## （实测：`m.bind(a) == m.bind(b)` 与 `sig.is_connected(m.bind(其它上下文))` 均为 true）。
## 所以即使回调每次 bind 了不同的上下文实例（效果被反复 apply 的常见情况），本方法也能正确去重，
## 不需要手动断开旧监听；反过来，裸 connect 第二次就会抛 already connected。
static func connect_once(sig: Signal, callable: Callable, flags: int = 0) -> void:
	if not sig.is_connected(callable):
		sig.connect(callable, flags)

## 幂等断开信号：仅当已连接时 disconnect（未连接时 Godot 会报错，故统一走这里）
static func safe_disconnect(sig: Signal, callable: Callable) -> void:
	if sig.is_connected(callable):
		sig.disconnect(callable)

## 幂等连接信号（只能拿到信号名时用，如 @export var signal_name: StringName 的场合）
## 语义与去重规则同 connect_once
static func connect_once_named(obj: Object, signal_name: StringName, callable: Callable, flags: int = 0) -> void:
	if not obj.is_connected(signal_name, callable):
		obj.connect(signal_name, callable, flags)

## 幂等断开信号（只能拿到信号名时用）
static func safe_disconnect_named(obj: Object, signal_name: StringName, callable: Callable) -> void:
	if obj.is_connected(signal_name, callable):
		obj.disconnect(signal_name, callable)

static func _is_active_function_state(v: Variant) -> bool:
	if v == null or not (v is Object) or v.get_class() != "GDScriptFunctionState":
		return false
	return bool(v.call("is_valid"))
