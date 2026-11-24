@tool
class_name GDExtensionCmakeTool
extends RefCounted

## GDExtension 构建的"CMake/工具链"切片: 工具链探测与环境注入、构建缓存读写、godot-cpp 同步、
## CMake 配置阶段(configure)。只是 GDExtensionRebuild 的实现细节, 不对外提供 API。

## 约束 1: 必须 extends RefCounted —— EditorScriptMenuTool 会把 extends EditorScript 的脚本当菜单工具列出。
## 约束 2: _host 不加类型注解 —— 双向类型注解会形成 class_name 环。
## 约束 3: 实例状态(日志缓冲/构建游标)全部留在 GDExtensionRebuild, 这里只读写 _host.*。

var _host   # GDExtensionRebuild 实例
var _probe: GDExtensionProbeTool   # 目标名/架构/规范名等只读解析

## godot-cpp 自动同步用: 已探测到的 git 可执行文件缓存(""=未探测)。机器事实, 跨场景不变。
## Reset: 进程级
static var _git_path := ""


func _which(prog: String) -> bool:
	var out: Array = []
	return OS.execute(prog, ["--version"], out) == 0


## Windows: 确保 MinGW 工具链在本次构建的 PATH 中。
## 必须注入工具链 bin 目录; 只看 g++ 会漏掉"有 g++ 无 make"的机器(w64devkit 同目录两者皆有)。
func _ensure_toolchain_env() -> void:
	if OS.get_name() != "Windows":
		return
	for _i in 4:
		var missing := _missing_toolchain_bins()
		if missing.is_empty():
			return
		var bin_dir := _toolchain_bin_dir()
		if bin_dir == "":
			_host._log("PATH 中缺少 ", ", ".join(missing), ", 也未发现常见 MinGW/w64devkit。可设环境变量 MINGW_HOME/W64DEVKIT_HOME 指向工具根目录, 或安装 w64devkit。")
			return
		if OS.get_environment("PATH").split(";", false).has(bin_dir):
			_host._log("工具链目录已在 PATH 中但仍缺少 ", ", ".join(missing), ", 请检查该目录内容: ", bin_dir)
			return
		OS.set_environment("PATH", "%s;%s" % [bin_dir, OS.get_environment("PATH")])
		_host._log("已把 MinGW 加入本次构建 PATH: ", bin_dir)


## 构建期必需的可执行文件 —— MinGW Makefiles 下 make 与编译器同等必需
func _missing_toolchain_bins() -> Array[String]:
	var missing: Array[String] = []
	if not _which("g++"):
		missing.append("g++")
	if not _which("make") and not _which("mingw32-make"):
		missing.append("make")
	return missing


## 工具链 bin 目录 —— 构建目录 CMakeCache 记录的编译器/构建器绝对路径最权威, 无缓存时按约定扫描
func _toolchain_bin_dir() -> String:
	for cache in _cache_files():
		for key in ["CMAKE_MAKE_PROGRAM", "CMAKE_CXX_COMPILER", "CMAKE_C_COMPILER"]:
			var dir := _cache_toolchain_dir(cache, key)
			if dir != "":
				return dir
	return GDExtensionProbeTool._find_exe_dir("g++.exe")


## 构建根目录下全部 CMakeCache.txt —— 缓存里的绝对路径是工具链最权威的线索
func _cache_files() -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [_host._abs("res://.godot/gdextension_build")]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var e := d.get_next()
		while e != "":
			var full := dir_path.path_join(e)
			if d.current_is_dir():
				stack.append(full)
			elif e.to_lower() == "cmakecache.txt":
				out.append(full)
			e = d.get_next()
		d.list_dir_end()
	return out


