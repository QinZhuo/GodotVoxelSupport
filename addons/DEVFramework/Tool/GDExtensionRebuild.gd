@tool
class_name GDExtensionRebuild
extends EditorScript

## 通用 GDExtension 一键构建工具 —— 零配置、零移动，支持任何遵循 godot-cpp 生态约定的扩展。
##
## 自动出现在 项目 → 工具 → EditorScript（EditorScriptMenuTool 扫描注册）。
## 一次运行自动完成: 发现扩展工程 → 读 CMakeLists 与 *.gdextension 分辨"如何构建/产物去哪"
## → CMake 配置(必要时)/异步编译(不卡编辑器, 实时回显) → 产物按规格改名部署。
##
## 三条"事实源", 不猜:
##   1) CMakeCache.txt(已配置过): 生成器/编译器/API 全以缓存为准, 只 cmake --build;
##   2) CMakeLists.txt(无缓存需配置时): 只扫三个高可信 token ——
##        add_library(<name> SHARED)          认产物名(替代模糊找库)
##        *_OUTPUT_DIRECTORY = <字面路径>     产物直出目录(加为搜索根)
##        set(GODOTCPP_API_VERSION "x.y")     有默认则不再传 -D(尊重工程钉的绑定版本)
##      其余(条件/生成器/编译器)交给 cmake 自身, 不做 CMake 语义解释;
##   3) *.gdextension [libraries]: 当前 平台.类型[.架构] 键 = 产物最终文件名与落点(部署规格)。
##
## 其余自动判定: 源码目录(唯一工程根 res://gdextension, 多个 addons 候选按规格配对);
## 构建类型 debug/release 跟随当前编辑器; 生成器探测 ninja 否则交给 cmake。
## 缓存纪律: 一切中间产物/CMake 缓存统一放 res://.godot/gdextension_build/(引擎自带全局忽略),
## 不进入工程目录; 部署后按规格 [libraries] 白名单清理 Native —— 只保留各平台/类型/架构键声明的
## 必要产物, 清掉无后缀原始/导入库(.a)与规格外历史库及临时残留(~*/TMP), 工程内只留必要文件。
## 自动闭环(可用 ProjectSettings 布尔开关关闭, 均默认开):
##   dev_framework/gdextension_build/auto_update_submodule  godot-cpp 对齐, 但"永不全量重建"为最高约束:
##     本地有可编译绑定快照(钉版或引擎回退) → 完全跳过(无网络、不切版本); 仅本地完全无快照才一次性对齐。
##   dev_framework/gdextension_build/auto_reload_editor      构建+部署成功后自动 重载当前项目 使新扩展生效。
## 增量保证: 首装(或配置被换清)后的所有构建都是纯增量 —— 不因上游分支漂移/tag 更新反复重编;
## 唯一可能的全量 = 首次构建 or 本地彻底无绑定快照时的一次性对齐(之后回归纯增量)。
## 编辑器内自动显示: 完成/失败时自动弹引擎顶部 Toaster 提示(Godot 4.3+ 顶部非模态小条);
## 过程输出实时回显 Output 面板并镜像到 res://.godot/gdextension_build/build.log,
## 阶段/进度(state.txt)与最终摘要(last_build.txt)同步落盘 —— 全程零手动查询。
## 通用性: 工具链与 git 均按 环境变量→PATH→常见约定目录扫描 定位, 不写死任何机器/用户路径, 跨项目跨平台。
## 已知边界(引擎层面): 编辑器只在启动时加载扩展; Windows 上编辑器锁住正在加载的 dll 会致覆盖失败,
## 工具会打印手动复制指引。发布由 CI 负责(本工具仅本机迭代)。

const KEY_UPDATE_SUBMODULE := "dev_framework/gdextension_build/auto_update_submodule"
const KEY_RELOAD_EDITOR := "dev_framework/gdextension_build/auto_reload_editor"

static var _me: GDExtensionRebuild   # 异步构建期间持有自身(菜单调用方不持有实例)

var _lines: Array[String] = []
var _cache_dirty := false   # submodule 检出变化 → 构建缓存作废, 需重新配置
var _start_ms := 0
var _last_progress := ""    # 最近一次解析到的 [k/N] 编译进度


