@tool
extends RefCounted

## ======= 多实例管理域 =======
## 实例清单/目标切换/崩溃后拉起/崩溃取证。前两项走 MCPRouter, 后两项直接读中枢记录并
## spawn 进程 —— 这是"目标实例已经死了"时唯一还能自救的路径, 故必须在**活着的**编辑器进程里执行。
## **必须带 @tool 且不声明 class_name**, 理由见 MCPDevServer 顶部"工具域文件"一段。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")

## 中枢与路由器由宿主注入(本域是纯 RefCounted, 拿不到服务器成员)。
## 两者都可能为 null: 游戏进程/导出包里没有多实例能力, 那时相关工具本就不注册。
static var _hub: Variant = null
static var _router: Variant = null


static func bind(hub: Variant, router: Variant) -> void:
	_hub = hub
	_router = router


## 本域的工具清单。hub_tools = 由中枢自己应答、不参与转发的那两个(见 MCPRouter.HUB_TOOLS)。
static func tools() -> Array:
	return [
		{
			"name": "list_instances",
			"desc": "列出本机当前所有装了本框架的 Godot 编辑器实例(含本进程)。每项: instance_id(如 MyGame@a1b2c3d4)、name、project_path、port、age_ms(心跳多久前, 越小越新)、is_self、is_hub。age_ms 明显大于 4000 说明该实例可能已关闭(会被自动剔除)。**同时打开多个项目时先调它**, 再用 use_instance 选默认目标, 或用工具的 instance 参数单次指定。",
			"schema": MCPToolContract.no_arg(),
			"handler": _handle_list_instances,
		},
		{
			"name": "use_instance",
			"desc": "设置**默认目标编辑器实例**。设置后, 之后所有工具调用(未显式传 instance 参数时)都转发到该实例的编辑器进程执行。instance 可填 instance_id(如 MyGame@a1b2c3d4)、唯一前缀(hash 或项目名前缀)、端口号; 传空字符串 = 恢复为「本实例」。设置会跨重启保留(目标编辑器回来后自动接回); 目标不在线时报错, 不会改到别的项目。**同时打开多个项目时, 先调 list_instances 拿 id, 再调本工具选一个**。",
			"schema": {"type": "object", "properties": {
				"instance": {"type": "string", "description": "目标实例: instance_id / 唯一前缀 / 端口号; 空字符串=恢复本实例。可用值见 list_instances。"},
			}},
			"handler": _handle_use_instance,
		},
		{
			# restart_editor 只能在**目标还活着**时用(它调的是该进程的 EditorInterface.restart_editor),
			# 崩溃/被强杀后没有任何实例能响应它。launch_project 由当前活着的实例直接 spawn 新进程。
			"name": "launch_project",
			"desc": "启动(或重启)某个项目的 Godot 编辑器 —— **即使那个项目的实例已经崩溃/被关闭**也能用: 由当前活着的实例直接 spawn 新进程。返回 pid、是否已注册、上次离开记录(previous_exit.clean=false 即上次是崩溃/强杀)。默认不阻塞(wait_ms=0), 之后用 list_instances 轮询它上线; 传 wait_ms>0 会在本实例里阻塞等待(最长该值), 期间本编辑器无响应。",
			"schema": {"type": "object", "properties": {
				"project_path": {"type": "string", "description": "项目根目录绝对路径(含 project.godot), 如 D:/Work/GodotProject/DEV Framework"},
				"wait_ms": {"type": "integer", "description": "阻塞等待实例上线的毫秒数; 0(默认)=立即返回, 由调用方轮询 list_instances"},
				"force": {"type": "boolean", "description": "崩溃环保护: 10 分钟内非正常退出 >=3 次时默认拒绝拉起(避免刷屏); 确认要强拉就传 true"},
			}, "required": ["project_path"]},
			"handler": _handle_launch_project,
		},
		{
			"name": "crash_report",
			"desc": "崩溃取证: 汇总某项目最近的非正常退出记录(含存活时长)、editor 日志尾部、以及 Windows 事件日志里的**故障模块@偏移**。若连续两次的 模块+偏移 相同, 会直接标 same_fault=true —— 那说明上一个修复没生效。崩溃后先看它, 再决定改代码还是拉起。scope=exits 只取退出记录(最快), scope=full(默认) 才追加日志尾部与 Windows 事件日志。详见 resources: devframework://docs/instance_recovery",
			"schema": {"type": "object", "properties": {
				"project_path": {"type": "string", "description": "项目根目录绝对路径; 省略则用当前实例所属项目"},
				"scope": {"type": "string", "enum": ["exits", "full"], "description": "exits=只返回实例退出记录(不读日志/事件日志, 最快); full=默认, 追加 editor 日志尾部与 Windows 故障模块@偏移"},
				"log_lines": {"type": "integer", "description": "scope=full 时附带多少行 editor 日志尾部(默认 80)"},
			}},
			"handler": _handle_crash_report,
		},
	]


