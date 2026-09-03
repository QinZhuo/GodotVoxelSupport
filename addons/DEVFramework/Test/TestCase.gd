class_name TestCase extends RefCounted

## 测试用例基类(框架仅提供断言基建, 具体用例由项目在 Scripts/Test/ 下编写)。
## 以 test_ 开头的方法会被 TestRunner 自动发现并执行;
## 方法可含 await(协程), runner 自动等待完成后再判定。

var _failures: Array = []
var _current_method := ""


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