## 从 CMakeCache.txt 读某个路径项(前缀匹配 "<key>:<TYPE>=", 覆盖 FILEPATH/INTERNAL 等)。
## 行格式是 `<KEY>:<TYPE>=<VALUE>`, 必须再切掉 `=<TYPE>` 段才能拿到值 ——
## 少了这一步, 拿到的是 "FILEPATH=C:/..." 这种串, 调用方会把它当成"不存在的路径"。
func _cache_value(cache: String, key: String) -> String:
	var f := FileAccess.open(cache, FileAccess.READ)
	if f == null:
		return ""
	var prefix := key + ":"
	while not f.eof_reached():
		var line := f.get_line()
		if not line.begins_with(prefix):
			continue
		var val := line.substr(prefix.length()).strip_edges()
		var eq := val.find("=")          # 去掉 "FILEPATH=" / "STRING=" 等类型段
		if eq >= 0:
			val = val.substr(eq + 1).strip_edges()
		if val.is_empty() or val.find("NOTFOUND") >= 0:
			return ""
		return val
	return ""


## 从 CMakeCache.txt 读某个路径项, 返回确实含工具链可执行文件的 bin 目录
func _cache_toolchain_dir(cache: String, key: String) -> String:
	var val := _cache_value(cache, key)
	if val == "":
		return ""
	var dir := val.get_base_dir().replace("\\", "/")
	for exe in ["g++.exe", "make.exe", "mingw32-make.exe"]:
		if FileAccess.file_exists(dir.path_join(exe)):
			return dir
	return ""


## 校验缓存里记录的工具链**绝对路径**是否仍指向真实存在的文件 —— 换机器 / 换工具链安装位置后
## 这些路径会失效(缓存随文件夹一起被拷走时尤其典型), 此时必须作废重配。
## ⚠ CMake 若在 PATH 中找到工具, cache 里存的是**裸程序名**(cmake.exe / c++.exe / mingw32-make.exe),
## 那不是"失效路径", 而是交给 PATH 解析的引用。把它当失效会让每一轮构建都 wipe 重建缓存:
## 缓存一重建, godot-cpp 的绑定就重新生成, 1000+ 目标全部重编 —— 表现就是"永远不增量"(实测踩过)。
func _dead_toolchain_paths(build_dir: String) -> Array[String]:
	var cache := build_dir.path_join("CMakeCache.txt")
	var dead: Array[String] = []
	for key in ["CMAKE_MAKE_PROGRAM", "CMAKE_CXX_COMPILER", "CMAKE_C_COMPILER", "CMAKE_COMMAND"]:
		var v := _cache_value(cache, key).replace("\\", "/")
		if v == "" or not v.is_absolute_path():
			continue   # 裸程序名: 由 PATH 解析, 不判失效
		if not FileAccess.file_exists(v):
			dead.append("%s=%s" % [key, v.get_file()])
	return dead


## 零配置骨架: 只要 res://gdextension/src 下有 .cpp, 就把构建需要的一切补齐。
## 只补缺失项(见 NativeScaffold): 手写 CMakeLists 的工程完全不受影响。
func _ensure_scaffold() -> void:
	# 多插件: 每个 addons/<Plugin>/Native/src 有 .cpp 就算一个插件, 各编一个库(共用 godot-cpp)。
	# 用 load 而不是全局类名: 新增的 class_name 要等编辑器重载脚本缓存才可见,
	# 而构建工具经常在"刚加完文件"的状态下被调用(与 ECSNative.instantiate_script 同一个理由)。
	var scaf: GDScript = load(GDExtensionProbeTool.SCAFFOLD_PATH) as GDScript
	if scaf == null:
		_host._log("警告: NativeScaffold 脚本缺失, 跳过骨架生成。")
		return
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	var res: Dictionary = scaf.ensure_project(root, GDExtensionProbeTool._engine_api_hint(), true,
			func(msg: String) -> void: _host._log(msg))
	var plugins: Array = res.get("plugins", [])
	if plugins.is_empty():
		return
	var names: Array[String] = []
	for p in plugins:
		names.append("%s(%s)" % [String(p["plugin"]), String(p["target"])])
	_host._log("原生插件 %d 个: %s" % [plugins.size(), ", ".join(names)])
	var created: Array = res.get("created", [])
	for item in created:
		_host._log("骨架自动生成: ", String(item))
	# 跨插件同名类会让引擎在加载时报难以定位的错, 提前判出
	var conflicts: Array = res.get("conflicts", [])
	for c in conflicts:
		_host._log("错误: 类名 %s 同时出现在插件 %s —— 同进程注册同名类会冲突, 请改名。" % [
			String(c["name"]), ", ".join(c["targets"])])


