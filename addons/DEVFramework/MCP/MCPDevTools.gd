@tool
extends RefCounted

## ======= 开发辅助域 =======
##
## 从 MCPDevServer 拆出的工具域, 收录"在宿主进程里就地执行开发动作"的能力。**本文件必须导出安全**
## (运行时服务器要在导出包里注册 eval_code), 故:
##   · 只留 eval_code(唯一运行时可用的开发辅助工具);
##   · restart_editor / script_status 依赖 EditorInterface / MCPScriptSync, 已拆到 MCPDevToolsEditor。
##
## 依赖方向与 MCPCodeIndex / MCPFileTools 一致, 严格单向: 本文件**不引用** MCPDevServer,
## 也不持有任何服务器状态, 只依赖:
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - VariantTool    全局 class_name, 入参读取
## (新鲜度守卫所需的 MCPScriptSync **不 preload**: 它含编辑器引用, 只在编辑器构建里经 load 条件加载。)
## 注册靠"把 _add_tool 当 Callable 传进来"完成, 所以连服务器的类型都不需要认识。
##
## ## eval_code 为什么需要一份"注入的上下文", 而它不是状态
##
## eval_code 的实现体要读四样都不属于本文件的东西: _mode / _game_started_at / _logger
## (分别用于新鲜度守卫的判据分支、mtime 基准、以及运行期错误捕获), 以及预检那一份
## _precheck_eval_code。本文件既不能引用 MCPDevServer, 也不该持有实例状态, 故这四项经
## set_eval_ctx_provider() 注入的 **provider Callable** 现取现用: 本文件只存那个 Callable,
## 每次调用向它要一份字典, 用完即弃, 不缓存任何服务器对象。
##
## 之所以不能各自"推导"掉:
##   - _mode 可以推导(Engine.is_editor_hint(), 与 _ready 的分支一致), 所以没注入时也能对;
##   - _game_started_at **不能**推导。它是"autoload 就绪时刻"(MCPDevServer._ready 里
##     int(Time.get_unix_time_from_system())), 取晚了会漏报"加载后就绪前那一小段"的改动。
##     MCPScriptSync._guard_runtime 对 baseline<=0 的处理是**全部放行**, 即闸门静默失效 ——
##     那正是本模块要消灭的失败模式, 故缺 provider 时也不能自己编一个基准。
##   - _logger **不能**推导(OS.add_logger 没有取回接口), 而编辑器进程与游戏进程都装了它。
##   - 预检**不能**推导: 黑名单要拦的正是 _mode 决定走哪个进程的那份代码。
## 注入点与"两个进程分支都要注入"的理由见 set_eval_ctx_provider 的注释。
##
## ## "eval 代码预检"簇也住本域(共享件住域, 主文件转发)
##
## precheck_eval_code / indent_method_body 及其黑名单(_EVAL_FORBIDDEN /
## _eval_forbidden_scan / _is_eval_id_char / MAX_EVAL_LENGTH)在本域, 主文件改成薄转发:
## 那边_call_game_eval_proxy(编辑器侧 game_eval 转发)也调它们, 而 eval_code 在本域。
## 共享件住域里、依赖方向保持单向, 同 MCPCodeIndex.collect_scene_deps 的先例。
## **只有一份实现**: 两份各自漂移的症状是"eval 能跑但 game_eval 被拦"或反过来, 且不报错。
##
## ## eval_code 的热重载边界(危险面, 别改坏)
##
## eval_code 执行前会过 MCPScriptSync.guard_eval(**仅编辑器构建**: 导出包无热重载、且不能加载
## MCPScriptSync, 故跳过守卫), 编辑器侧那条路径对**磁盘有改动的每一个
## .gd** 做 ResourceLoader.load(..., CACHE_MODE_REPLACE)。这个集合里包含 MCPDevServer.gd
## 自己 —— 而 MCPDevServer.gd 正承载 HTTP 服务器(_http), 原地重载它会终止服务器, 之后端口
## 不再监听、且无法靠 MCP 工具自救(见 MCPDevServer 顶部第 3 条注释)。这不是本文件引入的,
## 但本文件是该路径的入口, 故在此写明: **改 MCPDevServer.gd 之后不要紧接着调 eval_code**,
## 否则会在旧实例仍被替换的瞬间把服务器顶掉。要验自己刚改的 eval_code, 用
## script_status(path=res://addons/DEVFramework/MCP/MCPDevTools.gd) 先确认磁盘版本已加载。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 模式标识。**本文件必须导出安全**(运行时服务器要注册 eval_code), 故不能 preload 含编辑器引用的
## MCPScriptSync; 这两个字面量与 MCPScriptSync.MODE_* / MCPDevServer.MODE_* 取值一致。
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## eval 上下文提供器: 无参 Callable, 返回 {mode, game_started_at, logger}。
##
## 刻意做成"取用时回调"而不是"注册时快照": 快照会在 refresh_tools 重建注册表之后指向已失效的
## 服务器对象, 而回调每次都问当前的服务器。
static var _eval_ctx_provider: Callable = Callable()


