@tool
## 存档工具 - JSON 明文 / GZIP 压缩二进制
class_name SaveTool

enum Mode {
	JSON, ## 纯 JSON 明文
	GZIP, ## GZIP 压缩二进制
}

const MAX_BACKUPS := 3  ## 保留的滚动备份数

## 保存状态：{ 路径: null | [data, mode] }
## - 路径存在 = 正在保存中
## - null = 无待处理（当前请求直接执行）
## - Array = 有待处理数据（同一路径多次请求，只保留最后一份）
static var _save_states: Dictionary = {}


## 校验版本并补全缺失字段：以 defaults 为底，data 覆盖，缺失字段由 defaults 补齐
## [br]data 不是 Dictionary 时返回 defaults 副本；版本一致时直接返回 data
static func check_version(data: Variant, version: String, defaults: Dictionary) -> Dictionary:
	if not data is Dictionary:
		return defaults.duplicate(true)
	if data.get("version") == version:
		return data
	var result := merge_data(defaults, data)
	result["version"] = version
	return result


# ============================================================
# 数据合并
# ============================================================

enum MergeMode {
	KEEP,        ## 保留 base，忽略 incoming
	OVERWRITE,   ## incoming 覆盖（默认）
	NON_EMPTY,   ## incoming 非空/非零时才覆盖
	MAX,         ## 取 max(base, incoming)
	MAX_SIZE,    ## 数组取更长的
	ARRAY_UNION, ## 数组按 key 去重合并，去重参数通过 union_opts 传入
}

## 合并两个字典，返回新字典（不修改原数据）
## [br]每个字段的值可以是 MergeMode 枚举，或 ARRAY_UNION 时用数组 [MergeMode, dedup_key, limit]
## [br][param rules] 可以是 Dictionary（按字段指定）或单个 MergeMode（全局默认）
## [codeblock]
## SaveTool.merge_data(local, cloud, {name = SaveTool.MergeMode.NON_EMPTY})
## SaveTool.merge_data(local, cloud, SaveTool.MergeMode.KEEP)  # 全部保留本地
## [/codeblock]
static func merge_data(base: Dictionary, incoming: Dictionary, rules: Variant = {}) -> Dictionary:
	if not incoming is Dictionary or incoming.is_empty():
		return base.duplicate(true)
	if not base is Dictionary or base.is_empty():
		return incoming.duplicate(true)

	var default_mode: int = rules if rules is int else MergeMode.OVERWRITE
	var rules_dict: Dictionary = rules if rules is Dictionary else {}

	var result := base.duplicate(true)
	for key in incoming:
		var incoming_val = incoming[key]
		var raw = rules_dict.get(key, default_mode)
		var mode: int = raw if raw is int else raw[0]
		var opts: Array = raw if raw is Array else []
		match mode:
			MergeMode.KEEP:
				pass
			MergeMode.NON_EMPTY:
				if _is_non_empty(incoming_val):
					result[key] = incoming_val
			MergeMode.MAX:
				result[key] = maxi(result.get(key) if result.get(key) is int else 0, incoming_val if incoming_val is int else 0)
			MergeMode.MAX_SIZE:
				if base.get(key) is Array and incoming_val is Array:
					var ba: Array = base[key]; var ia: Array = incoming_val
					result[key] = ba if ba.size() >= ia.size() else ia
				else:
					result[key] = incoming_val
			MergeMode.ARRAY_UNION:
				if base.get(key) is Array and incoming_val is Array:
					result[key] = merge_array_union(base[key], incoming_val, opts[1] if opts.size() > 1 else "", opts[2] if opts.size() > 2 else 0)
				else:
					result[key] = incoming_val if incoming_val is Array else []
			_:
				if incoming_val is Dictionary and result.get(key) is Dictionary:
					result[key] = merge_data(result[key], incoming_val, rules)
				else:
					result[key] = incoming_val
	return result


