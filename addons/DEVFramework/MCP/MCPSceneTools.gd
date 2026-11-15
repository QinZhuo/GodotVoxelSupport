@tool
extends RefCounted

## ======= 场景树 / 场景编辑域 =======
##   - 场景树 / 节点(读): get_scene_tree / get_node_info / set_node_property / call_node_method
##   - 场景编辑(写):       add_node / save_scene / remove_node / duplicate_node / connect_signal
## 分组的界线是**副作用**: 前一组以观测为主(唯一的例外是 set_node_property / call_node_method,
## 改动能被用户 Ctrl+Z 撤掉 —— 这条"AI 改的东西必须可撤"是本域最重要的设计约束。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

## 跨域共享的编辑器环境辅助。本域**不持有**取编辑根节点的私有副本 —— 见文件头
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")

## 输出给 AI 的核心属性白名单(过滤编辑器内部数百项属性, 控制上下文开销)
const CORE_PROP_NAMES := ["name", "position", "scale", "rotation", "rotation_degrees", "visible", "modulate", "process_mode", "z_index", "text", "color"]

## 默认展开深度; 场景 UI 层级深的项目可在 dev_framework/mcp/scene_tree_depth 调小,
const SETTING_SCENE_TREE_DEPTH := "dev_framework/mcp/scene_tree_depth"
const DEFAULT_SCENE_TREE_DEPTH := 8


## 场景树默认展开深度(项目设置可覆盖)
static func scene_tree_depth() -> int:
	return int(ProjectSettings.get_setting(SETTING_SCENE_TREE_DEPTH, DEFAULT_SCENE_TREE_DEPTH))


## ======= 域注册入口 =======
static func register(add_tool: Callable) -> void:
	## -- 场景树 / 节点 --
	add_tool.call("get_scene_tree",
		"获取当前编辑场景的节点树结构(路径/名称/类型)。理解场景结构用。返回 node_count(本次列出行数)/pruned_nodes(因深度上限未展开的节点数), 后者>0 表示还有子树没给, 需深挖请用 get_node_info(path)。",
		{"type": "object", "properties": {"max_depth": {"type": "integer", "description": "最大展开深度, 默认取项目设置 dev_framework/mcp/scene_tree_depth"}, "include_properties": {"type": "boolean", "description": "是否附带每个节点的关键属性, 默认 false"}}},
		_handle_get_scene_tree)

	## 【必填参数一律声明 required】本文件里必填项的兜底曾分三档, 档位之间体验差别很大:
	##   2. handler 里手写 _fail("必须提供 path") -> 说得清, 但无 recovery 指引
	add_tool.call("get_node_info",
		"获取编辑场景中指定节点的属性及当前值。path传节点名或路径(如Main/Player)。",
		{"type": "object", "properties": {"path": MCPToolSchema.node_path()}, "required": ["path"]},
		_handle_get_node_info)

	add_tool.call("set_node_property",
		"修改编辑场景中节点属性(调试用), UndoRedo提交可按Ctrl+Z撤。仅改内存, 需save_scene写回.tscn。支持任意属性含 Node2D/Node3D 的 position/rotation/scale(Vector 可传 '1,2'/'1,2,3' 字符串)。",
		{"type": "object", "properties": {"path": MCPToolSchema.node_path(), "property": {"type": "string", "description": "属性名"}, "value": {"description": "新值(支持数字/字符串/布尔; Vector2 等可传 '1,2' 字符串)"}}, "required": ["path", "property"]},
		_handle_set_node_property)

	add_tool.call("call_node_method",
		"调用编辑场景中节点的方法(调试触发逻辑, 如播放动画/切换状态)。args以数组传参。【副作用】这是**真执行而非观测**: 方法体会真的跑起来, 可能改节点状态、触发信号, 或走进游戏业务逻辑(扣血/切状态/存档), 故重复调用会叠加出额外副作用, 只想看状态请用 get_node_info。",
		{"type": "object", "properties": {"path": MCPToolSchema.node_path(), "method": {"type": "string", "description": "方法名"}, "args": {"type": "array", "description": "参数数组"}}, "required": ["path", "method"]},
		_handle_call_node_method)


	## -- 场景编辑 --
	add_tool.call("add_node",
		"在当前编辑场景添加节点或实例化子场景。node_type为类名或.tscn的res://路径。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"parent": {"type": "string", "description": "父节点路径(编辑场景内), 缺省为场景根"}, "node_type": {"type": "string", "description": "节点类型类名或子场景 res:// 路径"}, "name": {"type": "string", "description": "新节点名称(可选)"}}, "required": ["node_type"]},
		_handle_add_node)

	add_tool.call("save_scene",
		"保存当前编辑场景到.tscn(set_node_property/add_node改动需save后写回)。",
		MCPToolSchema.no_arg(),
		_handle_save_scene)

	add_tool.call("remove_node",
		"从当前编辑场景删除指定节点(含子树)。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"path": MCPToolSchema.node_path()}, "required": ["path"]},
		_handle_remove_node)

	add_tool.call("duplicate_node",
		"复制当前编辑场景中的节点(含子树), 可作为兄弟节点。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"path": MCPToolSchema.str_arg("要复制的节点路径(编辑场景内)"), "new_name": {"type": "string", "description": "新节点名称(可选, 默认原名+_copy)"}}, "required": ["path"]},
		_handle_duplicate_node)

	add_tool.call("connect_signal",
		"在编辑场景节点上连接信号到方法(运行时连接, 随场景保存)。source_path源节点, signal信号名(如 'pressed'), method目标方法名, target_path目标节点(缺省为源节点所在场景根)。",
		{"type": "object", "properties": {
			"source_path": {"type": "string", "description": "发出信号的节点路径"},
			"signal": {"type": "string", "description": "信号名(如 pressed)"},
			"method": {"type": "string", "description": "要连接的方法名"},
			"target_path": {"type": "string", "description": "目标节点路径(缺省为源节点)"}
		}, "required": ["source_path", "signal", "method"]},
		_handle_connect_signal)


