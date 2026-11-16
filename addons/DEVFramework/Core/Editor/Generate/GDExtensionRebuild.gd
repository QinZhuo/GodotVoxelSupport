@tool
class_name GDExtensionRebuild
extends EditorScript

## 通用 GDExtension 一键构建工具 —— 零配置构建 + 规范命名部署, 支持任何 godot-cpp 生态扩展。
## -march, fat binary 只能用默认基线)。声明键保持架构专属不动: universal 与架构键同时声明会触发
## 源码目录: 唯一工程根 res://gdextension(不存在才扫 addons/*/);
## 唯一可能的全量 = 首次构建 or 本地彻底无绑定快照时的一次性对齐(之后回归纯增量)。

const KEY_UPDATE_SUBMODULE := "dev_framework/gdextension_build/auto_update_submodule"
const KEY_RELOAD_EDITOR := "dev_framework/gdextension_build/auto_reload_editor"
const KEY_SYNC_GDEXT := "dev_framework/gdextension_build/sync_gdextension"   # 部署后把实盘产物路径回写 *.gdextension([libraries])
const KEY_CROSS_ARCHS := "dev_framework/gdextension_build/cross_archs"       # macOS 按声明自动交叉补缺架构
const GDEXT_TYPES := ["debug", "release", "template_debug", "template_release"]   # 声明键中的构建类型 tag
const GDEXT_ARCHS := ["arm64", "x86_64", "arm32", "x86_32", "universal"]          # 声明键/规范名中的架构 tag
const KEY_STALL_KILL := "dev_framework/gdextension_build/stall_auto_kill"   # 检测到卡死(无新目标且无编译器进程)时自动终止进程树
const KEY_HARD_TIMEOUT := "dev_framework/gdextension_build/hard_timeout_sec"  # 零推进多久判死(秒, 0=关闭)
const KEY_JOBS := "dev_framework/gdextension_build/build_jobs"        # 并行度, 0=自动(默认16; 设小可降并发防卡)
const KEY_BUILD_TYPES := "dev_framework/gdextension_build/build_types"   # 要构建的构建类型(Array[String], 如 ["release"]=仅 release); 空=当前编辑器类型+另一版本
# 目标名不再可配: 统一由"插件名/插件内已有 .gdextension 文件名"决定(NativeScaffold._plugin_target)
const SCAFFOLD_PATH := "res://addons/DEVFramework/Core/Editor/Generate/NativeScaffold.gd"
## 唯一构建区: 项目根 res://gdextension/(CMakeLists + godot-cpp + 构建缓存)。
## 插件源码一律在 addons/<插件>/Native/src, 由生成的 CMakeLists 引用。
const BUILD_ZONE := "res://gdextension"


## 所有插件的原生源码目录: <插件>/Native/src(每插件一库, 共用 godot-cpp)。
## 旧布局则退回 res://gdextension/src —— 只扫 src, 绝不能扫 gdextension/ 根
## (godot-cpp 就在旁边, 扫进去会把第三方的 36 个 .cpp 当成"我们的源码"判新鲜度)。
static func native_source_dirs() -> Array[String]:
	var out: Array[String] = []
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	var scaf: GDScript = load(SCAFFOLD_PATH) as GDScript
	if scaf != null:
		for p in scaf.discover_plugins(root):
			out.append("res://" + String(p["src_abs"]).replace(root, "").replace("\\", "/").trim_prefix("/"))
	return out


static func _native_src_mtime(exts: PackedStringArray) -> int:
	var ms := 0
	for d in native_source_dirs():
		for f in FileTool.list_files(d, exts):
			ms = maxi(ms, int(FileAccess.get_modified_time(f)))
	return ms

## 异步构建轮询节拍: 每 0.2s 一拍; 下面所有间隔都按"拍"从秒换算, 改节拍即整体缩放
const POLL_INTERVAL_SEC := 0.2
const TICKS_PER_SEC := 5                                      # = 1 / POLL_INTERVAL_SEC
const DISK_REPORT_SEC := 2                                    # 磁盘产物进度上报间隔(秒)
const HEARTBEAT_INTERVAL_SEC := 10                            # 输出静默后的心跳间隔(秒)
const DISK_REPORT_TICKS := DISK_REPORT_SEC * TICKS_PER_SEC     # 10 拍
const HEARTBEAT_SILENT_TICKS := HEARTBEAT_INTERVAL_SEC * TICKS_PER_SEC   # 50 拍
const STALL_TIMEOUT_SEC := 500                                # 无新目标累计 500s 且无编译器进程 → 判卡死
## 兜底硬超时: 不看进程表, 只要这么久零新目标就判死并终止。正常编译再慢也会推进,
## 零推进只可能是被挂住的进程句柄/杀软锁文件 —— 这条兜底专治"进程已死但 is_process_running 仍为 true"。
const HARD_TIMEOUT_SEC := 600
const MIN_JOBS := 2                                           # 自动并行度下限
const MAX_JOBS := 16                                          # 自动并行度上限

static var _me: GDExtensionRebuild   # 异步构建期间持有自身(菜单调用方不持有实例)

var _lines: Array[String] = []
var _cache_dirty := false   # submodule 检出变化 → 构建缓存作废, 需重新配置
var _start_ms := 0
var _raw_log_pos := 0       # raw_build.log 尾部读取游标
var _total_targets := -1    # 编译目标总数缓存(Makefile 解析, -1=未解析)
var _objects_logged := 0    # 上次打印磁盘进度时的目标数(≥30 才刷一行)
var _build_started_unix := 0.0   # 本次编译启动时刻(Unix 秒): 判定默认名产物是否"本次链接", 防部署残留旧库冒充新产物

