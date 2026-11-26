@tool
class_name GDExtensionRebuild
extends EditorScript

const KEY_UPDATE_SUBMODULE := "dev_framework/gdextension_build/auto_update_submodule"
const KEY_RELOAD_EDITOR := "dev_framework/gdextension_build/auto_reload_editor"
const KEY_SYNC_GDEXT := "dev_framework/gdextension_build/sync_gdextension"   # 部署后把实盘产物路径回写 *.gdextension([libraries])

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

# 四个实现切片(@tool + RefCounted, 不是菜单脚本): 只由 _init_tools() 惰性装配。
var _probe: GDExtensionProbeTool
var _cmake: GDExtensionCmakeTool
var _proc: GDExtensionProcessTool
var _deploy: GDExtensionDeployTool

# 可编程入口 (MCP build_native / CI 复用)

const STATE_PATH := "res://.godot/gdextension_build/state.txt"
const SUMMARY_PATH := "res://.godot/gdextension_build/last_build.txt"

func _run() -> void:
	_me = self
	_start_ms = Time.get_ticks_msec()
	_init_tools()
	var cache_dir := _abs("res://.godot/gdextension_build")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	_state_write("构建进行中: 检查原生工程骨架…")
	_log("━━━━ GDExtension 一键构建 ━━━━")
	# 零配置: gdextension/src 下只要有 .cpp, 就把 CMakeLists / godot-cpp / 自动注册 /…
	_cmake._ensure_scaffold()
	_state_write("构建进行中: 定位扩展…")
	var loc := _probe._locate()
	if loc.is_empty():
		return _finish()
	var source_dir: String = loc.get("source")
	var all_targets: Array = loc.get("targets")
	if all_targets.is_empty():
		return _finish()
	var targets: Array = GDExtensionProcessTool.filter_targets(all_targets, _plugin_filter)
	if targets.is_empty():
		var names: Array[String] = []
		for tg in all_targets:
			var n := String(tg.get("target", ""))
			if not names.has(n):
				names.append(n)
		return _finish_with("没有名为 '%s' 的原生目标, 可选: %s" % [_plugin_filter, ", ".join(names)])
	_log("源码工程: ", source_dir)

	if not _cmake._precheck(source_dir):
		return _finish_with("定位/工具链失败")
	# 编译器 PATH 引导: 编辑器进程常不带 MinGW, 探测常见安装并注入本次进程环境
	_cmake._ensure_toolchain_env()
	# 自动同步 godot-cpp(仅当本地缺少所需绑定快照时才走网络, 避免每次拉取/全量重建)
	if _opt(KEY_UPDATE_SUBMODULE, true):
		_state_write("构建进行中: 同步 godot-cpp…")
		await _cmake._sync_godot_cpp(source_dir)
	# 双版本 × 架构依次: 配置 → 编译 → 部署验证 (当前编辑器类型+本机架构先行, 编辑器尽快可用)
	var info: Dictionary = loc.get("info")
	var gdext_by_target: Dictionary = loc.get("gdext_by_target", {})
	var done: Array[String] = []
	# 分组键 = "<target>|<type>": 多插件时每个插件的产物/声明必须各自成组,
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
		var build_dir := _cmake._pick_build_dir(source_dir, type, arch)
		if build_dir.is_empty():
			return _finish()
		_state_write("构建进行中(%s.%s): 配置 CMake…" % [type, arch])
		if not _cmake._ready_build_dir(build_dir, source_dir, info, type, arch):
			return _finish_with("CMake 配置失败(%s.%s)" % [type, arch])
		# 断点续跑: 上次"编译完成但没走到部署"(编辑器脚本重载会取消挂起的协程, state 会停在
		if _deploy._up_to_date(target_res, out_dir, tgt):
			# 无源码变更: 不调 cmake/make —— 否则会因"直出产物已被改名"而必然重链,
			_log("源码与构建配置均未变更, 跳过编译(产物保持原样): ", _probe._canonical_file(tgt, type, arch))
		elif _deploy._artifact_ready(info, type, arch, target_res, out_dir, tgt):
			_log("产物已是最新(上次构建未完成部署), 跳过编译: ", _probe._canonical_file(tgt, type, arch))
		else:
			var only := "" if String(_plugin_filter).strip_edges().to_lower() in ["", "all"] else tgt
			var ok := await _proc._build(build_dir, type, only)
			if not ok:
				return _finish_with("编译失败(%s.%s, 查看 build.log)" % [type, arch])
		var actual := _deploy._deploy(target_res, info, type, arch, out_dir, tgt)
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
	var platform := _probe._os_label()
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
		var uni := _deploy._lipo_merge(odir, tname, btype, files)
		if uni != "":
			done.append(uni)
			if _opt(KEY_SYNC_GDEXT, true):
				_deploy._gdext_adopt_universal(gd, platform, btype, uni)
			else:
				_log("警告: 声明未指向 universal(%s.%s), 请切换 %s.%s.universal 键或开启 sync_gdextension。" % [btype, btype, platform, btype])
			continue
		for f in files:
			var fname := String(f)
			# 规范名用作"同一个库的另一种名字"判据(回退部署时尤其重要)
			var fa := GDExtensionProbeTool._file_arch(fname)
			if fa == "":
				fa = _probe._arch()
			var canon := _probe._canonical_file(tname, btype, fa)
			if _opt(KEY_SYNC_GDEXT, true):
				_deploy._gdext_sync(gd, _probe._abs_to_res(odir).path_join(fname), platform, btype, fname, canon)
			else:
				_deploy._gdext_verify(gd, platform, btype, fname)
	# 终清: 逐插件清理(白名单取并集, 绝不跨插件误删)
	_deploy._final_cleanup(targets, gdext_by_target)
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
		await _proc._restart_editor()
	else:
		_log("需 项目→重新加载当前项目 生效(引擎启动时才加载扩展)。")
	_finish()

