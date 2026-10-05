extends SceneTree

## 测试 headless 入口:
##   godot --headless --script res://addons/DEVFramework/Test/run_headless.gd
##     → 只跑**进程无关**用例(编辑器进程语义, 快、无副作用)
##   godot --headless --script res://addons/DEVFramework/Test/run_headless.gd -- --game
##     → 先加载项目主场景(游戏进程语义: autoload + 场景树 + 真实时间), 再跑**需要游戏进程**的用例
## 退出码: 全部通过=0, 存在失败=1(CI 可直接判定)。
##
## 进程归属由用例自行声明(`TestCase.needs_game_process()`); 跑错进程的用例会被列为 skipped,
## 不会假失败也不会静默通过 —— 所以两种模式的结果合起来才是全量。

## 等待主场景就绪的最长帧数(约 4s@60fps): 游戏用例依赖场景树/单例/首帧逻辑都已就位
const GAME_READY_MAX_FRAMES := 240


func _initialize() -> void:
	if _wants_game_mode():
		_run_game()
	else:
		_run()


func _wants_game_mode() -> bool:
	for a in OS.get_cmdline_user_args():
		if str(a) == "--game":
			return true
	return false


func _run() -> void:
	var summary: Dictionary = await TestRunner.run_all("", TestRunner.TESTS_DIR, TestRunner.MODE_EDITOR)
	print(str(summary.get("text", "")))
	quit(0 if int(summary.get("failed", 1)) == 0 else 1)


## 游戏进程模式: 先起主场景, 等它就绪, 再跑游戏用例。
## ⚠️ 依赖 autoload(如 RankManager)与主场景节点在 headless 下能正常初始化;
## 若项目的主场景在 headless 下跑不起来, 应改用 MCP `run_game_tests`(跑在真实游戏进程里)。
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
	var summary: Dictionary = await TestRunner.run_all("", TestRunner.TESTS_DIR, TestRunner.MODE_GAME)
	print(str(summary.get("text", "")))
	quit(0 if int(summary.get("failed", 1)) == 0 else 1)


func _await_scene_ready() -> void:
	for _i in GAME_READY_MAX_FRAMES:
		await process_frame
		if current_scene != null and current_scene.is_node_ready():
			## 再多等两帧: 让 _ready/_enter_* 里的首个 await 段有机会跑完
			await process_frame
			await process_frame
			return
	printerr("[测试] 等待主场景就绪超时(%d 帧), 继续执行用例(环境可能不完整)" % GAME_READY_MAX_FRAMES)
