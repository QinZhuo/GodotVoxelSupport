@tool
extends RefCounted

## ======= 工具元数据(annotations / outputSchema) =======

## ======= 三张分类名单: 每个工具必须恰好落进一张 =======

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
	"search_symbols", "find_resource_users", "script_status",
	# -- 文件观测 --
	"read_file",
	# -- 崩溃取证: 只读日志与事件日志 --
	"crash_report",
	# -- job 轮询/列举: 只是看一个已在跑的任务 --
	"job_wait", "job_list", "wait_for",
]

## ------------------------------------- 有副作用但不破坏的工具(NON_DESTRUCTIVE)
const NON_DESTRUCTIVE := [
	# -- 产物落盘(新文件, 不覆盖; 删除即回退) --
	"take_screenshot", "resource_inspect", # resource_inspect 的 thumbnail/render 只新增产物文件; tree 纯只读
	# -- 场景编辑(单步都走 UndoRedo) --
	"set_node_property", "add_node", "undo_redo",
	# -- 保存(写的是当前内存态, 重放结果相同) --
	"save",
	# -- 编辑器/进程内状态(不影响工程文件) --
	"open_scene", "use_instance", "clear_logs", "refresh_tools", "perf", "job_cancel",
	# -- 运行中输入注入: 只驱动运行时状态, 不动工程; 重放会重复触发业务逻辑, 故不进幂等名单。
	"simulate_click", "simulate_drag", "simulate_key", "simulate_text", "simulate_scroll",
	# -- 起游戏进程跑测试: 进程可停、结果可重跑 --
	"run_tests",
]

## ---------------------------------------------------------------- 破坏性工具
const DESTRUCTIVE := [
	# -- 文件 --
	"write_file",      # 覆盖已有文件内容
	"delete_file",     # 不可撤销
	"move_file",       # 源路径就此消失, 且会改变全工程的引用解析(rename 不可撤回)
	# -- 场景 --
	"remove_node",     # 不可撤销(见 _apply_remove_node 注释: 走 UndoRedo 会被已删引用污染)
	"apply_scene_edits", # 批量事务: 整批可撤, 但只要含 remove_node 就有不可撤的部分
	# -- 项目设置 --
	"set_main_scene",  # 改 project.godot 主场景
	"project_setting", # 带 value 时写入并保存
	"reimport",        # 重建 .godot/imported 缓存
	"create_resource", # 覆盖同名 .tres(幂等, 但会把旧内容冲掉)
	# -- 进程生命周期 --
	"restart_editor",  # 重启编辑器进程
	"game_control",    # start/stop 会启停游戏进程
	"launch_project",  # spawn 一个新的编辑器进程
	"build_native",    # 覆盖部署原生库(restart=true 还会重载编辑器)
	# -- 场景内触发业务逻辑 --
	"call_node_method", # 调节点方法会走业务逻辑(扣血/切状态/存档...), 重复调用必有多余副作用
	# -- 任意代码执行 --
	"eval_code",
]

## ---------------------------------------------------------------- 幂等工具
const IDEMPOTENT := [
	# -- 会改状态但可安全重放 --
	"save", "set_node_property", "open_scene",
	"create_resource",
	"clear_logs",
	"refresh_tools",
	# perf: snapshot/fps/history 只读; reset 只清可重建的历史基线。
	"perf",
	# build_native: 重复构建同一份源码得到同一产物。
	"build_native",
	# use_instance: 只改"默认目标编辑器"这一项设置(会落盘, 但同参数重放结果相同, 不碰工程文件)。
	"use_instance",
	# -- 刻意不列 --
]

## 未列入任何名单的工具 = **破坏性**(保守兜底): 漏标的代价是多弹一次确认, 而不是
const KINDS := ["read_only", "non_destructive", "destructive"]

## ======= 入口: 供 MCPDevServer._add_tool 统一调用 =======

## 为单个工具生成完整 MCP 工具定义(含 annotations / outputSchema)。
static func build(name: String, desc: String, input_schema: Dictionary, kind := "") -> Dictionary:
	var k := str(kind)
	# 显式自报的分类优先; 没自报就查内置名单(框架自带工具全走这条路)。
	var read_only := k == "read_only" or (k.is_empty() and READ_ONLY.has(name))
	var non_destructive := k == "non_destructive" or (k.is_empty() and NON_DESTRUCTIVE.has(name))
	# 三张名单之外 = **破坏性**: 漏标只多弹一次确认, 不会静默当安全操作执行。
	var destructive := not read_only and not non_destructive
	var def := {
		"name": name,
		"description": desc,
		"inputSchema": input_schema,
		"annotations": {
			"readOnlyHint": read_only,
			"destructiveHint": destructive,
			# 只读天然幂等, 无需在 IDEMPOTENT 重复列举。
			"idempotentHint": read_only or IDEMPOTENT.has(name),
			# 显式标 false 表示无外部影响。
			"openWorldHint": false,
		},
		# 只声明 type: 各工具 structuredContent 形状差异极大(日志是数组、classdb 是成员树…)。
		"outputSchema": {"type": "object"},
	}
	return def

