@tool
class_name GDExtensionProbeTool
extends RefCounted

## GDExtension 构建的"探测与解析"切片: 源码目录/目标名/架构/构建类型/产物规范名/*.gdextension 解析。

## 约束 1: 必须 extends RefCounted —— EditorScriptMenuTool 会把 extends…

var _host   # GDExtensionRebuild 实例(运行期唯一状态持有者)

## 项目设置键/常量: 这里是权威定义, 键名一个字都不能改; GDExtensionRebuild 只保留它自己用到的。
const KEY_CROSS_ARCHS := "dev_framework/gdextension_build/cross_archs"       # macOS 按声明自动交叉补缺架构
const KEY_BUILD_TYPES := "dev_framework/gdextension_build/build_types"   # 要构建的构建类型(Array[String], 如 ["release"]=仅 release); 空=当前编辑器类型+另一版本
const GDEXT_TYPES := ["debug", "release", "template_debug", "template_release"]   # 声明键中的构建类型 tag
const GDEXT_ARCHS := ["arm64", "x86_64", "arm32", "x86_32", "universal"]          # 声明键/规范名中的架构 tag
const SCAFFOLD_PATH := "res://addons/DEVFramework/Core/Editor/Generate/NativeScaffold.gd"
## 唯一构建区: 项目根 res://gdextension/(CMakeLists + godot-cpp + 构建缓存)。
const BUILD_ZONE := "res://gdextension"

## 所有插件的原生源码目录: <插件>/Native/src(每插件一库, 共用 godot-cpp)。
static func native_source_dirs() -> Array[String]:
	var out: Array[String] = []
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	var scaf: GDScript = load(SCAFFOLD_PATH) as GDScript
	if scaf != null:
		for p in scaf.discover_plugins(root):
			out.append("res://" + String(p["src_abs"]).replace(root, "").replace("\\", "/").trim_prefix("/"))
	return out

## 某个 target 自己的源码目录(绝对路径); 找不到返回空串。
static func _native_src_dir_of(tgt: String) -> String:
	if tgt.is_empty():
		return ""
	var scaf: GDScript = load(SCAFFOLD_PATH) as GDScript
	if scaf == null:
		return ""
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	for p in scaf.discover_plugins(root):
		if String(p["target"]) == tgt:
			return String(p["src_abs"])
	return ""

## 源码最新 mtime。
static func _native_src_mtime(exts: PackedStringArray, tgt := "") -> int:
	var ms := 0
	var own := _native_src_dir_of(tgt)
	if own != "":
		for f in FileTool.list_files(own, exts):
			ms = maxi(ms, int(FileAccess.get_modified_time(f)))
		return ms
	for d in native_source_dirs():
		for f in FileTool.list_files(d, exts):
			ms = maxi(ms, int(FileAccess.get_modified_time(f)))
	return ms

