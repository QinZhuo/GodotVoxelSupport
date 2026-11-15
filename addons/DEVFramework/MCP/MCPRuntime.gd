@tool
extends RefCounted

## ======= 运行时（游戏进程）桥接 =======
## 由 MCPDevServer 以 preload 常量 `MCPRuntime` 引用。**必须 @tool 且不声明 class_name**
## 为什么这些必须集中在一处：它们全都围绕同一条判断"这条请求该在编辑器进程还是游戏进程执行"。

const MCPLogTools := preload("res://addons/DEVFramework/MCP/MCPLogTools.gd")

## MCPDevServer（Variant：跨编译代次不信任类型标注）
var server = null


func _init(owner) -> void:
	server = owner


## ------- 日志: process 分派 -------

func call_get_logs_local(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process != "game":
		return server._fail("导出运行时没有独立的编辑器进程; get_logs 的 process 只能是 'game'")
	return MCPLogTools._call_get_logs(args)


func call_get_logs_routed(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process == "game":
		return await server._call_runtime_proxy("get_logs", args)
	return MCPLogTools._call_get_logs(args)


func call_clear_logs_local(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process != "game":
		return server._fail("导出运行时没有独立的编辑器进程; clear_logs 的 process 只能是 'game'")
	return MCPLogTools._call_clear_errors(args)


func call_clear_logs_routed(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process == "game":
		return await server._call_runtime_proxy("clear_logs", args)
	return MCPLogTools._call_clear_errors(args)


## 读取必填的 process 参数(editor|game)；缺省/非法由调用方各自报错。
func _require_process(args: Dictionary) -> String:
	return VariantTool.get_string(args, "process", "").strip_edges()


## ------- run_tests: 双进程 -------

## runtime 侧(服务器位于游戏进程内): process 只能是 game(游戏用例就地跑)。
func call_run_tests_local(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process == "both":
		return server._fail("导出运行时没有独立的编辑器进程, process=both 无意义; 这里只能跑 process=game")
	if process != "game":
		return server._fail("导出运行时没有独立的编辑器进程; run_tests 的 process 只能是 'game'")
	return await server._runtime_run_game_tests(args)


## editor 侧: process=editor 在编辑器进程同步跑; process=game 转发到游戏进程。
func call_run_tests_routed(args: Dictionary) -> Dictionary:
	var script := VariantTool.get_string(args, "script").strip_edges()
	var process := _require_process(args)
	if process != "editor" and process != "game" and process != "both":
		return server._fail("process 必须是 editor / game / both, 收到: '%s'" % process)
	if process == "both":
		return await _run_tests_both(script)
	if process == "game":
		# 内联源码先在编辑器内编译预检：语法错就地拦截，不把坏代码转发到游戏进程
		if TestRunner.is_inline_source(script):
			var pre := TestRunner.precheck_inline(script, server._logger)
			if pre != "":
				return server._err_validation("内联测试代码预检未通过(未转发到游戏进程):\n%s" % pre,
					"修正内联测试源码后重试; 或改成文件放到 %s 下再用 script 路径跑" % TestRunner.TESTS_DIR)
		return await _run_tests_in_game(script)
	if script.is_empty():
		return server._fail("必须指定测试脚本(script: 脚本路径子串如 'test_display_tool', 或 'all' 全量, 或内联 GDScript 源码); 不支持默认全跑")
	return server._ok_json(await TestRunner.run_all(script, TestRunner.MODE_EDITOR, server._logger))


## 转发游戏用例到游戏进程；没有活跃会话时自动启动游戏（理由见下）。
func _run_tests_in_game(script: String) -> Dictionary:
	var auto_started := false
	if not _has_game_session():
		var started: Dictionary = await _call_run_game({})
		if bool(started.get("is_error", false)):
			return started
		auto_started = true
		# 自动启动在调试线 15s 内未就绪时返回的是**成功文案**，这里必须区分开
		if not bool(server._game_ready):
			return server._err_transient("已自动启动游戏, 但调试线 15 秒内未就绪, 本轮测试未执行",
				"稍后重试; 或 game_control(action=start) 后确认游戏窗口已进入主场景再调 run_tests")
		# 调试线就绪 ≠ 主场景初始化完：autoload 的 ready 早于场景根 _ready，此刻注入测试会插进
		# 半初始化状态（实测：自动启动后立刻转发，首轮用例常因依赖对象还是 null 而失败）。
		# ignore_time_scale=true：用例常把 time_scale 调高，等待不能被它缩短。
		await server.get_tree().create_timer(2.0, true, false, true).timeout
	var raw: Dictionary = await server._call_runtime_proxy("run_tests", {"process": "game", "script": script})
	if bool(raw.get("is_error", false)):
		return raw
	var sum := _summary_of(raw)
	if sum.is_empty():
		return raw
	if auto_started:
		sum["auto_started_game"] = true
		sum["text"] = "[已自动启动游戏进程(此前无运行实例)]\n%s" % str(sum.get("text", ""))
	return server._ok_json(sum)


## process=both: 编辑器段 → 游戏段，合并成一份汇总。
func _run_tests_both(script: String) -> Dictionary:
	if TestRunner.is_inline_source(script):
		# 内联源码只跑一次：它是临时逻辑验证，两段跑同一段代码只是翻倍耗时
		return server._ok_json(await TestRunner.run_all(script, TestRunner.MODE_EDITOR, server._logger))
	var editor_sum: Dictionary = await TestRunner.run_all(script, TestRunner.MODE_EDITOR, server._logger)
	# 选择器一条都没匹配上(早退结果)：游戏段必然同样为空，不再白起一轮
	if int(editor_sum.get("total", 0)) == 0 and int(editor_sum.get("failed", 0)) > 0:
		return server._ok_json(editor_sum)
	var game_res: Dictionary = await _run_tests_in_game(script)
	if bool(game_res.get("is_error", false)):
		return _both_with_game_failure(editor_sum, script, _error_text(game_res))
	var game_sum := _summary_of(game_res)
	if game_sum.is_empty():
		return _both_with_game_failure(editor_sum, script, "游戏进程返回内容无法解析为测试汇总")
	var merged: Dictionary = TestRunner.merge_summaries([editor_sum, game_sum], script)
	if bool(game_sum.get("auto_started_game", false)):
		merged["auto_started_game"] = true
		merged["text"] = "[已自动启动游戏进程(此前无运行实例)]\n%s" % str(merged.get("text", ""))
	return server._ok_json(merged)


## 游戏段没跑成 = 全量没跑成：记成**一条失败项**而不是静默省略
func _both_with_game_failure(editor_sum: Dictionary, script: String, reason: String) -> Dictionary:
	var merged: Dictionary = TestRunner.merge_summaries([editor_sum], script)
	merged["total"] = int(merged["total"]) + 1
	merged["failed"] = int(merged["failed"]) + 1
	merged["passed"] = int(merged["total"]) - int(merged["failed"])
	merged["failures"].append("<游戏段> 未执行: %s" % reason)
	merged["cases"].append({"case": "<游戏段>", "ok": false, "elapsed_ms": 0})
	merged["text"] = TestRunner.render_text(merged)
	return server._ok_json(merged)


## 取回结果里的结构化摘要（ok_json 放 structuredContent；少数路径只有 content[].text 的 JSON）
func _summary_of(res: Dictionary) -> Dictionary:
	var sc: Variant = res.get("structuredContent", null)
	if sc is Dictionary:
		return sc
	var content: Variant = res.get("content", null)
	if content is Array and not content.is_empty() and content[0] is Dictionary:
		var parsed: Variant = JSON.parse_string(str(content[0].get("text", "")))
		if parsed is Dictionary:
			return parsed
	return {}


## 取错误结果里的可读正文（错误封装把 message 放进 structuredContent.message）
func _error_text(res: Dictionary) -> String:
	var sc: Variant = res.get("structuredContent", null)
	if sc is Dictionary and str(sc.get("message", "")) != "":
		return str(sc.get("message"))
	var content: Variant = res.get("content", null)
	if content is Array and not content.is_empty() and content[0] is Dictionary:
		return str(content[0].get("text", ""))
	return "未知错误"


## ------- 游戏生命周期 -------

## start(支持 uid:// 场景, 已在运行时自动停旧实例后重启) / stop / continue。
## continue 并入本工具而非独立成工具：客户端决定映射哪些工具，恢复路径必须落在一定被映射的那个上。
func call_game_control(args: Dictionary) -> Dictionary:
	match VariantTool.get_string(args, "action"):
		"continue":
			return server._call_debug_continue({})
		"start":
			# 已在运行时自动停旧实例再启动：旧实例持有的是启动时固化的脚本，而
			if _has_game_session():
				await _call_stop_game({})
				if not await _wait_game_stopped(5.0):
					return server._fail("旧游戏实例 5 秒内未停止, 无法重启。请用 game_control(action=stop) 确认状态后重试。")
			return await _call_run_game(args)
		"stop":
			return await _call_stop_game({})
	return server._fail("未知 action: %s (可选 start/stop/continue)" % VariantTool.get_string(args, "action"))


## 编辑器模式且游戏调试线活跃（编辑器进程指向游戏进程的数据/操作要走代理）
func _has_game_session() -> bool:
	return server.is_editor_mode() and server.debugger_plugin != null and server.debugger_plugin.has_active_session()


## 记录"脚本新鲜度基准"的当前时刻（见 MCPScriptSync.guard_eval）。
## 基准点必须不晚于脚本加载完成的时刻才安全，故一律取"此刻"而非任何已有时间戳。
func mark_script_baseline(reason: String) -> void:
	server._game_started_at = int(Time.get_unix_time_from_system())
	LogTool.log("MCP", "脚本新鲜度基准更新(%s): %d" % [reason, server._game_started_at])


func call_take_screenshot(args: Dictionary) -> Dictionary:
	# capture_type=game(真实截图) 分析游戏运行画面：编辑器模式经调试线转发到游戏进程，运行时就地。
	var capture_type: String = VariantTool.get_string(args, "capture_type", "game")
	if capture_type == "game":
		if server.is_editor_mode():
			return await server._call_runtime_proxy("take_screenshot", args)
		return await server._runtime_take_screenshot(args)
	# editor / scene 两模式只取编辑器自己的像素，整段在 MCPScreenshotEditor 里。
	if not Engine.is_editor_hint():
		return server._fail("editor/scene 截图仅在编辑器进程可用")
	return await server._mod("MCPScreenshotEditor").capture_editor_side(capture_type, args)


func _call_run_game(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return server._fail("仅在编辑器模式可运行游戏")
	if _has_game_session():
		return server._fail("游戏已在运行(活跃调试会话)。如需重启请用 game_control(action=start)(会自动停掉旧实例)。")
	var raw := VariantTool.get_string(args, "scene")
	var source := "参数 scene"
	if raw.is_empty():
		raw = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		source = "项目主场景(application/run/main_scene)"
		if raw.is_empty():
			return server._err_validation(
				"必须提供 scene(要运行的场景 res:// 路径), 例如 res://Scenes/<主场景>.tscn",
				"传入 scene 参数后重试。")
	# uid:// → res://。解析失败时模块会先重扫 UID 缓存再重试一次 —— 编辑器重启后第一次启动
	var scene: String = await server._mod("MCPScriptSync").resolve_scene_path(raw)
	if scene.is_empty():
		return server._err_validation("无法把%s解析为项目内资源路径: %s" % [source, raw],
			"确认该资源已导入; 也可绕过 uid 解析 —— 直接传 res:// 路径形式。")
	if not ResourceLoader.exists(scene):
		return server._err_validation("启动场景不存在: %s" % scene,
			"传入存在的场景路径后重试。")
	var scene_res: Resource = ResourceLoader.load(scene)
	if not scene_res is PackedScene:
		return server._fail("不是有效场景文件: %s(类型: %s)" % [scene, scene_res.get_class() if scene_res else "null"])
	# 以调试模式启动(等效编辑器 F5)：编辑器自动建立 EngineDebugger 调试线，
	server._mod("MCPEditorEnv").play_custom_scene(scene)
	var ok_ready := await _wait_game_ready(15.0)
	if not ok_ready:
		return server._ok("已启动游戏(场景=%s), 但调试线 %d 秒内未就绪, 稍后重试运行时工具。" % [scene, int(15.0)])
	return server._ok("已启动游戏(调试模式, 场景=%s), 运行时工具已就绪。" % scene)


func _call_stop_game(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return server._fail("仅在编辑器模式可停止游戏")
	if server.debugger_plugin == null or not server.debugger_plugin.has_active_session():
		return server._fail("当前没有运行中的游戏")
	server._mod("MCPEditorEnv").stop_playing_scene()
	server._game_ready = false
	return server._ok("已停止游戏")


## 等待游戏调试会话结束(供 start 前自动停止旧实例用)，超时返回 false
func _wait_game_stopped(timeout_sec: float = 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		if not _has_game_session():
			return true
		await server.get_tree().create_timer(0.1).timeout
	return not _has_game_session()


## 等待游戏进程的调试线桥接就绪(session 已激活 且 收到 dev_mcp:ready)，超时返回 false
func _wait_game_ready(timeout_sec: float = 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while Time.get_ticks_msec() < deadline:
		if bool(server._game_ready) and _has_game_session():
			return true
		await server.get_tree().create_timer(0.1).timeout
	return false