## 数组并集合并：按 [param dedup_key] 去重，裁剪到 [param limit]
## 注意：返回的数组中的字典元素是原数据的新副本（深拷贝），避免与入参共享引用
static func merge_array_union(base_arr: Array, incoming_arr: Array, dedup_key: String, limit: int = 0) -> Array:
	if incoming_arr.is_empty():
		return base_arr.duplicate(true)
	if base_arr.is_empty():
		var r := incoming_arr.duplicate(true)
		if limit > 0 and r.size() > limit: r = r.slice(0, limit)
		return r

	var merged: Dictionary = {}
	for item in base_arr:
		if item is Dictionary:
			var k = item.get(dedup_key)
			if k != null: merged[k] = item
	for item in incoming_arr:
		if item is Dictionary:
			var k = item.get(dedup_key)
			if k != null: merged[k] = item

	var result: Array = []; result.assign(merged.values())
	if limit > 0 and result.size() > limit:
		result = result.slice(0, limit)
	return result


## 值是否"非空"：非空字符串、非零数字、非空数组/字典
static func _is_non_empty(val) -> bool:
	if val is String: return not val.is_empty()
	if val is int: return val != 0
	if val is float: return val != 0.0
	if val is Array: return not val.is_empty()
	if val is Dictionary: return not val.is_empty()
	return val != null


# ============================================================
# GZIP 编码/解码（可独立调用）
# ============================================================

## 将数据编码为 "GZIP" + 压缩字节数组
static func gzip_encode(data: Variant) -> PackedByteArray:
	var raw := var_to_bytes(data)
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	var out := "GZIP".to_utf8_buffer()
	out.append_array(compressed)
	return out

## 从字节数组解码。有 "GZIP"/"NECD"(旧) 头则解压，无则直接 bytes_to_var
static func gzip_decode(raw: PackedByteArray) -> Variant:
	if raw.size() >= 4:
		if (raw[0] == 0x47 and raw[1] == 0x5A) or (raw[0] == 0x4E and raw[1] == 0x45):
			var decompressed := raw.slice(4).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
			return bytes_to_var(decompressed)
	return bytes_to_var(raw)


# ============================================================
# 文件 I/O
# ============================================================

## 保存数据。JSON: 纯文本。GZIP: gzip_encode → 文件（原子写入 + 滚动备份）
static func save_data(path: String, data, mode: Mode = Mode.JSON) -> Error:
	var _t := LogTool.timer("存档", str("保存 ", path))
	var actual_path := _actual_path(path, mode)
	_make_dir(actual_path)

	var err: Error
	if mode == Mode.JSON:
		err = _atomic_write(actual_path, JSON.stringify(data).to_utf8_buffer())
	else:
		err = _atomic_write(actual_path, gzip_encode(data))

	_t.stop()
	if err == OK and OS.has_feature("editor") and path.begins_with("user://"):
		_save_debug_copy(path, data)
	return err


## 加载数据（主档 → .bak 三级回退）
static func load_data(path: String, mode: Mode = Mode.JSON) -> Variant:
	var _t := LogTool.timer("存档", str("加载 ", path))
	var actual_path := _actual_path(path, mode)
	var result: Variant = _read_file(actual_path, mode, path)
	if result != null:
		_t.stop(); return result
	result = _try_restore_from_bak(actual_path, mode, path)
	_t.stop()
	return result


# ============================================================
# 异步 I/O（AsyncTool 后台线程处理 CPU 密集部分）
# ============================================================

## 异步保存。后台: gzip_encode → 主线程: 写文件
## 同一路径多次调用时，缓存最新数据，当前保存完成后自动补存
## 缓存时也会等待整个保存链完成才返回，确保 await 返回时数据已持久化
static func save_async(path: String, data, mode: Mode = Mode.JSON) -> Error:
	if _save_states.has(path):
		_save_states[path] = [data, mode]
		LogTool.log("SaveTool", "路径 %s 正在保存中，缓存最新数据并等待完成" % path)
		await _wait_save_done(path)
		return OK

	_save_states[path] = null

	if mode == Mode.JSON:
		var err := save_data(path, data, mode)
		return await _flush_pending(path, err)

	var _t := LogTool.timer("存档", str("保存 ", path))
	var bytes: PackedByteArray = await AsyncTool.thread_call(func(): return gzip_encode(data))
	var err := _write_file(path, bytes)
	_t.stop()
	if err == OK and OS.has_feature("editor") and path.begins_with("user://"):
		_save_debug_copy(path, data)

	return await _flush_pending(path, err)

## 等待指定路径的保存链完成（当前保存 → 缓存补存，直到 _save_states 中移除该路径）
static func _wait_save_done(path: String) -> void:
	while _save_states.has(path):
		await Engine.get_main_loop().process_frame

