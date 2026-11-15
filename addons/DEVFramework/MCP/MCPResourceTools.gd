@tool
extends RefCounted

## ======= 资源与项目设置域 =======
## (打开场景、写项目设置、创建/读取 .tres、触发重新导入)。两者唯一的交集是都要走 res:// 路径
## 接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。据此各域给了不同答案,
## 且都正确, 不要为了"看起来统一"而改:
##   - log 域→ 注入 bind_logger: 漏调后果是 get_logs 返回"日志捕获器未就绪", **显式报错**。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## ======= 域注册入口 =======
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
##   注意这是**约定而非守卫**: 契约自检(_audit_tools / MCPToolAudit.audit_handler_params)校验的是
##   VariantTool 裸读。新增 handler 时只能靠自律 —— 这点必须写明, 否则后人会误以为
static func _handle_set_project_setting(args: Dictionary) -> Dictionary:
	var name := VariantTool.get_string(args, "name")
	if name.is_empty():
		return MCPResult.fail("必须提供 name")
	var value: Variant = args.get("value", null)
	# 防御: 部分 JSON→Variant 链路会把数组/对象退化为字符串(形如 ["a","b"]/{"k":1}),
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
## **必须先确认该资源归导入系统管**: reimport_files 是拿同名 .import 去驱动导入器的, 而
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


## preview_resource: 取编辑器生成的资源预览缩略图 → 存 PNG。
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
