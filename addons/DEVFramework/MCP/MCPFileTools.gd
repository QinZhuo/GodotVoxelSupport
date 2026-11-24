@tool
extends RefCounted

## ======= 文件操作域 =======
## 工具面: read_file(含 probe) / write_file(含 mode) / delete_file / move_file。
##   - 追加与覆盖是同一件事的两种模式, 故 write_file(mode=overwrite|append) 一个入口;
##   - "删之前先探一下"是读动作, 故 read_file(probe=true) 顺带回答存在性, 不单独占一个工具。
## 依赖: MCPResult(响应封装) + MCPToolContract(请求 schema 工厂)。**必须带 @tool 且不声明 class_name**。
## 写路径守卫与 dry_run 不是冗余检查: 漏一次就能删错东西或损坏工程, 且**不报错**。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")


## ======= 域注册入口 =======

## -- 文件操作 --
static func register(add_tool: Callable) -> void:
	add_tool.call("read_file",
		"读取文件内容(UTF-8)。返回内容与大小。大文件分段读: offset=起始字符下标(单位是**字符**不是字节), limit=本次最多返回字符数(默认0=不限); 返回的 next_char_offset=-1 表示已读完, 否则把它作为下次 offset 传入即可续读(同 get_logs 的 since/next 约定)。只想探存在性/大小而不读内容时传 probe=true(文件或目录都行)。",
		MCPToolContract.read_file(),
		_handle_read_file)

	add_tool.call("write_file",
		"写入内容到文件(不存在则创建, 含目录)。mode=overwrite(默认)整份覆盖、不可撤销; mode=append 追加到末尾。建议先 dry_run=true 预演(会告知是否覆盖已有文件), 确认后再实写。",
		MCPToolContract.write_content(),
		_handle_write_file)

	add_tool.call("delete_file",
		"删除文件或空目录(**不可撤销**)。强烈建议先传 dry_run=true 预演(返回目标大小), 确认后再删。目录只能删空目录。",
		MCPToolContract.file_path("文件或目录路径(res:// 或 user://)", true),
		_handle_delete_file)

	add_tool.call("move_file",
		"移动/重命名文件(改路径同时改名字, 覆盖两件事)。跨目录、跨 res:// 与 user:// 都行; 目标已存在时默认报错不覆盖(overwrite=true 才覆盖)。移动脚本/场景/资源后会触发一次文件系统扫描, 让编辑器立刻认得新路径。",
		{"type": "object", "properties": {
			"from": {"type": "string", "description": "源路径(res:// 或 user://)"},
			"to": {"type": "string", "description": "目标路径(含文件名)。只给目录会被当成语法错误, 必须写全"},
			"overwrite": {"type": "boolean", "description": "目标已存在时是否覆盖, 默认 false(报错)"},
		}, "required": ["from", "to"]},
		_handle_move_file)


## ======= 文件操作实现 =======


## 本域载荷最大的工具, 也是最容易被"顺手加上截断"的地方 —— **别加**。
static func _handle_read_file(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	# probe: 只探测存在性。目录也要能探(删空目录前正是最需要它的时候), 故 exists 取文件与目录的并集。
	if VariantTool.get_bool(args, "probe"):
		return _probe_path(path)
	if not FileAccess.file_exists(path):
		var dir := DirAccess.open(path)
		if dir != null:
			return MCPResult.fail("%s 是目录, 不是文件(用 list_dir 列内容, 或用 read_file(probe=true) 探测)" % path)
		return MCPResult.fail("文件不存在: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	# 仅支持 UTF-8(引擎默认编码)。不声明未实现的解码方式, 以免误导。
	var content := file.get_as_text()
	var size := file.get_length()
	file.close()
	# 分段读: offset/limit 按**字符**切(String 的索引单位), 而 `get_length()` 给的是字节数。
	var total_chars := content.length()
	var offset: int = maxi(0, VariantTool.get_int(args, "offset", 0))
	var limit: int = VariantTool.get_int(args, "limit", 0)
	if offset > total_chars:
		# 不静默返回空串: 读到文件末尾却拿到空内容, 调用方无法区分"文件是空的"与"游标越界"。
		return MCPResult.fail("offset %d 超出文件末尾(总字符数 %d)。文件已读完, 无需续读; 若确需重读请把 offset 回退到 0" % [offset, total_chars])
	# limit<=0 表示不限: substr 的第二参传 -1 即"到末尾", 但显式分两支写, 免得读代码的人以为会切出空串。
	var chunk: String = content.substr(offset, limit) if limit > 0 else content.substr(offset)
	var consumed: int = offset + chunk.length()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"encoding": "utf-8",
		"offset": offset,
		"total_chars": total_chars,
		"returned_chars": chunk.length(),
		# -1 = 已读完; 否则原样作为下次 offset 传回即可续读。语义与 get_logs 的 next 一致。
		"next_char_offset": consumed if consumed < total_chars else -1,
		"content": chunk,
	})


