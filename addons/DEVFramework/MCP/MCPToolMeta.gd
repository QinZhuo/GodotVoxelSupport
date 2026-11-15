@tool
extends RefCounted

## ======= 工具元数据(annotations / outputSchema) =======
## 与 MCPResult(响应契约)、MCPToolSchema(请求契约)同级的第三块协议契约。**必须带 @tool 且不

## ---------------------------------------------------------------- 只读工具
const READ_ONLY := [
	# -- 验证/查询 --
	"validate", "list_dir", "classdb_query",
	# -- 日志/错误 --
	"get_logs",
	# -- 场景观测 --
	"get_scene_tree", "get_node_info", "get_interactables",
	# -- 项目观测 --
	"get_project_info", "get_editor_activity",
	# -- 多实例观测 --
	"list_instances",
	# -- 代码/符号检索 --
	"search_symbols", "find_resource_users", "script_status", "get_resource_info",
	# -- 文件观测 --
	"read_file", "file_exists",
	# -- 测试 / 截图(不写工程状态) --
]

## ------------------------------------------------- 有副作用但不破坏的工具(SIDE_EFFECT)
const SIDE_EFFECT := [
	"take_screenshot", # 落盘新增 PNG(文件名含时间戳, 不覆盖已有文件; 删除即可回退)
	"render_model",    # 离屏渲染落盘新增 PNG(文件名含时戳, 不覆盖; 删除即可回退)
]

## ---------------------------------------------------------------- 破坏性工具
## destructiveHint 是**客户端唯一依据**来决定是否弹确认框, 所以宁可多标:
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
	# -- 任意代码执行 --
	"eval_code",
]

## ---------------------------------------------------------------- 幂等工具
const IDEMPOTENT := [
	# -- 会改状态但可安全重放 --
	"save_scene", "save_all", "set_node_property", "open_scene",
	"connect_signal", "create_resource",
	"clear_logs",
	"refresh_tools",
	# use_instance: 只改"默认目标编辑器"这一个进程内设置, 同参数重放结果相同。
	"use_instance",
	# -- 刻意不列 --
]

## 未列入任何名单的工具: 非只读, 且**默认非破坏性**。
## "漏标会静默降级成安全", 所以 audit() 必须把 DESTRUCTIVE 的完备性兜住。


## ======= 入口: 供 MCPDevServer._add_tool 统一调用 =======

## 为单个工具生成完整 MCP 工具定义(含 annotations / outputSchema)。
static func build(name: String, desc: String, input_schema: Dictionary) -> Dictionary:
	var read_only := READ_ONLY.has(name)
	# 后半段是防御性的: 两张名单重叠时按"非破坏性"处理 —— 错标破坏性的代价(高频工具反复弹框)
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
		"outputSchema": {"type": "object"},
	}
	return def


## ======= 为什么这里不生成 title =======
## 曾按"取描述首句"生成过, 移除理由是它对模型零增益却让常驻工具表多付 13.5%(实测 44889 字符里


## ======= 契约自检 =======

## 反向校验: 名单里是否写了未注册的工具名。
static func audit_against(registered: Dictionary) -> Array[String]:
	var issues: Array[String] = []
	for entry in [["READ_ONLY", READ_ONLY], ["DESTRUCTIVE", DESTRUCTIVE], ["SIDE_EFFECT", SIDE_EFFECT], ["IDEMPOTENT", IDEMPOTENT]]:
		for n in entry[1]:
			if not registered.has(n):
				issues.append("%s 含未注册的工具名 '%s'(工具已删除/改名, 名单未同步)" % [entry[0], n])
	return issues


## 校验四张名单的一致性。返回问题描述数组(空 = 通过), 由调用方决定如何报告。
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
static func _audit_side_effect_overlap() -> Array[String]:
	var out: Array[String] = []
	for n in SIDE_EFFECT:
		if READ_ONLY.has(n):
			out.append("SIDE_EFFECT 与 READ_ONLY 同时包含 '%s' —— 有副作用的工具不能声明只读, 否则客户端会自动重试并重复产生副作用" % n)
		if DESTRUCTIVE.has(n):
			out.append("SIDE_EFFECT 与 DESTRUCTIVE 同时包含 '%s' —— '有副作用但不破坏'与'破坏性'互斥, build() 会按非破坏性处理, 两处需对齐成一种" % n)
	return out


## IDEMPOTENT 里混入只读工具 = 冗余列举(只读已由 build() 自动推导为幂等)。
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
