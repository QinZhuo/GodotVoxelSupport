@tool
class_name GDExtensionRebuild
extends EditorScript

## 通用 GDExtension 一键构建工具 —— 零配置、零移动，支持任何遵循 godot-cpp 生态约定的扩展。
##
## 自动出现在 项目 → 工具 → EditorScript（EditorScriptMenuTool 扫描注册）。
## 一次运行自动完成: 发现扩展工程 → 读 CMakeLists 与 *.gdextension 分辨"如何构建/产物去哪"
## → CMake 配置(必要时)/异步编译(不卡编辑器, 实时回显) → 产物按规格改名部署。
##
## 两条"事实源", 不猜、无兜底、零 *.gdextension 匹配:
##   1) CMakeLists.txt(唯一事实源): 解析 add_library 目标名 / *_OUTPUT_DIRECTORY 直出目录 /
##      各平台条件块 OUTPUT_NAME → 精确推导 debug+release 双版本产物文件名与绝对路径
##      (CMake 直出, 无需搬移); 产物路径即最终落点, 不涉及规格文件反查(引擎加载由 .gdextension 自行声明);
##   2) CMakeCache.txt(已配置过): 生成器/编译器/API 全以缓存为准, 只 cmake --build。
## 一次运行自动构建两个版本: 先当前编辑器类型(debug 编辑器优先出 debug), 再另一版本;
## debug 与 release 各用独立构建缓存(CMAKE_BUILD_TYPE 不同不能共用)。
## 任一步推导失败 → 明确报错终止(宁可失败也不猜测), 修正 CMakeLists 后重跑。
##
## 源码目录: 唯一工程根 res://gdextension(不存在才扫 addons/*/);
## 构建后端固定只用 CMake 原生 Makefiles。
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
const KEY_STALL_KILL := "dev_framework/gdextension_build/stall_auto_kill"   # 检测到卡死(无新目标且无编译器进程)时自动终止进程树
const KEY_JOBS := "dev_framework/gdextension_build/build_jobs"        # 并行度, 0=自动(默认16; 设小可降并发防卡)

static var _me: GDExtensionRebuild   # 异步构建期间持有自身(菜单调用方不持有实例)

var _lines: Array[String] = []
var _cache_dirty := false   # submodule 检出变化 → 构建缓存作废, 需重新配置
var _start_ms := 0
var _raw_log_pos := 0       # raw_build.log 尾部读取游标
var _total_targets := -1    # 编译目标总数缓存(Makefile 解析, -1=未解析)
var _objects_logged := 0    # 上次打印磁盘进度时的目标数(≥30 才刷一行)
var _stall_warned := false  # 目标全满但仍卡住时只提示一次
var _prev_done_count := -1  # 上次心跳时的目标数(判断是否还在推进)
var _no_advance := 0        # 目标数无推进的累计秒(心跳间隔 10s)
var _stall_checked := false # 卡死检测已判定并处理
var _stall_killed := false  # 已自动终止卡死进程树


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
	var targets: Array = loc.get("targets")
	if targets.is_empty():
		return _finish()
	_log("源码工程: ", source_dir)

	if not _precheck(source_dir):
		return _finish_with("定位/工具链失败")
	# 编译器 PATH 引导: 编辑器进程常不带 MinGW, 探测常见安装并注入本次进程环境
	_ensure_toolchain_env()
	# 自动同步 godot-cpp(仅当本地缺少所需绑定快照时才走网络, 避免每次拉取/全量重建)
	if _opt(KEY_UPDATE_SUBMODULE, true):
		_state_write("构建进行中: 同步 godot-cpp…")
		await _sync_godot_cpp(source_dir)
	# 双版本依次: 配置 → 编译 → 部署验证 (debug 先行, 编辑器尽快可用; release 随后)
	var done: Array[String] = []
	for tg in targets:
		var type := String(tg.get("type"))
		var target_res := String(tg.get("artifact"))
		_log("──── ", type, " 版 ────")
		var build_dir := _pick_build_dir(source_dir, type)
		if build_dir.is_empty():
			return _finish()
		var info: Dictionary = loc.get("info")
		_state_write("构建进行中(%s): 配置 CMake…" % type)
		if not _ready_build_dir(build_dir, source_dir, info, type):
			return _finish_with("CMake 配置失败(%s)" % type)
		var ok := await _build(build_dir, type)
		if not ok:
			return _finish_with("编译失败(%s, 查看 build.log)" % type)
		_deploy(target_res, info)
		done.append(target_res)
	var elapsed := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var summary := "构建成功(debug + release, 用时 %.1fs)\n产物: %s\n日志: res://.godot/gdextension_build/build.log" % [elapsed, ", ".join(done)]
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

