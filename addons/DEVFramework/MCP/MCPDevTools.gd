@tool
extends RefCounted

## ======= 开发辅助域 =======
## 从 MCPDevServer 拆出的工具域, 收录"在宿主进程里就地执行开发动作"的能力。**本文件必须导出安全**
##   · 只留 eval_code(唯一运行时可用的开发辅助工具);
##   · restart_editor / script_status 依赖 EditorInterface / MCPScriptSync, 已拆到 MCPDevToolsEditor。
##   - MCPResult      响应封装
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 模式标识。**本文件必须导出安全**(运行时服务器要注册 eval_code), 故不能 preload 含编辑器引用的
const MODE_EDITOR := "editor"
const MODE_RUNTIME := "runtime"

## eval 上下文提供器: 无参 Callable, 返回 {mode, game_started_at, logger}。
static var _eval_ctx_provider: Callable = Callable()


## 注入 eval 运行上下文的提供器(无参 Callable, 返回上面那三个键, 见 EVAL_CTX_KEYS)。
## 服务器须在**编辑器与游戏两个进程分支都调一次**, 不能只依赖 register():
## 判据是"接缝可以存在, 但漏调必须可见" —— 漏调最隐蔽的代价是守卫静默失效后症状变成
static func set_eval_ctx_provider(provider: Callable) -> void:
	_eval_ctx_provider = provider


## ======= eval 实现(注册不在此) =======


## ======= 开发辅助工具实现 =======

## 取宿主进程的场景树。static 上下文没有 get_tree(), 故经 Engine 取主循环
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## resolve_eval_ctx 必须拿到**真值**的三个键。列成常量而非散在各处写字符串,
const EVAL_CTX_KEYS := ["mode", "game_started_at", "logger"]

## 降级文案里的"后果说明": 让看到告警的人立刻知道漏了这一项会怎样, 而不只是"少了这一项"。
const EVAL_CTX_DEGRADED_HINT := "后果: game_started_at 缺失使新鲜度守卫全部放行(跑旧代码也不拦); logger 缺失使运行期错误一条不捕获; mode 缺失使守卫走错判据分支。修法: 在服务器侧(编辑器与游戏两个进程分支都要)调用 MCPDevTools.set_eval_ctx_provider(...)。"


