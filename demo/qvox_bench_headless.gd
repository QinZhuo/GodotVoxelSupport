extends SceneTree

## 无头基准运行器：直接跑 QVox 写路径基准并退出，不依赖编辑器 / 游戏窗口。
## 用法：
##   godot --headless --path <proj> --script res://demo/qvox_bench_headless.gd
##
## 基准本体在 demo/qvox_write_bench.gd（class_name QVoxWriteBench）。这里只负责在无头
## SceneTree 里触发它 —— 实现只有一份，避免两处各自抄一遍后慢慢漂移。

func _initialize() -> void:
	QVoxWriteBench.run()
	quit()
