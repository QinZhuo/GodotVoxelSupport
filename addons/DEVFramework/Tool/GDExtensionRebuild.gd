@tool
class_name GDExtensionRebuild
extends EditorScript

## 通用 GDExtension 一键构建工具 —— 零配置构建 + 规范命名部署, 支持任何 godot-cpp 生态扩展。
##
## 自动出现在 项目 → 工具 → EditorScript（EditorScriptMenuTool 扫描注册）。
## 一次运行自动完成: 发现扩展工程 → 读 CMakeLists 分辨"如何构建/产物去哪"
## → CMake 配置(必要时)/异步编译(不卡编辑器, 实时回显) → 产物改名为规范名部署。
##
## 两条"事实源":
##   1) CMakeLists.txt(构建事实源): 只需解析出 add_library 目标名 与 *_OUTPUT_DIRECTORY 直出目录 ——
##      OUTPUT_NAME 各平台条件块为**可选项**(有则直出名即规范名, 零改名);
##      未写时 CMake 直出默认名(如 libdev.dylib), 工具统一改名为规范名:
##        lib<名>.<平台>.<debug|release>.<架构>.dylib / <名>.<平台>.<类型>.<架构>.dll / lib<名>...so
##      该规范名与 godot-cpp 官方 [libraries] 键风格一致, *.gdextension 声明无需手改;
##   2) CMakeCache.txt(已配置过): 生成器/编译器/API/构建类型 全以缓存为准, 只 cmake --build。
## 一次运行自动构建两个版本: 先当前编辑器类型(debug 编辑器优先出 debug), 再另一版本;
## debug 与 release 各用独立构建缓存(复用前校验 CMakeCache 的 CMAKE_BUILD_TYPE, 不符即作废重配)。
## 任一步推导失败 → 明确报错终止(宁可失败也不猜测), 修正 CMakeLists 后重跑。
## 声明同步(dev_framework/gdextension_build/sync_gdextension, 默认开): 部署后以"规范名产物"为准,
## 自动回写 *.gdextension [libraries] 的本平台键 —— 已有键只更新值(键名/架构风格不动), 缺键按
## "<平台>.<构建类型>[.<架构>]" 新增; template_debug 等其他体系键与其他段一律不碰。
## 跨项目零手工对齐; 不凭空创建 *.gdextension(entry_symbol 写在 C++ 里无法推导, 引擎侧需自行提供)。
## 关闭时退化为一致性校验告警。Native 清理白名单 = 声明键文件 + 本机两类型规范名,
## 杜绝"清理误删声明产物"—— 无任何白名单依据时跳过清理(宁可残留也不误删)。
## 跨架构(dev_framework/gdextension_build/cross_archs, 默认开): 声明驱动的补缺构建 ——
## 以 *.gdextension [libraries] 声明的本平台架构为准, macOS 上自动交叉编译缺失架构
## (Apple 工具链原生支持 -arch 交叉, 零额外工具链; CMAKE_OSX_ARCHITECTURES 按架构独立缓存目录);
## 其他平台交叉工具链复杂, 仅构建本机架构并提示。首次交叉构建需全量编译 godot-cpp, 耗时较长属正常。
## universal 合并(默认执行, 无开关): macOS 各类型多架构产物齐后
## 自动 lipo -create 合并为 lib<名>.macos.<类型>.universal.dylib —— 这正是 Godot 官方引擎发布的做法
## (各架构独立构建保留各自 -march 优化, 再合并; 优于 CMAKE_OSX_ARCHITECTURES 一次出双架构——那会废掉
## -march, fat binary 只能用默认基线)。声明键保持架构专属不动: universal 与架构键同时声明会触发
## 引擎重复库警告(Godot 4.4+ PR #98809), 发布用 universal 时二选一切换。
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
const KEY_SYNC_GDEXT := "dev_framework/gdextension_build/sync_gdextension"   # 部署后把实盘产物路径回写 *.gdextension([libraries])
const KEY_CROSS_ARCHS := "dev_framework/gdextension_build/cross_archs"       # macOS 按声明自动交叉补缺架构
const GDEXT_TYPES := ["debug", "release", "template_debug", "template_release"]   # 声明键中的构建类型 tag
const GDEXT_ARCHS := ["arm64", "x86_64", "arm32", "x86_32", "universal"]          # 声明键/规范名中的架构 tag
const KEY_STALL_KILL := "dev_framework/gdextension_build/stall_auto_kill"   # 检测到卡死(无新目标且无编译器进程)时自动终止进程树
const KEY_JOBS := "dev_framework/gdextension_build/build_jobs"        # 并行度, 0=自动(默认16; 设小可降并发防卡)

