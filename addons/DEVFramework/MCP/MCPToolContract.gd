@tool
extends RefCounted

## ======= 工具契约: 请求 schema 工厂 + 入参校验 =======

## search_symbols 的 kind 合法取值(schema enum 与 handler 校验共用)。
const SEARCH_KIND := ["all", "function", "variable", "class", "signal", "export", "shader", "node", "resource", "ref"]

## 进程维度工具的 process 合法取值(schema enum 与 handler 校验共用)。
const PROCESS := ["editor", "game"]

## ======= schema 工厂 =======

## 进程维度工具共用的 process 参数(必填)。
static func process_arg(desc: String = "") -> Dictionary:
	return {
		"type": "string",
		"enum": PROCESS,
		"description": desc if not desc.is_empty() else "在哪个进程执行: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。",
	}

## 通用字符串参数。
static func str_arg(desc: String) -> Dictionary:
	return {"type": "string", "description": desc}

## 通用文件路径描述(多处文案相同)。
const _FILE_PATH_DESC := "文件路径(res:// 或 user://)"

## 无参工具的标准 schema。
static func no_arg() -> Dictionary:
	return {"type": "object", "properties": {}}

## code 参数的默认文案, 集中在此以免转发层再抄一份。
const _CODE_ARG_DEFAULT := "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"

## code 参数。
static func code_arg(desc: String = "") -> Dictionary:
	return str_arg(desc if not desc.is_empty() else _CODE_ARG_DEFAULT)

## eval_code 的等待上限。
static func code_timeout_arg() -> Dictionary:
	return {"type": "integer", "description": "可选: 含await代码的等待上限毫秒, 默认 8000, 上限 15000"}

## 文件写类工具的预演参数。
static func dry_run_arg() -> Dictionary:
	return {"type": "boolean", "description": "预演模式: true=只返回将要发生的改动(目标是否存在/大小/是否覆盖), **不做任何实际改动**, 默认 false"}

## 单路径工具 schema(with_dry_run=true 时附带 dry_run)。
static func file_path(path_desc: String, with_dry_run: bool = false) -> Dictionary:
	var props := {"path": str_arg(path_desc)}
	if with_dry_run:
		props["dry_run"] = dry_run_arg()
	return {"type": "object", "properties": props, "required": ["path"]}

## read_file: path + 字符游标 + probe(只探测存在性, 不值得为它常驻一个工具)。
static func read_file() -> Dictionary:
	return {"type": "object", "properties": {
		"path": str_arg(_FILE_PATH_DESC),
		"probe": {"type": "boolean", "description": "只探测存在性, 不读取内容: 返回 exists/is_file/is_directory/size。默认 false"},
		"offset": {"type": "integer", "minimum": 0, "description": "起始字符下标, 默认 0。**单位是字符不是字节**, 与 next_char_offset 同单位"},
		"limit": {"type": "integer", "minimum": 1, "description": "本次最多返回的字符数, 默认 0=不限(仍受全局输出上限约束)。被上限截断时按 next_char_offset 续读"},
	}, "required": ["path"]}

## 文件写入 schema(mode 决定覆盖还是追加)。
static func write_content() -> Dictionary:
	return {"type": "object", "properties": {
		"path": str_arg(_FILE_PATH_DESC),
		"content": {"type": "string", "description": "要写入/追加的内容"},
		"mode": {"type": "string", "enum": ["overwrite", "append"], "description": "写入模式, 默认 overwrite=整份覆盖(不可撤销); append=追加到末尾(目标不存在则创建)"},
		"dry_run": dry_run_arg(),
	}, "required": ["path", "content"]}

## 场景内节点路径参数(读/写/调方法/删节点共用)。
static func node_path() -> Dictionary:
	return str_arg("节点路径(编辑场景内), 如 'Main' 或 'Main/Player'")

## clear_logs: 与 get_logs 同域, 但参数集不同(它是"清"), 故不复用 logs()。
static func clear_logs() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"process": process_arg("清哪个进程的缓冲: editor=编辑器进程; game=游戏进程(需游戏运行; 导出运行时=本进程)。必填。"),
			"scope": {"type": "string", "enum": ["all", "logs", "errors"], "description": "清理范围, 默认 all"},
		},
		"required": ["process"],
	}

