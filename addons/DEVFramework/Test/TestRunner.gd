class_name TestRunner extends RefCounted

## 轻量测试运行器(基建): 扫描项目 Scripts/Test/ 目录下所有用例类, 自动发现 test_ 开头方法执行。
##   · 进程无关(默认) —— 纯逻辑/资源层面, 编辑器进程即可, 快且无副作用;
##   · 需要游戏进程 —— 依赖项目单例 / 场景树 / 真实时间轴, 只能由 `run_tests(process=game)`
##   - MCP 工具 run_tests(process=editor|game, script=必填) —— script 为脚本路径子串(或 "all" 全量,
##   - headless CLI: godot --headless --script res://addons/DEVFramework/Test/run_headless.gd [-- --game]

const TESTS_DIR := "res://Scripts/Test/"
## 内联源码长度上限(字符)。与 eval_code 的 MAX_EVAL_LENGTH 同量级: 临时用例够用, 又挡住误传巨型文本。
const MAX_INLINE_LEN := 8192
## 单次 run_all 的**硬超时**(毫秒): 到点即判失败并停止等待剩余用例。
## 直接取 job 的硬超时 —— 两者必须一致: 比 job 长, 调用方会先拿到 timeout 而看不到测试自己的中止原因。
## ⚠️ 只能拦住"会 await(让出主循环)"的用例; 纯死循环(不让出主循环)会冻住整个进程, 硬超时也救不了。
const HARD_TIMEOUT_MS := JobTool.MAX_JOB_MS

## 编辑器/进程无关: 跳过需要游戏进程的用例(列出但不算失败)
const MODE_EDITOR := "editor"
## 游戏进程: 只跑需要游戏进程的用例
const MODE_GAME := "game"
## 编辑器段 + 游戏段合并后的标签(仅 MCP process=both 合并时使用, 不作为 run_all 的入参)
const MODE_BOTH := "both"

## 长用例心跳间隔(毫秒): 单个方法可能跑几十秒到几分钟, 只打一行"开始"会让人分不清
const HEARTBEAT_MS := 15000

## 防重入: 同一进程内不允许两轮 run_all 并发 —— 用例会改共享单例/存档/时间倍率,
## 交叉执行时互相污染, 且失败会指向错误的用例。空串 = 空闲, 否则为正在跑的 mode。
static var _running_mode := ""
## 本进程已跑过几轮: 首轮是冷缓存(脚本/资源首次加载, 实测能慢一倍),
## 那一轮的耗时不该进基线, 否则每次重启后"预计总时长"都会系统性地偏高。
static var _runs_this_process := 0


## [param script] 二选一(靠内容自动判别, 不新增参数):
##   · 测试脚本路径子串(如 "test_game_replay"); "all" = 全量(不推荐); 空串 = 全量(仅 headless CI 用);
##   · **内联 GDScript 源码**(含换行 或 以 "extends " 开头即判为源码)—— `extends TestCase` 定义
static func run_all(script := "", mode := MODE_EDITOR, logger: Object = null) -> Dictionary:
	# 闸门放在唯一入口: 两个宿主(编辑器 MCP / 游戏进程 MCP / headless)共用同一道,
	if _running_mode != "":
		return _error_result("已有测试在运行(%s), 本轮拒绝执行: 并发的两轮测试会互相污染共享状态(单例/存档/时间倍率)。等它跑完再来。"
			% _mode_label(_running_mode), script, mode)
	_running_mode = mode
	var result := await _run_all(script, mode, logger)
	_running_mode = ""
	return result


