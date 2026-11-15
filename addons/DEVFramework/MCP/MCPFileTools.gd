@tool
extends RefCounted

## ======= 文件操作域 =======
##   - MCPResult      响应封装
##   - MCPToolSchema  请求 schema 工厂
##   - VariantTool    全局 class_name, 入参读取
## 删错东西/工程损坏, 且**不报错**。改本文件时不要把它们当冗余检查清理掉。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")


## ======= 域注册入口 =======

## -- 文件操作 --
static func register(add_tool: Callable) -> void:
	add_tool.call("read_file",
		"读取文件内容(UTF-8)。返回内容与大小。大文件分段读: offset=起始字符下标(单位是**字符**不是字节), limit=本次最多返回字符数(默认0=不限); 返回的 next_char_offset=-1 表示已读完, 否则把它作为下次 offset 传入即可续读(同 get_logs 的 since/next 约定)。",
		MCPToolSchema.read_file(),
		_handle_read_file)

	add_tool.call("write_file",
		"写入内容到文件(不存在则创建, 含目录; 存在则**覆盖**, 不可撤销)。建议先 dry_run=true 预演(会告知是否覆盖已有文件), 确认后再实写。",
		MCPToolSchema.write_content(),
		_handle_write_file)

	add_tool.call("append_file",
		"追加内容到文件(不存在则创建)。可传 dry_run=true 查看当前大小而不实际追加。",
		MCPToolSchema.write_content(),
		_handle_append_file)

	add_tool.call("delete_file",
		"删除文件或空目录(**不可撤销**)。强烈建议先传 dry_run=true 预演(返回目标大小), 确认后再删。目录只能删空目录。",
		MCPToolSchema.file_path("文件或目录路径(res:// 或 user://)", true),
		_handle_delete_file)

	add_tool.call("file_exists",
		"检查文件或目录是否存在。",
		MCPToolSchema.file_path("文件或目录路径(res:// 或 user://)"),
		_handle_file_exists)


## ======= 文件操作实现 =======

## 本域载荷最大的工具, 也是最容易被"顺手加上截断"的地方 —— **别加**。
static func _handle_read_file(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	if not FileAccess.file_exists(path):
		return MCPResult.fail("文件不存在: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	# 仅支持 UTF-8(引擎默认编码)。此前声明的 gbk/gb2312 实际未实现解码, 已移除以免误导。
	var content := file.get_as_text()
	var size := file.get_length()
	file.close()
	# 分段读: offset/limit 按**字符**切(String 的索引单位), 而上面的 size 是 `get_length()`
	var total_chars := content.length()
	var offset: int = maxi(0, VariantTool.get_int(args, "offset", 0))
	var limit: int = VariantTool.get_int(args, "limit", 0)
	if offset > total_chars:
		# 不静默返回空串: 读到文件末尾却拿到空内容, 调用方无法区分"文件是空的"与"游标越界",
		return MCPResult.fail("offset %d 超出文件末尾(总字符数 %d)。文件已读完, 无需续读; 若确需重读请把 offset 回退到 0" % [offset, total_chars])
	# limit<=0 表示不限: substr 的第二参传 -1 即"到末尾", 但显式分两支写, 免得读代码的人
	var chunk: String = content.substr(offset, limit) if limit > 0 else content.substr(offset)
	var consumed: int = offset + chunk.length()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"encoding": "utf-8",
		"offset": offset,
		"total_chars": total_chars,
		"returned_chars": chunk.length(),
		# -1 = 已读完; 否则原样作为下次 offset 传回即可续读。语义与 get_logs 的 next 一致,
		"next_char_offset": consumed if consumed < total_chars else -1,
		"content": chunk,
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


static func _handle_write_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	var content := VariantTool.get_string(args, "content")
	var existed := FileAccess.file_exists(path)
	var dir_path := path.get_base_dir()
	if VariantTool.get_bool(args, "dry_run"):
		return _dry_run_result("write_file", path, {
			"action": "write",
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
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return MCPResult.fail("无法写入文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	var size := file.get_length()
	file.close()
	return MCPResult.ok_json({
		"path": path,
		"size": size,
		"existed": existed,
		"message": "文件写入成功"
	})


static func _handle_append_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	var content := VariantTool.get_string(args, "content")
	var existed := FileAccess.file_exists(path)
	if VariantTool.get_bool(args, "dry_run"):
		return _dry_run_result("append_file", path, {
			"action": "append",
			"exists": existed,
			"current_size": FileAccess.get_file_as_string(path).length() if existed else 0,
			"bytes": content.length(),
		})
	if not existed:
		# 目标不存在时复用 write_file 的实现路径(建目录 + 写入), 而不是另写一份创建逻辑 ——
		# 两份创建逻辑的漂移形态是"append 能建目录、write 不能"这类半通不通的 bug。
		return _handle_write_file(args)
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return MCPResult.fail("无法打开文件: %s (错误码: %d)" % [path, FileAccess.get_open_error()])
	file.seek_end()
	file.store_string(content)
	var new_size := file.get_length()
	file.close()
	return MCPResult.ok_json({
		"path": path,
		"size": new_size,
		"message": "内容追加成功"
	})


static func _handle_delete_file(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path")
	var guard := guard_write_path(path)
	if not guard.is_empty():
		return MCPResult.fail(guard)
	# dry_run 读一次就够: 原本两个分支各判一次 `args.get("dry_run") == true`, 严格比较
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


static func _handle_file_exists(args: Dictionary) -> Dictionary:
	var path: String = VariantTool.get_string(args, "path")
	if path.is_empty():
		return MCPResult.fail("必须提供 path")
	var exists := FileAccess.file_exists(path)
	var is_dir := false
	if not exists:
		var dir := DirAccess.open(path)
		is_dir = dir != null
	return MCPResult.ok_json({
		"path": path,
		"exists": exists or is_dir,
		"is_directory": is_dir,
		"message": "文件存在" if exists else ("目录存在" if is_dir else "文件不存在")
	})