## 检查并处理同一路径的待处理保存，有则递归补存
static func _flush_pending(path: String, last_err: Error) -> Error:
	if _save_states[path] is Array:
		var pending = _save_states[path]
		_save_states.erase(path)
		return await save_async(path, pending[0], pending[1])
	_save_states.erase(path)
	return last_err

## 异步加载（主线程读 → 后台解码；损坏时同步回退 .bak）
static func load_async(path: String, mode: Mode = Mode.JSON) -> Variant:
	if mode == Mode.JSON:
		return load_data(path, mode)

	var actual_path := _actual_path(path, mode)
	var result: Variant = await _read_file_async(actual_path, path)
	if result != null:
		return result
	result = _try_restore_from_bak(actual_path, Mode.GZIP, path)
	return result


## 尝试从最近备份恢复：依次尝试 .1.bak .2.bak ...，首次成功即写回主档
static func _try_restore_from_bak(actual_path: String, mode: Mode, original_path: String = "") -> Variant:
	for i in range(1, MAX_BACKUPS + 1):
		var bak_path := _backup_path(actual_path, i)
		if not FileAccess.file_exists(bak_path):
			continue
		var bak_display = "%s.bak (%s)" % [original_path, bak_path] if not original_path.is_empty() else bak_path
		LogTool.warn("存档", "主档损坏，尝试备份恢复(%d): %s" % [i, bak_display])
		var result: Variant = _read_file(bak_path, mode, original_path)
		if result != null:
			DirAccess.copy_absolute(bak_path, actual_path)
			LogTool.log("存档", "备份恢复成功 (第%d次备份)" % i)
			return result

	var display_path = "%s (实际路径: %s)" % [original_path, actual_path] if not original_path.is_empty() else actual_path
	LogTool.error("存档", "主档和全部备份均损坏，将使用默认档案: %s" % display_path)
	return null


## 同步读文件
static func _read_file(actual_path: String, mode: Mode, original_path: String = "") -> Variant:
	var display := original_path if not original_path.is_empty() else actual_path
	if not FileAccess.file_exists(actual_path):
		LogTool.warn("存档", "文件不存在: %s" % display)
		return null
	if mode == Mode.JSON:
		var file = FileAccess.open(actual_path, FileAccess.READ)
		if not file:
			LogTool.warn("存档", "文件无法打开: %s (错误: %d)" % [display, FileAccess.get_open_error()])
			return null
		var text := file.get_as_text()
		file.close()
		if text.is_empty():
			LogTool.warn("存档", "文件为空: %s" % display)
			return null
		var parsed = JSON.parse_string(text)
		if parsed == null:
			LogTool.warn("存档", "JSON解析失败: %s" % display)
		return parsed
	var file = FileAccess.open(actual_path, FileAccess.READ)
	if not file:
		LogTool.warn("存档", "文件无法打开: %s (错误: %d)" % [display, FileAccess.get_open_error()])
		return null
	var size := file.get_length()
	if size == 0:
		LogTool.warn("存档", "文件为空: %s" % display)
		file.close()
		return null
	var bytes := file.get_buffer(size)
	file.close()
	var decoded = gzip_decode(bytes)
	if decoded == null:
		LogTool.warn("存档", "GZIP解码失败: %s" % display)
	return decoded


## 异步读文件
static func _read_file_async(actual_path: String, original_path: String = "") -> Variant:
	var display := original_path if not original_path.is_empty() else actual_path
	if not FileAccess.file_exists(actual_path):
		LogTool.warn("存档", "文件不存在: %s" % display)
		return null
	var file = FileAccess.open(actual_path, FileAccess.READ)
	if not file:
		LogTool.warn("存档", "文件无法打开: %s (错误: %d)" % [display, FileAccess.get_open_error()])
		return null
	var size := file.get_length()
	if size == 0:
		LogTool.warn("存档", "文件为空: %s" % display)
		file.close()
		return null
	var bytes := file.get_buffer(size)
	file.close()
	var decoded = await AsyncTool.thread_call(func(): return gzip_decode(bytes))
	if decoded == null:
		LogTool.warn("存档", "GZIP解码失败: %s" % display)
	return decoded


