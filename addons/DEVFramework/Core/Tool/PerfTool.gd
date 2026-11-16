class_name PerfTool extends RefCounted
## 性能采样底座 —— 计时 / 重复采样统计 / 帧率采样 / 滚动窗口 / 历史耗时基线。
## 一切"测多快"的地方都走这里, 不要再各处手写 `Time.get_ticks_usec` 差值 + 自己求平均。
## Reset: 进程级（历史基线跨场景/跨轮次复用, 不随会话复位；需要重设基线用 clear_history）
##
## 方法论取自业界微基准库(Google Benchmark / nanobench / Catch2)的共识, 四条硬规则:
##   1) 预热期的样本一律丢弃 —— 首次 load / 着色器编译 / 缓存填充比稳态高一个量级;
##   2) 迭代数自适应 —— 快的逻辑多跑几轮, 慢的少跑, 由时间预算决定而不是拍一个固定值;
##   3) 看中位/分位而不是平均值 —— 卡顿来自长尾, 平均会把偶发尖峰稀释掉;
##   4) 报告可信度(CV) —— 变异系数大说明这次测量本身不可信, 结论不能拿去下判断。

## 历史基线的落盘位置(跨进程复用: 编辑器跑一轮、游戏跑一轮, 基线是同一份)
const HISTORY_PATH := "user://.dev_framework/perf_history.json"
const HISTORY_VERSION := 1
## 基线条目上限(超出淘汰最久未更新的), 避免长项目无限堆积
const HISTORY_MAX := 300
## EMA 平滑系数: 单次离群(机器抖动/首次编译)不该主导下一次预估
const EMA_ALPHA := 0.3
## 卡顿判定下限(毫秒): 1 帧 @60fps。实际阈值取 max(中位帧时间×2, 本值) ——
## 写死 33.4ms 在 144Hz 上会把正常帧全判成卡顿, 在半速场景又什么都抓不到。
const MIN_JANK_MS := 16.7
## 单个样本批至少跑这么久: 否则耗时低于计时器分辨率, 测出来的数是被量化过的(Catch2 的 clock resolution 检查)
const MIN_BATCH_MS := 0.1
## CV(变异系数)超过此值即视为测量不可信 —— 同一指标的多次结果散布过宽
const MAX_CV := 0.10

static var _history: Dictionary = {}
static var _history_loaded := false
static var _history_dirty := false
static var _clock_res_us := 0.0


# ============================================================
# 计时
# ============================================================

static func now_us() -> int:
	return Time.get_ticks_usec()


static func to_ms(usec: int) -> float:
	return float(usec) / 1000.0


## 计时器分辨率(微秒, 进程级缓存一次)。单次耗时低于它时, 读数可能是 0 —— 不是"很快", 是测不出来。
static func clock_resolution_us() -> float:
	if _clock_res_us > 0.0:
		return _clock_res_us
	var best := 1.0e9
	for i in 200:
		var a := now_us()
		var b := now_us()
		if b > a:
			best = minf(best, float(b - a))
	_clock_res_us = best if best < 1.0e9 else 1.0
	return _clock_res_us


## 单次耗时(毫秒)。⚠ 亚微秒逻辑用 bench_auto, 单次读数会被分辨率量化。
static func measure(action: Callable) -> float:
	var t0 := now_us()
	action.call()
	return to_ms(now_us() - t0)


## 固定迭代采样: 每个样本 = 执行一次 action。
## [param setup] 每次样本前执行且**不计时** —— 造数据/重置状态不能算进被测代码的账上
## (对应 Google Benchmark 用 ScopedPauseTiming 把准备工作移出计时区)。
static func bench(action: Callable, iters := 30, warmup := 5, setup := Callable()) -> Dictionary:
	return _run_batches(action, 1, maxi(iters, 1), maxi(warmup, 0), setup)