var _prev_done_count := -1  # 上次心跳时的目标数(判断是否还在推进)
var _no_advance := 0        # 目标数无推进的累计秒(心跳间隔 10s)
var _stall_checked := false # 卡死检测已判定并处理
var _stall_killed := false  # 已自动终止卡死进程树
var _synced: Array[String] = []   # 本次运行同步的声明条目(最终摘要展示)
var _build_types: Array[String] = []   # 本次实际要构建的构建类型(由配置决定, 部署保活/清理据此收敛)
var _plugin_filter := "all"   # 只构建某个原生目标(插件 target 名); "all"/"" = 全部


func _run() -> void:
	_me = self
	_start_ms = Time.get_ticks_msec()
	var cache_dir := _abs("res://.godot/gdextension_build")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	_state_write("构建进行中: 检查原生工程骨架…")
	_log("━━━━ GDExtension 一键构建 ━━━━")
	# 零配置: gdextension/src 下只要有 .cpp, 就把 CMakeLists / godot-cpp / 自动注册 / 声明补齐
	_ensure_scaffold()
	_state_write("构建进行中: 定位扩展…")
	var loc := _locate()
	if loc.is_empty():
		return _finish()
	var source_dir: String = loc.get("source")
	var all_targets: Array = loc.get("targets")
	if all_targets.is_empty():
		return _finish()
	var targets: Array = filter_targets(all_targets, _plugin_filter)
	if targets.is_empty():
		var names: Array[String] = []
		for tg in all_targets:
			var n := String(tg.get("target", ""))
			if not names.has(n):
				names.append(n)
		return _finish_with("没有名为 '%s' 的原生目标, 可选: %s" % [_plugin_filter, ", ".join(names)])
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
	var gdext_by_target: Dictionary = loc.get("gdext_by_target", {})
	var done: Array[String] = []
	# 分组键 = "<target>|<type>": 多插件时每个插件的产物/声明必须各自成组,
	# 只按 type 做键会把两个插件的文件混在一起(lipo 会把别家的库当自己的架构产物、同步会写错声明)。
	var groups: Dictionary = {}       # key -> 已部署文件名列表
	var group_out: Dictionary = {}    # key -> 输出目录
	var group_gdext: Dictionary = {}  # key -> 该插件的 .gdextension(res://)
	for tg in targets:
		var type := String(tg.get("type"))
		var arch := String(tg.get("arch"))
		var tgt := String(tg.get("target", ""))
		var out_dir := String(tg.get("out_dir", ""))
		var target_res := String(tg.get("artifact"))
		_log("──── %s / %s / %s ────" % [tgt, type, arch])
		var build_dir := _pick_build_dir(source_dir, type, arch)
		if build_dir.is_empty():
			return _finish()
		_state_write("构建进行中(%s.%s): 配置 CMake…" % [type, arch])
		if not _ready_build_dir(build_dir, source_dir, info, type, arch):
			return _finish_with("CMake 配置失败(%s.%s)" % [type, arch])
		# 断点续跑: 上次"编译完成但没走到部署"(编辑器脚本重载会取消挂起的协程, state 会停在
		# "编译中"; 实测踩过两次)。产物已比已部署库新且不比源码旧 → 直接部署, 不要白编一轮。
		if _up_to_date(target_res, out_dir, tgt):
			# 无源码变更: 不调 cmake/make —— 否则会因"直出产物已被改名"而必然重链,
			# 既白花时间, 又让产物字节每次都变(让人误以为"没改代码却变了")。
			_log("源码与构建配置均未变更, 跳过编译(产物保持原样): ", _canonical_file(tgt, type, arch))
		elif _artifact_ready(info, type, arch, target_res, out_dir, tgt):
			_log("产物已是最新(上次构建未完成部署), 跳过编译: ", _canonical_file(tgt, type, arch))
		else:
			var only := "" if String(_plugin_filter).strip_edges().to_lower() in ["", "all"] else tgt
			var ok := await _build(build_dir, type, only)
			if not ok:
				return _finish_with("编译失败(%s.%s, 查看 build.log)" % [type, arch])
		var actual := _deploy(target_res, info, type, arch, out_dir, tgt)
		if actual == "":
			return _finish_with("产物部署失败(%s.%s, 查看 build.log)" % [type, arch])
		done.append(target_res)
		var key := "%s|%s" % [tgt, type]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(actual)
		group_out[key] = out_dir
		group_gdext[key] = String(gdext_by_target.get(tgt, ""))
	# 每个 (插件, 类型) 一组: 多架构产物齐 → lipo 合并 universal → 同步该插件自己的声明
	var platform := _os_label()
	for key in groups:
		var parts := String(key).split("|")
		var tname := parts[0]
		var btype := parts[1]
		var files: Array = groups[key]
		var gd := String(group_gdext.get(key, ""))
		var odir := String(group_out.get(key, ""))
		if gd == "":
			_log("插件 %s 的产物目录未发现 *.gdextension, 跳过声明同步。" % tname)
			continue
		var uni := _lipo_merge(odir, tname, btype, files)
		if uni != "":
			done.append(uni)
			if _opt(KEY_SYNC_GDEXT, true):
				_gdext_adopt_universal(gd, platform, btype, uni)
			else:
				_log("警告: 声明未指向 universal(%s.%s), 请切换 %s.%s.universal 键或开启 sync_gdextension。" % [btype, btype, platform, btype])
			continue
		for f in files:
			var fname := String(f)
			# 规范名用作"同一个库的另一种名字"判据(回退部署时尤其重要)
			var fa := _file_arch(fname)
			if fa == "":
				fa = _arch()
			var canon := _canonical_file(tname, btype, fa)
			if _opt(KEY_SYNC_GDEXT, true):
				_gdext_sync(gd, _abs_to_res(odir).path_join(fname), platform, btype, fname, canon)
			else:
				_gdext_verify(gd, platform, btype, fname)
	# 终清: 逐插件清理(白名单取并集, 绝不跨插件误删)
	_final_cleanup(targets, gdext_by_target)
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


