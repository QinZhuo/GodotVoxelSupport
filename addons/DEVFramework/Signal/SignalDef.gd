@tool
@abstract
##信号
##    `safe_disconnect_named`）连接与断开，**不要裸 connect/disconnect**。
## 2. 原因（引擎实测结论）：`Callable` 的相等性只比较**「对象 + 方法」**，`bind()` 绑定的参数
## 4. 本类不得保存运行时状态：Def 是共享资源，会被多个物品 / 双方复用。
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
	return Def.csv_path("signal")
