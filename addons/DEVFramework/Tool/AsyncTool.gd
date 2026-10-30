@tool
## 异步工具 — WorkerThreadPool 后台任务 + Signal 等待 + 轮询等待 + 资源异步加载
class_name AsyncTool

## 异步加载资源，返回 Resource 或 null（超时/加载失败同样返回 null）
static func load_resource_async(path: String, timeout_ms: int = 30000) -> Resource:
	var file := path.get_file()
	var t := LogTool.timer("异步", str("加载资源: ", file))
	ResourceLoader.load_threaded_request(path)
	LogTool.log("异步", "开始请求: ", file)
	var done := func(): return ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_IN_PROGRESS
	await await_until(done, timeout_ms, "加载 %s" % file)
	var loaded := ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED
	var result: Resource = ResourceLoader.load_threaded_get(path) if loaded else null
	if result:
		LogTool.log("异步", "加载完成: ", file)
	else:
		LogTool.warn("异步", "加载失败: ", file)
	t.stop()
	return result

## 在后台线程执行 work，通过 Dictionary 容器返回结果（is_task_completed 保证同步，无需 Mutex）
## ⚠️ 任务句柄要 wait 一次才归还（`is_task_completed` 只查状态、不释放）；超时路径任务仍在跑，只能泄漏
static func thread_call(work: Callable) -> Variant:
	var data := {}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = work.call()
	)
	var completed := await await_until(func(): return WorkerThreadPool.is_task_completed(task_id))
	if completed:
		WorkerThreadPool.wait_for_task_completion(task_id)
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
	var data := {"p": 0.0}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = work.call(data)
	)
	# 主线程每帧轮询进度并回调(worker 线程只写 data 纯数据字段, 主线程读 → 安全)
	while not WorkerThreadPool.is_task_completed(task_id):
		on_progress.call(data.p)
		await Engine.get_main_loop().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	on_progress.call(data.p)
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
		var expired := (limit_ticks > 0 and Engine.get_physics_frames() - start_tick >= limit_ticks) \
			or (deadline_ms > 0 and Time.get_ticks_msec() >= deadline_ms)
		if expired:
			LogTool.warn("异步", "%s 等待超时(>%dms)，强制继续" % [log_name if not log_name.is_empty() else "await_until", timeout_ms])
			return false
		if use_ticks:
			await Engine.get_main_loop().physics_frame
		else:
			await Engine.get_main_loop().process_frame
	return true


## 等待一个 Signal 触发一次，**带超时保护**；返回 {ok: bool, args: Array}，ok=false 表示超时（未收到）。
## 用途：等待异步回调（如 Steam API），避免回调不来时协程永久挂起。
static func await_signal(sig: Signal, timeout_ms: int, log_name: String) -> Dictionary:
	var box := {"done": false, "args": []}
	var cb := func(...args):
		box.args = args
		box.done = true
	sig.connect(cb, CONNECT_ONE_SHOT)
	await await_until(func(): return box.done, timeout_ms, log_name)
	if not box.done:
		safe_disconnect(sig, cb)
		return {ok = false, args = []}
	return {ok = true, args = box.args}


## 等待所有 Signal 各触发一次的默认超时（毫秒）。
## ⚠️ **必须有超时**：无界等待会让"某一侧漏发信号"直接变成整局卡死 ——
## `MonitorGame._run_one_round` 就是靠这里的等待判定回合结束，漏发即回合永不结束
## （实测：回放里在结算面板上再点回放，一侧触发链断在半路 ⇒ 整局卡死）。
## ⚠️ 取得很宽（60s）是**刻意的**：这条等待覆盖的是"一整回合的符号→卡牌触发链"，
## 实测长构筑回合单侧就要 15s 以上（每张卡 1~2s + 落点重随 3s），固定小阈值会截断正常回合
## ⇒ 回合在链还没跑完时继续推进 ⇒ 回放与记录分叉（比卡死更隐蔽）。
## 因此它只是**兜底**，正常局永不触发；真正的病根（一侧链断在半路）由
## `MonitorGame._reset_fight_runtime_chain()` 在开新一遍回放前复位来处理。
const SIGNAL_WAIT_TIMEOUT_MS := 60000

