@tool
extends RefCounted

## 工具契约自检: 校验"工具注册表(定义)"与"handler 实现"两侧是否自洽。
##
## 从 MCPDevServer.gd 拆出。这一组只回答"定义与实现对不对得上", 与服务器的传输层、
## 协议层职责无关; 单独放才能在调整自检规则时不必去主服务器文件里翻找, 也避免了自检逻辑
## 与服务器的实例状态(端口/连接/会话)互相纠缠。
##
## 与 MCPResult / MCPToolSchema / MCPToolMeta 同族, 由 MCPDevServer 以 preload 常量
## `MCPToolAudit` 引用。**必须带 @tool 且不声明 class_name**, 理由同那几个文件: 一旦
## 声明成全局类, 本文件的改动就走不通"reload() 原地重编译 + refresh_tools 生效"这条链路,
## 而"改完自检规则立刻能看到新判定"正是本文件最主要的用法(见 MCPDevServer 顶部说明)。
const MCPToolMeta := preload("res://addons/DEVFramework/MCP/MCPToolMeta.gd")

## 本轮自检读到的源码缓存: 脚本路径 -> 源码文本。仅供入参一致性自检切片用, 每次自检重读一遍。
static var _source_cache := {}


## ======= 扫描范围: 为什么是整个目录, 而不是调用方给的一份名单 =======
##
## 判断"handler 究竟读了哪些入参"必须切出 handler 的函数体, 而 handler 分散在多个域文件里
## (MCPSceneTools / MCPValidateTools / ... ), 不是全在主服务器里。
##
## 原设计是调用方传一份路径名单进来。那份名单会**漏**, 而漏掉的形态是致命的: 名单里没有的
## 文件, 其 handler 一个都切不出函数体 → 入参一致性自检对那整批工具**静默跳过**, 且没有任何
## 迹象(不是报错, 是"永远通过")。换句话说, "维护一份要扫哪些文件的名单"这件事本身, 就是本文件
## 最想消灭的那类失败模式的来源 —— 拆分做得越碎, 名单越容易漏, 检查越名存实亡。
##
## 故改为从锚点脚本所在目录展开全量 .gd: 新增域文件自动纳入检查, 结构上不可能忘记登记。
## 代价只是每次自检多读几个文件, 而自检每次注册跑一次(会话内 1~2 次), 量级可忽略。

## 自检入口: 返回发现的问题列表(空 = 通过)。
## [param tool_defs] 工具定义列表(MCP 格式的 tools/list 条目)
## [param tool_handlers] 工具名 -> Callable
## [param anchor_script_path] 调用方自己的脚本路径, 仅用于定位"要扫哪个目录"。
##   本文件**不能**用 get_script().resource_path —— 那读到的是本文件自己, 一个 handler
##   函数体也切不出来, 自检会静默退化成"永远通过"(比不自检更糟)。
## [param audit_handlers] 可选: 工具名 -> "入参自检该切哪个 handler"。转发型工具注册进去的是
##   纯转发 lambda, 切它切不出函数体, 会被 audit_handler_params 记为检查缺失。调用方把同一工具的
##   具体实现登记在这里, 自检就切那份真正读入参的代码。缺项的工具仍按 _tool_handlers 走。
## [param registry_is_full] 本次 tool_defs 是否是**全量**工具表(默认 true)。游戏进程只注册运行时
##   那部分工具, 此时"名单里的编辑器工具没被注册"是分模式注册的正常结果, 不是名单未同步 ——
##   不跳过反向校验就会在每次游戏启动时刷出几十条误报, 而误报会让自检迅速被无视(见 MCPToolMeta.audit)。
static func audit_tools(tool_defs: Array, tool_handlers: Dictionary, anchor_script_path: String, audit_handlers: Dictionary = {}, registry_is_full: bool = true) -> Array[String]:
	var issues: Array[String] = []
	# 源码缓存必须每次自检重新读: 缓存的意义只是"一次自检内读一次"(几十个工具共用一份切片),
	# 跨自检复用会让刚改完的代码仍按旧文本判定 —— 那时报出的问题可能已经不存在, 比不报更糟。
	_load_sources(anchor_script_path)
	issues.append_array(MCPToolMeta.audit())
	issues.append_array(audit_tool_name_duplicates(tool_defs))
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
		if tool_handlers.has(tname):
			issues.append_array(audit_handler_params(tname, def.get("inputSchema", {}), audit_handlers.get(tname, tool_handlers[tname])))
	# 反向核对, 两项各自独立: 一项拿元数据名单查(名单写了却没注册), 一项拿源码查
	# (源码声明注册了却没进注册表)。都只在全量注册表下成立 —— 游戏进程只注册运行时那部分。
	if registry_is_full:
		issues.append_array(MCPToolMeta.audit_against(registered))
		issues.append_array(audit_declared_registrations(registered))
	return issues


