@tool
## 教程步骤 — 完成条件 = 信号(SignalTaskDef), 引导表现 = 高亮一组目标(targets)。
class_name TutorialStepDef extends SignalTaskDef

## 高亮目标(可多个; 空 = 无目标纯提示)。目标保持原样且可交互, 其余变暗且不可交互。
@export var targets: Array[TutorialTargetDef] = []

## 有目标时也允许"点任意处继续"(展示说明类步骤: 只让玩家看清目标, 不等交互信号)
@export var click_to_complete_with_target := false

## 不显示任何引导(不遮罩/不提示), 只等信号推进
@export var silent := false

## 是否拦截高亮区之外的输入(默认拦截)
@export var block_input := true

## 是否绘制暗区(关闭 = 只弹提示气泡, 适合"流程进行中"这类不能挡操作的等待)
@export var dim := true


## 提示文字复用 TaskDef 统一 desc 翻译(tr(名称_desc), 见 Assets/Translation/task.csv)
func get_desc(data) -> String:
	return "" if silent else super(data)


## 解析本步目标节点, 缺失节点直接跳过
func find_targets(host: Node) -> Array[Node]:
	var result: Array[Node] = []
	for target in targets:
		var node := target.resolve(host) if target else null
		if node:
			result.append(node)
	return result


## 是否配置了完成信号(继承自 SignalTaskDef.signals)
func has_signals() -> bool:
	return not signals.is_empty()


## 是否"点任意处继续": 有目标时仅看 click_to_complete_with_target, 无目标且无信号时默认如此
func click_to_complete_for(has_targets: bool) -> bool:
	if click_to_complete_with_target:
		return true
	return not has_targets and not has_signals()
