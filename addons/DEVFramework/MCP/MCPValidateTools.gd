@tool
extends RefCounted

## ======= 脚本/资源校验域 =======
##
## 从 MCPDevServer 拆出的工具域文件, 沿 MCPCodeIndex 的样板。收录"不信任声明、要实测"这一类能力:
##   - validate        统一验证入口(kind=script 编译校验 / kind=resource 资源可加载性)
##   - classdb_query   查 Godot 原生类 API(写脚本前确认方法/属性/信号签名)
## 两者放一个域是因为取向相同: validate 把待验代码真编译一遍看引擎怎么说, classdb_query 把类
## 成员真列一遍而不是靠记忆。
##
## ## 依赖方向: 严格单向
##
## 本文件**不引用** MCPDevServer, 也不持有任何服务器状态。只依赖:
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - VariantTool    全局 class_name, 入参读取
##   - MCPLogger      全局 class_name, 编译错误捕获(仅本域自用, 见"编译错误从哪来"一节)
## 注册靠"把 _add_tool 当 Callable 传进来"完成, 所以连服务器的类型都不需要认识。
##
## ## 为什么 handler 一律 static
##
## 1. MCPToolAudit 的入参一致性自检靠 handler.get_method() 拿函数名、再去源码里切函数体。
##    静态函数取到的 get_method() 同样返回函数名(实测 "GDScript::_handle_xxx"), 自检照常工作;
##    而若改用 lambda 注册, get_method() 返回空串, 那批工具会**静默跳过**入参自检 ——
##    正是这个自检文件开头警告的"比不自检更糟"的失效模式。
## 2. 本域实现体对实例状态零依赖(唯一例外已在文件内就地解决, 见下节), 静态化不损失任何东西。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 本域私有的编译错误捕获器。**刻意不共用 MCPDevServer 的那个**, 理由见下方"编译错误从哪来";
## 引擎里因此有两个 Logger 各自的**安全性依据**(不会互相抢日志、且都不许删)写在
## _compile_error_log() 的注释里 —— 嫌"看着像重复注册"而去动它的人请先读那段。
static var _compile_log: MCPLogger = null


## ======= 编译错误从哪来: 为什么本域自建一个 MCPLogger =======
##
## **接缝判据(全局统一, 不是本域的偏好)**: 接缝可以存在, 但漏调必须可见; 漏调会静默失效的
## 场合一律不许用接缝。(同源表述另存于 MCPLogTools.bind_logger 注释, 全框架各域各留一份。)
##
## 本域有两处接缝, 按判据给出**不同**答案, 且都正确 —— 不要为了"看起来统一"去改其中任何一处:
##   - 编译错误捕获器 → 域内自建: 漏调后果是编译错误捕获不到、validate 恒返回 valid=true,
##     **静默失效**(把编译失败的代码报成合法), 故必须否决接缝。
##   - register(add_tool) → 保留接缝: 漏调后果是工具不进 _tool_handlers, 调用时协议层直接返回
##     JSON-RPC 错误 "Unknown tool", **显式报错**, 满足判据前半句。见 register() 的注释。
##
## 校验脚本要能**说出哪里错**, 而 GDScript 编译错误没有结构化返回值: reload() 只回 Error 码,
## 具体错误文本走引擎的 OS 日志广播。原实现靠服务器持有的 MCPLogger 取"reload 期间新增的
## 错误条目", 但那是 MCPDevServer 的**实例字段**, 域文件既不能引用服务器也不能持有服务器状态。
## 留在主文件的后果是 validate 的注册/schema/分派/错误过滤被劈成两半, "域是自足的"当场破掉 ——
## 而那正是本轮拆分的全部意义。故在本域内自建捕获器, 保持依赖单向。

