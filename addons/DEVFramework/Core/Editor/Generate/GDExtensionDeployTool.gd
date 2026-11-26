@tool
class_name GDExtensionDeployTool
extends RefCounted

## GDExtension 构建的"部署与声明"切片: 产物校验/改名保活/清理、universal 合并、

## 约束 1: 必须 extends RefCounted —— EditorScriptMenuTool 会把 extends…

var _host   # GDExtensionRebuild 实例
var _probe: GDExtensionProbeTool   # 规范名/架构/声明解析等只读探测

## 部署: 默认名直出 → 实盘最新非常规名动态库 → 已存在规范名, 三级判定后统一**改名**为规范名
func _deploy(target_res: String, info: Dictionary, type: String, arch: String,
		out_dir_override := "", tgt := "") -> String:
	var out_dir: String = out_dir_override
	if out_dir == "" and not (info.get("out_dirs", []) as Array).is_empty():
		out_dir = String(info.get("out_dirs", [])[0])
	var target := tgt if tgt != "" else String(info.get("target", ""))
	var canonical := _probe._canonical_file(target, type, arch)
	var actual := ""
	var direct := _probe._default_out_file(target)   # CMake 默认直出名(刚链接, mtime 最新, 内容必然新鲜)
	# 已知命名集合 = 默认名 + 本目标全部 类型×架构 规范名: 都是"声明/最终形态"文件,
	var known := PackedStringArray()
	if direct != "":
		known.append(direct)
	for t in GDExtensionProbeTool.GDEXT_TYPES:
		for a in GDExtensionProbeTool.GDEXT_ARCHS:
			known.append(_probe._canonical_file(target, t, a))
	# 默认名命中须是"本次链接"的产物(mtime ≥ 本次编译启动): 编译器直出名与本工具约定不符时
	var direct_fresh := false
	if direct != "" and FileAccess.file_exists(String(out_dir).path_join(direct)):
		direct_fresh = FileAccess.get_modified_time(String(out_dir).path_join(direct)) + 5.0 >= _host._build_started_unix
	if direct_fresh:
		# 默认名存在 → 本次链接产物, 强制改名归位(覆盖可能残留的旧规范名, 杜绝陈旧命中)
		if _rename_lib(out_dir, direct, canonical):
			_host._log("产物规范命名: ", direct, " → ", canonical)
			actual = canonical
		else:
			_host._log("警告: 规范命名失败(文件可能被占用), 保留 ", direct, "; 声明同步将按实盘名对齐。")
			actual = direct
	else:
		# 默认名缺失/非本次产物 → 先实盘取本目标"最新"的非常规名动态库(刚链接完, 最新即本次
		actual = _probe._scan_dynamic_libs(out_dir, target, known)
		if actual != "":
			_host._log("规范名产物未直出, 实盘取最新动态库: ", actual)
		elif FileAccess.file_exists(_host._abs(target_res)):
			actual = canonical   # 直出名即规范名(CMake 钉了 OUTPUT_NAME)
	if actual == "":
		_host._log("预期产物未生成: ", _host._abs(target_res))
		_host._log("请确认 CMakeLists 已钉 *_OUTPUT_DIRECTORY 直出目录, 并检查上方编译输出。")
		return ""
	if actual != canonical:
		if _rename_lib(out_dir, actual, canonical):
			_host._log("产物规范命名: ", actual, " → ", canonical)
			actual = canonical
	_host._log("产物已就位: ", _probe._abs_to_res(out_dir).path_join(actual))
	return actual

## 源码/构建配置都没变 → 本次可**完全跳过编译**。
func _up_to_date(target_res: String, out_dir: String, tgt: String) -> bool:
	if not FileAccess.file_exists(_host._abs(target_res)):
		return false
	var deployed: int = int(FileAccess.get_modified_time(_host._abs(target_res)))
	# 源码(含 .h)比产物新 → 必须重编。
	if GDExtensionProbeTool._native_src_mtime(PackedStringArray([".cpp", ".h", ".hpp", ".c"]), tgt) > deployed:
		return false
	# 生成的 CMakeLists 变过(换模板/加插件/改参数) → 也要重配+重编
	for cfg in ["res://gdextension/CMakeLists.txt"]:
		if FileAccess.file_exists(cfg) and int(FileAccess.get_modified_time(cfg)) > deployed:
			return false
	return true

