extends SceneTree

## 无头基准运行器：直接跑 QVX 写路径基准并退出，不依赖编辑器 / 游戏窗口。

func _initialize() -> void:
	QVoxelWriteBench.run()
	quit()