static var _me: GDExtensionRebuild   # 异步构建期间持有自身(菜单调用方不持有实例)

var _lines: Array[String] = []
var _cache_dirty := false   # submodule 检出变化 → 构建缓存作废, 需重新配置
var _start_ms := 0
var _raw_log_pos := 0       # raw_build.log 尾部读取游标
var _total_targets := -1    # 编译目标总数缓存(Makefile 解析, -1=未解析)
var _objects_logged := 0    # 上次打印磁盘进度时的目标数(≥30 才刷一行)

var _prev_done_count := -1  # 上次心跳时的目标数(判断是否还在推进)
var _no_advance := 0        # 目标数无推进的累计秒(心跳间隔 10s)
var _stall_checked := false # 卡死检测已判定并处理
var _stall_killed := false  # 已自动终止卡死进程树
var _synced: Array[String] = []   # 本次运行同步的声明条目(最终摘要展示)


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
	# 双版本 × 架构依次: 配置 → 编译 → 部署验证 (当前编辑器类型+本机架构先行, 编辑器尽快可用)
	var info: Dictionary = loc.get("info")
	var gdext_res := String(loc.get("gdext"))
	if gdext_res == "":
		_log("产物输出目录未发现 *.gdextension, 跳过声明同步(引擎加载扩展仍需自行提供)。")
	var done: Array[String] = []
	var type_archs: Dictionary = {}   # 类型 → 已部署架构产物文件名列表(lipo 合并用)
	for tg in targets:
		var type := String(tg.get("type"))
		var arch := String(tg.get("arch"))
		var target_res := String(tg.get("artifact"))
		_log("──── %s / %s ────" % [type, arch])
		var build_dir := _pick_build_dir(source_dir, type, arch)
		if build_dir.is_empty():
			return _finish()
		_state_write("构建进行中(%s.%s): 配置 CMake…" % [type, arch])
		if not _ready_build_dir(build_dir, source_dir, info, type, arch):
			return _finish_with("CMake 配置失败(%s.%s)" % [type, arch])
		var ok := await _build(build_dir, type)
		if not ok:
			return _finish_with("编译失败(%s.%s, 查看 build.log)" % [type, arch])
		var actual := _deploy(target_res, info, type, arch)
		if actual == "":
			return _finish_with("产物部署失败(%s.%s, 查看 build.log)" % [type, arch])
		done.append(target_res)
		if not type_archs.has(type):
			type_archs[type] = []
		type_archs[type].append(actual)
	# 各类型多架构产物齐 → lipo 合并 universal 并删除输入架构文件(macOS 自带 lipo; 非 macOS/单架构自动跳过);
	# 合并成功的类型: 声明切到 universal 键; 未合并的类型: 按架构文件同步声明。
	# 轮间不做任何清理(防止删掉后续轮/合并所需文件), 全部完成后统一终清一次。
	var target_name := String(info.get("target", ""))
	var platform := _os_label()
	if target_name != "":
		for type in type_archs:
			var files: Array = type_archs[type]
			var uni := _lipo_merge(info, target_name, String(type), files)
			if uni != "":
				done.append(uni)
				if gdext_res != "":
					if _opt(KEY_SYNC_GDEXT, true):
						_gdext_adopt_universal(gdext_res, platform, String(type), uni)
					else:
						_log("警告: 声明未指向 universal(%s.%s), 请切换 %s.%s.universal 键或开启 sync_gdextension。" % [type, type, platform, type])
				continue
			if gdext_res != "":
				for f in files:
					var fname := String(f)
					if _opt(KEY_SYNC_GDEXT, true):
						_gdext_sync(gdext_res, _abs_to_res(String(info.get("out_dirs", [])[0])).path_join(fname), platform, String(type), fname)
					else:
						_gdext_verify(gdext_res, platform, String(type), fname)
	# 终清: 声明(此刻已是最终形态) + universal 产物之外的一切动态库残留
	_final_cleanup(info, gdext_res, target_name)
	var elapsed := (Time.get_ticks_msec() - _start_ms) / 1000.0
	var types_txt: Array[String] = []
	for tg in targets:
		types_txt.append(String(tg.get("type")))
	var summary := "构建成功(%s, 用时 %.1fs)\n产物: %s\n日志: res://.godot/gdextension_build/build.log" % [" + ".join(types_txt), elapsed, ", ".join(done)]
	if not _synced.is_empty():
		summary += "\n声明同步: " + ", ".join(_synced)
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

