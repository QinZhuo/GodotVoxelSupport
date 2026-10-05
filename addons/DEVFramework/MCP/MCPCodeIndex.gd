@tool
extends RefCounted

## ======= 代码与资源索引域 =======
##
## 从 MCPDevServer 拆出的第一个**域文件**, 也是后续各域的样板。收录"在磁盘上找东西"这一类
## 能力: list_dir / search_symbols / find_resource_users, 外加一个进程内辅助 global_classes_info()。
##
## ## 为什么按"域"切而不是按"逻辑角色"切
##
## 先前的拆分是按角色切的(MCPResult 管响应形状、MCPToolSchema 管请求形状、MCPToolMeta 管
## 注解), 结果每个文件都只有一两百行, 而一个工具域的 schema + 实现 + 辅助函数仍然散在主文件里。
## 按域切之后, 同一个工具的注册、schema、handler、它专属的辅助函数都在一个文件内, 改一个工具
## 不必再去主文件找三处。
##
## ## 依赖方向: 严格单向
##
## 本文件**不引用** MCPDevServer, 也不持有任何服务器状态。只依赖:
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - VariantTool    全局 class_name, 入参读取
## 注册靠"把 _add_tool 当 Callable 传进来"完成, 所以连服务器的类型都不需要认识。
##
## ## 为什么 handler 一律 static
##
## 1. MCPToolAudit 的入参一致性自检靠 handler.get_method() 拿函数名、再去源码里切函数体。
##    静态函数取到的 get_method() 同样返回函数名(实测 "GDScript::_handle_xxx"), 自检照常工作;
##    而若改用 lambda 注册, get_method() 返回空串, 那批工具会**静默跳过**入参自检 ——
##    正是这个自检文件开头警告的"比不自检更糟"的失效模式。
## 2. 本域实现体经实测对实例状态零依赖, 静态化不损失任何东西。真正依赖实例状态的那批
##    (调试桥接的 debugger_plugin、运行期的 _pending / _verify_sessions)刻意留在主服务器里。
##
## **必须带 @tool 且不声明 class_name**, 两条都是踩过的坑, 详见 MCPDevServer 顶部注释。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## ======= 域注册入口 =======
##
## 由 MCPDevServer._register_editor_tools() 调用一次。add_tool 是服务器 `_add_tool` 的
## Callable, 签名 (name, desc, input_schema, handler)。
##
## 与主文件里其余 _register_* 的区别: 那些是服务器的方法、可以直接调 self._add_tool, 而本文件
## 不认识服务器, 只能把方法当值传进来。代价是多一层 Callable 间接, 换来的是域文件可以被独立
## 阅读、独立修改、独立静态检查。
static func register(add_tool: Callable) -> void:
	add_tool.call("list_dir",
		"列出res://或user://目录下的文件/子目录。",
		{"type": "object", "properties": {"path": MCPToolSchema.str_arg("目录路径, 默认 res://"), "recursive": {"type": "boolean", "description": "是否递归列出子目录, 默认 false"}}},
		_handle_list_dir)

	add_tool.call("search_symbols",
		"跨脚本与场景/资源配置搜索符号。.gd 支持函数/变量/类定义与引用; .tscn/.tres 支持节点定义(node)、资源关联(ext_resource)、引用。改签名/改节点名/查某资源在哪些场景被用, 或找某功能实现位置。",
		{"type": "object", "properties": {
			"query": {"type": "string", "description": "要搜索的标识符(如 _generate / player_pos / Player 节点名 / MyClass / 资源路径)"},
			"kind": {"type": "string", "enum": MCPToolSchema.SEARCH_KIND, "description": "过滤: function/variable/class(仅.gd)/node(节点名)/resource(ext_resource)/ref(引用)/all(默认)"},
			"path": MCPToolSchema.str_arg("限定搜索目录(res://子路径), 默认 res:// 全项目"),
			"include_resources": {"type": "boolean", "description": "是否搜索 .tscn/.tres 文件, 默认 true"},
			"max_results": {"type": "integer", "minimum": 1, "description": "最多返回条数, 默认 100"}
		}, "required": ["query"]},
		_handle_search_symbols)

	add_tool.call("find_resource_users",
		"查任意资源的双向依赖: users=谁引用该资源(反向), deps=该资源依赖谁(正向依赖链, 含脚本/配置/场景/资产类型标签)。兼容 Godot4 的 res://路径 与 uid://xxx 两种引用形式。目标为带全局类名的脚本时, 额外扫描其它 .gd 中类名的词边界使用点(类型注解/extends/静态调用等, kind=class_ref)。改名/删除/移动资源前查完整影响面。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("目标资源路径(如 res://Scenes/Main.tscn 或 Scenes/Main.tscn)"),
			"max_results": {"type": "integer", "description": "最多返回引用文件数, 默认 100"},
			"include_script_refs": {"type": "boolean", "description": "是否包含 .gd 脚本里的 preload/load 引用, 默认 true"},
			"include_class_refs": {"type": "boolean", "description": "是否包含全局类名在 .gd 中的词边界引用扫描(仅目标是带 class_name 的脚本时生效), 默认 true"}
		}, "required": ["path"]},
		_handle_find_resource_users)