## 展开待扫描的源码: 锚点所在目录下的全部 .gd。
static func _load_sources(anchor_script_path: String) -> void:
	_source_cache = {}
	var dir_path := anchor_script_path.get_base_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		# 目录都打不开(锚点路径写错/目录被移走): 什么都不扫 = 静默全通过, 是最坏结果,
		# 故把锚点本身塞进缓存(值为空串), 让 func_body 明确"查过、没找到"而非"没查"。
		_source_cache[anchor_script_path] = ""
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
	# 同名函数落在哪个文件里就成了随机的, 表现为"自检结果偶发地多一条少一条"。
	names.sort()
	for name in names:
		_source_cache[dir_path.path_join(name)] = FileAccess.get_file_as_string(dir_path.path_join(name))


## ======= 检查 B: 工具重名 =======
##
## 为什么要查: _add_tool 里 _tool_handlers / _tool_schemas 是 **Dictionary(覆盖)**,
## 而 _tool_defs 是 **Array(累积)**。同一个工具名注册两次, 不会有任何报错, 结果是
## tools/list 里出现**两个同名条目**, 而客户端按名取到的是后注册的那份 —— 症状是
## "AI 看到的 schema 和它实际调到的实现不是同一个"。这类错配在拆分(一个工具的 desc/schema
## 与 handler 分处两地)之后特别容易发生, 所以按事实核对一次。
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
##
## 要防的故障: 某个注册接缝漏调 —— 新增域忘了接线, 或重构时删掉了那行 `Xxx.register(_add_tool)`。
## 后果是那一域的工具**一个都没进注册表**, 而症状轻到几乎看不见: tools/list 安静地少掉几个
## 条目, 直到有人真的去调那个工具才撞上 Unknown tool —— 而"没人调"恰恰是漏调能长期活着的理由。
## MCPDevServer 顶部那份接缝表本身就是为这件事写的, 但注释挡不住漏调, 只能靠检查。
##
## 判据是**纯 grep 事实**(同 audit_cross_domain_calls 的取舍): 扫源码里的注册调用, 取出紧跟其后的
## 工具名字面量, 与本次注册表比对。刻意不维护任何"应注册名册" —— 名册必然漂移, 而漂移本身就把
## 检查变回"漏了没人知道"。
##
## 与 MCPToolMeta.audit_against 的分工(后者覆盖不到这一半, 这是本项存在的理由): audit_against
## 拿四张元数据名单(READ_ONLY/DESTRUCTIVE/SIDE_EFFECT/IDEMPOTENT, 合计 40 个)反向核对,
## 而编辑器侧实际注册 50 个 —— 名单外的工具漏注册, 它一个字都不会报。
##
## 两条边界, 必须留在注释里防止后来人把它当成更强的检查:
##   1. **只查漏注册, 不查"多注册"**。工具名允许来自变量: MCPDevServer 就用
##      `_shot_spec["name"]` 转发 take_screenshot(它的 desc/schema 要与 MCPScreenshotTools
##      共用单副本)。那种工具名在源码里**抓不到**, 若再做一次反向比对, 它会被报成"注册表里有
##      而源码里没有" —— 纯误报, 而误报会让自检迅速被无视。故反向无从查起。
##      代价: 新增工具若也用变量传名, 本项对它无效 —— 所以新工具请直接写字面量。
##   2. 只在全量注册表下调用(见 audit_tools 的 registry_is_full): 游戏进程只注册运行时那部分
##      工具, 此时编辑器侧工具全部"源码有、注册表无", 不跳过就会在每次游戏启动时刷几十条。
static func audit_declared_registrations(registered: Dictionary) -> Array[String]:
	var issues: Array[String] = []
	# 注册调用的三种书写形态(实测, 见 MCPDevServer 顶部"工具域文件"一段):
	#   _add_tool("x", ...)               主文件直接调
	#   _register_game_play_tool("x", ...) 主文件, 编辑器/游戏双模式
	#   add_tool.call("x", ...)            域文件, 服务器方法当 Callable 传进来
	# 三者共同点是"紧跟工具名的字符串字面量", 故一条正则覆盖。_add_tool 分支不会误吃
	# _register_game_play_tool(两者无 "_add_tool" 子串), 也不会误吃函数**定义**处(定义里
	# 第一个参数名是 name 而非字面量)。
	var re := RegEx.create_from_string("\\b(?:_add_tool|_register_game_play_tool|add_tool\\.call)\\(\\s*\"(\\w+)\"")
	for path in _source_cache:
		# 必须剥注释: MCPValidateTools 顶部就在注释里列着 `_add_tool("validate", ...)` 这种
		# "副本已删、grep 一下验收"的写法, 不剥会被当成真实注册点。
		var src := strip_comments(str(_source_cache[path]))
		for m in re.search_all(src):
			var tname := m.get_string(1)
			if not registered.has(tname):
				issues.append("工具 '%s' 在 %s 里声明注册, 却没进本次注册表 —— 该域注册入口漏调(如 Xxx.register 未被调用)。症状是 tools/list 安静地少掉它, 直到有人调它才撞上 Unknown tool" % [tname, path.get_file()])
	return issues


