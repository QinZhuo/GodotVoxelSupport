class_name TestRunner extends RefCounted

## 轻量测试运行器(基建): 扫描项目 Scripts/Test/ 目录下所有用例类, 自动发现 test_ 开头方法执行。
## 框架只提供机制; 用例内容由项目编写(对齐 GUT/gdUnit4 的"框架=runner, 项目=用例"分工)。
##
## 用例按**进程归属**分两类(见 `TestCase.needs_game_process()`):
##   · 进程无关(默认) —— 纯逻辑/资源层面, 编辑器进程即可, 快且无副作用;
##   · 需要游戏进程 —— 依赖 MonitorGame / 场景树 / 真实时间轴, 只能由 `run_tests(process=game)`
##     (MCP, 游戏进程内) 或 headless `--game` 执行。
## 在错误的进程里跑某类用例时, 它会被列为 **skipped 并出现在结果文本里** ——
## 绝不静默通过, 也绝不因"缺环境"而假失败。
##
## 入口:
##   - MCP 工具 run_tests(process=editor|game, script=必填) —— script 为脚本路径子串(或 "all" 全量,
##     不推荐), 也可**直接传内联 GDScript 源码**(见 run_all 的 [param script])
##   - headless CLI: godot --headless --script res://addons/DEVFramework/Test/run_headless.gd [-- --game]
##     (CLI 传空 script = 全量, 供 CI 用)
## 用例方法可含 await(协程), runner 自动等待完成后再判定。

const TESTS_DIR := "res://Scripts/Test/"
## 内联源码长度上限(字符)。与 eval_code 的 MAX_EVAL_LENGTH 同量级: 临时用例够用, 又挡住误传巨型文本。
const MAX_INLINE_LEN := 8192
## 单次 run_all 的**硬超时**(毫秒): 到点即判失败并停止等待剩余用例 —— 强制测试不超过 10 分钟。
## ⚠️ 只能拦住"会 await(让出主循环)"的用例; 纯死循环(不让出主循环)会冻住整个进程, 硬超时也救不了。
const HARD_TIMEOUT_MS := 600000

## 编辑器/进程无关: 跳过需要游戏进程的用例(列出但不算失败)
const MODE_EDITOR := "editor"
## 游戏进程: 只跑需要游戏进程的用例
const MODE_GAME := "game"


## [param script] 二选一(靠内容自动判别, 不新增参数):
##   · 测试脚本路径子串(如 "test_game_replay"); "all" = 全量(不推荐); 空串 = 全量(仅 headless CI 用);
##   · **内联 GDScript 源码**(含换行 或 以 "extends " 开头即判为源码)—— `extends TestCase` 定义
##     test_ 方法即可, 直接编译运行、**不落盘**, 适合临时验证。
##   单个 token 一律按选择器处理: 打错脚本名得到的是"未找到匹配..."而不是莫名其妙的解析错。
## [param logger] 可选: 宿主的错误缓冲(MCPLogger)。仅用于内联源码编译失败时取回**具体解析错行**;
##   传 null(如 headless CLI)则退回通用提示。鸭子式调用(只用到 get_error_cursor/describe_errors_since),
##   故 Test 域不依赖 MCP 的具体类型。
static func run_all(script := "", mode := MODE_EDITOR, logger: Object = null) -> Dictionary:
	var deadline := Time.get_ticks_msec() + HARD_TIMEOUT_MS
	if is_inline_source(script):
		return await _run_inline(script, mode, logger, deadline)

	var run_all_mode := script.to_lower() == "all"
	var selector := "" if run_all_mode else script
	var case_paths: Array = []
	_collect_cases(TESTS_DIR, case_paths)
	case_paths.sort()

	if selector != "":
		var matched: Array = []
		for p in case_paths:
			if str(p).contains(selector):
				matched.append(p)
		if matched.is_empty():
			return _error_result("未找到匹配 '%s' 的测试脚本 (扫描 %s)" % [selector, TESTS_DIR], script, mode)
		case_paths = matched

	var acc := _new_acc()
	for path in case_paths:
		var script_res: Script = load(str(path))
		if script_res == null:
			# 无法加载用例脚本。**编辑器/F5(编辑器二进制)里这是真问题**(用例写坏/依赖缺失),
			# 记为失败; 而**导出包**里这是预期 —— 引用了编辑器类(如 EditorImportPlugin)的用例
			# 本就无法在发布版加载。此时记为 skipped(可见, 但不误报成失败)。
			if OS.has_feature("editor"):
				acc["failures"].append("%s: 用例脚本加载失败" % path)
				acc["failed"] = int(acc["failed"]) + 1
			else:
				acc["skipped"].append({case = str(path).get_file(), reason = "用例脚本加载失败(导出包不可用, 可能依赖编辑器类)"})
			continue
		await _run_one_case(script_res, str(path).get_file(), mode, acc, deadline)
		if bool(acc.get("aborted", false)):
			break

	var text := _format(int(acc["total"]), int(acc["failed"]), acc["failures"], acc["skipped"], acc["overruns"], mode)
	if run_all_mode:
		text += "\n[提醒] script=all 为全量运行(不推荐): 耗时可能过长, 建议按脚本精确指定。"
	return _summary(acc, script, mode, text)


## script 是否为内联源码(而非路径选择器)。判据刻意保守: 含换行 或 以 "extends " 开头。
## 单个 token(含打错的脚本名、'all')一律当选择器 —— 否则打错名字会变成"代码解析失败", 难定位。
static func is_inline_source(script: String) -> bool:
	return script.contains("\n") or script.strip_edges().begins_with("extends ")


