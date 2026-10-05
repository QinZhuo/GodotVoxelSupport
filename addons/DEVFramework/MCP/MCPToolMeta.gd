@tool
extends RefCounted

## ======= 工具元数据(annotations / outputSchema) =======
##
## 与 MCPResult(响应契约)、MCPToolSchema(请求契约)同级的第三块协议契约。**必须带 @tool 且不
## 声明 class_name**, 理由同前两文件。
##
## MCP 规范给每个工具定义了 annotations(readOnlyHint / destructiveHint / idempotentHint /
## openWorldHint), 但它们**全部有默认值, 且默认值对你不利**: destructiveHint 缺省 true(保守假设)
## 会让只读工具也被标成破坏性, openWorldHint 缺省 true 会让客户端以为会碰外部世界。省略则客户端
## 只能按最坏情况处理: 弹确认框、拒绝自动重试。
##
## 用三张名单驱动而非逐个工具手写: 49 处手写 = 49 处可漂移的地方, 新增工具忘了写就默默继承最保守
## 的默认值, 且**没有任何东西会报错**。新工具默认落到 fallback 分支, 安全侧兜底。
##
## 名单刻意显式而非按 "get_"/"list_" 前缀推断: get_editor_activity 名字像只读实为观测,
## project_setting 带 value 时是写入 —— 前缀推断的错判率高于它的维护收益。

## ---------------------------------------------------------------- 只读工具
## 语义: 不修改任何持久状态(磁盘/场景/设置), 可安全重试、可被客户端自动调用。
## 重复调用产生额外副作用的一律不列(如 game_control start 会重启进程)。
const READ_ONLY := [
	# -- 验证/查询 --
	"validate", "list_dir", "classdb_query",
	# -- 日志/错误 --
	"get_logs", "get_game_logs", "get_game_errors",
	# -- 场景观测 --
	"get_scene_tree", "get_node_info", "get_interactables",
	# -- 项目观测 --
	"get_project_info", "get_editor_activity",
	# -- 代码/符号检索 --
	"search_symbols", "find_resource_users", "script_status", "get_resource_info",
	# -- 文件观测 --
	"read_file", "file_exists",
	# -- 测试(不写工程状态) --
	"run_tests",
]

## ------------------------------------------------- 有副作用但不破坏的工具(SIDE_EFFECT)
## 语义: 会真的改动环境(落盘/起进程), 但**不覆盖、不删除、不重启** —— 删掉产物即可回到调用前。
##
## 单开一张表: 塞进 READ_ONLY 是错的(截图每次调用都新增一个 PNG, readOnlyHint=true 等于授权
## 客户端放心重试, 重试就攒下一堆无主截图); 落到破坏性默认分支也不对(它是调试高频工具, 每截
## 一张图弹一次确认框)。MCP 恰好能表达这个中间态: readOnlyHint=false + destructiveHint=false。
const SIDE_EFFECT := [
	"take_screenshot", # 落盘新增 PNG(文件名含时间戳, 不覆盖已有文件; 删除即可回退)
]

## ---------------------------------------------------------------- 破坏性工具
## 语义: 可能覆盖/删除/重启, 产生难以回退的变更。
## destructiveHint 是**客户端唯一依据**来决定是否弹确认框, 所以宁可多标:
## 标成 true 只多一次确认, 标成 false 而实际会删文件则是把用户文件置于风险中。
const DESTRUCTIVE := [
	# -- 文件 --
	"write_file",      # 覆盖已有文件内容
	"delete_file",     # 不可撤销
	# -- 场景 --
	"remove_node",     # 不可撤销(见 _call_remove_node 注释: 走 UndoRedo 会被已删引用污染)
	# -- 项目设置 --
	"set_main_scene",  # 改 project.godot 主场景
	"project_setting", # 带 value 时写入并保存
	"reimport",        # 重建 .godot/imported 缓存
	"restart_editor",  # 重启编辑器进程
	"game_control",    # start/stop 会启停游戏进程
	# -- 场景内触发业务逻辑 --
	"call_node_method", # 调节点方法会走业务逻辑(扣血/切状态/存档...), 重复调用必有多余副作用,
	                    # 且可能写入游戏自身状态。此前误列 READ_ONLY, 连带被 build() 推导出
	                    # idempotentHint=true(允许客户端自动重试) —— 语义与实现相反。
	# -- 任意代码执行 --
	# 与 call_node_method 同类, 且安全性的**上限更低**: 前者的副作用至少可从被调方法推断,
	# 这里的后续风险完全取决于调用方写了什么代码 —— 任何"按工具名推断是否危险"的规则在此
	# 都失效。此前漏标, 从 build() 的默认值拿到 destructiveHint=false, 与两份 description
	# 开头的【副作用】自相矛盾。
	"eval_code",
	"game_eval",
]

