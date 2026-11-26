class_name TestCase extends RefCounted

## 测试用例基类(框架仅提供断言基建, 具体用例由项目在 Scripts/Test/ 下编写)。

var _failures: Array = []
var _current_method := ""

## 该用例是否**必须**在游戏进程里跑(依赖项目单例 / 场景树 / 真实时间轴)。
func needs_game_process() -> bool:
	return false

func _fail(msg: String) -> void:
	_failures.append("%s: %s" % [_current_method, msg])

func assert_true(cond: bool, msg := "") -> void:
	if not cond:
		_fail(msg if msg != "" else "期望为 true")

func assert_false(cond: bool, msg := "") -> void:
	if cond:
		_fail(msg if msg != "" else "期望为 false")

func assert_eq(got, want, msg := "") -> void:
	if got != want:
		_fail("%s (got=%s want=%s)" % [msg if msg != "" else "值不相等", str(got), str(want)])

func assert_ne(got, not_want, msg := "") -> void:
	if got == not_want:
		_fail("%s (got=%s 不应等于 %s)" % [msg if msg != "" else "值不应相等", str(got), str(not_want)])

## 浮点/向量/Rect 的近似相等(引擎默认容差)。
func assert_approx(got, want, msg := "") -> void:
	var ok: bool
	if got is float or got is int or want is float or want is int:
		ok = is_equal_approx(float(got), float(want))
	else:
		ok = got.is_equal_approx(want)
	if not ok:
		_fail("%s (got=%s want=%s)" % [msg if msg != "" else "值不近似相等", str(got), str(want)])

## 断言一段逻辑的耗时上限(毫秒)。
func assert_under_ms(limit_ms: float, action: Callable, msg := "") -> void:
	var ms := _measure_resolved(action)
	if ms > limit_ms:
		_fail("%s耗时 %s > 上限 %s" % [_prefix(msg), PerfTool.fmt_cost(ms), PerfTool.fmt_cost(limit_ms)])

## 测一段逻辑的耗时并写入历史基线(不判失败), 返回毫秒。
func measure_ms(key: String, action: Callable) -> float:
	var ms := _measure_resolved(action)
	PerfTool.record(key, ms)
	return ms

## 单次测量; 读数低于计时器分辨率时改用分组采样。
func _measure_resolved(action: Callable) -> float:
	var ms := PerfTool.measure(action)
	if ms >= PerfTool.to_ms(int(PerfTool.clock_resolution_us())) * 2.0:
		return ms
	return float(PerfTool.bench_auto(action, 20.0)["p50_ms"])

## 断言平均帧率下限(p50 反推的等效帧率, 比瞬时 fps 更能代表稳定性)。
func assert_fps_at_least(min_fps: float, frames := 120, warmup := 30, key := "") -> Dictionary:
	var r: Dictionary = await PerfTool.sample_frames(frames, warmup)
	if r.has("error"):
		_fail(str(r["error"]))
		return r
	if key != "":
		PerfTool.record(key, float(r.get("p50_ms", 0.0)))
	var fps := float(r.get("fps_p50", 0.0))
	if fps < min_fps:
		# 采样侧会带回 note(如"在编辑器进程采样"): 帧率低可能根本不是被测逻辑的问题
		var note := str(r.get("note", ""))
		_fail("帧率 %.1f < 下限 %.1f (1%% low %.1f, p95 帧时间 %.1fms, 卡顿 %d 次@%.1fms, 绘制 %d)%s" % [
			fps, min_fps, float(r.get("fps_1pct_low", 0.0)), float(r.get("p95_ms", 0.0)),
			int(r.get("stutter", 0)), float(r.get("stutter_ms", 0.0)), int(r.get("draw_calls", 0)),
			"" if note.is_empty() else " —— " + note])
	return r

func _prefix(msg: String) -> String:
	return "%s " % msg if msg != "" else ""

## 用例级收尾钩子。
func cleanup() -> void:
	pass

## 该用例**预期**的最长运行时间（毫秒）；<=0 表示不限。
func max_duration_ms() -> int:
	return 0