## 定位构建目标 —— 一切信息只从 CMakeLists.txt 获取, 无兜底:
##   1) 解析 add_library 目标名 / *_OUTPUT_DIRECTORY 直出目录 / 各平台条件块 OUTPUT_NAME;
##   2) 由此精确推导"本机预期产物文件名 + 绝对路径"(CMake 直出, 无需搬移);
##   3) 产物路径即最终落点, 不涉及任何 *.gdextension 匹配(引擎加载由 .gdextension 自行声明)。
## 任一步推导失败 → 直接报错终止, 不做猜测式匹配。
func _locate() -> Dictionary:
	var dirs: Array[String] = []
	if _is_ext_source("res://gdextension"):
		dirs.append("res://gdextension")
	else:
		dirs = discover_source_dirs()
	if dirs.is_empty():
		_log("未发现 GDExtension 工程。请确认 res://gdextension(或 addons/*/) 含 CMakeLists.txt + godot-cpp/ submodule。")
		return {}
	var source_dir: String = dirs[0]
	if dirs.size() > 1:
		_log("发现多个工程目录, 取首个: ", source_dir)
		for d in dirs:
			_log("    - 候选: ", d)
	var info := _read_cmake_info(source_dir)

	# 双版本推导: debug + release 各推导一次产物路径(先当前编辑器类型, 编辑器尽快可用)
	var types: Array[String] = [_build_type()]
	for t in ["debug", "release"]:
		if not types.has(t):
			types.append(t)
	var targets: Array = []
	for t in types:
		var art := _expected_artifact(info, t)
		if art.is_empty():
			_log("CMakeLists.txt 缺少 ", t, " 版产物定义, 无法推导产物路径。")
			_log("需要: add_library(<name> SHARED) + *_OUTPUT_DIRECTORY 直出目录 + OUTPUT_NAME 条目 ", _os_label(), ".", t, "。")
			return {}
		targets.append({"type": t, "artifact": String(art.get("res"))})
	_log("已锁定(CMake 推导): ", source_dir)
	for tg in targets:
		_log("预期产物(", String(tg.get("type")), "): ", String(tg.get("artifact")))
	return {"source": source_dir, "targets": targets, "info": info}


## 由 CMake 信息推导指定构建类型的预期产物: {file(文件名), res(res://落点), abs(绝对路径)}。
## 产物名 = 平台.构建类型 对应的 OUTPUT_NAME 条目(CMake 实际行为);
## CMakeLists 钉了 OUTPUT_NAME 却缺该条目 → 模板未覆盖, 报空不猜测;
## 全文未钉 OUTPUT_NAME → 按 CMake 默认规则用 target 名(Windows 无前缀 / macOS/Linux 带 lib 前缀)。
func _expected_artifact(info: Dictionary, type: String) -> Dictionary:
	var out_dirs: Array = info.get("out_dirs", [])
	var target := String(info.get("target", ""))
	if out_dirs.is_empty() or target == "":
		return {}
	var names: Dictionary = info.get("output_names", {})
	var name := String(info.get("output_name", "")) if type == _build_type() else ""
	if name == "":
		if not names.is_empty():
			name = String(names.get("%s.%s" % [_os_label(), type], ""))
		if name == "":
			if not names.is_empty():
				_log("CMakeLists 钉了 OUTPUT_NAME 但缺少条目(", _os_label(), ".", type, "), 无法推导产物名。")
				_log("现有平台条目: ", ", ".join(names.keys()))
				return {}
			name = target
	var file := ""
	match _os_label():
		"windows":
			file = "%s.dll" % name
		"macos":
			file = "lib%s.dylib" % name
		"linux":
			file = "lib%s.so" % name
	if file == "":
		return {}
	var out_abs := String(out_dirs[0])
	return {"file": file, "res": _abs_to_res(out_abs).path_join(file), "abs": out_abs.path_join(file)}


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
	var root := _abs("res://")
	if p.begins_with(root):
		return "res://" + p.substr(root.length())
	return p


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


# ------------------------------------------------------------ 读 CMakeLists 分辨"如何构建"(三个高可信 token)

