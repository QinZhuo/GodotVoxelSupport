class_name TestCase extends RefCounted

## 测试用例基类(框架仅提供断言基建, 具体用例由项目在 Scripts/Test/ 下编写)。
## 以 test_ 开头的方法会被 TestRunner 自动发现并执行;
## 方法可含 await(协程), runner 自动等待完成后再判定。

var _failures: Array = []
var _current_method := ""


## 该用例是否**必须**在游戏进程里跑(依赖 MonitorGame / 场景树 / 真实时间轴)。
##
## 默认 false: 纯逻辑用例, 编辑器进程即可 —— 快、无副作用, `run_tests` 直接跑。
## 覆写为 true 之后:
##   · `run_tests`(编辑器进程) 不会跑它, 而是列为 **skipped 并写进结果文本**
##     (绝不静默通过: 免得"看着全绿其实一条没跑");
##   · 由 `run_game_tests`(MCP, 游戏进程内) 或 headless `--game` 实际执行。
##
## 判定建议: 用到 `MonitorGame.singleton` / `get_tree()` / 真实计时 / 真实战斗流程的用例
## 一律 return true; 只算数据、只读资源、只测纯函数的用例保持 false。
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
##
## 存在的理由：会写持久化状态（玩家档案/存档）的用例必须收尾还原，而**手动收尾只覆盖
## "正常跑完"那一条路** —— 中途 return、协程被超时中断、调试器断住，都会跳过后面的还原代码。
## 这类残留最麻烦的地方在于它**当时看不出来**：测试报红能发现"完全没还原"，而"还原了但漏了一项"
## 只会在几天后的平衡数据里显形。
##
## 约定：**必须幂等** —— 手动收尾已做过的用例，这里是空操作（靠收尾函数自身的状态判断）。
## 可含 await（runner 会等它跑完）。
func cleanup() -> void:
	pass
