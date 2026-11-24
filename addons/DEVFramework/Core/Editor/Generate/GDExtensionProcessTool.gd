@tool
class_name GDExtensionProcessTool
extends RefCounted

## GDExtension 构建的"子进程与等待"切片: 起 CMake --build 子进程、读日志、磁盘/心跳进度、
## 卡死与硬超时判定、终止进程树、编辑器重载。只是 GDExtensionRebuild 的实现细节。

## 约束 1: 必须 extends RefCounted —— EditorScriptMenuTool 会把 extends EditorScript 的脚本当菜单工具列出。
## 约束 2: _host 不加类型注解 —— 双向类型注解会形成 class_name 环。
## 约束 3: 实例状态(日志缓冲/构建游标)全部留在 GDExtensionRebuild, 这里只读写 _host.*。

var _host   # GDExtensionRebuild 实例

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
const KEY_STALL_KILL := "dev_framework/gdextension_build/stall_auto_kill"   # 检测到卡死(无新目标且无编译器进程)时自动终止进程树
const KEY_HARD_TIMEOUT := "dev_framework/gdextension_build/hard_timeout_sec"  # 零推进多久判死(秒, 0=关闭)
const KEY_JOBS := "dev_framework/gdextension_build/build_jobs"        # 并行度, 0=自动(默认16; 设小可降并发防卡)


func _restart_editor() -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(2.0).timeout
	if not Engine.has_singleton(&"EditorInterface"):
		return
	var ei = Engine.get_singleton(&"EditorInterface")
	if ei != null:
		ei.restart_editor(true)


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
	_host._log("开始编译 (%s%s)…… 编辑器保持可用, 输出实时回显。" % [type, "" if tgt == "" else ", " + tgt])
	var jobs := int(ProjectSettings.get_setting(KEY_JOBS, 0))
	if jobs <= 0:
		jobs = clampi(OS.get_processor_count(), MIN_JOBS, MAX_JOBS)
	# 子进程输出重定向到文件, 本进程定时尾读回显 —— 不经过 Godot execute_with_pipe 管道。
	var raw := _raw_log_path()
	DirAccess.remove_absolute(raw)
	_host._raw_log_pos = 0
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
	_host._build_started_unix = Time.get_unix_time_from_system()
	var pid := OS.create_process(shell, run_args)
	if pid <= 0:
		_host._log("异步执行不可用, 退化为阻塞执行(编辑器会卡住直到完成)。")
		var out: Array = []
		var code := OS.execute(shell, run_args, out, true)
		_host._print_out(out)
		return code == 0
	var tree := Engine.get_main_loop() as SceneTree
	_host._total_targets = -1   # 每次构建重新解析 Makefile(目录可能重建/缓存残留)
	_host._stall_checked = false
	_host._stall_killed = false
	_host._prev_done_count = -1
	_host._no_advance = 0
	_host._state_write("编译中: 启动…")
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
				_host._log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d/%d 目标文件" % [silent / TICKS_PER_SEC, d, t])
			else:
				_host._log_raw("[心跳] 编译仍在进行(已静默 %d 秒)… 已生成 %d 个目标(总数未知)" % [silent / TICKS_PER_SEC, d])
			# 目标长期不增长 → 累计"无推进"时长
			if d == _host._prev_done_count:
				_host._no_advance += HEARTBEAT_INTERVAL_SEC
			else:
				_host._no_advance = 0
				_host._prev_done_count = d
			# 兜底硬超时: 无论进程表怎么说, 只要这么久一个目标都没新增就判死 ——
			# 正常编译再慢也会推进, 零推进只能是被挂住的进程句柄/杀软锁文件。
			if hard_sec > 0 and _host._no_advance >= hard_sec and not _host._stall_killed:
				_host._stall_checked = true
				_host._log_raw("硬超时: %d 秒内没有任何新目标, 判定构建卡死。" % _host._no_advance)
				if _stall_kill_enabled():
					_kill_build_tree(pid)
					_host._stall_killed = true
					_host._log_raw("已终止进程树(pid %d)。可直接重跑(从已编译部分继续)。" % pid)
				else:
					_host._log_raw("自动终止已关闭(ProjectSettings: %s=false)。请在任务管理器结束 cmake/make 后重跑。" % KEY_STALL_KILL)
				break
			# 卡死熔断: 目标长期不增长 + 无编译器子进程存活 → 构建系统在等不存在的子进程(非编译慢)
			if _host._no_advance >= STALL_TIMEOUT_SEC and not _host._stall_checked and not _host._stall_killed:
				var active := _active_compile_procs()
				if active == 0:
					_host._stall_checked = true
					_host._log_raw("异常检测: %d 秒无新目标且无任何编译器进程 —— 构建疑似卡死, 尝试终止进程树。" % _host._no_advance)
					if _stall_kill_enabled():
						_kill_build_tree(pid)
						_host._stall_killed = true
						_host._log_raw("已终止卡死进程树(pid %d)。可直接重跑(从已编译部分继续); 反复出现请排查杀软实时扫描/编译器异常。" % pid)
					else:
						_host._log_raw("自动终止已关闭(ProjectSettings: %s=false)。请在任务管理器结束 cmake/make 后重跑。" % KEY_STALL_KILL)
				else:
					_host._log_raw("%d 秒无新目标, 仍有 %d 个编译器进程在跑(可能正在编译超大文件), 继续等待。" % [_host._no_advance, active])
		if _host._stall_killed:
			break
		await tree.create_timer(POLL_INTERVAL_SEC).timeout
	_drain_log(raw)   # 进程退出会 flush 全部缓冲, 收尾再读一次
	if _host._stall_killed:
		_host._log("构建已被工具终止(疑似卡死)。")
		_host._state_write("编译失败: 疑似卡死(已终止进程树)")
		return false
	if exit_code == -1:
		exit_code = OS.get_process_exit_code(pid)
	# 失败状态**立即**落盘: 否则调用方(build_native / 人)只能看到一个永远停在"编译中"的 state
	if exit_code != 0:
		_host._log("编译失败(退出码 %d), 请按上方报错定位。" % exit_code)
		_host._state_write("编译失败(退出码 %d)" % exit_code)
		return false
	_host._log("编译成功。")
	_host._state_write("编译完成: %s" % type)
	return true