## ---------------------------------------------------------------- 幂等工具
## 语义: 同一参数重复调用, 第二次起不再产生额外副作用。客户端据此可安全自动重试。
##
## **只读工具不在此列出**: 只读天然幂等, build() 已自动推导。重复列一遍只会多一处可漂移的地方。
## 多数写工具**不**幂等(delete_file / append_file / add_node 重复执行会叠加或二次删除),
## 宁可漏标不误标: 漏标的后果是客户端不自动重试, 误标的后果是重复扣血。
const IDEMPOTENT := [
	# -- 会改状态但可安全重放 --
	"save_scene", "save_all", "set_node_property", "open_scene",
	"connect_signal", "create_resource",
	"clear_logs", "clear_game_logs", "clear_game_errors",
	"refresh_tools",
	# -- 刻意不列 --
	# duplicate_node: 每次生成一个 *_copy, 重放会多出一份
	# add_node:  重放会产生同名/同类型重复节点
	# simulate_click/drag/key: 重放会重复触发业务逻辑(重复扣血/跳两次)
	# eval_code / game_eval: 执行任意代码, 副作用不可知
]

## 未列入任何名单的工具: 非只读, 且**默认非破坏性**。
##
## 这个方向与 MCP 规范相反(规范默认 true), 是刻意取舍: 翻转成破坏性会让 save_scene /
## open_scene / clear_logs 这类最高频的例行操作全部被弹确认框, 代价是每次调试都打断。代价则是
## "漏标会静默降级成安全", 所以 audit() 必须把 DESTRUCTIVE 的完备性兜住。
##
## 刻意留在名单外的: auto_verify(停掉用户正在跑的游戏)、verify_fix / run_game_tests(驱动
## 进程)、simulate_click/drag/key(注入输入)。它们会打断调试流程但都能恢复, 打断的代价由人当场
## 决定, 不如标成破坏性让客户端弹框。


## ======= 入口: 供 MCPDevServer._add_tool 统一调用 =======

## 为单个工具生成完整 MCP 工具定义(含 annotations / outputSchema)。
##
## 统一在这里生成而不是各 _add_tool 调用点自带, 是为了让"协议字段"这件事只发生在一个
## 地方: 以后规范加了新的工具字段, 改这一个函数即可, 49 个注册点零改动。
static func build(name: String, desc: String, input_schema: Dictionary) -> Dictionary:
	var read_only := READ_ONLY.has(name)
	# 后半段是防御性的: 两张名单重叠时按"非破坏性"处理 —— 错标破坏性的代价(高频工具反复弹框)
	# 大于错标非破坏性(客户端多自动调用一次), 且重叠本身会被 audit() 报出来。
	var destructive := DESTRUCTIVE.has(name) and not SIDE_EFFECT.has(name)
	var def := {
		"name": name,
		"description": desc,
		"inputSchema": input_schema,
		"annotations": {
			"readOnlyHint": read_only,
			"destructiveHint": destructive,
			# 只读天然幂等, 无需在 IDEMPOTENT 里重复列举(见该常量上方说明)
			"idempotentHint": read_only or IDEMPOTENT.has(name),
			# 显式标 false 让客户端知道无需为"外部影响"额外确认。不可省: 规范默认是 true。
			"openWorldHint": false,
		},
		# 只声明 type: 各工具 structuredContent 形状差异极大(日志是条目数组、classdb 是类成员树…),
		# 统一编一份具体 schema 必然有工具对不上, 客户端会按 schema 把合法响应当成非法拒掉 ——
		# 那是**制造**故障。宽松声明让客户端知道"是对象"即可。
		"outputSchema": {"type": "object"},
	}
	return def


## ======= 为什么这里不生成 title =======
##
## 规范给了 title 两个位置(顶层 Tool.title 与 Tool.annotations.title), 本服务器**都不发**。
## 曾按"取描述首句"生成过, 移除理由是它对模型零增益却让常驻工具表多付 13.5%(实测 44889 字符里
## 6046 是 title): 内容是 description 的截断副本(模型选工具只需 name + description), 且两个
## 位置 49/49 完全相同, 为兼容两端而都写等于把代价乘 2。它的正当用途是给人看 UI 标签, 而工具名
## 本身对 UI 已足够可读。
##
## 客户端若因 UI 需要中文标题, 回到这里恢复 `make_title()`, 但**只写一处**: 优先写顶层 title。