## 等待所有 Signal 各触发一次；内置超时保护（基于 await_until 的超时检测）。
## 超时上限见 [constant SIGNAL_WAIT_TIMEOUT_MS]（超时只告警不中断，与回合末结算同一原则）；
## 日志名会自动拼接等待的信号名（如 "await_signals:on_trigger_end"）。
## [param sigs] 要等待的信号（**同一 Signal 重复出现只算一次**：一次 emit 会唤醒它连上的全部回调，
##   按元素个数计数会被同一次触发同时满足 ⇒ 误判"全部已触发"）
## [param cancel_check] 可选的中断检测：返回 true 立即返回（等待期内可能有一侧永远不触发，
##   靠 [constant SIGNAL_WAIT_TIMEOUT_MS] 兜底就是干等一分钟，玩家取消/退出必须能马上走）
## [return] 是否全部触发（超时或被中断返回 false）
static func await_signals(sigs: Array, cancel_check: Callable = func(): return false) -> bool:
	var pending: Array[Signal] = []
	for s in sigs:
		var sig: Signal = s
		if not pending.has(sig):
			pending.append(sig)
	var total := pending.size()
	if total == 0:
		return true
	# 自动拼接等待的信号名，便于超时日志精确定位是哪些信号未触发
	var sig_names: Array[String] = []
	for i in total:
		sig_names.append(pending[i].get_name())
	var log_name := "%s:%s" % ["await_signals", ", ".join(sig_names)]
	var triggered := {value = 0}
	var callbacks: Array[Callable] = []
	for i in total:
		var sig: Signal = pending[i]
		var cb := func(..._sig_args):
			triggered.value += 1
			LogTool.log("信号", "已触发[%d/%d]: %s" % [triggered.value, total, sig])
		callbacks.append(cb)
		sig.connect(cb, CONNECT_ONE_SHOT)
	await await_until(
		func(): return cancel_check.call() or triggered.value >= total, SIGNAL_WAIT_TIMEOUT_MS, log_name)
	## 只看计数：await_until 返回 true 也可能是"被 cancel_check 中断"，不能直接用它的返回值
	if triggered.value >= total:
		return true
	## 超时/中断：摘掉还没触发的连接 —— 否则它们会在很久以后被触发，打到早已跑完的协程上
	## （一次性连接虽会自动断开，但"谁没来"没法判断，统一按 is_connected 清理）
	for i in total:
		if pending[i].is_connected(callbacks[i]):
			pending[i].disconnect(callbacks[i])
	return false


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
	# 超时时间：未指定时使用统一默认值
	var t := await_with_timeout_default_ms if timeout_ms <= 0 else timeout_ms
	# 日志名：为空时自动从 action 提取方法名，便于定位
	if log_name.is_empty():
		log_name = action.get_method() if action.is_valid() else "await_with_timeout"
	var tracked := _drive(action)
	# 复用 await_until 的超时检测：tracked.done 置 true 或超时即继续
	var done := await await_until(func(): return tracked.done, t, log_name)
	# 需要严格串行时：超时只告警，仍等它跑完（避免遗留协程与后续流程并行）
	if wait_on_timeout and not done:
		await await_until(func(): return tracked.done, -1, log_name)

## await_with_timeout 的统一默认等待时间（毫秒），>0 时启用超时检测
static var await_with_timeout_default_ms: int = 5000

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

## 是否为**协程句柄** —— 含 `await` 的函数在让出控制权前返回的 `GDScriptFunctionState`。
## 引擎**未把该类型暴露给脚本类型系统**(不能用 `is GDScriptFunctionState`), 只能按类名判定 ——
## 这是社区通行写法(见 godot-proposals#5673)。非 Object / null 一律 false。
static func is_coroutine(v: Variant) -> bool:
	return v != null and v is Object and v.get_class() == "GDScriptFunctionState"


## 等待协程句柄完成, 最多 timeout_ms 毫秒; 返回 true=已完成, false=超时。
## 引擎陷阱: await 一个【已完成/已失效】的句柄会永久挂起且无任何报错 —— 本方法先经 is_valid()
## 判定, 失效/非句柄输入视为"已完成"(立即返回 true)。
## ⚠️ 超时**不会掐死**协程(引擎不支持) —— 它仍在后台继续; 调用方须据此停止等待并(通常)中止后续步骤。
## [param on_tick] 可选: 等待期间每帧回调一次(节流由调用方自己做)。给"一个方法可能跑几分钟"的
##   长任务打心跳用 —— 否则外部只看到"开始"一行, 分不清在跑还是卡死。默认不回调, 零开销。
static func await_coroutine(fs: Variant, timeout_ms: int, on_tick := Callable()) -> bool:
	var tracked := _drive(fs)
	var done := func() -> bool:
		if on_tick.is_valid():
			on_tick.call()
		return tracked.done
	## 必须走 REAL_TIME：物理 tick 受 time_scale 影响，暂停（time_scale=0）时轮询停摆 ⇒ 超时保护失效
	return await await_until(done, timeout_ms, "await_coroutine", TimeBase.REAL_TIME)