## 自适应采样 —— 亚微秒逻辑唯一可靠的做法, 也是"不知道跑几次"时的默认选择。
## ① batch 从 1 起翻倍, 直到一个批次能测到 >= MIN_BATCH_MS(Catch2 的做法: 先确认测得出);
## ② 样本数按预算反推(Google Benchmark 的 min_time 思路), 预算偏了会被实测纠正, 不会像单次试探那样估偏一个量级。
static func bench_auto(action: Callable, budget_ms := 50.0, setup := Callable()) -> Dictionary:
	if setup.is_valid():
		setup.call()
	var batch := 1
	var batch_ms := measure(func() -> void: _run_body(action, batch))
	while batch_ms < MIN_BATCH_MS and batch < 1048576:
		batch *= 2
		batch_ms = measure(func() -> void: _run_body(action, batch))
	var samples := clampi(int(budget_ms / maxf(batch_ms, 0.001)), 10, 10000)
	var r := _run_batches(action, batch, samples, 2, setup)
	r["budget_ms"] = budget_ms
	return r


## 跑 samples 个样本, 每个样本 = 连续执行 batch 次 action 再除以 batch(把亚微秒信号放大到可测)。
static func _run_batches(action: Callable, batch: int, samples: int, warmup: int, setup: Callable) -> Dictionary:
	for i in warmup:
		if setup.is_valid():
			setup.call()
		_run_body(action, batch)
	var win := Rolling.new(samples)
	var t0 := now_us()
	for i in samples:
		if setup.is_valid():
			setup.call()
		var s := now_us()
		_run_body(action, batch)
		win.push(to_ms(now_us() - s) / float(batch))
	var r := win.stats()
	r["total_ms"] = to_ms(now_us() - t0)
	r["batch"] = batch
	# batch==1 且中位耗时落在计时器分辨率以内 ⇒ 这个数字是量化出来的, 必须换成 bench_auto
	# (batch>1 时已经用"多跑几遍再除"把信号放大过, 不再受分辨率限制)
	r["below_resolution"] = batch == 1 and float(r["p50_ms"]) < to_ms(int(clock_resolution_us())) * 2.0
	r["noisy"] = float(r["cv"]) > MAX_CV
	return r


static func _run_body(action: Callable, count: int) -> void:
	for i in count:
		action.call()


## 对一组耗时值求统计(入参 Array / PackedFloat64Array / PackedFloat32Array)。
## 除分位外还给 std_ms 与 cv: cv 大说明这次测量不可信, 别拿它下结论。
static func stats(values: Variant) -> Dictionary:
	var arr: Array = []
	if values is Array:
		arr = values
	elif values is PackedFloat64Array or values is PackedFloat32Array or values is PackedInt32Array:
		arr = Array(values)
	arr.sort()
	var n := arr.size()
	if n == 0:
		return {"count": 0, "avg_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "p99_ms": 0.0,
			"min_ms": 0.0, "max_ms": 0.0, "std_ms": 0.0, "cv": 0.0}
	var sum := 0.0
	for v in arr:
		sum += float(v)
	var mean := sum / float(n)
	var var_sum := 0.0
	for v in arr:
		var_sum += pow(float(v) - mean, 2.0)
	var sd := sqrt(var_sum / float(n))
	return {
		"count": n,
		"avg_ms": mean,
		"p50_ms": _pick(arr, 0.50),
		"p95_ms": _pick(arr, 0.95),
		"p99_ms": _pick(arr, 0.99),
		"min_ms": float(arr[0]),
		"max_ms": float(arr[n - 1]),
		"std_ms": sd,
		"cv": 0.0 if mean <= 0.0 else sd / mean,
	}