## 返回 {target, out_dirs(绝对), api_default, output_name(当前平台+类型), output_names(全量)}。
## 不解释 CMake 语义, 只扫模板级高可信写法;
## 扫不到任何 token 也不报错 —— 交由缓存/默认/模糊找库兜底。
## OUTPUT_NAME 解析: 跟踪 if/elseif 条件块, 按 "平台.构建类型" 归档 ——
## CMakeLists 由该单点钉死各平台产物名, 产物路径完全可推导, 无需模糊匹配。
func _read_cmake_info(project_dir: String) -> Dictionary:
	var info := {target = "", out_dirs = [], api_default = "", output_name = "", output_names = {}}
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


func _stall_kill_enabled() -> bool:
	return bool(ProjectSettings.get_setting(KEY_STALL_KILL, true))


## 存活编译器子进程数(cc1plus/g++/clang/python); 查询失败返回 -1
func _active_compile_procs() -> int:
	var out: Array = []
	if OS.get_name() == "Windows":
		if OS.execute("C:/Windows/System32/tasklist.exe", PackedStringArray(), out, true) != 0:
			return -1
		var n := 0
		for line in out:
			var l := String(line)
			if l.contains("cc1plus") or l.contains("g++.exe") or l.contains("python"):
				n += 1
		return n
	if OS.execute("ps", PackedStringArray(["-e", "-o", "comm="]), out, true) == 0:
		var n := 0
		for line in out:
			var l := String(line)
			if l.contains("cc1plus") or l.contains("g++") or l.contains("clang") or l.contains("python"):
				n += 1
		return n
	return -1


## 终止进程树(cmake→make→g++)
func _kill_build_tree(pid: int) -> void:
	if OS.get_name() == "Windows":
		OS.execute("C:/Windows/System32/taskkill.exe",
				PackedStringArray(["/PID", str(pid), "/T", "/F"]), [], true)
	else:
		OS.execute("kill", PackedStringArray(["-KILL", str(pid)]), [], true)


## 构建缓存统一放 res://.godot/gdextension_build/(引擎自带全局忽略, 不入库、不污染工程)。
## 复用已有缓存(优先名称含指定 平台+构建类型 者, 再取最新); 没有则新建 <源>-<os>-<arch>-<类型>。
## debug 与 release 各用独立缓存(CMAKE_BUILD_TYPE 不同不能共用)。
func _pick_build_dir(source_dir: String, type: String) -> String:
	var cache_root := _abs("res://.godot/gdextension_build")
	var token := _os_token()
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


func _ready_build_dir(build_dir: String, source_dir: String, info: Dictionary, type: String) -> bool:
	if _cache_dirty and FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_log("submodule 已更新, 作废旧构建缓存: ", build_dir)
		_wipe_dir(build_dir)
	if FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		# 后端一致性: 缓存必须是 CMake Makefiles, 否则 cmake --build 会按缓存里的其它生成器执行
		if _cache_is_makefiles(build_dir):
			_log("复用构建目录(以缓存配置为准): ", build_dir)
			return true
		_log("缓存生成器不是 Makefiles, 作废重新配置。")
		_wipe_dir(build_dir)
	var src_abs := _abs(source_dir)
	DirAccess.make_dir_recursive_absolute(build_dir)
	var args: PackedStringArray = ["-S", src_abs, "-B", build_dir]
	# 只用 CMake 原生后端: Windows MinGW Makefiles / 其余 Unix Makefiles
	args.append_array(["-G", "MinGW Makefiles" if OS.get_name() == "Windows" else "Unix Makefiles"])
	# API 版本: CMakeLists 默认值对应的绑定快照存在则尊重(不传 -D);
	# 否则在 godot-cpp 本地快照里选"≤ 引擎版本"的最新可用(避免默认 4.7 但无 4-7 快照导致失败)
	var api := _api_version_to_pass(source_dir, String(info.get("api_default", "")))
	if api != "":
		args.append("-DGODOTCPP_API_VERSION=%s" % api)
	args.append("-DCMAKE_BUILD_TYPE=%s" % type.capitalize())
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


## 读取 CMakeCache 确认生成器是否为 Makefiles(后端一致性检查)
func _cache_is_makefiles(build_dir: String) -> bool:
	var f := FileAccess.open(build_dir.path_join("CMakeCache.txt"), FileAccess.READ)
	if f == null:
		return false
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("CMAKE_GENERATOR:INTERNAL="):
			f.close()
			return line.contains("Makefiles")
	f.close()
	return false


