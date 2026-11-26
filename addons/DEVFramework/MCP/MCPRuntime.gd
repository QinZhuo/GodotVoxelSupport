@tool
extends RefCounted

## ======= 运行时（游戏进程）桥接 =======
## 由 MCPDevServer 以 preload 常量 `MCPRuntime` 引用。**必须 @tool 且不声明 class_name**。
## 集中在一处的原因: 这些实现全都围绕同一条判断 —— 这条请求该在编辑器进程还是游戏进程执行。

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

## runtime 侧(服务器位于游戏进程内): 只能跑 game 用例, editor 段无从执行。
func call_run_tests_local(args: Dictionary) -> Dictionary:
	return await _run_tests_start(args, TestRunner.MODE_GAME)


## 启动测试并等一个窗口: 窗口内跑完直接给结果, 超窗则返回 job 凭据交给客户端轮询。
## 调用方**不需要**知道 job 的存在 —— 返回体里有 `job_id` 且 `running` 时才需要 job_wait。
func _run_tests_start(args: Dictionary, mode: String) -> Dictionary:
	var script := VariantTool.get_string(args, "script").strip_edges()
	if script.is_empty():
		return server._fail("必须指定测试脚本(script: 脚本路径子串如 'test_game_replay', 或 'all' 全量, 或内联 GDScript 源码)")
	# 内联源码先编译预检: 语法错就地拦, 不占用 job
	if TestRunner.is_inline_source(script):
		var pre := TestRunner.precheck_inline(script, server._logger)
		if pre != "":
			return server._err_validation("内联测试代码预检未通过:\n%s" % pre,
				"修正内联测试源码后重试; 或改成文件放到 %s 下再用 script 路径跑" % TestRunner.TESTS_DIR)
	var wait_sec := clampf(VariantTool.get_float(args, "wait_sec", 5.0), 0.0, 25.0)
	return await _run_as_job("run_tests:%s" % script,
		func() -> Dictionary: return await TestRunner.run_all(script, mode, server._logger),
		int(wait_sec * 1000.0))


## 长任务统一收口: 启动 → 等一个窗口(窗口内跑完就直接给结果) → 补"怎么轮询"的提示。
## 所有返回 job 凭据的工具都走这里, 否则等待时长与提示文案又会各写一份。
func _run_as_job(key: String, work: Callable, wait_ms: int = JobTool.DEFAULT_WAIT_MS) -> Dictionary:
	var snap: Dictionary = JobTool.start(key, work)
	if bool(snap.get("running", false)) and wait_ms > 0:
		# 只等调用方指定的窗口：wait_sec=0 时立即把 job_id 交回去，客户端不会因为 30s 超时丢凭据。
		snap = await JobTool.wait(str(snap.get("job_id", "")), mini(wait_ms, JobTool.DEFAULT_WAIT_MS))
	return server._ok_json(_with_job_hint(snap))


## 未结束时补一句"怎么轮询"(客户端只认 job_id + running, 提示只是方便读)
func _with_job_hint(snap: Dictionary) -> Dictionary:
	if bool(snap.get("running", false)):
		snap["hint"] = "任务超过 %d 秒仍在运行, 已转为 job: 调 job_wait(job_id=\"%s\") 轮询 —— 完成即返回结果, 且不会重跑" % [
			JobTool.DEFAULT_WAIT_MS / 1000, str(snap.get("job_id", ""))]
	return snap


## editor 侧分派: process 决定"在哪个进程跑", action 决定"启动/查询"。
## 关键: job 状态在跑测试的进程里, 所以 status/result/cancel 必须路由到同一进程。
func call_run_tests_routed(args: Dictionary) -> Dictionary:
	var process := VariantTool.get_string(args, "process").strip_edges()
	if process == "":
		process = "editor"
	if process != "editor" and process != "game" and process != "both":
		return server._fail("process 必须是 editor / game / both, 收到: '%s'" % process)
	var action := VariantTool.get_string(args, "action").strip_edges().to_lower()
	if action == "":
		action = "run"
	if process == "both":
		# both = 编辑器段 + 游戏段, 天然是长任务 ⇒ 同样走 job: 超窗就交客户端轮询, 不要阻塞到跑完
		var both_script := VariantTool.get_string(args, "script").strip_edges()
		return await _run_as_job("run_tests:both:%s" % both_script,
			func() -> Dictionary: return await _run_tests_both(both_script))
	if process == "game":
		return await _run_tests_in_game(args)
	return await _run_tests_start(args, TestRunner.MODE_EDITOR)