## ======= 实现 =======

static func _handle_get_scene_tree(args: Dictionary) -> Dictionary:
	var max_depth: int = VariantTool.get_int(args, "max_depth", scene_tree_depth())
	var include_props := VariantTool.get_bool(args, "include_properties")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var lines: Array = []
	# 用字典带回"是否有子树因深度上限未展开", 而不是让它隐没在缺失的文本里 ——
	var stats := {"pruned": 0}
	_walk_scene_tree(root, 0, max_depth, include_props, lines, stats)
	var text := "\n".join(lines)
	if int(stats["pruned"]) > 0:
		text += "\n\n[深度截断] %d 个节点因 max_depth=%d 未展开(子树内容未返回)。\n续读: 增大 max_depth, 或用 get_node_info(path) 精确取某个子树。" % [int(stats["pruned"]), max_depth]
	# structuredContent 只放**元信息**, 不重复携带 tree 文本 ——
	# tree 再进 structuredContent 就是第三份。实测深展开时三份合计 27 万字符, 去掉一份后
	return MCPResult.ok_with_meta(text, {
		"root": str(root.name),
		"max_depth": max_depth,
		"node_count": lines.size(),
		"pruned_nodes": int(stats["pruned"]),
	})


## 递归展开场景树(供 get_scene_tree 使用)。stats.pruned 累计"有子节点但未展开"的节点数。
static func _walk_scene_tree(node: Node, depth: int, max_depth: int, include_props: bool, lines: Array, stats: Dictionary) -> void:
	var children := node.get_children()
	if depth > max_depth:
		if not children.is_empty():
			stats["pruned"] = int(stats["pruned"]) + 1
			lines.append("%s└─ [%d 个子节点未展开]" % ["  ".repeat(depth), children.size()])
		return
	var indent := "  ".repeat(depth)
	lines.append("%s%s [%s]" % [indent, node.name, node.get_class()])
	if include_props and depth < 3:
		var props := _collect_essential_props(node)
		if not props.is_empty():
			lines.append("%s    props: %s" % [indent, JSON.stringify(props)])
	for child in children:
		_walk_scene_tree(child, depth + 1, max_depth, include_props, lines, stats)


