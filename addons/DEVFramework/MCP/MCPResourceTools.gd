@tool
extends RefCounted

## ======= 资源与项目设置域 =======
##
## 从 MCPDevServer 拆出。收录"改动/查询**编辑器侧资源与项目配置**"这一类能力:
##   open_scene / set_main_scene / project_setting / save_all / reimport
##   create_resource / get_resource_info
##
## 与 MCPCodeIndex 的分工: 那边是**只读地找**(在磁盘上搜索符号与引用), 这边是**改与查实体**
## (打开场景、写项目设置、创建/读取 .tres、触发重新导入)。两者唯一的交集是都要走 res:// 路径
## 规范化, 故没有共用辅助函数。
##
## ## 本文件的两块职责(名字相近, 语义完全不同)
##
##   1. **tools/\* 工具**(下方"域注册入口"一节): open_scene / project_setting /
##      create_resource / get_resource_info 等 —— 改与查编辑器侧实体资源, 走 tools/call。
##   2. **resources/\* 协议端点**(文件末尾): list_resources / read_resource —— 把项目自带的
##      静态文档(LAYERS.md 与各模块 Readme.md)声明成 MCP 资源, 走 resources/list|read。
##
## 第 2 块此前住在 MCPDevServer 里, 与本文件同名却毫无关系, 读代码时极易误以为"resources
## 端点归 MCPResourceTools 管"而找不到它。现在两块在本文件内 —— "resources"这个词在项目里
## 只有一个落点, 这比拆成两个文件更不容易走丢(它们的调用方都是主文件, 不在同一处)。
##
## ## 依赖方向: 严格单向
##
## 与 MCPCodeIndex 同一条规矩, 理由照抄那份文件: 本文件**不引用** MCPDevServer, 也不持有任何
## 服务器状态, 只依赖 MCPResult / MCPToolSchema / VariantTool, 注册靠传入 _add_tool 的 Callable
## 完成。7 个 handler 全部零实例状态依赖, 因此**一律 static** —— 这也是入参一致性自检能工作的
## 前提(改用 lambda 注册会让 get_method() 返回空串, 那批工具会静默跳过自检)。
##
## ## 本域的编辑器依赖
##
## open_scene / reimport / save_all 三个走 EditorInterface, 在非编辑器进程(游戏运行期)不可用,
## 各自保留原有的 `Engine.is_editor_hint()` 守卫。project_setting / set_main_scene /
## create_resource / get_resource_info 只用 ProjectSettings 与 ResourceLoader, 游戏进程里也能跑,
## 故**不**加该守卫 —— 与原实现逐条一致, 不借拆分之机改行为。
##
## ## 接缝判据(全局统一, 不是本域的偏好)
##
## 接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。据此各域给了不同答案,
## 且都正确, 不要为了"看起来统一"而改:
##   - log 域→ 注入 bind_logger: 漏调后果是 get_logs 返回"日志捕获器未就绪", **显式报错**。
##   - validate 域 → 域内自建: 漏调后果是编译错误捕获不到、validate 恒返回 valid=true,
##     **静默失效**, 所以它必须否决接缝。
##   - dev 域 → 注入: _mode / _game_started_at 是实例状态且不可推导, 没有自建选项; 漏调后果
##     最隐蔽, 所以它自带告警。
##
## **本域的答案是"零状态接缝"(第四种形态)**: 本域没有任何 bind_xxx, 因为它**没有实例状态** ——
## 7 个 handler 对 _pending / _verify_sessions / _http / debugger_plugin / _mode / _logger /
## _game_started_at 等**零引用**, 不存在"必须由服务器递进来"的东西, 自然也就没有可漏调的绑定。
## 全域唯一的接缝是注册用的 add_tool, 而它的漏调后果是**显式**的: 7 个工具整体不进 _tool_defs,
## tools/list 里查不到, 调用直接回 Unknown tool; 而且因为 handler 全 static 且无状态, 不存在
## "注册了但注入失败、工具在却行为错"的中间态 —— 漏调在注册阶段就全无, 比 log 域的 null 捕获器
## 更靠前一步。
##
## MCPResult / MCPToolSchema 是 preload const、VariantTool 是全局 class_name, 三者都是**编译期**
## 解析, 不是接缝: 漏写只会编译失败, 无"静默跑偏"可言。
##
## 本域真正的静默风险点**不是接缝, 而是引擎前提**: EditorInterface 在非编辑器进程里不可用,
## 而 open_scene / reimport 的方法返回 void, 误跑时不会自己冒出来。故凡是走 EditorInterface 的
## handler 都以 `Engine.is_editor_hint()` + `MCPResult.fail("仅在编辑器模式可用")` **显式挡下**
## (reimport 的顺序是先校验资源存在、后校验编辑器模式, 与原实现一致)。
##
## 反向也要提醒: 别为了"和 open_scene 看起来统一"给 project_setting / set_main_scene /
## create_resource / get_resource_info 也补上 is_editor_hint 守卫 —— 那会**收窄能力**(把本来
## 在游戏进程里可用的工具变成不可用), 与本判据同属"为了统一而改"这一类错。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## ======= 域注册入口 =======
##
## 由 MCPDevServer._register_editor_tools() 调用一次。add_tool 是服务器 `_add_tool` 的
## Callable, 签名 (name, desc, input_schema, handler)。工具排列顺序与主文件
## _register_dev_tools 里原先的注册顺序一致, 便于对照迁移前后的 tools/list。
static func register(add_tool: Callable) -> void:
	add_tool.call("open_scene",
		"在编辑器打开场景(res://路径)。",
		{"type": "object", "properties": {"path": MCPToolSchema.str_arg("场景 res:// 路径")}, "required": ["path"]},
		_handle_open_scene)

	add_tool.call("set_main_scene",
		"设置项目主场景并保存project.godot。",
		{"type": "object", "properties": {"path": MCPToolSchema.str_arg("主场景 res:// 路径")}, "required": ["path"]},
		_handle_set_main_scene)

	add_tool.call("project_setting",
		"读写任意项目设置项(如 application/config/name)。value 缺省=读取; 提供 value=写入并保存。数组/对象值会自动还原为真正的 Variant。",
		{"type": "object", "properties": {
			"name": {"type": "string", "description": "设置项名称"},
			"value": {"description": "可选: 新值; 缺省则只读"}
		}, "required": ["name"]},
		_handle_project_setting)

	add_tool.call("save_all",
		"保存全部打开的场景与项目设置。",
		MCPToolSchema.no_arg(),
		_handle_save_all)

	add_tool.call("reimport",
		"重新导入资源(重建.godot/imported缓存), 资源显示异常/导入配置变更后使用。仅对有同名 .import 的资源有效(图片/音频/模型等); .gd/.tres/.json 等纯文本资源无需导入。",
		{"type": "object", "properties": {"path": MCPToolSchema.str_arg("要重新导入的资源 res:// 路径")}, "required": ["path"]},
		_handle_reimport)

	add_tool.call("create_resource",
		"创建 .tres 资源配置: 指定脚本(class_name 或 res://脚本路径)与属性字典, 写入 res:// 或 user:// 路径。配置驱动开发时创建 Def 资源用。注意: 新建脚本 class_name 需先 restart_editor 才能被引擎识别, 若创建失败请先 reload。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("要创建的 .tres 完整路径(如 res://Assets/Def/MyDef.tres)"),
			"script": {"type": "string", "description": "脚本 class_name 或 res:// 脚本路径(如 ChangelogDef 或 res://addons/.../ChangelogDef.gd)"},
			"properties": {"type": "object", "description": "属性字典(键=导出属性名, 值=属性值), 可嵌套资源/数组"}
		}, "required": ["path", "script"]},
		_handle_create_resource)

	add_tool.call("get_resource_info",
		"读取 .tres/.tscn 资源的完整属性树(递归), 便于理解配置结构。返回类型/导出属性/嵌套子资源/引用的脚本。排查配置或了解 Def 资源用。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("资源 res:// 路径(如 res://Assets/Def/MyDef.tres)"),
			"max_depth": {"type": "integer", "description": "嵌套资源最大展开深度, 默认 5"}
		}, "required": ["path"]},
		_handle_get_resource_info)

	add_tool.call("preview_resource",
		"取编辑器为某资源生成的**预览缩略图**(FileSystem 里那种), 存成 PNG 并返回路径。用途: 让已导入成 mesh 的模型(.vox/.qvx/.glb 等)看一眼渲染效果, 不必放进场景。传**源文件路径**(如 res://demo/deer.vox, 需已导入); 走 EditorResourcePreview, 异步回调。视角固定、尺寸由编辑器缩略图设置决定。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("已导入资源的源文件 res:// 路径(如 res://demo/deer.vox)")
		}, "required": ["path"]},
		_handle_preview_resource)

	add_tool.call("render_model",
		"把模型资源(.qvx/.vox 导入成的 Mesh、.mesh, 或含 Mesh 的 .tscn)离屏渲染成 PNG, **相机可调**: yaw/pitch 角度、dist 缩放、size 分辨率、透明背景。与 preview_resource 的固定缩略图互补 —— 那个视角固定且小, 这个能逐角度/放大核对造型。返回 PNG 路径。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("资源 res:// 路径(如 res://demo/samples/cottage.qvx, 需已导入)"),
			"yaw": {"type": "number", "description": "水平角(度), 默认 35"},
			"pitch": {"type": "number", "description": "俯仰角(度), 默认 20, 范围 -85..85"},
			"dist": {"type": "number", "description": "相机距离 = dist × 模型包围球半径, 越小越放大, 默认 2.7"},
			"size": {"type": "integer", "description": "输出边长(像素), 默认 512, 范围 64..2048"},
			"bg": {"type": "string", "description": "背景色 #rrggbb, 默认 #2a2d33"},
			"transparent": {"type": "boolean", "description": "透明背景, 默认 false"}
		}, "required": ["path"]},
		_handle_render_model)


