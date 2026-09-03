extends SceneTree

## 测试 headless 入口:
##   godot --headless --script res://addons/DEVFramework/Test/run_headless.gd
## 退出码: 全部通过=0, 存在失败=1(CI 可直接判定)。

func _initialize() -> void:
	_run()


func _run() -> void:
	var summary: Dictionary = await TestRunner.run_all()
	print(str(summary.get("text", "")))
	quit(0 if int(summary.get("failed", 1)) == 0 else 1)