## 最近邻分位: 已排序数组里取第 ceil(p*n) 个。
static func _pick(sorted: Array, p: float) -> float:
	var i := clampi(int(ceil(p * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return float(sorted[i])


# ============================================================
# 帧率 / 引擎指标
# ============================================================

## 当前进程的即时指标(不做采样, 零等待)。单位: 时间类已换算成毫秒, 内存为 MB。
## ⚠ mem_mb 取自 MEMORY_STATIC, **导出 release 包里读不到(恒为 0)**, 只有编辑器/debug 构建有效。
static func snapshot() -> Dictionary:
	var fps := Engine.get_frames_per_second()
	return {
		"fps": fps,
		"frame_ms": 0.0 if fps <= 0 else 1000.0 / float(fps),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	}


## 采一段真实帧时间(会 await 若干帧, 只能在主循环里调)。
## 返回 stats 的全部字段 + {frames, fps_p50, fps_p95, fps_1pct_low, stutter, stutter_ms, noisy, env}。
## 在编辑器进程采样会附带 note: 编辑器空闲节流会把帧率压到 10fps 左右, 那数字只能代表编辑器。
static func sample_frames(frames := 120, warmup := 30) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return {"error": "没有主循环(SceneTree), 无法采样帧时间"}
	var win := Rolling.new(maxi(frames, 1))
	for i in maxi(warmup, 0):
		await tree.process_frame
	var prev := now_us()
	for i in maxi(frames, 1):
		await tree.process_frame
		var now := now_us()
		win.push(to_ms(now - prev))
		prev = now
	var r := win.stats()
	var p50 := float(r["p50_ms"])
	# 卡顿阈值随实际帧长走(见 MIN_JANK_MS): 结果自带 stutter_ms, 一眼能看出按什么尺子量的
	var jank_ms := maxf(p50 * 2.0, MIN_JANK_MS)
	r["frames"] = win.size()
	r["fps_p50"] = _ms_to_fps(p50)
	r["fps_p95"] = _ms_to_fps(float(r["p95_ms"]))
	# 1% low(最差 1% 帧的等效帧率)是业界判断卡顿的标准指标: 平均值再高, 1% low 崩了就是手感差
	r["fps_1pct_low"] = _ms_to_fps(float(r["p99_ms"]))
	r["stutter_ms"] = jank_ms
	r["stutter"] = win.count_over(jank_ms)
	r["noisy"] = float(r["cv"]) > MAX_CV
	r.merge(snapshot(), true)
	# 环境必须跟数字一起记: 开关 vsync / 不同 max_fps / 不同窗口大小下的帧率互相不可比
	r["env"] = {
		"gpu": RenderingServer.get_video_adapter_name(),
		"cpu": OS.get_processor_name(),
		"max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode() if DisplayServer.has_method("window_get_vsync_mode") else -1,
		"window": DisplayServer.window_get_size(),
		"focused": DisplayServer.window_is_focused(),
	}
	if Engine.is_editor_hint():
		r["note"] = "编辑器进程的帧率受空闲节流限制(常见 10fps), 测真实性能请 process=game"
	return r


static func _ms_to_fps(ms: float) -> float:
	return 0.0 if ms <= 0.0 else 1000.0 / ms


# ============================================================
# 滚动窗口: 定长环形缓冲, 写入 O(1)(不要再用 Array + pop_front, 那是 O(n))
# ============================================================

class Rolling:
	var _cap: int
	var _items := PackedFloat64Array()
	var _pos := 0

	func _init(capacity: int) -> void:
		_cap = maxi(capacity, 1)

	func push(v: float) -> void:
		if _items.size() < _cap:
			_items.append(v)
			return
		_items[_pos] = v
		_pos = (_pos + 1) % _cap

	func size() -> int:
		return _items.size()

	func is_empty() -> bool:
		return _items.is_empty()

	func clear() -> void:
		_items.clear()
		_pos = 0

	func avg() -> float:
		if _items.is_empty():
			return 0.0
		var s := 0.0
		for v in _items:
			s += v
		return s / float(_items.size())

	## 峰值(最大值)
	func peak() -> float:
		var m := 0.0
		for v in _items:
			m = maxf(m, v)
		return m

	func percentile(p: float) -> float:
		var arr := Array(_items)
		arr.sort()
		return 0.0 if arr.is_empty() else PerfTool._pick(arr, p)

	func count_over(limit: float) -> int:
		var n := 0
		for v in _items:
			if v > limit:
				n += 1
		return n

	func stats() -> Dictionary:
		return PerfTool.stats(_items)


# ============================================================
# 历史耗时基线(ETA 预估的数据源)
# ============================================================

## 某条基线的当前值: {ms(EMA), last_ms, n, updated}。没有记录返回空字典。
static func history(key: String) -> Dictionary:
	_ensure_history()
	return (_history.get(key, {}) as Dictionary).duplicate()


## 全部基线; [param filter] 非空时按 key 子串过滤(基线常有上百条, 全量回传白占 token)。
static func history_all(filter := "") -> Dictionary:
	_ensure_history()
	if filter.is_empty():
		return _history.duplicate(true)
	var out := {}
	for k in _history:
		if str(k).contains(filter):
			out[k] = (_history[k] as Dictionary).duplicate()
	return out


## 记录一次实测耗时(毫秒)。只更新内存, 落盘由 flush_history() 统一做(逐条 open/close 太贵)。
## 0 是合法值(亚毫秒的逻辑), 不要按"无效数据"丢掉 —— 丢掉后那条基线永远建不起来。
static func record(key: String, ms: float) -> void:
	if key.is_empty() or ms < 0.0:
		return
	_ensure_history()
	var e: Dictionary = _history.get(key, {})
	var n := int(e.get("n", 0))
	e["ms"] = ms if n == 0 else lerpf(float(e.get("ms", ms)), ms, EMA_ALPHA)
	e["last_ms"] = ms
	e["n"] = n + 1
	e["updated"] = int(Time.get_unix_time_from_system())
	_history[key] = e
	_history_dirty = true


## 按基线给出建议预算(毫秒, 向上取整到秒)。没有基线返回 0。
static func suggest_ms(key: String, factor := 1.5, floor_ms := 1000) -> int:
	var e := history(key)
	if e.is_empty():
		return 0
	return maxi(floor_ms, int(ceil(float(e.get("ms", 0.0)) * factor / 1000.0)) * 1000)


static func forget(key: String) -> void:
	_ensure_history()
	if _history.erase(key):
		_history_dirty = true


static func clear_history() -> void:
	_history.clear()
	_history_loaded = true
	_history_dirty = false
	FileTool.write_text(HISTORY_PATH, JSON.stringify({"v": HISTORY_VERSION, "items": {}}, "\t"))


static func flush_history() -> void:
	if not _history_dirty:
		return
	_history_dirty = false
	_prune_history()
	FileTool.write_text(HISTORY_PATH, JSON.stringify({"v": HISTORY_VERSION, "items": _history}, "\t"))


static func _ensure_history() -> void:
	if _history_loaded:
		return
	_history_loaded = true
	var text := FileTool.read_text(HISTORY_PATH)
	if text.is_empty():
		return
	var data: Variant = JSON.parse_string(text)
	if data is Dictionary and data.get("items") is Dictionary:
		_history = data["items"]


## 超上限时按 updated 升序淘汰最旧的条目
static func _prune_history() -> void:
	if _history.size() <= HISTORY_MAX:
		return
	var keys: Array = _history.keys()
	keys.sort_custom(func(a, b) -> bool:
		return int(_history[a].get("updated", 0)) < int(_history[b].get("updated", 0)))
	for i in _history.size() - HISTORY_MAX:
		_history.erase(keys[i])


# ============================================================
# 格式化
# ============================================================

## 单次操作耗时的可读文本: 亚毫秒必须换单位 —— "0.000ms" 这种输出等于没有信息。
## 0.00008 → "80ns"; 0.0035 → "3.5µs"; 2.5 → "2.50ms"。
static func fmt_cost(ms: float) -> String:
	if ms >= 1.0:
		return "%.2fms" % ms
	if ms >= 0.001:
		return "%.1fµs" % (ms * 1000.0)
	return "%.0fns" % (ms * 1000000.0)


## 统一耗时文案: 900 → "900ms"; 12500 → "12.5s"; 125000 → "2m05s"。
static func fmt_ms(ms: float) -> String:
	var v := int(round(ms))
	if v < 1000:
		return "%dms" % v
	if v < 60000:
		return "%.1fs" % (float(v) / 1000.0)
	return "%dm%02ds" % [v / 60000, (v % 60000) / 1000]