static func _run_all(script: String, mode: String, logger: Object) -> Dictionary:
	var started_at := Time.get_ticks_msec()
	var deadline := started_at + HARD_TIMEOUT_MS
	_runs_this_process += 1
	if is_inline_source(script):
		return await _run_inline(script, mode, logger, deadline)

	var run_all_mode := script.to_lower() == "all"
	var selector := "" if run_all_mode else script
	var case_paths: Array = []
	_collect_cases(TESTS_DIR, case_paths)
	case_paths.sort()

	if selector != "":
		## 逗号分隔可多选(如 "cross,test_replay_matches"): 复现跨用例污染时按需组合, 不必全量
		var keys := selector.split(",", false)
		var matched: Array = []
		for p in case_paths:
			var path := str(p)
			for k in keys:
				if path.contains(str(k).strip_edges()):
					matched.append(p)
					break
		if matched.is_empty():
			return _error_result("未找到匹配 '%s' 的测试脚本 (扫描 %s)" % [selector, TESTS_DIR], script, mode)
		case_paths = matched

	var acc := _new_acc()
	var plan := _build_plan(case_paths, mode, acc)
	var planned := 0
	for item in plan:
		planned += (item["methods"] as Array).size()
	var est := _estimate_ms(plan)
	if int(est["covered"]) > 0:
		_progress("预计总时长 %s（历史基线覆盖 %d/%d 个方法）" % [
			PerfTool.fmt_ms(float(est["ms"])), int(est["covered"]), int(est["count"])])
	for item in plan:
		await _run_one_case(item, acc, deadline, planned, logger)
		if bool(acc.get("aborted", false)):
			break
	var elapsed := Time.get_ticks_msec() - started_at
	PerfTool.flush_history()
	var text := _format(int(acc["total"]), int(acc["failed"]), acc["failures"], acc["skipped"], acc["overruns"], mode)
	text += "\n用时 %s" % PerfTool.fmt_ms(float(elapsed))
	if _runs_this_process == 1:
		text += "（进程首轮: 冷缓存耗时不计入基线）"
	# 全覆盖时才给预估偏差: 只覆盖一半的预估拿来做对比会误导
	if int(est["count"]) > 0 and int(est["covered"]) == int(est["count"]):
		text += "（预估 %s, 偏差 %+.0f%%）" % [
			PerfTool.fmt_ms(float(est["ms"])),
			(float(elapsed) - float(est["ms"])) / maxf(float(est["ms"]), 1.0) * 100.0]
	if run_all_mode:
		text += "\n[提醒] script=all 为全量运行(不推荐): 耗时可能过长, 建议按脚本精确指定。"
	var summary := _summary(acc, script, mode, text)
	summary["elapsed_ms"] = elapsed
	summary["estimated_ms"] = int(est["ms"]) if int(est["covered"]) > 0 else 0
	return summary


## 预建计划: 先问清本模式要跑哪些方法(跳过的不算), 顺手记账。
## 集中在这一步是为了让"总数已知" —— 没有 total 就没有百分比进度, 也估不出剩余时间。
static func _build_plan(case_paths: Array, mode: String, acc: Dictionary) -> Array:
	var plan: Array = []
	for p in case_paths:
		var path := str(p)
		var label := path.get_file()
		var script_res: Script = load(path)
		if script_res == null:
			# 无法加载用例脚本。**编辑器/F5(编辑器二进制)里这是真问题**(用例写坏/依赖缺失),
			if OS.has_feature("editor"):
				acc["failures"].append("%s: 用例脚本加载失败" % path)
				acc["failed"] = int(acc["failed"]) + 1
			else:
				acc["skipped"].append({case = label, reason = "用例脚本加载失败(导出包不可用, 可能依赖编辑器类)"})
			continue
		# 探针实例只用来问 needs_game_process, 随即丢弃 —— 真正执行时再实例化,
		# 否则实例会在整轮运行期存活, 被中途的 ResetTool.all() 弄成残留状态
		# ⚠ GDScript 没有 try/catch: 对"有解析错误"的脚本直接 .new() 会抛
		# "Nonexistent function 'new'", 把**整批**计划打断成 0 项(实测 VoxelSupport 的
		# test 目录里有这种脚本, script=all 直接 0 项、连正确的用例都跑不到)。
		# 判据用源码里的 TestCase 继承声明: 解析失败的脚本 source_code 为空 → 自然跳过。
		# (不用 can_instantiate(): 实测它对这里的正常用例也返回 false, 会误杀全部。)
		var src: String = script_res.source_code if script_res is GDScript else ""
		if not src.contains("TestCase"):
			acc["skipped"].append({case = label, reason = "不是 TestCase 子类"})
			_progress("跳过 %s（非用例）" % label)
			continue
		# 解析失败的脚本: source_code 仍有文本(所以上面那句放它过去), 但 new() 会抛异常。
		# reload() 的返回码是唯一可靠的"能否编译"判据(实测 can_instantiate() 对正常用例也返回 false)。
		if script_res is GDScript and script_res.reload() != OK:
			acc["skipped"].append({case = label, reason = "脚本解析失败(修好之前无法运行)"})
			_progress("跳过 %s（解析失败）" % label)
			continue
		var probe = script_res.new()
		if probe == null:
			acc["failures"].append("%s: 用例类无法实例化" % label)
			acc["failed"] = int(acc["failed"]) + 1
			continue
		if not (probe is TestCase):
			acc["skipped"].append({case = label, reason = "不是 TestCase 子类"})
			_progress("跳过 %s（非 TestCase）" % label)
			continue
		var wants_game: bool = probe.has_method("needs_game_process") and bool(probe.needs_game_process())
		var skip := _skip_reason(mode, wants_game)
		if skip != "":
			acc["skipped"].append({case = label, reason = skip})
			_progress("跳过 %s（%s）" % [label, skip])
			continue
		plan.append({label = label, script = script_res, methods = _test_methods(script_res)})
	return plan


