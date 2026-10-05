@tool
extends RefCounted

## ======= 脚本新鲜度: 让 eval 一定跑在最新代码上 =======
##
## 由 MCPDevServer 以 preload 常量 `MCPScriptSync` 引用。
## **本文件必须带 @tool**, 且不声明 class_name, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
##
## 要解决的问题: 引擎在进程启动时把 .gd 固化进内存, 之后外部改文件**不会**热重载。
## MCP 有两个 eval 入口, 分别落在两个进程里, 撞的是同一个陷阱:
##   eval_code  → 编辑器进程
##   game_eval  → 游戏进程
## 任一侧拿到的都可能��"改了没生效"当成"代码写错了", 得出相反结论。
##
## 能自动做到什么(实测):
##   ResourceLoader.CACHE_MODE_REPLACE 能让**脚本缓存**立即换成磁盘版本,
##   之后 eval 里 new() 出来的对象就是新代码。
##   (顺带结论: fs.scan() 只重新导入文件系统, **不**替换内存里已加载的
##    GDScript, 所以编辑器侧必须用 CACHE_MODE_REPLACE, scan 只是补充。)
##
## 做不到什么(引擎能力边界, 非本实现的取舍):
##   场景树里**已经存在**的实例, 其类型在创建时就固定了, 无法热替换。
##   引擎没有提供任何 API 能改写既有实例的脚本版本。
##
## 因此判据分两级, 且这是充要的 —— 不再像早期实现那样"任何 .gd 改动就拒绝":
##   第 1 级 磁盘改动 → 重载缓存 → eval 中 new 的对象是新的        → 放行
##   第 2 级 被改动脚本在场景树中已有实例 → 那些实例仍是旧代码    → 拒绝
## 第 2 级由游戏侧判��(只有游戏进程能遍历自己的场景树), 但它可以精确指出
## "哪个类的哪些节点仍是旧代码", 而不是笼统地说"重启游戏吧"。

## 模式标识(与 MCPDevServer.MODE_* 对齐; 放在本模块以避免反向依赖)
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## 编辑器侧 mtime 初筛基准(上次同步时刻)。用于避免每次 eval 都对 600+ 个
## .gd 做全量读盘哈希比对 —— stat 全量仅数毫秒, 读盘哈希则是另一个量级。
static var _editor_baseline: int = 0


## eval 执行前的新鲜度守卫。两个 eval 入口都应先过这里, 这是唯一的判定点。
##
## 返回 {ok: bool, message: String, retryable: bool, recovery: String,
##       reloaded: Array[String]}
##   ok=false 时 message/retryable/recovery 直接交给响应封装
##   reloaded 是本次热重载的脚本(仅 ok=true 时有值), 用于告知调用方结果可信
##
## 注意: 本函数是协程(内部 await 重扫), 调用方必须 await, 否则拿到的是未完成的
## 状态对象而不是结果。
static func guard_eval(mode: String, baseline: int, tree: SceneTree = null) -> Dictionary:
	if mode == MODE_EDITOR:
		return await _guard_editor()
	return _guard_runtime(baseline, tree)


## ======= 不可热重载的脚本: 重载它等于关掉自己 =======
##
## 故障形态: 被改动的 .gd 里混着一个承载长驻资源的脚本 —— MCPDevServer 正持有 HTTP 服务器。
## 原地重载它会终止那个服务器, 端口不再监听; 而这之后**所有** MCP 工具都调不到, 包括本可用来
## 救场的 restart_editor 与 refresh_tools。只能由用户去编辑器里手动重启。
## 换句话说: 一次 eval 把整条 MCP 通道永久关掉, 且失败形态是**静默失联**(日志里没有任何报错)。
##
## 为何用注册表而不是硬编码文件名: 判据是"重载它等于关掉自己"这个**性质**, 不是某个具体文件。
## 框架不该知道自己的哪个文件承载服务器 —— 承载者自己知道, 所以由它在 _ready 里登记自己。
static var _unreloadable := {}


## 登记一个不能被热重载的脚本; 同一路径重复登记以最后一次为准。
static func register_unreloadable(path: String, reason: String) -> void:
	if not path.is_empty():
		_unreloadable[path] = reason


## 该脚本是否被登记为不可重载: 是则返回原因, 否则返回空串。
static func unreloadable_reason(path: String) -> String:
	return str(_unreloadable.get(path, ""))