## 输出目录里是否已有一个"比已部署库新、且不比源码旧"的产物 —— 即上次编译完成但没部署。
func _artifact_ready(info: Dictionary, type: String, arch: String, target_res: String,
		out_dir_override := "", tgt := "") -> bool:
	var out_dirs: Array = info.get("out_dirs", [])
	var target := tgt if tgt != "" else String(info.get("target", ""))
	var out_dir := out_dir_override
	if out_dir == "" and not out_dirs.is_empty():
		out_dir = String(out_dirs[0])
	if out_dir == "" or target == "":
		return false
	var deployed_ms := 0
	if FileAccess.file_exists(_host._abs(target_res)):
		deployed_ms = int(FileAccess.get_modified_time(_host._abs(target_res)))
	# 同上: 只看本 target 的源码, 否则别的插件改一行就会让这里误判"产物过期"。
	var src_ms := GDExtensionProbeTool._native_src_mtime(PackedStringArray([".cpp", ".h", ".hpp", ".c"]), tgt)
	var best := 0
	for cand in [_probe._default_out_file(target), _probe._canonical_file(target, type, arch)]:
		if cand == "":
			continue
		var p := out_dir.path_join(cand)
		if FileAccess.file_exists(p):
			best = maxi(best, int(FileAccess.get_modified_time(p)))
	return best > 0 and best > deployed_ms and best >= src_ms

## 同目录改名。
func _rename_lib(dir_path: String, from_file: String, to_file: String) -> bool:
	var from_abs := String(dir_path).path_join(from_file)
	var to_abs := String(dir_path).path_join(to_file)
	if from_abs == to_abs:
		return true
	if FileAccess.file_exists(to_abs) and DirAccess.remove_absolute(to_abs) != OK:
		var aside := "%s.old.%d" % [to_abs, Time.get_ticks_usec()]
		if DirAccess.rename_absolute(to_abs, aside) != OK:
			return false   # 连重命名都不行: 调用方回退到"按实盘名部署 + 改写声明"
		_host._log("旧产物被占用, 已旁置: ", aside.get_file(), "(下次构建时清理)")
	return DirAccess.rename_absolute(from_abs, to_abs) == OK

## 终清: 全部轮次与合并完成后执行一次(轮间零清理, 合并输入绝不误删)。
func _final_cleanup(targets: Array, gdext_by_target: Dictionary) -> void:
	var types: Array[String] = _host._build_types if not _host._build_types.is_empty() else ["debug", "release"]
	var seen := {}
	for tg in targets:
		var target := String(tg.get("target", ""))
		var native_dir := String(tg.get("out_dir", ""))
		var dir_key := "%s|%s" % [target, native_dir]
		if target == "" or native_dir == "" or seen.has(dir_key):
			continue
		seen[dir_key] = true
		var gdext_res := String(gdext_by_target.get(target, ""))
		var keep := _probe._gdext_keep_files(gdext_res) if gdext_res != "" else PackedStringArray()
		keep.append(target + ".gdextension")
		for a in (["x86_64", "arm64", "arm32", "x86_32"] if gdext_res == "" else _probe._declared_archs(gdext_res)):
			for bt in types:
				keep.append(_probe._canonical_file(target, bt, a))
		if _probe._os_label() == "macos":
			for bt in types:
				keep.append(_probe._universal_file(target, bt))
		_cleanup_native(native_dir, keep)

## lipo 合并: 同类型多架构产物 → universal 单文件, 成功后**删除输入架构文件**
func _lipo_merge(out_dir_override: String, target: String, type: String, files: Array) -> String:
	if _probe._os_label() != "macos" or files.size() < 2:
		return ""
	var out_dir := out_dir_override
	var out_name := _probe._universal_file(target, type)
	var out_abs := String(out_dir).path_join(out_name)
	var args := PackedStringArray(["-create"])
	for f in files:
		args.append(String(out_dir).path_join(String(f)))
	args.append_array(["-output", out_abs])
	DirAccess.remove_absolute(out_abs)   # lipo 不覆盖已存在输出
	var out: Array = []
	if OS.execute("lipo", args, out, true) != 0:
		_host._log("lipo 合并失败(不影响各架构独立产物): ", " ".join(out))
		return ""
	_host._log("lipo 合并完成: ", _probe._abs_to_res(out_dir).path_join(out_name), " ← ", ", ".join(files))
	var removed := 0
	for f in files:
		var in_abs := String(out_dir).path_join(String(f))
		if FileAccess.file_exists(in_abs) and DirAccess.remove_absolute(in_abs) == OK:
			removed += 1
		else:
			_host._log("警告: 架构产物删除失败(可能被占用, 可手动删除): ", String(f))
	if removed > 0:
		_host._log("已删除合并输入架构产物 %d 项(universal 为最终形态)。" % removed)
	return _probe._abs_to_res(out_dir).path_join(out_name)