## 协程等待的统一内核（[method await_coroutine] / [method await_with_timeout] 共用）：
## 后台把协程**驱动到结束**，主流程只轮询返回的 done 标记。
##
## ⚠️ 唯一要避开的写法：**动态调用** async 函数且不 await —— 即 `callable.call()` / `obj.call("m")`。
## Godot 4.7 会对这种写法报 `Trying to call an async function without "await"`：
##   · 编辑器里直接断到调试器 ⇒ 整局停在原地（表现为 0 CPU 的"卡死"）
##   · 导出版里后续驱动根本不执行 ⇒ done 永不置位 ⇒ 调用方空等到超时
##     （`_round_end` 的预算是 20s × 双方 ⇒ 每回合末白等 40s）
## 而**静态调用**（编译期已知是 async 方法的直接调用）不 await 是**合法**的：只丢弃返回值，
## 协程照常跑完（实测）——所以这里用 `_run_tracked(...)` 直接调用即可，无需 `call_deferred`
## 或 `process_frame.connect` 绕路（那两种都会改变起跑时机：延迟到 idle / 下一帧）。
##
## ⚠️ 起跑时机必须保持"同帧、同步"：测试运行器用本方法驱动**每一个**用例，
## 只要整体后移一帧，跨场边界与协程推进的相对次序就变了 ⇒ `test_cross_fight_state` /
## 回放一致性用例假红（实测）。
##
## ⚠️ 另一点：必须真的 `await` —— 只查句柄状态不会驱动协程；而 await 一个【已失效】的句柄
## 会永久挂起 ⇒ 先经 `_is_resumable` 过滤（失效视为已完成）。
## [param source] 可调用对象（Callable，内部调用并 await）或**已创建**的协程句柄。
static func _drive(source: Variant) -> Dictionary:
	var tracked := {done = true}
	if not (source is Callable) and not _is_resumable(source):
		return tracked
	tracked.done = false
	## 静态调用 async 函数且不 await：合法，且同步起跑（与旧实现的时序完全一致）
	_run_tracked(source, tracked)
	return tracked


## 后台把协程跑到结束并置 done（发后不理；调用方轮询 tracked.done）。
static func _run_tracked(source: Variant, tracked: Dictionary) -> void:
	await _await_source(source)
	tracked.done = true


## 统一的"跑完这个协程"：Callable 在内部调用并 await；句柄直接 await。
## 注意：`await source.call()` 不能改写成 `var fs = source.call()` —— 后者同样会被
## 4.7 的 async-必须-await 检查命中。
static func _await_source(source: Variant) -> void:
	if source is Callable:
		if (source as Callable).is_valid():
			await source.call()
	elif _is_resumable(source):
		await source


## ⚠️ 发后不理地启动一个协程（动画/位移这类"表现自己跑完"的场合）请用
## `callable.call_deferred()`，**不要**直接 `callable.call()`：
## Godot 4.7 起"调用 async 函数却不 await"会报
## `Trying to call an async function without "await"`，编辑器里会直接断到调试器（整局卡死）；
## `call_deferred` 走引擎侧延迟调用，不经过脚本侧的 await 检查，且在同一帧 idle 执行。


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
##     return await await_signal(_scores_downloaded, 10000, "按用户下载条目")
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


## 幂等连接信号：若该回调（对象 + 方法）尚未连接则 connect，防止重复 connect 报错 ERR_INVALID_PARAMETER。
## ⚠️ 前提：接收者必须是「每个逻辑监听者独享的对象」。若多张卡/效果共享同一个 Resource 实例
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

## 该协程句柄是否**仍可恢复**(可安全 await): 是协程句柄且 `is_valid()` 为真。
## await 一个已失效句柄会永久挂起且零报错(见框架 Readme 陷阱2), 故等待前必须先判。
static func _is_resumable(v: Variant) -> bool:
	return is_coroutine(v) and bool(v.call("is_valid"))
