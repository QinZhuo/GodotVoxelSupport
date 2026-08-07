@tool
## 带条件的信号定义
##
## 包装另一个 SignalDef，在触发时检查 ConditionDef 条件，
## 仅在条件满足时执行回调。
class_name ConditionSignalDef extends SignalDef

## 中文名
@export var name_zh: String:
	get(): return _get_zh(name)
	set(value): _set_zh(name, value)

## 被包装的信号定义
@export var signal_def: SignalDef

## 条件（为空时不进行过滤）
@export var condition: ConditionDef

func connect_signal(data, callable: Callable):
	if not signal_def:
		return
	signal_def.connect_signal(data, _on_signal.bind(callable))

func disconnect_signal(data, callable: Callable):
	if not signal_def:
		return
	signal_def.disconnect_signal(data, _on_signal.bind(callable))

func _on_signal(data, callable: Callable):
	if condition and not condition.is_met(data):
		return
	callable.call(data)

func _to_string() -> String:
	if signal_def and condition:
		return str(signal_def, " | ", condition)
	if signal_def:
		return str(signal_def)
	if condition:
		return str("[empty] | ", condition)
	return tr(name)