## 声明切换 universal: 合并成功后调用 —— 本平台+本类型的架构专属键改写/删除, 统一为
func _gdext_adopt_universal(gdext_res: String, platform: String, type: String, uni_res: String) -> void:
	var parsed := _probe._gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var lines: PackedStringArray = parsed["lines"]
	var uni_key := "%s.%s.universal" % [platform, type]
	var value := "\"%s\"" % uni_res
	var uni_line := -1        # 已有 universal 键的行号
	var first_arch_line := -1 # 首个架构专属键行号(无 universal 键时改写为 universal 键)
	var remove_lines := {}    # 待删除的架构键行号
	var covered := false      # 已有本平台本类型的**通用键**(macos.release)指向同一 universal 文件
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		var tags := key.split(".")
		if tags.is_empty() or tags[0] != platform:
			continue
		var has_type := false
		var has_arch := false
		for t in tags:
			if GDExtensionProbeTool.GDEXT_TYPES.has(t):
				has_type = true
			elif GDExtensionProbeTool.GDEXT_ARCHS.has(t):
				has_arch = true
		if not has_type or not tags.has(type):
			continue
		if not has_arch:
			# 通用键已指向 universal 产物 → 无需再加 universal 键(同类型两条键会触发重复库告警)
			if String(parsed["values"].get(key, "")) == uni_res:
				covered = true
			continue
		var ln := int(ent.get("line"))
		if tags.has("universal"):
			uni_line = ln
		elif first_arch_line < 0:
			first_arch_line = ln
		else:
			remove_lines[ln] = true
	var target_line := -1
	var write_key := ""
	if covered:
		# 通用键(如 macos.release)已指向 universal → 架构键/universal 键都是多余的, 一并删除,
		var dropped := 0
		for ln: int in [uni_line, first_arch_line]:
			if ln >= 0:
				remove_lines[ln] = true
				dropped += 1
		if dropped > 0:
			_host._log("通用键已覆盖 universal, 移除多余键 %d 条: " % dropped, String(gdext_res).get_file())
	elif uni_line >= 0:
		target_line = uni_line
		write_key = uni_key
		if first_arch_line >= 0:
			remove_lines[first_arch_line] = true   # universal 键已存在时, 残留架构键一并删除(指向文件已合并删除)
	elif first_arch_line >= 0:
		target_line = first_arch_line
		write_key = uni_key
	if target_line >= 0:
		if String(lines[target_line]) == "%s = %s" % [write_key, value]:
			_host._log("声明已一致, 无需同步: ", String(gdext_res).get_file(), " [", uni_key, "]")
		else:
			lines[target_line] = "%s = %s" % [write_key, value]
			_host._synced.append("%s → %s(切换 universal)" % [uni_key, uni_res])
			_host._log("已同步声明(切换 universal): ", gdext_res, " [", uni_key, "] = ", value)
	elif not covered:
		lines.insert(int(parsed["lib_end"]), "%s = %s" % [uni_key, value])
		_host._synced.append("%s → %s(新增)" % [uni_key, uni_res])
		_host._log("已同步声明(新增): ", gdext_res, " [", uni_key, "] = ", value)
	var out: Array[String] = []
	for i in lines.size():
		if remove_lines.has(i):
			continue   # 删除多余架构键行
		out.append(String(lines[i]))
	if FileTool.atomic_write_text(gdext_res, "\n".join(out)) != OK:
		_host._log("声明写回失败: ", gdext_res)
		return