## ======= 不生成 title =======

## ======= 契约自检 =======

## 反向校验: 名单里是否写了未注册的工具名。
static func audit_against(registered: Dictionary, kinds: Dictionary = {}) -> Array[String]:
	var issues: Array[String] = []
	for entry in [["READ_ONLY", READ_ONLY], ["DESTRUCTIVE", DESTRUCTIVE], ["NON_DESTRUCTIVE", NON_DESTRUCTIVE], ["IDEMPOTENT", IDEMPOTENT]]:
		for n in entry[1]:
			if not registered.has(n):
				issues.append("%s 含未注册的工具名 '%s'(工具已删除/改名, 名单未同步)" % [entry[0], n])
	# 反向兜底: build() 把三张名单都没写的工具判成破坏性, 即漏标 —— 会表现为"客户端老让我确认"。
	for tool_name in registered.keys():
		if READ_ONLY.has(tool_name) or NON_DESTRUCTIVE.has(tool_name) or DESTRUCTIVE.has(tool_name):
			continue
		if kinds.has(tool_name):
			var k := str(kinds[tool_name])
			if not KINDS.has(k):
				issues.append("工具 '%s' 自报的分类 '%s' 非法(只能是 %s)" % [tool_name, k, " / ".join(KINDS)])
			continue
		if IDEMPOTENT.has(tool_name):
			issues.append("工具 '%s' 只写进了 IDEMPOTENT, 未归入 READ_ONLY/NON_DESTRUCTIVE/DESTRUCTIVE —— 它会被 build() 判成破坏性并每次弹确认" % tool_name)
		else:
			issues.append("工具 '%s' 未归入任何分类名单 —— 已按破坏性兜底, 请显式登记进 READ_ONLY / NON_DESTRUCTIVE / DESTRUCTIVE" % tool_name)
	return issues

## 校验四张名单的一致性。
static func audit() -> Array[String]:
	var issues: Array[String] = []
	issues.append_array(_audit_overlap("READ_ONLY", READ_ONLY, "DESTRUCTIVE", DESTRUCTIVE))
	issues.append_array(_audit_non_destructive_overlap())
	issues.append_array(_audit_redundant_idempotent())
	issues.append_array(_audit_dupes("READ_ONLY", READ_ONLY))
	issues.append_array(_audit_dupes("DESTRUCTIVE", DESTRUCTIVE))
	issues.append_array(_audit_dupes("NON_DESTRUCTIVE", NON_DESTRUCTIVE))
	issues.append_array(_audit_dupes("IDEMPOTENT", IDEMPOTENT))
	return issues

## NON_DESTRUCTIVE 与另两张名单的交集(文案不同, 故不复用 _audit_overlap)。
static func _audit_non_destructive_overlap() -> Array[String]:
	var out: Array[String] = []
	for n in NON_DESTRUCTIVE:
		if READ_ONLY.has(n):
			out.append("NON_DESTRUCTIVE 与 READ_ONLY 同时包含 '%s' —— 有副作用的工具不能声明只读, 否则客户端会自动重试并重复产生副作用" % n)
		if DESTRUCTIVE.has(n):
			out.append("NON_DESTRUCTIVE 与 DESTRUCTIVE 同时包含 '%s' —— '有副作用但不破坏'与'破坏性'互斥, build() 会按非破坏性处理, 两处需对齐成一种" % n)
	return out

## IDEMPOTENT 的一致性检查。
static func _audit_redundant_idempotent() -> Array[String]:
	var out: Array[String] = []
	for n in IDEMPOTENT:
		if READ_ONLY.has(n):
			out.append("IDEMPOTENT 冗余列出只读工具 '%s'(build() 已由 readOnlyHint 自动推导幂等)" % n)
		elif not NON_DESTRUCTIVE.has(n) and not DESTRUCTIVE.has(n):
			out.append("IDEMPOTENT 列出未分类的工具 '%s' —— 先登记进 READ_ONLY/NON_DESTRUCTIVE/DESTRUCTIVE, 否则 build() 会把它判成破坏性" % n)
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