## 定位构建目标 —— 只需 CMakeLists 给出 目标名 + 输出目录:
##   1) 解析 add_library 目标名 / *_OUTPUT_DIRECTORY 直出目录;
##   2) 按工具规范名推导各构建类型产物(lib<名>.<平台>.<类型>.<架构>.<ext>);
##   3) 直出名若与规范名不同(未写 OUTPUT_NAME 的默认名), 编译后由 _deploy 改名归位。
## 推导不出目标名/输出目录 → 直接报错终止, 不做猜测式匹配。
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
	var gdext_res := _find_gdextension(info)

	# 双版本 × 架构: 类型 = [当前编辑器类型优先, 另一类型]; 架构 = 本机 + 声明中缺失的交叉架构(仅 macOS)
	var types: Array[String] = [_build_type()]
	for t in ["debug", "release"]:
		if not types.has(t):
			types.append(t)
	var archs := _plan_archs(gdext_res)
	var targets: Array = []
	for t in types:
		for a in archs:
			var art := _expected_artifact(info, t, a)
			if art.is_empty():
				_log("CMakeLists.txt 无法推导产物: 需要 add_library(<name> SHARED) 与 *_OUTPUT_DIRECTORY 直出目录。")
				return {}
			targets.append({"type": t, "arch": a, "artifact": String(art.get("res"))})
	_log("已锁定(CMake 推导): ", source_dir)
	for tg in targets:
		_log("预期产物(%s.%s): %s" % [String(tg.get("type")), String(tg.get("arch")), String(tg.get("artifact"))])
	return {"source": source_dir, "targets": targets, "info": info, "gdext": gdext_res}


## 由 CMake 信息推导指定构建类型/架构的预期产物: {file(文件名), res(res://落点), abs(绝对路径)}。
## 文件名 = 工具规范名 lib<target>.<平台>.<类型>.<架构>.<ext>(与 godot-cpp 官方 [libraries] 键风格一致);
## CMakeLists 若钉了同名 OUTPUT_NAME 则直出即命中(零改名), 未钉/默认名由 _deploy 统一改名归位。
func _expected_artifact(info: Dictionary, type: String, arch := "") -> Dictionary:
	var out_dirs: Array = info.get("out_dirs", [])
	var target := String(info.get("target", ""))
	if out_dirs.is_empty() or target == "":
		return {}
	var file := _canonical_file(target, type, arch)
	var out_abs := String(out_dirs[0])
	return {"file": file, "res": _abs_to_res(out_abs).path_join(file), "abs": out_abs.path_join(file)}