# ============================================================
# 可编程入口 (MCP build_native / CI 复用)
# 构建流程只此一份: 菜单 _run() 与 build_now() 走同一套, 不要在调用方重写。
# ============================================================

const STATE_PATH := "res://.godot/gdextension_build/state.txt"
const SUMMARY_PATH := "res://.godot/gdextension_build/last_build.txt"


## 跑完整流程并等它结束: {ok, summary, state}。
## [param restart] 完成后是否自动重载编辑器 —— Windows 上编辑器锁着 dll 时, 部署会退化成
## "改写 .gdextension 指向新产物", 只有重载编辑器才会真正加载新库。
## [param plugin] 只构建某个原生目标(插件 target 名); "all"/"" = 全部。
static func build_now(restart := false, plugin := "all") -> Dictionary:
	var started := int(Time.get_unix_time_from_system())
	var prev_reload := bool(ProjectSettings.get_setting(KEY_RELOAD_EDITOR, true))
	ProjectSettings.set_setting(KEY_RELOAD_EDITOR, restart)
	var inst := GDExtensionRebuild.new()
	inst._plugin_filter = plugin
	await inst._run()
	ProjectSettings.set_setting(KEY_RELOAD_EDITOR, prev_reload)
	var summary := FileTool.read_text(SUMMARY_PATH)
	# 摘要必须是**本次**构建写的: 卡死/异常退出时旧摘要还留在盘上,
	# 不校验新鲜度就会把上一次的成功当成这一次的成功(实测踩过)。
	var ts := 0
	if FileAccess.file_exists(SUMMARY_PATH):
		ts = int(FileAccess.get_modified_time(SUMMARY_PATH))
	var fresh := ts >= started
	return {
		"ok": fresh and summary.contains("构建成功"),
		"summary": summary if fresh else "(本次构建没有产出摘要, 视为失败; 详见 build.log)",
		"state": FileTool.read_text(STATE_PATH),
		"log": "res://.godot/gdextension_build/build.log",
	}


## 原生源码是否比已部署的库新 —— "改了 C++ 却没重编"的检测点(测试与 MCP 共用)。
## 只比时间戳: 源码树与产物足以判定, 不需要额外的指纹文件。
static func native_status() -> Dictionary:
	var src_ms := _native_src_mtime(PackedStringArray([".cpp", ".h", ".hpp"]))
	var lib_ms := 0
	var lib := ""
	for f in FileTool.list_files("res://addons/DEVFramework/Native", PackedStringArray([".dll", ".so", ".dylib"])):
		var ms := int(FileAccess.get_modified_time(f))
		if ms > lib_ms:
			lib_ms = ms
			lib = f
	# 逐插件新鲜度: 多插件时"哪个插件旧了"比一个全局布尔有用得多
	var per_target: Array = []
	var scaf: GDScript = load(SCAFFOLD_PATH) as GDScript
	if scaf != null:
		var root := ProjectSettings.globalize_path("res://").simplify_path()
		for p in scaf.discover_plugins(root):
			var src_abs := String(p["src_abs"])
			var nat_abs := String(p["native_abs"])
			var s_ms := 0
			for f in FileTool.list_files(src_abs, PackedStringArray([".cpp", ".h", ".hpp", ".c"])):
				s_ms = maxi(s_ms, int(FileAccess.get_modified_time(f)))
			var l_ms := 0
			for f in FileTool.list_files(nat_abs, PackedStringArray([".dll", ".so", ".dylib"])):
				l_ms = maxi(l_ms, int(FileAccess.get_modified_time(f)))
			per_target.append({
				"target": String(p["target"]), "plugin": String(p["plugin"]),
				"stale": s_ms > 0 and l_ms > 0 and s_ms > l_ms,
				"source_ms": s_ms, "lib_ms": l_ms,
			})
	return {
		"targets": per_target,
		"source_ms": src_ms,
		"lib_ms": lib_ms,
		"lib": lib,
		"has_native": src_ms > 0,
		# 没有原生源码(纯 GDScript 项目)或还没编过产物时不算 stale, 免得误报
		"stale": src_ms > 0 and lib_ms > 0 and src_ms > lib_ms,
	}


## 提前失败收尾: 记录摘要与状态, 并弹编辑器提示
func _finish_with(result: String) -> void:
	_summary_write("%s\n日志: res://.godot/gdextension_build/build.log\n修复后再次运行即可重试。" % result)
	_state_write(result)
	_toast("GDExtension 构建失败: " + result)
	_finish()


# ------------------------------------------------------------ 零配置定位

## 定位构建目标 —— 只需 CMakeLists 给出 目标名 + 输出目录:
func _locate() -> Dictionary:
	# 唯一构建区: 项目根 gdextension/(CMakeLists + godot-cpp)。
	# 插件源码在 addons/<插件>/Native/src —— 两者分工固定, 不再支持其它历史布局。
	var source_dir := BUILD_ZONE
	if not _is_ext_source(source_dir):
		_log("未找到原生构建区: 需要 %s/CMakeLists.txt + godot-cpp/。插件源码放 addons/<插件>/Native/src, 构建脚本会自动生成骨架。" % BUILD_ZONE)
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
	# 否则消费方会用自己 CMakeLists 里的规则重编同一批源码: 产物互相覆盖, 还会多出 debug 版本
	# (实测 SoL 构建把 DEVFramework 的 release 库换成了非优化版本, 帧耗涨 10 倍)。
	# 不做"谁才能构建"的限制: 任何项目触发构建, 都按同一套规则产出同名同规格的库。
	for tgt in names:
		var od: String = String(outputs.get(tgt, ""))
		for t in types:
			for a in archs:
				var art := _expected_artifact(info, t, a, od, String(tgt))
				if art.is_empty():
					_log("CMakeLists.txt 无法推导产物: 需要 add_library(<name> SHARED) 与 *_OUTPUT_DIRECTORY 直出目录。")
					return {}
				targets.append({"target": String(tgt), "type": t, "arch": a,
						"artifact": String(art.get("res")), "out_dir": od})
	# 每个 target 自己的声明(多插件时不能共用一份)
	var gdext_by_target := {}
	for tgt in names:
		gdext_by_target[String(tgt)] = _find_gdextension_for(String(tgt), String(outputs.get(tgt, "")), info)
	_log("已锁定(CMake 推导): ", source_dir, " 目标: ", ", ".join(PackedStringArray(names)))
	for tg in targets:
		_log("预期产物(%s,%s.%s): %s" % [String(tg.get("target")), String(tg.get("type")),
				String(tg.get("arch")), String(tg.get("artifact"))])
	return {"source": source_dir, "targets": targets, "info": info,
			"gdext": gdext_by_target.get(names[0], ""), "gdext_by_target": gdext_by_target}


