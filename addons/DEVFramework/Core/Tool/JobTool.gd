class_name JobTool extends RefCounted

## 长任务的通用底层：**启动即返回，超窗给凭据，客户端轮询**。
##
## 为什么需要它
## MCP 是请求-响应模型，客户端单次调用通常 30s 左右超时。把几十秒到几分钟的工作塞进一次
## 同步调用，结果是"超时 + 重试 = 重头再跑一遍"。业界统一做法是异步 job：先拿到 id，
## 再轮询状态。这里把它做成**框架底层工具**，任何耗时接口都能直接用，而不是各自实现一套。
##
## 为什么不走 notifications/progress
## 本服务器是短连接 HTTP(请求结束即断开)，发不出服务端主动通知；官方规范也说明进度通知
## 是 MAY 且**不能当作可靠性信号**。所以主路径是轮询，通知最多作为增强。
##
## 客户端只需一条规则:
##   result 里有 `job_id` 且 `running == true` → 调 job_wait(job_id) 反复问, 直到 running == false。
##
## 典型用法(工具侧):
##   var snap := JobTool.start("run_tests", func(): return await TestRunner.run_all(...))
##   if snap.running: return snap          # 交给客户端轮询
##   return snap                            # 已完成, 直接就是结果

## 单次调用最多等多久(毫秒)。MCP 客户端超时普遍 30s, 留 5s 余量给传输与序列化。
const DEFAULT_WAIT_MS := 28000
## job_wait 允许客户端指定的上限(毫秒): 再长也会被客户端自己掐断, 没意义。

## 保留多少个已结束 job(超出淘汰最旧的)
const MAX_KEPT_JOBS := 16
## 已结束 job 的保留时长(毫秒): 超期即回收, 长会话不会无限堆积
const KEEP_FINISHED_MS := 1800000
## 单个 job 的硬超时(毫秒): 超过即由看门狗判 timeout, 避免调用方永远看到 running。
const MAX_JOB_MS := 600000
## 速率采样窗口(毫秒): 只看最近这段的进度增量 —— 长任务里"当下速度"比全程平均更能反映还要多久。
const RATE_WINDOW_MS := 3000
## 每个 job 保留的采样点上限(超出丢最旧)
const MAX_SAMPLES := 64

static var _jobs: Dictionary = {}
static var _seq := 0
## 当前正在跑的 job(同一时刻只允许一个: 长任务通常改共享状态, 并发会互相污染)
static var _active := ""


## 启动任务并**立即返回**快照。已有任务在跑时返回它的快照(不重跑、不报错)。
## [param work] 协程/普通 Callable。内部可用 `JobTool.report()` 上报进度、
## `JobTool.is_cancelled()` 检查取消。
static func start(key: String, work: Callable) -> Dictionary:
	if _active != "":
		var running := status(_active)
		running["already_running"] = true
		running["hint"] = "已有任务在跑(%s), 这是它的快照; 用 job_wait 轮询而不是重复启动" % str(running.get("key", ""))
		return running
	_seq += 1
	# 带进程标识: 编辑器与游戏进程各自独立计数, 都从 job_1 开始 ⇒ 撞号时
	# job_wait 会在本进程查到"同名但不是同一个"的 job, 静默返回错误结果
	var id := "%s_job_%d" % [_proc_tag(), _seq]
	_jobs[id] = {
		"job_id": id, "key": key, "status": "running",
		"progress": 0, "total": 0, "current": "", "message": "",
		"started_at": Time.get_ticks_msec(), "started_us": Time.get_ticks_usec(), "finished_at": 0,
		"result": {}, "cancel_requested": false, "samples": [],
	}
	_active = id
	_prune()
	# 关键：必须把 work 推到**下一帧**再执行。
	# 直接调用 _run() 会同步跑这个协程直到它第一次 await —— 若 work 里有长时间同步段
	# （例如 500 栋建筑生成、100 年数值推进），start() 会被一起阻塞，客户端仍会超时，
	# "立即返回 job_id" 就是一句空话。用 0 秒 SceneTreeTimer 延后一帧，保证先交凭据。
	var starter := func() -> void: _run(id, work)
	# 用 Callable.call_deferred（Godot 的"下一帧空闲"原语），而不是 0 秒 SceneTreeTimer：
	# 计时器会受 Engine.time_scale 影响（测试/回放常把 time_scale 设 0 → job 永不启动），
	# call_deferred 进 MessageQueue，与时间缩放无关。
	starter.call_deferred()
	return status(id)


