@tool
extends RefCounted

## ======= 框架运维域(仅编辑器) =======
## 运行游戏、重建工具注册表、构建原生扩展 —— 都是在"操作框架本身", 而不是操作项目内容。
## 注册表生命周期与运行时对象由宿主持有, 本域只经 provider 触发, 不反向引用 MCPDevServer。
## **必须带 @tool 且不声明 class_name**, 理由见 MCPDevServer 顶部"工具域文件"一段。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")

## rebuild: 无参 Callable, 返回 {count:int, fingerprint:String, issues:Array} —— 重建注册表并跑契约自检。
static var _rebuild: Callable = Callable()
## runtime: 无参 Callable, 返回 MCPRuntime 实例(懒创建, 回指宿主)。
static var _runtime_provider: Callable = Callable()


static func bind(rebuild: Callable, runtime: Callable) -> void:
	_rebuild = rebuild
	_runtime_provider = runtime


## 宿主未 bind(域脚本被单独重编译/加载)时给出明确错误, 而不是在空 Callable 上崩。
static func _rt() -> Variant:
	if not _runtime_provider.is_valid():
		return null
	return _runtime_provider.call()


static func tools() -> Array:
	return [
		{
			"name": "game_control",
			"desc": "游戏运行控制。start=以调试模式启动(等效F5, 自动建 EngineDebugger 调试线, 缺省用主场景, 已在运行则先停旧实例); stop=停止; continue=解除因脚本错误/断点造成的暂停(报 error_category=game_breaked 时用它, 未暂停时是安全空操作)。**【副作用】start/stop 会抢占用户手头正在调试的游戏进程 —— 执行前先用 get_editor_activity 确认没有人在调试, 执行后游戏不会自动恢复。**",
			"schema": {"type": "object", "properties": {
				"action": {"type": "string", "enum": ["start", "stop", "continue"], "description": "启动/停止/解除断点暂停"},
				"scene": {"type": "string", "description": "action=start 时可选: 要运行的场景 res:// 或 uid:// 路径"}
			}, "required": ["action"]},
			"handler": _handle_game_control,
		},
		{
			"name": "refresh_tools",
			"desc": "重建 MCP 工具注册表并跑契约自检, 返回工具数与 schema_fingerprint(同值=注册表没变)。只对**域脚本**(MCP 目录下除 MCPDevServer.gd 以外的文件)的改动有效; 改了 MCPDevServer.gd 自身必须 restart_editor —— 那种情况下本工具仍报成功, 靠 fingerprint 不变识别。客户端不会自动刷新 tools/list(服务器发不出 list_changed), 需重连 MCP。详见 resources: devframework://docs/refresh_tools",
			"schema": MCPToolContract.no_arg(),
			"handler": _handle_refresh_tools,
		},
		{
			# 原生库不重编不会报任何错: 游戏与测试照跑, 只是跑的是旧 dll。故必须有可调用的构建入口。action=build **必须指定 plugin**(要全部就显式传 all): 全部构建会把没改的插件也重链, 产物时间戳随之变化。
			"name": "build_native",
			"desc": "构建 GDExtension 原生扩展(gdextension/ → addons/DEVFramework/Native)。**改过 gdextension/src/ 之后必须调用**, 否则游戏与测试跑的是旧库且不报任何错。status=只比时间戳(零等待, 改完先查); build=完整构建(CMake→增量编译→部署), 长任务, 超时返回 job_id 用 job_wait 轮询。restart=true 时构建完自动重载编辑器(Windows 上运行中的编辑器锁 dll, 需要重载才生效)。",
			"schema": {"type": "object", "properties": {
				"action": {"type": "string", "enum": ["status", "build"], "description": "status=检查是否需要重编(不编译); build=执行构建"},
				"restart": {"type": "boolean", "description": "action=build 时: 完成后是否自动重载编辑器(默认 false, 由调用方决定何时重启)"},
				# action=build 时必填(由 handler 强制): 不指定就只能"全部构建", 而全部构建会把没改的
				# 插件也重链一遍 —— 链接器每次写入新的 PE TimeDateStamp, 于是"代码一行没改, 产物却变了"。
				# 需要全部构建时显式传 "all"。action=status 不需要它。
				# 【为什么不写进 required】JSON Schema 的 required 是整条工具的, 无法按 action 分档;
				# 写进去会让 status 也变成必须带 plugin。故由 MCPRuntime 在 build 分支强制并给出可选值清单。
				"plugin": {"type": "string", "description": "action=build 时**必填**: 要构建的原生目标(插件的 target 名, 如 dev / voxelsupport); 确实要全部时显式传 \"all\"。action=status 可省略"},
			}, "required": ["action"]},
			"handler": _handle_build_native,
		},
	]


