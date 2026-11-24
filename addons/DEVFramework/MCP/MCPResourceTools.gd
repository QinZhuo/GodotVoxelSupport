@tool
extends RefCounted

## ======= 资源与项目设置域 =======
## 打开场景、读写项目设置、创建/读取 .tres、重新导入、预览与离屏渲染。
## 全部走 res:// 路径, 依赖 EditorInterface —— 只在编辑器进程注册。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")
const MCPScreenshotTools := preload("res://addons/DEVFramework/MCP/MCPScreenshotTools.gd")

## 预览/渲染图每调用一次新增一个文件, 不设上限会堆出几百个没人看的中间产物。
## 落盘产物属"可重建", 保留最近 N 个足够回看; 要长期留存请自己挪出这个目录。
const MAX_PREVIEWS := 32
## 截图留得比预览多一点(截图常被拿去当对照证据), 但同样要有上限。
const MAX_SHOTS := 64


## ======= 域注册入口 =======
static func register(add_tool: Callable) -> void:
	add_tool.call("open_scene",
		"在编辑器打开场景(res://路径)。",
		{"type": "object", "properties": {"path": MCPToolContract.str_arg("场景 res:// 路径")}, "required": ["path"]},
		_handle_open_scene)

	add_tool.call("set_main_scene",
		"设置项目主场景并保存project.godot。",
		{"type": "object", "properties": {"path": MCPToolContract.str_arg("主场景 res:// 路径")}, "required": ["path"]},
		_handle_set_main_scene)

	add_tool.call("project_setting",
		"读写任意项目设置项(如 application/config/name)。value 缺省=读取; 提供 value=写入并保存。数组/对象值会自动还原为真正的 Variant。",
		{"type": "object", "properties": {
			"name": {"type": "string", "description": "设置项名称"},
			"value": {"description": "可选: 新值; 缺省则只读"}
		}, "required": ["name"]},
		_handle_project_setting)

	add_tool.call("save",
		"保存当前场景或全部已打开场景 + 项目设置。scope=scene(默认)只存当前编辑场景; scope=all 存全部场景并写 project.godot。'只存当前场景'与'存全部'是同一个问题的两个取值, 分成两个工具会让人赌'没有别的场景是脏的'。",
		{"type": "object", "properties": {
			"scope": {"type": "string", "enum": ["scene", "all"], "description": "保存范围, 默认 scene=当前编辑场景; all=全部已打开场景 + 项目设置"},
		}},
		_handle_save)

	add_tool.call("reimport",
		"重新导入资源(重建.godot/imported缓存), 资源显示异常/导入配置变更后使用。仅对有同名 .import 的资源有效(图片/音频/模型等); .gd/.tres/.json 等纯文本资源无需导入。",
		{"type": "object", "properties": {"path": MCPToolContract.str_arg("要重新导入的资源 res:// 路径")}, "required": ["path"]},
		_handle_reimport)

	add_tool.call("create_resource",
		"创建 .tres 资源配置: 指定脚本(class_name 或 res://脚本路径)与属性字典, 写入 res:// 或 user:// 路径。配置驱动开发时创建 Def 资源用。注意: 新建脚本 class_name 需先 restart_editor 才能被引擎识别, 若创建失败请先 reload。",
		{"type": "object", "properties": {
			"path": MCPToolContract.str_arg("要创建的 .tres 完整路径(如 res://Assets/Def/MyDef.tres)"),
			"script": {"type": "string", "description": "脚本 class_name 或 res:// 脚本路径(如 ChangelogDef 或 res://addons/.../ChangelogDef.gd)"},
			"properties": {"type": "object", "description": "属性字典(键=导出属性名, 值=属性值), 可嵌套资源/数组"}
		}, "required": ["path", "script"]},
		_handle_create_resource)

	add_tool.call("resource_inspect",
		"检视一个资源, mode 决定看什么。tree(默认)=读 .tres/.tscn 的完整属性树(递归): 返回类型/导出属性/嵌套子资源/引用的脚本, **对 .tscn 还给出节点结构(root/各节点 path+type+script), 无需先在编辑器打开**; 但要读运行时属性值仍需 open_scene 后用 get_scene_tree / get_node_info。thumbnail=取编辑器为它生成的**预览缩略图**(视角固定、尺寸由编辑器缩略图设置决定), path 传**源文件**(如 .vox, 需已导入)。render=离屏渲染, **相机可调**(yaw/pitch/dist/size/bg/transparent), 用于逐角度放大核对造型。thumbnail/render 产出只是落盘 PNG, 删掉即回退。",
		{"type": "object", "properties": {
			"path": MCPToolContract.str_arg("资源路径: tree 传 .tres/.tscn; thumbnail 传已导入的源文件(如 .vox); render 传 Mesh/.mesh/含 Mesh 的 .tscn"),
			"mode": {"type": "string", "enum": ["tree", "thumbnail", "render"], "description": "检视方式, 默认 tree=属性树; thumbnail=编辑器缩略图(视角固定); render=离屏渲染(相机可调)"},
			"max_depth": {"type": "integer", "description": "mode=tree: 嵌套资源最大展开深度, 默认 5"},
			"yaw": {"type": "number", "description": "mode=render: 水平角(度), 默认 35"},
			"pitch": {"type": "number", "description": "mode=render: 俯仰角(度), 默认 20, 范围 -85..85"},
			"dist": {"type": "number", "description": "mode=render: 相机距离 = dist × 模型包围球半径, 越小越放大, 默认 2.7"},
			"size": {"type": "integer", "description": "mode=render: 输出边长(像素), 默认 512, 范围 64..2048"},
			"bg": {"type": "string", "description": "mode=render: 背景色 #rrggbb, 默认 #2a2d33"},
			"transparent": {"type": "boolean", "description": "mode=render: 透明背景, 默认 false"}
		}, "required": ["path"]},
		_handle_resource_inspect)


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
static func _to_res_path(ref: String) -> String:
	var s := ref.strip_edges()
	if s.begins_with("uid://"):
		return ResourceUID.uid_to_path(s)
	return FileTool.to_res_path(s)