## 本轮要构建的架构列表: 本机架构恒在; macOS 额外补齐 *.gdextension 声明中缺失的架构
## (Apple 工具链原生支持 -arch 交叉编译, 零额外工具链); 其他平台仅本机并提示。
## universal 键视为不指定架构(本机产物即可覆盖), 不触发交叉构建。
func _plan_archs(gdext_res: String) -> Array[String]:
	var host := _arch()
	var archs: Array[String] = [host]
	if not _opt(KEY_CROSS_ARCHS, true):
		return archs
	if _os_label() != "macos":
		var missing := _declared_missing_archs(gdext_res, host)
		if not missing.is_empty():
			_log("提示: 声明含跨架构产物(%s), 但交叉构建仅支持 macOS; 如需请在本平台手动构建。" % ", ".join(missing))
		return archs
	for a in _declared_missing_archs(gdext_res, host):
		archs.append(a)
		_log("声明需要跨架构产物, 将交叉构建(%s, 首次需全量编译 godot-cpp): lib 规范名架构 %s" % [a, a])
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


## 工具规范产物名: lib<名>.<平台>.<debug|release>.<架构>.dylib /
##                 <名>.<平台>.<debug|release>.<架构>.dll(Windows 无 lib 前缀) /
##                 lib<名>.<平台>.<debug|release>.<架构>.so
## 架构缺省取编辑器运行架构 —— 与 .gdextension 官方键/tag 命名对齐。
func _canonical_file(target: String, type: String, arch := "") -> String:
	var ext := ""
	var prefix := "lib"
	match _os_label():
		"windows":
			ext = ".dll"
			prefix = ""
		"macos":
			ext = ".dylib"
		"linux":
			ext = ".so"
		_:
			return ""
	var a := arch if arch != "" else _arch()
	return "%s%s.%s.%s.%s%s" % [prefix, target, _os_label(), type, a, ext]


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
## 目录名固定 <源>-<os>-<架构>-<类型> —— 类型/架构天然隔离, 不再从"任意缓存"复用
## (旧逻辑会把 release 塞进 debug 缓存目录: 单配置生成器忽略 --config, release 实际从未编译)。
## 复用前 _ready_build_dir 还会校验缓存里的 CMAKE_BUILD_TYPE / CMAKE_OSX_ARCHITECTURES, 不符即作废重配。
func _pick_build_dir(source_dir: String, type: String, arch: String) -> String:
	var cache_root := _abs("res://.godot/gdextension_build")
	var dir := cache_root.path_join("%s-%s-%s-%s" % [source_dir.get_file(), _os_label(), arch, type])
	if not FileAccess.file_exists(dir.path_join("CMakeCache.txt")):
		_log("未发现(%s.%s)已配置构建缓存, 将新建: " % [type, arch], dir)
	return dir


static func _newest_cache(dirs: Array) -> String:
	var best := String(dirs[0])
	var t := -1.0
	for d in dirs:
		var m := FileAccess.get_modified_time(String(d).path_join("CMakeCache.txt"))
		if m > t:
			t = m
			best = String(d)
	return best


