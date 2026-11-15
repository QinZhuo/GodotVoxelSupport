class_name TestCase extends RefCounted

## 测试用例基类(框架仅提供断言基建, 具体用例由项目在 Scripts/Test/ 下编写)。

var _failures: Array = []
var _current_method := ""


## 该用例是否**必须**在游戏进程里跑(依赖项目单例 / 场景树 / 真实时间轴)。
##   · `run_tests(process=editor)` 不会跑它, 而是列为 **skipped 并写进结果文本**
##   · 由 `run_tests(process=game)`(MCP, 游戏进程内) 或 headless `--game` 实际执行。
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


## 用例级收尾钩子。runner 在**每个 test_ 方法之后无条件调用**（不论成败）。
## 存在的理由：会写持久化状态（存档/配置）的用例必须收尾还原，而**手动收尾只覆盖
## 约定：**必须幂等** —— 手动收尾已做过的用例，这里是空操作（靠收尾函数自身的状态判断）。
func cleanup() -> void:
	pass


## 该用例**预期**的最长运行时间（毫秒）；<=0 表示不限。
## 实测用时超过声明值时，在结果里列一条 **SLOW**（不算失败），方便发现"某次改动让它悄悄变慢"。
func max_duration_ms() -> int:
	return 0