## 历史基线预估: 各方法 EMA 耗时之和。covered < count 时只是参考值。
## ⚠ 这里**不做** runner 开销补偿: 实测其量级只有 ~0.25% (每方法约 0.25ms),
## 而同一台机器上整轮耗时会因编辑器状态(重扫/失焦/重导入)漂移好几倍 ——
## 补一个小常量并不解决"偏差大", 只会让模型看起来更复杂。
static func _estimate_ms(plan: Array) -> Dictionary:
	var total := 0.0
	var covered := 0
	var count := 0
	for item in plan:
		for mname in item["methods"]:
			count += 1
			var h: Dictionary = PerfTool.history(_perf_key(str(item["label"]), str(mname)))
			if not h.is_empty():
				total += float(h.get("ms", 0.0))
				covered += 1
	return {"ms": total, "covered": covered, "count": count}


static func _perf_key(label: String, method: String) -> String:
	return "test:%s::%s" % [label, method]


## script 是否为内联源码(而非路径选择器)。判据刻意保守: 含换行 或 以 "extends " 开头。
## 单个 token(含打错的脚本名、'all')一律当选择器 —— 否则打错名字会变成"代码解析失败", 难定位。
static func is_inline_source(script: String) -> bool:
	return script.contains("\n") or script.strip_edges().begins_with("extends ")


## 仅编译校验内联源码(不执行), 返回错误文案(含具体解析错行) 或 "" 表示可编译。
static func precheck_inline(source: String, logger: Object = null) -> String:
	var c := _compile_inline(source, logger)
	return "" if c.get("ok", false) else str(c.get("error", ""))


## 编译内联源码为 GDScript。返回 {ok:true, script} 或 {ok:false, error}。
static func _compile_inline(source: String, logger: Object) -> Dictionary:
	if source.length() > MAX_INLINE_LEN:
		return {"ok": false, "error": "内联测试代码过长: %d 字符, 超过上限 %d。请精简后重试, 或写成文件放到 %s 下。" % [source.length(), MAX_INLINE_LEN, TESTS_DIR]}
	var cursor: int = logger.get_error_cursor() if logger != null else -1
	var gd := GDScript.new()
	gd.source_code = source
	if gd.reload() != OK:
		var detail: String = str(logger.describe_errors_since(cursor)) if logger != null else "(详细解析错见对应进程的 get_logs kind=error)"
		return {"ok": false, "error": "内联测试代码解析失败(需 `extends TestCase` 并定义 test_ 开头的断言方法)。\n%s" % detail}
	return {"ok": true, "script": gd}