func _ready_build_dir(build_dir: String, source_dir: String, info: Dictionary, type: String, arch: String) -> bool:
	if _cache_dirty and FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		_log("submodule 已更新, 作废旧构建缓存: ", build_dir)
		_wipe_dir(build_dir)
	if FileAccess.file_exists(build_dir.path_join("CMakeCache.txt")):
		# 后端一致性: 缓存必须是 CMake Makefiles, 否则 cmake --build 会按缓存里的其它生成器执行
		if _cache_is_makefiles(build_dir):
			# 构建类型一致性: 单配置生成器(Makefiles)忽略 --config, 缓存类型不符会把 release 跑成 debug
			var cached_type := _cache_build_type(build_dir)
			# 架构一致性(macOS): CMAKE_OSX_ARCHITECTURES 决定产物架构, 缓存不符即作废
			var cached_arch := _cache_osx_archs(build_dir) if _os_label() == "macos" else arch
			if cached_type == type and cached_arch == arch:
				_log("复用构建目录(以缓存配置为准): ", build_dir)
				return true
			_log("缓存配置(%s.%s)与目标(%s.%s)不符, 作废重新配置。" % [
				cached_type if cached_type != "" else "未设置",
				cached_arch if cached_arch != "" else "默认架构",
				type, arch])
		else:
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
	# macOS 交叉构建: Apple 工具链原生支持 -arch 交叉, 按架构钉死目标(本机/交叉统一走此参数)
	if _os_label() == "macos":
		args.append("-DCMAKE_OSX_ARCHITECTURES=%s" % arch)
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
			# 卡死熔断: 目标长期不增长 + 无编译器子进程存活 → 构建系统在等不存在的子进程(非编译慢)
			if d == _prev_done_count:
				_no_advance += 10
			else:
				_no_advance = 0
				_prev_done_count = d
			if _no_advance >= 500 and not _stall_checked and not _stall_killed:
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

## 部署: 直出命中规范名即用; 否则实盘兜底取最新动态库, 并统一**改名**为规范名
## (CMake 默认名 libdev.dylib → libdev.macos.debug.arm64.dylib), 与 *.gdextension 声明天然对应。
## CMakeLists 钉了规范名 OUTPUT_NAME 时改名零成本(同名跳过)。找不到产物返回 ""(部署失败)。
## Windows 边界: 编辑器锁住加载中的 dll 致改名失败 → 保留直出名并告警(声明同步按实盘名对齐, 保可用)。
func _deploy(target_res: String, info: Dictionary, type: String, arch: String) -> String:
	var out_dir: String = info.get("out_dirs", [])[0]
	var target := String(info.get("target", ""))
	var canonical := _canonical_file(target, type, arch)
	var actual := ""
	var direct := _default_out_file(target)   # CMake 默认直出名(刚链接, mtime 最新, 内容必然新鲜)
	if direct != "" and FileAccess.file_exists(String(out_dir).path_join(direct)):
		# 默认名存在 → 本次链接产物, 强制改名归位(覆盖可能残留的旧规范名, 杜绝陈旧命中)
		if _rename_lib(out_dir, direct, canonical):
			_log("产物规范命名: ", direct, " → ", canonical)
			actual = canonical
		else:
			_log("警告: 规范命名失败(文件可能被占用), 保留 ", direct, "; 声明同步将按实盘名对齐。")
			actual = direct
	elif FileAccess.file_exists(_abs(target_res)):
		actual = canonical   # 直出名即规范名(CMake 钉了 OUTPUT_NAME)
	else:
		actual = _scan_dynamic_libs(out_dir)
		if actual != "":
			_log("规范名产物未直出, 实盘取最新动态库: ", actual)
	if actual == "":
		_log("预期产物未生成: ", _abs(target_res))
		_log("请确认 CMakeLists 已钉 *_OUTPUT_DIRECTORY 直出目录, 并检查上方编译输出。")
		return ""
	if actual != canonical:
		if _rename_lib(out_dir, actual, canonical):
			_log("产物规范命名: ", actual, " → ", canonical)
			actual = canonical
	_log("产物已就位: ", _abs_to_res(out_dir).path_join(actual))
	return actual


## CMake 默认直出名(macOS lib<名>.dylib / Windows <名>.dll / Linux lib<名>.so; 未钉 OUTPUT_NAME 时 CMake 的输出文件名)
func _default_out_file(target: String) -> String:
	match _os_label():
		"windows":
			return "%s.dll" % target
		"macos":
			return "lib%s.dylib" % target
		"linux":
			return "lib%s.so" % target
		_:
			return ""


## 同目录改名(先清旧规范名残留); 失败返回 false(Windows 编辑器锁定 dll 等场景)
func _rename_lib(dir_path: String, from_file: String, to_file: String) -> bool:
	var to_abs := String(dir_path).path_join(to_file)
	if FileAccess.file_exists(to_abs):
		DirAccess.remove_absolute(to_abs)
	return DirAccess.rename_absolute(String(dir_path).path_join(from_file), to_abs) == OK


