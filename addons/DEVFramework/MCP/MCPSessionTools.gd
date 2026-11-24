@tool
extends RefCounted

## ======= 会话域: 长任务 / 性能 / 日志 (进程无关) =======
## 这些工具在编辑器进程与游戏进程里都注册, 但同一个工具在两个进程里的"该谁干"不同:
##   · 编辑器进程 → *_routed: 编辑器侧就地执行或经调试线转发到游戏;
##   · 游戏进程   → *_local : 本进程即目标, 不再转发。
## 判据只有 Engine.is_editor_hint() 一条, 收在 _handlers 里, 于是注册时不必再区分两套 handler。
## 具体实现在 MCPRuntime(由宿主经 bind 注入), 本域只提供工具面。
## **必须带 @tool 且不声明 class_name**, 理由见 MCPDevServer 顶部"工具域文件"一段。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")

## 无参 Callable, 返回 MCPRuntime 实例(宿主懒创建, 回指宿主)。
static var _runtime_provider: Callable = Callable()


static func bind(runtime: Callable) -> void:
	_runtime_provider = runtime


## 宿主未 bind(域脚本被单独重编译/加载)时给出明确错误, 而不是在空 Callable 上崩。
static func _rt() -> Variant:
	if not _runtime_provider.is_valid():
		return null
	return _runtime_provider.call()