## 取本域私有的编译错误捕获器(首次调用时创建并注册到 OS)。
##
## **删之前必读: 引擎里同时存在两个 Logger 是有意为之, 不是重复注册。** 依据有两条:
## 1. MCPLogger 的读取接口是**非破坏性的逻辑游标读** ——
##    · get_error_cursor() 只取本实例环形缓冲 `_errors` 的写指针, 不动缓冲内容;
##    · take_errors_since(since) 只按"下标 >= since"读**一段区间**, 不删除数组元素;
##      环形缓冲头部丢弃是靠 `_err_base_index` 游标补偿的, 不是靠真的丢元素;
##    · 唯一的破坏性路径是 clear_errors(), 本编译路径**没有**调用它。
## 2. 每个 MCPLogger 实例持有**自己的** `_errors` 缓冲, 实例之间不共享。
## 于是本域这个额外实例不会让 MCPDevServer 少读到任何一条错误(get_logs / get_errors /
## _safe_call_handler 的运行期诊断全部照旧), 反过来也不影响本域 —— 两个方向都互不干扰。
##
## **因此不要因为看起来"重复注册"就删掉其中任何一个:**
##   · 删掉本域这个 → _compile_and_collect 取不到错误、恒返回空列表 →
##     validate(kind=script) 会把**编译失败的代码报成合法**(valid=true)。
##     没有报错、没有告警、没有任何可观测迹象, 是最难查的一类失效。
##   · 删掉服务器那个 → get_logs / _safe_call_handler 失去运行期诊断。
## 代价只是每条 print/错误多一次字符串清洗, 以及两块环形缓冲(日志 2000 条 + 错误 500 条)
## 的常驻内存。
static func _compile_error_log() -> MCPLogger:
	if _compile_log == null:
		_compile_log = MCPLogger.new()
		OS.add_logger(_compile_log)
	return _compile_log