## 终清: 全部轮次与合并完成后执行一次(轮间零清理, 合并输入绝不误删)。
## 白名单 = 声明值文件(此刻已是最终形态: 已合并类型为 universal 键, 未合并类型为架构键)
## + universal 产物 + 未合并类型的架构规范名防御(声明同步失败时仍保产物可用)。
func _final_cleanup(info: Dictionary, gdext_res: String, target: String) -> void:
	var native_dir: String = info.get("out_dirs", [])[0]
	var keep := _gdext_keep_files(gdext_res)
	for a in _declared_archs(gdext_res):   # 声明仍是架构键的类型(合并失败/未合并) → 规范名保护
		keep.append(_canonical_file(target, "debug", a))
		keep.append(_canonical_file(target, "release", a))
	if _os_label() == "macos":
		keep.append(_universal_file(target, "debug"))     # lipo 合并产物恒保
		keep.append(_universal_file(target, "release"))
	if keep.is_empty():
		_log("无清理白名单, 跳过 Native 清理。")
		return
	_cleanup_native(native_dir, keep)
	if keep.is_empty():
		_log("无清理白名单, 跳过 Native 清理。")
		return
	_cleanup_native(native_dir, keep)


## 在产物输出目录(*_OUTPUT_DIRECTORY)里定位 *.gdextension(与产物同目录是框架约定)。
## 找不到返回 ""(此时跳过声明同步与校验, 引擎侧需自行提供声明文件)。
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


## universal 产物名: lib<名>.macos.<debug|release>.universal.dylib(lipo 合并输出, 发布素材)
func _universal_file(target: String, type: String) -> String:
	return "lib%s.macos.%s.universal.dylib" % [target, type]


## lipo 合并: 同类型多架构产物 → universal 单文件, 成功后**删除输入架构文件**
## (universal 为最终形态, 声明由 _gdext_adopt_universal 切到 universal 键; 输入由下次构建重新直出)。
## Godot 官方引擎发布即此做法: 各架构独立构建(保留各自 -march 优化)后合并。
## macOS 自带 lipo(Xcode CLT); 非 macOS / 单架构时跳过。失败返回 ""(不影响独立产物)。
func _lipo_merge(info: Dictionary, target: String, type: String, files: Array) -> String:
	if _os_label() != "macos" or files.size() < 2:
		return ""
	var out_dir: String = info.get("out_dirs", [])[0]
	var out_name := _universal_file(target, type)
	var out_abs := String(out_dir).path_join(out_name)
	var args := PackedStringArray(["-create"])
	for f in files:
		args.append(String(out_dir).path_join(String(f)))
	args.append_array(["-output", out_abs])
	DirAccess.remove_absolute(out_abs)   # lipo 不覆盖已存在输出
	var out: Array = []
	if OS.execute("lipo", args, out, true) != 0:
		_log("lipo 合并失败(不影响各架构独立产物): ", " ".join(out))
		return ""
	_log("lipo 合并完成: ", _abs_to_res(out_dir).path_join(out_name), " ← ", ", ".join(files))
	var removed := 0
	for f in files:
		var in_abs := String(out_dir).path_join(String(f))
		if FileAccess.file_exists(in_abs) and DirAccess.remove_absolute(in_abs) == OK:
			removed += 1
		else:
			_log("警告: 架构产物删除失败(可能被占用, 可手动删除): ", String(f))
	if removed > 0:
		_log("已删除合并输入架构产物 %d 项(universal 为最终形态)。" % removed)
	return _abs_to_res(out_dir).path_join(out_name)