static func _handle_list_instances(args: Dictionary) -> Dictionary:
	return await _router.call_list_instances(args)


static func _handle_use_instance(args: Dictionary) -> Dictionary:
	return _router.call_use_instance(args)


## 拉起一个项目的编辑器。崩溃环保护等价 systemd 的 StartLimitBurst/IntervalSec:
## 一个必崩的库会被反复拉起, 而"刚崩过"本身就说明该先修而不是再拉。
static func _handle_launch_project(args: Dictionary) -> Dictionary:
	var raw := String(args.get("project_path", "")).strip_edges()
	if raw == "":
		return MCPResult.err_validation("project_path 不能为空", "传项目根目录的绝对路径(含 project.godot)")
	var path := raw.simplify_path()
	if not FileAccess.file_exists(path.path_join("project.godot")):
		return MCPResult.err_validation("不是 Godot 项目(缺 project.godot): %s" % path,
				"确认路径指向项目根目录(不是 addons/ 或子目录)")
	var prev: Dictionary = _hub.last_exit_for(path)
	var guard: Dictionary = _hub.crash_loop(path)
	if not bool(guard.get("allowed", true)) and not VariantTool.get_bool(args, "force", false):
		return MCPResult.err_validation(
				"拒绝拉起: %s\n%s" % [str(guard.get("hint", "")), str(prev)],
				"先修崩溃原因(用 crash_report 取证); 确实要强拉就传 force=true。")
	var wait_ms := VariantTool.get_int(args, "wait_ms", 0)
	var exe := OS.get_executable_path()
	var pid := OS.create_process(exe, PackedStringArray(["--editor", "--path", path]))
	if pid <= 0:
		return MCPResult.err_internal("无法启动编辑器进程: %s" % exe, "手动启动编辑器, 或检查 Godot 路径是否可执行")
	var t0 := Time.get_ticks_msec()
	var hit: Dictionary = {}
	if wait_ms > 0:
		while Time.get_ticks_msec() - t0 < wait_ms:
			for e in _hub.snapshot():
				if String(e.get("project_path", "")).simplify_path() == path:
					hit = e
					break
			if not hit.is_empty():
				break
			OS.delay_msec(400)
	var out := {
		"pid": pid,
		"exe": exe,
		"project_path": path,
		"registered": not hit.is_empty(),
		"waited_ms": Time.get_ticks_msec() - t0,
		"instance_id": str(hit.get("instance_id", "")),
		"uid": str(hit.get("uid", "")),
		"port": int(hit.get("port", 0)),
		"previous_exit": prev,
	}
	if prev.is_empty():
		out["hint"] = "没有该项目的离开记录(可能是首次启动, 或记录已滚出最近 8 条)。"
	elif bool(prev.get("clean", true)):
		out["hint"] = "上次是**正常退出**, 已重新启动。"
	else:
		out["hint"] = "上次是**非正常退出**(%s, 约 %d 秒前) —— 若反复崩溃请查 editor 日志: %s" % [
			str(prev.get("reason", "")), int(prev.get("ago_ms", 0)) / 1000, "user://logs/godot.log"]
	if not out["registered"]:
		out["next"] = "用 list_instances 轮询, 出现在列表里后再 use_instance 选定它(通常 3~6 秒)。"
	return MCPResult.ok_json(out)


