@tool
## 存档工具 - JSON 明文 / GZIP 压缩二进制 / 原样字节
class_name SaveTool

enum Mode {
	JSON, ## 纯 JSON 明文
	GZIP, ## GZIP 压缩二进制（路径会被哈希成文件名，属"存档槽"语义，不适合用户可见文件）
	BYTES, ## 原样字节：内容由调用方自带编码（如 .qvox）；写入不做变换、路径不改名
}

## 唯一一份备份的后缀：写入前把当前主档转存为它（只保留上一份成功内容，够回滚一步）
const BACKUP_SUFFIX := ".bak"

## 保存状态：{ 路径: null | [data, mode] }
## - 路径存在 = 正在保存中
## - null = 无待处理（当前请求直接执行）
## - Array = 有待处理数据（同一路径多次请求，只保留最后一份）
static var _save_states: Dictionary = {}


## 会话级复位：丢弃未落盘的待处理请求（在途写盘不受影响）
static func reset() -> void:
	_save_states.clear()


## 校验版本并补全缺失字段：以 defaults 为底，data 覆盖，缺失字段由 defaults 补齐
static func check_version(data: Variant, version: String, defaults: Dictionary) -> Dictionary:
	if not data is Dictionary:
		return defaults.duplicate(true)
	if data.get("version") == version:
		return data
	var result := merge_data(defaults, data)
	result["version"] = version
	return result


## 比较两个点分语义版本号（如 "0.5.0"、"1.2.3.4"）
static func compare_version(a: String, b: String) -> int:
	if a.is_empty() or b.is_empty():
		return 0
	var pa := a.split(".")
	var pb := b.split(".")
	var n := maxi(pa.size(), pb.size())
	for i in n:
		var va := int(pa[i]) if i < pa.size() else 0
		var vb := int(pb[i]) if i < pb.size() else 0
		if va != vb:
			return 1 if va > vb else -1
	return 0


## a 版本号严格高于 b 时返回 true（含相等语义，遵循 compare_version）
static func is_version_newer(a: String, b: String) -> bool:
	return compare_version(a, b) > 0


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
				var base_val = result.get(key)
				## 只比数值（int / float 都算）：旧实现用 `maxi(_, else 0)` 把 float 字段静默归零
				## （时间戳字段踩过）。非数值（规则误配到文本/数组上）保留 base，
				## 与 ARRAY_UNION 的自愈约定一致：一个坏值不该把好数据清空。
				if (base_val is int or base_val is float) and (incoming_val is int or incoming_val is float):
					result[key] = max(base_val, incoming_val)
			MergeMode.MAX_SIZE:
				if base.get(key) is Array and incoming_val is Array:
					var ba: Array = base[key]; var ia: Array = incoming_val
					result[key] = ba if ba.size() >= ia.size() else ia
				else:
					result[key] = incoming_val
			MergeMode.ARRAY_UNION:
				if incoming_val is Array:
					if base.get(key) is Array:
						result[key] = merge_array_union(base[key], incoming_val, opts[1] if opts.size() > 1 else "", opts[2] if opts.size() > 2 else 0)
					else:
						result[key] = incoming_val
				# incoming 不是数组（字段被写坏 / 类型不符）⇒ **保留 base**：
				# 旧实现写 `result[key] = []`，会让一个坏值把本地好数组清空（实测过）

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

## 保存数据。JSON: 纯文本。GZIP: gzip_encode。BYTES: 原样落盘（均为原子写入 + 单份备份）
static func save_data(path: String, data, mode: Mode = Mode.JSON, keep_backup := true) -> Error:
	var _t := LogTool.timer("存档", str("保存 ", path))
	var actual_path := _actual_path(path, mode)
	FileTool.ensure_dir(actual_path)

	var err: Error
	if mode == Mode.JSON:
		err = _atomic_write(actual_path, JSON.stringify(data).to_utf8_buffer(), keep_backup)
	elif mode == Mode.BYTES:
		## BYTES 只接受已编码好的字节: 传别的东西进来会写成 0 字节, 而且 _atomic_write 会先把主档轮转成 .bak,
		## 等于静默毁档, 所以在写之前就拒掉。
		if not (data is PackedByteArray):
			LogTool.error("存档", "Mode.BYTES 需要 PackedByteArray: %s" % path)
			_t.stop()
			return ERR_INVALID_PARAMETER
		err = _atomic_write(actual_path, data, keep_backup)
	else:
		err = _atomic_write(actual_path, gzip_encode(data), keep_backup)

	_t.stop()
	return err