## 声明切换 universal: 合并成功后调用 —— 本平台+本类型的架构专属键改写/删除, 统一为
## "<平台>.<类型>.universal = universal 产物路径"(Godot 4.4+ 支持加载 universal 标签;
## universal 与架构键同声明会触发引擎重复库警告, 故架构键必须移除)。
## 首个架构键行原位改写为 universal 键(行数不变、无空行残留), 其余架构键行删除。
func _gdext_adopt_universal(gdext_res: String, platform: String, type: String, uni_res: String) -> void:
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var lines: PackedStringArray = parsed["lines"]
	var uni_key := "%s.%s.universal" % [platform, type]
	var value := "\"%s\"" % uni_res
	var uni_line := -1        # 已有 universal 键的行号
	var first_arch_line := -1 # 首个架构专属键行号(无 universal 键时改写为 universal 键)
	var remove_lines := {}    # 待删除的架构键行号
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		var tags := key.split(".")
		if tags.is_empty() or tags[0] != platform:
			continue
		var has_type := false
		var has_arch := false
		for t in tags:
			if GDEXT_TYPES.has(t):
				has_type = true
			elif GDEXT_ARCHS.has(t):
				has_arch = true
		if not has_type or not tags.has(type) or not has_arch:
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
	if uni_line >= 0:
		target_line = uni_line
		write_key = uni_key
		if first_arch_line >= 0:
			remove_lines[first_arch_line] = true   # universal 键已存在时, 残留架构键一并删除(指向文件已合并删除)
	elif first_arch_line >= 0:
		target_line = first_arch_line
		write_key = uni_key
	if target_line >= 0:
		if String(lines[target_line]) == "%s = %s" % [write_key, value]:
			_log("声明已一致, 无需同步: ", String(gdext_res).get_file(), " [", uni_key, "]")
		else:
			lines[target_line] = "%s = %s" % [write_key, value]
			_synced.append("%s → %s(切换 universal)" % [uni_key, uni_res])
			_log("已同步声明(切换 universal): ", gdext_res, " [", uni_key, "] = ", value)
	else:
		lines.insert(int(parsed["lib_end"]), "%s = %s" % [uni_key, value])
		_synced.append("%s → %s(新增)" % [uni_key, uni_res])
		_log("已同步声明(新增): ", gdext_res, " [", uni_key, "] = ", value)
	var out: Array[String] = []
	for i in lines.size():
		if remove_lines.has(i):
			continue   # 删除多余架构键行
		out.append(String(lines[i]))
	var f := FileAccess.open(gdext_res, FileAccess.WRITE)
	if f == null:
		_log("声明写回失败: ", gdext_res)
		return
	f.store_string("\n".join(out))
	f.close()


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


## 实盘扫描: 输出目录里的动态库(dylib/dll/so), 取 mtime 最新 —— 覆盖 CMake 默认名/变量拼接名等
## 解析器无法预知的直出名(刚编译完, 最新即本次直出)。返回文件名, 无动态库返回 ""。
func _scan_dynamic_libs(dir_path: String) -> String:
	var best := ""
	var best_m := -1
	var dir := DirAccess.open(String(dir_path))
	if dir == null:
		return ""
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if not dir.current_is_dir():
			var low := e.to_lower()
			if low.ends_with(".dylib") or low.ends_with(".dll") or low.ends_with(".so"):
				if e.contains(".universal."):
					e = dir.get_next()
					continue   # universal 合并产物不是构建直出物, 不参与实盘兜底
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
## template_debug/template_release 等其他体系键不视为目标(不更新、不冲突)。
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
	# 键无架构 tag(通用键) → 仅 universal 产物可写(单架构产物写通用键会破坏其他架构)。
	if not arch_tags.is_empty():
		return arch_tags.has(arch)
	return arch == "universal"


## 从规范名/声明值文件名中提取架构 tag(无架构段返回 "")
static func _file_arch(file: String) -> String:
	var re := RegEx.new()
	re.compile("\\.(arm64|x86_64|arm32|x86_32|universal)\\.")
	var m := re.search(file)
	return m.get_string(1) if m != null else ""


