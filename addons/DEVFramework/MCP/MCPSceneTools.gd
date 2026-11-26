@tool
extends RefCounted

## ======= 场景树 / 场景编辑域 =======
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")

## 跨域共享的编辑器环境辅助。
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")

## 输出给 AI 的核心属性白名单(过滤编辑器内部数百项属性, 控制上下文开销)
const CORE_PROP_NAMES := ["name", "position", "scale", "rotation", "rotation_degrees", "visible", "modulate", "process_mode", "z_index", "text", "color"]

## 默认展开深度; 场景 UI 层级深的项目可在 dev_framework/mcp/scene_tree_depth 调小。
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

	## 【必填参数一律声明 required】handler 里手写 _fail("必须提供 path") 说得清, 但模型在调用前
	add_tool.call("get_node_info",
		"获取编辑场景中指定节点的属性及当前值。path传节点名或路径(如Main/Player)。默认只回核心属性(位置/可见性/文本等)与脚本导出变量, 嵌套的 Object/Resource 值不回; 要看**其它**属性(如自定义控件的某个属性, 或 Object 引用到底指向谁)就传 properties 指定属性名。",
		{"type": "object", "properties": {
			"path": MCPToolContract.node_path(),
			"properties": {"type": "array", "items": {"type": "string"}, "description": "可选: 只取这些属性名(按名字直读, 含 Object/Resource 值会被转成路径字符串)。省略则回核心属性白名单"},
		}, "required": ["path"]},
		_handle_get_node_info)

	add_tool.call("set_node_property",
		"修改编辑场景中节点属性(调试用), UndoRedo提交可按Ctrl+Z撤。仅改内存, 需 save(scope=\"scene\") 写回.tscn。支持任意属性含 Node2D/Node3D 的 position/rotation/scale(Vector 可传 '1,2'/'1,2,3' 字符串)。",
		{"type": "object", "properties": {"path": MCPToolContract.node_path(), "property": {"type": "string", "description": "属性名"}, "value": {"description": "新值(支持数字/字符串/布尔; Vector2 等可传 '1,2' 字符串)"}}, "required": ["path", "property"]},
		_handle_set_node_property)

	add_tool.call("call_node_method",
		"调用编辑场景中节点的方法(调试触发逻辑, 如播放动画/切换状态)。args以数组传参。【副作用】这是**真执行而非观测**: 方法体会真的跑起来, 可能改节点状态、触发信号, 或走进游戏业务逻辑(扣血/切状态/存档), 故重复调用会叠加出额外副作用, 只想看状态请用 get_node_info。",
		{"type": "object", "properties": {"path": MCPToolContract.node_path(), "method": {"type": "string", "description": "方法名"}, "args": {"type": "array", "description": "参数数组"}}, "required": ["path", "method"]},
		_handle_call_node_method)

	## -- 场景编辑 --
	add_tool.call("add_node",
		"在当前编辑场景添加节点或实例化子场景。node_type为类名或.tscn的res://路径。UndoRedo提交可Ctrl+Z撤。",
		{"type": "object", "properties": {"parent": {"type": "string", "description": "父节点路径(编辑场景内), 缺省为场景根"}, "node_type": {"type": "string", "description": "节点类型类名或子场景 res:// 路径"}, "name": {"type": "string", "description": "新节点名称(可选)"}}, "required": ["node_type"]},
		_handle_add_node)

	add_tool.call("remove_node",
		"从当前编辑场景删除指定节点(含子树)。**【不可撤销】** 不走 UndoRedo(节点删除的撤销会保留已删节点引用, 保存场景时触发 'Trying to assign invalid previously freed instance'), 故 Ctrl+Z 不能把它变回来。要删多个节点请用 apply_scene_edits 一次提交; 若拿不准, 先 get_node_info 确认再删。",
		{"type": "object", "properties": {"path": MCPToolContract.node_path()}, "required": ["path"]},
		_handle_remove_node)

	## duplicate_node / connect_signal 的入参是 apply_scene_edits 里同名 op 的真子集(少了…
	add_tool.call("apply_scene_edits",
		"批量执行场景编辑(一次事务): 建控件树、批量设属性、批量删/复制。ops 按顺序执行, 任一失败即整体回滚并指出第几条; dry_run=true 只校验不落改动。**除 remove_node 外都可一次 Ctrl+Z 整体撤销**(含 remove_node 时结果带 irreversible=true)。op.action: add_node / remove_node / set_property / duplicate_node / connect_signal / rename。改一处时用对应的单条工具更省。",
		{"type": "object", "properties": {
			"ops": {"type": "array", "description": "操作数组, 按顺序执行。每项都含 action 字段, 其余字段随 action 而定", "items": {
				"type": "object",
				"properties": {
					"action": {"type": "string", "enum": ["add_node", "remove_node", "set_property", "duplicate_node", "connect_signal", "rename"]},
					"path": {"type": "string", "description": "目标节点路径(remove_node/set_property/duplicate_node/rename 用)"},
					"parent": {"type": "string", "description": "add_node: 父节点路径, 缺省为场景根"},
					"node_type": {"type": "string", "description": "add_node: 节点类名或子场景 res:// 路径"},
					"name": {"type": "string", "description": "add_node/rename: 新名称"},
					"property": {"type": "string", "description": "set_property: 属性名"},
					"value": {"description": "set_property: 新值(支持 '1,2' 这类向量字符串)"},
					"new_name": {"type": "string", "description": "duplicate_node: 副本名称, 缺省原名+_copy"},
					"source_path": {"type": "string", "description": "connect_signal: 发出信号的节点路径"},
					"signal": {"type": "string", "description": "connect_signal: 信号名"},
					"method": {"type": "string", "description": "connect_signal: 目标方法名"},
					"target_path": {"type": "string", "description": "connect_signal: 目标节点路径, 缺省为源节点"},
				},
				"required": ["action"],
			}},
			"dry_run": MCPToolContract.dry_run_arg(),
		}, "required": ["ops"]},
		_handle_apply_scene_edits)

	## 【撤销】apply_scene_edits 的另一半: 它以"一次 Ctrl+Z 整体撤销"为卖点, 却没把撤销动作交给
	add_tool.call("undo_redo",
		"撤销/重做当前编辑场景的改动(与编辑器 Ctrl+Z / Ctrl+Shift+Z 同一条撤销栈, 会让用户的撤销历史一起前进)。apply_scene_edits 等场景编辑之后用它自我回退。steps 可一次连撤多步; 撤到底或无可重做时返回实际执行了几步。",
		{"type": "object", "properties": {
			"action": {"type": "string", "enum": ["undo", "redo"], "description": "undo=撤销, redo=重做, 默认 undo"},
			"steps": {"type": "integer", "minimum": 1, "description": "连续执行几步, 默认 1"},
		}, "required": ["action"]},
		_handle_undo_redo)