## 项目设置项读写统一入口: value 缺省=读取, 提供=写入并保存。
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
## 读写合一: value 缺省=读取, 提供=写入, 故不能用 VariantTool.get_* 判别缺省。
## 这是**约定而非守卫**: 契约自检只校验 VariantTool 写法, 新增 handler 需自律。
static func _handle_set_project_setting(args: Dictionary) -> Dictionary:
	var name := VariantTool.get_string(args, "name")
	if name.is_empty():
		return MCPResult.fail("必须提供 name")
	var value: Variant = args.get("value", null)
	# 防御: 部分 JSON→Variant 链路会把数组/对象退化为字符串(形如 ["a","b"]/{"k":1})。
	if value is String:
		var s := str(value).strip_edges()
		if (s.begins_with("[") and s.ends_with("]")) or (s.begins_with("{") and s.ends_with("}")):
			var parsed: Variant = JSON.parse_string(s)
			if parsed is Array or parsed is Dictionary:
				value = parsed
	ProjectSettings.set_setting(name, value)
	ProjectSettings.save()
	return MCPResult.ok("已设置 %s = %s 并保存" % [name, str(value)])


## 保存(scope=scene|all)。两个取值是两种意图: 想只存当前时不该去赌"没有别的场景是脏的",
## 故合成一个工具用 scope 区分, 而不是两个工具。
static func _handle_save(args: Dictionary) -> Dictionary:
	var scope := VariantTool.get_string(args, "scope", "scene").strip_edges()
	if scope.is_empty():
		scope = "scene"
	if scope != "scene" and scope != "all":
		return MCPResult.fail("未知的 scope: '%s'(只能是 scene 或 all)" % scope)
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用(保存的是编辑器里打开的场景)")
	if scope == "scene":
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return MCPResult.fail("当前没有正在编辑的场景。要存全部已打开的场景请用 scope=all")
		var ps_scene := EditorInterface.save_scene()
		return MCPResult.ok_json({
			"scope": "scene",
			"scene": str(root.scene_file_path),
			"error_code": ps_scene,
			"message": "已保存当前场景" if ps_scene == OK else "保存当前场景失败(错误码 %d)" % ps_scene,
		})
	# save_all_scenes() 返回 void, 拿不到逐场景的错误码 —— 只能报"已请求保存"。
	EditorInterface.save_all_scenes()
	var ps := ProjectSettings.save()
	return MCPResult.ok_json({
		"scope": "all",
		"project_settings_error_code": ps,
		"message": "已保存全部打开的场景, 项目设置(err=%d)" % ps,
	})


