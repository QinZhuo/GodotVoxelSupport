@tool
extends RefCounted

## ======= 工具结果封装内核 =======
##
## 由 MCPDevServer 以 preload 常量 `MCPResult` 引用。**必须带 @tool 且不声明 class_name**。
##
## 这里是 **MCP 协议边界**: 响应形状(content/isError/structuredContent)与错误分类是外部契约,
## 一旦有第二个消费者(测试、其他工具层)就该能直接复用, 而不必去服务器里翻。它也是全服务器
## 唯一零状态依赖的部分 —— 所有 handler 都调它, 它不调任何人, 故可独立演进、独立单测。
##
## MCPDevServer 侧保留同名薄转发(_ok/_err_*/_err), 于是 50+ 个调用点无需改动。
## 分类常量请写 MCPResult.CAT_*(唯一定义处在此)。

## error_category 取值(唯一定义处)。新代码请用下面的**语义化封装**, 不要拼裸字符串 ——
## 裸字符串最大的代价是 retryable 由调用点随手决定: 同一类别时而可重试时而不可,
## 调用方无法据此决策, 于是干脆一律重试, 这个字段就白传了。
const CAT_VALIDATION := "validation"      # 输入/代码问题: 同参数重试永远失败(改参数后重试有效)
const CAT_TRANSIENT := "transient"        # 暂时性故障(超时/未就绪): 等待后重试可能成功
const CAT_GAME_STOPPED := "game_stopped"  # 游戏进程已结束/崩溃: 必须重启游戏
const CAT_GAME_BREAKED := "game_breaked"  # 游戏被调试器暂停(脚本错误/断点): 进程活着但主循环停着
const CAT_STALE_CODE := "stale_code"      # 代码已改动而本进程跑的是旧版: 需重启对应进程
const CAT_INTERNAL := "internal"          # 服务器内部错误: 不应重试同参数
##
## game_breaked 单列而不并入 transient: 后者只需"等等再试", 而它要求先 get_game_errors 定位、
## game_control(action=continue) 解除暂停。合并会让 AI 用"等待"应对一个必须人工介入的状态。