static func _handle_game_control(args: Dictionary) -> Dictionary:
	# 刻意为 Variant: MCPRuntime 由宿主按"当前磁盘版本"重编译, 这里按 preload 的类型绑定会对不上代次。
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("运维域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	return await rt.call_game_control(args)


## 自检结果必须回给调用方: 只落到编辑器日志里等于没查(AI 改完框架脚本看不见对错)。
## 判定"是否真的生效"以 schema_fingerprint 跨次对比为准 —— 客户端缓存了旧 tools/list 时,
## 只有指纹能说明服务器侧到底换没换。
static func _handle_refresh_tools(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.err_validation("仅在编辑器模式可用", "游戏进程与导出包里没有可重建的编辑域")
	if not _rebuild.is_valid():
		return MCPResult.err_internal("注册表重建回调未绑定", "restart_editor 后重试")
	var r: Dictionary = _rebuild.call()
	var count := int(r.get("count", 0))
	var fp := str(r.get("fingerprint", ""))
	var issues: Array = r.get("issues", [])
	var stale: Array = r.get("stale_leaves", [])
	# 叶子改动不生效是"看起来成功了其实跑旧代码", 必须单独说, 不能混进 audit 的通过/失败。
	var stale_note := "" if stale.is_empty() else "【叶子脚本未换代】%s 是域里 const preload 绑定的, 磁盘已改但当前仍跑旧版(需要 restart_editor, 或等编辑器文件系统重扫后再 refresh_tools)。" % ", ".join(PackedStringArray(stale))
	if issues.is_empty():
		return MCPResult.ok_json({
			"tool_count": count,
			"schema_fingerprint": fp,
			"audit": "pass",
			"stale_leaves": stale,
			"message": "%s服务器侧工具注册表已重建: %d 个工具, 契约自检通过, 指纹 %s。判定'是否真的生效'以本指纹跨次对比为准(指纹不变即注册表没变)。【客户端不一定同步】本服务器是短连接 HTTP, 发不出 notifications/tools/list_changed(capabilities 已如实报 listChanged:false), 因此客户端若缓存了旧的 tools/list, 它手上的 schema 仍是旧的 —— 需在 IDE 侧重连 MCP 才会刷新; 在此之前, 以 tools/list 直查服务器为准, 不要拿会话开始时的快照当权威。" % [stale_note, count, fp],
		})
	return MCPResult.ok_json({
		"tool_count": count,
		"schema_fingerprint": fp,
		"audit": "fail",
		"issues": issues,
		"stale_leaves": stale,
		"message": "%s服务器侧工具注册表已重建: %d 个工具, 但契约自检发现 %d 个问题(见 issues), 指纹 %s。判定'是否真的生效'以本指纹跨次对比为准。【客户端不一定同步】本服务器推不出 tools/list_changed, 客户端缓存的旧 tools/list 要到 IDE 侧重连 MCP 才刷新。" % [stale_note, count, issues.size(), fp],
	})


static func _handle_build_native(args: Dictionary) -> Dictionary:
	var rt: Variant = _rt()
	if rt == null:
		return MCPResult.err_internal("运维域未绑定运行时", "调用 refresh_tools 重建注册表; 仍失败说明宿主注册后没走 _bind_domains")
	return await rt.call_build_native_local(args)