## 加载数据（主档 → 唯一备份回退）。
## `decode` 只在 JSON/GZIP 之外需要：这两种模式自带"解码失败 = 这份内容不能用"的判据，而
static func load_data(path: String, mode: Mode = Mode.JSON, decode: Callable = Callable()) -> Variant:
	var _t := LogTool.timer("存档", str("加载 ", path))
	var actual_path := _actual_path(path, mode)
	var result: Variant = _read_file(actual_path, mode, path, decode)
	if result != null:
		_t.stop(); return result
	result = _try_restore_from_bak(actual_path, mode, path, decode)
	_t.stop()
	return result


# ============================================================

## 异步保存。后台: gzip_encode → 主线程: 写文件
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
	# 先做快照：后台线程编码期间主线程仍会修改原容器（Array/Dictionary 非线程安全），
	# 直接共享可能导致序列化结果错乱（如字典被平铺成"键/值"交替的元素），必须先深拷贝
	var snapshot: Variant = data.duplicate(true) if (data is Array or data is Dictionary) else data
	var bytes: PackedByteArray = PackedByteArray()
	if mode == Mode.BYTES:
		# BYTES: 调用方自带编码, 原样落盘(与同步 save_data 一致, 不做 gzip)
		if not (snapshot is PackedByteArray):
			LogTool.error("存档", "Mode.BYTES 需要 PackedByteArray: %s" % path)
			_t.stop()
			return await _flush_pending(path, ERR_INVALID_PARAMETER)
		bytes = snapshot
	else:
		var enc = await AsyncTool.thread_call(func(): return gzip_encode(snapshot))
		if enc == null:
			# 后台编码失败: 走统一收尾(清理保存态), 避免该路径永久卡在"正在保存中"
			LogTool.error("存档", "GZIP 编码失败: %s" % path)
			_t.stop()
			return await _flush_pending(path, FAILED)
		bytes = enc
	var err := _write_file(path, bytes, mode)
	_t.stop()
	return await _flush_pending(path, err)

## 等待保存链的超时（毫秒）。正常一次保存 300ms 内完成，超出说明保存链异常收尾（写盘/编码失败没清状态）。
## 必须有上限：这里原本是"无限等"，一旦某条链卡住，之后该路径的所有保存都会永远挂在这里
const WAIT_SAVE_TIMEOUT_MS := 10000

## 等待指定路径的保存链完成（当前保存 → 缓存补存，直到 _save_states 中移除该路径）
static func _wait_save_done(path: String) -> void:
	var deadline := Time.get_ticks_msec() + WAIT_SAVE_TIMEOUT_MS
	while _save_states.has(path):
		if Time.get_ticks_msec() >= deadline:
			## 超时即接管：清掉死掉的状态让后续保存能继续，宁可丢一次合并写，也不要把流程永久卡住
			LogTool.error("SaveTool", "等待保存完成超时(>%dms)，接管并清理状态: %s" % [WAIT_SAVE_TIMEOUT_MS, path])
			_save_states.erase(path)
			return
		await Engine.get_main_loop().process_frame

## 检查并处理同一路径的待处理保存，有则递归补存
static func _flush_pending(path: String, last_err: Error) -> Error:
	## 必须用 get(): _wait_save_done 超时接管时会先 erase 掉该路径,
	## 这里再用 [] 访问就会报 "Invalid access to property or key ... on Dictionary",
	## 而且报错发生在 await 链里, 会把整条保存流程中断。
	var pending: Variant = _save_states.get(path)
	_save_states.erase(path)
	if pending is Array:
		return await save_async(path, pending[0], pending[1])
	return last_err

## 异步加载（主线程读 → 后台解码；损坏时同步回退 .bak）
static func load_async(path: String, mode: Mode = Mode.JSON) -> Variant:
	if mode != Mode.GZIP:
		return load_data(path, mode)

	var actual_path := _actual_path(path, mode)
	var result: Variant = await _read_file_async(actual_path, path)
	if result != null:
		return result
	result = _try_restore_from_bak(actual_path, Mode.GZIP, path)
	return result