## 取本次 eval 用的运行上下文: provider 现取现用, [param override] 非空时按键覆盖。
## ## 为什么这里必须有接缝
## 域内自建物理上不存在, 只能注入。判据"接缝可以存在, 但漏调必须可见; 漏调会静默失效的
static func resolve_eval_ctx(override: Dictionary = {}) -> Dictionary:
	var out := {
		"mode": MODE_EDITOR if Engine.is_editor_hint() else MODE_RUNTIME,
		"game_started_at": 0,
		"logger": null,
	}
	# 来源记账: out 的初值是"推导值"而非真值。降级判定必须按"哪些键拿到了真值"来算 ——
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
## 另注: 主文件那份 _call_eval_code 必须删干净 —— 同名会让自检按字典序切到
static func _call_eval_code(args: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var code: String = VariantTool.get_string(args, "code")
	if code.is_empty():
		return MCPResult.fail("必须提供 code")
	var context := resolve_eval_ctx(ctx)
	var mode := str(context.get("mode", MODE_EDITOR))
	var game_started_at := int(context.get("game_started_at", 0))
	var logger: Object = context.get("logger", null)
	# 降级告警在**每一条**返回路径上都要带上(含错误路径): 守卫误判时 eval 是失败的,
	var warn := _degraded_warning(mode, game_started_at, context)
	var tree := _tree()
	# 顺序: 新鲜度守卫排在预检**之前**, 让预检基于已同步的缓存判断, 免得为一个
	# 注意这**不是**全局类能热切换的原因 —— 实测调整顺序无效: 缓存确实换新了,
	# (原因与实测过程见 MCPScriptSync._guard_runtime)。
	# 含编辑器引用不能 preload。故按特征标签分流 —— 非编辑器构建直接跳过守卫(ok=true)。
	var guard := {"ok": true}
	if Engine.is_editor_hint() or OS.has_feature("editor"):
		var sync: Variant = load("res://addons/DEVFramework/MCP/MCPScriptSync.gd")
		if sync != null:
			guard = await sync.guard_eval(mode, game_started_at, tree)
	if not bool(guard.get("ok", true)):
		# category 由守卫按失败原因判定(编辑器侧=磁盘脚本语法错, 游戏侧=跑的是旧代码)。
		return _attach_warning(MCPResult.err(str(guard.get("message", "")), str(guard.get("category", MCPResult.CAT_STALE_CODE)),
			bool(guard.get("retryable", false)), str(guard.get("recovery", ""))), warn)
	# 预处理(长度/安全扫描/语法编译)**只做一次**, 并把编译好的脚本返回来直接执行 ——
	var prep := _prepare_eval(code, logger)
	if not bool(prep.get("ok", false)):
		return _attach_warning(MCPResult.err_validation(str(prep.get("error", "")),
			"修正代码语法后重新调用 eval(语法错误无法通过重试解决)"), warn)
	var script: GDScript = prep.get("script")
	# 执行前记录错误游标, 以便捕获本次 eval 运行期错误(用逻辑游标, 环形缓冲满后仍正确)。
	var err_before: int = logger.get_error_cursor() if logger else 0
	var inst: Node = script.new()
	if inst == null:
		return _attach_warning(MCPResult.err_internal("无法实例化求值脚本", "重新调用 eval, 或检查服务器日志"), warn)
	var root := tree.root if tree != null else null
	if root:
		root.add_child(inst)
	var result: Variant = inst.call("_mcp_run")
	# await 感知: 代码含 await 时 call 返回协程句柄, 等待其完成再回传真实结果(带超时)。
	if AsyncTool.is_coroutine(result):
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
	# 否则编辑器侧只能等代理超时(_game_call_timeout_ms)再回查错误缓冲, AI 无法及时定位。
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
		return _attach_warning(MCPResult.err_validation(
					"eval 执行返回: %s\n执行中捕获 %d 条运行期错误(合并后 %d 类, 前 %d 类):\n%s\n\n提示: get_node() 相对路径基于 eval 脚本实例, 找不到节点常因路径写错, 建议用绝对路径(/root/场景名/...) 或 get_tree().current_scene.get_node(...)。完整错误列表可用 %s; 重复噪音可在项目设置 dev_framework/mcp/ignored_error_patterns 配置子串忽略。" %
			# 上面这些错误取自**本进程**的 logger 游标, 故按模式指向对应进程的日志。
			[shown, runtime_errors.size(), merged.size(), max_show, "\n".join(msgs),
				"get_logs(process=game,kind=error)" if mode == MODE_RUNTIME else "get_logs(process=editor,kind=error)"],
			"修正 eval 代码中的错误后重试"), warn)
	return _attach_warning(MCPResult.ok("执行成功, 返回: %s" % shown), warn)


## ======= eval 代码预检(与主文件共用) =======

## 预检 eval 代码(供"编辑器侧转发前拦截"用): 返回 "" 表示通过, 否则错误描述。
##   (否则调用方只得到笼统的 "Parse error", 还得再去 get_logs 翻具体行)。
static func precheck_eval_code(code: String, logger: Object = null) -> String:
	var prep := _prepare_eval(code, logger)
	return "" if bool(prep.get("ok", false)) else str(prep.get("error", ""))


## eval 代码的**唯一**预处理: 长度校验 + 安全扫描 + 语法预编译。
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
static func _parse_error_details(logger: Object, cursor: int) -> String:
	if logger == null:
		return "(详细解析错见 get_logs(kind=error))"
	return str(logger.describe_errors_since(cursor))


## 静态扫描 eval 代码中被禁止的 API, 返回 "" 表示通过。
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
	var i := 0
	var length := code.length()
	while i < length:
		var c := code[i]
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
		# 跳过字符串字面量 ' " (含转义) 和""" 长字符串