## 跑完整流程并等它结束: {ok, summary, state}。
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
static func native_status() -> Dictionary:
	var probe := GDExtensionProbeTool.new()
	# 平台扩展名从规范命名规则反推 —— 构建/部署/清理与本处必须认同一套命名(唯一真值在 probe)。
	var ext := probe._canonical_file("probe", probe._build_type(), probe._arch()).get_extension()
	var per_target: Array = []
	var scaf: GDScript = load(GDExtensionProbeTool.SCAFFOLD_PATH) as GDScript
	if scaf != null and ext != "":
		for p in scaf.discover_plugins(ProjectSettings.globalize_path("res://").simplify_path()):
			var tgt := String(p["target"])
			var s_ms := 0
			for f in FileTool.list_files(String(p["src_abs"]), PackedStringArray([".cpp", ".h", ".hpp", ".c"])):
				s_ms = maxi(s_ms, int(FileAccess.get_modified_time(f)))
			var l_ms := 0
			var l_file := ""
			var prefix := "lib%s." % tgt
			# include_hidden: 库文件可能被外部工具打上隐藏属性, 默认枚举会"看不见已存在的库"。
			for f in FileTool.list_files(String(p["native_abs"]), PackedStringArray(["." + ext]), false, true):
				var base := f.get_file()
				if base.begins_with("~") or not base.begins_with(prefix):
					continue
				var ms := int(FileAccess.get_modified_time(f))
				if ms > l_ms:
					l_ms = ms
					l_file = f
			per_target.append({
				"target": tgt, "plugin": String(p["plugin"]),
				"stale": s_ms > 0 and l_ms > 0 and s_ms > l_ms,
				"source_ms": s_ms, "lib_ms": l_ms, "lib": l_file,
			})
	# 全局值 = 各 target 的汇总; "需要重编"= 有任一个 target 旧了(不是拿全局最大源码去比全局最小产物)。
	var src_ms := 0
	var lib_ms := 0
	var lib := ""
	var any_stale := false
	for t in per_target:
		src_ms = maxi(src_ms, int(t["source_ms"]))
		any_stale = any_stale or bool(t["stale"])
		if int(t["lib_ms"]) > lib_ms:
			lib_ms = int(t["lib_ms"])
			lib = String(t["lib"])
	return {
		"targets": per_target,
		"source_ms": src_ms,
		"lib_ms": lib_ms,
		"lib": lib,
		"has_native": src_ms > 0,
		# 没有原生源码(纯 GDScript 项目)或还没编过产物时不算 stale, 免得误报
		"stale": any_stale,
	}

## 提前失败收尾: 记录摘要与状态, 并弹编辑器提示
func _finish_with(result: String) -> void:
	_summary_write("%s\n日志: res://.godot/gdextension_build/build.log\n修复后再次运行即可重试。" % result)
	_state_write(result)
	_toast("GDExtension 构建失败: " + result)
	_finish()

## ── 实现切片装配 ─────────────────────────────────────────────────
func _init_tools() -> void:
	if _probe != null:
		return
	_probe = GDExtensionProbeTool.new()
	_probe._host = self
	_cmake = GDExtensionCmakeTool.new()
	_cmake._host = self
	_cmake._probe = _probe
	_proc = GDExtensionProcessTool.new()
	_proc._host = self
	_deploy = GDExtensionDeployTool.new()
	_deploy._host = self
	_deploy._probe = _probe

## 兼容入口: 实现已搬到 GDExtensionProbeTool; 外部(Test/工具脚本)在入口实例上直接调这几个,
func _canonical_file(target: String, type: String, arch := "") -> String:
	_init_tools()
	return _probe._canonical_file(target, type, arch)

func _os_label() -> String:
	_init_tools()
	return _probe._os_label()

func _default_out_file(target: String) -> String:
	_init_tools()
	return _probe._default_out_file(target)

func _universal_file(target: String, type: String) -> String:
	_init_tools()
	return _probe._universal_file(target, type)

## 纯函数转发: test_native_scaffold.gd 按类名调用, 契约面必须留在入口。
static func parse_target_outputs(text: String, cmake_dir_abs: String) -> Dictionary:
	return GDExtensionProbeTool.parse_target_outputs(text, cmake_dir_abs)

static func filter_targets(targets: Array, plugin: String) -> Array:
	return GDExtensionProcessTool.filter_targets(targets, plugin)

func _opt(key: String, def_val: bool) -> bool:
	return bool(ProjectSettings.get_setting(key, def_val))

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
	# 走单例取法(而非已弃用的 get_editor_interface()), 非编辑器进程直接跳过
	if not Engine.has_singleton(&"EditorInterface"):
		return
	var ei = Engine.get_singleton(&"EditorInterface")
	if ei == null or not ei.has_method("get_editor_toaster"):
		return
	var toaster = ei.get_editor_toaster()
	if toaster == null or not toaster.has_method("push_text"):
		return
	toaster.push_text(text)

## 阶段/结果状态文件(实时阶段/进度; 供查看, 非必要)
func _state_write(text: String) -> void:
	FileTool.write_text(_abs("res://.godot/gdextension_build/state.txt"), text)

## 最终摘要(成败/用时/产物/下一步): 自动重载前落盘 + 同步进 build.log/Output。
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