## 重新导入资源。
## **必须先确认该资源归导入系统管**: reimport_files 是拿同名 .import 去驱动导入器的, 目录里的源文件不归它管。
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
	# 回读自检: 属性设错(set 静默失败)或脚本 @export 类型不符时, 上面的 set() 不会报错,
	# 只有落盘后重新 load 才看得出来。不校验就会得到"创建成功但字段是默认值"的假成功。
	var readback := ResourceLoader.load(path)
	if readback == null:
		return MCPResult.fail("资源已写入但无法回读加载(文件可能损坏): %s" % path)
	var mismatched: Array = []
	for key2 in properties:
		if not _has_resource_property(readback, key2):
			mismatched.append(str(key2))
			continue
		var want: Variant = VariantTool.infer(properties[key2])
		var got: Variant = readback.get(key2)
		if typeof(got) != typeof(want) or str(got) != str(want):
			mismatched.append(str(key2))
	var out := {
		"path": path,
		"script": script_ref,
		"properties": properties,
		"verified": true,
		"readback_type": readback.get_class(),
		"message": "资源配置创建成功并已回读校验(建议 restart_editor 让编辑器识别新资源)",
	}
	if not mismatched.is_empty():
		out["verified"] = false
		out["mismatched_properties"] = mismatched
		out["message"] = "资源配置已保存, 但回读发现 %d 个属性与写入值不一致: %s。多半是脚本 @export 类型不匹配或属性名写错(未被 @export 导出的属性不会落盘)。" % [mismatched.size(), ", ".join(mismatched)]
	return MCPResult.ok_json(out)


## 回读校验用: 该属性是否真的存在于资源上(排除"写进去但没落盘"的假成功)。
static func _has_resource_property(res: Resource, key: String) -> bool:
	for info in res.get_property_list():
		if str(info.get("name", "")) == key:
			return true
	return false


## resource_inspect 的统一入口: mode 决定看属性树还是出图。
static func _handle_resource_inspect(args: Dictionary) -> Dictionary:
	var mode := VariantTool.get_string(args, "mode", "tree").strip_edges()
	if mode.is_empty():
		mode = "tree"
	if mode == "tree":
		return _inspect_tree(args)
	if mode == "thumbnail" or mode == "render":
		return await _inspect_image(args)
	return MCPResult.fail("未知的 mode: '%s'(只能是 tree / thumbnail / render)" % mode)


## mode=tree: 资源属性树(+ .tscn 的节点结构)。
static func _inspect_tree(args: Dictionary) -> Dictionary:
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
	info.merge(_scene_structure(res, max_depth), true)
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


## .tscn 的节点结构: PackedScene 本身只有内建属性, 节点树要实例化才拿得到。
## 实例化后不入树、读完即 free, 对当前编辑场景零副作用 —— 未打开的场景也能看清结构。
static func _scene_structure(res: Resource, max_depth: int) -> Dictionary:
	if not (res is PackedScene):
		return {}
	var inst := (res as PackedScene).instantiate()
	if inst == null:
		return {"scene_error": "场景实例化失败(.tscn 可能损坏或缺少依赖脚本)"}
	var root_info := _walk_scene_nodes(inst, str(inst.name), 0, max_depth)
	var out := {"root": String(inst.name), "node_count": int(root_info.get("_count", 1)), "nodes": root_info}
	root_info.erase("_count")
	inst.free()
	return out


## 递归收集节点: {path, name, type[, script][, children]}; path 自己拼, 因为实例化但未入树的
## 节点没有可用的 get_path()。_count 供上层统计节点总数, 返回前会被摘掉。
static func _walk_scene_nodes(node: Node, path: String, depth: int, max_depth: int) -> Dictionary:
	var out := {"path": path, "name": String(node.name), "type": node.get_class(), "_count": 1}
	if node.get_script() != null:
		out["script"] = node.get_script().resource_path
	if depth >= max_depth:
		if node.get_child_count() > 0:
			out["_truncated"] = node.get_child_count()
			out["_count"] = 1 + _subtree_size(node)
		return out
	var kids: Array = []
	var total := 1
	for child in node.get_children():
		var sub := _walk_scene_nodes(child, "%s/%s" % [path, child.name], depth + 1, max_depth)
		total += int(sub.get("_count", 1))
		sub.erase("_count")
		kids.append(sub)
	if not kids.is_empty():
		out["children"] = kids
	out["_count"] = total
	return out