## 注入 eval 运行上下文的提供器(无参 Callable, 返回上面那三个键, 见 EVAL_CTX_KEYS)。
##
## 服务器须在**编辑器与游戏两个进程分支都调一次**, 不能只依赖 register():
## 游戏进程注册的是 game_eval 等宿主工具, 压根不走 register()(那边注册表里没有本域工具)。
##
## 漏调不会被静默吞掉: resolve_eval_ctx 会标记 degraded 并给出 reason, 由 _call_eval_code
## 挂进每一次 eval 响应的顶层 text / warnings, 游戏侧还会附带"[守卫未生效]"那条。
## 判据是"接缝可以存在, 但漏调必须可见" —— 漏调最隐蔽的代价是守卫静默失效后症状变成
## "问题查不出来", 没有任何报错指向根因。
static func set_eval_ctx_provider(provider: Callable) -> void:
	_eval_ctx_provider = provider


## ======= eval 实现(注册不在此) =======
##
## eval_code 的 MCP 工具注册已收进 MCPDevServer._register_game_play_tools(带必填 process):
## 编辑器侧 process=editor 就地执行、process=game 经预检 + 调试线转发; 运行时就地执行。故本文件
## 不再有 register()。本文件保持零编辑器标识符(restart_editor / script_status 在 MCPDevToolsEditor)。
##
## eval 上下文经 set_eval_ctx_provider() 单独注入(服务器在注册 eval_code 前调它)。
##
## handler 一律 static(不用 lambda): MCPToolAudit 靠 handler.get_method() 拿函数名再去源码里
## 切函数体做入参一致性自检, lambda 注册会让 get_method() 返回 "<anonymous lambda>", 那批工具
## 将**静默跳过**自检 —— 详见 MCPCodeIndex 开头与 MCPToolAudit 开头。


## ======= 开发辅助工具实现 =======

## 取宿主进程的场景树。static 上下文没有 get_tree(), 故经 Engine 取主循环
## (与 MCPScriptSync._rescan_fs 同一手法)。
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## resolve_eval_ctx 必须拿到**真值**的三个键。列成常量而非散在各处写字符串,
## 因为降级判定要逐键对账, 而漏拼一个键就等于该项静默走推导值。
const EVAL_CTX_KEYS := ["mode", "game_started_at", "logger"]

## 降级文案里的"后果说明": 让看到告警的人立刻知道漏了这一项会怎样, 而不只是"少了这一项"。
## 这段是本判据的落点 —— 接缝漏调之所以危险, 是因为后果全都不报错。
const EVAL_CTX_DEGRADED_HINT := "后果: game_started_at 缺失使新鲜度守卫全部放行(跑旧代码也不拦); logger 缺失使运行期错误一条不捕获; mode 缺失使守卫走错判据分支。修法: 在服务器侧(编辑器与游戏两个进程分支都要)调用 MCPDevTools.set_eval_ctx_provider(...)。"


## 取本次 eval 用的运行上下文: provider 现取现用, [param override] 非空时按键覆盖。
##
## ## 为什么这里必须有接缝
##
## mode / game_started_at / logger 都属于服务器实例字段且**不可推导**(逐项理由见文件头),
## 域内自建物理上不存在, 只能注入。判据"接缝可以存在, 但漏调必须可见; 漏调会静默失效的
## 场合一律不许用接缝"在本处的落法就是下面这段降级记账。
##
## ## 降级怎么做到"可见"
##
## 三项缺任何一项, 后果都是"看起来正常、实则失效"且都不报错。故这里不静默补值:
## 返回字典**恒带** degraded / reason 两键, 由 _call_eval_code 挂进响应(顶层 text +
## warnings + structuredContent), 用户与 AI 从 MCP 返回值就能看见, 不必翻日志。
## 对照本仓库另外两种落法: log 域漏调返回"未就绪"是显式报错, validate 域因为漏调会静默
## 恒真所以直接否决接缝 —— 本域属"注入 + 自带告警"这一档。
static func resolve_eval_ctx(override: Dictionary = {}) -> Dictionary:
	var out := {
		"mode": MODE_EDITOR if Engine.is_editor_hint() else MODE_RUNTIME,
		"game_started_at": 0,
		"logger": null,
	}
	# 来源记账: out 的初值是"推导值"而非真值。降级判定必须按"哪些键拿到了真值"来算 ——
	# 若直接看 out.has(k), 初值齐全会永远判定为不降级, 那个标记就形同虚设。
	var from_source := PackedStringArray()
	if _eval_ctx_provider.is_valid():
		var provided: Variant = _eval_ctx_provider.call()
		if provided is Dictionary:
			var given: Dictionary = provided
			out.merge(given, true)
			for k in given.keys():
				from_source.append(str(k))
	if not override.is_empty():
		out.merge(override, true)
		for k in override.keys():
			if not from_source.has(k):
				from_source.append(str(k))
	var missing := PackedStringArray()
	for k: String in EVAL_CTX_KEYS:
		if not from_source.has(k):
			missing.append(k)
	out["degraded"] = missing.is_empty() == false
	out["reason"] = "" if missing.is_empty() else \
		"eval ctx 降级: 缺 %s。%s" % [", ".join(missing), EVAL_CTX_DEGRADED_HINT]
	return out