func _precheck(source_dir: String) -> bool:
	var abs: String = _host._abs(source_dir)
	if not FileAccess.file_exists(abs.path_join("CMakeLists.txt")):
		_host._log("该扩展暂仅支持 CMake 构建(未找到 CMakeLists.txt)。")
		return false
	if not FileAccess.file_exists(abs.path_join("godot-cpp/SConstruct")):
		_host._log("godot-cpp 尚未获取(不入库), 请执行:")
		_host._log("    git clone --depth 1 https://github.com/godotengine/godot-cpp gdextension/godot-cpp")
		return false
	var out: Array = []
	if OS.execute("cmake", ["--version"], out, true) != 0:
		_host._log("未找到 cmake, 请安装并加入 PATH(Windows 便携版可参考 w64devkit)。")
		return false
	var ver: String = (out[0] if not out.is_empty() else "").strip_edges().split("\n")[0]
	_host._log("cmake: ", ver)
	return true


## 定位 git: PATH 未必有 → 走通用探测(_find_exe_dir), 仍无则按 PATH 名兜底。静态(供解析器复用)
static func _git_exe() -> String:
	if _git_path == "":
		var dir := GDExtensionProbeTool._find_exe_dir("git.exe")
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


func _sync_godot_cpp(source_dir: String) -> void:
	var vi: Dictionary = Engine.get_version_info()
	var engine_api := "%d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 0))]
	var def_api := _cmake_api_default(source_dir)
	# 核心原则 —— 只要有"可编译"的本地快照(CMakeLists 钉版, 或引擎回退版), 就绝不动 submodule。
	if def_api != "" and _has_snapshot(source_dir, def_api):
		_host._log("godot-cpp 钉版快照已在本地(默认 ", def_api, "), 无需同步 —— 纯增量。")
		return
	if _api_version_to_pass(source_dir, def_api) != "":
		_host._log("godot-cpp 本地有可用回退快照(引擎 ", engine_api, " 无对应钉版), 无需同步 —— 纯增量。")
		return
	_host._log("godot-cpp 本地无任何可用绑定快照(仓库钉版异常/引擎过新), 一次性对齐引擎 ", engine_api, " ……")
	var gcpp: String = _host._abs(source_dir).path_join("godot-cpp")
	var out: Array = []
	if OS.execute(_git_exe(), ["-C", gcpp, "rev-parse", "--is-inside-work-tree"], out) != 0:
		_host._log("godot-cpp 不是 git 工作树, 跳过自动更新。")
		return
	var want := _resolve_godot_cpp_ref(gcpp, engine_api)
	if want.is_empty():
		_host._log("无法解析 godot-cpp 对应版本(网络不可达?), 沿用当前 submodule。")
		return
	var head: Array = []
	if OS.execute(_git_exe(), ["-C", gcpp, "rev-parse", "HEAD"], head) != 0:
		return
	var current := String(head[0]).strip_edges()
	if current == String(want.get("sha")):
		_host._log("godot-cpp 已是最新(", want.get("name"), ")。")
		return
	_host._log("检出 godot-cpp: ", current.substr(0, 8), " → ", want.get("name"))
	var fetch: Array = []
	var ok := false
	if String(want.get("kind")) == "tag":
		ok = OS.execute(_git_exe(), ["-C", gcpp, "fetch", "origin", "tag", String(want.get("name"))], fetch) == 0
	else:
		ok = OS.execute(_git_exe(), ["-C", gcpp, "fetch", "origin", String(want.get("name"))], fetch) == 0
	_host._print_out(fetch)
	if not ok:
		_host._log("fetch 失败, 沿用当前 submodule。")
		return
	var co: Array = []
	ok = OS.execute(_git_exe(), ["-C", gcpp, "checkout", "--detach", String(want.get("sha"))], co) == 0
	_host._print_out(co)
	if ok:
		_host._cache_dirty = true
		_host._log("godot-cpp 已更新, 将重建构建缓存。")
	else:
		_host._log("checkout 失败, 沿用当前 submodule。")


