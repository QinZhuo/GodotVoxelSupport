@tool
@abstract
##信号
##
## 连接约定（务必遵守，避免重复连接报错与漏断开）：
## 1. 一律用 `AsyncTool.connect_once` / `safe_disconnect`（只有信号名时用 `connect_once_named` /
##    `safe_disconnect_named`）连接与断开，**不要裸 connect/disconnect**。
## 2. 原因（引擎实测结论）：`Callable` 的相等性只比较**「对象 + 方法」**，`bind()` 绑定的参数
##    **不参与**比较 —— `m.bind(a) == m.bind(b)` 为 true，`is_connected(m.bind(其它上下文))` 也为 true。
##    所以：重复 connect 同一回调（哪怕每次 bind 了不同上下文）会抛
##    `ERR_INVALID_PARAMETER: Signal 'x' is already connected`；而 is_connected 判定与 disconnect
##    对任意 bind 变体都成立，无需自己遍历连接比对参数。
## 3. 回调身份 = 「所属对象 + 方法名」⇒ **同一个 SignalDef 实例在同一信号上只能保留一个回调**；
##    需要多份互不干扰的订阅时，让回调挂在各自的对象上（例如各物品自己的 SignalEffectDef），
##    并把上下文 bind 进参数。
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
	return "res://Assets/Translation/signal.csv"