## ======= 实现 =======

static func _handle_get_scene_tree(args: Dictionary) -> Dictionary:
	var max_depth: int = VariantTool.get_int(args, "max_depth", scene_tree_depth())
	var include_props := VariantTool.get_bool(args, "include_properties")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var lines: Array = []
	# 用字典带回"是否有子树因深度上限未展开", 而不是让它隐没在缺失的文本里。
	var stats := {"pruned": 0, "nodes": 0}
	_walk_scene_tree(root, 0, max_depth, include_props, lines, stats)
	var text := "\n".join(lines)
	if int(stats["pruned"]) > 0:
		text += "\n\n[深度截断] %d 个节点因 max_depth=%d 未展开(子树内容未返回)。\n续读: 增大 max_depth, 或用 get_node_info(path) 精确取某个子树。" % [int(stats["pruned"]), max_depth]
	# structuredContent 只放**元信息**, 不重复携带 tree 文本 ——
	return MCPResult.ok_with_meta(text, {
		"root": str(root.name),
		"max_depth": max_depth,
		# 数节点, 不数行: include_properties=true 时每个节点会多出一行 props,
		"node_count": int(stats["nodes"]),
		"pruned_nodes": int(stats["pruned"]),
	})

## 递归展开场景树(供 get_scene_tree 使用)。
static func _walk_scene_tree(node: Node, depth: int, max_depth: int, include_props: bool, lines: Array, stats: Dictionary) -> void:
	var children := node.get_children()
	if depth > max_depth:
		if not children.is_empty():
			stats["pruned"] = int(stats["pruned"]) + 1
			lines.append("%s└─ [%d 个子节点未展开]" % ["  ".repeat(depth), children.size()])
		return
	var indent := "  ".repeat(depth)
	stats["nodes"] = int(stats["nodes"]) + 1
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
	var wanted: Array = VariantTool.get_array(args, "properties")
	var props := {}
	if wanted.is_empty():
		props = _collect_essential_props(node)
	else:
		# 指定属性名的路径: 白名单之外的值也要能取到(自定义控件属性、Object 引用到底指向谁),
		for raw_name in wanted:
			var pname := str(raw_name).strip_edges()
			if pname.is_empty():
				continue
			if not _has_property(node, pname):
				props[pname] = {"_error": "节点没有该属性"}
				continue
			props[pname] = _read_property_value(node, pname)
	var info := {
		"name": node.name,
		"class": node.get_class(),
		# 相对场景根的写法: get_path() 是编辑器内部长路径(/root/@EditorNode@19513/@Panel@14/...
		"path": _scene_relative_path(node),
		"properties": props,
	}
	return MCPResult.ok_json(info)

