@tool
extends RefCounted

## ======= 工具入参校验(落地 MCP 规范的 MUST validate all tool inputs) =======
##
## 与 MCPToolSchema(请求)、MCPResult(响应)同级的第三块协议契约, 由 MCPDevServer 以 preload
## 常量 `MCPArgCheck` 引用。同样带 @tool、不声明 class_name。
##
## ## 为什么不干脆让 VariantTool 报错
##
## VariantTool 的"转换失败返回缺省值"对**项目内可信数据**是对的, 换来 60+ 处调用点永不因类型
## 问题崩掉。但 MCP 的 arguments 是**不可信输入**, 规范对此是 MUST 级要求。静默降级在协议边界
## 上有两个坏处: 调用方无从纠正(既不算错误也没给线索), 以及降级后的值会**伪装成合法值** ——
## get_scene_tree 传 max_depth:"5" 会被转成 3 且 pruned_nodes:0, 模型据此认定"场景就这些",
## 带着错结论往下走, 比直接失败危险得多。
##
## 故两条规则并存: handler 内部一律走 VariantTool(要健壮), 协议入口先走本文件(要诚实)。
## 本文件只拦**硬错**, 不做"顺手转换" —— 那正是要把静默降级赶出协议边界的东西。
##
## ## 校验范围(刻意保守: 误报比漏报更伤, 一个总在误报的自检会被迅速无视)
##
## 只查三类, 每类都必然是调用方的错: required 缺失、enum 值不在枚举内(附合法取值)、
## 类型**族**不兼容(该类型根本无法承载该值)。
## 不查: 未知键(properties 并非封闭, 如 set_node_property 的 value 本就开放)、数值范围
## (交给客户端校验)、数字字符串→数字(项目内表单手填是常态, 真正不可转换的才算硬错)。

## 需要展开成普通 Array 而非原样接受的类型。
## 与 VariantTool._PACKED_TYPES 同源, 此处独立列出而不是引用: 那边是私有常量, 而共享它
## 会把两个本不相关的模块绑在一起 —— 为 6 个类型常量换来这种耦合不划算。
const _PACKED := [
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
]


## 校验一次 tools/call 的 arguments。返回问题描述数组(空 = 通过)。
## **只读, 绝不修改 args**: 校验层顺手"修正"参数, 会让调用方以为自己传对了, 下次继续错。
static func check(schema: Dictionary, args: Dictionary) -> Array[String]:
	var out: Array[String] = []
	_walk(schema, args, "", out)
	return out


static func _walk(schema: Dictionary, args: Dictionary, prefix: String, out: Array[String]) -> void:
	for key in VariantTool.as_string_array(schema.get("required", [])):
		var at := prefix + key
		if not args.has(key) or VariantTool.is_blank(args[key]):
			out.append('"%s" 是必填参数, 但未提供或为空。' % at)
	var props = schema.get("properties", {})
	if not props is Dictionary:
		return
	for key in props:
		# 省略的键交给 handler 用默认值处理 —— 在这一层报"缺失"会把所有可选参数变成必填。
		if not args.has(key):
			continue
		var v: Variant = args[key]
		var prop = props[key]
		if not prop is Dictionary:
			continue
		var at := prefix + str(key)
		var tname := str(prop.get("type", ""))
		if not _type_ok(v, tname):
			out.append('"%s" 期望 %s, 实际收到 %s。请直接传符合类型的 JSON 值: 数字不要加引号, 布尔不要写成字符串("true" 不是布尔)。' % [at, tname, _describe(v)])
			continue
		var legal: Variant = prop.get("enum", null)
		if legal is Array and not legal.has(v):
			out.append('"%s" 的值 %s 不在合法取值内。合法值: %s。' % [at, _describe(v), " / ".join(PackedStringArray(legal))])
			continue
		# 只递归显式声明了 properties 的嵌套对象。其余 object 参数(set_node_property 的
		# value、auto_verify 的 prev_snapshot)是刻意开放的, 把它们当定形字典校验只会误伤。
		if tname == "object" and prop.get("properties", null) is Dictionary:
			_walk(prop, v, at + ".", out)


## 值能否被该 schema 类型承载。未声明 type 的一律放行: 由"没写"推导出凭空冒出来的限制,
## 是本文件最不该犯的错。
static func _type_ok(v: Variant, tname: String) -> bool:
	match tname:
		"integer", "number":
			# 两者都收 int 与 float: JSON 本身区分不了 3 与 3.0, 解析器给出哪一种取决于客户端
			# 的写法。把 float 判成"integer 参数传错"是在惩罚序列化差异, 不是在纠错。
			return v is int or v is float
		"boolean":
			return v is bool
		"string":
			# 数字字符串放行(项目内表单手填的常态)。反过来必须报错: 数组/字典传给 string 参数时
			# VariantTool 会把它 str() 成 "[1, 2]", 于是报出 "文件不存在: [1, 2]" —— 参数错误
			# 被伪装成了资源错误, 从报错文本里完全看不出根因。
			return v is String or VariantTool.is_number(v)
		"array":
			return v is Array or typeof(v) in _PACKED
		"object":
			return v is Dictionary
	return true


## 报给调用方看的值描述。容器只报类型不展开: 展开只会刷屏, 且对"改掉这个参数"毫无帮助。
static func _describe(v: Variant) -> String:
	var t := type_string(typeof(v))
	if v is Array or v is Dictionary:
		return t
	var s := str(v)
	return t if s.is_empty() else '%s("%s")' % [t, s]