## 定位构建目标 —— 只需 CMakeLists 给出 目标名 + 输出目录。
func _locate() -> Dictionary:
	# 唯一构建区: 项目根 gdextension/(CMakeLists + godot-cpp)。
	var source_dir := BUILD_ZONE
	if not _is_ext_source(source_dir):
		_host._log("未找到原生构建区: 需要 %s/CMakeLists.txt + godot-cpp/。插件源码放 addons/<插件>/Native/src, 构建脚本会自动生成骨架。" % BUILD_ZONE)
		return {}
	var info := _read_cmake_info(source_dir)
	var gdext_res := _find_gdextension(info)

	# 类型 = 配置的构建类型(如 ["release"]=仅 release, 单版本提速); 空配置则 [当前编辑器类型优先, 另一类型]
	var types: Array[String] = _plan_build_types()
	var archs := _plan_archs(gdext_res)
	var targets: Array = []
	var outputs: Dictionary = info.get("outputs", {})
	var names: Array = outputs.keys()
	if names.is_empty():
		names = [String(info.get("target", ""))]
	# 共享插件(junction)的产物目录带**其它项目**的归属标记 → 本项目不构建。
	for tgt in names:
		var od: String = String(outputs.get(tgt, ""))
		for t in types:
			for a in archs:
				var art := _expected_artifact(info, t, a, od, String(tgt))
				if art.is_empty():
					_host._log("CMakeLists.txt 无法推导产物: 需要 add_library(<name> SHARED) 与 *_OUTPUT_DIRECTORY 直出目录。")
					return {}
				targets.append({"target": String(tgt), "type": t, "arch": a,
						"artifact": String(art.get("res")), "out_dir": od})
	# 每个 target 自己的声明(多插件时不能共用一份)
	var gdext_by_target := {}
	for tgt in names:
		gdext_by_target[String(tgt)] = _find_gdextension_for(String(tgt), String(outputs.get(tgt, "")), info)
	_host._log("已锁定(CMake 推导): ", source_dir, " 目标: ", ", ".join(PackedStringArray(names)))
	for tg in targets:
		_host._log("预期产物(%s,%s.%s): %s" % [String(tg.get("target")), String(tg.get("type")),
				String(tg.get("arch")), String(tg.get("artifact"))])
	return {"source": source_dir, "targets": targets, "info": info,
			"gdext": gdext_by_target.get(names[0], ""), "gdext_by_target": gdext_by_target}

## 由 CMake 信息推导指定构建类型/架构的预期产物: {file(文件名), res(res://落点), abs(绝对路径)}。
func _expected_artifact(info: Dictionary, type: String, arch := "", out_dir := "", tgt := "") -> Dictionary:
	var out_dirs: Array = info.get("out_dirs", [])
	var target := tgt if tgt != "" else String(info.get("target", ""))
	var dir := out_dir
	if dir == "" and not out_dirs.is_empty():
		dir = String(out_dirs[0])
	if dir == "" or target == "":
		return {}
	var file := _canonical_file(target, type, arch)
	return {"file": file, "res": _abs_to_res(dir).path_join(file), "abs": String(dir).path_join(file)}

## 本轮要构建的架构列表: 本机架构恒在; macOS 额外补齐 *.gdextension 声明中缺失的架构
func _plan_archs(gdext_res: String) -> Array[String]:
	var host := _arch()
	var archs: Array[String] = [host]
	if not _host._opt(KEY_CROSS_ARCHS, true):
		return archs
	if _os_label() != "macos":
		var missing := _declared_missing_archs(gdext_res, host)
		if not missing.is_empty():
			_host._log("提示: 声明含跨架构产物(%s), 但交叉构建仅支持 macOS; 如需请在本平台手动构建。" % ", ".join(missing))
		return archs
	for a in _declared_missing_archs(gdext_res, host):
		archs.append(a)
		_host._log("声明需要跨架构产物, 将交叉构建(%s, 首次需全量编译 godot-cpp): lib 规范名架构 %s" % [a, a])
	return archs

## 从 *.gdextension 声明收集本平台"文件名内含架构且 ≠ host"的架构集合(去重、按声明顺序)
func _declared_missing_archs(gdext_res: String, host: String) -> Array[String]:
	var missing: Array[String] = []
	var re_arch := RegEx.new()
	re_arch.compile("\\.(arm64|x86_64|arm32|x86_32)\\.")
	for file in _gdext_keep_files(gdext_res):
		var m := re_arch.search(file)
		if m == null:
			continue
		var a := m.get_string(1)
		if a != host and not missing.has(a):
			missing.append(a)
	return missing

## 工具规范产物名: lib<名>.<平台>.<debug|release>.<架构>.<ext>
func _canonical_file(target: String, type: String, arch := "") -> String:
	var ext := ""
	match _os_label():
		"windows":
			ext = ".dll"
		"macos":
			ext = ".dylib"
		"linux":
			ext = ".so"
		_:
			return ""
	var a := arch if arch != "" else _arch()
	return "lib%s.%s.%s.%s%s" % [target, _os_label(), type, a, ext]