## ----- 编辑器进程 -----
## 判据用**内容哈希**(磁盘 vs ResourceLoader 缓存)而非 mtime: 编辑器会自己改
## 写 .import 等衍生文件, mtime 不可靠; 且哈希比较零漏报, 误报可被下一次
## 自动重载消化(不会挡住调用方)。
static func _guard_editor() -> Dictionary:
	var stale := changed_by_content()
	if stale.is_empty():
		return _pass([])
	# 不可热重载的脚本先分流出去, 且这一类**一个都不重载** —— 半重载比什么都不做更难判断。
	# 刻意显式阻止而非静默跳过: 跳过后跑的是旧代码, 而 tools/list 与契约自检看上去一切正常,
	# 调用方会把旧代码的结果当成新的继续往下改(连 schema_fingerprint 都不会变)。
	var blocked: Array[String] = []
	for p in stale:
		if _unreloadable.has(p):
			blocked.append(p)
	if not blocked.is_empty():
		var lines := PackedStringArray()
		for p in blocked:
			lines.append("  %s —— %s" % [p, str(_unreloadable[p])])
		return {
			"ok": false,
			# 归 stale_code 而非 validation: 跑不动的原因是"跑的是旧代码",
			# 而"该做什么"是重启而不是改代码。
			"category": "stale_code",
			"message": "这些脚本承载长驻服务, 不能热重载(重载会终止该服务, 且之后所有 MCP 工具都调不到, 无法自救), 已阻止执行:\n%s"
				% "\n".join(lines),
			"retryable": false,
			"recovery": "调用 restart_editor 重启编辑器(插件自启会自动恢复 MCP 连接); 或在插件面板禁用再启用 DEVFramework。",
			"reloaded": [] as Array[String],
		}
	# 丢弃缓存并从磁盘重新加载。加载失败通常意味着磁盘版本有语法错误,
	# 此时不该执行 —— 否则会拿到一份半坏的脚本, 报错信息还指向 eval 内部。
	var failed: Array[String] = []
	for p in stale:
		if not (ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE) is GDScript):
			failed.append(p)
	# scan 让文件系统补齐全局类缓存(新增的 class_name 要靠它才能被解析)。
	# 它不负责替换已加载脚本, 但缺了它新建的全局类会解析失败。
	_rescan_fs()
	if failed.is_empty():
		return _pass(stale)
	return {
		"ok": false,
		# 编辑器侧的失败含义与游戏侧不同: 这里是"磁盘版本自身有问题"(语法错),
		# 而非"跑的是旧代码", 故归 validation —— 归到 stale_code 会误导调用方
		# 去重启编辑器, 而真正该做的是改代码。
		"category": "validation",
		"message": "这些脚本改动后无法重新加载(通常是磁盘版本存在语法错误), 已阻止执行:\n%s"
			% "\n".join(PackedStringArray(failed)),
		"retryable": false,
		"recovery": "修正这些脚本的语法错误后重新调用 eval。",
		"reloaded": [] as Array[String],
	}


## ----- 游戏进程 -----
## baseline: 本次游戏会话的"脚本就绪时刻"(unix 秒)。
## 游戏侧拿不到编辑器那种内容哈希判据的成本优势(600+ 次读盘会卡主循环),
## 但 mtime 判据在这里是充要的: mtime 晚于就绪时刻 ⇒ 该脚本必在加载之后才被改
## ⇒ 游戏内必是旧代码。唯一理论漏报窗口是"加载 → 就绪"之间的同秒修改。
static func _guard_runtime(baseline: int, tree: SceneTree) -> Dictionary:
	# 游戏未就绪时无判据可用(也不该有 eval 请求到达)
	if baseline <= 0:
		return _pass([])
	var changed := changed_by_mtime(baseline)
	if changed.is_empty():
		return _pass([])
	# 关键顺序: 先抓住"旧脚本对象"再重载。重载后 ResourceLoader 里已是新版,
	# 拿不到旧对象就无从判断场景树里的实例是不是旧代码。
	# has_cached 为 false = 该脚本从未在本进程加载过 ⇒ 不可能有既有实例 ⇒ 不阻塞。
	var old_scripts: Dictionary = {}  # path -> 旧脚本对象
	for p in changed:
		if ResourceLoader.has_cached(p):
			var cached: Resource = ResourceLoader.load(p)  # 命中缓存, 不重新读盘
			if cached != null:
				old_scripts[p] = cached
	for p in changed:
		ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REPLACE)
	# 第 2 级判据: 按脚本对象比对(而非 class_name), 这样没有 class_name、
	# 仅被场景引用的脚本同样能查出既有实例。
	var live := live_instances(tree, old_scripts)
	# 第 3 级: 全局类(class_name)的引用也切不过来。
	#
	# 实测(游戏进程): ResourceLoader.CACHE_MODE_REPLACE 确实换掉了脚本缓存,
	# 但 eval 里 AsyncScope.new() 仍执行旧代码 —— 全局类的解析结果来自进程级的
	# 全局类表, 不随 ResourceLoader 缓存更新而刷新。编辑器侧之所以能切换, 是因为
	# 它额外调了 fs.scan(), 而全局类表由编辑器文件系统维护; 游戏进程没有
	# EditorInterface, 无法触发这次刷新。故这是引擎架构差异, 不是顺序问题。
	#
	# 这条必须实测判定而非假设: 若把"没修好"当成"已修复"放行, 闸门就退化成
	# 静默返回旧代码 —— 那正是本模块要消灭的失败模式。
	var stuck := stuck_globals(changed)
	if live.is_empty() and stuck.is_empty():
		return _pass(changed)
	return {
		"ok": false,
		"category": "stale_code",
		"message": _describe_block(live, stuck),
		"retryable": true,
		"recovery": "调用 game_control(action=start) 重启游戏(会自动停止旧实例)后重试。",
		"reloaded": [] as Array[String],
	}