# ------------------------------------------------------------ 异步构建

func _build(build_dir: String, type: String) -> bool:
	_log("开始编译 (", type, ")…… 编辑器保持可用, 输出实时回显。")
	var jobs := int(ProjectSettings.get_setting(KEY_JOBS, 0))
	if jobs <= 0:
		jobs = clampi(OS.get_processor_count(), 2, 16)
	# 子进程输出重定向到文件, 本进程定时尾读回显 —— 不经过 Godot execute_with_pipe 管道。
	# 原因: Godot Windows 的管道实现存在读取竞态(高频起停子进程时读线程停摆 → 子进程写管道被堵 → 构建死锁),
	# ninja/make 下均已复现。文件 IO 无此问题, 编辑器仍可用, 输出仍实时(受 stdout 块缓冲影响略有分批)。
	var raw := _raw_log_path()
	DirAccess.remove_absolute(raw)
	_raw_log_pos = 0
	var shell := "sh"
	var run_args := PackedStringArray()
	var cmd_line := "cmake --build \"%s\" --config %s --parallel %d > \"%s\" 2>&1" \
			% [build_dir, type.capitalize(), jobs, raw]
	if OS.get_name() == "Windows":
		# 写入临时 .cmd 再执行, 避免 cmd /c 内联多层引号在含空格路径下转义出错
		var bat := raw.get_base_dir().path_join("run_build.cmd")
		var bf := FileAccess.open(bat, FileAccess.WRITE)
		if bf:
			bf.store_line("@echo off")
			bf.store_line(cmd_line)
			bf.store_line("exit /b %errorlevel%")
			bf.close()
		shell = "cmd.exe"
		run_args = PackedStringArray(["/c", bat.replace("/", "\\")])
	else:
		run_args = PackedStringArray(["-c", cmd_line])
	# 用 create_process 启动, 完全不建立管道: 子进程链若继承管道句柄会导致其等待 EOF 而死锁
	# (此前 Ninja/Make 在 Godot 内异步卡死、引擎 PeekNamedPipe 报错的根因)。输出已重定向到文件。
	var pid := OS.create_process(shell, run_args)
	if pid <= 0:
		_log("异步执行不可用, 退化为阻塞执行(编辑器会卡住直到完成)。")
		var out: Array = []
		var code := OS.execute(shell, run_args, out, true)
		_print_out(out)
		return code == 0
	var tree := Engine.get_main_loop() as SceneTree
	_total_targets = -1   # 每次构建重新解析 Makefile(目录可能重建/缓存残留)
	_stall_warned = false
	_stall_checked = false
	_stall_killed = false
	_prev_done_count = -1
	_no_advance = 0
	_state_write("编译中: 启动…")
	var tick := 0
	var silent := 0
	while OS.is_process_running(pid):
		var had := _drain_log(raw)
		if had:
			silent = 0
		else:
			silent += 1
		tick += 1
		if tick % 10 == 0:   # ~每 2s: 磁盘产物进度(独立于输出, 兜底可量化)
			_report_disk_progress(build_dir)
		if silent >= 50 and silent % 50 == 0:   # 静默 ≥10s 后每 10s 心跳一次
			var d := _count_build_objects(build_dir)
			var t := _total_compile_units(build_dir)
			if t > 0:
				_log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d/%d 目标文件" % [silent / 5, d, t])
			else:
				_log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d 个目标(总数未知)" % [silent / 5, d])
			if silent >= 300 and not _stall_warned and t > 0 and d >= t:   # 已满但仍卡 ≥60s → 一次性诊断引导
				_stall_warned = true
				_log_raw("所有编译目标已生成但进程仍未退出: 通常是构建描述文件被并发写入/截断损坏,")
				_log_raw("或同时开了多个 Godot 实例抢占同一构建目录。")
				_log_raw("处理: 关闭全部 Godot → 删除该构建目录后重新运行(将重新配置), 并保持单实例。")
			# 卡死熔断: 目标长期不增长 + 无编译器子进程存活 → 构建系统在等不存在的子进程(非编译慢)
			if d == _prev_done_count:
				_no_advance += 10
			else:
				_no_advance = 0
				_prev_done_count = d
			if _no_advance >= 60 and not _stall_checked and not _stall_killed:
				var active := _active_compile_procs()
				if active == 0:
					_stall_checked = true
					_log_raw("异常检测: %d 秒无新目标且无任何编译器进程 —— 构建疑似卡死, 尝试终止进程树。" % _no_advance)
					if _stall_kill_enabled():
						_kill_build_tree(pid)
						_stall_killed = true
						_log_raw("已终止卡死进程树(pid %d)。可直接重跑(从已编译部分继续); 反复出现请排查杀软实时扫描/编译器异常。" % pid)
					else:
						_log_raw("自动终止已关闭(ProjectSettings: %s=false)。请在任务管理器结束 cmake/make 后重跑。" % KEY_STALL_KILL)
				else:
					_log_raw("%d 秒无新目标, 仍有 %d 个编译器进程在跑(可能正在编译超大文件), 继续等待。" % [_no_advance, active])
		if _stall_killed:
			break
		await tree.create_timer(0.2).timeout
	_drain_log(raw)   # 进程退出会 flush 全部缓冲, 收尾再读一次
	if _stall_killed:
		_log("构建已被工具终止(疑似卡死)。")
		return false
	var exit_code := OS.get_process_exit_code(pid)
	if exit_code == 0:
		_log("编译成功。")
	else:
		_log("编译失败(退出码 %d), 请按上方报错定位。" % exit_code)
	return exit_code == 0


