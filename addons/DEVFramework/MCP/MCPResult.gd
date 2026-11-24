@tool
extends RefCounted

## ======= 工具结果封装内核 =======
## 由 MCPDevServer 以 preload 常量 `MCPResult` 引用。**必须带 @tool 且不声明 class_name**。
## 零状态依赖: 所有 handler 都调它, 它不调任何人。

## error_category 取值(唯一定义处)。新代码用下面的**语义化封装**, 不要拼裸字符串。
## game_breaked 的恢复入口是 game_control(action=continue); 与 game_stopped 分开的理由:
## 一个只能人工介入, 一个重启即可。
const CAT_VALIDATION := "validation"      # 输入/代码问题: 同参数重试永远失败(改参数后重试有效)
const CAT_TRANSIENT := "transient"        # 暂时性故障(超时/未就绪): 等待后重试可能成功
const CAT_GAME_STOPPED := "game_stopped"  # 游戏进程已结束/崩溃: 必须重启游戏
const CAT_GAME_BREAKED := "game_breaked"  # 游戏被调试器暂停(脚本错误/断点): 进程活着但主循环停着
const CAT_STALE_CODE := "stale_code"      # 代码已改动而本进程跑的是旧版: 需重启对应进程
const CAT_INTERNAL := "internal"          # 服务器内部错误: 不应重试同参数


## 统一工具结果封装
static func make(text: String, is_error: bool, extra: Dictionary = {}, content_text: String = "") -> Dictionary:
	var out := {
		"text": text,
		"is_error": is_error,
		"isError": is_error,
		"content": [ {"type": "text", "text": content_text if not content_text.is_empty() else text}],
		# 【协议契约】MCP 2025-06-18 起: 工具一旦在 tools/list 声明 outputSchema(MCPToolMeta 对
		# 所有工具一律声明 {"type":"object"}), 则**每个**结果都必须带 structuredContent,
		# 否则合规客户端会判成 -32600 InvalidRequest。故这里无条件塞一份。
		"structuredContent": {},
	}
	for key in extra:
		out[key] = extra[key]
	return out


static func ok(text: String) -> Dictionary:
	return make(text, false)


## 简写失败封装: 分类固定为 validation, 不把元数据塞进 content[].text。
## 需要调用方改变行为的提示必须进 content[] —— 看不到就会盲目重试。
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


## 结构化结果封装: 数据同时以 structuredContent 与 content[].text(序列化 JSON, 向后兼容)。
## 不做 JSON 往返: Godot 的 JSON 解析把**所有**数字变成 float(node_count=5 -> 5.0),
## 客户端按 schema 的 "type":"integer" 会判为不符合。duplicate 一份即可保住 int。
static func ok_json(data: Dictionary) -> Dictionary:
	return make(JSON.stringify(data), false, {"structuredContent": data.duplicate(true)})


## 正文与结构化元信息**分离**的封装(补 ok_json 的缺口)。
## 标量元信息(节点总数、是否被截断)供调用方判断要不要续读; meta 同样 duplicate, 理由见 ok_json。
static func ok_with_meta(text: String, meta: Dictionary) -> Dictionary:
	return make(text, false, {"structuredContent": meta.duplicate(true)})


## 把已落盘的 PNG 附到结果里, 让"画面感知"一步到位(否则调用方还得再读一次图)。
## 超限时不报错(图已落盘, 路径仍在结果里), 只把原因写进 image_omitted ——
## 静默丢弃会让调用方以为"这图就是黑的"。
const MAX_INLINE_IMAGE_BYTES := 1572864

static func attach_image(result: Dictionary, path: String, mime: String = "image/png") -> Dictionary:
	if bool(result.get("is_error", false)) or path.is_empty():
		return result
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		result["image_omitted"] = "读不到图片字节: %s" % path
		return result
	if bytes.size() > MAX_INLINE_IMAGE_BYTES:
		result["image_omitted"] = "图片 %d 字节超过内联上限 %d, 已只回路径(可缩小 max_width 重试)" % [
			bytes.size(), MAX_INLINE_IMAGE_BYTES]
		return result
	var content: Array = result.get("content", [])
	content.append({"type": "image", "data": Marshalls.raw_to_base64(bytes), "mimeType": mime})
	result["content"] = content
	return result


## 工具返回"资源链接"(规范 content 类型 resource_link): 让大段文档走 resources 通道。
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


## 游戏被调试器暂停。recovery 允许覆盖: "错误缓冲无内容"分支要说明需手动读取。
static func err_game_breaked(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_GAME_BREAKED, true,
		recovery if not recovery.is_empty() else "get_logs(process=game,kind=error)查错后game_control(action=continue); 或game_control(action=stop)修复重启")


static func err_stale_code(text: String, recovery: String) -> Dictionary:
	return err(text, CAT_STALE_CODE, true, recovery)


## recovery 可省略(传空串等价): 省略时退回通用的"看日志"指引。需要具体下一步的调用点应显式给出。
static func err_internal(text: String, recovery: String = "") -> Dictionary:
	return err(text, CAT_INTERNAL, false,
		recovery if not recovery.is_empty() else "查看编辑器控制台或调用 get_logs 获取详情。")


## 底层结构化错误封装。category 取值见 CAT_*; retryable 由语义化封装固化。
## 元数据必须进 content[].text, 不能只平铺顶层 —— 协议客户端读的是 content[]。
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
## text / is_error 不是 MCP 协议字段(进程内逻辑读它们), 且与 content[0].text 逐字节重复;
## 不剥等于每次调用把同一份正文传两遍, 大响应里占比接近一半。
static func for_protocol(result: Dictionary) -> Dictionary:
	if not result.has("text") and not result.has("is_error"):
		return result
	var out := result.duplicate()
	out.erase("text")
	out.erase("is_error")
	return out