func _run() -> void:
	_me = self
	_start_ms = Time.get_ticks_msec()
	var cache_dir := _abs("res://.godot/gdextension_build")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	_state_write("构建进行中: 定位扩展…")
	_log("━━━━ GDExtension 一键构建 ━━━━")
	var loc := _locate()
	if loc.is_empty():
		return _finish()
	var source_dir: String = loc.get("source")
	var ext_file: String = loc.get("extension")
	var target_res := _parse_library_target(ext_file)
	if target_res.is_empty():
		return _finish()
	_log("源码工程: ", source_dir)
	_log("规格文件: ", ext_file)
	_log("本机产物落点: ", target_res)

	if not _precheck(source_dir):
		return _finish_with("定位/工具链失败")
	# 编译器 PATH 引导: 编辑器进程常不带 MinGW, 探测常见安装并注入本次进程环境
	_ensure_toolchain_env()
	# 自动同步 godot-cpp(仅当本地缺少所需绑定快照时才走网络, 避免每次拉取/全量重建)
	if _opt(KEY_UPDATE_SUBMODULE, true):
		_state_write("构建进行中: 同步 godot-cpp…")
		await _sync_godot_cpp(source_dir)
	var build_dir := _pick_build_dir(source_dir)
	if build_dir.is_empty():
		return _finish()
	var info := _read_cmake_info(source_dir, build_dir)
	_state_write("构建进行中: 配置 CMake…")
	if not _ready_build_dir(build_dir, source_dir, info):
		return _finish_with("CMake 配置失败")
	var ok := await _build(build_dir)
	if not ok:
		return _finish_with("编译失败(查看 build.log)")
	_deploy(build_dir, ext_file, target_res, info)
	var elapsed := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var summary := "构建成功(用时 %.1fs)\n产物: %s\n日志: res://.godot/gdextension_build/build.log" % [elapsed, target_res]
	if _opt(KEY_RELOAD_EDITOR, true):
		summary += "\n下一步: 2 秒后自动重载当前项目。"
	else:
		summary += "\n下一步: 项目→重新加载当前项目 生效。"
	_summary_write(summary)
	_state_write("构建完成(用时 %.1fs)" % elapsed)
	_log("构建完成。")
	_toast("GDExtension 构建成功(用时 %.1fs)" % elapsed)
	if _opt(KEY_RELOAD_EDITOR, true):
		_log("2 秒后自动重载当前项目使新扩展生效……")
		await _restart_editor()
	else:
		_log("需 项目→重新加载当前项目 生效(引擎启动时才加载扩展)。")
	_finish()


## 提前失败收尾: 记录摘要与状态, 并弹编辑器提示
func _finish_with(result: String) -> void:
	_summary_write("%s\n日志: res://.godot/gdextension_build/build.log\n修复后再次运行即可重试。" % result)
	_state_write(result)
	_toast("GDExtension 构建失败: " + result)
	_finish()


# ------------------------------------------------------------ 零配置定位

## 源码目录: res://gdextension 唯一工程根; 多个 addons 候选时按规格文件归属配对
func _locate() -> Dictionary:
	var dirs := discover_source_dirs()
	if dirs.is_empty():
		_log("未发现 GDExtension 工程。请确认 res://gdextension(或 addons/*/) 含 CMakeLists.txt + godot-cpp/ submodule。")
		return {}
	var ext_order: Array[String] = []
	var seen := {}
	for d in dirs:
		for e in find_extension_files(d):
			if not seen.has(e):
				seen[e] = true
				ext_order.append(e)
	if ext_order.is_empty():
		_log("未找到 *.gdextension 规格文件(常见位置: addons/**/Native、addons/**、bin)。")
		return {}
	var want := "%s.%s.%s" % [_os_label(), _build_type(), _arch()]
	var want_short := "%s.%s" % [_os_label(), _build_type()]
	var runnable: Array[String] = []
	for e in ext_order:
		var keys := _parse_library_keys(e)
		if keys.has(want) or keys.has(want_short):
			runnable.append(e)
	var pool: Array[String] = runnable if not runnable.is_empty() else ext_order
	var ext_file: String = pool[0]
	var newest := -1.0
	for e in pool:
		var m := FileAccess.get_modified_time(e)
		if m > newest:
			newest = m
			ext_file = e
	var source_dir: String = dirs[0]
	if dirs.size() > 1:
		var by_ext := _source_matching_addon(ext_file, dirs)
		if by_ext != "":
			source_dir = by_ext
		else:
			_log("多个工程目录且无法判定归属, 默认取: ", source_dir)
			for d in dirs:
				_log("    - 候选: ", d)
	if dirs.size() > 1 or ext_order.size() > 1:
		_log("已选择: ", source_dir, " + ", ext_file)
		if not runnable.is_empty() and runnable.size() < ext_order.size():
			_log("其余规格无本机(", want, ")条目, 已忽略。")
	return {"source": source_dir, "extension": ext_file}


## 规格文件位于某个"同样是工程候选"的 addons 目录下时, 判定归属
static func _source_matching_addon(ext_file: String, dirs: Array) -> String:
	var parts := ext_file.split("/", false)
	if parts.size() >= 3 and parts[1] == "addons":
		var addon_dir := "res://addons/%s" % parts[2]
		for d in dirs:
			if d == addon_dir:
				return d
	return ""


## 自动发现工程目录候选(静态, 供外部/MCP 复用): 项目根 gdextension/ + 各 addons/*/
static func discover_source_dirs() -> Array[String]:
	var out: Array[String] = []
	if _is_ext_source("res://gdextension"):
		out.append("res://gdextension")
	var addons := DirAccess.open("res://addons")
	if addons:
		addons.list_dir_begin()
		var entry := addons.get_next()
		while entry != "":
			if addons.current_is_dir() and not entry.begins_with("."):
				var cand := "res://addons/%s" % entry
				if _is_ext_source(cand):
					out.append(cand)
			entry = addons.get_next()
		addons.list_dir_end()
	return out


