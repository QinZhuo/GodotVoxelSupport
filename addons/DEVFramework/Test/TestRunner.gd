class_name TestRunner extends RefCounted

## 轻量测试运行器(基建): 扫描项目 Scripts/Test/ 目录下所有用例类, 自动发现 test_ 开头方法执行。
## 框架只提供机制; 用例内容由项目编写(对齐 GUT/gdUnit4 的"框架=runner, 项目=用例"分工)。
##
## 用例按**进程归属**分两类(见 `TestCase.needs_game_process()`):
##   · 进程无关(默认) —— 纯逻辑/资源层面, 编辑器进程即可, 快且无副作用;
##   · 需要游戏进程 —— 依赖 MonitorGame / 场景树 / 真实时间轴, 只能由 `run_game_tests`
##     (MCP, 游戏进程内) 或 headless `--game` 执行。
## 在错误的进程里跑某类用例时, 它会被列为 **skipped 并出现在结果文本里** ——
## 绝不静默通过, 也绝不因"缺环境"而假失败。
##
## 入口:
##   - MCP 工具 run_tests(编辑器/进程无关) / run_game_tests(游戏进程)
##   - headless CLI: godot --headless --script res://addons/DEVFramework/Test/run_headless.gd [-- --game]
## 用例方法可含 await(协程), runner 自动等待完成后再判定。

const TESTS_DIR := "res://Scripts/Test/"

## 不过滤: 当前进程能跑什么就跑什么(慎用, 缺环境的用例会在运行期报错而非跳过)
const MODE_ALL := "all"
## 编辑器/进程无关: 跳过需要游戏进程的用例(列出但不算失败)
const MODE_EDITOR := "editor"
## 游戏进程: 只跑需要游戏进程的用例
const MODE_GAME := "game"


static func run_all(filter := "", root_dir := TESTS_DIR, mode := MODE_ALL) -> Dictionary:
	var case_paths: Array = []
	_collect_cases(root_dir, case_paths)
	case_paths.sort()

	var total := 0
	var failed := 0
	var failures: Array = []
	var case_reports: Array = []
	var skipped: Array = []

	for path in case_paths:
		if filter != "" and not str(path).contains(filter):
			continue
		var script: Script = load(str(path))
		if script == null:
			failures.append("%s: 用例脚本加载失败" % path)
			failed += 1
			continue
		# 无类型标注(鸭子式): 规避跨编译代次时类型化赋值静默失败的坑; new 失败返回 null 再判空
		var inst = script.new()
		if inst == null:
			failures.append("%s: 用例类无法实例化" % path)
			failed += 1
			continue
		var wants_game: bool = inst.has_method("needs_game_process") and bool(inst.needs_game_process())
		var skip := _skip_reason(mode, wants_game)
		if skip != "":
			skipped.append({case = str(path).get_file(), reason = skip})
			continue
		for mname in _test_methods(script):
			total += 1
			inst._current_method = mname
			var before: int = inst._failures.size()
			var err: String = await _run_one(inst, mname)
			## 兜底收尾：不论成败都跑。手动收尾只覆盖"正常跑完"那条路，中途 return /
			## 协程被超时中断都会跳过它 —— 对会写玩家档案的用例，那等于把测试数据留在存档里。
			await _run_cleanup(inst)
			var new_failures: Array = inst._failures.slice(before)
			if err != "":
				new_failures.append("%s: %s" % [mname, err])
			if not new_failures.is_empty():
				failed += 1
				for f in new_failures:
					failures.append("%s | %s" % [str(path).get_file(), str(f)])
		if inst._failures.is_empty():
			case_reports.append({"case": str(path).get_file(), "ok": true})
		else:
			case_reports.append({"case": str(path).get_file(), "ok": false, "failures": inst._failures.duplicate()})

	return {
		"total": total,
		"passed": total - failed,
		"failed": failed,
		"failures": failures,
		"cases": case_reports,
		"skipped": skipped,
		"mode": mode,
		"text": _format(total, failed, failures, skipped, mode),
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


## 跑一个用例方法。协程用例（方法体含 await）在 Godot 4 里会返回一个协程句柄，
## 这里复用框架自带的 `AsyncTool.await_state_safe`：它先经 `is_valid()` 判定再等待，
## 规避"await 一个已完成/已失效的句柄会永久挂起且零报错"这个引擎坑（见框架 Readme 陷阱2）。
static func _run_one(inst: TestCase, method_name: String) -> String:
	await AsyncTool.await_state_safe(inst.call(method_name))
	return ""


## 跑用例的收尾钩子（`TestCase.cleanup`）。用 `await_state_safe` 同样地规避
## "await 一个已失效句柄会永久挂起" —— 钩子里漏写 await 就会踩这个坑并挂住整个 run_all。
static func _run_cleanup(inst: TestCase) -> void:
	await AsyncTool.await_state_safe(inst.call("cleanup"))


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
			return "全部"


static func _format(total: int, failed: int, failures: Array, skipped: Array, mode: String) -> String:
	var lines: Array = []
	lines.append("测试结果[v2|%s]: %d 项, 通过 %d, 失败 %d, 跳过 %d (扫描 %s)" % [
		_mode_label(mode), total, total - failed, failed, skipped.size(), TESTS_DIR])
	if not failures.is_empty():
		lines.append("--- 失败明细 ---")
		for f in failures:
			lines.append("  FAIL %s" % str(f))
	if not skipped.is_empty():
		lines.append("--- 跳过(需在对应进程运行) ---")
		for s in skipped:
			lines.append("  SKIP %s (%s) —— 改用 %s" % [
				str(s.get("case", "")), str(s.get("reason", "")), _next_tool(mode)])
	if failures.is_empty() and skipped.is_empty():
		lines.append("全部通过")
	return "\n".join(lines)


## 被跳过的用例该去哪儿跑
static func _next_tool(mode: String) -> String:
	if mode == MODE_GAME:
		return "run_tests(编辑器进程)"
	return "run_game_tests(游戏进程)"
