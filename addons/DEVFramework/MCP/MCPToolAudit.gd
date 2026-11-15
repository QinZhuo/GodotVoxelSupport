@tool
extends RefCounted

## 工具契约自检: 校验"工具注册表(定义)"与"handler 实现"两侧是否自洽。
## `MCPToolAudit` 引用。**必须带 @tool 且不声明 class_name**, 理由同那几个文件: 一旦
const MCPToolMeta := preload("res://addons/DEVFramework/MCP/MCPToolMeta.gd")

## 本轮自检读到的源码缓存: 脚本路径 -> 源码文本。仅供入参一致性自检切片用, 每次自检重读一遍。
static var _source_cache := {}

## 本轮源码是否可读。false = 读不到(导出包脚本是二进制 token, get_file_as_string 返回空) ——
## 误报成"切不出函数体"(实测导出运行时会刷出 20 条虚假告警)。那是"查不到", 不是"有问题"。
static var _sources_ok := true


## ======= 扫描范围: 为什么是整个目录, 而不是调用方给的一份名单 =======
## 判断"handler 究竟读了哪些入参"必须切出 handler 的函数体, 而 handler 分散在多个域文件里

## 自检入口: 返回发现的问题列表(空 = 通过)。
##   本文件**不能**用 get_script().resource_path —— 那读到的是本文件自己, 一个 handler
static func audit_tools(tool_defs: Array, tool_handlers: Dictionary, anchor_script_path: String, audit_handlers: Dictionary = {}, registry_is_full: bool = true, extra_scripts: Array = []) -> Array[String]:
	var issues: Array[String] = []
	# 源码缓存必须每次自检重新读: 缓存的意义只是"一次自检内读一次"(几十个工具共用一份切片),
	_load_sources(anchor_script_path, extra_scripts)
	issues.append_array(MCPToolMeta.audit())
	issues.append_array(audit_tool_name_duplicates(tool_defs))
	# 源码相关检查只在**能读到源码**时执行(见 _sources_ok): 导出包读不到源码, 子句若照跑会把每个
	if _sources_ok:
		issues.append_array(audit_cross_domain_calls())
	var registered := {}
	for def in tool_defs:
		var tname := str(def.get("name", ""))
		registered[tname] = true
		if str(def.get("description", "")).is_empty():
			issues.append("工具 '%s' 缺少 description" % tname)
		# handler 缺失: 注册了却调不通, 会在 tools/call 时才暴露为 Unknown tool
		if not tool_handlers.has(tname):
			issues.append("工具 '%s' 已进注册表但无对应 handler" % tname)
		issues.append_array(audit_input_schema(tname, def.get("inputSchema", {})))
		if tool_handlers.has(tname) and _sources_ok:
			issues.append_array(audit_handler_params(tname, def.get("inputSchema", {}), audit_handlers.get(tname, tool_handlers[tname])))
	# 反向核对, 两项各自独立: 一项拿元数据名单查(名单写了却没注册), 一项拿源码查
	if registry_is_full:
		issues.append_array(MCPToolMeta.audit_against(registered))
		if _sources_ok:
			issues.append_array(audit_declared_registrations(registered))
	return issues


## 展开待扫描的源码: 锚点所在目录下的全部 .gd, 外加项目侧 provider 脚本(在目录之外)。
static func _load_sources(anchor_script_path: String, extra_scripts: Array = []) -> void:
	_source_cache = {}
	var dir_path := anchor_script_path.get_base_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		# 目录都打不开(锚点路径写错/目录被移走): 什么都不扫 = 静默全通过, 是最坏结果,
		_source_cache[anchor_script_path] = ""
		_sources_ok = false
		return
	dir.list_dir_begin()
	var names: Array[String] = []
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.ends_with(".gd"):
			names.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	# 排序: DirAccess 的遍历顺序不保证稳定, 而 func_body 取"第一个命中的文件"。不排序时
	names.sort()
	for name in names:
		_source_cache[dir_path.path_join(name)] = FileAccess.get_file_as_string(dir_path.path_join(name))
	# provider 脚本: MCP 目录之外, 单独并入(func_body 全局按函数名搜, 与目录文件同等待遇)。
	for p in extra_scripts:
		var path := str(p)
		if not path.is_empty() and not _source_cache.has(path):
			_source_cache[path] = FileAccess.get_file_as_string(path)
	# 判定源码可读性: 锚点(主文件)内容为空即视为读不到 —— 导出包脚本是二进制 token,
	_sources_ok = not str(_source_cache.get(anchor_script_path, "")).is_empty()


## ======= 检查 B: 工具重名 =======
static func audit_tool_name_duplicates(tool_defs: Array) -> Array[String]:
	var issues: Array[String] = []
	var counts := {}
	for def in tool_defs:
		var tname := str(def.get("name", ""))
		if tname.is_empty():
			continue
		counts[tname] = int(counts.get(tname, 0)) + 1
	for tname in counts:
		if int(counts[tname]) > 1:
			issues.append("工具名 '%s' 在注册表里出现 %d 次 —— _tool_defs 是 Array(累积)不去重, 客户端按名取到的是最后一份, 与前面的条目静默错配" % [tname, int(counts[tname])])
	return issues