## 等任务结束(最多 wait_ms)。结束 → 完整结果; 未结束 → 快照(仍是同一个 job_id)。
static func wait(job_id: String, wait_ms := DEFAULT_WAIT_MS) -> Dictionary:
	var id := job_id if job_id != "" else _active
	if id == "":
		return {"error": "没有可等价的 job(还没启动过任务?)"}
	var deadline := Time.get_ticks_msec() + mini(wait_ms, DEFAULT_WAIT_MS)
	while true:
		var job: Dictionary = _jobs.get(id, {})
		if job.is_empty():
			return {"error": "未知 job_id: '%s'" % id}
		if str(job["status"]) != "running":
			return status(id)
		if Time.get_ticks_msec() >= deadline:
			return status(id)
		await Engine.get_main_loop().process_frame
	return status(id)


static func status(job_id := "") -> Dictionary:
	var id := job_id if job_id != "" else _pick()
	if id == "":
		return {"error": "没有可用的 job(还没启动过任务?)"}
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return {"error": "未知 job_id: '%s'(可用: %s)" % [job_id, _ids_text()]}
	var snap := _snapshot(id, job)
	# 已完成就把结果一并带上: 轮询到 done 的那一次调用就能拿到全部明细,
	# 不必再补一次 result(否则调用方要写两套分支)
	if str(job["status"]) != "running":
		snap.merge(job.get("result", {}), true)
		snap["status"] = str(job["status"])
	return snap


## 列出本进程记得的所有 job(最近的在前)。
## 为什么需要它: 只暴露 wait/cancel 时, 调用方**必须知道 job_id 才能问**; 而 job_id 常在前一次
## 响应里, 一旦客户端超时丢掉响应、或换了会话接着干, 就再没有入口把 id 拿回来 ——
## 明明 job 还在跑, 调用方却只能重启一遍任务。这条补的正是"我说的那个 job 现在怎样了"。
static func list() -> Dictionary:
	_prune()
	var ids: Array = _jobs.keys()
	ids.sort()
	ids.reverse()
	var items: Array = []
	for k in ids:
		var snap := _snapshot(str(k), _jobs[k])
		snap["active"] = str(k) == _active
		# 列表只给"摘要 + 凭据": 完整结果可能很大, 要明细就用 job_wait(job_id)。
		snap.erase("current")
		items.append(snap)
	return {
		"count": items.size(),
		"active": _active,
		"items": items,
		"hint": "要完整结果(含 result)用 job_wait(job_id); 这里只列摘要。" if not items.is_empty() else "本进程还没有启动过 job。",
		"process": "editor" if Engine.is_editor_hint() else "game",
		"kept_max": MAX_KEPT_JOBS,
	}


static func cancel(job_id := "") -> Dictionary:
	var id := job_id if job_id != "" else _pick()
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return {"error": "未知 job_id: '%s'" % job_id}
	job["cancel_requested"] = true
	return {"job_id": id, "cancel_requested": true,
		"hint": "取消在任务的下一个检查点生效(无法中途掐断正在 await 的协程)"}


