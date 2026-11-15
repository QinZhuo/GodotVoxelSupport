@tool
extends RefCounted

## ======= 工具入参校验(落地 MCP 规范的 MUST validate all tool inputs) =======

## 需要展开成普通 Array 而非原样接受的类型。
const _PACKED := [
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
]


## 校验一次 tools/call 的 arguments。返回问题描述数组(空 = 通过)。
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
		if tname == "object" and prop.get("properties", null) is Dictionary:
			_walk(prop, v, at + ".", out)


## 值能否被该 schema 类型承载。未声明 type 的一律放行: 由"没写"推导出凭空冒出来的限制,
static func _type_ok(v: Variant, tname: String) -> bool:
	match tname:
		"integer", "number":
			# 两者都收 int 与 float: JSON 本身区分不了 3 与 3.0, 解析器给出哪一种取决于客户端
			return v is int or v is float
		"boolean":
			return v is bool
		"string":
			# 数字字符串放行(项目内表单手填的常态)。反过来必须报错: 数组/字典传给 string 参数时
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