static func _handle_get_node_info(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	var node := _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	var info := {
		"name": node.name,
		"class": node.get_class(),
		"path": node.get_path(),
		"properties": _collect_essential_props(node),
	}
	return MCPResult.ok_json(info)


## 提取对 AI 调试最有用的核心属性
static func _collect_essential_props(node: Node) -> Dictionary:
	var out := {}
	for p in node.get_property_list():
		var pname: String = str(p.name)
		if pname.begins_with("theme_override") or pname.begins_with("accessibility_") \
				or pname.begins_with("focus_") or pname == "editor_description" or pname == "script":
			continue
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE or pname in CORE_PROP_NAMES:
			var v: Variant = node.get(pname)
			if v != null and not (v is Object or v is Resource):
				out[pname] = v
	return out


static func _handle_set_node_property(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	var property: String = VariantTool.get_string(args, "property")
	# "value" 是全服务器**唯一**允许裸读的入参键: 目标类型事先未知, 只能先取
	var value: Variant = args.get("value", null)
	var node := _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	var current: Variant = node.get(property)
	if current == null and not node.has_method(property):
		return MCPResult.fail("节点 %s 没有属性: %s" % [path, property])
	var typed: Variant = VariantTool.infer(value)
	if typed is String and current != null:
		typed = VariantTool.coerce(value, typeof(current))
	if typed == null and value != null:
		return MCPResult.fail("无法转换值 %s 为属性类型" % str(value))
	# 经 UndoRedo 提交, 使 AI 的修改可用 Ctrl+Z 撤销(Ctrl+Z 作用于当前编辑场景)
	var undo := _editor_undo_redo()
	if undo:
		undo.create_action("MCP: set %s.%s" % [node.name, property])
		undo.add_do_property(node, property, typed)
		undo.add_undo_property(node, property, current)
		undo.commit_action()
	else:
		node.set(property, typed)
	return MCPResult.ok("已设置 %s.%s = %s" % [path, property, str(node.get(property))])


static func _handle_call_node_method(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	var method: String = VariantTool.get_string(args, "method")
	var args_arr: Array = VariantTool.get_array(args, "args")
	var node := _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	if not node.has_method(method):
		return MCPResult.fail("节点 %s 没有方法: %s" % [path, method])
	var converted_args: Array = []
	for arg in args_arr:
		converted_args.append(VariantTool.infer(arg))
	var result: Variant = node.callv(method, converted_args)
	return MCPResult.ok("已调用 %s.%s() -> %s" % [path, method, str(result)])


static func _handle_add_node(args: Dictionary) -> Dictionary:
	var parent_path := VariantTool.get_string(args, "parent")
	var node_type := VariantTool.get_string(args, "node_type")
	var new_name := VariantTool.get_string(args, "name")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var parent := root
	if not parent_path.is_empty():
		parent = _resolve_node(parent_path)
		if parent == null:
			return MCPResult.fail("找不到父节点: %s" % parent_path)
	var new_node: Node
	if node_type.begins_with("res://"):
		if not ResourceLoader.exists(node_type):
			return MCPResult.fail("子场景不存在: %s" % node_type)
		var packed: PackedScene = ResourceLoader.load(node_type)
		if packed == null:
			return MCPResult.fail("子场景加载失败: %s" % node_type)
		new_node = packed.instantiate()
	else:
		if not ClassDB.class_exists(node_type):
			return MCPResult.fail("未知节点类型: %s" % node_type)
		new_node = ClassDB.instantiate(node_type)
		if new_node == null:
			return MCPResult.fail("无法实例化节点类型: %s" % node_type)
	if not new_name.is_empty():
		new_node.name = new_name
	var owner_root: Node = root
	var undo := _editor_undo_redo()
	if undo:
		# 经 UndoRedo 提交, 使 AI 新增节点可用 Ctrl+Z 移除。
		undo.create_action("MCP: add %s" % new_node.name)
		undo.add_do_method(parent, "add_child", new_node, true)
		undo.add_undo_method(parent, "remove_child", new_node)
		undo.add_do_property(new_node, "owner", owner_root)
		undo.add_undo_property(new_node, "owner", null)
		undo.commit_action()
	else:
		parent.add_child(new_node, true)
		_assign_owner_recursive(new_node, owner_root)
	return MCPResult.ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])


## 递归把节点及其子树 owner 设为场景根, 保证新增节点可随场景保存
static func _assign_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owner_recursive(child, root)


## 删除节点(含子树)
static func _handle_remove_node(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var root: Node = MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	if node == root:
		return MCPResult.fail("不能删除场景根节点")
	var parent: Node = node.get_parent()
	if parent == null:
		return MCPResult.fail("节点没有父节点: %s" % path)
	# 直接删除: 节点删除的 UndoRedo 会保留已删节点引用, 保存场景时触发
	parent.remove_child(node)
	node.owner = null
	node.queue_free()
	return MCPResult.ok("已删除节点 %s" % node.name)


## 复制节点(含子树)为兄弟
static func _handle_duplicate_node(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var new_name := VariantTool.get_string(args, "new_name")
	var root: Node = MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	var dup: Node = node.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS)
	if dup == null:
		return MCPResult.fail("节点复制失败: %s" % path)
	if new_name.is_empty():
		new_name = node.name + "_copy"
	dup.name = new_name
	var parent: Node = node.get_parent()
	if parent == null:
		return MCPResult.fail("节点没有父节点: %s" % path)
	var owner_root: Node = root
	var undo: EditorUndoRedoManager = _editor_undo_redo()
	if undo:
		undo.create_action("MCP: duplicate %s" % new_name)
		undo.add_do_method(parent, "add_child", dup, true)
		undo.add_undo_method(parent, "remove_child", dup)
		undo.add_do_property(dup, "owner", owner_root)
		undo.add_undo_property(dup, "owner", null)
		undo.commit_action()
	else:
		parent.add_child(dup, true)
		_assign_owner_recursive(dup, owner_root)
	return MCPResult.ok("已复制节点 %s → %s" % [node.name, dup.name])


## 连接信号到方法
static func _handle_connect_signal(args: Dictionary) -> Dictionary:
	var source_path := VariantTool.get_string(args, "source_path")
	var signal_name := VariantTool.get_string(args, "signal")
	var method := VariantTool.get_string(args, "method")
	var target_path := VariantTool.get_string(args, "target_path")
	var root: Node = MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var source: Node = _resolve_node(source_path)
	if source == null:
		return MCPResult.fail("找不到源节点: %s" % source_path)
	if not source.has_signal(signal_name):
		return MCPResult.fail("节点 %s 没有信号 %s" % [source.name, signal_name])
	var target: Node = source
	if not target_path.is_empty():
		target = _resolve_node(target_path)
		if target == null:
			return MCPResult.fail("找不到目标节点: %s" % target_path)
	if not target.has_method(method):
		return MCPResult.fail("目标节点 %s 没有方法 %s" % [target.name, method])
	# 场景内连接的信号, 随场景保存
	var undo: EditorUndoRedoManager = _editor_undo_redo()
	if undo:
		undo.create_action("MCP: connect %s.%s -> %s.%s" % [source.name, signal_name, target.name, method])
		undo.add_do_method(source, "connect", signal_name, Callable(target, method))
		undo.add_undo_method(source, "disconnect", signal_name, Callable(target, method))
		undo.commit_action()
	else:
		source.connect(signal_name, Callable(target, method))
	return MCPResult.ok("已连接 %s.%s → %s.%s" % [source.name, signal_name, target.name, method])


static func _handle_save_scene(_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var err := EditorInterface.save_scene()
	if err != OK:
		return MCPResult.fail("保存场景失败(错误码 %d)" % err)
	return MCPResult.ok("已保存场景 %s" % root.get_scene_file_path())


## ======= 本域辅助 =======

## 在场景内解析节点(名称/相对路径/绝对路径)
static func _resolve_node(path: String) -> Node:
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return null
	if path == "root" or path == "/" or path == str(root.name):
		return root
	if path.begins_with("@"):
		return root.find_child(path.substr(1), true, false)
	if path.begins_with("/"):
		var rel := path.trim_prefix("/")
		return root.get_node_or_null(rel)
	var n := root.get_node_or_null(path)
	if n:
		return n
	return root.find_child(path, true, false)


## 获取编辑器 UndoRedo 管理器(仅编辑器模式)。所有场景变异工具经它提交,
## "Ctrl+Z 撤销"这个能力静默消失。严格说这撞在全局判据"漏调必须可见"上, 但**保留原样**:
##   - 它不是漏调, 是编辑器能力缺失时的兜底路径, 原始实现即如此;
##   - 改掉会让本域在"能改但不能撤"时直接失败, 那比静默降级更糟。
## 而 static 化之后拿不到 self。查过唯一创建 MCPDevServer 的位置(plugin.gd
static func _editor_undo_redo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()