## 任务内部上报进度。progress 必须是**单调递增**的量(已完成项数), 与 MCP 规范一致。
static func report(progress: int, total := -1, current := "", message := "") -> void:
	if _active == "":
		return
	var job: Dictionary = _jobs.get(_active, {})
	if job.is_empty():
		return
	var before := int(job.get("progress", 0))
	job["progress"] = maxi(before, progress)
	# 只在实际推进时记采样点: 速率外推(RATE_WINDOW_MS 窗口)靠这些点
	if int(job["progress"]) != before:
		_note_progress(job)
	if total >= 0:
		job["total"] = total
	if current != "":
		job["current"] = current
	if message != "":
		job["message"] = message


## 任务内部检查是否被请求取消(在用例/步骤边界调用)
static func is_cancelled() -> bool:
	if _active == "":
		return false
	return bool((_jobs.get(_active, {}) as Dictionary).get("cancel_requested", false))


## 复位(ResetTool 会调)。**只清已结束的任务**: 正在跑的那个必须保留,
## 否则调用方还拿着它的 job_id 轮询时会拿到"未知 job_id"。
static func clear() -> void:
	var running: Dictionary = _jobs.get(_active, {})
	var keep := ""
	if not running.is_empty() and str(running.get("status", "")) == "running":
		keep = _active
	_jobs.clear()
	if keep != "":
		_jobs[keep] = running
	_active = keep


static func _run(id: String, work: Callable) -> void:
	_watchdog(id)   # 看门狗: work 卡死时把 job 落成 timeout, 别让调用方永远看到 running
	var out: Variant = await work.call()
	var job: Dictionary = _jobs.get(id, {})
	if job.is_empty():
		return  # 被 clear 掉了
	if str(job.get("status", "")) == "timeout":
		return  # 看门狗已裁决, 保留 timeout 状态(返回值迟到也不再改判)
	job["result"] = out if out is Dictionary else {"value": out}
	job["finished_at"] = Time.get_ticks_msec()
	job["current"] = ""
	# 历史基线: 同类任务下次启动就有"上次用时"可参考, 也是 ETA 在进度不可用时的兜底。
	# 用微秒计时: 毫秒取整会让快任务记成 0, 那条基线就永远振不起来。
	var dur_us := PerfTool.now_us() - int(job.get("started_us", PerfTool.now_us()))
	PerfTool.record("job:" + str(job.get("key", "")), PerfTool.to_ms(maxi(dur_us, 0)))
	PerfTool.flush_history()
	var failed := false
	if out is Dictionary:
		failed = int((out as Dictionary).get("failed", 0)) > 0 or bool((out as Dictionary).get("aborted", false))
	job["status"] = "failed" if failed else "done"
	if _active == id:
		_active = ""


## work 卡死(纯 await 挂住)时无法从外部掐断协程, 但至少要给调用方一个确定结论:
## 超过 MAX_JOB_MS 就把 job 标成 timeout 并释放 active, 让后续任务能继续。
static func _watchdog(id: String) -> void:
	while true:
		await Engine.get_main_loop().process_frame
		var job: Dictionary = _jobs.get(id, {})
		if job.is_empty() or str(job.get("status", "")) != "running":
			return
		if Time.get_ticks_msec() - int(job.get("started_at", 0)) > MAX_JOB_MS:
			job["status"] = "timeout"
			job["finished_at"] = Time.get_ticks_msec()
			job["result"] = {"error": "任务超过 %d 秒未完成, 已判超时(其协程可能仍在后台跑)" % (MAX_JOB_MS / 1000)}
			if _active == id:
				_active = ""
			return


static func _snapshot(id: String, job: Dictionary) -> Dictionary:
	var started := int(job.get("started_at", 0))
	var finished := int(job.get("finished_at", 0))
	var elapsed := (finished if finished > 0 else Time.get_ticks_msec()) - started
	var running := str(job.get("status", "")) == "running"
	# 剩余时间只有"还在跑"才有意义: 结束的 job 给 0, 客户端不必再判 running 才看 ETA
	var eta := _eta_ms(job, elapsed) if running else 0
	var rate := _rate(job) if running else 0.0
	return {
		"job_id": id,
		"key": str(job.get("key", "")),
		"status": str(job.get("status", "")),
		"running": running,
		"progress": int(job.get("progress", 0)),
		"total": int(job.get("total", 0)),
		"current": str(job.get("current", "")),
		"message": str(job.get("message", "")),
		"elapsed_ms": elapsed,
		"elapsed_text": PerfTool.fmt_ms(float(elapsed)),
		"rate": snappedf(rate, 0.01),
		"eta_ms": eta,
		"eta_text": "未知" if eta < 0 else PerfTool.fmt_ms(float(eta)),
		"cancel_requested": bool(job.get("cancel_requested", false)),
	}


