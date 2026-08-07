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

## 每帧 poll done() 直到返回 true
static func await_until(done: Callable) -> void:
	while not done.call():
		await Engine.get_main_loop().process_frame

## 等待所有 Signal 各触发一次
static func await_signals(...sigs) -> void:
	if sigs.is_empty():
		return
	var remaining := sigs.size()
	var triggered := {value = 0}
	for i in sigs.size():
		var sig: Signal = sigs[i]
		sig.connect(func(...args):
			triggered.value += 1
			LogTool.log("信号", "已触发[%d/%d]: %s" % [triggered.value, remaining, sig])
		, CONNECT_ONE_SHOT)
	await await_until(func(): return triggered.value >= remaining)

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

## 等待协程完成，带超时保护。超时后强制继续并打印警告日志。
## [param action] 要执行的协程函数（Callable），函数内部使用 await 则可被超时保护
## [param timeout_ms] 超时时间（毫秒）
## [param log_name] 日志中标识该调用的名称
static func await_with_timeout(action: Callable, timeout_ms: int, log_name: String) -> void:
	var state := {done = false}
	# 启动后台协程执行 action，完成后设置 state.done
	await_call(action, func(): state.done = true)
	var start_time := Time.get_ticks_msec()
	await await_until(func():
		if Time.get_ticks_msec() - start_time > timeout_ms:
			LogTool.error("异步", "%s 超时(>%dms)，强制继续" % [log_name, timeout_ms])
			return true
		return state.done
	)

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