## 解析 godot-cpp 应检出的引用(静态可测, 只 ls-remote, 不改动工作树)。
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


## 构建缓存统一放 res://.godot/gdextension_build/(引擎自带全局忽略, 不入库、不污染工程)。
func _pick_build_dir(source_dir: String, type: String, arch: String) -> String:
	var cache_root: String = _host._abs("res://.godot/gdextension_build")
	var dir := cache_root.path_join("%s-%s-%s-%s" % [source_dir.get_file(), _probe._os_label(), arch, type])
	if not FileAccess.file_exists(dir.path_join("CMakeCache.txt")):
		_host._log("未发现(%s.%s)已配置构建缓存, 将新建: " % [type, arch], dir)
	return dir


func _ready_build_dir(build_dir: String, source_dir: String, info: Dictionary, type: String, arch: String) -> bool:
	if _host._cache_dirty and FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_host._log("submodule 已更新, 作废旧构建缓存: ", build_dir)
		_wipe_dir(build_dir)
	if FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		# 后端一致性: 缓存必须是 CMake Makefiles, 否则 cmake --build 会按缓存里的其它生成器执行
		if _cache_is_makefiles(build_dir):
			# 构建类型一致性: 单配置生成器(Makefiles)忽略 --config, 缓存类型不符会把 release 跑成 debug
			var cached_type := _cache_build_type(build_dir)
			# 架构一致性(macOS): CMAKE_OSX_ARCHITECTURES 决定产物架构, 缓存不符即作废
			var cached_arch := _cache_osx_archs(build_dir) if _probe._os_label() == "macos" else arch
			# 工具链存活: 缓存里记的是绝对路径, 换机器/重装工具链后即失效, 必须作废重配
			var dead_tc := _dead_toolchain_paths(build_dir)
			if cached_type == type and cached_arch == arch and dead_tc.is_empty():
				_host._log("复用构建目录(以缓存配置为准): ", build_dir)
				_ensure_ccache(build_dir)
				return true
			if not dead_tc.is_empty():
				_host._log("缓存工具链已失效(", ", ".join(dead_tc), "), 作废重新配置。")
			else:
				_host._log("缓存配置(%s.%s)与目标(%s.%s)不符, 作废重新配置。" % [
					cached_type if cached_type != "" else "未设置",
					cached_arch if cached_arch != "" else "默认架构",
					type, arch])
		else:
			_host._log("缓存生成器不是 Makefiles, 作废重新配置。")
		_wipe_dir(build_dir)
	var src_abs: String = _host._abs(source_dir)
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
	# ccache: godot-cpp 的绑定生成器是 custom target(每次都重写 gen/*, 内容通常不变),
	# 没有编译缓存时"改一个 .cpp"会连带重编 1000+ 个 gen 目标; 有 ccache 则整批命中。
	var cc := _ccache_exe()
	if cc != "":
		args.append("-DCMAKE_CXX_COMPILER_LAUNCHER=%s" % cc)
	# macOS 交叉构建: Apple 工具链原生支持 -arch 交叉, 按架构钉死目标(本机/交叉统一走此参数)
	if _probe._os_label() == "macos":
		args.append("-DCMAKE_OSX_ARCHITECTURES=%s" % arch)
	_host._log("配置 CMake: ", " ".join(args))
	var out: Array = []
	var code := OS.execute("cmake", args, out, true)
	_host._print_out(out)
	if code != 0:
		_host._log("cmake 配置失败(退出码 %d)。Windows 常见原因: MinGW 未在 PATH, 或用 MSVC 但编辑器非从 vcvars 环境启动。" % code)
		_wipe_dir(build_dir)   # 清掉失败残留缓存, 下次重新配置
		return false
	return true