## 不做"谁能构建"的限制: 任何项目触发构建都产出同名同规格的库。
## 一致性靠"所有项目的 CMakeLists 都由 NativeScaffold 统一生成"来保证, 而不是靠归属白名单。


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


## 工具规范产物名: lib<名>.<平台>.<debug|release>.<架构>.<ext>
## 全平台统一带 lib 前缀 —— 与 godot-cpp 官方模板一致(libgdexample.windows.release.x86_64.dll),
## 也和 CMake/MinGW 的 SHLIBPREFIX 默认值一致, 于是不需要 PREFIX "" 这种平台特例。
## (GDExtension 对文件名没有硬性要求, 唯一硬约束是[库名]与 .gdextension 的 [libraries] 一字不差。)
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


# ------------------------------------------------------------ 读 CMakeLists 分辨"如何构建"(三个高可信 token)

## 返回 {target, out_dirs(绝对), api_default, output_name(当前平台+类型), output_names(全量)}。
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
	re_out.compile("(?:LIBRARY|RUNTIME|ARCHIVE)_OUTPUT_DIRECTORY\\s+([^\\s#)]+)")
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

	# 多 target(每个原生插件一个): 记录 target -> 输出目录。部署/声明同步按 target 分别落位,
	# 否则多插件工程只有第一个目标会被正确命名与校验(其余产物留在目录里但没人管)。
	info.outputs = parse_target_outputs(text, _abs(project_dir))

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
## 按 `add_library(<name>` 分段, 只取该段之后的 `*_OUTPUT_DIRECTORY` —— 多插件时每个 target
## 的产物落在自己的 Native 目录, 部署/清理/声明同步都依赖这份映射。
static func parse_target_outputs(text: String, cmake_dir_abs: String) -> Dictionary:
	var re_out := RegEx.new()
	# 排除右括号: 单行写法 `set_target_properties(X PROPERTIES RUNTIME_OUTPUT_DIRECTORY <path>)` 里
	# 路径后面紧跟 `)`, 不排除就会把括号当成路径的一部分(实测踩过, 部署会去找不存在的目录)。
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


# ------------------------------------------------------------ 工具链探测与构建目录

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
			_log("PATH 中缺少 ", ", ".join(missing), ", 也未发现常见 MinGW/w64devkit。可设环境变量 MINGW_HOME/W64DEVKIT_HOME 指向工具根目录, 或安装 w64devkit。")
			return
		if OS.get_environment("PATH").split(";", false).has(bin_dir):
			_log("工具链目录已在 PATH 中但仍缺少 ", ", ".join(missing), ", 请检查该目录内容: ", bin_dir)
			return
		OS.set_environment("PATH", "%s;%s" % [bin_dir, OS.get_environment("PATH")])
		_log("已把 MinGW 加入本次构建 PATH: ", bin_dir)


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
	return _find_exe_dir("g++.exe")


## 构建根目录下全部 CMakeCache.txt —— 缓存里的绝对路径是工具链最权威的线索
func _cache_files() -> Array[String]:
	var out: Array[String] = []
	var stack: Array[String] = [_abs("res://.godot/gdextension_build")]
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


## 通用可执行文件定位 —— 跨平台、不写死用户名/机器路径:
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


## 零配置骨架: 只要 res://gdextension/src 下有 .cpp, 就把构建需要的一切补齐。
## 只补缺失项(见 NativeScaffold): 手写 CMakeLists 的工程完全不受影响。
func _ensure_scaffold() -> void:
	# 多插件: 每个 addons/<Plugin>/Native/src 有 .cpp 就算一个插件, 各编一个库(共用 godot-cpp)。
	# 用 load 而不是全局类名: 新增的 class_name 要等编辑器重载脚本缓存才可见,
	# 而构建工具经常在"刚加完文件"的状态下被调用(与 ECSNative.instantiate_script 同一个理由)。
	var scaf: GDScript = load(SCAFFOLD_PATH) as GDScript
	if scaf == null:
		_log("警告: NativeScaffold 脚本缺失, 跳过骨架生成。")
		return
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	var res: Dictionary = scaf.ensure_project(root, _engine_api_hint(), true,
			func(msg: String) -> void: _log(msg))
	var plugins: Array = res.get("plugins", [])
	if plugins.is_empty():
		return
	var names: Array[String] = []
	for p in plugins:
		names.append("%s(%s)" % [String(p["plugin"]), String(p["target"])])
	_log("原生插件 %d 个: %s" % [plugins.size(), ", ".join(names)])
	var created: Array = res.get("created", [])
	for item in created:
		_log("骨架自动生成: ", String(item))
	# 跨插件同名类会让引擎在加载时报难以定位的错, 提前判出
	var conflicts: Array = res.get("conflicts", [])
	for c in conflicts:
		_log("错误: 类名 %s 同时出现在插件 %s —— 同进程注册同名类会冲突, 请改名。" % [
			String(c["name"]), ", ".join(c["targets"])])


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