## 尝试从唯一备份恢复：成功即写回主档
static func _try_restore_from_bak(actual_path: String, mode: Mode, original_path: String = "", decode: Callable = Callable()) -> Variant:
	var bak_path := actual_path + BACKUP_SUFFIX
	var display_path = "%s (实际路径: %s)" % [original_path, actual_path] if not original_path.is_empty() else actual_path
	if not FileAccess.file_exists(bak_path):
		LogTool.error("存档", "主档损坏且无备份，将使用默认档案: %s" % display_path)
		return null
	LogTool.warn("存档", "主档损坏，尝试备份恢复: %s.bak" % display_path)
	var result: Variant = _read_file(bak_path, mode, original_path, decode)
	if result != null:
		DirAccess.copy_absolute(bak_path, actual_path)
		LogTool.log("存档", "备份恢复成功: %s" % display_path)
		return result
	LogTool.error("存档", "主档和备份均损坏，将使用默认档案: %s" % display_path)
	return null


## 同步读文件。`decode` 非 null 且 mode == BYTES 时接管"字节 → 可用内容"：返回 null 即视为损坏。
static func _read_file(actual_path: String, mode: Mode, original_path: String = "", decode: Callable = Callable()) -> Variant:
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
		var parsed = VariantTool.parse_json(text)
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
	if mode == Mode.BYTES:
		if not decode.is_valid():
			return bytes
		var value: Variant = decode.call(bytes)
		if value == null:
			LogTool.warn("存档", "内容校验未通过: %s" % display)
		return value
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


## 写入文件（按 mode 计算实际落盘路径，与同步 save_data 的 _actual_path 保持一致）
static func _write_file(path: String, bytes: PackedByteArray, mode: Mode) -> Error:
	return _atomic_write(_actual_path(path, mode), bytes)

## 原子写入：先把当前主档转存为唯一备份，再由 FileTool 统一原子落盘
static func _atomic_write(actual_path: String, bytes: PackedByteArray, keep_backup := true) -> Error:
	FileTool.ensure_dir(actual_path)
	if keep_backup and FileAccess.file_exists(actual_path):
		_rotate_backup(actual_path)
	return FileTool.atomic_write_bytes(actual_path, bytes)


## 备份轮转：主档 → .bak（只保留上一份成功内容；旧备份直接丢弃）
## 先改名到 .bak.tmp 再替换: 若先删旧备份再改名, 中途失败就一份备份都不剩了。
static func _rotate_backup(actual_path: String) -> void:
	var bak_path := actual_path + BACKUP_SUFFIX
	var tmp := bak_path + ".tmp"
	DirAccess.remove_absolute(tmp)
	if DirAccess.rename_absolute(actual_path, tmp) != OK:
		return  # 主档还在, 只是这轮没备份
	DirAccess.remove_absolute(bak_path)
	if DirAccess.rename_absolute(tmp, bak_path) != OK:
		DirAccess.rename_absolute(tmp, actual_path)  # 回滚: 宁可没备份, 也不能没主档


## 检查文件是否存在
static func file_exists(path: String, mode: Mode = Mode.JSON) -> bool:
	return FileAccess.file_exists(_actual_path(path, mode))


## 删除存档（含唯一备份）
static func delete_data(path: String, mode: Mode = Mode.JSON) -> Error:
	var actual_path := _actual_path(path, mode)
	if not FileAccess.file_exists(actual_path):
		return FAILED
	var err := DirAccess.remove_absolute(actual_path)
	if err != OK:
		LogTool.error("存档", "删除文件失败:", path, "错误:", err)
		return err
	var bak_path := actual_path + BACKUP_SUFFIX
	if FileAccess.file_exists(bak_path):
		DirAccess.remove_absolute(bak_path)
	return OK


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

## 递归扫描 res:// 目录、用回调过滤资源（.remap 归一由 FileTool.list_files 统一处理）。
static func load_defs(dir_path: String, filter: Callable,
		extensions: PackedStringArray = PackedStringArray([".tres"])) -> Array[Def]:
	var result: Array[Def] = []
	for true_path in FileTool.list_files(dir_path, extensions):
		var res := FileTool.load_resource(true_path)
		if res != null and filter.call(res):
			result.append(res)
	return result
