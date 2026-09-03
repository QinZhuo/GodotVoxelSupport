class_name TestRunner extends RefCounted

## 轻量测试运行器(基建): 扫描项目 Scripts/Test/ 目录下所有用例类, 自动发现 test_ 开头方法执行。
## 框架只提供机制; 用例内容由项目编写(对齐 GUT/gdUnit4 的"框架=runner, 项目=用例"分工)。
## 入口:
##   - MCP 工具 run_tests
##   - headless CLI: godot --headless --script res://addons/DEVFramework/Test/run_headless.gd
## 用例方法可含 await(协程), runner 自动等待完成后再判定。

const TESTS_DIR := "res://Scripts/Test/"


static func run_all(filter := "", root_dir := TESTS_DIR) -> Dictionary:
	var case_paths: Array = []
	_collect_cases(root_dir, case_paths)
	case_paths.sort()

	var total := 0
	var failed := 0
	var failures: Array = []
	var case_reports: Array = []

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
		var methods: Array = []
		for mi in script.get_script_method_list():
			var mname := str(mi.get("name", ""))
			if mname.begins_with("test_"):
				methods.append(mname)
		methods.sort()
		for mname in methods:
			total += 1
			inst._current_method = mname
			var before: int = inst._failures.size()
			var err: String = await _run_one(inst, mname)
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
		"text": _format(total, failed, failures),
	}


static func _run_one(inst: TestCase, method_name: String) -> String:
	var ret: Variant = inst.call(method_name)
	if _is_function_state(ret):
		await ret
	return ""


static func _is_function_state(v: Variant) -> bool:
	return v != null and v is Object and v.get_class() == "GDScriptFunctionState"


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


static func _format(total: int, failed: int, failures: Array) -> String:
	var lines: Array = []
	lines.append("测试结果[v2]: %d 项, 通过 %d, 失败 %d (扫描 %s)" % [total, total - failed, failed, TESTS_DIR])
	if not failures.is_empty():
		lines.append("--- 失败明细 ---")
		for f in failures:
			lines.append("  FAIL %s" % str(f))
	else:
		lines.append("全部通过")
	return "\n".join(lines)
