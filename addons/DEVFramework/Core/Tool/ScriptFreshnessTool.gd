@tool
class_name ScriptFreshnessTool extends RefCounted

## 脚本新鲜度：磁盘上的 .gd 与当前进程**已加载**的版本是否一致。
## 【解决什么】编辑器进程里改完脚本直接 run_tests，会跑到旧代码（已加载脚本不会自动换新）。
## TestRunner 在编辑器模式开跑前问一次：有 changed 就拒绝并提示重启/headless，
## 而不是静默给出与磁盘不一致的结果。
##
## 只检查 **已缓存**（ResourceLoader.has_cached）的脚本：没被加载过的脚本本来就不参与本进程运行，
## 也不会因为"改了没加载"而影响结果；同时避免为了检查把所有脚本都 load 一遍（有静态初始化副作用）。

const DEFAULT_ROOTS: Array[String] = ["res://Scripts", "res://addons"]
const SKIP_DIRS := [".godot", ".git", ".import"]


## 单文件状态：in_sync / changed / not_loaded / not_script / missing
static func status(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"state": "missing", "path": path}
	var disk_hash := _file_hash(path)
	if not ResourceLoader.has_cached(path):
		return {"state": "not_loaded", "path": path, "disk_hash": disk_hash}
	var res = ResourceLoader.load(path)
	if not (res is GDScript):
		return {"state": "not_script", "path": path, "disk_hash": disk_hash}
	var loaded_hash := str((res as GDScript).source_code).hash()
	return {
		"state": "in_sync" if loaded_hash == disk_hash else "changed",
		"path": path,
		"disk_hash": disk_hash,
		"loaded_hash": loaded_hash,
	}


## 扫描若干根目录下所有"已缓存且磁盘已变"的脚本。返回排序后的路径。
static func stale_cached_scripts(roots: Array = []) -> Array:
	var use_roots: Array = roots if not roots.is_empty() else DEFAULT_ROOTS
	var files: Array = []
	for root in use_roots:
		_collect_gd(str(root), files)
	var stale: Array = []
	for path in files:
		if status(path).get("state", "") == "changed":
			stale.append(path)
	stale.sort()
	return stale


## 给测试结果用的一行摘要。
static func describe(stale: Array) -> String:
	if stale.is_empty():
		return ""
	var lines := PackedStringArray()
	var show := mini(stale.size(), 12)
	for i in show:
		lines.append("  - " + str(stale[i]))
	if stale.size() > show:
		lines.append("  … 另有 %d 个" % (stale.size() - show))
	return "\n".join(lines)


# —— 内部 ——

static func _file_hash(path: String) -> int:
	## 空文件也要按空串哈希（与 source_code 一致），否则占位空脚本会被误判成 changed
	return FileAccess.get_file_as_string(path).hash()


static func _collect_gd(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with(".") or entry in SKIP_DIRS:
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect_gd(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
