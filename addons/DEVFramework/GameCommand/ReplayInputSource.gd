@tool
class_name ReplayInputSource extends InputSource

## 回放输入源：按序弹出预录输入（回放/自动化测试用），绝不触碰任何 UI。
## inputs 的每项为一条决策的参数数组，与实战日志的 params 决策段一一对应，
## 保证回放确定性。

var inputs: Array = []
## 已消费的输入（供校验与调试）
var consumed: Array = []

func _init(p_inputs: Array = []) -> void:
	inputs.assign(p_inputs)

func poll(_tick: int, _request: Dictionary = {}) -> Array:
	if inputs.is_empty():
		push_error("ReplayInputSource: 输入队列已空，动作与记录不匹配")
		return []
	var value: Array = inputs.pop_front()
	consumed.append(value.duplicate(true))
	return value