## 决定 GODOTCPP_API_VERSION 是否传 -D 及传什么:
##   - CMakeLists 默认值对应的绑定快照存在 → ""(不传, 尊重工程钉版)
##   - 否则在 godot-cpp 本地 extension_api-*.json 快照里, 取主次版本 ≤ 引擎 的最新可用
##   - 本地全无 → ""(交给 cmake, 会给出缺文件报错)
func _api_version_to_pass(source_dir: String, api_default: String) -> String:
	var gext_dir: String = _host._abs(source_dir).path_join("godot-cpp/gdextension")
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
	var p: String = _host._abs(source_dir).path_join("CMakeLists.txt")
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
	return FileAccess.file_exists(_api_file(_host._abs(source_dir).path_join("godot-cpp/gdextension"), api))


## 编译缓存工具(ccache): 存在即用, 不存在就静默跳过 —— 纯加速选项, 不改变构建结果。
## 为什么要它: godot-cpp 的绑定生成器是 custom target, 每次都重写 gen/*(内容通常不变),
## 于是"改一个 .cpp"会连带重编 1000+ 个 gen 目标; ccache 按预处理内容哈希命中, 整批跳过。
static func _ccache_exe() -> String:
	var out: Array = []
	return "ccache" if OS.execute("ccache", ["--version"], out) == 0 else ""


## 老缓存里没有 launcher 时补一条(只改缓存, 不重新配置整棵树):
## 否则"复用构建目录"会让 ccache 永远不生效, 增量也就永远不成立。
func _ensure_ccache(build_dir: String) -> void:
	var cc := _ccache_exe()
	if cc == "":
		return
	if _cache_has_launcher(build_dir):
		return
	var out: Array = []
	if OS.execute("cmake", ["-B", build_dir, "-DCMAKE_CXX_COMPILER_LAUNCHER=" + cc], out, true) == 0:
		_host._log("已为现有构建缓存启用编译缓存(ccache): 下次构建起生效。")
	else:
		_host._print_out(out)


static func _cache_has_launcher(build_dir: String) -> bool:
	var f := FileAccess.open(build_dir.path_join("CMakeCache.txt"), FileAccess.READ)
	if f == null:
		return false
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("CMAKE_CXX_COMPILER_LAUNCHER:") and line.get_slice("=", 1).strip_edges() != "":
			f.close()
			return true
	f.close()
	return false


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


## 读取 CMakeCache 的 CMAKE_BUILD_TYPE(单配置生成器实际生效的构建类型); 无设置返回 ""
func _cache_build_type(build_dir: String) -> String:
	var f := FileAccess.open(build_dir.path_join("CMakeCache.txt"), FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("CMAKE_BUILD_TYPE:STRING="):
			f.close()
			return line.substr("CMAKE_BUILD_TYPE:STRING=".length()).to_lower()
	f.close()
	return ""


## 读取 CMakeCache 的 CMAKE_OSX_ARCHITECTURES(macOS 交叉构建一致性); 未设置返回 ""
func _cache_osx_archs(build_dir: String) -> String:
	var f := FileAccess.open(build_dir.path_join("CMakeCache.txt"), FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("CMAKE_OSX_ARCHITECTURES:STRING="):
			f.close()
			return line.substr("CMAKE_OSX_ARCHITECTURES:STRING=".length()).strip_edges().to_lower()
	f.close()
	return ""