## 声明同步: 以实盘产物为准, 把 [libraries] 里"本平台"的键值对齐到本次产物。
func _gdext_sync(gdext_res: String, file_res: String, platform: String, type: String, file: String,
		canonical := "") -> void:
	var parsed := _probe._gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var lines: PackedStringArray = parsed["lines"]
	var value := "\"%s\"" % file_res
	var arch := GDExtensionProbeTool._file_arch(file)
	var changed := false
	var touched: Array[String] = []
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		if not key.begins_with(platform + "."):
			continue
		var declared := String(parsed["values"].get(key, ""))
		var matched := GDExtensionProbeTool._gdext_key_matches(key, platform, type, arch)
		var dangling := declared != "" and not FileAccess.file_exists(declared)
		var same_product := canonical != "" and declared.get_file() == canonical
		if not matched and not dangling and not same_product:
			continue
		if declared == file_res:
			continue   # 已一致
		lines[int(ent.get("line"))] = "%s = %s" % [key, value]
		touched.append(key)
		changed = true
	if not changed:
		_host._log("声明已一致, 无需同步: ", String(gdext_res).get_file())
		return
	for k in touched:
		_host._synced.append("%s → %s" % [k, file_res])
		_host._log("已同步声明: ", gdext_res, " [", k, "] = ", value)
	if FileTool.atomic_write_text(gdext_res, "\n".join(lines)) != OK:
		_host._log("声明写回失败: ", gdext_res)
		return

	# 本平台没有任何可用的键(纯 CMake 新工程)才补一条; 同名键已存在时改写而非追加,
	for ent in parsed["entries"]:
		if String(ent.get("key")).begins_with(platform + "."):
			return
	var new_key := "%s.%s" % [platform, type]
	if arch != "":
		new_key += "." + arch
	var at: int = parsed["lib_end"]
	while at > 0 and String(lines[at - 1]).strip_edges() == "":
		at -= 1
	lines.insert(at, "%s = %s" % [new_key, value])
	_host._synced.append("%s → %s(新增)" % [new_key, file_res])
	_host._log("已同步声明(新增): ", gdext_res, " [", new_key, "] = ", value)
	if FileTool.atomic_write_text(gdext_res, "\n".join(lines)) != OK:
		_host._log("声明写回失败: ", gdext_res)

## sync 关闭时的退化模式: 只校验不回写 —— 声明与实盘不一致时明确告警(引擎将加载失败)。
func _gdext_verify(gdext_res: String, platform: String, type: String, file: String) -> void:
	var parsed := _probe._gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var seen := false
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		if not GDExtensionProbeTool._gdext_key_matches(key, platform, type, GDExtensionProbeTool._file_arch(file)):
			continue
		seen = true
		var declared := String(parsed["values"].get(key, "")).get_file()
		if declared != file:
			_host._log("警告: 声明不一致 —— [", key, "] 指向 ", declared, ", 实际产物 ", file, "; 引擎可能无法加载!")
			_host._log("可开启 dev_framework/gdextension_build/sync_gdextension 自动对齐, 或修正 CMakeLists OUTPUT_NAME。")
		break
	if not seen:
		_host._log("警告: ", String(gdext_res).get_file(), " 缺少 [", platform, ".", type, "] 声明键, 引擎可能无法加载本产物(开启 sync 可自动补齐)。")

func _cleanup_native(native_dir: String, keep: PackedStringArray) -> void:
	var keep_set := {}
	for k in keep:
		keep_set[k] = true
	var dir := DirAccess.open(native_dir)
	if dir == null:
		return
	var removed := 0
	# ⚠ 必须包含隐藏文件: Windows 的 ReplaceFile 残留(`xxx.dll~RF123abc.TMP`)与部分改名旁置
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var low := entry.to_lower()
		# 垃圾文件统一规则(不限于动态库后缀):
		var is_tmp := entry.begins_with("~") or low.ends_with(".tmp") or low.ends_with(".temp") \
				or low.contains(".old.") or low.ends_with(".dll.a")
		var is_lib := low.ends_with(".dll") or low.ends_with(".so") or low.ends_with(".dylib") \
				or low.ends_with(".a") or low.ends_with(".lib")
		if not dir.current_is_dir() and not keep_set.has(entry) and (is_tmp or is_lib):
			if dir.remove(entry) == OK:
				removed += 1
				_host._log("清理非必要产物: ", entry)
			elif entry.begins_with("~lib"):
				# Windows 上 Godot 会把扩展库复制成 `~<原名>` 再加载(为了能覆盖原文件),
				_host._log("跳过引擎运行期副本(重启编辑器后可清理): ", entry)
			else:
				_host._log("清理失败(文件可能被占用): ", entry)
		entry = dir.get_next()
	dir.list_dir_end()
	if removed > 0:
		_host._log("Native 仅保留 CMake 声明的各平台产物, 已清理 ", removed, " 项。")