## ======= 检查 E: 源码里声明注册了, 就必须真的进了注册表(漏注册检测) =======
## 两条边界, 必须留在注释里防止后来人把它当成更强的检查:
static func audit_declared_registrations(registered: Dictionary) -> Array[String]:
	var issues: Array[String] = []
	# 注册调用的三种书写形态(实测, 见 MCPDevServer 顶部"工具域文件"一段):
	var re := RegEx.create_from_string("\\b(?:_add_tool|_register_game_play_tool|add_tool\\.call)\\(\\s*\"(\\w+)\"")
	for path in _source_cache:
		# 必须剥注释: MCPValidateTools 顶部就在注释里列着 `_add_tool("validate", ...)` 这种
		var src := strip_comments(str(_source_cache[path]))
		for m in re.search_all(src):
			var tname := m.get_string(1)
			if not registered.has(tname):
				issues.append("工具 '%s' 在 %s 里声明注册, 却没进本次注册表 —— 该域注册入口漏调(如 Xxx.register 未被调用)。症状是 tools/list 安静地少掉它, 直到有人调它才撞上 Unknown tool" % [tname, path.get_file()])
	return issues


## ======= 检查 D: 跨域静态调用的目标必须存在 =======
## 本项是四类检查里**唯一**能抓到"改名做了一半"的: 那种故障的形态是主文件按新接口名写了
##   · read_lints / get_script_method_list 全部零诊断 —— 被调用的类名解析正常, 只是它没有
##   · 只在 tools/call 真正执行到那一行时才炸 "Function not found", 表现为某一个工具
## 两条边界, 必须写在这里防止后来人把它当成更强的检查:
static func audit_cross_domain_calls() -> Array[String]:
	var issues: Array[String] = []
	# 类名(= 文件 basename) -> 该文件的顶层成员表。只有本目录里存在的才算域。
	var members := {}
	for path in _source_cache:
		members[path.get_file().get_basename()] = _top_level_members(_source_cache[path])
	var call_re := RegEx.create_from_string("\\b(MCP[A-Za-z]+)\\.(\\w+)\\s*\\(")
	for path in _source_cache:
		# 必须先剥注释: 注释里大量"写法示例"(如"域文件统一写作 MCPXxx.register(_add_tool)")
		var src := strip_comments(str(_source_cache[path]))
		for m in call_re.search_all(src):
			var cls := m.get_string(1)
			var member := m.get_string(2)
			if not members.has(cls):
				continue
			if (members[cls] as Array).has(member) or _ENGINE_MEMBERS.has(member):
				continue
			issues.append("%s:%d 调用 %s.%s(), 但 %s.gd 顶层没有这个名字 —— 静态检查零诊断, 只在运行时炸。域文件接口改名后忘了同步调用点就是这个形态" % [
				path.get_file(), _line_of(src, m.get_start()), cls, member, cls])
	return issues


## 由语言本身提供、不在任何脚本源码里的成员。`X.new()` 是**实例化**(要求 X 有构造能力),
## 不是"调用 X 的某个静态方法" —— 离线核对时它是被本项检查报出来的**唯一一处**误报。
const _ENGINE_MEMBERS := ["new", "free"]