## ======= 域注册入口 =======
##
## 由 MCPDevServer._register_editor_tools() 经 _register_validate_tools 调用一次。
## add_tool 是服务器 `_add_tool` 的 Callable, 签名 (name, desc, input_schema, handler)。
##
## 与主文件里其余 _register_* 的区别: 那些是服务器的方法、可以直接调 self._add_tool, 而本文件
## 不认识服务器, 只能把方法当值传进来。代价是多一层 Callable 间接, 换来的是域文件可以被独立
## 阅读、独立修改、独立静态检查。
##
## 这个接缝为什么可以留(按"编译错误从哪来"那节的开头判据自查过): 漏调后果是 validate /
## classdb_query 不进 _tool_handlers, 协议层在调用前会检查 _tool_handlers.has(tool_name),
## 缺失即返回 JSON-RPC 错误 "Unknown tool: validate" —— **显式报错**, 不会伪装成正常结果,
## 满足判据前半句"漏调必须可见"。MCPCodeIndex.register 是同形状、同结论, 各域一致。
##
## 但要**如实记下这处的可见性弱于 logger 那处**, 别把它当成"加载期就有守卫": 漏注册
## **只在有人调这个工具时**才暴露, 加载期没有任何迹象 —— 契约自检兜不住, 因为
## MCPToolAudit.audit_tools 只审**已注册**的 tool_defs/tool_handlers(schema 与 handler 是否
## 读同一批键), 它没有"应注册名册"这个入参, 无从比对"缺了谁"。本域若整个 register 没被调,
## 就会安静地少掉 2 个工具, 直到有人去调 validate 才会撞上 Unknown tool。
## (这与 MCPDevServer 里"曾有实现完整却从未注册的死代码"是同一类问题, 可见那里早有前例。)
## 已补上, 两条互补(都在 audit_tools 里, 且都只在 registry_is_full 下跑):
## MCPToolMeta.audit_against 用四张元数据名单反向核对"名单写了却没注册" ——
## validate 与 classdb_query 都在 READ_ONLY 名单里, 故本域整个 register 漏调会被报出来;
## MCPToolAudit.audit_declared_registrations 反过来扫源码里的注册调用, 覆盖名单之外的工具。
##
## 留判别方法给后人: 接缝漏调后是**显式报错**, 还是**静默返回看似正常的结果**? 只有后者
## (如本域的 logger)才必须改成域内自建或补告警; 前者(如本函数)可留接缝, 但别误以为
## 它另有加载期守卫 —— 上面已写明没有。
##
## ======= 接线契约: 已接线、副本已删, 且重名已有自动检查守着 =======
##
## **当前状态(实测)**: 主文件 `_register_validate_tools()` 的函数体只剩一行
## `MCPValidateTools.register(_add_tool)`; 它自己那两份 `_add_tool("validate", ...)` /
## `_add_tool("classdb_query", ...)` 副本**已删除**(全目录 grep 这两个工具名 0 命中)。
## 本段留着不是记流水账, 而是**验收方法**: 任何人重新引入副本, 上面那两条 grep 立刻会响。
## (定位一律用函数名 `_register_validate_tools`, 别用行号 —— 主文件被并行编辑, 行号已多次位移。)
##
## 为什么"删副本"曾是硬要求, 以及现在由什么守住:
## 不删的后果是**重名注册**, 而它**没有任何检查会发现**:
##   · MCPDevServer._add_tool 里 `_tool_handlers[name]` / `_tool_schemas[name]` 是 **Dictionary**,
##     重名 → 后注册的覆盖先注册的; 而 `_tool_defs.append(...)` 是 **Array**, 重名 → **累积两条**。
##   · 于是**先注册的那份实现成为死代码**(dict 侧只剩后一份的 handler), _tool_defs 里躺着两条同名项,
##     tool_count 虚高, 而协议层只派发到后一份。
##   · 全项目没有一处能发现: MCPToolAudit 的 `registered[tname] = true` 是 Dictionary(把重名折叠),
##     它只管"进了注册表却没 handler"(管不到"进了两次")。症状是**死代码**, 不是报错。
## 副本这次是靠人记住并删掉的, 但不必再靠人: MCPToolAudit.audit_tool_name_duplicates
## 专门比对"源码里声明注册的工具名"与"实际注册表", 重名会作为一条 issue 报出 ——
## 故同一个坑对下一个域不再敞开。上面那两条 grep 保留作人工验收, 不再是唯一防线。
##
## ======= 为什么本域的 handler 名要保持 `_handle_` 前缀(理由已按当前事实重新校准) =======
##
## 先说机制(结论仍成立): MCPToolAudit.func_body(method) 是**按函数名**在全部源文件里找、
## **返回第一个命中**的, 而 _load_sources 明确 `names.sort()`(注释写着"不排序时同名函数落在哪个
## 文件里就成了随机的")。所以命中是**确定的、可按文件名算出来**的, 不是随机的。
##
## **【不可当通则用, 方向必须按具体的两个文件算】** 该目录当前字典序为:
##   MCPCodeIndex < MCPDevServer < MCPDevTools < MCPFileTools < MCPLogTools
##     < MCPResourceTools < MCPSceneTools < MCPScreenshotTools < MCPScriptSync < MCPValidateTools
## 本域属于"主文件先命中"是因为 **MCPValidateTools.gd 排在整个列表最后**; 唯独 **MCPCodeIndex.gd
## 排在 MCPDevServer.gd 之前** —— 在 CodeIndex 域撞名时方向**相反**, 是域文件先命中。抄去判断别的域会算反。
##
## **强度校准(重要, 别把这段当成"现在正危险")**: 副本已删, 故**此刻**把 `_handle_*` 改名成
## `_call_*` 并**不会**造成误报 —— 只剩一份, func_body 切谁都对。这段之所以还留着, 是下面三条:
##   1. **共享命名空间**: 主文件二十来个 handler 几乎全是 `_call_*`, 改名等于主动钻进那个空间。
##      将来主文件新增 handler、或任何一方再出现同名副本, func_body 会**确定地**切到主文件那份
##      (MCPDevServer < MCPValidateTools), 于是拿一份的 schema 比另一份的 handler, 报出归因错误的
##      "入参不一致"问题 —— 而真凶是重名, 症状指向入参, 极难反查。
##   2. **它违反一个可推广的不变量**: 域文件 handler 名严格**由工具名派生**
##      (`validate` → `_handle_validate`), 工具名全局唯一故 `_handle_*` 天然不重名。当前全目录
##      35 个 `_handle_*` 函数无一重名, 可作证。(主文件自己有一个 `_handle_jsonrpc`, 与本域四个不撞。)
##      一旦改成 `_call_*`, 这条不变量就只在"恰好没撞"时成立, 而"恰好"不会每次都成立。
##   3. **"统一风格"这个理由本身是假的**: 主文件的 `_call_*` 里既有还没搬走的实现, 也有只留一行
##      转调域实现的薄壳(如 `_call_get_game_logs` 转 `MCPLogTools._call_collect_logs`),
##      所以向它对齐并不能换来一致性, 只会把"实现体在本文件"与"薄壳"两类混进同一个命名空间。
## 结论: 保持 `_handle_*`。这是**预防性约定**, 不是当前正在发生的故障 —— 写成后者会让人以为危在旦夕,
## 等发现"根本没出事"之后连这段的其余部分也不信了。
static func register(add_tool: Callable) -> void:
	add_tool.call("validate",
		"统一验证入口。kind=script: 验证GDScript语法/可编译性(传path读磁盘或传code源码), 返回是否有效与错误明细; kind=resource: 验证资源/场景能否被引擎加载(排查.tres/.tscn损坏或依赖缺失)。",
		{"type": "object", "properties": {
			"kind": {"type": "string", "enum": ["script", "resource"], "description": "验证类型, 默认 script"},
			"path": MCPToolSchema.str_arg("目标 res:// 路径(script 与 code 二选一)"),
			"code": MCPToolSchema.str_arg("kind=script 时可直接传源码文本")
		}},
		_handle_validate)

	add_tool.call("classdb_query",
		"查询Godot类API(方法/属性/信号/枚举)。search模糊搜类名, class_name查指定类成员。写脚本前确认API签名用。返回JSON。",
		{"type": "object", "properties": {
			"class_name": {"type": "string", "description": "要查询的类名(如 CharacterBody2D/Button), 提供后返回该类的成员清单"},
			"search": {"type": "string", "description": "按关键字模糊搜索类名(如 'body' 匹配 CharacterBody2D/RigidBody2D 等)"},
			"methods": {"type": "boolean", "description": "是否返回方法清单, 默认 true"},
			"properties": {"type": "boolean", "description": "是否返回属性清单, 默认 true"},
			"signals": {"type": "boolean", "description": "是否返回信号清单, 默认 true"}
		}},
		_handle_classdb_query)