func _sync_godot_cpp(source_dir: String) -> void:
	var vi: Dictionary = Engine.get_version_info()
	var engine_api := "%d.%d" % [int(vi.get("major", 4)), int(vi.get("minor", 0))]
	var def_api := _cmake_api_default(source_dir)
	# 核心原则 —— 只要有"可编译"的本地快照(CMakeLists 钉版, 或引擎回退版), 就绝不动 submodule:
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
func _pick_build_dir(source_dir: String, type: String, arch: String) -> String:
	var cache_root := _abs("res://.godot/gdextension_build")
	var dir := cache_root.path_join("%s-%s-%s-%s" % [source_dir.get_file(), _os_label(), arch, type])
	if not FileAccess.file_exists(dir.path_join("CMakeCache.txt")):
		_log("未发现(%s.%s)已配置构建缓存, 将新建: " % [type, arch], dir)
	return dir


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
			# 工具链存活: 缓存里记的是绝对路径, 换机器/重装工具链后即失效, 必须作废重配
			var dead_tc := _dead_toolchain_paths(build_dir)
			if cached_type == type and cached_arch == arch and dead_tc.is_empty():
				_log("复用构建目录(以缓存配置为准): ", build_dir)
				_ensure_ccache(build_dir)
				return true
			if not dead_tc.is_empty():
				_log("缓存工具链已失效(", ", ".join(dead_tc), "), 作废重新配置。")
			else:
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
	# ccache: godot-cpp 的绑定生成器是 custom target(每次都重写 gen/*, 内容通常不变),
	# 没有编译缓存时"改一个 .cpp"会连带重编 1000+ 个 gen 目标; 有 ccache 则整批命中。
	var cc := _ccache_exe()
	if cc != "":
		args.append("-DCMAKE_CXX_COMPILER_LAUNCHER=%s" % cc)
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
		_log("已为现有构建缓存启用编译缓存(ccache): 下次构建起生效。")
	else:
		_print_out(out)


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


# ------------------------------------------------------------ 异步构建

## 按插件/目标名过滤构建目标(纯函数, 便于测试): "all"/"" = 全部; 否则大小写不敏感匹配 target 名。
static func filter_targets(targets: Array, plugin: String) -> Array:
	var want := plugin.strip_edges().to_lower()
	if want == "" or want == "all":
		return targets
	var out: Array = []
	for tg in targets:
		if String(tg.get("target", "")).to_lower() == want:
			out.append(tg)
	return out


func _build(build_dir: String, type: String, tgt := "") -> bool:
	_log("开始编译 (%s%s)…… 编辑器保持可用, 输出实时回显。" % [type, "" if tgt == "" else ", " + tgt])
	var jobs := int(ProjectSettings.get_setting(KEY_JOBS, 0))
	if jobs <= 0:
		jobs = clampi(OS.get_processor_count(), MIN_JOBS, MAX_JOBS)
	# 子进程输出重定向到文件, 本进程定时尾读回显 —— 不经过 Godot execute_with_pipe 管道。
	var raw := _raw_log_path()
	DirAccess.remove_absolute(raw)
	_raw_log_pos = 0
	var shell := "sh"
	var run_args := PackedStringArray()
	# 指定插件时用 --target 只编那一个库(省时间); all 时一次调用编全部目标
	var tgt_arg := "" if tgt == "" else " --target %s" % tgt
	var cmd_line := "cmake --build \"%s\" --config %s --parallel %d%s > \"%s\" 2>&1" \
			% [build_dir, type.capitalize(), jobs, tgt_arg, raw]
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
	_build_started_unix = Time.get_unix_time_from_system()
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
	var hard_sec := int(ProjectSettings.get_setting(KEY_HARD_TIMEOUT, HARD_TIMEOUT_SEC))
	var exit_code := -1
	while true:
		# 结束判定必须多信号: 只靠 is_process_running 会因 pid 残留(cmd.exe 退出但句柄未回收)死等,
		# 表现就是"没有编译器进程、日志不再更新、state 卡在编译中"—— 实测踩过一次。
		exit_code = OS.get_process_exit_code(pid)
		if exit_code != -1:
			break
		if not OS.is_process_running(pid):
			exit_code = OS.get_process_exit_code(pid)
			break
		var had := _drain_log(raw)
		if had:
			silent = 0
		else:
			silent += 1
		tick += 1
		if tick % DISK_REPORT_TICKS == 0:   # 每 DISK_REPORT_SEC 秒: 磁盘产物进度(独立于输出, 兜底可量化)
			_report_disk_progress(build_dir)
		if silent >= HEARTBEAT_SILENT_TICKS and silent % HEARTBEAT_SILENT_TICKS == 0:   # 静默够久后每 HEARTBEAT_INTERVAL_SEC 秒心跳一次
			var d := _count_build_objects(build_dir)
			var t := _total_compile_units(build_dir)
			if t > 0:
				_log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d/%d 目标文件" % [silent / TICKS_PER_SEC, d, t])
			else:
				_log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d 个目标(总数未知)" % [silent / TICKS_PER_SEC, d])
			# 目标长期不增长 → 累计"无推进"时长
			if d == _prev_done_count:
				_no_advance += HEARTBEAT_INTERVAL_SEC
			else:
				_no_advance = 0
				_prev_done_count = d
			# 兜底硬超时: 无论进程表怎么说, 只要这么久一个目标都没新增就判死 ——
			# 正常编译再慢也会推进, 零推进只能是被挂住的进程句柄/杀软锁文件。
			if hard_sec > 0 and _no_advance >= hard_sec and not _stall_killed:
				_stall_checked = true
				_log_raw("硬超时: %d 秒内没有任何新目标, 判定构建卡死。" % _no_advance)
				if _stall_kill_enabled():
					_kill_build_tree(pid)
					_stall_killed = true
					_log_raw("已终止进程树(pid %d)。可直接重跑(从已编译部分继续)。" % pid)
				else:
					_log_raw("自动终止已关闭(ProjectSettings: %s=false)。请在任务管理器结束 cmake/make 后重跑。" % KEY_STALL_KILL)
				break
			# 卡死熔断: 目标长期不增长 + 无编译器子进程存活 → 构建系统在等不存在的子进程(非编译慢)
			if _no_advance >= STALL_TIMEOUT_SEC and not _stall_checked and not _stall_killed:
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
		await tree.create_timer(POLL_INTERVAL_SEC).timeout
	_drain_log(raw)   # 进程退出会 flush 全部缓冲, 收尾再读一次
	if _stall_killed:
		_log("构建已被工具终止(疑似卡死)。")
		_state_write("编译失败: 疑似卡死(已终止进程树)")
		return false
	if exit_code == -1:
		exit_code = OS.get_process_exit_code(pid)
	# 失败状态**立即**落盘: 否则调用方(build_native / 人)只能看到一个永远停在"编译中"的 state
	if exit_code != 0:
		_log("编译失败(退出码 %d), 请按上方报错定位。" % exit_code)
		_state_write("编译失败(退出码 %d)" % exit_code)
		return false
	_log("编译成功。")
	_state_write("编译完成: %s" % type)
	return true


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