static func _is_ext_source(dir_path: String) -> bool:
	var has_build := FileAccess.file_exists(dir_path.path_join("CMakeLists.txt")) \
			or FileAccess.file_exists(dir_path.path_join("SConstruct"))
	var has_cpp := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path.path_join("godot-cpp")))
	return has_build and has_cpp


## 自动收集 *.gdextension(静态, 供外部/MCP 复用): 工程目录内/bin + addons/**/Native + addons/**
static func find_extension_files(source_dir: String) -> Array[String]:
	var found: Array[String] = []
	var seen := {}
	for probe in [source_dir, source_dir.path_join("bin")]:
		_collect_ext(probe, found, seen, 0)
	_collect_ext("res://addons", found, seen, 3)
	found.sort()
	return found


static func _collect_ext(dir_path: String, out: Array[String], seen: Dictionary, depth: int) -> void:
	if depth < 0 or seen.has(dir_path):
		return
	seen[dir_path] = true
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if depth > 0:
				_collect_ext(full, out, seen, depth - 1)
			elif entry in ["Native", "bin"]:
				_collect_ext(full, out, seen, 1)
		elif entry.ends_with(".gdextension"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## 解析 [libraries] 中当前 平台.类型[.架构] 键 → res:// 落点; 键缺失给出清单
func _parse_library_target(ext_file: String) -> String:
	var keys := _parse_library_keys(ext_file)
	var want := "%s.%s.%s" % [_os_label(), _build_type(), _arch()]
	var want_short := "%s.%s" % [_os_label(), _build_type()]
	for try_key in [want, want_short]:
		if keys.has(try_key):
			return keys[try_key]
	_log("规格文件中缺少本机条目 ", want, "(或 ", want_short, "), 现有条目:")
	for k in keys:
		_log("    - ", k, " = ", keys[k])
	return ""


## 解析 .gdextension 的 [libraries] 段(静态, 供外部/MCP 复用)
static func _parse_library_keys(ext_file: String) -> Dictionary:
	var keys := {}
	var f := FileAccess.open(ext_file, FileAccess.READ)
	if f == null:
		return keys
	var in_libraries := false
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("["):
			in_libraries = line.to_lower().begins_with("[libraries]")
			continue
		if not in_libraries or line == "" or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var val := line.substr(eq + 1).strip_edges().trim_prefix('"').trim_suffix('"')
		if key != "" and val != "":
			keys[key] = val
	f.close()
	return keys


# ------------------------------------------------------------ 读 CMakeLists 分辨"如何构建"(三个高可信 token)

## 返回 {target, out_dirs(绝对), api_default}。不解释 CMake 语义, 只扫模板级高可信写法;
## 扫不到任何 token 也不报错 —— 交由缓存/默认/模糊找库兜底。
func _read_cmake_info(project_dir: String, build_dir: String) -> Dictionary:
	var info := {target = "", out_dirs = [], api_default = ""}
	var cmake_path := _abs(project_dir).path_join("CMakeLists.txt")
	if not FileAccess.file_exists(cmake_path):
		return info
	var text := FileAccess.get_file_as_string(cmake_path)

	var re_target := RegEx.new()
	re_target.compile("add_library\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var m := re_target.search(text)
	if m:
		info.target = m.get_string(1)

	var re_out := RegEx.new()
	re_out.compile("(?:LIBRARY|RUNTIME|ARCHIVE)_OUTPUT_DIRECTORY\\s+([^\\s#]+)")
	var out_set := {}
	for om in re_out.search_all(text):
		var raw: String = om.get_string(1).trim_prefix('"').trim_suffix('"')
		if raw.is_empty() or raw.contains("${CMAKE_CURRENT_BINARY_DIR}"):
			continue
		var expanded := raw.replace("${CMAKE_CURRENT_SOURCE_DIR}", _abs(project_dir))
		var normalized := _normalize_abs(expanded)
		if not normalized.is_empty() and not out_set.has(normalized):
			out_set[normalized] = true
			info.out_dirs.append(normalized)

	var re_api := RegEx.new()
	re_api.compile("set\\s*\\(\\s*GODOTCPP_API_VERSION\\s+(?:\"([0-9.]+)\"|([0-9.]+))")
	var am := re_api.search(text)
	if am:
		info.api_default = am.get_string(1) if am.get_string(1) != "" else am.get_string(2)
	return info


## 规范化绝对路径(展开 .. 与 .), 支持 Windows "C:/..." 与 POSIX "/..."
func _normalize_abs(path: String) -> String:
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


# ------------------------------------------------------------ 工具链探测与构建目录

func _which(prog: String) -> bool:
	var out: Array = []
	return OS.execute(prog, ["--version"], out) == 0


## Windows: PATH 无 g++ 时, 按通用约定(环境变量→用户目录/常见根扫描)定位并注入本次进程 PATH
func _ensure_toolchain_env() -> void:
	if OS.get_name() != "Windows":
		return
	if _which("g++"):
		return
	var bin_dir := _find_exe_dir("g++.exe")
	if bin_dir == "":
		_log("PATH 中无 g++, 也未发现常见 MinGW/w64devkit。可设环境变量 MINGW_HOME/W64DEVKIT_HOME 指向工具根目录, 或安装 w64devkit。")
		return
	OS.set_environment("PATH", "%s;%s" % [bin_dir, OS.get_environment("PATH")])
	_log("已把 MinGW 加入本次构建 PATH: ", bin_dir)


## 通用可执行文件定位 —— 跨平台、不写死用户名/机器路径:
##   1) 环境变量目录(MINGW_HOME/W64DEVKIT_HOME/MSYS2_ROOT/GIT_HOME 等);
##   2) 用户主目录与 LOCALAPPDATA 下按名命中的目录 + scoop/apps 包目录;
##   3) 各平台常见安装根(Program Files、C:/msys64、C:/msys2)。
## 返回"包含 exe 的 bin 目录", 找不到返回 ""。
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

func _precheck(source_dir: String) -> bool:
	var abs := _abs(source_dir)
	if not FileAccess.file_exists(abs.path_join("CMakeLists.txt")):
		_log("该扩展暂仅支持 CMake 构建(未找到 CMakeLists.txt)。")
		return false
	if not FileAccess.file_exists(abs.path_join("godot-cpp/SConstruct")):
		_log("godot-cpp submodule 未初始化, 请先执行:")
		_log("    git submodule update --init --recursive")
		return false
	var out: Array = []
	if OS.execute("cmake", ["--version"], out, true) != 0:
		_log("未找到 cmake, 请安装并加入 PATH(Windows 便携版可参考 w64devkit)。")
		return false
	var ver: String = (out[0] if not out.is_empty() else "").strip_edges().split("\n")[0]
	_log("cmake: ", ver)
	return true


# ------------------------------------------------------------ godot-cpp 自动同步(对齐当前引擎版本)

static var _git_path := ""   # 已探测到的 git 可执行文件缓存(""=未探测)

## 定位 git: PATH 未必有 → 走通用探测(_find_exe_dir), 仍无则按 PATH 名兜底。静态(供解析器复用)
static func _git_exe() -> String:
	if _git_path == "":
		var dir := _find_exe_dir("git.exe")
		var cand := "%s/git.exe" % dir if dir != "" else ""
		var list: Array[String] = []
		if cand != "":
			list.append(cand)
		list.append("git")
		for c in list:
			var out: Array = []
			if OS.execute(c, ["--version"], out) == 0:
				_git_path = c
				return c
		_git_path = "git"   # 兜底按 PATH 名, 失败由调用方告警处理
	return _git_path


static func _git_exec(args: PackedStringArray, out: Array = []) -> int:
	return OS.execute(_git_exe(), args, out)


## 把 godot-cpp submodule 与当前引擎对齐 —— 但以"永不全量重建"为最高约束:
##   唯一原则: 本地存在任何可编译的绑定快照(钉版或引擎回退) → 直接跳过(无网络、不切版本、不重建);
##   只有本地完全无可用快照(钉版异常/引擎远新于上游) 才解析并一次性对齐, 对齐后即永久回到纯增量。
## 不因上游分支漂移而反复重编: 上游无匹配 tag 时回退其默认分支 HEAD 仅发生在那"一次性"里。
## 任何 git 失败都不中断构建 —— 打印告警并沿用现有 submodule。
func _sync_godot_cpp(source_dir: String) -> void:
	var vi: Dictionary = Engine.get_version_info()
	var engine_api := "%d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 0))]
	var def_api := _cmake_api_default(source_dir)
	# 核心原则 —— 只要有"可编译"的本地快照(CMakeLists 钉版, 或引擎回退版), 就绝不动 submodule:
	# 不产生网络、不切换版本、不触碰构建缓存 ⇒ 首装成功后的所有后续构建都是纯增量。
	if def_api != "" and _has_snapshot(source_dir, def_api):
		_log("godot-cpp 钉版快照已在本地(默认 ", def_api, "), 无需同步 —— 纯增量。")
		return
	if _api_version_to_pass(source_dir, def_api) != "":
		_log("godot-cpp 本地有可用回退快照(引擎 ", engine_api, " 无对应钉版), 无需同步 —— 纯增量。")
		return
	_log("godot-cpp 本地无任何可用绑定快照(仓库钉版异常/引擎过新), 一次性对齐引擎 ", engine_api, " ……")
	var gcpp := _abs(source_dir).path_join("godot-cpp")
	var out: Array = []
	if OS.execute(_git_exe(), ["-C", gcpp, "rev-parse", "--is-inside-work-tree"], out) != 0:
		_log("godot-cpp 不是 git 工作树, 跳过自动更新。")
		return
	var want := _resolve_godot_cpp_ref(gcpp, engine_api)
	if want.is_empty():
		_log("无法解析 godot-cpp 对应版本(网络不可达?), 沿用当前 submodule。")
		return
	var head: Array = []
	if OS.execute(_git_exe(), ["-C", gcpp, "rev-parse", "HEAD"], head) != 0:
		return
	var current := String(head[0]).strip_edges()
	if current == String(want.get("sha")):
		_log("godot-cpp 已是最新(", want.get("name"), ")。")
		return
	_log("检出 godot-cpp: ", current.substr(0, 8), " → ", want.get("name"))
	var fetch: Array = []
	var ok := false
	if String(want.get("kind")) == "tag":
		ok = OS.execute(_git_exe(), ["-C", gcpp, "fetch", "origin", "tag", String(want.get("name"))], fetch) == 0
	else:
		ok = OS.execute(_git_exe(), ["-C", gcpp, "fetch", "origin", String(want.get("name"))], fetch) == 0
	_print_out(fetch)
	if not ok:
		_log("fetch 失败, 沿用当前 submodule。")
		return
	var co: Array = []
	ok = OS.execute(_git_exe(), ["-C", gcpp, "checkout", "--detach", String(want.get("sha"))], co) == 0
	_print_out(co)
	if ok:
		_cache_dirty = true
		_log("godot-cpp 已更新, 将重建构建缓存。")
	else:
		_log("checkout 失败, 沿用当前 submodule。")


## 解析 godot-cpp 应检出的引用(静态可测, 只 ls-remote, 不改动工作树)。
## tag 命名如 godot-4.7-stable / godot-4.4.1-stable(patch 为 0 时省略); 取"主次版本与引擎一致"的最新 tag,
## 无匹配(如上游尚无 4.7 tag)则回退默认分支 HEAD —— 其携带最新引擎 API, 避免错配旧版。
static func _resolve_godot_cpp_ref(godot_cpp_abs: String, engine_version: String) -> Dictionary:
	var tags: Array = []
	if OS.execute(_git_exe(), ["-C", godot_cpp_abs, "ls-remote", "--tags", "origin"], tags) != 0:
		return {}
	var ev := engine_version.split(".")
	var e_major := int(ev[0]) if ev.size() > 0 else 4
	var e_minor := int(ev[1]) if ev.size() > 1 else 0
	var best_base := ""
	var best_sha := ""
	var best_key := Vector2i(-1, -1)
	var tag_re := RegEx.new()
	tag_re.compile("^([0-9a-f]{40})\\s+refs/tags/godot-([0-9]+)\\.([0-9]+)(?:\\.([0-9]+))?-stable$")
	for line in tags:
		var m := tag_re.search(String(line).strip_edges())
		if not m:
			continue
		var t_major := int(m.get_string(2))
		var t_minor := int(m.get_string(3))
		var t_patch := int(m.get_string(4)) if m.get_string(4) != "" else 0
		# 精确匹配引擎次版本(4.7 → 只认 4.7 系 tag), 无则整体回退默认分支, 避免错配旧版
		if t_major != e_major or t_minor != e_minor:
			continue
		if t_patch > best_key.y:
			best_key = Vector2i(t_minor, t_patch)
			best_sha = m.get_string(1)
			best_base = "%d.%d" % [t_major, t_minor] if t_patch == 0 else "%d.%d.%d" % [t_major, t_minor, t_patch]
	if best_base != "":
		return {name = "godot-%s-stable" % best_base, sha = best_sha, kind = "tag"}
	# 上游无 ≤ 引擎的 tag → 用默认分支 HEAD(godot-cpp 默认分支携带最新引擎 API)
	var head: Array = []
	if OS.execute(_git_exe(), ["-C", godot_cpp_abs, "ls-remote", "--symref", "origin", "HEAD"], head) != 0 or head.is_empty():
		return {}
	var branch := ""
	var sha := ""
	for line in head:
		var s := String(line)
		if s.begins_with("ref:"):
			var idx := s.find("refs/heads/")
			if idx >= 0:
				var tail := s.substr(idx + "refs/heads/".length())
				branch = tail.split("\t")[0].strip_edges()
		elif sha == "":
			sha = s.split("\t")[0].strip_edges()
	if branch == "" or sha == "":
		return {}
	return {name = "origin/" + branch, sha = sha, kind = "branch"}


func _restart_editor() -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(2.0).timeout
	if get_editor_interface() != null:
		get_editor_interface().restart_editor(true)


## 递归清空目录(作废缓存用)
func _wipe_dir(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			if d.current_is_dir():
				_wipe_dir(dir_path.path_join(entry))
				d.remove(entry)
			else:
				d.remove(entry)
		entry = d.get_next()
	d.list_dir_end()


func _opt(key: String, def_val: bool) -> bool:
	return bool(ProjectSettings.get_setting(key, def_val))


## 构建缓存统一放 res://.godot/gdextension_build/(引擎自带全局忽略, 不入库、不污染工程)。
## 复用已有缓存(优先名称含当前 平台+构建类型 者, 再取最新); 没有则新建 <源>-<os>-<arch>-<类型>。
func _pick_build_dir(source_dir: String) -> String:
	var cache_root := _abs("res://.godot/gdextension_build")
	var token := _os_token()
	var type := _build_type()
	var cached: Array[String] = []
	var cached_ok: Array[String] = []
	var cdir := DirAccess.open(cache_root)
	if cdir:
		cdir.list_dir_begin()
		var entry := cdir.get_next()
		while entry != "":
			if cdir.current_is_dir():
				var full := cache_root.path_join(entry)
				if FileAccess.file_exists(full.path_join("CMakeCache.txt")):
					cached.append(full)
					var low := entry.to_lower()
					if low.contains(token) and low.contains(type):
						cached_ok.append(full)
			entry = cdir.get_next()
		cdir.list_dir_end()
	if not cached_ok.is_empty():
		return _newest_cache(cached_ok)
	if not cached.is_empty():
		return _newest_cache(cached)
	var fresh := cache_root.path_join("%s-%s-%s-%s" % [source_dir.get_file(), _os_label(), _arch(), type])
	_log("未发现已配置构建缓存, 将新建: ", fresh)
	return fresh


static func _newest_cache(dirs: Array) -> String:
	var best := String(dirs[0])
	var t := -1.0
	for d in dirs:
		var m := FileAccess.get_modified_time(String(d).path_join("CMakeCache.txt"))
		if m > t:
			t = m
			best = String(d)
	return best


func _ready_build_dir(build_dir: String, source_dir: String, info: Dictionary) -> bool:
	if _cache_dirty and FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_log("submodule 已更新, 作废旧构建缓存: ", build_dir)
		_wipe_dir(build_dir)
	if FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_log("复用构建目录(以缓存配置为准): ", build_dir)
		return true
	var src_abs := _abs(source_dir)
	DirAccess.make_dir_recursive_absolute(build_dir)
	var args: PackedStringArray = ["-S", src_abs, "-B", build_dir]
	var generator := _detect_generator()
	if generator != "":
		args.append_array(["-G", generator])
	# API 版本: CMakeLists 默认值对应的绑定快照存在则尊重(不传 -D);
	# 否则在 godot-cpp 本地快照里选"≤ 引擎版本"的最新可用(避免默认 4.7 但无 4-7 快照导致失败)
	var api := _api_version_to_pass(source_dir, String(info.get("api_default", "")))
	if api != "":
		args.append("-DGODOTCPP_API_VERSION=%s" % api)
	args.append("-DCMAKE_BUILD_TYPE=%s" % _build_type_cap())
	_log("配置 CMake: ", " ".join(args))
	var out: Array = []
	var code := OS.execute("cmake", args, out, true)
	_print_out(out)
	if code != 0:
		_log("cmake 配置失败(退出码 %d)。Windows 常见原因: MinGW 未在 PATH, 或用 MSVC 但编辑器非从 vcvars 环境启动。" % code)
		_wipe_dir(build_dir)   # 清掉失败残留缓存, 下次重新配置
		return false
	return true


## 决定 GODOTCPP_API_VERSION 是否传 -D 及传什么:
##   - CMakeLists 默认值对应的绑定快照存在 → ""(不传, 尊重工程钉版)
##   - 否则在 godot-cpp 本地 extension_api-*.json 快照里, 取主次版本 ≤ 引擎 的最新可用
##   - 本地全无 → ""(交给 cmake, 会给出缺文件报错)
func _api_version_to_pass(source_dir: String, api_default: String) -> String:
	var gext_dir := _abs(source_dir).path_join("godot-cpp/gdextension")
	if api_default != "" and FileAccess.file_exists(_api_file(gext_dir, api_default)):
		return ""
	var vi: Dictionary = Engine.get_version_info()
	var e_major := int(vi.get("major", 4))
	var e_minor := int(vi.get("minor", 0))
	var best := ""
	var best_key := Vector2i(-1, -1)
	var re := RegEx.new()
	re.compile("^extension_api-(\\d+)-(\\d+)\\.json$")
	var dir := DirAccess.open(gext_dir)
	if dir:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			var m := re.search(entry)
			if m:
				var mj := int(m.get_string(1))
				var mn := int(m.get_string(2))
				if mj == e_major and mn <= e_minor and Vector2i(mj, mn) > best_key:
					best_key = Vector2i(mj, mn)
					best = "%d.%d" % [mj, mn]
			entry = dir.get_next()
		dir.list_dir_end()
	return best


func _api_file(gext_dir: String, api: String) -> String:
	return gext_dir.path_join("extension_api-%s.json" % api.replace(".", "-"))


## CMakeLists 里钉的 GODOTCPP_API_VERSION 默认值(无则 "")
func _cmake_api_default(source_dir: String) -> String:
	var p := _abs(source_dir).path_join("CMakeLists.txt")
	if not FileAccess.file_exists(p):
		return ""
	var re := RegEx.new()
	re.compile("set\\s*\\(\\s*GODOTCPP_API_VERSION\\s+(?:\"([0-9.]+)\"|([0-9.]+))")
	var m := re.search(FileAccess.get_file_as_string(p))
	if m == null:
		return ""
	return m.get_string(1) if m.get_string(1) != "" else m.get_string(2)


## godot-cpp 本地是否已有某 API 版本的绑定快照
func _has_snapshot(source_dir: String, api: String) -> bool:
	if api == "":
		return false
	return FileAccess.file_exists(_api_file(_abs(source_dir).path_join("godot-cpp/gdextension"), api))


func _detect_generator() -> String:
	var out: Array = []
	return "Ninja" if OS.execute("ninja", ["--version"], out) == 0 else ""


# ------------------------------------------------------------ 异步构建

func _build(build_dir: String) -> bool:
	var type := _build_type()
	_log("开始编译 (", type, ")…… 编辑器保持可用, 输出实时回显。")
	var args := ["--build", build_dir, "--config", type.capitalize()]
	var pipe: Dictionary = OS.execute_with_pipe("cmake", PackedStringArray(args), false)
	var pid: int = int(pipe.get("pid", 0))
	var stdout: Variant = pipe.get("stdout")
	var stderr: Variant = pipe.get("stderr")
	if pid <= 0:
		_log("execute_with_pipe 不可用, 退化为阻塞执行(编辑器会卡住直到完成)。")
		var out: Array = []
		var code := OS.execute("cmake", PackedStringArray(args), out, true)
		_print_out(out)
		return code == 0
	var tree := Engine.get_main_loop() as SceneTree
	while OS.is_process_running(pid):
		_drain(stdout)
		_drain(stderr)
		await tree.create_timer(0.2).timeout
	_drain(stdout)
	_drain(stderr)
	var exit_code := OS.get_process_exit_code(pid)
	if stdout is FileAccess:
		(stdout as FileAccess).close()
	if stderr is FileAccess:
		(stderr as FileAccess).close()
	if exit_code == 0:
		_log("编译成功。")
	else:
		_log("编译失败(退出码 %d), 请按上方报错定位。" % exit_code)
	return exit_code == 0


func _drain(pipe) -> void:
	if pipe == null or not (pipe is FileAccess):
		return
	var fa := pipe as FileAccess
	if fa.get_length() <= fa.get_position():
		return
	var text := fa.get_as_text()
	if text != "":
		_log_raw(text)
		_track_progress(text)


static var _prog_re: RegEx = null   # [k/N] 编译进度

## 解析 cmake 输出中的 [k/N] 进度 → 更新 state.txt(供状态工具实时查看)
func _track_progress(text: String) -> void:
	if _prog_re == null:
		_prog_re = RegEx.new()
		_prog_re.compile("\\[(\\d+)/(\\d+)\\]")
	var cur := ""
	for m in _prog_re.search_all(text):
		cur = "%s/%s" % [m.get_string(1), m.get_string(2)]
	if cur != "" and cur != _last_progress:
		_last_progress = cur
		_state_write("编译中: %s" % cur)


# ------------------------------------------------------------ 部署: 找产物 → 按规格键改名放入落点

func _deploy(build_dir: String, ext_file: String, target_res: String, info: Dictionary) -> void:
	var roots: Array[String] = [build_dir]
	for d in info.get("out_dirs", []):
		roots.append(String(d))
	var target_dir_abs := _abs(target_res).get_base_dir()
	if not roots.has(target_dir_abs):
		roots.append(target_dir_abs)
	var artifact := _find_artifact(roots, String(info.get("target", "")))
	if artifact.is_empty():
		_log("未定位到产物, 请检查上方编译输出。")
		return
	var target_abs := _abs(target_res)
	if artifact == target_abs:
		_log("产物已就位(直出目标目录): ", target_abs)
	else:
		DirAccess.make_dir_recursive_absolute(target_abs.get_base_dir())
		_log("产物: ", artifact)
		if _copy_binary(artifact, target_abs):
			_log("已部署: ", target_res)
		else:
			_log("覆盖目标失败: ", target_abs)
			if OS.get_name() == "Windows":
				_log("原因通常是编辑器正加载该 dll(Windows 文件锁)。请关闭编辑器后手动复制:")
			else:
				_log("请检查目标目录权限后重试, 或手动复制:")
			_log("    copy  \"%s\"  →  \"%s\"" % [artifact, target_abs])
			return
	# 部署后白名单清理: 该目录只保留 *.gdextension [libraries] 声明的各平台必要产物
	_cleanup_native(target_abs.get_base_dir(), ext_file, target_res)


## 部署后清理产物目录: 只保留 *.gdextension [libraries] 声明过的必要文件(各平台/类型/架构键的库)。
## 清掉三类"插件加载不需要"的残留: 无后缀原始产物/导入库(如 libdev.dll.a)、规格外历史库文件、
## 系统锁或覆盖中断产生的临时件(~*/ *.TMP)。规格内跨平台发布件(如 mac dylib)一律保留。
func _cleanup_native(native_dir: String, ext_file: String, deployed_res: String) -> void:
	var keep := _library_whitelist(ext_file)
	keep[deployed_res.get_file()] = true
	var dir := DirAccess.open(native_dir)
	if dir == null:
		return
	var removed := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var low := entry.to_lower()
		var is_tmp := entry.begins_with("~") or low.ends_with(".tmp") or low.ends_with(".temp")
		var is_lib := low.ends_with(".dll") or low.ends_with(".so") or low.ends_with(".dylib") \
				or low.ends_with(".a") or low.ends_with(".lib")
		if not dir.current_is_dir() and not keep.has(entry) and (is_tmp or is_lib):
			if dir.remove(entry) == OK:
				removed += 1
				_log("清理非必要产物: ", entry)
			else:
				_log("清理失败(文件可能被占用): ", entry)
		entry = dir.get_next()
	dir.list_dir_end()
	if removed > 0:
		_log("Native 仅保留规格声明的各平台产物, 已清理 ", removed, " 项。")


## *.gdextension [libraries] 全部值(各平台/类型/架构) → 文件名集合(保留白名单)
func _library_whitelist(ext_file: String) -> Dictionary:
	var keep := {}
	for val in _parse_library_keys(ext_file).values():
		var file := String(val).get_file()
		if file != "":
			keep[file] = true
	return keep


## 在多个搜索根里找"名字匹配 CMake 目标"的最新共享库(跳过 godot-cpp 中间产物)
func _find_artifact(roots: Array, target: String) -> String:
	var stems := PackedStringArray()
	if target != "":
		stems.append(target)
		stems.append("lib" + target)
	var found: Array[String] = []
	for r in roots:
		_walk_artifact(String(r), 0, stems, found)
	if found.is_empty():
		return ""
	found.sort_custom(func(a: String, b: String) -> bool:
		return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	return found[0]


func _walk_artifact(dir_path: String, depth: int, stems: PackedStringArray, out: Array[String]) -> void:
	if depth > 3:
		return
	if dir_path.to_lower().ends_with("godot-cpp"):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_walk_artifact(full, depth + 1, stems, out)
		elif entry.ends_with(".dll") or entry.ends_with(".so") or entry.ends_with(".dylib"):
			var ok_stem := stems.is_empty()
			if not ok_stem:
				var stem := entry.get_basename()
				for s in stems:
					if stem == s:
						ok_stem = true
						break
			if ok_stem:
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


# ------------------------------------------------------------ 平台信息

func _os_label() -> String:
	match OS.get_name():
		"Windows": return "windows"
		"macOS", "OSX": return "macos"
		"Linux": return "linux"
		_: return OS.get_name().to_lower()


func _arch() -> String:
	var arch := Engine.get_architecture_name().to_lower()
	return "x86_64" if arch == "universal" else arch


func _os_token() -> String:
	match OS.get_name():
		"Windows": return "win"
		"macOS", "OSX": return "mac"
		"Linux": return "linux"
	return _os_label()


## 构建类型跟随当前编辑器(debug 编辑器 → debug 产物, 与 .gdextension 键对应)
func _build_type() -> String:
	return "debug" if OS.is_debug_build() else "release"


func _build_type_cap() -> String:
	return _build_type().capitalize()


# ------------------------------------------------------------ 小工具

func _res(p: String) -> String:
	if p.begins_with("res://"):
		return p
	return "res://%s" % p.trim_prefix("/")


func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(_res(p))


## 字节级复制(失败返回 false 由调用方给指引)
func _copy_binary(src: String, dst: String) -> bool:
	var f_in := FileAccess.open(src, FileAccess.READ)
	if f_in == null:
		return false
	var data := f_in.get_buffer(f_in.get_length())
	f_in.close()
	if data.is_empty():
		return false
	var f_out := FileAccess.open(dst, FileAccess.WRITE)
	if f_out == null:
		return false
	f_out.store_buffer(data)
	f_out.close()
	return true


func _print_out(out: Array) -> void:
	for line in out:
		_log_raw(String(line))


func _log(...parts) -> void:
	_log_raw(" ".join(parts.map(str)))


## 输出实时回显 + 追加镜像到 res://.godot/gdextension_build/build.log(编辑器重启后仍可查)
func _log_raw(text: String) -> void:
	_lines.append(text)
	print(text)
	var f := FileAccess.open(_log_path(), FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_string(text + "\n")
		f.close()


func _log_path() -> String:
	return _abs("res://.godot/gdextension_build/build.log")


## 编辑器内自动提示: Godot 4.3+ 顶部 Toaster(非模态、自动消失), 无需翻日志或手动查询。
## 旧引擎无 get_editor_toaster 时静默跳过(日志/状态文件照常, 功能不受影响)。
func _toast(text: String) -> void:
	var ei := get_editor_interface()
	if ei == null or not ei.has_method("get_editor_toaster"):
		return
	var toaster = ei.get_editor_toaster()
	if toaster == null or not toaster.has_method("push_text"):
		return
	toaster.push_text(text)


## 阶段/结果状态文件(实时阶段/进度; 供查看, 非必要)
func _state_write(text: String) -> void:
	var f := FileAccess.open(_abs("res://.godot/gdextension_build/state.txt"), FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()


## 最终摘要(成败/用时/产物/下一步): 自动重载前落盘 + 同步进 build.log/Output,
## 让 build.log 尾部即可看到最终结果(不依赖任何手动查询入口)
func _summary_write(text: String) -> void:
	var f := FileAccess.open(_abs("res://.godot/gdextension_build/last_build.txt"), FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	for line in text.split("\n"):
		if line != "":
			_log_raw(line)


func _finish() -> void:
	var tail := "━ 完成(共 %d 行输出, 日志: res://.godot/gdextension_build/build.log) ━" % _lines.size()
	_log(tail)
	_state_write("done")
	_me = null