## 存在性探测。exists 把"目录存在"也算存在 ——
## 调用方问的是"这路径上有没有东西", 只有 is_directory 用来区分是什么。
static func _probe_path(path: String) -> Dictionary:
	var is_file := FileAccess.file_exists(path)
	var is_dir := false
	var file_size := 0
	if is_file:
		# get_length() 是实例方法, 得先开文件; 顺带拿到**字节**数(与 read_file 的字符游标不是一回事)。
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			file_size = f.get_length()
			f = null
	else:
		is_dir = DirAccess.open(path) != null
	return MCPResult.ok_json({
		"path": path,
		"exists": is_file or is_dir,
		"is_file": is_file,
		"is_directory": is_dir,
		"size": file_size,
		"message": "文件存在" if is_file else ("目录存在" if is_dir else "文件不存在"),
	})


## ======= 文件写入安全(dry_run + 路径守卫) =======

## 写操作允许的路径前缀。
const _WRITE_PATH_PREFIXES := ["res://", "user://"]

## 受保护路径前缀: 这些目录由引擎/导入器管理, 人工写入要么被覆盖要么会破坏索引。
const _PROTECTED_PREFIXES := [
	"res://.godot/", "res://.import/",
	"res://project.godot",
]


## 校验写路径。返回空串 = 通过; 否则返回拒绝原因(可直接作为错误信息)。
static func guard_write_path(path: String) -> String:
	if path.is_empty():
		return "必须提供 path"
	if path.contains(".."):
		return "路径含 '..' 父级跳转(拒绝): %s" % path
	for p in _PROTECTED_PREFIXES:
		if path.begins_with(p):
			return "路径位于受保护目录, 禁止直接写入: %s (%s 由引擎/导入器管理, 请改用对应工具操作)" % [path, p]
	var ok := false
	for p in _WRITE_PATH_PREFIXES:
		if path.begins_with(p):
			ok = true
			break
	if not ok:
		return "只允许写入 res:// 或 user:// 下的路径(收到: %s)。绝对路径会写到工程外, 相对路径依赖当前工作目录, 均不允许。" % path
	return ""


## 预演结果(统一形状)。
static func _dry_run_result(tool_name: String, path: String, detail: Dictionary) -> Dictionary:
	var info := detail.duplicate(true)
	info["path"] = path
	info["dry_run"] = true
	info["message"] = "[预演] 未做任何改动。确认无误后去掉 dry_run 参数重新调用 %s。" % tool_name
	return MCPResult.ok_json(info)


## 写/追加的唯一入口(mode 决定覆盖还是追加)。
static func _handle_write_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	var content := VariantTool.get_string(args, "content")
	var mode := VariantTool.get_string(args, "mode", "overwrite").strip_edges()
	if mode.is_empty():
		mode = "overwrite"
	if mode != "overwrite" and mode != "append":
		return MCPResult.fail("未知的 mode: '%s'(只能是 overwrite 或 append)" % mode)
	var existed := FileAccess.file_exists(path)
	var dir_path := path.get_base_dir()
	if VariantTool.get_bool(args, "dry_run"):
		if mode == "append":
			return _dry_run_result("write_file", path, {
				"action": "append",
				"exists": existed,
				"current_size": FileAccess.get_file_as_string(path).length() if existed else 0,
				"bytes": content.length(),
			})
		return _dry_run_result("write_file", path, {
			"action": "overwrite",
			"exists": existed,
			"would_overwrite": existed,
			"would_create_dirs": not dir_path.is_empty() and DirAccess.open(dir_path) == null,
			"bytes": content.length(),
		})
	if not dir_path.is_empty():
		var dir := DirAccess.open(dir_path)
		if dir == null:
			var err := DirAccess.make_dir_recursive_absolute(dir_path)
			if err != OK:
				return MCPResult.fail("无法创建目录: %s (错误码: %d)" % [dir_path, err])
	if mode == "append" and existed:
		var afile := FileAccess.open(path, FileAccess.READ_WRITE)
		if afile == null:
			return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
		afile.seek_end()
		afile.store_string(content)
		var appended_size := afile.get_length()
		afile.close()
		return MCPResult.ok_json({
			"path": path,
			"size": appended_size,
			"mode": "append",
			"message": "内容追加成功"
		})
	# overwrite 与"append 但目标不存在"共用同一条创建路径: 两份创建逻辑的典型漂移是一边补了守卫、另一边没补。
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return MCPResult.fail("无法写入文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	var size := file.get_length()
	file.close()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"mode": mode,
		"existed": existed,
		"message": "内容追加成功" if mode == "append" else "文件写入成功"
	})