static func tools() -> Array:
	# 日志 schema 的 process 参数走统一工厂, 免得与 get_logs 的描述各写一份而漂移。
	var logs_schema := MCPToolContract.logs("200(log)/100(warning|error)", "条目", {
		"process": MCPToolContract.process_arg("读哪个进程的缓冲"),
		"kind": {"type": "string", "enum": ["log", "warning", "error"], "description": "获取类别, 默认 log"},
	})
	logs_schema["required"] = ["process"]
	return [
		{
			"name": "run_tests",
			"desc": "运行单元测试(Scripts/Test/ 下 extends TestCase, test_ 方法自动发现)。script 必填: 脚本名子串 / 'all'=全量 / 内联 GDScript 源码(不落盘)。process 必填: editor|game|both。**长任务**: wait_sec 默认 5, 超窗口返回 {job_id, running:true}, 用 job_wait 继续等; 建议 wait_sec=0~5 避免客户端 30s 超时丢 job_id。详见 resources: devframework://docs/run_tests",
			"schema": {"type": "object", "properties": {
				"process": {"type": "string", "enum": ["editor", "game", "both"], "description": "在哪个进程跑: editor=编辑器进程(只跑进程无关用例); game=游戏进程(跑 needs_game_process() 用例; 无运行中的游戏时自动启动一个); both=先 editor 段再 game 段并合并(**同步阻塞**, 跑全量用)。"},
				"script": {"type": "string", "description": "必填。二选一(靠内容自动判别): ①测试脚本路径子串(如 'test_game_replay'), 只运行匹配的用例文件; 'all'=全量(**不推荐**: 耗时可能过长)。②**内联 GDScript 源码**——含换行 或 以 'extends ' 开头即判为源码, 需 `extends TestCase` 并定义 test_ 开头的断言方法, 直接编译运行、**不落盘**, 适合临时验证(上限 8192 字符)。单个词(含打错的脚本名)一律按选择器处理。"},
				"wait_sec": {"type": "number", "minimum": 0, "maximum": 25, "description": "启动后最多阻塞等待秒数(默认 5, 0=立即返回 job_id, 上限 25)。长测试建议 0~5, 再用 job_wait(job_id) 轮询，避免客户端 30s 超时丢失 job_id。"},
			}, "required": ["process", "script"]},
			"handler": _handle_run_tests,
		},
		{
			"name": "job_wait",
			"desc": "等待长任务结束(**通用**: 任何返回 job_id + running:true 的接口都适用, 不会重跑任务)。每次调用固定等 28 秒(不超过 MCP 客户端 30s 上限, 调用方无需也不能指定): 完成 → 返回完整结果(status=done/failed); 未完成 → 返回同一 job_id 的进度快照(progress/current/elapsed_ms), 继续调它即可。job 在哪个进程不用管, 工具会自动找到(先本地, 再转游戏进程)。典型用法: 拿到 job_id 后循环 job_wait(job_id) 直到 running == false。",
			# 等待时长固定(28s)且不可指定 —— 挂一个同名"说明"参数只会诱导模型去填一个毫无作用的入参。
			"schema": {"type": "object", "properties": {
				"job_id": {"type": "string", "description": "长任务返回体里的 job_id。省略=最近启动的那个 job(JobTool 会回落 _active/最近的 job)。"},
			}},
			"handler": _handle_job_wait,
		},
		{
			"name": "job_list",
			"desc": "列出本进程记得的 job(最近的在前, 摘要级: 状态/进度/耗时/ETA/是否已请求取消)。用于「不知道 job_id 但想知道那个任务怎样了」—— 例如上一次响应被客户端超时丢掉了。要完整结果(含 result)仍用 job_wait(job_id)。",
			"schema": MCPToolContract.no_arg(),
			"handler": _handle_job_list,
		},
		{
			"name": "job_cancel",
			"desc": "请求取消长任务(在任务的下一个检查点生效; 正在 await 的协程无法中途掐断, 所以可能还要等当前用例跑完)。",
			"schema": {"type": "object", "properties": {
				"job_id": {"type": "string", "description": "要取消的 job_id。"},
			}, "required": ["job_id"]},
			"handler": _handle_job_cancel,
		},
		{
			"name": "perf",
			"desc": "性能采样。action=snapshot=即时指标(零等待); fps=采样 N 帧, 返回 avg/p50/p95/p99、fps_1pct_low(判断手感的标准口径)、卡顿次数、CV(>10% 说明测量不可信) 与 env(环境不同则数字互不可比); history=历史耗时基线; reset=清空基线。process 必填, **测帧率必须 game**(编辑器进程被空闲节流压到 10fps)。**逻辑微基准别用本工具**, 用 run_tests 传内联 TestCase(assert_fps_at_least/assert_under_ms), 阈值能进 CI。",
			"schema": {"type": "object", "properties": {
				"process": MCPToolContract.process_arg("在哪个进程采样 —— **测帧率必须选 game**"),
				"action": {"type": "string", "enum": ["snapshot", "fps", "history", "reset"], "description": "snapshot=当前即时指标(零等待); fps=采样 N 帧算 p50/p95/卡顿; history=历史耗时基线; reset=清空基线重新积累。"},
				"frames": {"type": "integer", "description": "action=fps 时采样的帧数, 默认 120(约 2 秒 @60fps), 上限 1200。"},
				"warmup": {"type": "integer", "description": "action=fps 时先丢弃的预热帧数, 默认 30 —— 首帧的着色器编译/资源加载会让结果高出量级。"},
				"key": {"type": "string", "description": "action=history 时的 key 子串过滤(如 'test:' 只看测试基线, 'job:run_tests' 只看测试任务); 省略=全部。"},
			}, "required": ["process", "action"]},
			"handler": _handle_perf,
		},
		{
			"name": "get_logs",
			"desc": "获取日志/错误/警告(获取而非打印), process 必填: editor=编辑器进程缓冲, game=游戏进程缓冲(需游戏运行; 导出运行时=本进程; 游戏断点暂停时仍可安全读)。kind=log 取 print; warning 取 push_warning; error 取脚本错误(script_error/shader_error/stderr, 含栈追踪)。返回 next 游标作 since 增量拉取, 连续重复自动合并(repeat 计数)省 token。",
			"schema": logs_schema,
			"handler": _handle_get_logs,
		},
		{
			"name": "clear_logs",
			"desc": "清空指定进程的日志/错误缓冲(调试复位)。process 必填: editor/game。scope=all 全清; logs 只清 print 日志; errors 只清错误与警告。",
			"schema": MCPToolContract.clear_logs(),
			"handler": _handle_clear_logs,
		},
	]


## ======= 双进程分发 =======

## 编辑器进程: 目标可能是它自己, 也可能是它拉起的游戏 → 走 routed(内部按 process 决定)。
## 游戏进程(含导出运行时): 本进程就是目标 → 走 local, 不再转发。
static func _handle_run_tests(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_run_tests_routed(args)
	return await rt.call_run_tests_local(args)


static func _handle_job_wait(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_job_wait_routed(args)
	return await rt.call_job_wait_local(args)


static func _handle_job_list(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_job_list_routed(args)
	return await rt.call_job_list_local(args)


static func _handle_job_cancel(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_job_cancel_routed(args)
	return await rt.call_job_cancel_local(args)


static func _handle_perf(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_perf_routed(args)
	return await rt.call_perf_local(args)


static func _handle_get_logs(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_get_logs_routed(args)
	return await rt.call_get_logs_local(args)


static func _handle_clear_logs(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("会话域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	if Engine.is_editor_hint():
		return await rt.call_clear_logs_routed(args)
	return await rt.call_clear_logs_local(args)