## 转发到游戏进程（含自动启动）。args 原样转发: process/script 给到对端。
func _run_tests_in_game(args: Dictionary) -> Dictionary:
	var script := VariantTool.get_string(args, "script").strip_edges()
	var fwd := {"process": "game"}
	if script != "":
		fwd["script"] = script
	var auto_started := false
	if not _has_game_session():
		var started: Dictionary = await _call_run_game({})
		if bool(started.get("is_error", false)):
			return started
		auto_started = true
		# 自动启动在调试线 15s 内未就绪时, 启动本身仍返回成功文案, 故必须单独判就绪标志。
		if not bool(server._game_ready):
			return server._err_transient("已自动启动游戏, 但调试线 15 秒内未就绪, 本轮测试未执行",
				"稍后重试; 或 game_control(action=start) 后确认游戏窗口已进入主场景再调 run_tests")
		# 调试线就绪 ≠ 主场景初始化完: autoload 的 ready 早于场景根 _ready, 此刻注入测试会插进
		# 半初始化状态, 首轮用例常因依赖对象还是 null 而失败。
		# ignore_time_scale=true: 用例常把 time_scale 调高, 等待不能被它缩短。
		await server.get_tree().create_timer(2.0, true, false, true).timeout
	var raw: Dictionary = await server._call_runtime_proxy("run_tests", fwd)
	if bool(raw.get("is_error", false)):
		return raw
	# job 快照(status/progress/...)与"跑完的汇总(total/passed/failed)"是两种形状:
	# 只有跑完(或已结束)才做汇总修饰, 运行中直接原样返回给调用方轮询。
	var payload := _summary_of(raw)
	if payload.is_empty():
		payload = raw
	if auto_started:
		payload["auto_started_game"] = true
		var keep_text := str(payload.get("text", ""))
		payload["text"] = "[已自动启动游戏进程(此前无运行实例)]\n%s" % keep_text
	return server._ok_json(payload)


## process=both: 编辑器段 → 游戏段，合并成一份汇总。
func _run_tests_both(script: String) -> Dictionary:
	if TestRunner.is_inline_source(script):
		# 内联源码只跑一次：它是临时逻辑验证，两段跑同一段代码只是翻倍耗时
		return await TestRunner.run_all(script, TestRunner.MODE_EDITOR, server._logger)
	var editor_sum: Dictionary = await TestRunner.run_all(script, TestRunner.MODE_EDITOR, server._logger)
	# 选择器一条都没匹配上(早退结果)：游戏段必然同样为空，不再白起一轮
	if int(editor_sum.get("total", 0)) == 0 and int(editor_sum.get("failed", 0)) > 0:
		return editor_sum
	var game_res: Dictionary = await _run_tests_in_game({"process": "game", "action": "run", "script": script})
	if bool(game_res.get("is_error", false)):
		return _both_with_game_failure(editor_sum, script, _error_text(game_res))
	var game_sum := _summary_of(game_res)
	if game_sum.is_empty():
		return _both_with_game_failure(editor_sum, script, "游戏进程返回内容无法解析为测试汇总")
	var merged: Dictionary = TestRunner.merge_summaries([editor_sum, game_sum], script)
	if bool(game_sum.get("auto_started_game", false)):
		merged["auto_started_game"] = true
		merged["text"] = "[已自动启动游戏进程(此前无运行实例)]\n%s" % str(merged.get("text", ""))
	return merged


## 游戏段没跑成 = 全量没跑成：记成**一条失败项**而不是静默省略
func _both_with_game_failure(editor_sum: Dictionary, script: String, reason: String) -> Dictionary:
	var merged: Dictionary = TestRunner.merge_summaries([editor_sum], script)
	merged["total"] = int(merged["total"]) + 1
	merged["failed"] = int(merged["failed"]) + 1
	merged["passed"] = int(merged["total"]) - int(merged["failed"])
	merged["failures"].append("<游戏段> 未执行: %s" % reason)
	merged["cases"].append({"case": "<游戏段>", "ok": false, "elapsed_ms": 0})
	merged["text"] = TestRunner.render_text(merged)
	return merged


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
			# 已在运行时自动停旧实例再启动：旧实例持有的是启动时固化的脚本, 而重启后才会重新读盘。
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
	# uid:// → res://。解析失败时模块会先重扫 UID 缓存再重试一次(编辑器重启后首次启动常见)。
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
	# 以调试模式启动(等效编辑器 F5): 编辑器自动建立 EngineDebugger 调试线。
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
	# 主动停止: 上一轮的错误副本不再代表当前状态, 别让下一次调用背上旧的"崩溃"提示
	server._game_error_digest.clear()
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


# ------------------------------------------------------------
# 通用长任务查询(与具体工具无关)
# 客户端只认一条规则: 返回体里有 job_id 且 running → job_wait(job_id) 循环。
# job 状态在"跑任务的进程"里, 这里自动判断在本进程还是游戏进程, 调用方不必关心。
# ------------------------------------------------------------

func call_job_wait_local(args: Dictionary) -> Dictionary:
	# 等待时长**固定** 28s(JobTool.DEFAULT_WAIT_MS): 不接受调用方指定 ——
	# 传大值只会把自己卡到 MCP 客户端的 30s 上限, 传小值则无谓地多次往返。
	# JobTool.wait 内部 await 主循环帧, 是协程 —— 必须 await
	return server._ok_json(await JobTool.wait(VariantTool.get_string(args, "job_id").strip_edges()))


