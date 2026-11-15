@tool
extends RefCounted

## ======= 工具结果封装内核 =======
## 由 MCPDevServer 以 preload 常量 `MCPResult` 引用。**必须带 @tool 且不声明 class_name**。
## 唯一零状态依赖的部分 —— 所有 handler 都调它, 它不调任何人, 故可独立演进、独立单测。
## 分类常量请写 MCPResult.CAT_*(唯一定义处在此)。

## error_category 取值(唯一定义处)。新代码请用下面的**语义化封装**, 不要拼裸字符串 ——
const CAT_VALIDATION := "validation"      # 输入/代码问题: 同参数重试永远失败(改参数后重试有效)
const CAT_TRANSIENT := "transient"        # 暂时性故障(超时/未就绪): 等待后重试可能成功
const CAT_GAME_STOPPED := "game_stopped"  # 游戏进程已结束/崩溃: 必须重启游戏
const CAT_GAME_BREAKED := "game_breaked"  # 游戏被调试器暂停(脚本错误/断点): 进程活着但主循环停着
const CAT_STALE_CODE := "stale_code"      # 代码已改动而本进程跑的是旧版: 需重启对应进程
const CAT_INTERNAL := "internal"          # 服务器内部错误: 不应重试同参数
##
## game_control(action=continue) 解除暂停。合并会让 AI 用"等待"应对一个必须人工介入的状态。


## 统一工具结果封装
static func make(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	var out := {
		"text": text,
		"is_error": is_error,
		"isError": is_error,
		"content": [ {"type": "text", "text": content_text if not content_text.is_empty() else text}],
		# 【协议契约】MCP 2025-06-18 起: 工具一旦在 tools/list 声明 outputSchema(MCPToolMeta 对
		# 所有工具一律声明 {"type":"object"}), 则**每个**结果都必须带符合该 schema 的
		# structuredContent —— 否则合规客户端会把它判成 -32600 InvalidRequest(实测: 报错时正常、
		"structuredContent": {},
	}
	for key in extra:
		out[key] = extra[key]
	return out


static func ok(text: String) -> Dictionary:
	return make(text, false)


## 简写失败封装: 分类固定为 validation, 但**不**把元数据塞进 content[].text。
## 还是重启)必须进 content[], AI 看不到就会盲目重试; 不会改变的(validation 类 message 本身已
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
static func ok_json(data: Dictionary) -> Dictionary:
	var json := JSON.stringify(data)
	var safe_data: Variant = JSON.parse_string(json)
	if not safe_data is Dictionary:
		safe_data = data
	return make(json, false, {"structuredContent": safe_data})


## 正文与结构化元信息**分离**的封装(补 ok_json 的缺口)。
## 于是一份正文在响应里出现**三次**(顶层 text / content[].text / structuredContent)。实测
## 标量元信息(节点总数、是否被截断), 供调用方判断要不要续读。meta 同样经 JSON 往返。
static func ok_with_meta(text: String, meta: Dictionary) -> Dictionary:
	var safe_meta: Variant = {}
	if not meta.is_empty():
		var parsed: Variant = JSON.parse_string(JSON.stringify(meta))
		if parsed is Dictionary:
			safe_meta = parsed
	return make(text, false, {"structuredContent": safe_meta})


## 工具返回"资源链接"(规范 content 类型 resource_link): 让大段文档走 resources 通道, 而不是
static func resource_link(uri: String, name: String, mime_type: String, text: String, description: String = "") -> Dictionary:
	var link := {"type": "resource_link", "uri": uri, "name": name, "mimeType": mime_type}
	if not description.is_empty():
		link["description"] = description
	var out := make(text, false)
	out["content"] = [{"type": "text", "text": text}, link]
	return out


## 语义化错误封装: retryable 由类别固化, 调用方只负责给出恢复动作。


static func err_validation(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_VALIDATION, false, recovery)


static func err_transient(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_TRANSIENT, true, recovery)


static func err_game_stopped(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_GAME_STOPPED, true, recovery)


## 游戏被调试器暂停。recovery 允许覆盖: "错误缓冲无内容"那条分支说的是"缓冲没读到、需你手动
static func err_game_breaked(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_GAME_BREAKED, true,
		recovery if not recovery.is_empty() else "get_logs(process=game,kind=error)查错后game_control(action=continue); 或game_control(action=stop)修复重启")


static func err_stale_code(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_STALE_CODE, true, recovery)


## recovery 可省略(传空串等价): 省略时退回通用的"看日志"指引。需要具体下一步的调用点应显式给出。
static func err_internal(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_INTERNAL, false,
		recovery if not recovery.is_empty() else "查看编辑器控制台或调用 get_logs 获取详情。")


## 底层结构化错误封装。category 取值见 CAT_*; retryable 由语义化封装固化, 仅当它需按上下文
## 元数据必须进 content[].text, 不能只平铺在顶层: 协议客户端读的是 content[], 只平铺在顶层的话
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
## 为什么必须剥: 这两个字段**不是 MCP 协议字段**(50+ 处内部逻辑读它们), 而 text 与
## 实测 read_file 读 MCPDevServer.gd(33K 正文): 响应 74336 字符, 其中 33353 是纯重复, 占
static func for_protocol(result: Dictionary) -> Dictionary:
	if not result.has("text") and not result.has("is_error"):
		return result
	var out := result.duplicate()
	out.erase("text")
	out.erase("is_error")
	return out
