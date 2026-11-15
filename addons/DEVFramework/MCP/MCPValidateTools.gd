@tool
extends RefCounted

## ======= 脚本/资源校验域 =======
## 从 MCPDevServer 拆出的工具域文件, 沿 MCPCodeIndex 的样板。收录"不信任声明、要实测"这一类能力:
##   - validate        统一验证入口(kind=script 编译校验 / kind=resource 资源可加载性)
##   - classdb_query   查 Godot 原生类 API(写脚本前确认方法/属性/信号签名)
##   - MCPResult      响应封装
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 本域私有的编译错误捕获器。**刻意不共用 MCPDevServer 的那个**, 理由见下方"编译错误从哪来";
static var _compile_log: MCPLogger = null


## ======= 编译错误从哪来: 为什么本域自建一个 MCPLogger =======
## **接缝判据(全局统一, 不是本域的偏好)**: 接缝可以存在, 但漏调必须可见; 漏调会静默失效的
## 本域有两处接缝, 按判据给出**不同**答案, 且都正确 —— 不要为了"看起来统一"去改其中任何一处:
##   - 编译错误捕获器 → 域内自建: 漏调后果是编译错误捕获不到、validate 恒返回 valid=true,
##     **静默失效**(把编译失败的代码报成合法), 故必须否决接缝。

## 取本域私有的编译错误捕获器(首次调用时创建并注册到 OS)。
##    · get_error_cursor() 只取本实例环形缓冲 `_errors` 的写指针, 不动缓冲内容;
##    · take_errors_since(since) 只按"下标 >= since"读**一段区间**, 不删除数组元素;
##    · 唯一的破坏性路径是 clear_errors(), 本编译路径**没有**调用它。
## **因此不要因为看起来"重复注册"就删掉其中任何一个:**
static func _compile_error_log() -> MCPLogger:
	if _compile_log == null:
		_compile_log = MCPLogger.new()
		OS.add_logger(_compile_log)
	return _compile_log


## ======= 域注册入口 =======
## 满足判据前半句"漏调必须可见"。MCPCodeIndex.register 是同形状、同结论, 各域一致。
## (如本域的 logger)才必须改成域内自建或补告警; 前者(如本函数)可留接缝, 但别误以为
## **当前状态(实测)**: 主文件 `_register_validate_tools()` 的函数体只剩一行
##   · MCPDevServer._add_tool 里 `_tool_handlers[name]` / `_tool_schemas[name]` 是 **Dictionary**,
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
