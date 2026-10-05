@tool
class_name ReplayInputSource extends InputSource

## 回放输入源：按序弹出预录输入（回放/自动化测试用），绝不触碰任何 UI。
## inputs 的每项为一条决策的参数数组，与记录的 params 决策段一一对应，保证回放确定性。

var inputs: Array = []

func _init(p_inputs: Array = []) -> void:
	inputs.assign(p_inputs)


## 由记录的决策段构造（每个答案为一次决策，包装成单元素参数组）
static func from_answers(answers: Array) -> ReplayInputSource:
	var queued: Array = []
	for answer in answers:
		queued.append([answer])
	return ReplayInputSource.new(queued)


## 是否已经报告过"队列空"（每个输入源只报一次，避免刷屏）
var _reported_empty := false

func poll(_request: Variant = null) -> Array:
	if inputs.is_empty():
		## 输入用尽 = 本次操作在记录里没有可用的决策答案（旧格式记录 / 对手记录缺决策段）。
		## 按契约语义处理即可：返回空数组 = 取消/无法作答（效果层会走取消分支）。
		## ⚠️ 这里**不能用 push_error**：回放这类记录时每一次这类操作都会命中，
		## 而调试器开着"遇错即断点"时会让回放直接卡住（实测：回放其他战绩满屏红字并暂停）。
		## 只告警一次，保留可诊断性又不刷屏。
		if not _reported_empty:
			_reported_empty = true
			LogTool.warn("回放", "记录缺少本次操作的决策答案，按取消处理（%d 次决策未取到）" % inputs.size())
		return []
	return inputs.pop_front()


## 是否已报告过"答案未用完"（与 `_reported_empty` 同风格：只报一次，不刷屏）
var _reported_unused := false

## 校验决策段是否被完整消费：记录里的答案**多于**效果链实际请求
## = 记录与当前效果链不匹配（典型：某版本删了一个点选、或改变选择方式）。
## 只报告、不改动 inputs（幂等，可安全重复调用）。
func verify_consumed() -> String:
	if inputs.is_empty() or _reported_unused:
		return ""
	_reported_unused = true
	return "决策答案未用完（记录剩 %d 个）" % inputs.size()

## 旧格式记录没有决策段：缺答时允许效果层走默认目标兜底（复现历史行为）。
func allows_missing_answer() -> bool:
	return true