## ======= 契约自检 =======

## 反向校验: 名单里是否写了未注册的工具名。
## 放在本文件而不是让调用方遍历, 是因为遍历必然要把三张名单暴露出去 —— 而名单是本文件的
## 实现细节(将来增删一张表, 调用方不该跟着改)。对外只留 audit() 与 audit_against() 两个入口。
static func audit_against(registered: Dictionary) -> Array[String]:
	var issues: Array[String] = []
	for entry in [["READ_ONLY", READ_ONLY], ["DESTRUCTIVE", DESTRUCTIVE], ["SIDE_EFFECT", SIDE_EFFECT], ["IDEMPOTENT", IDEMPOTENT]]:
		for n in entry[1]:
			if not registered.has(n):
				issues.append("%s 含未注册的工具名 '%s'(工具已删除/改名, 名单未同步)" % [entry[0], n])
	return issues


## 校验四张名单的一致性。返回问题描述数组(空 = 通过), 由调用方决定如何报告。
##
## 规则只列**真冲突**, 因为误报会让自检迅速被无视 —— 一个总在喊狼来了的检查等于没有检查。
## IDEMPOTENT ∩ READ_ONLY 只算冗余不算矛盾(幂等是只读的子集, 已由 build() 推导)。
## 名单内重复也报(名单本该是集合)。
static func audit() -> Array[String]:
	var issues: Array[String] = []
	issues.append_array(_audit_overlap("READ_ONLY", READ_ONLY, "DESTRUCTIVE", DESTRUCTIVE))
	issues.append_array(_audit_side_effect_overlap())
	issues.append_array(_audit_redundant_idempotent())
	issues.append_array(_audit_dupes("READ_ONLY", READ_ONLY))
	issues.append_array(_audit_dupes("DESTRUCTIVE", DESTRUCTIVE))
	issues.append_array(_audit_dupes("SIDE_EFFECT", SIDE_EFFECT))
	issues.append_array(_audit_dupes("IDEMPOTENT", IDEMPOTENT))
	return issues


## SIDE_EFFECT 与另两张名单的交集 —— 不复用 _audit_overlap: 那套文案对这里的两个交集都不成立,
## 而**文案不准确的自检等于没有自检**。∩ READ_ONLY 是三张表里最严重的矛盾(等于授权客户端
## 放心自动重试); ∩ DESTRUCTIVE 会被 build() 静默按非破坏性处理, 不报出来就没人知道。
static func _audit_side_effect_overlap() -> Array[String]:
	var out: Array[String] = []
	for n in SIDE_EFFECT:
		if READ_ONLY.has(n):
			out.append("SIDE_EFFECT 与 READ_ONLY 同时包含 '%s' —— 有副作用的工具不能声明只读, 否则客户端会自动重试并重复产生副作用" % n)
		if DESTRUCTIVE.has(n):
			out.append("SIDE_EFFECT 与 DESTRUCTIVE 同时包含 '%s' —— '有副作用但不破坏'与'破坏性'互斥, build() 会按非破坏性处理, 两处需对齐成一种" % n)
	return out


## IDEMPOTENT 里混入只读工具 = 冗余列举(只读已由 build() 自动推导为幂等)。
## 同时拦下 SIDE_EFFECT 那一类: 它目前只有截图一种形态, 每次调用新增一个产物, 重放会多出
## 一份文件, 与"第二次起不再产生额外副作用"直接冲突。
static func _audit_redundant_idempotent() -> Array[String]:
	var out: Array[String] = []
	for n in IDEMPOTENT:
		if READ_ONLY.has(n):
			out.append("IDEMPOTENT 冗余列出只读工具 '%s'(build() 已由 readOnlyHint 自动推导幂等)" % n)
		elif SIDE_EFFECT.has(n):
			out.append("IDEMPOTENT 列出有副作用的工具 '%s'(如 take_screenshot 每次调用新增一个产物, 重放会多出一份, 不满足幂等定义)" % n)
	return out


static func _audit_overlap(a_name: String, a: Array, b_name: String, b: Array) -> Array[String]:
	var out: Array[String] = []
	for n in a:
		if b.has(n):
			out.append("%s 与 %s 同时包含 '%s' —— 只读工具不应有破坏性副作用" % [a_name, b_name, n])
	return out


static func _audit_dupes(list_name: String, list: Array) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for n in list:
		if seen.has(n):
			out.append("%s 中 '%s' 重复出现" % [list_name, n])
		seen[n] = true
	return out