## 改动过的脚本里, 属于全局类(class_name)的那些 —— 它们在游戏进程内无法热替换。
static func stuck_globals(changed: Array[String]) -> Array[String]:
	if changed.is_empty():
		return [] as Array[String]
	var globals: Dictionary = {}  # path -> class_name
	for c in ProjectSettings.get_global_class_list():
		globals[str(c.get("path", ""))] = str(c.get("class", ""))
	var out: Array[String] = []
	for p in changed:
		if globals.has(p):
			out.append(p)
	return out


## 找出 scripts 中每个脚本在场景树里仍存活的实例(热重载后即"旧代码"实例)。
## 返回 {path: [节点路径, ...]}
##
## 比对依据是脚本对象引用而非 class_name: 热重载保留 class_name 但会换掉脚本对象,
## 所以正在跑旧代码的实例其 get_script() 仍等于重载**前**的那个对象 —— 正是这里要的。
static func live_instances(tree: SceneTree, scripts: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if tree == null or tree.root == null or scripts.is_empty():
		return out
	# 反查表: 脚本对象 -> 路径。避免每个脚本各遍历一次场景树(节点常有数千个)
	var by_object: Dictionary = {}
	for p in scripts:
		by_object[scripts[p]] = p
	for n in tree.root.find_children("*", "", true, false):
		if not is_instance_valid(n):
			continue
		var s: Variant = n.get_script()
		if s == null or not by_object.has(s):
			continue
		var owner_path := str(by_object[s])
		if not out.has(owner_path):
			out[owner_path] = [] as Array[String]
		out[owner_path].append("/root/" + str(tree.root.get_path_to(n)))
	return out


## 阻塞原因分两类, 分开陈述才能让人知道"该重启"还是"该改代码"。
##   实例类: 场景里已有这些脚本的节点, 引擎不允许热替换实例类型
##   全局类: 引用解析不随缓存刷新, 只能靠重启刷新全局类表
static func _describe_block(live: Dictionary, stuck: Array[String]) -> String:
	var parts := PackedStringArray()
	if not live.is_empty():
		var lines := PackedStringArray()
		for p in live:
			var nodes: Array = live[p]
			var shown := nodes.slice(0, 3)
			lines.append("  %s —— %d 个实例仍是旧代码: %s%s" % [
				p, nodes.size(), ", ".join(PackedStringArray(shown)),
				" 等" if nodes.size() > shown.size() else "",
			])
		parts.append("既有实例无法热替换(引擎限制: 实例类型在创建时固定):\n%s" % "\n".join(lines))
	if not stuck.is_empty():
		var lines := PackedStringArray()
		for p in stuck:
			lines.append("  %s (%s)" % [p, _global_class_name(p)])
		parts.append("全局类引用不会随脚本缓存刷新(游戏进程无 EditorInterface, 刷不了全局类表):\n%s"
			% "\n".join(lines))
	return "已尝试热重载, 但以下改动在运行中的游戏内无法生效, 已阻止执行:\n%s" % "\n\n".join(parts)


static func _global_class_name(path: String) -> String:
	for c in ProjectSettings.get_global_class_list():
		if str(c.get("path", "")) == path:
			return str(c.get("class", ""))
	return "?"


static func _pass(reloaded: Array) -> Dictionary:
	return {
		"ok": true, "message": "", "retryable": false, "recovery": "",
		"reloaded": reloaded,
	}


## ----- 判据: 磁盘内容 vs 已加载内容(编辑器侧) -----
## 返回"内容确有差异"的脚本, 并顺带把基准推到最新。
static func changed_by_content() -> Array[String]:
	var out: Array[String] = []
	var touched := changed_by_mtime(_editor_baseline)
	for p in touched:
		if script_status_of(p).get("state", "") == "changed":
			out.append(p)
	# 无论内容是否变化都推进基准: mtime 变但内容未变(改完又改回/仅触碰)
	# 不该反复触发读盘比对
	_editor_baseline = int(Time.get_unix_time_from_system())
	return out


## 单个脚本的加载状态。script_status 工具的判据也走这里, 保证只有一处实现。
## state: missing / not_loaded / not_script / changed / in_sync
static func script_status_of(path: String) -> Dictionary:
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return {"state": "missing", "path": path}
	# 磁盘侧哈希: 读原始文本。已加载侧取 GDScript.source_code, 与磁盘同源可比。
	var disk := FileAccess.get_file_as_string(path)
	var disk_hash := int(disk.hash())
	if not ResourceLoader.has_cached(path):
		return {"state": "not_loaded", "path": path, "disk_hash": disk_hash}
	var res: Resource = ResourceLoader.load(path)
	if not (res is GDScript):
		return {"state": "not_script", "path": path, "disk_hash": disk_hash}
	var loaded_hash := int(str(res.source_code).hash())
	return {
		"state": "in_sync" if loaded_hash == disk_hash else "changed",
		"path": path,
		"disk_hash": disk_hash,
		"loaded_hash": loaded_hash,
	}


## 把 uid:// 或裸路径统一解析为可直接使用的 res:// 路径; 解析不出来返回空串。
##
## 为什么要多这一步: 项目主场景常配置为 uid://, 而编辑器重启后 .godot/uid_cache.bin
## 尚未重建, 此时 ResourceUID.uid_to_path() 直接失败。于是"restart_editor 之后的
## 第一次 game_control(action=start)"必然报错 —— 而那恰好是"改完代码 → 重载 → 验证"
## 这条最高频链路的第一个动作, 报错却发生在与代码无关的地方, 白白打断一次验证。
## 实测: 手动 fs.scan() 后即恢复, 故这里按需补一次重扫并重试(复用本模块同一入口)。
##
## 非 uid 形式只补全 res:// 前缀, 不做存在性校验 —— 校验语义属于调用方。
static func resolve_scene_path(ref: String) -> String:
	var s := ref.strip_edges()
	if s.is_empty():
		return ""
	if not s.begins_with("uid://"):
		return s if s.begins_with("res://") else "res://" + s
	var resolved := ResourceUID.uid_to_path(s)
	if resolved.is_empty() or not resolved.begins_with("res://"):
		# UID 缓存未就绪(典型: 编辑器刚重启), 重建后再试一次
		await _rescan_fs()
		resolved = ResourceUID.uid_to_path(s)
	return resolved if resolved.begins_with("res://") else ""


## ----- 判据: 磁盘 mtime(游戏侧) -----
static func changed_by_mtime(since: int) -> Array[String]:
	var out: Array[String] = []
	if since <= 0:
		return out
	_collect_gd("res://", out, since)
	return out


## 递归收集 mtime 晚于 since 的 .gd
##
## 只按名字跳过点目录: 本项目的隐藏目录均为点开头(.godot/.import/.git),
## 且不依赖 current_is_hidden —— 该方法在本引擎版本不可用, 调用它会让整次
## 扫描抛错, 把一个性能优化变成可用性事故。
static func _collect_gd(dir_path: String, out: Array[String], since: int) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect_gd(dir_path.path_join(entry), out, since)
		elif entry.ends_with(".gd"):
			var p := dir_path.path_join(entry)
			if FileAccess.get_modified_time(p) > since:
				out.append(p)
		entry = dir.get_next()
	dir.list_dir_end()


## 触发编辑器资源重扫并等待完成(最多 5s)。让文件系统补齐全局类缓存。
## static 上下文没有 get_tree(), 故经 Engine 取主循环; 且调用链上的函数都随之变成协程。
static func _rescan_fs() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	fs.scan()
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	var deadline := Time.get_ticks_msec() + 5000
	while fs.is_scanning() and Time.get_ticks_msec() < deadline:
		await loop.process_frame