## ======= 实现 =======

static func _handle_list_dir(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path", "res://")
	var recursive := VariantTool.get_bool(args, "recursive")
	if not path.ends_with("/"):
		path += "/"
	var dir := DirAccess.open(path)
	if dir == null:
		return MCPResult.fail("无法打开目录: %s" % path)
	var dirs: Array = []
	var files: Array = []
	if recursive:
		_collect_dir(path, dirs, files)
	else:
		dir.list_dir_begin()
		var f := dir.get_next()
		while not f.is_empty():
			if dir.current_is_dir() and f != "." and f != "..":
				dirs.append(f)
			elif not dir.current_is_dir():
				files.append(f)
			f = dir.get_next()
		dir.list_dir_end()
	return MCPResult.ok_json({"path": path, "dirs": dirs, "files": files})


## 递归收集目录内容(供 list_dir 使用)
static func _collect_dir(base: String, dirs: Array, files: Array) -> void:
	var d := DirAccess.open(base)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while not f.is_empty():
		if d.current_is_dir() and f != "." and f != "..":
			dirs.append(base + f + "/")
			_collect_dir(base + f + "/", dirs, files)
		elif not d.current_is_dir():
			files.append(base + f)
		f = d.get_next()
	d.list_dir_end()


## 已注册全局类清单。**刻意不是工具**: 它没有 schema、不进注册表, 而是由 get_project_info
## (kind=classes) 在进程内直接分派。把它注册成工具等于对外承诺一个契约, 而它的形状完全依附于
## get_project_info 的调用场景 —— 那是对外契约膨胀, 不是能力缺失。
static func global_classes_info() -> Dictionary:
	var list := ProjectSettings.get_global_class_list()
	var out: Array = []
	for c in list:
		out.append({
			"name": c.get("name", ""),
			"path": c.get("path", ""),
			"base": c.get("base", ""),
			"class": c.get("class", ""),
		})
	return MCPResult.ok_json({"count": out.size(), "classes": out})


## 跨脚本与场景/资源配置搜索符号(函数/变量/类定义与引用)
static func _handle_search_symbols(args: Dictionary) -> Dictionary:
	var query := VariantTool.get_string(args, "query")
	var kind := VariantTool.get_string(args, "kind", "all")
	var search_path := VariantTool.get_string(args, "path")
	var include_resources := VariantTool.get_bool(args, "include_resources", true)
	var max_results := VariantTool.get_int(args, "max_results", 100)
	if query.is_empty():
		return MCPResult.fail("必须提供 query")
	var base_dir := "res://"
	if not search_path.is_empty():
		if not search_path.begins_with("res://"):
			search_path = "res://" + search_path.trim_prefix("/")
		base_dir = search_path
		if not DirAccess.dir_exists_absolute(base_dir):
			return MCPResult.fail("目录不存在: %s" % base_dir)
	if kind not in MCPToolSchema.SEARCH_KIND:
		return MCPResult.fail("kind 无效: %s (可选: %s)" % [kind, " / ".join(MCPToolSchema.SEARCH_KIND)])
	# query 若是资源路径/uid, 补充另一形态(uid 或 res://路径)以便双向匹配
	var needles: Array = [query]
	if query.begins_with("res://"):
		var uid := ResourceLoader.get_resource_uid(query)
		if uid >= 0:
			needles.append(ResourceUID.id_to_text(uid))
	elif query.begins_with("uid://"):
		var rpath := ResourceUID.uid_to_path(query)
		if not rpath.is_empty():
			needles.append(rpath)
	# 收集文件(仅 .gd 或含 .tscn/.tres)
	var code_files: Array = []
	var extensions := PackedStringArray([".gd"])
	if include_resources:
		extensions = PackedStringArray([".gd", ".tscn", ".tres"])
	_collect_files(base_dir, code_files, extensions)
	# 逐文件扫描
	var defs: Array = []
	var refs: Array = []
	for fpath in code_files:
		var is_scene: bool = fpath.ends_with(".tscn") or fpath.ends_with(".tres")
		var matcher := func(line: String, line_num: int) -> Variant:
			var m: Variant
			if is_scene:
				m = _match_scene_symbol(line, needles)
			else:
				m = _match_symbol(line, needles)
			if m == null:
				return null
			m["line"] = line_num
			m["text"] = line.strip_edges()
			return m
		for hit in _scan_file_lines(fpath, matcher):
			var entry := {
				"file": fpath,
				"line": hit.get("line", 0),
				"text": hit.get("text", ""),
				"type": hit.get("type", "ref"),
				"symbol": hit.get("symbol", query),
			}
			if kind != "all" and String(entry.get("type")) != kind:
				continue
			if entry.get("type") == "ref":
				if refs.size() < max_results:
					refs.append(entry)
			elif defs.size() < max_results:
				defs.append(entry)
			if defs.size() + refs.size() >= max_results * 2:
				break
		if defs.size() + refs.size() >= max_results * 2:
			break
	return MCPResult.ok_json({
		"query": query,
		"definitions": defs,
		"references": refs,
		"definition_count": defs.size(),
		"reference_count": refs.size(),
		"files_scanned": code_files.size(),
	})


## 递归收集 res:// 下匹配扩展名的文件(如 .gd/.tscn/.tres)
static func _collect_files(dir_path: String, out: Array, extensions: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while not fname.is_empty():
		if fname == "." or fname == "..":
			fname = dir.get_next()
			continue
		var full := dir_path.path_join(fname)
		if dir.current_is_dir():
			# 跳过隐藏/构建目录
			if not fname.begins_with(".") and fname != "build" and fname != "Native":
				_collect_files(full, out, extensions)
		elif _has_any_ext(fname, extensions):
			out.append(full)
		fname = dir.get_next()
	dir.list_dir_end()


static func _has_any_ext(fname: String, extensions: PackedStringArray) -> bool:
	for ext in extensions:
		if fname.ends_with(ext):
			return true
	return false


## 逐行扫描文件, matcher(line, line_num) 返回字典即命中(含 type 等), 返回 null 跳过。收集全部命中行。
static func _scan_file_lines(fpath: String, matcher: Callable) -> Array:
	var hits: Array = []
	if not FileAccess.file_exists(fpath):
		return hits
	var file := FileAccess.open(fpath, FileAccess.READ)
	if file == null:
		return hits
	var line_num := 0
	while not file.eof_reached():
		var line := file.get_line()
		line_num += 1
		var result: Variant = matcher.call(line, line_num)
		if result != null:
			hits.append(result)
	file.close()
	return hits


## 匹配一行里的符号定义或引用, needles[0] 为原始 query。返回 {type, symbol} 或 null
static func _match_symbol(line: String, needles: Array) -> Variant:
	var stripped := line.strip_edges()
	if stripped.begins_with("#"):
		return null
	var query := String(needles[0])
	# 定义: func 名字(
	if RegEx.create_from_string("\\bfunc\\s+(" + _regex_escape(query) + ")\\s*\\(").search(stripped):
		return {"type": "function", "symbol": query}
	# 定义: class_name 名字 或 class 名字
	if RegEx.create_from_string("\\bclass(?:_name)?\\s+(" + _regex_escape(query) + ")\\b").search(stripped):
		return {"type": "class", "symbol": query}
	# 定义: var 名字 / @export var 名字 / const 名字
	if RegEx.create_from_string("\\b(?:var|const)\\s+(" + _regex_escape(query) + ")\\s*(?::|=)").search(stripped):
		return {"type": "variable", "symbol": query}
	# 引用: 任一 needle 命中
	for needle in needles:
		if stripped.contains(String(needle)):
			return {"type": "ref", "symbol": String(needle)}
	return null


static func _regex_escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace(".", "\\.").replace("(", "\\(").replace(")", "\\)").replace("[", "\\[").replace("]", "\\]").replace("{", "\\{").replace("}", "\\}").replace("*", "\\*").replace("+", "\\+").replace("?", "\\?").replace("|", "\\|").replace("^", "\\^").replace("$", "\\$")


## 匹配 .tscn/.tres 文件行的符号定义或引用, needles[0] 为原始 query
static func _match_scene_symbol(line: String, needles: Array) -> Variant:
	var stripped := line.strip_edges()
	if stripped.is_empty():
		return null
	var query := String(needles[0])
	var is_path_query := query.begins_with("res://") or query.begins_with("uid://")
	# 节点定义: [node name="查询" (仅标识符查询时)
	if not is_path_query and stripped.begins_with("[node"):
		var name_idx := stripped.find("name=\"")
		if name_idx != -1:
			var name_part := stripped.substr(name_idx + 6)
			var name_end := name_part.find("\"")
			if name_end != -1 and name_part.substr(0, name_end) == query:
				return {"type": "node", "symbol": query}
	# ext_resource / sub_resource 定义(资源/脚本关联)
	if stripped.begins_with("[ext_resource") or stripped.begins_with("[sub_resource"):
		for needle in needles:
			if stripped.contains(String(needle)):
				return {"type": "resource", "symbol": String(needle)}
	# 普通引用: 任一 needle 命中(含属性值引用, 如 script=ExtResource(...) 等)
	for needle in needles:
		if stripped.contains(String(needle)):
			return {"type": "ref", "symbol": String(needle)}
	return null


static func _handle_find_resource_users(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var path := VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not path.begins_with("res://"):
		path = "res://" + path.trim_prefix("/")
	if not ResourceLoader.exists(path):
		return MCPResult.fail("资源不存在: %s" % path)
	var include_script_refs := VariantTool.get_bool(args, "include_script_refs", true)
	var include_class_refs := VariantTool.get_bool(args, "include_class_refs", true)
	var max_results := VariantTool.get_int(args, "max_results", 100)
	# 目标资源的 UID 与归一化路径
	var target_uid := ResourceLoader.get_resource_uid(path)
	var needles: Array = [ResourceUID.ensure_path(path)]
	if target_uid >= 0:
		needles.append(ResourceUID.id_to_text(target_uid))
	var target_res_path := String(needles[0])
	# 目标脚本的全局类名(存在时启用第二引用通道: 类名在 .gd 中的词边界使用点)
	var target_class_name := ""
	if include_class_refs and target_res_path.ends_with(".gd"):
		for c in ProjectSettings.get_global_class_list():
			if String(c.get("path", "")) == target_res_path:
				target_class_name = str(c.get("name", c.get("class", "")))
				break
	# 收集全部代码/资源配置文件
	var files: Array = []
	var extensions := PackedStringArray([".gd", ".tscn", ".tres", ".res"])
	_collect_files("res://", files, extensions)
	var users: Array = []
	var files_scanned := 0
	for fpath in files:
		if fpath == target_res_path:
			continue
		# .gd 脚本: preload/load 引用走文本匹配; 全局类名引用走词边界匹配
		if fpath.ends_with(".gd"):
			if not include_script_refs:
				continue
			var matcher := func(line: String, _line_num: int) -> Variant:
				if line.begins_with("#"):
					return null
				for needle in needles:
					if line.contains(String(needle)):
						return {"needle": String(needle)}
				if target_class_name != "" and _line_contains_word(line, target_class_name):
					return {"needle": target_class_name, "class_ref": true}
				return null
			var hits := _scan_file_lines(fpath, matcher)
			if not hits.is_empty():
				var hit: Dictionary = hits[0]
				var entry := {"file": fpath, "kind": "class_ref" if bool(hit.get("class_ref", false)) else "script"}
				if hit.has("needle"):
					entry["via"] = hit["needle"]
				users.append(entry)
				if users.size() >= max_results:
					break
			continue
		# 其他资源文件: 引擎级依赖解析(准确处理 uid::path 引用)
		var deps := ResourceLoader.get_dependencies(fpath)
		files_scanned += 1
		var matched := false
		for dep in deps:
			var dep_str := String(dep)
			if dep_str.contains("::"):
				# uid::<空>::path 三段格式
				if target_uid >= 0 and dep_str.get_slice("::", 0) == str(target_uid):
					matched = true
					break
				if dep_str.get_slice("::", 2) == target_res_path:
					matched = true
					break
			elif dep_str == target_res_path:
				matched = true
				break
		if matched:
			users.append({"file": fpath, "kind": "resource"})
			if users.size() >= max_results:
				break
	var uid_text := String(needles[1]) if needles.size() > 1 else ""
	# 正向依赖链: 该资源依赖谁(场景/脚本/配置/资产), 与 users(谁引用它)互为反向
	var deps_list: Array = []
	var deps_map := collect_scene_deps(target_res_path)
	for dpath in deps_map:
		if String(dpath) == target_res_path:
			continue
		deps_list.append({"path": String(dpath), "type": _resource_type_label(String(dpath))})
	deps_list.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.get("path", "")) < str(b.get("path", "")))
	return MCPResult.ok_json({
		"target": target_res_path,
		"uid": uid_text,
		"class_name": target_class_name,
		"user_count": users.size(),
		"files_scanned": files_scanned,
		"users": users,
		"dep_count": deps_list.size(),
		"deps": deps_list,
		"hint": "users=谁引用该资源(反向, kind=script为路径引用/class_ref为全局类名使用点/resource为资源依赖), deps=该资源依赖谁(正向)。改/删资源前看两边评估影响面。",
	})


## 词边界匹配: 标识符前后不得是字母/数字/下划线(避免子串误命中)
static func _line_contains_word(line: String, word: String) -> bool:
	if word.is_empty():
		return false
	var idx := line.find(word)
	while idx >= 0:
		var before_ok := idx == 0 or not _is_ident_char(line[idx - 1])
		var after := idx + word.length()
		var after_ok := after >= line.length() or not _is_ident_char(line[after])
		if before_ok and after_ok:
			return true
		idx = line.find(word, idx + 1)
	return false


static func _is_ident_char(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


## 按扩展名分类资源: script/config/scene/asset
static func _resource_type_label(path: String) -> String:
	if path.ends_with(".gd"):
		return "script"
	if path.ends_with(".tscn"):
		return "scene"
	if path.ends_with(".tres") or path.ends_with(".res"):
		return "config"
	return "asset"


## 收集场景依赖链的全部资源文件(递归: 场景依赖 → 资源依赖), 含脚本/配置/图片/音频/字体等。
## 排除 .godot 缓存与 .import 元数据, 只看用户资源。
##
## 本函数原先住在 MCPDevServer 的运行校验域, 被本域的 find_resource_users 与那边的
## _snapshot_deps_mtime 同时使用 —— 是整轮拆分里**唯一**的跨域共享件。放在本域的理由是它
## 与其它扫描器同族(都是"沿 res:// 递归解析资源图"), 且这样依赖是单向的(运行校验域 → 本域);
## 若留在主服务器, 则每个域都要反向引用服务器, 等于把耦合从横向搬到纵向, 什么都没解决。
static func collect_scene_deps(scene: String) -> Dictionary:
	var deps := {}
	var visited := {}
	_collect_deps_recursive(scene, deps, visited)
	return deps


static func _collect_deps_recursive(path: String, deps: Dictionary, visited: Dictionary) -> void:
	if visited.has(path):
		return
	visited[path] = true
	# 排除引擎缓存/导入元数据(这些被改动不代表用户资源变化)
	if path.contains("/.godot/") or path.ends_with(".import"):
		return
	if path.ends_with(".gd") or path.ends_with(".tres") or path.ends_with(".tscn") or path.ends_with(".res") \
		or path.ends_with(".png") or path.ends_with(".jpg") or path.ends_with(".svg") or path.ends_with(".webp") \
		or path.ends_with(".wav") or path.ends_with(".ogg") or path.ends_with(".mp3") \
		or path.ends_with(".ttf") or path.ends_with(".otf") or path.ends_with(".glb") or path.ends_with(".gltf"):
		deps[path] = true
	if not ResourceLoader.exists(path):
		return
	var sub := ResourceLoader.get_dependencies(path)
	for dep in sub:
		var dep_str := String(dep)
		# 格式: path 或 uid::<空>::path
		var real := dep_str
		if dep_str.contains("::"):
			real = dep_str.get_slice("::", 2)
		if real.is_empty():
			continue
		_collect_deps_recursive(real, deps, visited)