## 声明同步: 以实盘产物为准, 把 [libraries] 里"本平台+本类型"的键值写成产物路径。
## 已有匹配键 → 只更新值(键名与其架构 tag 风格保持不动); 值已一致则不写(零 diff);
## 无匹配键 → 按 "<平台>.<类型>[.<文件名内架构>]" 新增(引擎特性匹配要求键 tags ⊆ 当前 features,
## 缺架构 tag 的键对同平台各架构通用, 故自动新增也不锁死架构)。
func _gdext_sync(gdext_res: String, file_res: String, platform: String, type: String, file: String) -> void:
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var lines: PackedStringArray = parsed["lines"]
	var found_key := ""
	var found_line := -1
	var found_val := ""
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		if _gdext_key_matches(key, platform, type, _file_arch(file)):
			found_key = key
			found_line = int(ent.get("line"))
			found_val = String(parsed["values"].get(key, ""))
			break
	var value := "\"%s\"" % file_res
	if found_line >= 0:
		if found_val == file_res:
			_log("声明已一致, 无需同步: ", String(gdext_res).get_file(), " [", found_key, "]")
			return
		lines[found_line] = "%s = %s" % [found_key, value]
		_synced.append("%s → %s(更新)" % [found_key, file_res])
		_log("已同步声明(更新): ", gdext_res, " [", found_key, "] = ", value)
	else:
		var arch := _file_arch(file)
		var new_key := "%s.%s" % [platform, type]
		if arch != "":
			new_key += "." + arch
		var at: int = parsed["lib_end"]
		while at > 0 and String(lines[at - 1]).strip_edges() == "":
			at -= 1
		lines.insert(at, "%s = %s" % [new_key, value])
		_synced.append("%s → %s(新增)" % [new_key, file_res])
		_log("已同步声明(新增): ", gdext_res, " [", new_key, "] = ", value)
	var f := FileAccess.open(gdext_res, FileAccess.WRITE)
	if f == null:
		_log("声明写回失败: ", gdext_res)
		return
	f.store_string("\n".join(lines))
	f.close()


## sync 关闭时的退化模式: 只校验不回写 —— 声明与实盘不一致时明确告警(引擎将加载失败)。
func _gdext_verify(gdext_res: String, platform: String, type: String, file: String) -> void:
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var seen := false
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		if not _gdext_key_matches(key, platform, type, _file_arch(file)):
			continue
		seen = true
		var declared := String(parsed["values"].get(key, "")).get_file()
		if declared != file:
			_log("警告: 声明不一致 —— [", key, "] 指向 ", declared, ", 实际产物 ", file, "; 引擎可能无法加载!")
			_log("可开启 dev_framework/gdextension_build/sync_gdextension 自动对齐, 或修正 CMakeLists OUTPUT_NAME。")
		break
	if not seen:
		_log("警告: ", String(gdext_res).get_file(), " 缺少 [", platform, ".", type, "] 声明键, 引擎可能无法加载本产物(开启 sync 可自动补齐)。")


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


## 本机架构名(构建缓存目录隔离用; universal 编辑器二进制用 uname 探测真实运行架构)
func _arch() -> String:
	var arch := Engine.get_architecture_name().to_lower()
	if arch != "universal":
		return arch
	# universal 二进制无法从引擎 API 得知真实运行架构: 在 Apple Silicon 上归一为 x86_64
	# 会构建出宿主无法加载的库, 故用 uname 探测硬件架构(arm64/x86_64), 失败才回退旧规则
	if OS.get_name() == "macOS":
		var out: Array = []
		if OS.execute("uname", PackedStringArray(["-m"]), out) == 0 and not out.is_empty():
			var host := String(out[0]).strip_edges().to_lower()
			if host == "arm64" or host == "x86_64":
				return host
	return "x86_64"


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
	if f == null:
		f = FileAccess.open(_log_path(), FileAccess.WRITE)   # 文件不存在时先创建(READ_WRITE 不建文件)
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