## ======= 实现 =======

## validate 的分派: 只按 kind 选实现。刻意做成"薄分派"而不把两支合成一支: 两支验的是完全
## 不同的对象(源码 vs 资源), 合成一支会在同一个函数体里同时出现编译器与 ResourceLoader 两套
## 失败形态, 读的人得自己拆开看。
static func _handle_validate(args: Dictionary) -> Dictionary:
	if VariantTool.get_string(args, "kind", "script") == "resource":
		return await _handle_validate_resource(args)
	return await _handle_validate_script(args)


static func _handle_validate_script(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	var code: String = VariantTool.get_string(args, "code")
	if path.is_empty() and code.is_empty():
		return MCPResult.fail("必须提供 path 或 code 之一")
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			return MCPResult.fail("脚本文件不存在: %s" % path)
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return MCPResult.fail("无法读取脚本文件: %s" % path)
		code = file.get_as_text()
		file.close()
	var script := _make_tmp_script(code)
	var outcome := _compile_and_collect(script)
	# 剔除误报: GDScript.new() 临时脚本默认无路径, 引擎会因 class_name 已全局注册
	# 且注册路径 != 本脚本路径而报 "hides a global class"——当验证对象正是该 class_name
	# 的注册文件本身(或其修改版本)时, 此冲突并非真实语法错误, 应剔除后再判定有效性。
	outcome.real_errors = _filter_class_conflicts(outcome.real_errors, path, code)
	# warnings 通道同样过滤: 带 "Warning treated as error" 后缀的 hides 消息会被归入此处
	var filtered_warns: Array = []
	for w in outcome.warnings:
		var msg := str(w)
		if msg.contains("hides a global script class") and _is_class_conflict_false_positive(_class_from_conflict(msg), path, code):
			continue
		filtered_warns.append(msg)
	outcome.warnings = filtered_warns
	if outcome.real_errors.is_empty():
		return MCPResult.ok_json({
			"valid": true,
			"message": "脚本语法有效" + ("(含 %d 条可忽略警告)" % outcome.warnings.size() if outcome.warnings.size() > 0 else ""),
			"error_latin": 0,
			"error_text": "",
			"warnings": outcome.warnings,
		})
	var text := "; ".join(outcome.real_errors)
	return MCPResult.ok_json({
		"valid": false,
		"message": "解析失败: %s" % text,
		"error_line": 0,
		"error_text": text,
		"errors": outcome.real_errors,
		"warnings": outcome.warnings,
	})


## 构造一个用于预编译的临时 GDScript(无资源路径, 不触碰 Resource 缓存)。
static func _make_tmp_script(code: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = code
	return script


## 编译临时脚本并收集时的新增错误/警告。返回 {"real_errors", "warnings"}。
##
## reload() 的是上面那个**临时**脚本(GDScript.new(), 无 resource_path, 不进 Resource 缓存),
## 不是本文件、也不是 MCPDevServer —— reload 那两个会杀死 HTTP 服务器, MCPDevServer 顶部注释
## 里有明确警告, 实测踩过。
static func _compile_and_collect(script: GDScript) -> Dictionary:
	var log := _compile_error_log()
	var n0: int = log.get_error_cursor() if log else 0
	script.reload()
	var new_errs: Array = []
	if log:
		new_errs = log.take_errors_since(n0).entries
	var real: Array = []
	var warns: Array = []
	for e in new_errs:
		var msg: String = str(e.get("message", ""))
		if msg.contains("Warning treated as error") or msg.contains("inferred from a Variant"):
			warns.append(msg)
		else:
			real.append(msg)
	return {"real_errors": real, "warnings": warns}


## 逐个过滤 class 冲突: 保留真实冲突, 剔除"验证该 class_name 注册文件本身"造成的误报。
static func _filter_class_conflicts(errors: Array, path: String, code: String) -> Array:
	var kept: Array = []
	for e in errors:
		var msg := str(e)
		if msg.contains("hides a global script class"):
			var cls := _class_from_conflict(msg)
			if not _is_class_conflict_false_positive(cls, path, code):
				kept.append(e)
		else:
			kept.append(e)
	return kept


## 从冲突错误文本解析出冲突的 class_name(形如 "Class \"Foo\" hides a global class.")。
static func _class_from_conflict(msg: String) -> String:
	var start := msg.find("\"")
	if start < 0:
		return ""
	var end := msg.find("\"", start + 1)
	if end < 0:
		return ""
	return msg.substr(start + 1, end - start - 1)


## 判定一条 class 冲突是否为误报:
## - 冲突的 class_name 尚未全局注册        → 缓存滞后, 误报
## - 注册路径 == 本次被验证 path            → 验证注册文件自身, 误报
## - 无 path 但 code 声明了同名 class_name  → 新定义源, 误报
## - 解析不出 class_name                    → 无法判断, 保守不判误报(可能真是语法错误)
static func _is_class_conflict_false_positive(cls: String, path: String, code: String) -> bool:
	if cls.is_empty():
		return false
	var reg := _global_class_path(cls)
	if reg.is_empty():
		return true
	if not path.is_empty() and _same_path(reg, path):
		return true
	if path.is_empty() and _extract_class_name(code) == cls:
		return true
	return false


## 查询一个 class_name 在全局类缓存中的注册路径(res://…); 未注册返回 ""。
static func _global_class_path(target_class: String) -> String:
	var classes: Array = ProjectSettings.get_setting("_global_script_classes", [])
	for c in classes:
		if c is Dictionary and str(c.get("class", "")) == target_class:
			return str(c.get("path", ""))
	return ""


## 简化路径比较(处理分隔符/大小写, 避免 Windows 盘符差异导致误判)。
static func _same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").to_lower() == b.replace("\\", "/").to_lower()


## 扫描脚本头部(class_name 仅允许在 extends 之前), 返回声明的类名; 未声明返回 ""。
static func _extract_class_name(code: String) -> String:
	for line in code.split("\n"):
		var t := line.strip_edges()
		if t.is_empty() or t.begins_with("#") or t.begins_with("@"):
			continue
		if t.begins_with("class_name "):
			return t.trim_prefix("class_name ").split(" ")[0].replace("\t", "").strip_edges()
		if not t.begins_with("extends"):
			break
	return ""


static func _handle_validate_resource(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		return MCPResult.fail("资源加载失败: %s" % path)
	return MCPResult.ok_json({
		"valid": true,
		"type": res.get_class(),
		"message": "资源可正常加载",
	})


## 查询 Godot 类的 API(方法/属性/信号)。用于 AI 写脚本前确认原生 API 用法。
static func _handle_classdb_query(args: Dictionary) -> Dictionary:
	var query_class: String = VariantTool.get_string(args, "class_name")
	var search: String = VariantTool.get_string(args, "search")
	var want_methods: bool = VariantTool.get_bool(args, "methods", true)
	var want_props: bool = VariantTool.get_bool(args, "properties", true)
	var want_signals: bool = VariantTool.get_bool(args, "signals", true)

	# 模糊搜索类名
	if search != "":
		var matches: Array = []
		var all_classes := ClassDB.get_class_list()
		for c in all_classes:
			if str(c).to_lower().contains(search.to_lower()):
				matches.append(c)
		matches.sort()
		if matches.size() > 50:
			matches = matches.slice(0, 50)
		return MCPResult.ok_json({"mode": "search", "query": search, "match_count": matches.size(), "classes": matches})

	if query_class == "":
		return MCPResult.fail("必须提供 class_name 或 search")
	if not ClassDB.class_exists(query_class):
		return MCPResult.fail("类不存在: %s(请用 search 模糊搜索)" % query_class)

	var out := {"class_name": query_class, "inherits": _class_inheritance_chain(query_class)}
	if want_methods:
		var methods: Array = []
		for m in ClassDB.class_get_method_list(query_class, true):
			var arg_sig := ""
			var arg_names: Array = m.get("args", [])
			if arg_names.size() > 0:
				var parts := PackedStringArray()
				for a in arg_names:
					parts.append("%s:%s" % [a.get("name", "?"), a.get("type", "?")])
				arg_sig = "(" + ", ".join(parts) + ")"
			else:
				arg_sig = "()"
			var ret: int = int(m.get("return", {}).get("type", 0)) if m.get("return", {}) is Dictionary else 0
			methods.append("%s%s -> %s" % [m.get("name", "?"), arg_sig, _type_name(ret)])
		out["methods"] = methods
	if want_props:
		var props: Array = []
		for p in ClassDB.class_get_property_list(query_class, true):
			props.append("%s : %s" % [p.get("name", "?"), _type_name(int(p.get("type", 0)))])
		out["properties"] = props
	if want_signals:
		var signals: Array = []
		var sigs: Array = _instance_signal_list(query_class)
		for s in sigs:
			var arg_sig := ""
			var arg_names: Array = s.get("args", [])
			if arg_names.size() > 0:
				var parts := PackedStringArray()
				for a in arg_names:
					parts.append("%s:%s" % [a.get("name", "?"), a.get("type", "?")])
				arg_sig = "(" + ", ".join(parts) + ")"
			else:
				arg_sig = "()"
			signals.append("%s%s" % [s.get("name", "?"), arg_sig])
		out["signals"] = signals
	return MCPResult.ok_json(out)


## 获取类的信号列表: ClassDB.class_get_signal_list 对内置类返回空,
## 改为实例化后调 get_signal_list()(实例仅用于读 API, 无需入树)。
static func _instance_signal_list(cname: String) -> Array:
	if not ClassDB.can_instantiate(cname):
		return []
	var inst: Object = ClassDB.instantiate(cname)
	if inst == null:
		return []
	var sigs: Array = inst.get_signal_list()
	inst.free()
	return sigs


## 返回类的继承链(从基类到最终祖先)
static func _class_inheritance_chain(cname: String) -> Array:
	var chain: Array = []
	var cur := cname
	while cur != "" and ClassDB.class_exists(cur):
		chain.append(cur)
		cur = ClassDB.get_parent_class(cur)
	return chain


## 将 Godot 类型枚举值转为可读类型名
static func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_NIL: return "null"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_OBJECT: return "Object"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		_:
			if type_id >= TYPE_OBJECT:
				return "Object/%s" % type_id
			return "type_%d" % type_id