## 只数节点数, 不建结构(用于被深度截断的分支如实报 total)。
static func _subtree_size(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		n += 1 + _subtree_size(child)
	return n


static func _value_type(v: Variant) -> String:
	return type_string(typeof(v))


## mode=thumbnail|render: 出一张 PNG(两个旧工具只差相机能不能调, 故合成一个)。
static func _inspect_image(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return MCPResult.fail("path 不能为空")
	var mode := VariantTool.get_string(args, "mode", "thumbnail").strip_edges()
	if mode.is_empty():
		mode = "thumbnail"
	if mode == "render":
		return await _preview_by_render(path, args)
	if mode != "thumbnail":
		return MCPResult.fail("未知的 mode: '%s'(只能是 thumbnail 或 render)" % mode)
	# thumbnail 走的是**源文件**路径(如 .vox), 它可能还没被导入成 Resource,
	# 但既然编辑器都没有它的缩略图, 早点给出可读的原因比等 5 秒超时有用。
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
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
	# 用 get_basename 去掉源扩展名, 免得出现 icon.png.png。
	var out_path := "%s/%s.png" % [dir, path.get_file().get_basename()]
	var err := img.save_png(out_path)
	if err != OK:
		return MCPResult.fail("保存预览失败（错误码 %d）" % err)
	_prune_dir(dir, MAX_PREVIEWS, "")
	return MCPResult.ok_json({
		"path": out_path, "width": img.get_width(), "height": img.get_height(), "mode": "thumbnail",
	})


## 目录超量后按修改时间删最旧的(previews 与 screenshots 共用)。
## **只碰自己产出的文件**: 同一个截图目录里还有用户手工截的图与测试产物(前缀各不相同),
## 按目录全清会替别人删证据 —— 所以必须给前缀, 只统计/淘汰匹配前缀的那些。
static func _prune_dir(dir_res: String, keep: int, prefix: String) -> void:
	var dir := DirAccess.open(dir_res)
	if dir == null:
		return
	var entries: Array = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and (prefix.is_empty() or entry.begins_with(prefix)):
			var full := dir_res.path_join(entry)
			entries.append({"path": full, "mtime": FileAccess.get_modified_time(full)})
		entry = dir.get_next()
	dir.list_dir_end()
	if entries.size() <= keep:
		return
	entries.sort_custom(func(a, b): return int(a["mtime"]) < int(b["mtime"]))
	for i in entries.size() - keep:
		DirAccess.remove_absolute(str(entries[i]["path"]))


## EditorResourcePreview 的回调接收器：把异步结果存下来，供调用方轮询。
class PreviewReceiver extends RefCounted:
	var tex: Texture2D

	func _on_preview(_path: String, preview: Texture2D, _thumbnail: Texture2D, _ud: Variant) -> void:
		tex = preview


## ======= resource_inspect(mode=render): 可调相机的离屏渲染 =======
static func _preview_by_render(path: String, args: Dictionary) -> Dictionary:
	if not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	var res := ResourceLoader.load(path)
	var content := _renderable_from(res)
	if content == null:
		return MCPResult.fail("该资源无法渲染(需要 Mesh / PackedScene / Node3D): %s" % path)
	var img: Image = await _render_to_image(content, args)
	if img == null:
		return MCPResult.fail("离屏渲染没有产出图像(窗口渲染可能被禁用)")
	var yaw := VariantTool.get_float(args, "yaw", 35.0)
	var pitch := clampf(VariantTool.get_float(args, "pitch", 20.0), -85.0, 85.0)
	var dist := maxf(VariantTool.get_float(args, "dist", 2.7), 0.2)
	var out_dir := "user://mcp_previews"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out_path := "%s/render_%s_%d.png" % [out_dir, path.get_file().get_basename(), Time.get_ticks_usec()]
	var err := img.save_png(out_path)
	if err != OK:
		return MCPResult.fail("保存渲染图失败(错误码 %d)" % err)
	_prune_dir(out_dir, MAX_PREVIEWS, "")
	var out := MCPResult.ok_json({
		"path": out_path, "width": img.get_width(), "height": img.get_height(),
		"yaw": yaw, "pitch": pitch, "dist": dist,
	})
	# 渲染图的意义就是"看一眼造型": 只回路径等于让调用方再走一趟读图。
	return MCPResult.attach_image(out, out_path)


## ======= 离屏渲染的共用底座(预览 / 场景缩略图都走这里) =======
## 只有这一个底座: 相机/灯光/环境/尺寸/透明底全由 args 决定, 调用方只选"渲染什么"。
## 各写一套的后果是同样的模型在不同入口亮度不同 —— 差异纯属实现漂移。

## 离屏渲染一个节点子树, 返回 Image(null = 拿不到画面)。不落盘, 由调用方决定存哪。
## args: size(默认 512) / yaw / pitch / dist / bg / transparent
static func _render_to_image(content: Node, args: Dictionary) -> Image:
	var size := clampi(VariantTool.get_int(args, "size", 512), 64, 2048)
	var yaw := VariantTool.get_float(args, "yaw", 35.0)
	var pitch := clampf(VariantTool.get_float(args, "pitch", 20.0), -85.0, 85.0)
	var dist := maxf(VariantTool.get_float(args, "dist", 2.7), 0.2)
	var bg := VariantTool.get_string(args, "bg", "#2a2d33")
	var transparent := VariantTool.get_bool(args, "transparent", false)
	var parent := EditorInterface.get_base_control()
	if parent == null:
		return null
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
	return img


## 把一张图交给 ScreenshotTool 落盘(颜色处理/缩放/命名全在那里, 本域不再重复一套)。
static func save_shot(img: Image, capture_type: String, args: Dictionary) -> Dictionary:
	var opts := {
		"dir": ScreenshotTool.DEFAULT_DIR_RES,
		"prefix": "mcp",
		"max_width": VariantTool.get_int(args, "max_width", ScreenshotTool.DEFAULT_MAX_WIDTH),
		"capture_type": capture_type,
	}
	opts.merge(MCPScreenshotTools.color_opts(args))
	var out := ScreenshotTool.save_image(img, opts)
	# 截图同样是有一次调用就多一个文件: 给个上限, 免得 res://.godot 里堆满再也没人看的 PNG。
	if bool(out.get("ok", false)):
		_prune_dir(str(out.get("res_path", "")).get_base_dir(), MAX_SHOTS, "mcp_")
	return out


## 给"当前编辑场景"拍一张缩略图 —— 截图域 take_screenshot(capture_type=scene) 的编辑器侧实现。
## 走同一个渲染底座, 只是把"当前场景"实例化后交给它; 参数可覆盖 size/bg/transparent/相机。
static func scene_thumbnail(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return MCPResult.fail("当前没有打开的场景")
	var scene_path := root.get_scene_file_path()
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return MCPResult.fail("当前场景尚未保存到磁盘, 无法缩略绘制: %s" % scene_path)
	var res: Resource = ResourceLoader.load(scene_path)
	if not res is PackedScene:
		return MCPResult.fail("当前场景不是 PackedScene: %s" % scene_path)
	var inst := (res as PackedScene).instantiate()
	if not (inst is Node3D):
		return MCPResult.fail("场景缩略图只支持 3D 场景(根节点为 Node3D): %s" % scene_path)
	# 缩略图默认给足留白: 尺寸偏小、背景透明、相机拉远一点, 与编辑器 FileSystem 里的观感接近。
	var opts := {"size": 256, "transparent": true, "dist": 3.0}
	opts.merge(args)
	# caller 传的 max_width 是"落盘缩放", 与渲染尺寸无关, 别让它污染渲染参数。
	var img: Image = await _render_to_image(inst, opts)
	inst.queue_free()
	if img == null:
		return MCPResult.fail("场景缩略图渲染失败(无法取得画面)")
	var shot := save_shot(img, "scene", args)
	if not shot.get("ok", false):
		return MCPResult.fail(str(shot.get("error", "截图失败")))
	var out := MCPResult.ok_json({
		"path": shot.get("path", ""),
		"res_path": shot.get("res_path", ""),
		"width": int(shot.get("width", 0)),
		"height": int(shot.get("height", 0)),
		"bytes": int(shot.get("bytes", 0)),
		"capture_type": "scene",
		"scene": scene_path,
		"color_mode": str(shot.get("color_mode", "")),
	})
	return MCPResult.attach_image(out, str(shot.get("res_path", "")))


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