## 仅编译校验内联源码(不执行), 返回错误文案(含具体解析错行) 或 "" 表示可编译。
## 供 process=game 转发前在编辑器内拦截语法错 —— **游戏进程里解析错会触发调试器断点中断游戏**,
## 与 eval 的转发预检同理(见 MCPDevServer._call_game_eval_proxy)。
static func precheck_inline(source: String, logger: Object = null) -> String:
	var c := _compile_inline(source, logger)
	return "" if c.get("ok", false) else str(c.get("error", ""))


## 编译内联源码为 GDScript。返回 {ok:true, script} 或 {ok:false, error}。
## 编译前记错误游标, 失败时据此取回**引擎刚打印的**具体解析错(含行号)。
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
	await _run_one_case(c.get("script"), "<inline>", mode, acc, deadline)
	var text := _format(int(acc["total"]), int(acc["failed"]), acc["failures"], acc["skipped"], acc["overruns"], mode)
	return _summary(acc, "<inline>", mode, text)


static func _new_acc() -> Dictionary:
	return {"total": 0, "failed": 0, "failures": [], "cases": [], "skipped": [], "overruns": [], "aborted": false}


## 执行一个用例(文件或内联), 把结果累积进 acc(不返回)。deadline 为整个 run_all 的硬超时点。
static func _run_one_case(res: Script, label: String, mode: String, acc: Dictionary, deadline: int) -> void:
	# 无类型标注(鸭子式): 规避跨编译代次时类型化赋值静默失败的坑; new 失败返回 null 再判空
	var inst = res.new()
	if inst == null:
		acc["failures"].append("%s: 用例类无法实例化" % label)
		acc["failed"] = int(acc["failed"]) + 1
		return
	var wants_game: bool = inst.has_method("needs_game_process") and bool(inst.needs_game_process())
	var skip := _skip_reason(mode, wants_game)
	if skip != "":
		acc["skipped"].append({case = label, reason = skip})
		return
	var case_started_at := Time.get_ticks_msec()
	for mname in _test_methods(res):
		var remaining := deadline - Time.get_ticks_msec()
		if remaining <= 0:
			acc["failures"].append("%s | %s: 超过硬超时(%d 分钟), 已中止剩余用例" % [label, mname, HARD_TIMEOUT_MS / 60000])
			acc["failed"] = int(acc["failed"]) + 1
			acc["aborted"] = true
			return
		acc["total"] = int(acc["total"]) + 1
		inst._current_method = mname
		var before: int = inst._failures.size()
		var started_at := Time.get_ticks_msec()
		var err: String = await _run_one(inst, mname, remaining)
		var elapsed := Time.get_ticks_msec() - started_at
		## 兜底收尾：不论成败都跑。手动收尾只覆盖"正常跑完"那条路，中途 return /
		## 协程被超时中断都会跳过它 —— 对会写玩家档案的用例，那等于把测试数据留在存档里。
		await _run_cleanup(inst, maxi(1000, remaining - elapsed))
		var limit := int(inst.max_duration_ms())
		if limit > 0 and elapsed > limit:
			## suggested_max_ms: 按实测值向上取整到秒, 供脚本作者直接更新 max_duration_ms。
			acc["overruns"].append({
				case = label, method = mname,
				elapsed_ms = elapsed, max_ms = limit,
				suggested_max_ms = int(ceil(float(elapsed) / 1000.0)) * 1000,
			})
		var new_failures: Array = inst._failures.slice(before)
		if err != "":
			new_failures.append("%s: %s" % [mname, err])
		if not new_failures.is_empty():
			acc["failed"] = int(acc["failed"]) + 1
			for f in new_failures:
				acc["failures"].append("%s | %s" % [label, str(f)])
		# 硬超时: 该方法的协程仍在后台跑(引擎无法掐死), 继续跑后续只会互相污染 ⇒ 立即中止。
		if err != "":
			acc["aborted"] = true
			acc["cases"].append({"case": label, "ok": false, "elapsed_ms": Time.get_ticks_msec() - case_started_at, "failures": inst._failures.duplicate()})
			return
	var case_elapsed := Time.get_ticks_msec() - case_started_at
	if inst._failures.is_empty():
		acc["cases"].append({"case": label, "ok": true, "elapsed_ms": case_elapsed})
	else:
		acc["cases"].append({"case": label, "ok": false, "elapsed_ms": case_elapsed, "failures": inst._failures.duplicate()})


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


## 早退结果(选择器无匹配 / 内联编译失败): 直接给出失败摘要, 不走正常执行流程。
static func _error_result(msg: String, script_label: String, mode: String) -> Dictionary:
	return {
		"total": 0, "passed": 0, "failed": 1, "failures": [msg],
		"cases": [], "skipped": [], "overruns": [], "mode": mode, "script": script_label,
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
## 协程用例（方法体含 await）在 Godot 4 里会返回一个协程句柄; 复用 `AsyncTool.await_coroutine`:
## 它先判 is_valid 再等待, 且**带时限** —— 规避"await 已失效句柄永久挂起"这个引擎坑, 同时给硬超时兜底。
static func _run_one(inst: TestCase, method_name: String, timeout_ms: int) -> String:
	var done := await AsyncTool.await_coroutine(inst.call(method_name), timeout_ms)
	return "" if done else "超过硬超时(该用例/方法未在剩余时限内结束)"


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


static func _mode_label(mode: String) -> String:
	match mode:
		MODE_EDITOR:
			return "编辑器/进程无关"
		MODE_GAME:
			return "游戏进程"
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
	return "run_tests(process=game)"