## ======= 检查 D: 跨域静态调用的目标必须存在 =======
##
## 本项是四类检查里**唯一**能抓到"改名做了一半"的: 那种故障的形态是主文件按新接口名写了
## 调用, 而域文件那一半没跟上(接口改名的中间态)。此时
##   · read_lints / get_script_method_list 全部零诊断 —— 被调用的类名解析正常, 只是它没有
##     那个方法, GDScript 的静态检查不报这种"跨脚本方法缺失";
##   · 只在 tools/call 真正执行到那一行时才炸 "Function not found", 表现为某一个工具
##     单独失效, 同批次其它工具全部正常。
## 真实一次: MCPDevServer 调 MCPScreenshotTools.capture_editor_side(), 而域文件里当时只有
## _call_take_screenshot —— 静态全绿, 运行时才炸。
##
## 因此本项检查的是**纯 grep 事实**(调用的名字在目标文件的顶层成员表里没有), 不含任何
## 对函数体形态或语义 的假设, 所以零误报。
##
## 两条边界, 必须写在这里防止后来人把它当成更强的检查:
##   1. **"目标存在"不等于"目标正确"**。若调用方与域文件同时把签名改了(参数个数/返回值类型),
##      名字仍在, 本项通过。这类问题留给 validate 与实跑覆盖 —— 把本项说成能防住签名漂移,
##      就是又一次"总在喊狼来了的检查"。
##   2. 目标类**不在本目录**时(外部全局类)一律跳过不报, 否则自检会依赖目录外的文件布局。
static func audit_cross_domain_calls() -> Array[String]:
	var issues: Array[String] = []
	# 类名(= 文件 basename) -> 该文件的顶层成员表。只有本目录里存在的才算域。
	var members := {}
	for path in _source_cache:
		members[path.get_file().get_basename()] = _top_level_members(_source_cache[path])
	var call_re := RegEx.create_from_string("\\b(MCP[A-Za-z]+)\\.(\\w+)\\s*\\(")
	for path in _source_cache:
		# 必须先剥注释: 注释里大量"写法示例"(如"域文件统一写作 MCPXxx.register(_add_tool)")
		# 会命中调用点正则, 不剥就是一批凭空报错。
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
## 这不是一份项目侧需要维护的名单, 而是 GDScript 内建成员集的一部分。
const _ENGINE_MEMBERS := ["new", "free"]


