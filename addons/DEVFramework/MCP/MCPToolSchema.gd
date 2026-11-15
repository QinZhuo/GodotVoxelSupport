@tool
extends RefCounted

## ======= 工具参数 schema 工厂 =======
## **本文件必须带 @tool**, 且不声明 class_name, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。

## 常用 code 参数的默认文案。集中在此, 避免转发层再抄一份而漂移。
const _CODE_ARG_DEFAULT := "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"

## search_symbols 的 kind 合法取值(单一来源)。schema 的 enum 与 handler 的校验共用它 ——
const SEARCH_KIND := ["all", "function", "variable", "class", "node", "resource", "ref"]


## 通用字符串参数。
static func str_arg(desc: String) -> Dictionary:
	return {"type": "string", "description": desc}


## 常用 code 参数。desc 留空则用默认文案(让转发层不必复述它)。
static func code_arg(desc: String = "") -> Dictionary:
	return str_arg(desc if not desc.is_empty() else _CODE_ARG_DEFAULT)


## eval_code 的 timeout_ms 共用定义。
static func code_timeout_arg() -> Dictionary:
	return {"type": "integer", "description": "可选: 含await代码的等待上限毫秒, 默认 8000, 上限 15000"}


## 通用文件路径参数描述(read_file / write_file / append_file 三处字面量相同)。
const _FILE_PATH_DESC := "文件路径(res:// 或 user://)"


## 无参工具的标准 schema
static func no_arg() -> Dictionary:
	return {"type": "object", "properties": {}}


## 游戏操作工具 schema(editor 代理版与 runtime 原生版共用)
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


## 游标类工具(get_logs)的 schema。
## 应当先看到, 否则它得读完四个游标参数才发现这个工具要先选类别。
static func logs(default_max: String, unit: String, extra: Dictionary = {}) -> Dictionary:
	# 先放该工具独有参数(顺序见上方说明), 再逐个写游标参数, 同名以游标参数为准。
	# 不要用 Dictionary.merge_in(): 那是 Godot 3 的原地合并 API, Godot 4 只有 merge(),
	var props := extra.duplicate(true)
	props["max"] = {"type": "integer", "minimum": 1, "description": "最多条数(合并后), 默认 %s" % default_max}
	props["since"] = {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的%s, 默认 0=全量" % unit}
	props["contains"] = {"type": "string", "description": "按 message 子串过滤(大小写敏感), 只返回含该子串的条目。缓冲动辄上百条, 没有它就只能全量拉取再人眼扫。过滤先于 max 截断, 故语义是'全部%s中匹配的, 最多 max 条'" % unit}
	props["merge"] = {"type": "boolean", "description": "是否合并连续重复%s, 默认 true" % unit}
	return {"type": "object", "properties": props}


## 文件写类工具(写入/追加/删除)共用的 dry_run 参数。
static func dry_run_arg() -> Dictionary:
	return {"type": "boolean", "description": "预演模式: true=只返回将要发生的改动(目标是否存在/大小/是否覆盖), **不做任何实际改动**, 默认 false"}


## 文件路径工具(读取/删除)schema。with_dry_run=true 时附带 dry_run 参数.
static func file_path(path_desc: String, with_dry_run: bool = false) -> Dictionary:
	var props := {"path": str_arg(path_desc)}
	if with_dry_run:
		props["dry_run"] = dry_run_arg()
	return {"type": "object", "properties": props, "required": ["path"]}


## read_file 的 schema: path + 字符游标(offset / limit)。
## 返回里 next_char_offset=-1 表示已读完, 否则原样作为下次 offset 传回即可。
## `FileAccess.get_length()` 给的**字节**。两个单位混用是这类接口最常见的踩坑点, 故游标
static func read_file() -> Dictionary:
	return {"type": "object", "properties": {
		"path": str_arg(_FILE_PATH_DESC),
		"offset": {"type": "integer", "minimum": 0, "description": "起始字符下标, 默认 0。**单位是字符不是字节**, 与 next_char_offset 同单位"},
		"limit": {"type": "integer", "minimum": 1, "description": "本次最多返回的字符数, 默认 0=不限(仍受全局输出上限约束)。被上限截断时按 next_char_offset 续读"},
	}, "required": ["path"]}


## 文件写入/追加 schema(两个工具共用同一结构).
static func write_content() -> Dictionary:
	return {"type": "object", "properties": {
		"path": str_arg(_FILE_PATH_DESC),
		"content": {"type": "string", "description": "要写入/追加的内容"},
		"dry_run": dry_run_arg(),
	}, "required": ["path", "content"]}


## 场景内节点路径参数(get_node_info / set_node_property / call_node_method / remove_node 共用)。
## 如 'Main' 或 'Main/Player'"。同一概念两种说法, 而"要不要带场景根名"恰好是 AI 最容易填错的
static func node_path() -> Dictionary:
	return str_arg("节点路径(编辑场景内), 如 'Main' 或 'Main/Player'")

