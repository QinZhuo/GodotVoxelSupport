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

## 每帧 poll done() 直到返回 true；带超时检测，超时后强制继续并打印警告日志。
## [param done] 完成检测回调，返回 true 视为完成
## [param timeout_ms] 超时时间（毫秒）。>0 时启用超时检测，超时后强制返回
## [param log_name] 超时日志标识（可选，便于定位）
static func await_until(done: Callable, timeout_ms: int = -1, log_name: String = "") -> void:
	var start_time := Time.get_ticks_msec()
	while not done.call():
		if timeout_ms > 0 and Time.get_ticks_msec() - start_time > timeout_ms:
			LogTool.warn("异步", "%s 等待超时(>%dms)，强制继续" % [log_name, timeout_ms])
			return
		await Engine.get_main_loop().process_frame

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

## 等待协程完成，基于 await_until 的超时检测实现。超时后强制继续并打印警告日志。
## [param action] 要执行的协程函数（Callable），函数内部使用 await 则可被超时保护
## [param timeout_ms] 超时时间（毫秒）。不传或 <=0 时使用统一的默认等待时间 await_with_timeout_default_ms
## [param log_name] 日志标识（可选）。为空时自动基于 action 的方法名生成
static func await_with_timeout(action: Callable, timeout_ms: int = -1, log_name: String = "") -> void:
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
			await Engine.get_main_loop().create_timer(await_emit_delay).timeout
	timer.stop()

## 安全等待一个协程句柄(GDScriptFunctionState), 返回其结果。
## 引擎陷阱: await 一个【已完成/已失效】的句柄会永久挂起且无任何报错 ——
## 本方法先经 is_valid() 判定, 仅活跃句柄才真正等待; 失效/非句柄输入返回 null。
static func await_state_safe(fs: Variant) -> Variant:
	if _is_active_function_state(fs):
		return await fs
	return null


## 幂等连接信号：若调用方尚未连接该信号则 connect，防止重复 connect 报错 ERR_INVALID_PARAMETER。
## [param sig] 目标信号（如 obj.my_signal）
## [param callable] 连接的回调；注意用 bind 绑定稳定宿主后其恒等，is_connected 才能正确去重
static func connect_once(sig: Signal, callable: Callable) -> void:
	if not sig.is_connected(callable):
		sig.connect(callable)

## 幂等断开信号：仅当已连接时 disconnect
static func safe_disconnect(sig: Signal, callable: Callable) -> void:
	if sig.is_connected(callable):
		sig.disconnect(callable)

static func _is_active_function_state(v: Variant) -> bool:
	if v == null or not (v is Object) or v.get_class() != "GDScriptFunctionState":
		return false
	return bool(v.call("is_valid"))