## 节点相对"当前编辑场景根"的路径(根自己返回 root 的节点名)。
static func _scene_relative_path(node: Node) -> String:
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return str(node.get_path())
	if node == root:
		return String(root.name)
	if not root.is_ancestor_of(node):
		return str(node.get_path())
	return String(root.get_path_to(node))

## 节点是否有该属性(get 不到但存在默认值为 null 的属性也要算"有")。
static func _has_property(node: Node, pname: String) -> bool:
	for p in node.get_property_list():
		if str(p.name) == pname:
			return true
	return false

## 把属性值转成可放进 JSON 的形式。
static func _read_property_value(node: Node, pname: String) -> Variant:
	var v: Variant = node.get(pname)
	if v is Object:
		var obj := v as Object
		if obj == null:
			return null
		if obj is Resource:
			var res := obj as Resource
			var res_path := res.resource_path
			if not res_path.is_empty():
				return res_path
			return {"_resource_class": res.get_class()}
		var n := obj as Node
		if n != null:
			return {"_node_path": str(n.get_path()), "_class": n.get_class()}
		return {"_object_class": obj.get_class()}
	# 空的对象槽(属性声明为 Object 但从未赋值, 如 Control.theme)typeof 是 OBJECT 却既不是
	if typeof(v) == TYPE_OBJECT:
		return null
	return v

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

## ======= 单步编辑(单工具与批量工具共用同一份实现) =======

## 设置属性。
static func _apply_set_property(node: Node, property: String, value: Variant, undo: EditorUndoRedoManager, add_undo: bool = true, execute_now: bool = false) -> String:
	if not _has_property(node, property):
		return "节点 %s 没有属性: %s" % [node.name, property]
	var current: Variant = node.get(property)
	var typed: Variant = VariantTool.infer(value)
	if typed is String and _is_res_path(String(typed)) and (current is Resource or _declares_object(node, property)):
		# 资源属性(texture / mesh / theme / font 等)不能交给 coerce: 它按 typeof(current) 做
		var loaded := _load_resource_arg(String(typed))
		if loaded == null:
			return "资源属性 %s 无法从路径加载: %s(路径要以 res:// 或 uid:// 开头)" % [property, str(typed)]
		typed = loaded
	elif typed is String and current != null:
		typed = VariantTool.coerce(value, typeof(current))
	if typed == null and value != null:
		return "无法转换值 %s 为属性类型" % str(value)
	if execute_now or undo == null:
		node.set(property, typed)
	if undo:
		undo.add_do_property(node, property, typed)
		if add_undo:
			undo.add_undo_property(node, property, current)
	return ""

static func _is_res_path(s: String) -> bool:
	var t := s.strip_edges()
	return t.begins_with("res://") or t.begins_with("uid://")

## 把资源路径写成 Resource。
static func _load_resource_arg(path: String) -> Resource:
	var p := path.strip_edges()
	if p.is_empty():
		return null
	if p.begins_with("uid://"):
		var resolved := ResourceUID.uid_to_path(p)
		if resolved.is_empty():
			return null
		p = resolved
	# 先 exists 再 load: 直接 load 一个不存在的路径会在编辑器里刷一条 "Cannot open file" 错误,
	if not p.begins_with("res://") or not ResourceLoader.exists(p):
		return null
	return ResourceLoader.load(p)