## 崩溃取证。"同模块同偏移连续出现"是最有价值的信号: 说明上一个修复没生效。
## scope=exits 只列退出记录 —— 后两步要起 powershell 查 Get-WinEvent, 在"只想确认它是不是崩了"
## 的场景里纯属浪费。
static func _handle_crash_report(args: Dictionary) -> Dictionary:
	var proj := VariantTool.get_string(args, "project_path").strip_edges()
	if proj == "":
		proj = ProjectSettings.globalize_path("res://").simplify_path()
	proj = proj.simplify_path()
	var scope := VariantTool.get_string(args, "scope", "full").strip_edges()
	if scope.is_empty():
		scope = "full"
	if scope != "exits" and scope != "full":
		return MCPResult.err_validation("未知的 scope: '%s'" % scope, "scope 只能是 exits 或 full")
	var n_lines := maxi(10, VariantTool.get_int(args, "log_lines", 80))
	var mine: Array = []
	for e in _hub.exits_snapshot(20):
		if String(e.get("project_path", "")).simplify_path() == proj:
			mine.append(e)
	if scope == "exits":
		# 与 full 共用 exits/crashed_count 两个键, 只省掉昂贵部分 —— 调用方不必按 scope 改解析逻辑。
		return MCPResult.ok_json({
			"project_path": proj,
			"scope": "exits",
			"exits": mine,
			"crashed_count": mine.size(),
			"hint": "clean=false 的条目说明该实例没走正常注销(心跳超时被剔除) → 崩溃/被强杀。要日志尾部与 Windows 故障模块@偏移, 用 scope=full; 拉起用 launch_project。",
		})
	var evr: Dictionary = windows_crash_events_ex(5)
	var events: Array = evr.get("events", [])
	var sig := ""
	var same := false
	if events.size() >= 2:
		sig = "%s@%s" % [str(events[0].get("module", "")), str(events[0].get("offset", ""))]
		var sig2 := "%s@%s" % [str(events[1].get("module", "")), str(events[1].get("offset", ""))]
		same = sig != "@" and sig == sig2
	var log_file := project_log_path(proj)
	var out := {
		"project_path": proj,
		"exits": mine,
		"crashed_count": mine.size(),
		"log_file": log_file,
		"log_tail": tail_lines(log_file, n_lines),
		"windows_events": events,
		"windows_events_error": String(evr.get("error", "")),
		"fault_signature": sig,
		"same_fault": same,
	}
	if same:
		out["hint"] = "连续两次崩溃都在 **%s** —— 同一个崩溃点复发, 说明上次的修复没生效(先改代码, 别急着拉起)。" % sig
	elif not mine.is_empty():
		out["hint"] = "有 %d 次非正常退出; 可先看 windows_events 的 模块@偏移 定位。要恢复用 launch_project。" % mine.size()
	else:
		out["hint"] = "该项目没有非正常退出记录(可能是首次启动, 或记录已滚出)。"
	return MCPResult.ok_json(out)


## ======= 崩溃取证辅助 =======

## 项目 → editor 日志路径。user:// 按项目名隔离, 所以要从对方 project.godot 读 config/name。
static func project_log_path(proj: String) -> String:
	var name := proj.get_file()
	var cfg := proj.path_join("project.godot")
	if FileAccess.file_exists(cfg):
		var re := RegEx.new()
		re.compile("config/name=\"([^\"]*)\"")
		var m := re.search(FileAccess.get_file_as_string(cfg))
		if m != null:
			name = m.get_string(1)
	var base := OS.get_environment("APPDATA")
	if base.is_empty():
		base = OS.get_environment("XDG_DATA_HOME")
	if base.is_empty():
		return ""
	return base.path_join("Godot/app_userdata").path_join(name).path_join("logs/godot.log")


static func tail_lines(path: String, n: int) -> Array:
	if path == "" or not FileAccess.file_exists(path):
		return []
	var all := FileAccess.get_file_as_string(path).split("\n", false)
	return all.slice(maxi(0, all.size() - n))