## 内联源码: 直接编译成 TestCase 跑, 不扫目录、不落盘。
static func _run_inline(source: String, mode: String, logger: Object, deadline: int) -> Dictionary:
	var c := _compile_inline(source, logger)
	if not c.get("ok", false):
		return _error_result(str(c.get("error", "")), "<inline>", mode)
	var acc := _new_acc()
	var res: Script = c.get("script")
	var probe = res.new()
	if probe == null:
		acc["failures"].append("<inline>: 用例类无法实例化")
		acc["failed"] = 1
		return _summary(acc, "<inline>", mode, _format(0, 1, acc["failures"], [], [], mode))
	var methods := _test_methods(res)
	var wants_game: bool = probe.has_method("needs_game_process") and bool(probe.needs_game_process())
	var skip := _skip_reason(mode, wants_game)
	if skip != "":
		acc["skipped"].append({case = "<inline>", reason = skip})
		return _summary(acc, "<inline>", mode, _format(0, 0, [], acc["skipped"], [], mode))
	await _run_one_case({label = "<inline>", script = res, methods = methods}, acc, deadline, methods.size(), logger)
	PerfTool.flush_history()
	var text := _format(int(acc["total"]), int(acc["failed"]), acc["failures"], acc["skipped"], acc["overruns"], mode)
	return _summary(acc, "<inline>", mode, text)


static func _new_acc() -> Dictionary:
	return {"total": 0, "failed": 0, "failures": [], "cases": [], "skipped": [], "overruns": [], "aborted": false}


