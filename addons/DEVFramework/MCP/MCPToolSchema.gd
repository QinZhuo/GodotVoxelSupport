@tool
extends RefCounted

## ======= 工具参数 schema 工厂 =======
##
## 由 MCPDevServer 以 preload 常量 `MCPToolSchema` 引用。
## **本文件必须带 @tool**, 且不声明 class_name, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
## 一句话版: 缺 @tool 时编辑器不做完整语义分析, 下面的代码就算有解析期错误也会一路"假绿",
## 直到运行时以 "Nonexistent function" 的形式让**整个 MCP 服务器**的工具同时返回空结果。
##
## 从 MCPDevServer 拆出, 与 MCPResult 同为「MCP 协议契约」的一部分: 结果封装定义了
## 响应长什么样, 这里定义**请求**长什么样。两者都是外部契约、零状态依赖, 都值得有一个
## 不依赖 4000 行服务器就能读懂的地方。
##
## 单一工厂的意义不是省代码, 而是防漂移。各工具各写各的 schema 时, 同一个概念的描述会
## 慢慢分叉 —— 而分叉出的差异常常是**误导性**的, 不只是不好看。真实例子: max 究竟是
## 合并前还是合并后的条数(见 logs()), 两种说法指向不同的截断行为, AI 按错的那个理解
## 就会拿不到想要的条目数量。

## 常用 code 参数的默认文案。集中在此, 避免转发层再抄一份而漂移。
const _CODE_ARG_DEFAULT := "要执行的 GDScript 代码(方法体内容, 缩进由服务器自动处理)"

## search_symbols 的 kind 合法取值(单一来源)。schema 的 enum 与 handler 的校验共用它 ——
## 两处各写一份必然漂移: 改了 handler 忘了 schema, 新值在 IDE 里不会被提示, 在入参校验层
## 还会被当成非法值拒掉; 反向漂移则是 schema 承诺了一个 handler 不认的值。
const SEARCH_KIND := ["all", "function", "variable", "class", "node", "resource", "ref"]


## 通用字符串参数。
## path 与 code 两类参数的实现完全一致(都是 type=string + description), 只有默认值
## 不同, 故合一 —— 留着两个实现相同的函数, 改文案时漏改一处, 两个工具的参数描述就悄悄
## 分叉成两种说法。
static func str_arg(desc: String) -> Dictionary:
	return {"type": "string", "description": desc}


## 常用 code 参数。desc 留空则用默认文案(让转发层不必复述它)。
static func code_arg(desc: String = "") -> Dictionary:
	return str_arg(desc if not desc.is_empty() else _CODE_ARG_DEFAULT)


## eval_code / game_eval 的 timeout_ms 共用定义。
##
## 这两个工具此前**各写一份字面量完全相同**的文案, 且分处两个文件(编辑器侧 _add_tool 与
## runtime 侧 _register_game_play_tool) —— 同一句话说两遍的漂移风险正是本文件存在的理由,
## 而"上限 15000"这类约束漂移出去是静默的(改了 schema 忘了实现, 或反之, 两边都不报错)。
static func code_timeout_arg() -> Dictionary:
	return {"type": "integer", "description": "可选: 含await代码的等待上限毫秒, 默认 8000, 上限 15000"}


## 通用文件路径参数描述(read_file / write_file / append_file 三处字面量相同)。
const _FILE_PATH_DESC := "文件路径(res:// 或 user://)"


## 无参工具的标准 schema
static func no_arg() -> Dictionary:
	return {"type": "object", "properties": {}}