func call_job_wait_routed(args: Dictionary) -> Dictionary:
	return await _route_job("job_wait", args, call_job_wait_local)


func call_job_cancel_local(args: Dictionary) -> Dictionary:
	return server._ok_json(JobTool.cancel(VariantTool.get_string(args, "job_id").strip_edges()))


func call_job_cancel_routed(args: Dictionary) -> Dictionary:
	return await _route_job("job_cancel", args, call_job_cancel_local)


## 列出 job: 本地有就直接给本地; 本地空且有游戏会话时才去问游戏进程。
## 与 wait/cancel 的"先探本地"不同 —— 列表没有 id 可探, 本地"空列表"本身不是答案。
func call_job_list_local(_args: Dictionary) -> Dictionary:
	return server._ok_json(JobTool.list())


func call_job_list_routed(args: Dictionary) -> Dictionary:
	var local: Dictionary = JobTool.list()
	if int(local.get("count", 0)) > 0 or not _has_game_session():
		return server._ok_json(local)
	var r: Dictionary = await server._call_runtime_proxy("job_list", args)
	if not bool(r.get("is_error", false)):
		return r
	return server._ok_json(local)


## ------- perf: 帧率 / 引擎指标 -------
## action=snapshot(即时指标) / fps(采样 N 帧) / history(历史耗时基线) / reset(清基线)。
## 逻辑微基准**不走这里**: 用 run_tests 传内联 TestCase + assert_under_ms —— 那边才有断言与历史基线。

func call_perf_local(args: Dictionary) -> Dictionary:
	var action := VariantTool.get_string(args, "action", "snapshot").strip_edges().to_lower()
	match action:
		"snapshot":
			return server._ok_json(PerfTool.snapshot())
		"fps":
			var frames := clampi(VariantTool.get_int(args, "frames", 120), 10, 1200)
			var warmup := clampi(VariantTool.get_int(args, "warmup", 30), 0, 600)
			var report: Dictionary = await PerfTool.sample_frames(frames, warmup)
			if report.has("error"):
				return server._err_transient(str(report["error"]), "改在游戏进程里调用(action=fps 需要真实帧循环)")
			return server._ok_json(report)
		"history":
			return server._ok_json({"items": PerfTool.history_all(VariantTool.get_string(args, "key").strip_edges())})
		"reset":
			PerfTool.clear_history()
			return server._ok_json({"cleared": true})
	return server._fail("action 必须是 snapshot / fps / history / reset, 收到: '%s'" % action)


func call_perf_routed(args: Dictionary) -> Dictionary:
	var process := _require_process(args)
	if process == "game":
		return await server._call_runtime_proxy("perf", args)
	if process == "" or process == "editor":
		return await call_perf_local(args)
	return server._fail("process 必须是 editor / game, 收到: '%s'" % process)


## 可构建的原生 target 名(供 build_native 报错时列选项)。
func _native_target_names() -> Array[String]:
	var out: Array[String] = []
	var st: Dictionary = GDExtensionRebuild.native_status()
	for t in st.get("targets", []):
		var name := String((t as Dictionary).get("target", ""))
		if name != "" and not out.has(name):
			out.append(name)
	return out


## ------- build_native: 原生扩展构建 -------
## 构建流程**只存在于 GDExtensionRebuild**(菜单与 MCP 共用同一份), 这里只做 action 分发 + job 包装。

func call_build_native_local(args: Dictionary) -> Dictionary:
	var action := VariantTool.get_string(args, "action", "status").strip_edges().to_lower()
	match action:
		"status":
			return server._ok_json(GDExtensionRebuild.native_status())
		"build":
			var restart := bool(args.get("restart", false))
			# 必须显式指定插件: 全部构建会把没改的插件也重链一遍, 产物时间戳因此变化。
			# schema 已把 plugin 标为必填(见 MCPDevActions), 这里再兜一层并给出可选项。
			var plugin := VariantTool.get_string(args, "plugin").strip_edges()
			if plugin == "":
				return server._fail("build 必须指定 plugin(要全部构建请显式传 \"all\")。可选: %s"
						% ", ".join(PackedStringArray(_native_target_names())))
			return await _run_as_job("build_native",
				func() -> Dictionary: return await GDExtensionRebuild.build_now(restart, plugin))
	return server._fail("action 必须是 status / build, 收到: '%s'" % action)


## job 状态存在**跑任务的那个进程**里: 先查本进程, 没有再转发游戏进程。
## wait / cancel 的路由逻辑完全相同, 抽在这里避免两份拷贝各自漂移。
func _route_job(tool: String, args: Dictionary, local: Callable) -> Dictionary:
	var job_id := VariantTool.get_string(args, "job_id").strip_edges()
	var probe := JobTool.status(job_id)
	if not probe.has("error"):
		return await local.call(args)
	if not _has_game_session():
		return server._ok_json(probe)
	var r: Dictionary = await server._call_runtime_proxy(tool, {"job_id": job_id})
	if not bool(r.get("is_error", false)):
		return r
	return server._ok_json(probe)   # 两边都没有 → 返回本进程的原始错误