## 进度速率(项/秒): 优先取 RATE_WINDOW_MS 窗口内的增量(反映"当下速度"),
## 窗口内没有推进时退化为全程平均 —— 窗口过期但仍在跑的任务不该显示 0。
static func _rate(job: Dictionary) -> float:
	var now := Time.get_ticks_msec()
	var progress := int(job.get("progress", 0))
	var base_t := int(job.get("started_at", 0))
	var base_p := 0
	for s in job.get("samples", []):
		if now - int(s.get("t", now)) <= RATE_WINDOW_MS:
			base_t = int(s.get("t", now))
			base_p = int(s.get("p", 0))
			break
	if base_p >= progress:
		base_t = int(job.get("started_at", 0))
		base_p = 0
	var dt := float(now - base_t) / 1000.0
	return 0.0 if dt <= 0.0 else float(progress - base_p) / dt


## 剩余毫秒估算; -1 = 无法预估(既没有确定总数, 也没有同类任务历史)。
static func _eta_ms(job: Dictionary, elapsed_ms: int) -> int:
	var total := int(job.get("total", 0))
	var progress := int(job.get("progress", 0))
	var rate := _rate(job)
	if total > progress and progress > 0 and rate > 0.0:
		return int(ceil(float(total - progress) / rate * 1000.0))
	var hist: Dictionary = PerfTool.history("job:" + str(job.get("key", "")))
	if not hist.is_empty():
		return maxi(0, int(float(hist.get("ms", 0.0))) - elapsed_ms)
	return -1


static func _note_progress(job: Dictionary) -> void:
	var samples: Array = job.get("samples", [])
	samples.append({"t": Time.get_ticks_msec(), "p": int(job.get("progress", 0))})
	while samples.size() > MAX_SAMPLES:
		samples.pop_front()
	job["samples"] = samples


## job id 的进程前缀: 编辑器 e / 游戏 g
static func _proc_tag() -> String:
	return "e" if Engine.is_editor_hint() else "g"


static func _pick() -> String:
	if _active != "":
		return _active
	var best := ""
	var best_seq := -1
	for k in _jobs.keys():
		var n := str(k).get_slice("_", 2).to_int()   # "<tag>_job_<n>"
		if n > best_seq:
			best_seq = n
			best = str(k)
	return best


static func _ids_text() -> String:
	var ids: Array = _jobs.keys()
	ids.sort()
	return ", ".join(ids) if not ids.is_empty() else "(无)"


static func _prune() -> void:
	# 1) TTL: 已结束且超过保留期的直接回收(长会话里反复跑测试不会无限堆积结果)
	var now := Time.get_ticks_msec()
	for k in _jobs.keys():
		if str(k) == _active:
			continue
		var job: Dictionary = _jobs[k]
		if str(job.get("status", "")) == "running":
			continue
		var finished := int(job.get("finished_at", 0))
		if finished > 0 and now - finished > KEEP_FINISHED_MS:
			_jobs.erase(k)
	# 2) 数量上限: 仍超限时淘汰最旧的已结束 job
	if _jobs.size() <= MAX_KEPT_JOBS:
		return
	var keys: Array = _jobs.keys()
	keys.sort()
	for k in keys:
		if _jobs.size() <= MAX_KEPT_JOBS:
			break
		if str(k) == _active:
			continue
		if str(_jobs[k].get("status", "")) == "running":
			continue
		_jobs.erase(k)