## 游戏操作工具 schema(editor 代理版与 runtime 原生版共用)
##
## click 刻意**不列 required**: 坐标与 ref 是两条互斥的定位路径, 无论把哪一条写进 required,
## 走另一条的调用都会被 MCPArgCheck 判成"缺参数"而失败。故 required 留空, 由 handler 校验
## "ref 与 x/y 至少给一组"(缺了显式报错, 不静默点默认位置)。
static func simulate_click() -> Dictionary:
	return {"type": "object", "properties": {
		"ref": {"type": "string", "description": "get_interactables 返回的元素引用(如 e3)。**优先用这个**: 2D 元素由服务端解析成实时位置(无需自己算坐标, 界面动过也不会点偏); 3D 元素(space=3d)则由工具在物体自身上激活, 不需要坐标"},
		"x": {"type": "integer", "description": "点击位置 X(窗口坐标); 仅在拿不到 ref 时用"},
		"y": {"type": "integer", "description": "点击位置 Y(窗口坐标); 仅在拿不到 ref 时用"},
		"space": {"type": "string", "enum": ["window", "viewport"], "description": "x/y 所属坐标系, 默认 window。传 viewport 时服务端按 content_scale 自动换算"},
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


## 游标类工具(get_logs / get_game_logs / get_game_errors)的 schema。
##
## 三者共用一个工厂, 因为各写各的会漂移出**误导性**差异, 而不只是不好看: max 究竟是
## 合并前还是合并后的条数, 写错会让 AI 按错误预期截断(实现顺序见 _call_collect_logs:
## contains 过滤 → merge 合并 → max 截断, 故是合并后)。三者如今共用同一个实现
## (_call_collect_logs), 这层一致性由结构保证, 不依赖描述对齐 —— 此前 get_logs 会把 args
## 原样转发给 get_game_logs, 同一参数两处解释, 那种耦合正是要消除的。
##
## default_max 是**描述片段**而非整数: get_logs 的默认值随 kind 变化(log=200,
## warning/error=100), 写死一个数会让 AI 以为任何 kind 都适用。
## extra 是该工具独有的参数, 排在游标参数**之前** —— AI 顺序阅读, 主参数(如 kind)
## 应当先看到, 否则它得读完四个游标参数才发现这个工具要先选类别。
static func logs(default_max: String, unit: String, extra: Dictionary = {}) -> Dictionary:
	# 先放该工具独有参数(顺序见上方说明), 再逐个写游标参数, 同名以游标参数为准。
	# 不要用 Dictionary.merge_in(): 那是 Godot 3 的原地合并 API, Godot 4 只有 merge(),
	# 而它返回**新**字典不改原对象 —— 误用会在解析期报
	# "Function merge_in() not found in base Dictionary", 整个脚本编译失败。
	var props := extra.duplicate(true)
	props["max"] = {"type": "integer", "minimum": 1, "description": "最多条数(合并后), 默认 %s" % default_max}
	props["since"] = {"type": "integer", "description": "增量游标(上次返回的 next), 只返回此位置之后的%s, 默认 0=全量" % unit}
	props["contains"] = {"type": "string", "description": "按 message 子串过滤(大小写敏感), 只返回含该子串的条目。缓冲动辄上百条, 没有它就只能全量拉取再人眼扫。过滤先于 max 截断, 故语义是'全部%s中匹配的, 最多 max 条'" % unit}
	props["merge"] = {"type": "boolean", "description": "是否合并连续重复%s, 默认 true" % unit}
	return {"type": "object", "properties": props}


## 文件写类工具(写入/追加/删除)共用的 dry_run 参数。
## 三个工具共用同一份定义: 三处各写一遍必然漂移, 而漂移出的差异是**危险**的 ——
## 若 delete_file 的 dry_run 文案没说明"不实际删除", AI 可能预演完就以为文件已删。
static func dry_run_arg() -> Dictionary:
	return {"type": "boolean", "description": "预演模式: true=只返回将要发生的改动(目标是否存在/大小/是否覆盖), **不做任何实际改动**, 默认 false"}


## 文件路径工具(读取/删除)schema。with_dry_run=true 时附带 dry_run 参数.
##
## 把 dry_run 的拼装收进工厂而不是在注册点手写, 是因为字典字面量里无法"展开"一个键值对:
## 注册点若写 `"dry_run": _dry_run_arg()` 之外的任何形态(如直接 `_dry_run_arg()`),
## 解析期就会报 "Expected ':' after dictionary key" —— 那正是本次改造实际踩到的报错。
## 顺带把 path 参数的描述也收进来, 三个文件工具的 path 文案从此只有一处.
static func file_path(path_desc: String, with_dry_run: bool = false) -> Dictionary:
	var props := {"path": str_arg(path_desc)}
	if with_dry_run:
		props["dry_run"] = dry_run_arg()
	return {"type": "object", "properties": props, "required": ["path"]}


## read_file 的 schema: path + 字符游标(offset / limit)。
##
## 游标不是可选装饰, 而是这个工具可用性的前提: read_file 是最容易撞上输出上限的工具
## (整个文件进响应), 而没有游标时 AI 撞上截断后只剩两条路 —— 换个小文件, 或用 eval_code
## 现场写循环分次读。后者把本该一次调用的事变成三步, 且绕开了统一的截断统计与续读提示。
## 语义照抄 get_logs 那套已验证的游标约定(见 logs()), 不另发明第二种分页风格:
## 返回里 next_char_offset=-1 表示已读完, 否则原样作为下次 offset 传回即可。
##
## offset/limit 的单位是**字符**而非字节: String 的索引单位是字符, 而返回里的 size 是
## `FileAccess.get_length()` 给的**字节**。两个单位混用是这类接口最常见的踩坑点, 故游标
## 字段独立命名(不叫 next_offset), 让"字节数"和"游标"在名字层面就不可能混淆。
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
##
## 统一的原因: 此前四个工具里三个写"节点路径(编辑场景内)"、一个写"节点路径(编辑场景内),
## 如 'Main' 或 'Main/Player'"。同一概念两种说法, 而"要不要带场景根名"恰好是 AI 最容易填错的
## 地方 —— 缺了示例的那三个等于没告诉它。带示例的版本胜出, 故收成一处。
static func node_path() -> Dictionary:
	return str_arg("节点路径(编辑场景内), 如 'Main' 或 'Main/Player'")


## auto_verify 参数 schema
static func auto_verify() -> Dictionary:
	return {"type": "object", "properties": {
		"scene": {"type": "string", "description": "要启动的场景 res:// 路径, 缺省用主场景"},
		"duration": {"type": "number", "description": "单次运行总时长上限(秒), 默认 4, 超过判失败"},
		"stop_on_error": {"type": "boolean", "description": "任一步出错立即停止(true=hard)还是跑完再汇总(false=soft), 默认 true"},
		"retries": {"type": "integer", "description": "失败后的重试次数(总执行=1+retries)。每轮独立重启场景, 用于排除 flaky/时序性失败。默认 0"},
		"retry_backoff_ms": {"type": "integer", "description": "重试间隔毫秒, 默认 500"},
		"prev_snapshot": {"type": "object", "description": "可选: 上次的 scene_deps 快照(由本工具返回), 传入后检测本次执行前脚本/资源/配置是否变化, 结果含 deps_changed(兼容 code_changed)。供 verify_fix 复用。"},
		"operations": {"type": "array", "description": "操作序列(模拟玩家行为+延迟+断言)。每步格式: {'action': wait/click/drag/key/eval/poll/screenshot, ...}. wait 带 ms; click 带 x/y; drag 带 from_x/from_y/to_x/to_y; key 带 key; eval 带 code(GDScript, 可return); poll 带 code+timeout_ms(轮询直到返回 true); screenshot 可带 capture_type。操作间自动串行执行。"},
	}}