## 子进程原始输出落点(每次构建覆盖)
func _raw_log_path() -> String:
	return _abs("res://.godot/gdextension_build/raw_build.log")


## 定期把磁盘真实进度写入 state/日志(每 ~2s; 每前进 ≥30 个目标才刷一行日志, 避免刷屏)
func _report_disk_progress(build_dir: String) -> void:
	var total := _total_compile_units(build_dir)
	var done := _count_build_objects(build_dir)
	if total > 0:
		_state_write("编译中: 已生成 %d/%d 目标" % [done, total])
	else:
		_state_write("编译中: 已生成 %d 个目标" % done)
	if done - _objects_logged >= 30:
		_objects_logged = done
		if total > 0:
			_log_raw("编译进度: %d/%d 目标" % [done, total])
		else:
			_log_raw("编译进度: 已生成 %d 个目标" % done)


## 构建目录里已生成的编译单元(.o/.obj)数量 —— 独立于输出管道的真实进度
func _count_build_objects(build_dir: String) -> int:
	var count := 0
	var stack: Array[String] = [build_dir]
	while not stack.is_empty():
		var dir := DirAccess.open(stack.pop_back())
		if dir == null:
			continue
		dir.list_dir_begin()
		var e := dir.get_next()
		while e != "":
			if e.begins_with("."):
				e = dir.get_next()
				continue
			var full := dir.get_current_dir().path_join(e)
			if dir.current_is_dir():
				stack.append(full)
			elif e.ends_with(".o") or e.ends_with(".obj"):
				count += 1
			e = dir.get_next()
		dir.list_dir_end()
	return count


## 编译目标总数: 统计整个构建树所有 build.make 里的"对象编译目标"(去重)。
## 覆盖根工程与 godot-cpp 子 make; 同一对象会有多行依赖声明, 故按目标路径去重后再计数。
## 只认 "<path>.o/.obj" 形式的目标行, 与扩展名差异(Unix .o / Windows .obj)无关。解析一次并缓存。
func _total_compile_units(build_dir: String) -> int:
	if _total_targets >= 0:
		return _total_targets
	_total_targets = 0
	var seen := {}
	var stack: Array[String] = [build_dir]
	while not stack.is_empty():
		var dir := DirAccess.open(stack.pop_back())
		if dir == null:
			continue
		dir.list_dir_begin()
		var e := dir.get_next()
		while e != "":
			if e.begins_with("."):
				e = dir.get_next()
				continue
			var full := dir.get_current_dir().path_join(e)
			if dir.current_is_dir():
				stack.append(full)
			elif e == "build.make":
				for line in FileAccess.get_file_as_string(full).split("\n"):
					var target := line.split(":", 1)[0].strip_edges()
					if (target.ends_with(".o") or target.ends_with(".obj")) and not seen.has(target):
						seen[target] = true
						_total_targets += 1
			e = dir.get_next()
		dir.list_dir_end()
	return _total_targets