## 执行一个用例(计划项 = {label, script, methods}), 把结果累积进 acc(不返回)。
## planned 为本轮确认的方法总数: 有总数才能算百分比进度与 ETA。
static func _run_one_case(item: Dictionary, acc: Dictionary, deadline: int, planned: int, logger: Object) -> void:
	# 无类型标注(鸭子式): 规避跨编译代次时类型化赋值静默失败的坑
	var inst = (item["script"] as Script).new()
	var label := str(item["label"])
	if inst == null:
		acc["failures"].append("%s: 用例类无法实例化" % label)
		acc["failed"] = int(acc["failed"]) + 1
		return
	var case_started_at := Time.get_ticks_msec()
	# 用例级结论不能只看 inst._failures: 运行期错误不走 _fail, 只看它会让该用例显示 ok=true
	var case_failed := false
	for mname in item["methods"]:
		# 取消请求在用例边界生效: 协程无法中途掐断, 但至少不再启动新的用例方法
		if JobTool.is_cancelled():
			acc["failures"].append("%s: 已取消(用户请求)" % label)
			acc["failed"] = int(acc["failed"]) + 1
			acc["aborted"] = true
			return
		var remaining := deadline - Time.get_ticks_msec()
		if remaining <= 0:
			acc["failures"].append("%s | %s: 超过硬超时(%d 分钟), 已中止剩余用例" % [label, mname, HARD_TIMEOUT_MS / 60000])
			acc["failed"] = int(acc["failed"]) + 1
			acc["aborted"] = true
			return
		acc["total"] = int(acc["total"]) + 1
		_progress("→ %s › %s" % [label, mname])
		# 进度上报给通用 job 层(长任务由调用方 JobTool 包装): 总数已知 ⇒ 百分比进度与 ETA 生效
		JobTool.report(int(acc["total"]), planned, "%s › %s" % [label, mname])
		inst._current_method = mname
		var before: int = inst._failures.size()
		var started_at := Time.get_ticks_msec()
		var started_us := PerfTool.now_us()
		var err_cursor: int = logger.get_error_cursor() if logger != null and logger.has_method("get_error_cursor") else -1
		var err: String = await _run_one(inst, mname, remaining, _make_heartbeat("%s › %s" % [label, mname], started_at))
		var elapsed := Time.get_ticks_msec() - started_at
		var perf_key := _perf_key(label, mname)
		# 基线用微秒: 大量用例是亚毫秒的, 取整到毫秒会全变成 0, 基线永远建不起来。
		# 进程首轮是冷缓存, 不记 —— 否则每次重启都要拿一次偏高的值去污染 EMA。
		if _runs_this_process > 1:
			PerfTool.record(perf_key, PerfTool.to_ms(PerfTool.now_us() - started_us))
		## 兜底收尾：不论成败都跑。手动收尾只覆盖"正常跑完"那条路，中途 return /
		await _run_cleanup(inst, maxi(1000, remaining - elapsed))
		## 用例体内的引擎报错(调错方法/空引用)只打一行日志、不进 _failures ⇒ 测试会"假通过"。
		## 按游标把这段区间内的 error 归到本方法; 只读不消费, get_logs 仍能取到同一批。
		var runtime_errors := _runtime_errors_since(logger, err_cursor)
		## 用例间复位会话级静态状态：漏清会让下一个用例读到上一个的残留
		ResetTool.all()
		var limit := int(inst.max_duration_ms())
		if limit > 0 and elapsed > limit:
			## suggested_max_ms: 取"本次实测"与"历史基线×1.5"的较大者 —— 只看单次会被一次抖动带偏。
			acc["overruns"].append({
				case = label, method = mname,
				elapsed_ms = elapsed, max_ms = limit,
				suggested_max_ms = maxi(int(ceil(float(elapsed) / 1000.0)) * 1000, PerfTool.suggest_ms(perf_key)),
			})
		var new_failures: Array = inst._failures.slice(before)
		if err != "":
			new_failures.append("%s: %s" % [mname, err])
		for i in mini(runtime_errors.size(), 3):
			new_failures.append("%s: 运行期错误 %s" % [mname, str(runtime_errors[i])])
		if runtime_errors.size() > 3:
			new_failures.append("%s: 另有 %d 条运行期错误(见 get_logs kind=error)" % [mname, runtime_errors.size() - 3])
		if not new_failures.is_empty():
			case_failed = true
			acc["failed"] = int(acc["failed"]) + 1
			for f in new_failures:
				acc["failures"].append("%s | %s" % [label, str(f)])
		_progress("%s %s" % ["通过" if new_failures.is_empty() else "失败", _fmt_ms(elapsed)])
		# 硬超时: 该方法的协程仍在后台跑(引擎无法掐死), 继续跑后续只会互相污染 ⇒ 立即中止。
		if err != "":
			acc["aborted"] = true
			acc["cases"].append({"case": label, "ok": false, "elapsed_ms": Time.get_ticks_msec() - case_started_at, "failures": inst._failures.duplicate()})
			return
	var case_elapsed := Time.get_ticks_msec() - case_started_at
	if case_failed:
		acc["cases"].append({"case": label, "ok": false, "elapsed_ms": case_elapsed, "failures": inst._failures.duplicate()})
	else:
		acc["cases"].append({"case": label, "ok": true, "elapsed_ms": case_elapsed})


static func _summary(acc: Dictionary, script_label: String, mode: String, text: String) -> Dictionary:
	var total := int(acc["total"])
	var failed := int(acc["failed"])
	return {
		"total": total,
		"passed": total - failed,
		"failed": failed,
		"failures": acc["failures"],
		"cases": acc["cases"],
		"skipped": acc["skipped"],
		"overruns": acc["overruns"],
		"aborted": bool(acc.get("aborted", false)),
		"mode": mode,
		"script": script_label,
		"text": text,
	}