## 属性声明的类型是不是 Object(Resource 也算)。
static func _declares_object(node: Node, pname: String) -> bool:
	for p in node.get_property_list():
		if str(p.name) == pname:
			return int(p.type) == TYPE_OBJECT
	return false

static func _handle_set_node_property(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	var property: String = VariantTool.get_string(args, "property")
	# "value" 是全服务器**唯一**允许裸读的入参键: 目标类型事先未知, 只能先取
	var value: Variant = args.get("value", null)
	var node := _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	# 经 UndoRedo 提交, 使 AI 的修改可用 Ctrl+Z 撤销(Ctrl+Z 作用于当前编辑场景)
	var undo := _editor_undo_redo()
	if undo:
		undo.create_action("MCP: set %s.%s" % [node.name, property])
	var err := _apply_set_property(node, property, value, undo, true)
	if not err.is_empty():
		if undo:
			undo.commit_action(false)
		return MCPResult.fail(err)
	if undo:
		undo.commit_action()
	# 回显必须是"读得回来"的形式: 资源属性经 Resource 对象时 str() 只给 <Object#null> /…
	var shown: Variant = _read_property_value(node, property)
	return MCPResult.ok_json({
		"path": _scene_relative_path(node),
		"property": property,
		"value": shown,
		"message": "已设置 %s.%s = %s" % [path, property, JSON.stringify(shown) if shown != null else "null"],
	})

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

## 按类型/子场景造一个尚未入树的节点。
static func _make_node(node_type: String, new_name: String, out_err: Array) -> Node:
	var new_node: Node = null
	if node_type.begins_with("res://"):
		if not ResourceLoader.exists(node_type):
			out_err.append("子场景不存在: %s" % node_type)
			return null
		var packed: PackedScene = ResourceLoader.load(node_type)
		if packed == null:
			out_err.append("子场景加载失败: %s" % node_type)
			return null
		new_node = packed.instantiate()
	else:
		if not ClassDB.class_exists(node_type):
			out_err.append("未知节点类型: %s" % node_type)
			return null
		new_node = ClassDB.instantiate(node_type)
		if new_node == null:
			out_err.append("无法实例化节点类型: %s" % node_type)
			return null
	if new_node == null:
		out_err.append("节点实例化失败: %s" % node_type)
		return null
	if not new_name.is_empty():
		new_node.name = new_name
	return new_node

## 把已造好的节点挂到 parent 上, 并把 owner 递归指到场景根(否则存不进 .tscn)。
static func _apply_add_node(parent: Node, new_node: Node, root: Node, undo: EditorUndoRedoManager, add_undo: bool = true, execute_now: bool = false) -> void:
	if execute_now or undo == null:
		parent.add_child(new_node, true)
		_assign_owner_recursive(new_node, root)
	if undo:
		# 经 UndoRedo 提交, 使 AI 新增节点可用 Ctrl+Z 移除。
		undo.add_do_method(parent, "add_child", new_node, true)
		if add_undo:
			undo.add_undo_method(parent, "remove_child", new_node)
		# owner 用**方法**记录, 不用 add_do_property/add_undo_property:
		undo.add_do_method(new_node, "set_owner", root)
		if add_undo:
			undo.add_undo_method(new_node, "set_owner", null)

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
	var errs: Array = []
	var new_node := _make_node(node_type, new_name, errs)
	if new_node == null:
		return MCPResult.fail(str(errs[0]) if not errs.is_empty() else "节点实例化失败: %s" % node_type)
	var undo := _editor_undo_redo()
	if undo:
		undo.create_action("MCP: add %s" % new_node.name)
	_apply_add_node(parent, new_node, root, undo, true)
	if undo:
		undo.commit_action()
	return MCPResult.ok("已添加节点 %s [%s] 到 %s" % [new_node.name, new_node.get_class(), parent.name])

## 递归把节点及其子树 owner 设为场景根, 保证新增节点可随场景保存
static func _assign_owner_recursive(node: Node, root: Node) -> void:
	node.owner = root
	for child in node.get_children():
		_assign_owner_recursive(child, root)

## 删除节点(含子树)。
static func _apply_remove_node(node: Node, root: Node) -> String:
	if node == root:
		return "不能删除场景根节点"
	var parent: Node = node.get_parent()
	if parent == null:
		return "节点没有父节点: %s" % node.get_path()
	parent.remove_child(node)
	node.owner = null
	node.queue_free()
	return ""

static func _handle_remove_node(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var root: Node = MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var node: Node = _resolve_node(path)
	if node == null:
		return MCPResult.fail("找不到节点: %s" % path)
	var err := _apply_remove_node(node, root)
	if not err.is_empty():
		return MCPResult.fail(err)
	return MCPResult.ok("已删除节点 %s" % node.name)

## 复制节点(含子树)为兄弟。
static func _make_duplicate(node: Node, new_name: String, out_err: Array) -> Node:
	var dup: Node = node.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS)
	if dup == null:
		out_err.append("节点复制失败: %s" % str(node.get_path()))
		return null
	dup.name = new_name if not new_name.is_empty() else node.name + "_copy"
	return dup

## 连接信号到方法。
static func _apply_connect_signal(source: Node, signal_name: String, target: Node, method: String, undo: EditorUndoRedoManager, add_undo: bool = true, execute_now: bool = false) -> String:
	if not source.has_signal(signal_name):
		return "节点 %s 没有信号 %s" % [source.name, signal_name]
	if not target.has_method(method):
		return "目标节点 %s 没有方法 %s" % [target.name, method]
	var cb := Callable(target, method)
	if source.is_connected(signal_name, cb):
		return ""
	if execute_now or undo == null:
		source.connect(signal_name, cb)
	if undo:
		undo.add_do_method(source, "connect", signal_name, cb)
		if add_undo:
			undo.add_undo_method(source, "disconnect", signal_name, cb)
	return ""

## ======= 批量编辑: 一次事务改多处 =======
static func _handle_apply_scene_edits(args: Dictionary) -> Dictionary:
	var ops: Array = VariantTool.get_array(args, "ops")
	if ops.is_empty():
		return MCPResult.fail("ops 不能为空")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	if VariantTool.get_bool(args, "dry_run"):
		return _dry_run_edits(ops, root)
	var undo := _editor_undo_redo()
	if undo:
		undo.create_action("MCP: apply %d edits" % ops.size())
	var executed := 0
	var recorded := 0
	var irreversible := false
	var report: Array = []
	for i in ops.size():
		var op: Variant = ops[i]
		if not (op is Dictionary):
			return _abort_edits(undo, recorded, "第 %d 条操作不是对象(要 {action:..., ...})" % (i + 1), report, irreversible)
		var err := _apply_one_edit(op as Dictionary, root, undo)
		if not err.is_empty():
			return _abort_edits(undo, recorded, "第 %d 条操作失败: %s" % [i + 1, err], report, irreversible)
		executed += 1
		var act := VariantTool.get_string(op, "action")
		if act == "remove_node":
			irreversible = true
		else:
			recorded += 1
		report.append({"index": i + 1, "action": act})
	return _finish_edits(undo, recorded, executed, report, irreversible)

## 执行一条 op。
static func _apply_one_edit(op: Dictionary, root: Node, undo: EditorUndoRedoManager) -> String:
	var act := VariantTool.get_string(op, "action").strip_edges()
	var path := VariantTool.get_string(op, "path")
	match act:
		"add_node":
			var node_type := VariantTool.get_string(op, "node_type")
			if node_type.is_empty():
				return "add_node 缺少 node_type"
			var parent: Node = root
			var parent_path := VariantTool.get_string(op, "parent")
			if not parent_path.is_empty():
				parent = _resolve_node(parent_path)
				if parent == null:
					return "找不到父节点: %s" % parent_path
			var errs: Array = []
			var new_node := _make_node(node_type, VariantTool.get_string(op, "name"), errs)
			if new_node == null:
				return str(errs[0]) if not errs.is_empty() else "节点实例化失败: %s" % node_type
			_apply_add_node(parent, new_node, root, undo, true, true)
			return ""
		"remove_node":
			var victim := _resolve_node(path)
			if victim == null:
				return "找不到节点: %s" % path
			return _apply_remove_node(victim, root)
		"set_property":
			var node := _resolve_node(path)
			if node == null:
				return "找不到节点: %s" % path
			var property := VariantTool.get_string(op, "property")
			if property.is_empty():
				return "set_property 缺少 property"
			return _apply_set_property(node, property, op.get("value", null), undo, true, true)
		"duplicate_node":
			var src := _resolve_node(path)
			if src == null:
				return "找不到节点: %s" % path
			if src.get_parent() == null:
				return "节点没有父节点: %s" % path
			var dups: Array = []
			var dup := _make_duplicate(src, VariantTool.get_string(op, "new_name"), dups)
			if dup == null:
				return str(dups[0])
			_apply_add_node(src.get_parent(), dup, root, undo, true, true)
			return ""
		"connect_signal":
			var source := _resolve_node(VariantTool.get_string(op, "source_path"))
			if source == null:
				return "找不到源节点: %s" % VariantTool.get_string(op, "source_path")
			var target: Node = source
			var target_path := VariantTool.get_string(op, "target_path")
			if not target_path.is_empty():
				target = _resolve_node(target_path)
				if target == null:
					return "找不到目标节点: %s" % target_path
			return _apply_connect_signal(source, VariantTool.get_string(op, "signal"),
				target, VariantTool.get_string(op, "method"), undo, true, true)
		"rename":
			var target_node := _resolve_node(path)
			if target_node == null:
				return "找不到节点: %s" % path
			var new_name2 := VariantTool.get_string(op, "name")
			if new_name2.is_empty():
				return "rename 缺少 name"
			return _apply_set_property(target_node, "name", new_name2, undo, true, true)
		_:
			return "未知的 action: '%s'(可用: add_node/remove_node/set_property/duplicate_node/connect_signal/rename)" % act

## 收尾: 有 undo 就提交(不重复执行, 因为 op 已经边执行边记了)。
static func _finish_edits(undo: EditorUndoRedoManager, recorded: int, executed: int, report: Array, irreversible: bool) -> Dictionary:
	if undo and recorded > 0:
		undo.commit_action(false)
	var out := {
		"executed": executed,
		"ops": report,
		"undoable": recorded > 0,
		"irreversible": irreversible,
		"message": "已执行 %d 条操作(可一次 Ctrl+Z 整体撤销)" % executed,
	}
	if irreversible:
		out["message"] = "已执行 %d 条操作; 本次含删除节点 —— 删除不可撤销(见 remove_node 注释)" % executed
	return MCPResult.ok_json(out)

## 失败即整体回滚。
static func _abort_edits(undo: EditorUndoRedoManager, recorded: int, why: String, report: Array, irreversible: bool) -> Dictionary:
	if undo and recorded > 0:
		undo.commit_action(false)
		var rollback := _undo_redo_of_edited_root(undo)
		if rollback:
			rollback.undo()
		else:
			why += "(警告: 找不到可回滚的历史, 本次改动可能残留在场景里)"
	var tail := "已回滚本次已执行的 %d 条操作。" % report.size() if recorded > 0 else "本次没有产生任何改动。"
	if irreversible:
		tail += "(注意: 删除节点不可撤销, 已删的不会回来)"
	return MCPResult.fail("%s
%s" % [why, tail])

## 预演: 只校验每条 op 的形状与目标是否存在, 一律不改。
static func _dry_run_edits(ops: Array, root: Node) -> Dictionary:
	var planned: Array = []
	for i in ops.size():
		var op: Variant = ops[i]
		if not (op is Dictionary):
			return MCPResult.fail("第 %d 条操作不是对象(要 {action:..., ...})" % (i + 1))
		var act := VariantTool.get_string(op, "action").strip_edges()
		var problem := ""
		match act:
			"add_node":
				var node_type := VariantTool.get_string(op, "node_type")
				if node_type.is_empty():
					problem = "缺少 node_type"
				elif node_type.begins_with("res://"):
					if not ResourceLoader.exists(node_type):
						problem = "子场景不存在: %s" % node_type
				elif not ClassDB.class_exists(node_type):
					problem = "未知节点类型: %s" % node_type
				var parent_path := VariantTool.get_string(op, "parent")
				if problem.is_empty() and not parent_path.is_empty() and _resolve_node(parent_path) == null:
					problem = "找不到父节点: %s" % parent_path
			"remove_node", "duplicate_node", "rename":
				if _resolve_node(VariantTool.get_string(op, "path")) == null:
					problem = "找不到节点: %s" % VariantTool.get_string(op, "path")
			"set_property":
				var node := _resolve_node(VariantTool.get_string(op, "path"))
				if node == null:
					problem = "找不到节点: %s" % VariantTool.get_string(op, "path")
				else:
					var property := VariantTool.get_string(op, "property")
					if property.is_empty():
						problem = "缺少 property"
					elif not _has_property(node, property):
						problem = "节点 %s 没有属性: %s" % [node.name, property]
			"connect_signal":
				var src := _resolve_node(VariantTool.get_string(op, "source_path"))
				if src == null:
					problem = "找不到源节点: %s" % VariantTool.get_string(op, "source_path")
				elif not src.has_signal(VariantTool.get_string(op, "signal")):
					problem = "节点 %s 没有信号 %s" % [src.name, VariantTool.get_string(op, "signal")]
			_:
				problem = "未知的 action: '%s'" % act
		if not problem.is_empty():
			return MCPResult.fail("[预演] 第 %d 条操作无法执行: %s。未做任何改动。" % [i + 1, problem])
		planned.append({"index": i + 1, "action": act, "ok": true})
	return MCPResult.ok_json({
		"dry_run": true,
		"planned": planned,
		"message": "[预演] 未做任何改动; %d 条操作形状与目标均已校验。确认后去掉 dry_run 重新调用 apply_scene_edits。" % ops.size(),
	})

## 撤销/重做。
static func _handle_undo_redo(args: Dictionary) -> Dictionary:
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var history := _undo_redo_of_edited_root(_editor_undo_redo())
	if history == null:
		return MCPResult.fail("当前场景没有可用的撤销历史(编辑器能力不可用)")
	var action := VariantTool.get_string(args, "action", "undo").strip_edges()
	if action != "undo" and action != "redo":
		return MCPResult.fail("action 只能是 undo 或 redo, 收到: %s" % action)
	var steps := maxi(1, VariantTool.get_int(args, "steps", 1))
	var done := 0
	for _i in steps:
		if action == "undo":
			if not history.has_undo():
				break
			history.undo()
		else:
			if not history.has_redo():
				break
			history.redo()
		done += 1
	if done == 0:
		return MCPResult.fail("%s 无处可去: %s。当前 can_undo=%s, can_redo=%s。" % [
			action, "已经撤到底" if action == "undo" else "没有可重做的操作",
			str(history.has_undo()), str(history.has_redo())])
	return MCPResult.ok_json({
		"action": action,
		"steps": done,
		"can_undo": history.has_undo(),
		"can_redo": history.has_redo(),
		"message": ("已撤销 %d 步" if action == "undo" else "已重做 %d 步") % done,
	})

## ======= 本域辅助 =======

## 在场景内解析节点(名称/相对路径/绝对路径)
static func _resolve_node(path: String) -> Node:
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return null
	if path == "root" or path == "/" or path == str(root.name):
		return root
	# 「场景根/子路径」也收: get_node_info 报出来的就是相对场景根的路径, 而它自己带不带根名
	if path.begins_with(str(root.name) + "/"):
		path = path.substr(str(root.name).length() + 1)
	if path.begins_with("@"):
		return root.find_child(path.substr(1), true, false)
	if path.begins_with("/"):
		var rel := path.trim_prefix("/")
		return root.get_node_or_null(rel)
	var n := root.get_node_or_null(path)
	if n:
		return n
	return root.find_child(path, true, false)

## 取"当前编辑场景根"对应的那条历史(UndoRedo)。
static func _undo_redo_of_edited_root(undo: EditorUndoRedoManager) -> UndoRedo:
	if undo == null:
		return null
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return null
	var history_id := undo.get_object_history_id(root)
	if history_id == EditorUndoRedoManager.INVALID_HISTORY:
		return null
	return undo.get_history_undo_redo(history_id)

## 获取编辑器 UndoRedo 管理器(仅编辑器模式)。
static func _editor_undo_redo() -> EditorUndoRedoManager:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_undo_redo()