static func _handle_delete_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	# dry_run 读一次就够: `args.get("dry_run") == true` 的严格比较在入参来自 JSON 时并不可靠, 统一走 VariantTool。
	var dry_run := VariantTool.get_bool(args, "dry_run")
	if not FileAccess.file_exists(path):
		var dir := DirAccess.open(path)
		if dir == null:
			return MCPResult.fail("文件或目录不存在: %s" % path)
		if dry_run:
			return _dry_run_result("delete_file", path, {"action": "delete_empty_dir"})
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			return MCPResult.fail("无法删除目录: %s (错误码: %d)。注意: 只能删除空目录" % [path, err])
		return MCPResult.ok_json({"path": path, "message": "目录删除成功"})
	if dry_run:
		return _dry_run_result("delete_file", path, {
			"action": "delete_file",
			"bytes": FileAccess.get_file_as_string(path).length(),
		})
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return MCPResult.fail("无法删除文件: %s (错误码: %d)" % [path, err])
	return MCPResult.ok_json({"path": path, "message": "文件删除成功"})


## 移动/重命名。走 DirAccess.rename_absolute 而不是"复制 + 删源": 同盘 rename 是原子的,
## 中途失败不会留下半份文件(复制+删源在两者之间崩掉就是"新旧都在"或"新旧都没")。
static func _handle_move_file(args: Dictionary) -> Dictionary:
	var from := VariantTool.get_string(args, "from")
	var to := VariantTool.get_string(args, "to")
	if from.is_empty() or to.is_empty():
		return MCPResult.fail("from 与 to 都必须提供")
	# 两侧都要过写权限守卫: 只守一侧等于给了"写到保护目录"的后门。
	for p in [from, to]:
		var guard := guard_write_path(str(p))
		if not guard.is_empty():
			return MCPResult.fail(guard)
	if from == to:
		return MCPResult.fail("from 与 to 相同, 无需移动: %s" % from)
	if not FileAccess.file_exists(from) and DirAccess.open(from) == null:
		return MCPResult.fail("源不存在: %s" % from)
	var overwrite := VariantTool.get_bool(args, "overwrite")
	if FileAccess.file_exists(to) and not overwrite:
		return MCPResult.fail("目标已存在: %s(确需覆盖请传 overwrite=true)" % to)
	# 目标目录不存在时先建: rename 不会替调用方造目录, 而"忘了建目录"是最常见的失败原因。
	var to_dir := to.get_base_dir()
	if not to_dir.is_empty() and DirAccess.open(to_dir) == null:
		var mk := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to_dir))
		if mk != OK:
			return MCPResult.fail("无法创建目标目录 %s (错误码: %d)" % [to_dir, mk])
	if overwrite and FileAccess.file_exists(to):
		DirAccess.remove_absolute(to)
	var err := DirAccess.rename_absolute(from, to)
	if err != OK:
		return MCPResult.fail("移动失败: %s -> %s (错误码: %d)" % [from, to, err])
	# 编辑器要重新认得新路径: 脚本/场景/资源都靠 .uid 与导入缓存, 不扫一次会看到"文件消失"。
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		EditorInterface.get_resource_filesystem().scan()
	return MCPResult.ok_json({
		"from": from, "to": to, "overwrite": overwrite,
		"message": "移动成功" + (", 已触发文件系统扫描" if Engine.is_editor_hint() else ""),
	})
