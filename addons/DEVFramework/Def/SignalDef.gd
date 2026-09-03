@tool
@abstract
##信号
class_name SignalDef extends Def

@abstract
func connect_signal(data, callable: Callable)

@abstract
func disconnect_signal(data, callable: Callable)

## 从连接上下文中解析宿主根节点(约定: Dictionary{"root": Node} / 带 root 属性的对象 / 直接传 Node)
static func get_root(data) -> Node:
	if data is Dictionary:
		return data.get("root")
	if data is Node:
		return data
	if data != null and "root" in data:
		return data.get("root")
	return null

func get_csv_path() -> String:
	return "res://Assets/Translation/signal.csv"