## Windows 事件日志里的崩溃条目(最近 N 条)。只 Windows 有; 其它平台返回空数组。
static func windows_crash_events(limit: int) -> Array:
	return windows_crash_events_ex(limit).get("events", [])


## 同上, 但把失败原因也带出来 —— 取证工具不能"静默空结果", 那与"没有崩溃"无法区分。
## 整个 PowerShell 片段只用**单引号**: 经 OS.execute 转发时命令行里的双引号会被再解析一次。
static func windows_crash_events_ex(limit: int) -> Dictionary:
	if OS.get_name() != "Windows":
		return {"events": [], "error": "只有 Windows 有应用事件日志"}
	# 用 @@ 作分隔而不是换行: OS.execute 的输出可能把多条事件合进一个字符串, 按 \n split 会串行。
	var ps := ("Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddHours(-24)} " +
			"-MaxEvents %d -ErrorAction SilentlyContinue | ForEach-Object { " % limit +
			"'@@' + $_.TimeCreated.ToString('MM-dd HH:mm:ss') + ' ' + ($_.Message -replace '\\s+', ' ') }")
	for exe in PackedStringArray(["powershell", "pwsh"]):
		var out: Array = []
		var code := OS.execute(exe, PackedStringArray(["-NoProfile", "-NonInteractive", "-Command", ps]), out, true)
		var all := ""
		for line in out:
			all += String(line)
		var events: Array = _parse_crash_lines(all)
		if not events.is_empty():
			return {"events": events, "error": ""}
		if code == 0:
			return {"events": [], "error": "近 24 小时没有应用崩溃事件(或事件日志已滚动)"}
		var first := all.strip_edges()
		if first != "":
			return {"events": [], "error": "%s: %s" % [exe, first.substr(0, 200)]}
	return {"events": [], "error": "无法执行 powershell/pwsh"}


## 去掉十六进制的零填充: 0x000000000001ca42 → 0x1ca42(便于跨次比较"同一崩溃点")。
static func _norm_hex(h: String) -> String:
	if not h.begins_with("0x") and not h.begins_with("0X"):
		return h
	var digits := h.substr(2).lstrip("0")
	if digits == "":
		digits = "0"
	return "0x" + digits.to_lower()


## 解析 "@@时间 <消息>" 片段。模块取消息里**最后一个**库文件名(app 的 .exe 在前, 故障模块在后)。
## ⚠ 模式里不要出现中文: Godot 的 RegEx 对含全角字符的 pattern 会编译失败, 整条 search 恒为 null。
static func _parse_crash_lines(all: String) -> Array:
	var events: Array = []
	for chunk in all.split("@@"):
		var s := chunk.strip_edges()
		if s.length() < 8:
			continue
		var at := ""
		var m_at := RegEx.create_from_string("^(\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d)")
		var mm := m_at.search(s)
		if mm != null:
			at = mm.get_string(1)
		# 异常代码按 ASCII 形态认(0xc + 7 位十六进制), 不靠标签文本。
		var code := ""
		var after_code := 0
		var m_code := RegEx.create_from_string("0xc[0-9a-fA-F]{7}")
		var mc := m_code.search(s)
		if mc != null:
			code = mc.get_string(0)
			after_code = mc.get_end()
		# 偏移 = 异常代码**之后**的第一个十六进制(>=4 位): 消息顺序是
		#   Exception code | Fault offset | Faulting process id, 而 time stamp 在代码之前被位置条件排除。
		var offset := ""
		for mo in RegEx.create_from_string("0x[0-9a-fA-F]{4,}").search_all(s):
			if mo.get_start() >= after_code and mo.get_string(0) != code:
				offset = _norm_hex(mo.get_string(0))
				break
		var module := ""
		var matches := RegEx.create_from_string("([~A-Za-z0-9_.\\-]+\\.(?:dll|dylib|so))").search_all(s)
		if not matches.is_empty():
			module = matches[matches.size() - 1].get_string(1)
		if at == "" and module == "" and code == "":
			continue
		events.append({"at": at, "module": module, "offset": offset, "code": code})
	return events