## 统一工具结果封装
## 函数名是 make 而不是 wrap: GDScript 有全局内建 wrap(value, min, max), 与本函数重名。撞名后
## 分析器会把调用解析到全局 wrap, "4 参调用"被报成 Too many arguments —— 而缺 @tool 时这行代码
## 连语义分析都不做, 静态检查全绿, 直到运行时才以 "Nonexistent function" 全线崩掉。
##
## 同时输出 MCP 标准字段(content 数组 + 驼峰 isError)与自定义字段(text/is_error), 后者**只在
## 进程内流转**, 由 for_protocol 在出协议边界前剥掉。extra 追加结构化字段; content_text 用于让
## content[].text 与顶层 text 不同(顶层保持纯文本给内部逻辑, 协议客户端读 content[])。
static func make(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	var out := {
		"text": text,
		"is_error": is_error,
		"isError": is_error,
		"content": [ {"type": "text", "text": content_text if not content_text.is_empty() else text}],
	}
	for key in extra:
		out[key] = extra[key]
	return out


static func ok(text: String) -> Dictionary:
	return make(text, false)


## 简写失败封装: 分类固定为 validation, 但**不**把元数据塞进 content[].text。
##
## 分层依据是"元数据会不会改变调用方行为": 会改变的(is_retryable / recovery 决定下一步该重试
## 还是重启)必须进 content[], AI 看不到就会盲目重试; 不会改变的(validation 类 message 本身已
## 自带修复方向)再附分类只增 token。因此 100+ 处简单错误统一走 fail, 只有真正需要区分重试
## 策略的少数情况才显式用 err_*。
static func fail(text: String) -> Dictionary:
	return make(text, true, {
		"error_category": CAT_VALIDATION,
		"is_retryable": false,
		"structuredContent": {
			"message": text,
			"error_category": CAT_VALIDATION,
			"is_retryable": false,
		},
	})


## 结构化结果封装: 数据同时以 structuredContent 与 content[].text(序列化 JSON, 向后兼容)
## 输出。数据先经 JSON 往返, 把 NodePath/Vector2/Color 等 Variant 转成 JSON 兼容类型,
## 保证 structuredContent 是纯 JSON 对象。
static func ok_json(data: Dictionary) -> Dictionary:
	var json := JSON.stringify(data)
	var safe_data: Variant = JSON.parse_string(json)
	if not safe_data is Dictionary:
		safe_data = data
	return make(json, false, {"structuredContent": safe_data})


## 正文与结构化元信息**分离**的封装(补 ok_json 的缺口)。
##
## ok_json 的正文由 data 序列化而来, 想同时给可读正文和元信息时正文只能也塞进 data ——
## 于是一份正文在响应里出现**三次**(顶层 text / content[].text / structuredContent)。实测
## get_scene_tree 带 tree 时三份合计约 27 万字符, 即使正文已截断到上限, structuredContent 里
## 那份完整的仍让响应体纹丝不动, 截断形同虚设。
##
## 分工: ok_json(data) 用于"数据即正文"; ok_with_meta(t, m) 用于正文是大段可读文本、m 只放
## 标量元信息(节点总数、是否被截断), 供调用方判断要不要续读。meta 同样经 JSON 往返。
static func ok_with_meta(text: String, meta: Dictionary) -> Dictionary:
	var safe_meta: Variant = {}
	if not meta.is_empty():
		var parsed: Variant = JSON.parse_string(JSON.stringify(meta))
		if parsed is Dictionary:
			safe_meta = parsed
	return make(text, false, {"structuredContent": safe_meta})


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。
## 这几个是新增代码的推荐入口(它把"该不该重试"这个判断从 50+ 个调用点收敛到一处)。


static func err_validation(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_VALIDATION, false, recovery)


static func err_transient(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_TRANSIENT, true, recovery)


static func err_game_stopped(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_GAME_STOPPED, true, recovery)


## 游戏被调试器暂停。recovery 允许覆盖: "错误缓冲无内容"那条分支说的是"缓冲没读到、需你手动
## 复核", 措辞该不同 —— 统一的是接口与分类, 不是把有意义的差异也抹平。
##
## 默认 recovery 只提 game_control(action=...), 不提独立工具名: 客户端把哪些工具映射成可调用
## 入口由**它**决定, 服务端 tools/list 里有 ≠ 调得到。曾默认写 debug_continue(当时是独立工具),
## 而客户端映射里没有它 —— 恢复路径在最需要它的时刻(游戏出错)才发现是断的。
static func err_game_breaked(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_GAME_BREAKED, true,
		recovery if not recovery.is_empty() else "get_game_errors查错后game_control(action=continue); 或game_control(action=stop)修复重启")


static func err_stale_code(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_STALE_CODE, true, recovery)


## recovery 可省略(传空串等价): 省略时退回通用的"看日志"指引。需要具体下一步的调用点应显式给出。
static func err_internal(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_INTERNAL, false,
		recovery if not recovery.is_empty() else "查看编辑器控制台或调用 get_logs 获取详情。")


## 底层结构化错误封装。category 取值见 CAT_*; retryable 由语义化封装固化, 仅当它需按上下文
## 动态决定(如新鲜度守卫的 category 透传)时才直接调用。
##
## 元数据必须进 content[].text, 不能只平铺在顶层: 协议客户端读的是 content[], 只平铺在顶层的话
## category / is_retryable / recovery 对 AI 不可见 —— AI 只读到一句 message 于是照旧盲目重试,
## 而消除盲目重试正是这些字段存在的理由。
##
## structuredContent 也填: 规范要求"声明了 outputSchema 就 MUST 提供合规 structuredContent",
## 全部工具都声明了, 错误路径同样受约束。它曾刻意留空(怕不判 is_error 就读 sc 的几处把明确的
## "error" 静默读成 "unknown"), 该阻碍已清除 —— 四处读取点均已加 is_error 分流。
## data 未做 JSON 往返: 这里全是 String/bool, 本就纯 JSON。
static func err(text: String, category: String, retryable: bool, recovery: String) -> Dictionary:
	var data := {
		"message": text,
		"error_category": category,
		"is_retryable": retryable,
		"recovery": recovery,
	}
	return make(text, true, {
		"error_category": category,
		"is_retryable": retryable,
		"recovery": recovery,
		"structuredContent": data,
	}, JSON.stringify(data))


## ======= 协议边界净化 =======
##
## 剥掉仅供进程内逻辑使用的顶层字段(text / is_error), 得到可直接发往客户端的 result。
##
## 为什么必须剥: 这两个字段**不是 MCP 协议字段**(50+ 处内部逻辑读它们), 而 text 与
## content[0].text 在 content_text 为空时**逐字节相同** —— 每次调用都要把同一份正文传两遍。
## 实测 read_file 读 MCPDevServer.gd(33K 正文): 响应 74336 字符, 其中 33353 是纯重复, 占
## 45%。这个成本每次调用都付, 是整个 MCP 通道最大的单点浪费(约 1.7 万 token 换零信息)。
##
## 为什么不从 make() 里直接不产出: 内部逻辑读这两个字段, 且它们在日志与错误分类判定里有真实
## 用途(is_error 决定走哪条日志分支)。故保留产出、只在边界剥离: 内部零影响, 协议层干净。
## 本函数幂等, 调用点可无条件套用。
static func for_protocol(result: Dictionary) -> Dictionary:
	if not result.has("text") and not result.has("is_error"):
		return result
	var out := result.duplicate()
	out.erase("text")
	out.erase("is_error")
	return out