## 合并多段摘要(编辑器段 + 游戏段)为一份, 供 MCP process=both 使用。
static func merge_summaries(parts: Array, script_label: String) -> Dictionary:
	var total := 0
	var failed := 0
	var aborted := false
	var failures: Array = []
	var cases: Array = []
	var overruns: Array = []
	var ran := {}
	var skip_seen := {}
	var elapsed_ms := 0
	var estimated_ms := 0
	for p in parts:
		var d: Dictionary = p
		total += int(d.get("total", 0))
		failed += int(d.get("failed", 0))
		elapsed_ms += int(d.get("elapsed_ms", 0))
		estimated_ms += int(d.get("estimated_ms", 0))
		aborted = aborted or bool(d.get("aborted", false))
		failures.append_array(d.get("failures", []))
		overruns.append_array(d.get("overruns", []))
		for c in d.get("cases", []):
			cases.append(c)
			ran[str(c.get("case", ""))] = true
		for s in d.get("skipped", []):
			var key := str(s.get("case", ""))
			if not skip_seen.has(key):
				skip_seen[key] = {entry = s, hits = 0}
			skip_seen[key]["hits"] = int(skip_seen[key]["hits"]) + 1
	var skipped: Array = []
	for key in skip_seen:
		if not ran.has(key) and int(skip_seen[key]["hits"]) >= parts.size():
			skipped.append(skip_seen[key]["entry"])
	var merged := {
		"total": total, "passed": total - failed, "failed": failed,
		"failures": failures, "cases": cases, "skipped": skipped,
		"overruns": overruns, "aborted": aborted,
		"elapsed_ms": elapsed_ms, "estimated_ms": estimated_ms,
		"mode": MODE_BOTH, "script": script_label,
	}
	merged["text"] = render_text(merged)
	return merged


## 按摘要字段重新排版正文。字段被外部改过(如 both 里把"游戏段未执行"记成一条失败)时,
## text 必须跟着重排, 否则正文与结构化数据自相矛盾。
static func render_text(summary: Dictionary) -> String:
	return _format(int(summary.get("total", 0)), int(summary.get("failed", 0)),
		summary.get("failures", []), summary.get("skipped", []), summary.get("overruns", []),
		str(summary.get("mode", MODE_EDITOR)))


## 早退结果(选择器无匹配 / 内联编译失败): 直接给出失败摘要, 不走正常执行流程。
## 字段形状必须与 _summary 一致 —— 少了 elapsed_ms/estimated_ms, 调用方读它会拿到 null。
static func _error_result(msg: String, script_label: String, mode: String) -> Dictionary:
	return {
		"total": 0, "passed": 0, "failed": 1, "failures": [msg],
		"cases": [], "skipped": [], "overruns": [], "aborted": false,
		"elapsed_ms": 0, "estimated_ms": 0,
		"mode": mode, "script": script_label,
		"text": "测试结果[v2|%s]: %s" % [_mode_label(mode), msg],
	}


## 该用例是否在当前进程里跑；不该跑时返回**原因**（同一句话直接进结果文本）
static func _skip_reason(mode: String, wants_game: bool) -> String:
	match mode:
		MODE_EDITOR:
			return "需要游戏进程" if wants_game else ""
		MODE_GAME:
			return "" if wants_game else "只在游戏进程模式运行"
		_:
			return ""


## 用例类里以 test_ 开头的可执行方法（按名排序，保证执行顺序稳定）
static func _test_methods(script: Script) -> Array:
	var methods: Array = []
	for mi in script.get_script_method_list():
		var mname := str(mi.get("name", ""))
		if mname.begins_with("test_"):
			methods.append(mname)
	methods.sort()
	return methods


## 跑一个用例方法, 最多 timeout_ms 毫秒。返回 "" = 正常结束, 否则为超时文案。
## 它先判 is_valid 再等待, 且**带时限** —— 规避"await 已失效句柄永久挂起"这个引擎坑, 同时给硬超时兜底。
static func _run_one(inst: TestCase, method_name: String, timeout_ms: int, on_tick := Callable()) -> String:
	var done := await AsyncTool.await_coroutine(inst.call(method_name), timeout_ms, on_tick)
	return "" if done else "超过硬超时(该用例/方法未在剩余时限内结束)"


## 自 cursor 起新增的引擎报错(去重 + 带定位)。只有 MCP 宿主注入了 logger 才生效, headless 下返回空。
static func _runtime_errors_since(logger: Object, cursor: int) -> Array:
	if logger == null or cursor < 0 or not logger.has_method("take_errors_since"):
		return []
	var entries: Array = logger.take_errors_since(cursor).get("entries", [])
	var out: Array = []
	var seen := {}
	for e in entries:
		if not (e is Dictionary):
			continue
		var msg := str((e as Dictionary).get("message", "")).strip_edges()
		if msg.is_empty() or seen.has(msg):
			continue
		seen[msg] = true
		out.append("%s @%s:%s" % [msg, str(e.get("file", "?")), str(e.get("line", "?"))])
	return out