## 在宿主进程执行一段 GDScript。
##
## ## 命名: 沿用主服务器原名 _call_eval_code, 不套壳成 _handle_eval_code
##
## 它既是注册进工具表的 eval_code handler, 又是主文件三处跨域调用点的公共入口:
##   _register_runtime_tools 的 game_eval runtime 实现(约 3624)
##   _runtime_auto_verify 的 "eval" 动作(约 4002)
##   _poll_until 的轮询探测(约 4085)
## 三处都只传一个 Dictionary(单参调用), 故签名是 ([param args], [param ctx] = {}),
## ctx 走默认空字典 → 回落到 provider。
##
## 不套壳的第二个理由: MCPToolAudit 靠 handler.get_method() 取函数名再切源码函数体做
## 入参一致性自检。若拆成 "_handle_eval_code 转发 → 实现"两层, 自检切到的转发层里
## 没有任何入参读取, 那批检查会**静默失效**(不是报错, 是"永远通过")。
## 另注: 主文件那份 _call_eval_code 必须删干净 —— 同名会让自检按字典序切到
## "MCPDevServer.gd"里的那份去(MCPDevServer < MCPDevTools), 切到的正是被删空的旧位置。
##
## [param ctx] 运行上下文覆盖项, 见 resolve_eval_ctx。省略时向 provider 取。
static func _call_eval_code(args: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var code: String = VariantTool.get_string(args, "code")
	if code.is_empty():
		return MCPResult.fail("必须提供 code")
	var context := resolve_eval_ctx(ctx)
	var mode := str(context.get("mode", MODE_EDITOR))
	var game_started_at := int(context.get("game_started_at", 0))
	var logger: Object = context.get("logger", null)
	# 降级告警在**每一条**返回路径上都要带上(含错误路径): 守卫误判时 eval 是失败的,
	# 但"这次判定本身可不可信"恰恰只在失败时才需要知道, 只挂成功路径等于该看见时看不见。
	var warn := _degraded_warning(mode, game_started_at, context)
	var tree := _tree()
	# 顺序: 新鲜度守卫排在预检**之前**, 让预检基于已同步的缓存判断, 免得为一个
	# 马上就要被替换掉的旧版本报错。
	# 注意这**不是**全局类能热切换的原因 —— 实测调整顺序无效: 缓存确实换新了,
	# 但 eval 里 AsyncScope.new() 仍执行旧代码, 真正的原因是游戏进程刷不了全局类表
	# (原因与实测过程见 MCPScriptSync._guard_runtime)。
	# 两个 eval 入口共用这一个判定点, 内部按模式走各自的判据:
	# 编辑器侧比内容哈希, 游戏侧比 mtime 并区分"有既存实例"与"是全局类"两种阻塞原因。
	# **新鲜度守卫只在编辑器构建(编辑器/游戏进程)有意义**: 导出包无热重载, 且 MCPScriptSync
	# 含编辑器引用不能 preload。故按特征标签分流 —— 非编辑器构建直接跳过守卫(ok=true)。
	var guard := {"ok": true}
	if Engine.is_editor_hint() or OS.has_feature("editor"):
		var sync: Variant = load("res://addons/DEVFramework/MCP/MCPScriptSync.gd")
		if sync != null:
			guard = await sync.guard_eval(mode, game_started_at, tree)
	if not bool(guard.get("ok", true)):
		# category 由守卫按失败原因判定(编辑器侧=磁盘脚本语法错, 游戏侧=跑的是旧代码)。
		# 这两者的正确恢复动作完全相反(改代码 vs 重启进程), 统一归为一类会让调用方
		# 按错误的方向恢复, 所以分类在判定处产生, 这里只透传。
		return _attach_warning(MCPResult.err(str(guard.get("message", "")), str(guard.get("category", MCPResult.CAT_STALE_CODE)),
			bool(guard.get("retryable", false)), str(guard.get("recovery", ""))), warn)
	# 预处理(长度/安全扫描/语法编译)**只做一次**, 并把编译好的脚本返回来直接执行 ——
	# 不再"预检编译一次 + 执行前再编译一次"。编译失败时 _prepare_eval 会把引擎本轮打印的
	# **具体解析错**(如 "Cannot call non-static function ... on the class ...")经 logger 游标取回并内联,
	# 使 AI 一眼看到根因, 不必再去 get_logs 翻。
	# 单一实现住本域(主文件 _call_game_eval_proxy 的转发前预检也走 precheck_eval_code → _prepare_eval)。
	var prep := _prepare_eval(code, logger)
	if not bool(prep.get("ok", false)):
		return _attach_warning(MCPResult.err_validation(str(prep.get("error", "")),
			"修正代码语法后重新调用 eval(语法错误无法通过重试解决)"), warn)
	var script: GDScript = prep.get("script")
	# 执行前记录错误游标, 以便捕获本次 eval 运行期错误(用逻辑游标, 环形缓冲满后仍正确)。
	# 取在编译**之后**: 上一步的编译错已在上面内联返回, 不会混进运行期错误收集。
	var err_before: int = logger.get_error_cursor() if logger else 0
	var inst: Node = script.new()
	if inst == null:
		return _attach_warning(MCPResult.err_internal("无法实例化求值脚本", "重新调用 eval, 或检查服务器日志"), warn)
	var root := tree.root if tree != null else null
	if root:
		root.add_child(inst)
	var result: Variant = inst.call("_mcp_run")
	# await 感知: 代码含 await 时 call 返回协程句柄, 等待其完成再回传真实结果(带超时)。
	# 超时不杀续体: 实例转交延迟回收, 协程自然结束后自动释放(对齐 DevTools/Node REPL 的 top-level await 语义)。
	if _is_function_state(result):
		var timeout_sec := clampf(VariantTool.get_float(args, "timeout_ms", 8000) / 1000.0, 0.5, 15.0)
		var holder := {"done": false, "value": null}
		_await_state(result, holder)
		var elapsed := 0.0
		while not holder.done and elapsed < timeout_sec:
			await tree.create_timer(0.05).timeout
			elapsed += 0.05
		if not holder.done:
			_reap_later(result, inst)
			return _attach_warning(MCPResult.ok("协程仍在后台执行(已等待%.1fs): eval 启动的异步流程会继续运行, 实例将在其结束后自动释放。\n如需拿到最终返回值请增大 timeout_ms 重试(上限15000); 若只需触发副作用则当前调用已生效。" % elapsed), warn)
		result = holder.value
	if root and is_instance_valid(inst):
		inst.queue_free()
	# 收集本次运行产生的运行期错误(若代码 halt, 也会反映为错误入队)
	var runtime_errors: Array = []
	if logger:
		var taken: Dictionary = logger.take_errors_since(err_before)
		runtime_errors = taken.get("entries", [])
	var shown := str(result)
	if result is Dictionary or result is Array:
		shown = JSON.stringify(result)
	# 运行期错误(如 get_node 访问 null 字段)应作为错误即时返回, 而非"成功+警告",
	# 否则编辑器侧只能等 20s 超时再回查错误缓冲, AI 无法及时定位。
	if not runtime_errors.is_empty():
		var merged := condense_runtime_errors(runtime_errors)
		if merged.is_empty():
			return _attach_warning(MCPResult.ok("执行成功, 返回: %s\n(捕获 %d 条运行期错误, 均命中 dev_framework/mcp/ignored_error_patterns 已过滤)" % [shown, runtime_errors.size()]), warn)
		var msgs := PackedStringArray()
		var max_show := mini(merged.size(), 5)
		for i in range(max_show):
			var e: Dictionary = merged[i]
			var count := int(e.get("count", 1))
			msgs.append("%s@%s:%s" % [e.get("message", ""), e.get("file", "?"), e.get("line", "?")] + ("" if count <= 1 else " (x%d)" % count))
		# 用 err_validation(is_retryable=false) 而非裸 err + true:
		# is_retryable 回答的是"**原样**重发一次有没有意义"。此处是同一段 eval 代码再次执行,
		# 必然报同样的错, 所以答案是没有 —— 标 true 会让 AI 在没改代码的情况下盲目重试,
		# 白费一轮。"修正代码后重试"确实有效, 但那属于改参数之后的重试, 由 recovery 承载。
		return _attach_warning(MCPResult.err_validation(
					"eval 执行返回: %s\n执行中捕获 %d 条运行期错误(合并后 %d 类, 前 %d 类):\n%s\n\n提示: get_node() 相对路径基于 eval 脚本实例, 找不到节点常因路径写错, 建议用绝对路径(/root/场景名/...) 或 get_tree().current_scene.get_node(...)。完整错误列表可用 %s; 重复噪音可在项目设置 dev_framework/mcp/ignored_error_patterns 配置子串忽略。" %
			# 上面这些错误取自**本进程**的 logger 游标, 故按模式指向对应进程的日志。
			[shown, runtime_errors.size(), merged.size(), max_show, "\n".join(msgs),
				"get_logs(process=game,kind=error)" if mode == MODE_RUNTIME else "get_logs(process=editor,kind=error)"],
			"修正 eval 代码中的错误后重试"), warn)
	return _attach_warning(MCPResult.ok("执行成功, 返回: %s" % shown), warn)


## ======= eval 代码预检(与主文件共用) =======
##
## 整簇住本域, 主文件改成薄转发(MCPDevTools.precheck_eval_code / indent_method_body):
## 共享件住域里、依赖方向保持单向, 同 MCPCodeIndex.collect_scene_deps 的先例。
## **只有一份实现**是硬要求 —— 两份各自漂移的症状是"eval 能跑但 game_eval 被拦"或反过来,
## 且不报错(两边都能正常返回, 只是判据不同了)。
##
## 安全边界警告: 黑名单是"事故防护围栏", 不是信任模型。改名单前先读下面的注释。

## 预检 eval 代码(供"编辑器侧转发前拦截"用): 返回 "" 表示通过, 否则错误描述。
## 内含安全扫描 + 语法预编译(单一实现见 _prepare_eval)。
## [param logger] 可选: 传入则编译失败时从它取**本轮新增的引擎解析错**内联进错误文案
##   (否则调用方只得到笼统的 "Parse error", 还得再去 get_logs 翻具体行)。
static func precheck_eval_code(code: String, logger: Object = null) -> String:
	var prep := _prepare_eval(code, logger)
	return "" if bool(prep.get("ok", false)) else str(prep.get("error", ""))


## eval 代码的**唯一**预处理: 长度校验 + 安全扫描 + 语法预编译。
## 返回 {ok:bool, script:GDScript(ok 时), error:String(不 ok 时)}。
## 编译一次并把脚本返给调用方复用 —— 消除"预检编译一次、执行又编译一次"的重复编译。
static func _prepare_eval(code: String, logger: Object = null) -> Dictionary:
	if code.is_empty():
		return {"ok": false, "error": "必须提供 code"}
	if code.length() > MAX_EVAL_LENGTH:
		return {"ok": false, "error": "代码过长: %d 字符, 超过上限 %d。请拆分逻辑后重试。" % [code.length(), MAX_EVAL_LENGTH]}
	var forbidden := _eval_forbidden_scan(code)
	if forbidden != "":
		return {"ok": false, "error": forbidden}
	# 编译前记错误游标: 编译失败时据此取回**引擎刚打印的**具体解析错(非破坏性读)。
	var cursor: int = logger.get_error_cursor() if logger != null else -1
	var script := GDScript.new()
	script.source_code = _wrap_source(code)
	var err := script.reload()
	if err != OK:
		var text := error_string(err)
		var hint := ""
		if text.contains("hides a global script class"):
			hint = " (class_name 与全局类冲突: 请勿在 eval_code 中声明类, 或先 restart_editor)"
		return {"ok": false, "error": "代码解析失败: %s%s\n%s" % [text, hint, _parse_error_details(logger, cursor)]}
	return {"ok": true, "script": script}


## 把代码包成挂在场景树上的 Node 方法(让用户代码可直接 get_tree()/get_node())。
static func _wrap_source(code: String) -> String:
	return "extends Node\nfunc _mcp_run():\n%s" % indent_method_body(code)


## 从 logger 取**自 cursor 起新增**的错误条目, 拼成具体解析错文案(供编译失败时内联)。
## take_errors_since 是**非破坏性**读(不推进游标), 故与后续"运行期错误收集"互不影响。
static func _parse_error_details(logger: Object, cursor: int) -> String:
	if logger == null or cursor < 0:
		return "(详细解析错见 get_logs(kind=error))"
	var taken: Dictionary = logger.take_errors_since(cursor)
	var entries: Array = taken.get("entries", [])
	var lines := PackedStringArray()
	for e in entries:
		if not (e is Dictionary):
			continue
		var msg := str((e as Dictionary).get("message", "")).strip_edges()
		if msg.is_empty():
			continue
		var ln := str((e as Dictionary).get("line", ""))
		lines.append("- %s%s" % [msg, ("" if ln.is_empty() else "  (行 %s)" % ln)])
		if lines.size() >= 5:
			break
	return "(引擎未提供详细解析错)" if lines.is_empty() else "具体:\n" + "\n".join(lines)


## 静态扫描 eval 代码中被禁止的 API, 返回 "" 表示通过。
## 只保留两类"高危且游戏开发测试用不到"的接口:
##   1. 宿主进程控制: 执行系统命令 / 启停进程 / 改环境变量 —— 测试用不到, 出事影响编辑器进程本身。
##   2. 网络出站与监听 —— 数据外泄或暴露本机端口, 工具层也没有对应能力。
## 其余一律放开: 读写文件、加载保存资源、访问场景树与主循环、改项目设置等都是测试常用手段,
## 需要留痕时走 read_file/write_file 等带 dry_run 的工具, eval 不再重复限制。
## 已知边界: 本清单不是安全沙箱, 只是"事故防护围栏", 拦不住有能力的调用方
## (如 ClassDB.instantiate("OS") 可取到真单例绕过点号匹配), 用来压低"被提示注入诱导"的意外概率。
## 要真隔离必须把 eval 放进独立进程, 远超 GDScript 静态扫描的能力, 属设计取舍。
const _EVAL_FORBIDDEN := [
	# -- 宿主进程控制 --
	["OS.execute", "调用系统命令"],
	["OS.create_process", "启动外部进程"],
	["OS.shell_open", "调用系统命令打开文件或 URL"],
	["OS.kill", "终止进程"],
	["OS.set_environment", "修改编辑器进程环境变量"],
	["DisplayServer.shell_open", "调用 shell 打开外部程序"],
	# -- 网络出站与监听 --
	["HTTPRequest", "发起网络请求"],
	["HTTPClient", "发起网络请求"],
	["TCPServer", "监听网络端口"],
	["UDPServer", "UDP 监听"],
	["StreamPeerTCP", "TCP 连接"],
	["StreamPeerTLS", "TLS 连接"],
	["PacketPeerUDP", "UDP 收发"],
	["PacketPeer", "网络收发"],
]

## eval 代码长度上限(字符), 防止超长脚本导致编辑/运行进程缓慢或冻结。超限以 validation 错误拒绝。
const MAX_EVAL_LENGTH := 8192


## 判断是否为"空标识符"字符(数字开头等非法用途, 防止 `123execute` 之类绕过)
static func _is_eval_id_char(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


## 静态扫描 eval 代码中被禁止的 API, 返回 "" 表示通过。
static func _eval_forbidden_scan(code: String) -> String:
	# 词法级扫描: 跳过字符串字面量/注释/预处理器, 只扫描真实代码 token, 避免误报。
	# 同时做标识符边界检查, 防止 `fooProcess`/`executefield` 之类拼接绕过。
	var i := 0
	var length := code.length()
	while i < length:
		var c := code[i]
		# 跳过字符串字面量 ' " (含转义) 和""" 长字符串
		if c == '"' or c == "'":
			var quote := code[i]
			if i + 2 < length and code[i + 1] == quote and code[i + 2] == quote:
				i += 3
				while i + 2 < length and not (code[i] == quote and code[i + 1] == quote and code[i + 2] == quote):
					i += 1
				i += 3
				continue
			i += 1
			while i < length:
				if code[i] == '\\':
					i += 2
					continue
				if code[i] == quote:
					break
				i += 1
			i += 1
			continue
		# 跳过 '#' 注释到行尾
		if c == '#':
			while i < length and code[i] != '\n':
				i += 1
			continue
		# 跳过 @onready/@export 等注解(不匹配代码, 但避免误认其中的单词)
		if c == '@':
			while i < length and (_is_eval_id_char(code[i])):
				i += 1
			continue
		# 扫描一个标识符 token
		if _is_eval_id_char(c):
			var start := i
			while i < length and _is_eval_id_char(code[i]):
				i += 1
			var token := code.substr(start, i - start)
			# 单 token 危险类名(前缀匹配类名本身)
			for item in _EVAL_FORBIDDEN:
				var name: String = item[0]
				if "." in name:
					continue
				if token == name:
					return "代码包含被禁止的 API: %s (%s)。出于安全考虑不允许在 eval 中执行。" % [name, item[1]]
			# 成员访问: 检查后续是否为 .成员名(如 OS.execute), 支持空格与换行
			for item in _EVAL_FORBIDDEN:
				var name: String = item[0]
				if "." not in name:
					continue
				var parts := name.split(".")
				if token != parts[0]:
					continue
				# 跳过 . 与空白
				var j := i
				while j < length and (code[j] == ' ' or code[j] == '\t' or code[j] == '\n' or code[j] == '\r'):
					j += 1
				if j < length and code[j] == '.':
					j += 1
					var k := j
					while k < length and _is_eval_id_char(code[k]):
						k += 1
					if code.substr(j, k - j) == parts[1]:
						return "代码包含被禁止的 API: %s (%s)。出于安全考虑不允许在 eval 中执行。" % [name, item[1]]
			continue
		# 非标识符字符: 继续
		i += 1
	return ""


## 把用户 eval_code 规范成方法体缩进
##
## 与 precheck_eval_code 同源(它内部就调本函数), 故黑名单扫描与实际执行的文本必然一致 ——
## 分成两处实现时, "预检编译过的代码"与"真正跑的代码"可能不是同一份文本。
static func indent_method_body(code: String) -> String:
	var lines := code.split("\n")
	var out := PackedStringArray()
	for line in lines:
		var norm := _normalize_indent(line, 4)
		out.append("    " + norm)
	return "\n".join(out)


static func _normalize_indent(line: String, tab_w: int) -> String:
	var i := 0
	var spaces := 0
	while i < line.length():
		var c := line.unicode_at(i)
		if c == 9:
			spaces += tab_w
			i += 1
		elif c == 32:
			spaces += 1
			i += 1
		else:
			break
	var prefix := ""
	for j in spaces:
		prefix += " "
	return prefix + line.substr(i)


## ======= eval 接缝的可观测性 =======
##
## 判据(全仓库统一): **接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。**
## 本域属"注入 + 自带告警"那一档 —— mode/game_started_at/logger 是实例状态且不可推导,
## 没有自建选项; 那就只剩"让漏调看得见"这一条路。对照: log 域漏调返回"未就绪"是显式报错,
## validate 域因漏调会静默恒真而直接否决接缝。三种落法都对, 别为了统一而改。

## 把告警挂到响应上: 顶层 text 加前缀 + warnings 数组 + (有 structuredContent 时)结构化字段。
##
## 为什么要写三处而不是只写顶层: MCP 协议客户端读的是 content[], 顶层字段只有进程内逻辑
## 看得见(同 MCPResult.err 把元信息塞进 content[].text 的理由)。只平铺顶层等于
## "日志里有、用户看不见", 那正是本判据要消灭的形态。
##
## 唯一例外: 有 structuredContent 时 content[0].text 承载的是 JSON 载荷, 前面加一行文本
## 会破坏客户端对它的解析, 故那条路径改在 structuredContent 里加 warnings 字段 ——
## 声明了 outputSchema 的客户端读 structuredContent, 一样看得到。
static func _attach_warning(result: Dictionary, warning: String) -> Dictionary:
	if warning.is_empty():
		return result
	var out := result.duplicate(true)
	var line := warning if warning.begins_with("[") else ("[警告] " + warning)
	var warns: Array = []
	var prev: Variant = out.get("warnings", [])
	if prev is Array:
		warns.assign(prev)
	warns.append(line)
	out["warnings"] = warns
	out["text"] = line + "\n" + str(out.get("text", ""))
	var sc: Variant = out.get("structuredContent", null)
	if sc is Dictionary:
		sc["warnings"] = warns
		return out
	var content: Array = out.get("content", [])
	for item in content:
		if item is Dictionary and item.has("text"):
			item["text"] = line + "\n" + str(item["text"])
	return out


## 组装降级告警文案: "接缝降级"与"游戏侧守卫未生效"两条合并成可辨识的告警。
##
## 第二条不靠 ctx 而靠本地判据: MCPScriptSync._guard_runtime 在 baseline<=0 时直接
## _pass([])(全部放行), 而这种"通过"长得和真通过一模一样 —— 只有把"这次通过是无基准的放行"
## 写出来, 症状(问题查不出来)才有指向根因的线索。
##
## 不去改 MCPScriptSync: 它是多个域共用的判据模块, 给它加"降级感知"参数会把本域的接线问题
## 泄进公共层; 本域自己同时握着 mode 与 baseline, 自己判更准也更省。
static func _degraded_warning(mode: String, game_started_at: int, context: Dictionary) -> String:
	var reasons := PackedStringArray()
	if bool(context.get("degraded", false)):
		reasons.append("[eval-ctx 降级] " + str(context.get("reason", "")))
	if mode == MODE_RUNTIME and game_started_at <= 0:
		reasons.append("[守卫未生效] game_started_at<=0, 新鲜度守卫对本次 eval **全部放行**: 跑的是旧代码也不会被拦。编辑器侧按内容哈希判新鲜度, 不依赖该基准, 故此条只在游戏侧出现。")
	return "\n".join(reasons)


## 判断值是否为协程句柄(GDScriptFunctionState 未暴露给脚本类型系统, 用类名判断)
static func _is_function_state(v) -> bool:
	return v != null and v is Object and v.get_class() == "GDScriptFunctionState"


## 等待协程完成并把最终返回值写入 holder(fire-and-forget 调用)
static func _await_state(fs: Object, holder: Dictionary) -> void:
	var value = await fs
	holder.value = value
	holder.done = true


## eval 协程超时后的延迟回收: 自然结束后再释放求值实例(不掐死续体)
static func _reap_later(fs: Object, inst: Node) -> void:
	await fs
	if is_instance_valid(inst):
		inst.queue_free()


## ======= eval 附带错误降噪 =======
##
## 整簇搬进本域的理由: 忽略模式有**两条**上报路径共用(eval 的附带错误、通用 handler 的
## 诊断附加), 而"明明配了却仍然冒出来"正是过滤规则只生效在一条路径上的典型症状。拆散
## 就会重新制造那个坑。
##
## 内置噪音过滤模式, 在项目设置之外始终生效。
## Unrecognized UID + get_id_path 只在 UID 缓存未就绪/重建的那一瞬出现, 是 fs.scan() 的
## 已知副作用: 资源本身存在(否则 reload 会报资源缺失), 紧接着的重试就会成功。功能问题
## 已由 MCPScriptSync.resolve_scene_path 的重扫兜住, 这里只消掉噪音 —— 否则每次编辑器
## 重启后首次启动游戏都会冒一条, 让人和 AI 都误判成"启动失败"。
const BUILTIN_IGNORED_ERROR_PATTERNS := ["Unrecognized UID", "get_id_path"]


## 取生效的忽略模式: 内置默认 + 项目设置 dev_framework/mcp/ignored_error_patterns。
## 两条错误上报路径(eval 的附带错误、通用 handler 的诊断)共用它 —— 过滤规则只在一条
## 路径上生效的话, "明明配了却仍然冒出来"会变成极难排查的问题。
static func get_ignored_error_patterns() -> Array:
	var ignored: Array = BUILTIN_IGNORED_ERROR_PATTERNS.duplicate()
	# 设置项可能是真数组 / PackedStringArray / JSON 数组文本 / 逗号分隔文本(历史上两种坏值都存在),
	# as_string_array 一次覆盖这四种来源, 故这里不再逐形态分支。
	ignored.append_array(VariantTool.as_string_array(
		ProjectSettings.get_setting("dev_framework/mcp/ignored_error_patterns", null)))
	return ignored


## 判断一段诊断文本是否**全部**由被忽略的模式构成(供通用 handler 的诊断附加用)。
##
## 判据是"全部"而非"含": 只要混进任何其他错误就必须照常上报, 否则真错误会被一并吞掉 ——
## 那比多报一条噪音危险得多。空文本返回 false: 无内容不该被当成"已全部过滤"。
static func is_all_ignored(outcome: String, ignored: Array) -> bool:
	var has_line := false
	for line in outcome.split("\n"):
		var s := line.strip_edges()
		if s.is_empty():
			continue
		has_line = true
		var hit := false
		for p: String in ignored:
			if p != "" and s.contains(p):
				hit = true
				break
		if not hit:
			return false
	return has_line


## eval 附带错误降噪: 按 message+位置合并重复计数, 并应用忽略模式。
static func condense_runtime_errors(entries: Array) -> Array:
	var ignored := get_ignored_error_patterns()
	var merged: Array = []
	var index := {}
	for e: Dictionary in entries:
		var msg := str(e.get("message", ""))
		var skip := false
		for p in ignored:
			if p != "" and msg.contains(p):
				skip = true
				break
		if skip:
			continue
		var key := "%s|%s|%s" % [msg, str(e.get("file", "")), str(e.get("line", ""))]
		if index.has(key):
			merged[index[key]]["count"] = int(merged[index[key]]["count"]) + 1
		else:
			index[key] = merged.size()
			merged.append({"message": msg, "file": str(e.get("file", "?")), "line": str(e.get("line", "?")), "count": 1})
	return merged