## 读取原始构建日志自上次位置起的新内容, 逐行回显到 Output/镜像日志; 返回是否有新行
func _drain_log(raw_path: String) -> bool:
	var f := FileAccess.open(raw_path, FileAccess.READ)
	if f == null:
		return false
	f.seek(_raw_log_pos)
	var had := false
	while not f.eof_reached():
		_log_raw(f.get_line())
		had = true
	_raw_log_pos = f.get_position()
	f.close()
	return had


# ------------------------------------------------------------ 部署: CMake 直出验证 + 纯 CMake 推导的残留清理

## 部署: 唯一事实是 CMake 直出 —— 预期产物路径存在即完成, 不搬移不改名;
## 不存在即报错(由定位阶段保证能走到这里时产物路径已确定), 不做猜测式查找/复制。
func _deploy(target_res: String, info: Dictionary) -> void:
	var target_abs := _abs(target_res)
	if not FileAccess.file_exists(target_abs):
		_log("预期产物未生成: ", target_abs)
		_log("请确认 CMakeLists 已钉 OUTPUT_DIRECTORY 直出目录与各平台 OUTPUT_NAME, 并检查上方编译输出。")
		return
	_log("产物已就位(CMake 直出): ", target_res)
	# 部署后清理: 白名单同样纯 CMake 推导 —— OUTPUT_NAME 各平台条目按平台后缀展开
	_cleanup_native(target_abs.get_base_dir(), _cmake_keep_names(info))


## CMake OUTPUT_NAME 全量平台条目 → 各平台产物文件名白名单。
## 例: macos.debug→lib<名>.dylib / windows.debug→<名>.dll / linux.release→lib<名>.so
func _cmake_keep_names(info: Dictionary) -> PackedStringArray:
	var keep := PackedStringArray()
	var names: Dictionary = info.get("output_names", {})
	for key in names:
		var k := String(key)
		var os := k.split(".")[0]
		var name := String(names[key])
		match os:
			"windows":
				keep.append("%s.dll" % name)
			"macos":
				keep.append("lib%s.dylib" % name)
			"linux":
				keep.append("lib%s.so" % name)
	if names.is_empty() and String(info.get("target", "")) != "":
		# CMakeLists 未钉 OUTPUT_NAME: 按默认规则 target 名即产物名(本机平台)
		match _os_label():
			"windows":
				keep.append("%s.dll" % String(info.get("target")))
			"macos":
				keep.append("lib%s.dylib" % String(info.get("target")))
			"linux":
				keep.append("lib%s.so" % String(info.get("target")))
	return keep


## 部署后清理产物目录: 只保留 CMake OUTPUT_NAME 推导出的各平台产物。
## 清掉三类"插件加载不需要"的残留: 导入库(.a/.lib)、历史库文件、
## 系统锁或覆盖中断产生的临时件(~*/ *.TMP)。其余平台发布件(在白名单内)一律保留。
func _cleanup_native(native_dir: String, keep: PackedStringArray) -> void:
	var keep_set := {}
	for k in keep:
		keep_set[k] = true
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
		if not dir.current_is_dir() and not keep_set.has(entry) and (is_tmp or is_lib):
			if dir.remove(entry) == OK:
				removed += 1
				_log("清理非必要产物: ", entry)
			else:
				_log("清理失败(文件可能被占用): ", entry)
		entry = dir.get_next()
	dir.list_dir_end()
	if removed > 0:
		_log("Native 仅保留 CMake 声明的各平台产物, 已清理 ", removed, " 项。")


# ------------------------------------------------------------ 平台信息

func _os_label() -> String:
	match OS.get_name():
		"Windows": return "windows"
		"macOS", "OSX": return "macos"
		"Linux": return "linux"
		_: return OS.get_name().to_lower()


## 本机架构名(构建缓存目录隔离用; universal 归一为 x86_64)
func _arch() -> String:
	var arch := Engine.get_architecture_name().to_lower()
	return "x86_64" if arch == "universal" else arch


func _os_token() -> String:
	match OS.get_name():
		"Windows": return "win"
		"macOS", "OSX": return "mac"
		"Linux": return "linux"
	return _os_label()


## 构建类型跟随当前编辑器(debug 编辑器 → debug 产物优先构建)
func _build_type() -> String:
	return "debug" if OS.is_debug_build() else "release"


# ------------------------------------------------------------ 小工具

func _res(p: String) -> String:
	if p.begins_with("res://"):
		return p
	return "res://%s" % p.trim_prefix("/")


func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(_res(p))


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