## 取某个脚本源码里的顶层成员名: func / const / var。
##
## const/var 也必须收: `MCPResult.for_protocol(...)` 这类引用若只查 func 就会被误报成
## "调用了不存在的方法"。只认行首, 缩进的一律排除(嵌套 func 与 lambda 都是缩进的)。
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
## 资源路径并不罕见), 按 '#' 砍会把那一行后面的代码整段丢掉, 于是真调用点被误删成假阴性。
## 故按字符扫描并跟踪引号状态, 只在字符串外遇到 '#' 时才丢弃到行尾。
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
## 重点是 required ⊆ properties: 客户端按 JSON Schema 校验时, required 引用了未声明的
## 属性会直接判整个请求非法, 而这种错误在编辑器里点一下工具就能看出来, 不该留给用户撞。
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
##
## 这是"schema 与实现失配"里**更致命**的一半: handler 读了一个 schema 没声明的键, AI 在
## tools/list 里就看不到它, 于是永远不会传, handler 拿默认值静默继续跑 —— 不报错、不崩,
## 只是结果不对(AI 以为做了筛选/指定了路径, 实际是全量或默认值)。
##
## 只报这一个方向。反方向"schema 声明了但 handler 没读"**刻意不报**: 预演参数(dry_run)
## 之类常常在 schema 里列出以引导 AI 使用, handler 的读取路径可能分散在分支甚至另一个
## handler 里(如 append_file 复用 write_file), 静态扫描判不准。一个总在喊狼来了的检查
## 等于没有检查 —— 所以宁可漏报, 不引入无法消除的误报。
static func audit_handler_params(tname: String, schema: Variant, handler: Callable) -> Array[String]:
	var issues: Array[String] = []
	if not schema is Dictionary:
		return issues
	var props: Variant = (schema as Dictionary).get("properties", {})
	if not props is Dictionary:
		return issues
	# 定位不到函数体 = 本项自检对这次注册**没有执行**。这里必须报出来, 不能静默返回空列表:
	# 静默返回会把"没查"记成"通过", 那比不自检更糟 —— 这批工具会永久退出检查范围, 而注册表
	# 看上去一切正常, 没有报错、没有告警、也没有任何可观测的迹象。
	#
	# 两个判据缺一不可, 且都实测过:
	#   · lambda: get_method() 返回的是**字面量字符串 "<anonymous lambda>"**, 不是空串。所以
	#     只判 is_empty() 会漏掉全部转发型工具 —— 那道守卫是死代码, 看着像在防这个, 实际从不命中。
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
##
## 按名字找而不是按"注册处"找: 工具名到文件位置的映射会随拆分漂移, 而函数名是稳定的。
static func func_body(method: String) -> String:
	for path in _source_cache:
		var body := _func_body_in(_source_cache[path], method)
		if not body.is_empty():
			return body
	return ""


## 从单个脚本源码里切出某个顶层函数的片段(func 行到下一个顶层 func 行之前)。
## 只认行首的 func —— 嵌套函数与 lambda 都带缩进, 天然被排除。
##
## **两种声明形式都必须认**: 拆到独立域文件里的 handler 写作 `static func`, 留在主服务器的
## 仍是非静态 `func`, 两种形态会长期共存。只认一种 → 另一种形态的 handler 一个都切不出
## 函数体 → 对应那批工具静默跳过本项自检, 且不报任何错。
##
## 同理, 结束边界必须把 `static func` 一并计入(见 _next_func_line): 切 static 函数时若只找
## "\nfunc ", 会把后面整个文件的几十个函数全当成函数体, 于是报出"工具 A 的 handler 读了
## 工具 B 的参数"这类凭空问题 —— 误报同样是"检查等于没有检查"。
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
	# 同文件里其他工具的参数全算到这一个头上, 报出一批"读了未声明参数"的凭空问题 —— 误报
	# 同样是"检查等于没有检查"(见 scan_arg_keys 末尾)。域文件里"第一个函数恰好是某个 handler"
	# 是很现实的布局, 所以这条分支的正确性不是可选的。
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
## args.get("k") / args["k"]; 匹配不到不代表没读(可能有间接转发), 故只在"读到但没声明"时报问题。
##
## 第一条模式**不能**加 `(?<![\w.])` 否定环视: 调用形态已变成 `VariantTool.get_string(`,
## 其前缀 `VariantTool.` 本身就足够特异, 加了反而会让它在 "." 处失配、导致整个自检
## 静默扫不到任何键 —— 那正是本函数当年失灵的形态(规则改了而正则没跟上, 检查变空转)。
##
## 而后两条的 `args` 前必须加否定环视, 已证明不是可有可无: verify_fix 里写的是
## `verify_args["prev_snapshot"]`(给它自己的局部字典赋值), 而朴素的 `args\["(\w+)"\]`
## 恰好命中这串的后半段, 于是把一个**局部变量名**误报成"未声明的入参"。正则不做词边界
## 就把这类噪声塞进自检, 而总在喊狼来了的检查等于没有检查。
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