## 写入文件
static func _write_file(path: String, bytes: PackedByteArray) -> Error:
	return _atomic_write(_actual_path(path, Mode.GZIP), bytes)

## 原子写入：.tmp 写完后，滚动备份（主档 → .1.bak → .2.bak → ...），.tmp rename 为主档
static func _atomic_write(actual_path: String, bytes: PackedByteArray) -> Error:
	_make_dir(actual_path)
	var tmp_path := actual_path + ".tmp"
	var file = FileAccess.open(tmp_path, FileAccess.WRITE)
	if not file:
		LogTool.error("存档", "无法打开文件:", tmp_path)
		return FAILED
	file.store_buffer(bytes)
	file.close()

	if FileAccess.file_exists(actual_path):
		_rotate_backups(actual_path)

	return DirAccess.rename_absolute(tmp_path, actual_path)


## 滚动备份：.N.bak → .(N+1).bak，主档 → .1.bak，超出 MAX_BACKUPS 则删除
static func _rotate_backups(actual_path: String) -> void:
	# 从最旧开始删除
	var last_path := _backup_path(actual_path, MAX_BACKUPS)
	if FileAccess.file_exists(last_path):
		DirAccess.remove_absolute(last_path)
	# 从后往前滚动
	for i in range(MAX_BACKUPS - 1, 0, -1):
		var old_path := _backup_path(actual_path, i)
		if FileAccess.file_exists(old_path):
			DirAccess.rename_absolute(old_path, _backup_path(actual_path, i + 1))
	# 主档 → .1.bak
	DirAccess.rename_absolute(actual_path, _backup_path(actual_path, 1))


static func _backup_path(actual_path: String, index: int) -> String:
	return actual_path + ".%d.bak" % index

static func _make_dir(path: String) -> void:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

## 编辑器调试副本
static func _save_debug_copy(path: String, data) -> void:
	var df := FileAccess.open(path + ".debug.json", FileAccess.WRITE)
	if df:
		df.store_string(JSON.stringify(data))
		df.close()


## 检查文件是否存在
static func file_exists(path: String, mode: Mode = Mode.JSON) -> bool:
	return FileAccess.file_exists(_actual_path(path, mode))


## 删除存档（含滚动备份和调试副本）
static func delete_data(path: String, mode: Mode = Mode.JSON) -> Error:
	var actual_path := _actual_path(path, mode)
	if not FileAccess.file_exists(actual_path):
		return FAILED
	var err := DirAccess.remove_absolute(actual_path)
	if err != OK:
		LogTool.error("存档", "删除文件失败:", path, "错误:", err)
		return err
	# 删除所有滚动备份
	for i in range(1, MAX_BACKUPS + 1):
		var bak_path := _backup_path(actual_path, i)
		if FileAccess.file_exists(bak_path):
			DirAccess.remove_absolute(bak_path)
	# 删除编辑器调试副本
	if OS.has_feature("editor") and path.begins_with("user://"):
		var debug_path := path + ".debug.json"
		if FileAccess.file_exists(debug_path):
			DirAccess.remove_absolute(debug_path)
	return OK


# ============================================================
# 内部：路径解析
# ============================================================

## GZIP 模式用 SHA256 哈希文件名
static func _actual_path(path: String, mode: Mode) -> String:
	if mode == Mode.GZIP:
		var hash := _sha256(path)
		return path.get_base_dir().path_join(hash)
	return path

static func _sha256(input: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(input.to_utf8_buffer())
	return ctx.finish().hex_encode()


# ============================================================
# 资源扫描（支持打包后的 .remap 路径）
# ============================================================

## 递归扫描 res:// 目录，用回调过滤资源
static func load_defs(dir_path: String, filter: Callable) -> Array[Def]:
	var result: Array[Def] = []
	var dir := DirAccess.open(dir_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		var full_path := dir_path.path_join(file_name)
		if dir.current_is_dir():
			result.append_array(load_defs(full_path + "/", filter))
		elif file_name.ends_with(".tres") or file_name.ends_with(".tres.remap"):
			var true_path := full_path.trim_suffix(".remap")
			if not ResourceLoader.exists(true_path):
				file_name = dir.get_next()
				continue
			var res = load(true_path)
			if filter.call(res):
				result.append(res)
		file_name = dir.get_next()
	dir.list_dir_end()
	return result
