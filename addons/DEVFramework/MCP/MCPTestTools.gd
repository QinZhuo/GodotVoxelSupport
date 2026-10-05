@tool
extends RefCounted

## ======= 测试域 =======
##
## 从 MCPDevServer 拆出的工具域文件, 沿其余域文件的样板。收录"让框架自己证明自己"的能力:
##   - run_tests  跑项目单元测试(编辑器侧只跑进程无关用例)
##
## 依赖方向: 严格单向 —— 本文件不引用 MCPDevServer, 也不持有任何服务器状态。只依赖:
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - TestRunner     全局 class_name, 用例发现与执行
##   - VariantTool    全局 class_name, 入参读取
## 注册靠"把 _add_tool 当 Callable 传进来"完成, 所以连服务器的类型都不需要认识。
##
## handler 一律 static, 理由与其余域一致(见 MCPValidateTools 顶部"为什么 handler 一律 static"
## 第 1 条): MCPToolAudit 的入参一致性自检靠 handler.get_method() 拿函数名、再去源码里切函数体,
## 改用 lambda 注册会让自检静默跳过 —— 比不自检更糟。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## 注册本域工具。add_tool 由服务器以 `_add_tool` 的形式传进来。
static func register(add_tool: Callable) -> void:
	add_tool.call("run_tests",
		"运行项目单元测试(Scripts/Test/ 目录, extends TestCase, test_ 开头方法自动发现; 支持协程用例)。返回通过/失败统计与失败明细。修改核心逻辑(ModifierValue/EffectsDef/StateMachine/Task/GameCommand 等)后建议调用。",
		{"type": "object", "properties": {
			"filter": MCPToolSchema.str_arg("可选: 用例文件路径子串过滤, 如 test_effects")
		}},
		_handle_run_tests)


## 编辑器侧: 只跑**进程无关**用例(纯逻辑/资源)。需要游戏进程的用例会被 TestRunner 列为
## skipped 并写进结果文本, 由 `run_game_tests` 在游戏进程里执行 —— 两类合起来才是全量,
## 绝不静默通过(旧行为会让游戏用例因缺 MonitorGame 而假失败或漏跑)。
static func _handle_run_tests(args: Dictionary) -> Dictionary:
	var filter := VariantTool.get_string(args, "filter")
	var summary: Dictionary = await TestRunner.run_all(filter, TestRunner.TESTS_DIR, TestRunner.MODE_EDITOR)
	return MCPResult.ok_json(summary)