## 取某个脚本源码里的顶层成员名: func / const / var。
## const/var 也必须收: `MCPResult.for_protocol(...)` 这类引用若只查 func 就会被误报成
static func _top_level_members(src: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string("^(static\\s+)?(func|const|var)\\s+(\\w+)")
	for line in src.split("\n"):
		var m := re.search(line)
		if m:
			out.append(m.get_string(3))
	return out


## 把字符下标换算成 1 起的行号, 只为让自检报错能直接定位。
static func _line_of(src: String, at: int) -> int:
	return src.substr(0, at).count("\n") + 1


## 剥掉注释, 只留代码。**不是**简单按 '#' 截断 —— 字符串里可以合法含 '#'("res://a#b" 这类
static func strip_comments(src: String) -> String:
	var out := PackedStringArray()
	var quote := ""
	var i := 0
	while i < src.length():
		var c := src[i]
		if not quote.is_empty():
			out.append(c)
			if c == "\\" and i + 1 < src.length():
				out.append(src[i + 1])
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if c == "#":
			while i < src.length() and src[i] != "\n":
				i += 1
			continue
		if c == "\"" or c == "'":
			quote = c
		out.append(c)
		i += 1
	return "".join(out)


## 校验单个工具的入参 schema 是否自洽。返回问题描述数组。
static func audit_input_schema(tname: String, schema: Variant) -> Array[String]:
	var issues: Array[String] = []
	if not schema is Dictionary:
		return ["工具 '%s' 的 inputSchema 不是对象" % tname]
	var s: Dictionary = schema
	if str(s.get("type", "")) != "object":
		issues.append("工具 '%s' 的 inputSchema.type 不是 object" % tname)
	var props: Variant = s.get("properties", {})
	if not props is Dictionary:
		return issues + ["工具 '%s' 的 inputSchema.properties 不是对象" % tname]
	var required: Variant = s.get("required", [])
	if required is Array:
		for r in required:
			if not props.has(r):
				issues.append("工具 '%s' 的 required 含未声明的属性 '%s'" % [tname, str(r)])
	return issues


## 校验 handler 真正读取的入参是否都在 schema 里声明。
static func audit_handler_params(tname: String, schema: Variant, handler: Callable) -> Array[String]:
	var issues: Array[String] = []
	if not schema is Dictionary:
		return issues
	var props: Variant = (schema as Dictionary).get("properties", {})
	if not props is Dictionary:
		return issues
	# 定位不到函数体 = 本项自检对这次注册**没有执行**。这里必须报出来, 不能静默返回空列表:
	# 两个判据缺一不可, 且都实测过:
	#   · lambda: get_method() 返回的是**字面量字符串 "<anonymous lambda>"**, 不是空串。所以
	#   · 具名但切不出: 函数存在却在已加载源码里找不到(被删/改名/未落盘), 同样等于没查。
	var method := String(handler.get_method())
	if method.is_empty() or method == "<anonymous lambda>":
		return ["工具 '%s' 的 handler 是转发 lambda(方法名 '%s'), 入参一致性自检未执行 —— 检查缺失必须报出, 不能记作通过。请在 MCPDevServer._register_game_play_tool 里把它登记进 _tool_audit_handlers" % [tname, method]]
	var body := func_body(method)
	if body.is_empty():
		return ["工具 '%s' 的 handler %s() 在已加载源码里切不出函数体(被删/改名/未落盘?), 入参一致性自检未执行 —— 检查缺失必须报出, 不能记作通过" % [tname, method]]
	for key in scan_arg_keys(body):
		if not props.has(key):
			issues.append("工具 '%s' 的 handler %s() 读取了 schema 未声明的参数 '%s' —— AI 在 tools/list 里看不到它, 永远传不进来" % [tname, method, key])
	return issues


## 在全部已加载的源文件里切出某个顶层函数的片段, 返回第一个命中的。
static func func_body(method: String) -> String:
	for path in _source_cache:
		var body := _func_body_in(_source_cache[path], method)
		if not body.is_empty():
			return body
	return ""


## 从单个脚本源码里切出某个顶层函数的片段(func 行到下一个顶层 func 行之前)。
## **两种声明形式都必须认**: 拆到独立域文件里的 handler 写作 `static func`, 留在主服务器的
## 同理, 结束边界必须把 `static func` 一并计入(见 _next_func_line): 切 static 函数时若只找
static func _func_body_in(src: String, method: String) -> String:
	for decl in ["\nstatic func %s(", "\nfunc %s("]:
		var start := src.find(decl % method)
		if start < 0:
			continue
		var rest := src.substr(start + 1)
		var end := _next_func_line(rest)
		return rest.substr(0, end) if end >= 0 else rest
	# 目标函数是文件里的第一个函数(声明前没有换行, 上面两轮都匹配不到)。
	# 注意必须仍然切到**下一个**函数为止, 不能直接返回整个文件: 整个文件交给入参扫描会把
	for decl in ["static func %s(", "func %s("]:
		if src.begins_with(decl % method):
			var end := _next_func_line(src)
			return src.substr(0, end) if end >= 0 else src
	return ""


## 下一个顶层函数的首行下标(返回它前面那个换行的位置), 没有则 -1。
static func _next_func_line(body: String) -> int:
	var a := body.find("\nfunc ")
	var b := body.find("\nstatic func ")
	if a < 0:
		return b
	if b < 0:
		return a
	return mini(a, b)


## 扫出函数体里读取的所有入参键。覆盖统一入口 VariantTool.get_*(args, "k") 与遗留的
## 第一条模式**不能**加 `(?<![\w.])` 否定环视: 调用形态已变成 `VariantTool.get_string(`,
## 而后两条的 `args` 前必须加否定环视: 局部字典若恰好以 `args` 结尾(如 `verify_args["k"]`),
static func scan_arg_keys(body: String) -> Array[String]:
	var out: Array[String] = []
	for pattern in [
		"VariantTool\\.get_\\w+\\(\\s*args\\s*,\\s*\"(\\w+)\"",
		"(?<![\\w.])args\\.get\\(\\s*\"(\\w+)\"",
		"(?<![\\w.])args\\[\\s*\"(\\w+)\"\\s*\\]",
	]:
		for m in RegEx.create_from_string(pattern).search_all(body):
			var key := m.get_string(1)
			if not out.has(key):
				out.append(key)
	return out