## get_logs 的 schema: 该工具独有参数(extra)在前, 游标参数在后, 同名以游标参数为准。
static func logs(default_max: String, unit: String, extra: Dictionary = {}) -> Dictionary:
	var props := extra.duplicate(true)
	props["max"] = {"type": "integer", "minimum": 1, "description": "最多条数(合并后), 默认 %s" % default_max}
	props["since"] = {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的%s, 默认 0=全量" % unit}
	props["contains"] = {"type": "string", "description": "按 message 子串过滤(大小写敏感), 只返回含该子串的条目。缓冲动辄上百条, 没有它就只能全量拉取再人眼扫。过滤先于 max 截断, 故语义是'全部%s中匹配的, 最多 max 条'" % unit}
	props["merge"] = {"type": "boolean", "description": "是否合并连续重复%s, 默认 true" % unit}
	return {"type": "object", "properties": props}

## ======= 输入模拟工具(editor 代理版与 runtime 原生版共用同一份 schema) =======

static func simulate_click() -> Dictionary:
	return {"type": "object", "properties": {
		"ref": {"type": "string", "description": "get_interactables 返回的元素引用(如 e3)。**优先用这个**: 2D 元素由服务端解析成实时位置(无需自己算坐标, 界面动过也不会点偏); 3D 元素(space=3d)则由工具在物体自身上激活, 不需要坐标"},
		"x": {"type": "integer", "description": "点击位置 X(窗口坐标); 仅在拿不到 ref 时用"},
		"y": {"type": "integer", "description": "点击位置 Y(窗口坐标); 仅在拿不到 ref 时用"},
		"space": {"type": "string", "enum": ["window", "viewport"], "description": "x/y 所属坐标系, 默认 window。传 viewport 时服务端按 content_scale 自动换算。子视口(space=subviewport, 贴在 3D 显示器/平板上的 UI)不在此列 —— 它只能靠 ref 点, 传 x/y 怎么算都打不中"},
	}}

static func simulate_drag() -> Dictionary:
	return {"type": "object", "properties": {
		"from_x": {"type": "integer", "description": "起始X坐标"},
		"from_y": {"type": "integer", "description": "起始Y坐标"},
		"to_x": {"type": "integer", "description": "目标X坐标"},
		"to_y": {"type": "integer", "description": "目标Y坐标"},
	}, "required": ["from_x", "from_y", "to_x", "to_y"]}

static func simulate_key() -> Dictionary:
	return {"type": "object", "properties": {
		"key": {"type": "string", "description": "按键名称, 如 'space', 'enter', 'escape', 'a'-'z', '0'-'9'"},
		"pressed": {"type": "boolean", "description": "true=按下, false=释放, 默认 true"},
	}, "required": ["key"]}

## 文本输入走控件的 insert_text_at_caret, 不逐字符注入按键: 后者要处理 IME、修饰键、
static func simulate_text() -> Dictionary:
	return {"type": "object", "properties": {
		"text": {"type": "string", "description": "要输入的文本(支持中文等任意字符)"},
		"ref": {"type": "string", "description": "目标输入控件的 ref(get_interactables 返回, 如 e3)。优先用这个"},
		"path": {"type": "string", "description": "或直接给节点路径(/root/... 或相对游戏场景根); 与 ref 二选一, ref 优先"},
		"submit": {"type": "boolean", "description": "输入后是否发一次回车(LineEdit 会触发 text_submitted), 默认 false"},
		"replace": {"type": "boolean", "description": "true=先清空控件现有内容, 默认 true(false=在光标处插入)"},
	}, "required": ["text"]}

## 滚轮: 容器/列表滚动只能靠 WHEEL_UP/DOWN, 键盘翻页并不等价。
static func simulate_scroll() -> Dictionary:
	return {"type": "object", "properties": {
		"amount": {"type": "integer", "description": "滚动格数, 正数=向下(WHEEL_DOWN), 负数=向上。默认 1"},
		"ref": {"type": "string", "description": "滚轮事件的目标控件 ref; 省略则用 x/y(或视口中心)"},
		"x": {"type": "integer", "description": "滚轮位置 X(窗口坐标), 仅在无 ref 时用"},
		"y": {"type": "integer", "description": "滚轮位置 Y(窗口坐标), 仅在无 ref 时用"},
	}}

## ======= 入参校验(MCP 规范要求对所有工具入参做校验) =======

## 需要展开成普通 Array 而非原样接受的类型。
const _PACKED := [
	TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
]

## 拼写纠错的最大编辑距离。
const _NEAREST_MAX_DISTANCE := 3

## 校验一次 tools/call 的 arguments。
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
	# 未知参数必须报错, 不能交给 handler 静默忽略: 拼错的参数会让工具"看起来坏了"
	_check_unknown(props, args, prefix, out)
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
		# 只递归显式声明了 properties 的嵌套对象。
		if tname == "object" and prop.get("properties", null) is Dictionary:
			_walk(prop, v, at + ".", out)
		elif tname == "array" and prop.get("items", null) is Dictionary:
			# 数组元素声明了 properties 时才逐个查(apply_scene_edits.ops 就是这种形状)。
			var item: Dictionary = prop["items"]
			if not item.get("properties", null) is Dictionary:
				continue
			var arr: Array = v if v is Array else Array(v)
			for i in arr.size():
				if arr[i] is Dictionary:
					_walk(item, arr[i], "%s[%d]." % [at, i], out)

## 报出 schema 未声明的参数(拼错的键几乎都落在这里), 能确定时附带最接近的合法参数名。
static func _check_unknown(props: Dictionary, args: Dictionary, prefix: String, out: Array[String]) -> void:
	var known: Array = props.keys()
	for key in args:
		var k := str(key)
		if props.has(key) or props.has(k):
			continue
		# 路由参数: 就地执行前 MCPRouter 已把它摘掉, 但转发与自检路径里可能残留, 不该报成拼写错。
		if k == "instance" and prefix.is_empty():
			continue
		var near := _nearest(k, known)
		var hint := ("(最接近: %s)" % near) if not near.is_empty() else ""
		var names: Array = []
		for known_key in known:
			names.append(str(known_key))
		out.append('"%s%s" 不是本工具的合法参数%s。可用参数: %s。' % [prefix, k, hint, " / ".join(PackedStringArray(names))])

## 找最接近的已知参数名。
static func _nearest(name: String, known: Array) -> String:
	var best := ""
	var best_d := _NEAREST_MAX_DISTANCE
	for k in known:
		var d := _distance(name.to_lower(), str(k).to_lower())
		if d < best_d:
			best_d = d
			best = str(k)
	return best

## Levenshtein 距离。
static func _distance(a: String, b: String) -> int:
	var la := a.length()
	var lb := b.length()
	if la == 0:
		return lb
	if lb == 0:
		return la
	var prev: Array[int] = []
	for j in lb + 1:
		prev.append(j)
	for i in range(1, la + 1):
		var cur: Array[int] = [i]
		for j in range(1, lb + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur.append(mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost))
		prev = cur
	return prev[lb]

## 值能否被该 schema 类型承载。
static func _type_ok(v: Variant, tname: String) -> bool:
	match tname:
		"integer", "number":
			# 两者都收 int 与 float: JSON 区分不了 3 与 3.0, 解析器给出哪一种取决于客户端。
			return v is int or v is float
		"boolean":
			return v is bool
		"string":
			# 数字字符串放行(表单手填的常态); 容器必须报错, 否则会被静默转成 "[]" 这种看着像值的字符串。
			return v is String or VariantTool.is_number(v)
		"array":
			return v is Array or typeof(v) in _PACKED
		"object":
			return v is Dictionary
	return true

## 报给调用方看的值描述。
static func _describe(v: Variant) -> String:
	var t := type_string(typeof(v))
	if v is Array or v is Dictionary:
		return t
	var s := str(v)
	return t if s.is_empty() else '%s("%s")' % [t, s]
