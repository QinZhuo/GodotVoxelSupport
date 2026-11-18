extends SceneTree

## 测试 headless 入口:

## 等待主场景就绪的最长帧数(约 4s@60fps): 游戏用例依赖场景树/单例/首帧逻辑都已就位
const GAME_READY_MAX_FRAMES := 240


var _logger = null


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var arg := str(a)
		if arg.begins_with("--freshness="):
			TestRunner.set_freshness_mode(arg.trim_prefix("--freshness="))
	if _wants_game_mode():
		_run_game()
	else:
		_run()


## headless 也要像 GUT 一样把引擎/脚本报错算进失败（原来只有 MCP 注入 logger 才统计）。
## 传 "--allow-errors" 可关闭（给"故意触发错误"的旧用例兜底）。
func _attach_logger() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a) == "--allow-errors":
			return
	var script = load("res://addons/DEVFramework/MCP/MCPLoggerDebug.gd")
	if script == null:
		return
	_logger = script.new()
	OS.add_logger(_logger)


func _detach_logger() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null


func _wants_game_mode() -> bool:
	for a in OS.get_cmdline_user_args():
		if str(a) == "--game":
			return true
	return false


func _run() -> void:
	_attach_logger()
	var summary: Dictionary = await TestRunner.run_all(_script_arg(), TestRunner.MODE_EDITOR, _logger)
	_detach_logger()
	# 早退（选择器无匹配/解析失败）是同步返回的：若在 _initialize 阶段直接 quit()，
	# 主循环还没起来，退出码会被忽略（实测 no-selector 仍 exit 0）。等一帧再退出。
	await process_frame
	_finish(summary)


## 打印结果并退出: 码 0=全通过 / 1=有失败, 供 CI 判定。两个模式共用
func _finish(summary: Dictionary) -> void:
	print(str(summary.get("text", "")))
	# 0 个用例绝不能算成功：CI 里"没跑"和"跑了全过"必须是两种结局。
	var total := int(summary.get("total", 0))
	if total <= 0:
		printerr("[测试] 本轮执行了 0 个用例（选择器/进程模式/脚本解析/目录扫描），按失败处理。")
		quit(2)
		return
	quit(0 if int(summary.get("failed", 1)) == 0 else 1)


## `-- --script <名字>`: 只跑指定用例; 缺省 = 全量(空串)
func _script_arg() -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--script")
	return str(args[i + 1]) if i >= 0 and i + 1 < args.size() else ""


## 游戏进程模式: 先起主场景, 等它就绪, 再跑游戏用例。
## ⚠️ 依赖项目 autoload 与主场景节点在 headless 下能正常初始化;
func _run_game() -> void:
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		printerr("[测试] 项目未配置 application/run/main_scene, 无法以游戏进程模式运行")
		quit(1)
		return
	print("[测试] 游戏进程模式: 先加载主场景 %s" % main_scene)
	var err := change_scene_to_file(main_scene)
	if err != OK:
		printerr("[测试] 主场景加载失败: %s (err=%d)" % [main_scene, err])
		quit(1)
		return
	await _await_scene_ready()
	_attach_logger()
	var summary: Dictionary = await TestRunner.run_all(_script_arg(), TestRunner.MODE_GAME, _logger)
	_detach_logger()
	_finish(summary)


func _await_scene_ready() -> void:
	for _i in GAME_READY_MAX_FRAMES:
		await process_frame
		if current_scene != null and current_scene.is_node_ready():
			## 再多等两帧: 让 _ready/_enter_* 里的首个 await 段有机会跑完
			await process_frame
			await process_frame
			return
	printerr("[测试] 等待主场景就绪超时(%d 帧), 继续执行用例(环境可能不完整)" % GAME_READY_MAX_FRAMES)