class_name ResetTool

## 会话级静态状态复位：切场景 / 回标题 / 换存档 / 测试每例后，调一次 `all()`。
##
## 登记纪律：
##   · 含 `static var` 的 `XxxTool` 必须在此登记，否则 `test_contract_reset` 失败；
##   · 进程级缓存（日志镜像 / 平台查询 / 语言表 / LUT）在类文件头标 `## Reset: 进程级` 豁免；
##   · `reset()` 只清会话数据，不打断在途协程。

static func all() -> void:
	UITool.reset()
	TipTool.reset()
	FocusMaskTool.reset()
	TimeTool.reset()
	TickTool.reset()
	PointerTool.reset()
	AudioTool.reset()
	PoolTool.reset()
	SaveTool.reset()
	PrewarmTool.reset()
	InputTool.reset()
	AsyncTool.reset()
	CameraTool.reset()
	TaskTool.reset()
	DialogueTool.reset()
