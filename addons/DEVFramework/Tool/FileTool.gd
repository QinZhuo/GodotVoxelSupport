@tool
class_name FileTool
## 文件读写公共原语 —— 框架内一切"落盘"统一走这里, 避免各处各写一份临时文件 + 改名样板。
##
## 为什么需要原子写入:
## `FileAccess.open(path, WRITE)` 会**先把文件截断清空**, 若写入过程中崩溃/断电/进程被杀,
## 读者拿到的就是半截文件 —— 存档损坏最典型的成因。原子写入 = 先写同目录 `.tmp`, 再 `rename` 覆盖;
## 同一文件系统内的 rename 是原子操作, 读者要么看到旧档、要么看到新档, 绝不会看到中间态。
##
## rename 覆盖语义(已实测 + 官方文档核对): POSIX `rename(2)` 覆盖已存在目标, Windows 亦然
## (本项目 Godot 4.7 实测 `rename_absolute(tmp, 已存在目标)` 返回 OK 且内容被替换)。
## 但官方文档未承诺跨平台一致, 故失败且目标存在时回退为"删目标再 rename"(窗口极小, 仍远优于直接覆写)。
##
## `.tmp` 必须与被写文件**同目录**: 跨文件系统 rename 会失败(EXDEV), 那时原子性也无从谈起。


## 递归收集目录下的文件, 按扩展名过滤(需带点, 如 [code][".tres"][/code]; 空则不过滤)。
##
## 自动归一导出包的 [code].remap[/code]([code]x.tres.remap[/code] → [code]x.tres[/code]),
## 因此开发态与导出包用同一套代码路径。返回 res:// 完整路径。
static func list_files(dir_path: String, extensions: PackedStringArray = PackedStringArray(), recursive := true) -> PackedStringArray:
	var out := PackedStringArray()
	var stack: Array[String] = [dir_path]
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var dir := DirAccess.open(cur)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if dir.current_is_dir():
				if recursive and not entry.begins_with("."):
					stack.append(cur.path_join(entry) + "/")
			else:
				var full := cur.path_join(entry)
				if full.ends_with(".remap"):
					full = full.trim_suffix(".remap")
				if _match_ext(full, extensions):
					out.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	return out


## 递归收集目录自身及其所有子目录(仅目录), 返回完整 res:// 路径(带尾部 /), 已排序。
static func list_dirs(dir_path: String, recursive := true) -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [dir_path]
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		var dir := DirAccess.open(cur)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if dir.current_is_dir() and not entry.begins_with("."):
				var full := cur.path_join(entry) + "/"
				out.append(full)
				if recursive:
					stack.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	out.sort()
	return out


static func _match_ext(path: String, extensions: PackedStringArray) -> bool:
	if extensions.is_empty():
		return true
	for ext in extensions:
		if path.ends_with(ext):
			return true
	return false


## 裸路径补全 res:// 前缀(不校验存在性, 不做 uid 解析 —— 那属于调用方语义)。
## "a/b" 与 "/a/b" 都归一为 "res://a/b"。
static func to_res_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	return "res://" + path.trim_prefix("/")


## 绝对路径 → res:// 路径(项目根内); 项目根外原样返回。
static func abs_to_res(path: String) -> String:
	var root := ProjectSettings.globalize_path("res://")
	if path.begins_with(root):
		return "res://" + path.substr(root.length())
	return path


## 加载资源: 不存在 / 加载失败一律返回 null(不抛错)。
## 收敛全框架 "ResourceLoader.exists + load" 的样板(Def 存档 / Def 目录扫描 / 表格浏览等)。
static func load_resource(path: String) -> Resource:
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path)


## 确保 path 的父目录存在(不存在则递归创建)。返回目录是否可用。
static func ensure_dir(path: String) -> void:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


## 写入文本(**非原子**)。适合日志 / 状态等"丢了也无所谓"的可重写文件。
static func write_text(path: String, text: String) -> Error:
	ensure_dir(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		LogTool.error("文件", "写入失败: %s (错误: %d)" % [path, FileAccess.get_open_error()])
		return FAILED
	f.store_string(text)
	f.close()
	return OK


## 读取全部文本; 文件不存在 / 打开失败返回 ""。
static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


## 原子写入文本(UTF-8)。
static func atomic_write_text(path: String, text: String) -> Error:
	return atomic_write_bytes(path, text.to_utf8_buffer())


## 原子写入字节: 写 .tmp → rename 覆盖。失败时清理 .tmp 并返回错误码。
static func atomic_write_bytes(path: String, bytes: PackedByteArray) -> Error:
	ensure_dir(path)
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		LogTool.error("文件", "无法打开临时文件: %s (错误: %d)" % [tmp_path, FileAccess.get_open_error()])
		return FAILED
	f.store_buffer(bytes)
	f.close()

	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK and FileAccess.file_exists(path):
		# 平台 rename 不覆盖已存在目标 → 退化为"删目标再 rename"
		DirAccess.remove_absolute(path)
		err = DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		LogTool.error("文件", "原子写入失败: %s (错误: %d)" % [path, err])
		DirAccess.remove_absolute(tmp_path)
	return err