## CMake if/elseif 条件文本 → "平台.构建类型" 归档键(仅识别本工具支持的模板写法)
static func _cond_key(cond: String) -> String:
	var c := cond.replace(" ", "")
	var os := ""
	if c.contains("WIN32"):
		os = "windows"
	elif c.contains("NOTAPPLE") and c.contains("UNIX"):
		os = "linux"
	elif c.contains("APPLE"):
		os = "macos"
	if os == "":
		return ""
	var type := ""
	if c.contains("Debug"):
		type = "debug"
	elif c.contains("Release"):
		type = "release"
	if type == "":
		return ""
	return "%s.%s" % [os, type]

## 绝对路径 → res:// 路径(项目根内); 项目根外原样返回
func _abs_to_res(p: String) -> String:
	return FileTool.abs_to_res(p)

static func _is_ext_source(dir_path: String) -> bool:
	var has_build := FileAccess.file_exists(dir_path.path_join("CMakeLists.txt")) \
			or FileAccess.file_exists(dir_path.path_join("SConstruct"))
	var has_cpp := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path.path_join("godot-cpp")))
	return has_build and has_cpp

## 返回 {target, out_dirs(绝对), api_default, output_name(当前平台+类型)…
func _read_cmake_info(project_dir: String) -> Dictionary:
	var info := {target = "", out_dirs = [], api_default = "", output_name = "", output_names = {}}
	var cmake_path: String = _host._abs(project_dir).path_join("CMakeLists.txt")
	if not FileAccess.file_exists(cmake_path):
		return info
	var text := FileAccess.get_file_as_string(cmake_path)

	var re_target := RegEx.new()
	re_target.compile("add_library\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var m := re_target.search(text)
	if m:
		info.target = m.get_string(1)

	var re_out := RegEx.new()
	re_out.compile("(?:LIBRARY|RUNTIME|ARCHIVE)_OUTPUT_DIRECTORY\\s+([^\\s#)]+)")
	var out_set := {}
	for om in re_out.search_all(text):
		var raw: String = om.get_string(1).trim_prefix('"').trim_suffix('"')
		if raw.is_empty() or raw.contains("${CMAKE_CURRENT_BINARY_DIR}"):
			continue
		var expanded: String = raw.replace("${CMAKE_CURRENT_SOURCE_DIR}", _host._abs(project_dir))
		var normalized := _normalize_abs(expanded)
		if not normalized.is_empty() and not out_set.has(normalized):
			out_set[normalized] = true
			info.out_dirs.append(normalized)

	# 多 target(每个原生插件一个): 记录 target -> 输出目录。
	info.outputs = parse_target_outputs(text, _host._abs(project_dir))

	var re_api := RegEx.new()
	re_api.compile("set\\s*\\(\\s*GODOTCPP_API_VERSION\\s+(?:\"([0-9.]+)\"|([0-9.]+))")
	var am := re_api.search(text)
	if am:
		info.api_default = am.get_string(1) if am.get_string(1) != "" else am.get_string(2)

	# OUTPUT_NAME: 逐行跟踪 if/elseif/endif, 把各条件块里的值按 平台.构建类型 归档
	var re_if := RegEx.new()
	re_if.compile("^\\s*(?:else)?if\\s*\\(([^)]*)\\)")
	var re_endif := RegEx.new()
	re_endif.compile("^\\s*endif\\s*\\(")
	var re_name := RegEx.new()
	re_name.compile("OUTPUT_NAME\\s+\"?([A-Za-z0-9._-]+)\"?")
	var cond := ""
	var names := {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if re_endif.search(line) != null:
			cond = ""
			continue
		var im := re_if.search(line)
		if im != null:
			cond = im.get_string(1)
			continue
		if cond == "":
			continue
		var nm := re_name.search(line)
		if nm != null:
			var key := _cond_key(cond)
			if key != "":
				names[key] = nm.get_string(1)
	info.output_names = names
	var cur := "%s.%s" % [_os_label(), _build_type()]
	if names.has(cur):
		info.output_name = names[cur]
	return info

## 解析 CMakeLists 里每个 target 的输出目录: {target: 绝对路径}。
static func parse_target_outputs(text: String, cmake_dir_abs: String) -> Dictionary:
	var re_out := RegEx.new()
	# 排除右括号: 单行写法 `set_target_properties(X PROPERTIES…
	re_out.compile("(?:LIBRARY|RUNTIME|ARCHIVE)_OUTPUT_DIRECTORY\\s+([^\\s#)]+)")
	var re_addlib := RegEx.new()
	re_addlib.compile("add_library\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var outputs := {}
	var cur_tgt := ""
	for line in text.split("\n"):
		var lm := re_addlib.search(line)
		if lm != null:
			cur_tgt = lm.get_string(1)
			continue
		if cur_tgt == "":
			continue
		var om := re_out.search(line)
		if om == null:
			continue
		var raw: String = om.get_string(1).trim_prefix('"').trim_suffix('"')
		if raw.is_empty() or raw.contains("${CMAKE_CURRENT_BINARY_DIR}"):
			continue
		var nz := _normalize_abs(raw.replace("${CMAKE_CURRENT_SOURCE_DIR}", cmake_dir_abs))
		if not nz.is_empty():
			outputs[cur_tgt] = nz
	return outputs

## 规范化绝对路径(展开 .. 与 .), 支持 Windows "C:/..." 与 POSIX "/..."
static func _normalize_abs(path: String) -> String:
	path = path.replace("\\", "/")
	var is_win := path.length() > 2 and path[1] == ":"
	var drive := path.substr(0, 2) if is_win else ""
	var rest := path.substr(2) if is_win else path
	if not is_win and not rest.begins_with("/"):
		return ""
	var stack: Array[String] = []
	for p in rest.split("/"):
		if p == "..":
			if not stack.is_empty():
				stack.pop_back()
		elif p != "" and p != ".":
			stack.append(p)
	var joined := "/".join(stack)
	return ("%s/%s" % [drive, joined]) if is_win else ("/" + joined)

## 通用可执行文件定位 —— 跨平台、不写死用户名/机器路径。
static func _find_exe_dir(exe: String) -> String:
	var sub_paths := ["", "bin", "cmd", "usr/bin", "mingw64/bin", "ucrt64/bin"]
	var roots: Array[String] = []
	if OS.get_name() == "Windows":
		for k in ["MINGW_HOME", "W64DEVKIT_HOME", "MSYS2_ROOT", "MSYSTEM_PREFIX", "GIT_HOME"]:
			var v := OS.get_environment(k)
			if v != "":
				roots.append(v)
		for base in [OS.get_environment("USERPROFILE"), OS.get_environment("LOCALAPPDATA")]:
			if base == "":
				continue
			var d := DirAccess.open(base)
			if d:
				d.list_dir_begin()
				var e := d.get_next()
				while e != "":
					if d.current_is_dir() and _hint_hit(e.to_lower()):
						roots.append("%s/%s" % [base, e])
					e = d.get_next()
				d.list_dir_end()
			var scoop: String = String(base) + "/scoop/apps"
			var sd := DirAccess.open(scoop)
			if sd:
				sd.list_dir_begin()
				var e := sd.get_next()
				while e != "":
					if sd.current_is_dir() and _hint_hit(e.to_lower()):
						roots.append("%s/%s/current" % [scoop, e])
					e = sd.get_next()
				sd.list_dir_end()
		roots.append("C:/Program Files/Git")
		roots.append("C:/Program Files (x86)/Git")
		roots.append("C:/msys64")
		roots.append("C:/msys2")
	for root in roots:
		for sub in sub_paths:
			var dir := root if sub == "" else "%s/%s" % [root, sub]
			if FileAccess.file_exists("%s/%s" % [dir, exe]):
				return dir
	return ""

static func _hint_hit(low: String) -> bool:
	for h in ["w64devkit", "mingw", "msys", "gcc", "llvm", "git"]:
		if low.contains(h):
			return true
	return false

static func _engine_api_hint() -> String:
	var v := Engine.get_version_info()
	return "%d.%d" % [int(v.get("major", 4)), int(v.get("minor", 0))]

## CMake 默认直出名: 全平台 lib<名>.<ext>(CMake/MinGW 的 SHLIBPREFIX 默认就是 lib…
func _default_out_file(target: String) -> String:
	match _os_label():
		"windows":
			return "lib%s.dll" % target
		"macos":
			return "lib%s.dylib" % target
		"linux":
			return "lib%s.so" % target
		_:
			return ""

## 某个 target 自己的声明: 优先 <输出目录>/<target>.gdextension(多插件时唯一正确),
func _find_gdextension_for(target: String, out_dir: String, info: Dictionary) -> String:
	var dir := out_dir
	if dir == "":
		var ds: Array = info.get("out_dirs", [])
		if not ds.is_empty():
			dir = String(ds[0])
	if dir != "":
		var p := dir.path_join(target + ".gdextension")
		if FileAccess.file_exists(p):
			return _abs_to_res(p)
	return _find_gdextension(info)

## 在产物输出目录(*_OUTPUT_DIRECTORY)里定位 *.gdextension(与产物同目录是框架约定)。
func _find_gdextension(info: Dictionary) -> String:
	for d in info.get("out_dirs", []):
		var dir := DirAccess.open(String(d))
		if dir == null:
			continue
		dir.list_dir_begin()
		var e := dir.get_next()
		while e != "":
			if not dir.current_is_dir() and e.ends_with(".gdextension"):
				dir.list_dir_end()
				return _abs_to_res(String(d)).path_join(e)
			e = dir.get_next()
		dir.list_dir_end()
	return ""

## universal 产物名: lib<名>.macos.<debug|release>.universal.dylib(lipo…
func _universal_file(target: String, type: String) -> String:
	return "lib%s.macos.%s.universal.dylib" % [target, type]

## 从声明收集本平台键中的架构 tag 集合(去重; 无架构/仅 universal 键则返回空 —— 不需要架构文件保护)
func _declared_archs(gdext_res: String) -> Array[String]:
	var archs: Array[String] = []
	if gdext_res == "":
		return archs
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return archs
	var platform := _os_label()
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		var tags := key.split(".")
		if tags.is_empty() or tags[0] != platform:
			continue
		for t in tags:
			if GDEXT_ARCHS.has(t) and t != "universal" and not archs.has(t):
				archs.append(t)
	return archs

## 实盘扫描: 输出目录里"本目标"的动态库, 取 mtime 最新 ——
func _scan_dynamic_libs(dir_path: String, target_name: String, exclude: PackedStringArray) -> String:
	var best := ""
	var best_m := -1
	var excl := {}
	for k in exclude:
		excl[k] = true
	var ext := _default_out_file(target_name).get_extension()
	var dir := DirAccess.open(String(dir_path))
	if dir == null:
		return ""
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if not dir.current_is_dir():
			var low := e.to_lower()
			if ext != "" and low.ends_with("." + ext):
				if e.contains(".universal.") or e.begins_with("~") or not e.contains(target_name) or excl.has(e):
					e = dir.get_next()
					continue   # universal 合并产物/~ 残留/其他目标产物/已知命名 不参与实盘兜底
				var m := FileAccess.get_modified_time(String(dir_path).path_join(e))
				if m > best_m:
					best_m = m
					best = e
		e = dir.get_next()
	dir.list_dir_end()
	return best

## 解析 *.gdextension: 保留原始行; 抽取 [libraries] 段的 键→(行号, 值) 与段尾插入点。
func _gdext_parse(gdext_res: String) -> Dictionary:
	if not FileAccess.file_exists(gdext_res):
		return {}
	var re_kv := RegEx.new()
	re_kv.compile("^\\s*([A-Za-z0-9_.]+)\\s*=\\s*(.+?)\\s*$")
	var lines := FileAccess.get_file_as_string(gdext_res).split("\n")
	var sec := ""
	var lib_end := -1
	var entries: Array = []
	var values := {}
	for i in lines.size():
		var s := String(lines[i]).strip_edges()
		if s.begins_with("["):
			if sec == "libraries" and lib_end < 0:
				lib_end = i
			sec = s.trim_prefix("[").trim_suffix("]").strip_edges()
			continue
		if sec != "libraries":
			continue
		var m := re_kv.search(String(lines[i]))
		if m == null:
			continue
		var key := m.get_string(1)
		entries.append({"key": key, "line": i})
		values[key] = m.get_string(2).trim_prefix("\"").trim_suffix("\"")
		lib_end = i + 1
	if lib_end < 0:
		lib_end = lines.size()
	return {"lines": lines, "entries": entries, "values": values, "lib_end": lib_end}

## 声明键是否属于"本平台 + 本构建类型": 首 tag = 平台, 且键无任何类型 tag(通用键)或含目标类型。
static func _gdext_key_matches(key: String, platform: String, type: String, arch: String) -> bool:
	var tags := key.split(".")
	if tags.is_empty() or tags[0] != platform:
		return false
	var has_type := false
	var arch_tags: Array[String] = []
	for t in tags:
		if GDEXT_TYPES.has(t):
			has_type = true
		elif GDEXT_ARCHS.has(t):
			arch_tags.append(t)
	if has_type and not tags.has(type):
		return false
	# 架构校验: 键含架构 tag → 必须与产物架构一致(杜绝 arm64 键被 x86_64 产物覆盖);
	if not arch_tags.is_empty():
		return arch_tags.has(arch)
	return true

## 从规范名/声明值文件名中提取架构 tag(无架构段返回 "")
static func _file_arch(file: String) -> String:
	var re := RegEx.new()
	re.compile("\\.(arm64|x86_64|arm32|x86_32|universal)\\.")
	var m := re.search(file)
	return m.get_string(1) if m != null else ""

## 清理白名单: [libraries] 全部键声明的文件名 —— 声明里没出现的库即规格外残留。
func _gdext_keep_files(gdext_res: String) -> PackedStringArray:
	var keep := PackedStringArray()
	if gdext_res == "":
		return keep
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return keep
	for ent in parsed["entries"]:
		keep.append(String(parsed["values"].get(String(ent.get("key")), "")).get_file())
	return keep

func _os_label() -> String:
	match OS.get_name():
		"Windows": return "windows"
		"macOS", "OSX": return "macos"
		"Linux": return "linux"
		_: return OS.get_name().to_lower()

## 本机架构名(构建缓存目录隔离用; universal 编辑器二进制用 uname 探测真实运行架构)
func _arch() -> String:
	var arch := Engine.get_architecture_name().to_lower()
	if arch != "universal":
		return arch
	# universal 二进制无法从引擎 API 得知真实运行架构: 在 Apple Silicon 上归一为 x86_64
	if OS.get_name() == "macOS":
		var out: Array = []
		if OS.execute("uname", PackedStringArray(["-m"]), out) == 0 and not out.is_empty():
			var host := String(out[0]).strip_edges().to_lower()
			if host == "arm64" or host == "x86_64":
				return host
	return "x86_64"

func _build_type() -> String:
	return "debug" if OS.is_debug_build() else "release"

## 本次要构建的构建类型清单(配置驱动)。
func _plan_build_types() -> Array[String]:
	var cfg: Array = ProjectSettings.get_setting(KEY_BUILD_TYPES, [])
	var out: Array[String] = []
	for t in cfg:
		var s := String(t).to_lower()
		if (s == "debug" or s == "release") and not out.has(s):
			out.append(s)
	if out.is_empty():
		# 统一规则: 一律 release —— 与"哪个项目触发构建"无关。
		out = ["release"]
	_host._build_types = out
	_host._log("构建类型清单: ", " ".join(out))
	return out