## 部署: 默认名直出 → 实盘最新非常规名动态库 → 已存在规范名, 三级判定后统一**改名**为规范名
func _deploy(target_res: String, info: Dictionary, type: String, arch: String,
		out_dir_override := "", tgt := "") -> String:
	var out_dir: String = out_dir_override
	if out_dir == "" and not (info.get("out_dirs", []) as Array).is_empty():
		out_dir = String(info.get("out_dirs", [])[0])
	var target := tgt if tgt != "" else String(info.get("target", ""))
	var canonical := _canonical_file(target, type, arch)
	var actual := ""
	var direct := _default_out_file(target)   # CMake 默认直出名(刚链接, mtime 最新, 内容必然新鲜)
	# 已知命名集合 = 默认名 + 本目标全部 类型×架构 规范名: 都是"声明/最终形态"文件,
	# 不作为实盘扫描候选 —— 否则同目录其他 类型/架构 的产物(先构建的 debug 库、
	var known := PackedStringArray()
	if direct != "":
		known.append(direct)
	for t in GDEXT_TYPES:
		for a in GDEXT_ARCHS:
			known.append(_canonical_file(target, t, a))
	# 默认名命中须是"本次链接"的产物(mtime ≥ 本次编译启动): 编译器直出名与本工具约定不符时
	var direct_fresh := false
	if direct != "" and FileAccess.file_exists(String(out_dir).path_join(direct)):
		direct_fresh = FileAccess.get_modified_time(String(out_dir).path_join(direct)) + 5.0 >= _build_started_unix
	if direct_fresh:
		# 默认名存在 → 本次链接产物, 强制改名归位(覆盖可能残留的旧规范名, 杜绝陈旧命中)
		if _rename_lib(out_dir, direct, canonical):
			_log("产物规范命名: ", direct, " → ", canonical)
			actual = canonical
		else:
			_log("警告: 规范命名失败(文件可能被占用), 保留 ", direct, "; 声明同步将按实盘名对齐。")
			actual = direct
	else:
		# 默认名缺失/非本次产物 → 先实盘取本目标"最新"的非常规名动态库(刚链接完, 最新即本次
		# (CMake 钉了 OUTPUT_NAME 且刚重链)。顺序不能反: 先认"规范名已存在"会把编译器直出的
		actual = _scan_dynamic_libs(out_dir, target, known)
		if actual != "":
			_log("规范名产物未直出, 实盘取最新动态库: ", actual)
		elif FileAccess.file_exists(_abs(target_res)):
			actual = canonical   # 直出名即规范名(CMake 钉了 OUTPUT_NAME)
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


## 源码/构建配置都没变 → 本次可**完全跳过编译**。
##
## 为什么需要它: 部署会把链接器直出的 `lib<名>.dll` 改名成规范名 `lib<名>.<平台>.<类型>.<架构>.dll`,
## 于是下一次 make 发现"链接目标文件不存在"就必然重链 —— 即使一行代码没改。
## 表现就是"没改代码, 产物 mtime/字节却变了"(链接器每次输出含 build-id/时间戳, 内容必然不同),
## 而且每次白花 7~9 秒。这里用"源码 mtime ≤ 已部署产物 mtime, 且 CMakeLists 也没更新"来提前收工。
func _up_to_date(target_res: String, out_dir: String, tgt: String) -> bool:
	if not FileAccess.file_exists(_abs(target_res)):
		return false
	var deployed := int(FileAccess.get_modified_time(_abs(target_res)))
	# 源码(含 .h)比产物新 → 必须重编
	if _native_src_mtime(PackedStringArray([".cpp", ".h", ".hpp", ".c"])) > deployed:
		return false
	# 生成的 CMakeLists 变过(换模板/加插件/改参数) → 也要重配+重编
	for cfg in ["res://gdextension/CMakeLists.txt"]:
		if FileAccess.file_exists(cfg) and int(FileAccess.get_modified_time(cfg)) > deployed:
			return false
	return true


## 输出目录里是否已有一个"比已部署库新、且不比源码旧"的产物 —— 即上次编译完成但没部署。
## 两个条件缺一不可: 只比已部署库新, 改了源码也会误判为"不用编"; 只比源码新, 刚部署完也会说"要重编"。
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
	if FileAccess.file_exists(_abs(target_res)):
		deployed_ms = int(FileAccess.get_modified_time(_abs(target_res)))
	var src_ms := _native_src_mtime(PackedStringArray([".cpp", ".h", ".hpp", ".c"]))
	var best := 0
	for cand in [_default_out_file(target), _canonical_file(target, type, arch)]:
		if cand == "":
			continue
		var p := out_dir.path_join(cand)
		if FileAccess.file_exists(p):
			best = maxi(best, int(FileAccess.get_modified_time(p)))
	return best > 0 and best > deployed_ms and best >= src_ms


