@tool
## 带条件的信号定义
##
## 包装另一个 SignalDef，触发时检查 ConditionDef 条件，仅条件满足时把信号转发给回调
## (常用于计数任务的条件过滤 —— 只统计满足条件的触发)。
## 条件上下文约定: 基于 connect_signal 传入的 data(连接时的固定上下文)求值;
## 若要按"这次事件携带的数据"判定(如按购买类型), 请用项目/业务专用信号定义,
## 不要改此通用类的判定语义(它被计数任务等按"连接上下文"语义复用)。
class_name ConditionSignalDef extends SignalDef


## 被包装的信号定义
@export var signal_def: SignalDef

## 条件（为空时不进行过滤）
@export var condition: ConditionDef

func connect_signal(data, callable: Callable) -> void:
	if not signal_def:
		return
	# bind 追加在参数表末尾: 信号实参在前, [data, callable] 在后 —— _on_signal 据此还原
	signal_def.connect_signal(data, _on_signal.bind(data, callable))

func disconnect_signal(data, callable: Callable) -> void:
	if not signal_def:
		return
	signal_def.disconnect_signal(data, _on_signal.bind(data, callable))

func _on_signal(...args) -> void:
	# 参数布局: (信号实参..., data, callable) —— bind(data, callable) 追加在参数表末尾。
	# 信号 emit 时实参在前、绑定参数在后(见 Godot Callable.bind 语义); 信号实参个数不定,
	# 所以用变长参数, 并固定从尾部取 data/callable(常驻最后两位), 中间即信号自身实参。
	if args.size() < 2:
		return
	var data: Variant = args[args.size() - 2]
	var callback: Callable = args[args.size() - 1]
	if condition and not condition.is_met(data):
		return
	callback.callv(args.slice(0, args.size() - 2))

func _to_string() -> String:
	if signal_def and condition:
		return str(signal_def, " | ", condition)
	if signal_def:
		return str(signal_def)
	if condition:
		return str("[empty] | ", condition)
	return tr(name)