## 心跳回调: 由等待内核每帧调用一次, 这里按 HEARTBEAT_MS 节流成"每 15s 一行"。
static func _make_heartbeat(label: String, started_at: int) -> Callable:
	var box := {last = started_at}
	return func() -> void:
		var now := Time.get_ticks_msec()
		if now - int(box.last) < HEARTBEAT_MS:
			return
		box.last = now
		## 心跳顺带报 ETA: 长用例最需要的不是"还在跑", 而是"还要多久"
		var eta := str(JobTool.status().get("eta_text", ""))
		var tail := "" if eta.is_empty() or eta == "未知" else ", 预计还需 %s" % eta
		_progress("… %s 仍在运行 (%s%s)" % [label, _fmt_ms(now - started_at), tail])


## 跑用例的收尾钩子（`TestCase.cleanup`）, 同样带时限 —— 钩子漏写 await 或自身卡住会挂住整个 run_all。
static func _run_cleanup(inst: TestCase, timeout_ms: int) -> void:
	await AsyncTool.await_coroutine(inst.call("cleanup"), timeout_ms)


static func _collect_cases(base: String, out: Array) -> void:
	var dir := DirAccess.open(base)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := base.path_join(name)
		if dir.current_is_dir() and not name.begins_with("."):
			_collect_cases(full, out)
		elif name.ends_with(".gd") and name.begins_with("test_"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## 逐条进度输出: 全量动辄几分钟, 没有进度就分不清"还在跑"还是"卡死"。
static func _progress(msg: String) -> void:
	print("[测试] %s" % msg)


static func _fmt_ms(ms: int) -> String:
	return PerfTool.fmt_ms(float(ms))


static func _mode_label(mode: String) -> String:
	match mode:
		MODE_EDITOR:
			return "编辑器/进程无关"
		MODE_GAME:
			return "游戏进程"
		MODE_BOTH:
			return "全量(编辑器+游戏)"
		_:
			return mode


static func _format(total: int, failed: int, failures: Array, skipped: Array, overruns: Array, mode: String) -> String:
	var lines: Array = []
	lines.append("测试结果[v2|%s]: %d 项, 通过 %d, 失败 %d, 跳过 %d" % [
		_mode_label(mode), total, total - failed, failed, skipped.size()])
	if not failures.is_empty():
		lines.append("--- 失败明细 ---")
		for f in failures:
			lines.append("  FAIL %s" % str(f))
	if not overruns.is_empty():
		lines.append("--- 超过声明上限(仅提示, 不算失败) ---")
		for o in overruns:
			lines.append("  SLOW %s::%s 用时 %dms > max_duration_ms %dms —— 建议把该脚本的 max_duration_ms 调到 >= %dms" % [
				str(o.get("case", "")), str(o.get("method", "")), int(o.get("elapsed_ms", 0)),
				int(o.get("max_ms", 0)), int(o.get("suggested_max_ms", 0))])
	if not skipped.is_empty():
		lines.append("--- 跳过(需在对应进程运行) ---")
		for s in skipped:
			lines.append("  SKIP %s (%s) —— 改用 %s" % [
				str(s.get("case", "")), str(s.get("reason", "")), _next_tool(mode)])
	if failures.is_empty() and skipped.is_empty() and overruns.is_empty():
		lines.append("全部通过" if total > 0 else "未发现 test_ 用例(检查脚本是否定义了 test_ 开头的方法)")
	return "\n".join(lines)


## 被跳过的用例该去哪儿跑
static func _next_tool(mode: String) -> String:
	if mode == MODE_GAME:
		return "run_tests(process=editor)"
	if mode == MODE_BOTH:
		# 两段都跳过了它 ⇒ 不是进程归属问题(两边都不认), 得看该脚本自己
		return "检查该脚本 needs_game_process() 与依赖环境"
	return "run_tests(process=game)"