## 子进程原始输出落点(每次构建覆盖)
func _raw_log_path() -> String:
	return _host._abs("res://.godot/gdextension_build/raw_build.log")


## 定期把磁盘真实进度写入 state/日志(每 ~2s; 每前进 ≥30 个目标才刷一行日志, 避免刷屏)
func _report_disk_progress(build_dir: String) -> void:
	var total := _total_compile_units(build_dir)
	var done := _count_build_objects(build_dir)
	if total > 0:
		_host._state_write("编译中: 已生成 %d/%d 目标" % [done, total])
	else:
		_host._state_write("编译中: 已生成 %d 个目标" % done)
	if done - _host._objects_logged >= 30:
		_host._objects_logged = done
		if total > 0:
			_host._log_raw("编译进度: %d/%d 目标" % [done, total])
		else:
			_host._log_raw("编译进度: 已生成 %d 个目标" % done)


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
	if _host._total_targets >= 0:
		return _host._total_targets
	_host._total_targets = 0
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
						_host._total_targets += 1
			e = dir.get_next()
		dir.list_dir_end()
	return _host._total_targets


## 读取原始构建日志自上次位置起的新内容, 逐行回显到 Output/镜像日志; 返回是否有新行
func _drain_log(raw_path: String) -> bool:
	var f := FileAccess.open(raw_path, FileAccess.READ)
	if f == null:
		return false
	f.seek(_host._raw_log_pos)
	var had := false
	while not f.eof_reached():
		_host._log_raw(f.get_line())
		had = true
	_host._raw_log_pos = f.get_position()
	f.close()
	return had