## ======= 实现 =======

static func _handle_open_scene(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var path := VariantTool.get_string(args, "path")
	if path.is_empty() or not ResourceLoader.exists(path):
		return MCPResult.fail("场景不存在: %s" % path)
	EditorInterface.open_scene_from_path(path)
	return MCPResult.ok("已打开场景 %s" % path)


## 设置主场景。
##
## **同一资源不重写**: 主场景在 project.godot 里常以 uid:// 形式存储, 而调用方几乎总是拿着
## res:// 路径(从 get_scene_tree / find_resource_users 得到的就是这个形式)。无条件写入会把
## uid:// 覆盖成 res:// —— 资源没变, project.godot 却多出一行无信息量的 diff, 而它会混进真正的
## 改动里被 review 掉。故先比资源身份(两种引用形式解析后相等即同一资源), 相同就不碰磁盘。
static func _handle_set_main_scene(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path").strip_edges()
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	var target := _to_res_path(path)
	if target.is_empty() or not ResourceLoader.exists(target):
		return MCPResult.fail("场景不存在: %s" % path)
	var current := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if not current.is_empty() and _to_res_path(current) == target:
		return MCPResult.ok("主场景已指向该场景(project.godot 存为 %s), 无需改动" % current)
	ProjectSettings.set_setting("application/run/main_scene", path)
	ProjectSettings.save()
	return MCPResult.ok("已设置主场景: %s" % path)


## uid:// 或裸路径 → res:// 路径, 解析不出来返回空串。
##
## 只为**比较**两个引用是否指向同一资源, 故不做 UID 缓存未就绪时的重扫兜底(那是
## MCPScriptSync.resolve_scene_path 的职责, 它的调用方需要拿到可直接用的路径)。此处解析失败
## 一律退回"两边原文不相等", 后果至多是多写一次内容相同的设置, 不会写错资源。
static func _to_res_path(ref: String) -> String:
	var s := ref.strip_edges()
	if s.begins_with("uid://"):
		return ResourceUID.uid_to_path(s)
	return FileTool.to_res_path(s)


## 项目设置项读写统一入口: value 缺省=读取, 提供=写入并保存
static func _handle_project_setting(args: Dictionary) -> Dictionary:
	if args.has("value"):
		return _handle_set_project_setting(args)
	return _handle_get_project_setting(args)


static func _handle_get_project_setting(args: Dictionary) -> Dictionary:
	var name := VariantTool.get_string(args, "name")
	if name.is_empty():
		return MCPResult.fail("必须提供 name")
	if not ProjectSettings.has_setting(name):
		return MCPResult.fail("不存在设置项: %s" % name)
	return MCPResult.ok_json({"name": name, "value": ProjectSettings.get_setting(name)})


## ======= 一处合法的裸读: "value" =======
##
## 下面 _handle_set_project_setting 的 "value" 走裸 args.get("value", null), 因为它的
## **目标类型事先未知**: 由用户任意指定。强行套进 VariantTool.get_* 反而会丢信息
## (get_string 会把数组/对象 str() 成一段文本)。
##
## 原文(主文件「统一入参读取」小节)的说明, 照搬备查:
##   set_node_property 与 set_project_setting 的 "value" 走裸 args.get("value", null),
##   因为它们的**目标类型事先未知**: 前者要靠 node.get(property) 的 typeof() 反推, 后者由用户
##   任意指定。这两处接 VariantTool.infer(猜类型) / VariantTool.coerce(对齐目标类型),
##   强行套进 get_* 反而会丢信息。除这两处外, handler 里的 args.get( 一律是漂移。
##
##   注意这是**约定而非守卫**: 契约自检(_audit_tools / MCPToolAudit.audit_handler_params)校验的是
##   "schema 声明了哪些键、schema 与 handler 声明是否一致", 不校验 handler 是否绕过
##   VariantTool 裸读。新增 handler 时只能靠自律 —— 这点必须写明, 否则后人会误以为
##   已经有检查兜着。想让它变成真守卫, 需在 MCPToolAudit.audit_handler_params 加一条: handler 源码中
##   出现 args.get( 且该键不在 VariantTool.get_* 调用列表中 → 报问题。
##
##   历史教训(留着提醒别走回头路): 主文件此前同时存在 `_to_bool`(支持 "true"/数字)与 9 处
##   绕过它的裸转, 而 `_arg_int` 更是长期零调用 —— 入口摆在那里却一行防护都没生效。
##   "同一个参数两种读法"长期共存, 每处裸转都是一个潜在的静默反转。
static func _handle_set_project_setting(args: Dictionary) -> Dictionary:
	var name := VariantTool.get_string(args, "name")
	if name.is_empty():
		return MCPResult.fail("必须提供 name")
	var value: Variant = args.get("value", null)
	# 防御: 部分 JSON→Variant 链路会把数组/对象退化为字符串(形如 ["a","b"]/{"k":1}),
	# 此处尝试还原为真正的 Variant, 保证数组类设置(如 PackedStringArray 语义项)可被原生读取。
	if value is String:
		var s := str(value).strip_edges()
		if (s.begins_with("[") and s.ends_with("]")) or (s.begins_with("{") and s.ends_with("}")):
			var parsed: Variant = JSON.parse_string(s)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	ProjectSettings.set_setting(name, value)
	ProjectSettings.save()
	return MCPResult.ok("已设置 %s = %s 并保存" % [name, str(value)])


static func _handle_save_all(_args: Dictionary) -> Dictionary:
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	var ps := ProjectSettings.save()
	return MCPResult.ok("已保存全部场景, 项目设置(err=%d)" % ps)


## 重新导入资源。
##
## **必须先确认该资源归导入系统管**: reimport_files 是拿同名 .import 去驱动导入器的, 而
## .gd/.json/.tres 等纯文本资源没有 .import(它们直接读源文件), 对它们调用不会"什么都不做",
## 而是让引擎在导入器查找处触发内部断言 —— 用户看到的是一句带 node.cpp 的晦涩 BUG 报错,
## 既没提路径也没提"这资源不需要导入"。这类"参数语义错但报成引擎故障"的错最费时间, 故挡在调用前。
static func _handle_reimport(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	if path.is_empty() or not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	if not FileAccess.file_exists(path + ".import"):
		return MCPResult.fail("%s 不由导入系统管理(无同名 .import), 无法重新导入。\n纯文本资源(.gd/.tres/.json/.csv 等)改完直接生效, 无需导入; 图片/音频/模型等二进制资源才有 .import。" % path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return MCPResult.fail("编辑器文件系统不可用")
	fs.reimport_files([path])
	return MCPResult.ok("已触发重新导入: %s" % path)


## 创建 .tres 资源配置
static func _handle_create_resource(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var script_ref := VariantTool.get_string(args, "script")
	var properties: Dictionary = VariantTool.get_dict(args, "properties")
	if path.is_empty() or script_ref.is_empty():
		return MCPResult.fail("必须提供 path 和 script")
	if not path.ends_with(".tres"):
		return MCPResult.fail("路径必须以 .tres 结尾: %s" % path)
	# 解析脚本: class_name 或 res:// 脚本路径
	var script: Script = null
	if script_ref.begins_with("res://"):
		script = load(script_ref) as Script
	elif script_ref.begins_with("class:"):
		script = load(script_ref.trim_prefix("class:")) as Script
	else:
		# 全局类名(如 ChangelogDef): 查全局类列表找脚本路径
		var all_classes := ProjectSettings.get_global_class_list()
		for c in all_classes:
			if str(c.get("class", "")) == script_ref:
				script = load(str(c.get("path", ""))) as Script
				break
		if script == null:
			# 兜底: 尝试当作 res:// 相对路径
			script = load("res://" + script_ref) as Script
	if script == null:
		return MCPResult.fail("找不到脚本 %s (新建脚本请先 restart_editor)" % script_ref)
	if not script.can_instantiate():
		return MCPResult.fail("脚本 %s 不可实例化(abstract/@tool 缺失?)" % script_ref)
	var res: Resource = script.new() as Resource
	if res == null:
		return MCPResult.fail("脚本实例化失败: %s" % script_ref)
	# 设置属性(逐项, 用自动类型转换)
	for key in properties:
		if not res.has_method("set") and not (key in res):
			return MCPResult.fail("属性不存在: %s" % key)
		var v: Variant = VariantTool.infer(properties[key])
		res.set(key, v)
	# 确保目录存在并保存
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var dir := DirAccess.open(dir_path)
		if dir == null:
			var err := DirAccess.make_dir_recursive_absolute(dir_path)
			if err != OK:
				return MCPResult.fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return MCPResult.fail("保存资源失败: %s (错误码: %d)" % [path, err])
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
	return MCPResult.ok_json({
		"path": path,
		"script": script_ref,
		"properties": properties,
		"message": "资源配置创建成功(建议 restart_editor 让编辑器识别新资源)"
	})


## 读取资源的完整属性树
static func _handle_get_resource_info(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var max_depth := VariantTool.get_int(args, "max_depth", 5)
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	var res: Resource = ResourceLoader.load(path)
	if res == null:
		return MCPResult.fail("资源加载失败: %s" % path)
	var info := {
		"path": path,
		"type": res.get_class(),
		"script": res.get_script().resource_path if res.get_script() else null,
		"name": res.resource_name if res is Resource else "",
		"properties": _resource_property_tree(res, 0, max_depth),
	}
	return MCPResult.ok_json(info)


## ======= 专属辅助函数(只被本域使用) =======

## 递归收集资源导出属性(含嵌套子资源)
static func _resource_property_tree(res: Resource, depth: int, max_depth: int) -> Dictionary:
	var out := {}
	if depth > max_depth:
		return {"_note": "达到最大深度, 停止展开"}
	for p in res.get_property_list():
		var pname: String = str(p.name)
		# 跳过内置元数据与脚本引用(避免噪音)
		if pname.begins_with("_") or pname in ["resource_path", "resource_name", "script", "resource_local_to_scene"]:
			continue
		var val: Variant = res.get(pname)
		if val is Resource:
			if val == res:
				out[pname] = {"_self_ref": true}
			else:
				out[pname] = _resource_property_tree(val, depth + 1, max_depth)
		elif val is Dictionary:
			out[pname] = {"_dict_size": (val as Dictionary).size()}
		elif val is Array:
			out[pname] = {"_array_size": (val as Array).size(), "_type": _value_type(val)}
		else:
			out[pname] = {"value": val, "type": _value_type(val)}
	return out


static func _value_type(v: Variant) -> String:
	return type_string(typeof(v))


## ======= resources 协议端点(静态文档索引) =======
##
## 为什么需要: LAYERS.md 与各模块 Readme.md 是这个项目的**约定载体**(比如"框架=机制、
## 项目=内容, 新代码该放哪"的判定清单), 但它们此前没有任何 MCP 入口 —— AI 要读到只能靠
## eval_code 现场 FileAccess 打开。那样做有两个坏处: 绕开了统一的截断统计, 且把一次
## 声明式的读取变成了执行任意代码。
##
## 刻意**只给索引而非全文**: 最大一份 57KB(约 20K token), 一次性灌进上下文既挤掉后续工具
## 调用的额度, 也会把真正相关的那几段埋掉。故 read_resource 返回「标题索引 + 开头预览」,
## 全文按需用 read_file(offset/limit) 续读 —— read_file 加游标与这条路径是配套的, 否则模型
## 拿到索引却读不到内容, 那只是把"读不到"换成了"不知道从哪读起"。
##
## 白名单而非任意路径: uri 由客户端提供, 放开等于凭空多一个文件读取面, 而那件事 read_file
## 已经做完了(带路径守卫)。这里只做 read_file 做不到的那一件: 把静态知识**声明出来**,
## 让模型知道它存在 —— 可见性本身就是价值。

const _RESOURCE_DOCS := [
	{"uri": "res://addons/DEVFramework/LAYERS.md", "name": "分层约定(框架 vs 项目)",
		"desc": "新代码放哪的判定清单、框架红线与历史案例。写任何新代码前必读。"},
	{"uri": "res://addons/DEVFramework/Readme.md", "name": "DEVFramework 使用说明",
		"desc": "框架总览: 各模块入口与用法索引。体量最大, 建议先取标题索引再按需精读。"},
	{"uri": "res://addons/DEVFramework/ECS/Readme.md", "name": "ECS 使用说明",
		"desc": "ECS 实体组件系统: SoA 列存、命令缓冲、prefab 批量实例化、存档。"},
	{"uri": "res://addons/DEVFramework/Camera/Readme.md", "name": "Camera 虚拟机位",
		"desc": "Camera 模块: 机位(视角/跟随/blend)与面板类 UI 的机位切换。"},
	{"uri": "res://addons/DEVFramework/AI/Readme.md", "name": "GOAP AI",
		"desc": "GOAP 目标导向 AI: 目标声明、行动规划、世界状态变化触发重规划。"},
	{"uri": "res://addons/DEVFramework/Task/Readme.md", "name": "Task 任务 + 新手教程",
		"desc": "Task 任务系统与 Tutorial 新手引导: 配置式步骤、指针事件放行、CSV 翻译。"},
	{"uri": "res://addons/DEVFramework/GameCommand/Readme.md", "name": "GameCommand 命令",
		"desc": "GameCommand: 命令记录与回放。"},
]

## resources/read 的开头预览字符数上限。取 3000 是权衡: 足够看出写法约定与目录结构,
## 又不至于挤占一次工具调用的额度; 真要读全文走 read_file 的 offset/limit。
const _RESOURCE_PREVIEW_CHARS := 3000

## 标题索引条数上限。同上理由: 索引本身不该变成噪声。
const _RESOURCE_MAX_HEADINGS := 80


## resources/list 的响应体。由 MCPDevServer._handle_jsonrpc 的 resources/list 分支调用。
static func list_resources() -> Array:
	var out: Array = []
	for d in _RESOURCE_DOCS:
		out.append({
			"uri": d["uri"],
			"name": d["name"],
			"description": d["desc"],
			"mimeType": "text/markdown",
		})
	return out


## resources/read 的 result 体。成功返回 {contents:[...]}, 失败直接返回 MCPResult 的
## validation 错误(自带 content + isError) —— 两种情况都是合法 result, 调用方不必分支处理
## 两种错误形状。
##
## 索引/预览/续读提示全部拼进 contents[].text, 而**不**放成并列字段: 规范下客户端只保证
## 把 text 交给模型, 写进并列字段的东西模型看不到, 那等于白写。
static func read_resource(uri: String) -> Dictionary:
	var entry: Dictionary = {}
	for d in _RESOURCE_DOCS:
		if d["uri"] == uri:
			entry = d
			break
	if entry.is_empty():
		return MCPResult.err_validation("未登记的资源 uri: %s" % uri,
			"先调 resources/list 取可用 uri(共 %d 份文档); 若只是想读任意文件, 用 read_file(带路径守卫)" % _RESOURCE_DOCS.size())
	if not FileAccess.file_exists(uri):
		return MCPResult.err_validation("文档不存在: %s" % uri, "文件可能已被移动或改名, 请用 resources/list 复核可用 uri")
	var text := FileAccess.get_file_as_string(uri)
	var total := text.length()
	var body := "[文档] %s\n[说明] %s\n[标题索引]\n%s\n\n[开头预览 前%d字符 / 全文%d字符]\n%s\n\n[续读] 读全文用 read_file(path=\"%s\", offset=<字符下标>, limit=<本次要读的字符数>), 按返回的 next_char_offset 接下一段; next_char_offset 为 -1 表示已读完。" % [
		str(entry["name"]),
		str(entry["desc"]),
		"\n".join(PackedStringArray(_markdown_headings(text))),
		_RESOURCE_PREVIEW_CHARS,
		total,
		text.substr(0, _RESOURCE_PREVIEW_CHARS),
		uri,
	]
	return {
		"contents": [{
			"uri": uri,
			"name": str(entry["name"]),
			"description": str(entry["desc"]),
			"mimeType": "text/markdown",
			"text": body,
		}],
	}


## 提取 markdown 标题作为目录索引。**必须跳过围栏代码块**: 文档里有大量以 # 开头的
## GDScript 注释, 不过滤索引会被这些注释灌满, 而真正的小节标题埋在中间 —— 那样的索引
## 比没有索引更糟, 因为它看起来是有用的。
## 只收前三级(#/##/###): 更深的层级在这些文档里通常是补充说明而非章节, 全收会显著拉长索引。
static func _markdown_headings(text: String) -> Array[String]:
	var out: Array[String] = []
	var in_fence := false
	for line in text.split("\n"):
		if line.begins_with("```"):
			in_fence = not in_fence
			continue
		if in_fence:
			continue
		var s: String = line.strip_edges()
		if s.length() < 2 or not s.begins_with("#"):
			continue
		var hashes := 0
		while hashes < s.length() and s[hashes] == "#":
			hashes += 1
		if hashes > 3:
			continue
		# "#" 后必须紧跟空白才是标题(ATX 规范), 否则 "#hashtag" 这类普通文本会被误收。
		if s.length() > hashes and s[hashes] != " " and s[hashes] != "\t":
			continue
		out.append(s)
		if out.size() >= _RESOURCE_MAX_HEADINGS:
			out.append("...(标题过多, 已截断)")
			break
	return out


## preview_resource: 取编辑器生成的资源预览缩略图 → 存 PNG。
## 【为什么用 EditorResourcePreview】那是 FileSystem 面板出缩略图的**同一套机制**: 对"已导入资源"
## (含 .vox/.qvx 导入成的 .mesh)自动可用, 不必自己搭离屏渲染。代价是**异步回调** + 缩略图尺寸。
## 回调经 PreviewReceiver(把异步结果转成可 await 信号的 RefCounted)接住。
static func _handle_preview_resource(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var path := str(args.get("path", ""))
	if path.is_empty():
		return MCPResult.fail("path 不能为空")
	var recv := PreviewReceiver.new()
	EditorInterface.get_resource_previewer().queue_resource_preview(path, recv, &"_on_preview", null)
	# 轮询 + 超时兜底：回调可能因资源没导入 / 类型无生成器而永不到来，不能无限挂起（会卡死工具调用）。
	var deadline := Time.get_ticks_msec() + 5000
	while recv.tex == null and Time.get_ticks_msec() < deadline:
		await Engine.get_main_loop().process_frame
	var tex: Texture2D = recv.tex
	if tex == null:
		return MCPResult.fail("拿不到预览（该资源可能没导入，或类型没有预览生成器）: %s" % path)
	var img := tex.get_image()
	if img == null:
		return MCPResult.fail("预览纹理没有图像数据: %s" % path)
	var dir := "user://mcp_previews"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var out_path := "%s/%s.png" % [dir, path.get_file()]
	var err := img.save_png(out_path)
	if err != OK:
		return MCPResult.fail("保存预览失败（错误码 %d）" % err)
	return MCPResult.ok_json({"path": out_path, "width": img.get_width(), "height": img.get_height()})


## EditorResourcePreview 的回调接收器：把异步结果存下来，供调用方轮询。
class PreviewReceiver extends RefCounted:
	var tex: Texture2D

	func _on_preview(_path: String, preview: Texture2D, _thumbnail: Texture2D, _ud: Variant) -> void:
		tex = preview


## ======= render_model: 可调相机的离屏渲染预览 =======
##
## 【为什么不复用 preview_resource】那是 FileSystem 缩略图机制(EditorResourcePreview): 视角固定、
## 尺寸由编辑器设置决定, **没有任何角度/缩放入参**(见该工具说明)。想要"自由调角度、放大缩小"就得
## 自建离屏渲染: 一个 SubViewport + Camera3D, 相机位置由 yaw/pitch/dist 决定。
##
## 【为什么挂在编辑器根控件下】SubViewport 只要在场景树里且 update_mode != DISABLED 就会渲染到自己的
## 纹理(不需要 SubViewportContainer 显示)。挂在 base_control 下即随编辑器帧循环出图, 读完即释放,
## 不干扰用户界面。
##
## 【为什么等几帧】刚 add_child 时子视口尚未产出画面; get_texture().get_image() 要等至少一帧渲染
## 完成才有内容。取 4 帧留足余量(编辑器帧循环下代价可忽略)。
static func _handle_render_model(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var path := VariantTool.get_string(args, "path").strip_edges()
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	var res := ResourceLoader.load(path)
	var content := _renderable_from(res)
	if content == null:
		return MCPResult.fail("该资源无法渲染(需要 Mesh / PackedScene / Node3D): %s" % path)
	var size := clampi(VariantTool.get_int(args, "size", 512), 64, 2048)
	var yaw := VariantTool.get_float(args, "yaw", 35.0)
	var pitch := clampf(VariantTool.get_float(args, "pitch", 20.0), -85.0, 85.0)
	var dist := maxf(VariantTool.get_float(args, "dist", 2.7), 0.2)
	var bg := VariantTool.get_string(args, "bg", "#2a2d33")
	var transparent := VariantTool.get_bool(args, "transparent", false)

	var parent := EditorInterface.get_base_control()
	if parent == null:
		return MCPResult.fail("拿不到编辑器根控件, 无法离屏渲染")

	var vp := SubViewport.new()
	vp.size = Vector2i(size, size)
	vp.transparent_bg = transparent
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	parent.add_child(vp)

	vp.add_child(_make_render_env(bg))
	vp.add_child(content)
	var cam := Camera3D.new()
	cam.fov = 45.0
	vp.add_child(cam)
	cam.current = true

	# content 已入树, get_aabb() 给的是含变换的包围盒 → 按其中心/包围球半径摆相机
	var box := _content_aabb(content)
	var center := box.get_center()
	var radius := box.size.length() * 0.5
	if radius <= 0.0001:
		radius = 0.5
	var yr := deg_to_rad(yaw)
	var pr := deg_to_rad(pitch)
	var dir := Vector3(cos(pr) * sin(yr), sin(pr), cos(pr) * cos(yr)).normalized()
	cam.position = center + dir * (radius * dist)
	cam.look_at(center, Vector3.UP)

	for _i in 4:
		await Engine.get_main_loop().process_frame
	var tex := vp.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	vp.queue_free()
	if img == null:
		return MCPResult.fail("离屏渲染没有产出图像(窗口渲染可能被禁用)")
	var out_dir := "user://mcp_previews"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out_path := "%s/render_%s_%d.png" % [out_dir, path.get_file().get_basename(), Time.get_ticks_usec()]
	var err := img.save_png(out_path)
	if err != OK:
		return MCPResult.fail("保存渲染图失败(错误码 %d)" % err)
	return MCPResult.ok_json({
		"path": out_path, "width": img.get_width(), "height": img.get_height(),
		"yaw": yaw, "pitch": pitch, "dist": dist,
	})


## 资源 → 可渲染节点(未入树)。Mesh 包一层 MeshInstance3D; PackedScene 实例化; 其余 Node3D 原样。
static func _renderable_from(res: Resource) -> Node:
	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res
		return mi
	if res is PackedScene:
		var inst := (res as PackedScene).instantiate()
		if inst is Node3D:
			return inst
		if inst is Node:
			var holder := Node3D.new()
			holder.add_child(inst)
			return holder
	return null


## 一个带环境(背景色 + 环境光)与主光的 WorldEnvironment。
static func _make_render_env(bg: String) -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.html(bg) if Color.html_is_valid(bg) else Color(0.16, 0.18, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)
	we.add_child(sun)
	return we


## 节点子树里全部有网格的 MeshInstance3D 的合并包围盒(global 空间)。
static func _content_aabb(node: Node) -> AABB:
	var box := AABB()
	var found := false
	for mi in _render_mesh_instances(node):
		var a: AABB = mi.get_aabb()
		if found:
			box = box.merge(a)
		else:
			box = a
			found = true
	if not found:
		box = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	return box


static func _render_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		out.append_array(_render_mesh_instances(c))
	return out