## CMake 默认直出名: 全平台 lib<名>.<ext>(CMake/MinGW 的 SHLIBPREFIX 默认就是 lib, 与规范名同前缀)
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


## 同目录改名。目标已存在且**正被加载**(Windows 上编辑器锁着 dll)时, 走 rename-then-replace:
## MSDN《Dynamic-Link Library Updates》的官方做法 —— 加载中的 DLL 不允许删除/覆盖, 但**允许重命名**,
## 于是把它旁置成 `<名>.old.<tick>`, 再把新产物改名到规范名。
## 这样规范名永远是最新的, 声明不用退化成"指向 libdev.dll"这种别名,
## 也就不存在"debug 键还指着旧的规范名文件 → 构建成功却跑旧库"。
## 旁置文件当次删不掉(仍被加载), 由 _cleanup_native 在下次构建(通常已重启过)时清掉。
func _rename_lib(dir_path: String, from_file: String, to_file: String) -> bool:
	var from_abs := String(dir_path).path_join(from_file)
	var to_abs := String(dir_path).path_join(to_file)
	if from_abs == to_abs:
		return true
	if FileAccess.file_exists(to_abs) and DirAccess.remove_absolute(to_abs) != OK:
		var aside := "%s.old.%d" % [to_abs, Time.get_ticks_usec()]
		if DirAccess.rename_absolute(to_abs, aside) != OK:
			return false   # 连重命名都不行: 调用方回退到"按实盘名部署 + 改写声明"
		_log("旧产物被占用, 已旁置: ", aside.get_file(), "(下次构建时清理)")
	return DirAccess.rename_absolute(from_abs, to_abs) == OK


## 终清: 全部轮次与合并完成后执行一次(轮间零清理, 合并输入绝不误删)。
## 逐插件清理: 每个 target 只清自己 Native 目录, 白名单只含自己的声明/产物,
## 否则多插件时会把别家的库当"非必要产物"删掉(实测这是最危险的一类误删)。
func _final_cleanup(targets: Array, gdext_by_target: Dictionary) -> void:
	var types: Array[String] = _build_types if not _build_types.is_empty() else ["debug", "release"]
	var seen := {}
	for tg in targets:
		var target := String(tg.get("target", ""))
		var native_dir := String(tg.get("out_dir", ""))
		var dir_key := "%s|%s" % [target, native_dir]
		if target == "" or native_dir == "" or seen.has(dir_key):
			continue
		seen[dir_key] = true
		var gdext_res := String(gdext_by_target.get(target, ""))
		var keep := _gdext_keep_files(gdext_res) if gdext_res != "" else PackedStringArray()
		keep.append(target + ".gdextension")
		for a in (["x86_64", "arm64", "arm32", "x86_32"] if gdext_res == "" else _declared_archs(gdext_res)):
			for bt in types:
				keep.append(_canonical_file(target, bt, a))
		if _os_label() == "macos":
			for bt in types:
				keep.append(_universal_file(target, bt))
		_cleanup_native(native_dir, keep)


## 某个 target 自己的声明: 优先 <输出目录>/<target>.gdextension(多插件时唯一正确),
## 找不到再退回"输出目录里的第一个"(单插件工程的既有行为)。
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


## universal 产物名: lib<名>.macos.<debug|release>.universal.dylib(lipo 合并输出, 发布素材)
func _universal_file(target: String, type: String) -> String:
	return "lib%s.macos.%s.universal.dylib" % [target, type]


## lipo 合并: 同类型多架构产物 → universal 单文件, 成功后**删除输入架构文件**
func _lipo_merge(out_dir_override: String, target: String, type: String, files: Array) -> String:
	if _os_label() != "macos" or files.size() < 2:
		return ""
	var out_dir := out_dir_override
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
## universal 与架构键同声明会触发引擎重复库警告, 故架构键必须移除)。
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
	if FileTool.atomic_write_text(gdext_res, "\n".join(out)) != OK:
		_log("声明写回失败: ", gdext_res)
		return


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


## 实盘扫描: 输出目录里"本目标"的动态库(dylib/dll/so), 取 mtime 最新 ——
func _scan_dynamic_libs(dir_path: String, target_name: String, exclude: PackedStringArray) -> String:
	var best := ""
	var best_m := -1
	var excl := {}
	for k in exclude:
		excl[k] = true
	var dir := DirAccess.open(String(dir_path))
	if dir == null:
		return ""
	dir.list_dir_begin()
	var e := dir.get_next()
	while e != "":
		if not dir.current_is_dir():
			var low := e.to_lower()
			if low.ends_with(".dylib") or low.ends_with(".dll") or low.ends_with(".so"):
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
	# 无架构 tag = 通用键(windows.release), 对本架构同样适用 —— 早先要求 "arch == universal"
	# 会让这类键永远匹配不上, 于是每次同步都**追加一条重复键**(实测写坏过 dev.gdextension)。
	if not arch_tags.is_empty():
		return arch_tags.has(arch)
	return true


## 从规范名/声明值文件名中提取架构 tag(无架构段返回 "")
static func _file_arch(file: String) -> String:
	var re := RegEx.new()
	re.compile("\\.(arm64|x86_64|arm32|x86_32|universal)\\.")
	var m := re.search(file)
	return m.get_string(1) if m != null else ""


## 声明同步: 以实盘产物为准, 把 [libraries] 里"本平台"的键值对齐到本次产物。
## 命中条件(任一):
##   · 键 = 本平台 + 本类型(+架构匹配) —— 本次构建直接负责的键;
##   · 键指向的文件**已不存在** —— 产物改名/清理后留下的悬空声明, 不自愈会让引擎加载失败;
##   · 键指向的文件就是本次产物的**规范名** —— 同一个库的另一种名字(典型: 一个产物同时供
##     debug/release 两个键)。Windows 上编辑器锁着 dll 时部署只能回退到非规范名,
##     若只改"本类型"的键, 调试版编辑器加载的 windows.debug.x86_64 会一直指向旧的规范名文件,
##     表现是"构建成功但跑的还是旧库"。
func _gdext_sync(gdext_res: String, file_res: String, platform: String, type: String, file: String,
		canonical := "") -> void:
	var parsed := _gdext_parse(gdext_res)
	if parsed.is_empty():
		return
	var lines: PackedStringArray = parsed["lines"]
	var value := "\"%s\"" % file_res
	var arch := _file_arch(file)
	var changed := false
	var touched: Array[String] = []
	for ent in parsed["entries"]:
		var key := String(ent.get("key"))
		if not key.begins_with(platform + "."):
			continue
		var declared := String(parsed["values"].get(key, ""))
		var matched := _gdext_key_matches(key, platform, type, arch)
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
		_log("声明已一致, 无需同步: ", String(gdext_res).get_file())
		return
	for k in touched:
		_synced.append("%s → %s" % [k, file_res])
		_log("已同步声明: ", gdext_res, " [", k, "] = ", value)
	if FileTool.atomic_write_text(gdext_res, "\n".join(lines)) != OK:
		_log("声明写回失败: ", gdext_res)
		return

	# 本平台没有任何可用的键(纯 CMake 新工程)才补一条; 同名键已存在时改写而非追加,
	# 否则每轮构建都会多一条重复键(实测写坏过 dev.gdextension)。
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
	_synced.append("%s → %s(新增)" % [new_key, file_res])
	_log("已同步声明(新增): ", gdext_res, " [", new_key, "] = ", value)
	if FileTool.atomic_write_text(gdext_res, "\n".join(lines)) != OK:
		_log("声明写回失败: ", gdext_res)


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


func _cleanup_native(native_dir: String, keep: PackedStringArray) -> void:
	var keep_set := {}
	for k in keep:
		keep_set[k] = true
	var dir := DirAccess.open(native_dir)
	if dir == null:
		return
	var removed := 0
	# ⚠ 必须包含隐藏文件: Windows 的 ReplaceFile 残留(`xxx.dll~RF123abc.TMP`)与部分改名旁置
	# 文件带 hidden 属性, 默认枚举会跳过它们 → 清理循环"看不见"这些垃圾(实测残留堆了十几 MB)。
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var low := entry.to_lower()
		# 垃圾文件统一规则(不限于动态库后缀):
		#   ~*            = Windows ReplaceFile 的临时残留(~xxxx.TMP), 与 ~libdev.dll 这类旁置副本
		#   *.old.*       = 被占用旧库的旁置文件(见 _rename_lib), 下次构建时已随重启释放
		#   *.dll.a       = MinGW 导入库(构建副产物, 运行时不需要)
		var is_tmp := entry.begins_with("~") or low.ends_with(".tmp") or low.ends_with(".temp") \
				or low.contains(".old.") or low.ends_with(".dll.a")
		var is_lib := low.ends_with(".dll") or low.ends_with(".so") or low.ends_with(".dylib") \
				or low.ends_with(".a") or low.ends_with(".lib")
		if not dir.current_is_dir() and not keep_set.has(entry) and (is_tmp or is_lib):
			if dir.remove(entry) == OK:
				removed += 1
				_log("清理非必要产物: ", entry)
			elif entry.begins_with("~lib"):
				# Windows 上 Godot 会把扩展库复制成 `~<原名>` 再加载(为了能覆盖原文件),
				# 这份副本被引擎进程占用, 只要编辑器活着就删不掉 —— 它不是我们的产物, 不必当失败。
				_log("跳过引擎运行期副本(重启编辑器后可清理): ", entry)
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
	if OS.get_name() == "macOS":
		var out: Array = []
		if OS.execute("uname", PackedStringArray(["-m"]), out) == 0 and not out.is_empty():
			var host := String(out[0]).strip_edges().to_lower()
			if host == "arm64" or host == "x86_64":
				return host
	return "x86_64"


func _build_type() -> String:
	return "debug" if OS.is_debug_build() else "release"


## 本次要构建的构建类型清单(配置驱动):
func _plan_build_types() -> Array[String]:
	var cfg: Array = ProjectSettings.get_setting(KEY_BUILD_TYPES, [])
	var out: Array[String] = []
	for t in cfg:
		var s := String(t).to_lower()
		if (s == "debug" or s == "release") and not out.has(s):
			out.append(s)
	if out.is_empty():
		# 统一规则: 一律 release —— 与"哪个项目触发构建"无关。
		# 曾按"当前编辑器类型"取, 于是 debug 版编辑器(如 SoL)会产出 12MB 未优化库,
		# 覆盖掉宿主项目的 1.7MB 优化库(实测帧耗涨 10 倍)。需要 debug 请显式配 build_types。
		out = ["release"]
	_build_types = out
	_log("构建类型清单: ", " ".join(out))
	return out


# ------------------------------------------------------------ 小工具

func _res(p: String) -> String:
	return FileTool.to_res_path(p)


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
	FileTool.write_text(_abs("res://.godot/gdextension_build/state.txt"), text)


## 最终摘要(成败/用时/产物/下一步): 自动重载前落盘 + 同步进 build.log/Output,
func _summary_write(text: String) -> void:
	FileTool.write_text(_abs("res://.godot/gdextension_build/last_build.txt"), text)
	for line in text.split("\n"):
		if line != "":
			_log_raw(line)


func _finish() -> void:
	var tail := "━ 完成(共 %d 行输出, 日志: res://.godot/gdextension_build/build.log) ━" % _lines.size()
	_log(tail)
	_state_write("done")
	_me = null
