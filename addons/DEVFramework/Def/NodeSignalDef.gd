@tool
## 节点信号定义 — 连接上下文 root 下指定节点的指定信号。
##
## 通用信号源: 让 TaskDef(SignalTaskDef) 能订阅任意场景节点信号(如 Button.pressed)。
## data 约定: connect_signal(data, cb) 中的 data 携带宿主根节点(SignalDef.get_root)。
class_name NodeSignalDef extends SignalDef

## 目标节点路径(相对上下文 root)
@export var node_path: NodePath
## 信号名
@export var signal_name: StringName


func connect_signal(data, callable: Callable) -> void:
	var node := _resolve(data)
	if node == null:
		return
	if not node.has_signal(signal_name):
		push_error("[NodeSignalDef] %s 上不存在信号 %s" % [node, signal_name])
		return
	if not node.is_connected(signal_name, callable):
		node.connect(signal_name, callable)


func disconnect_signal(data, callable: Callable) -> void:
	var node := _resolve(data)
	if node and node.is_connected(signal_name, callable):
		node.disconnect(signal_name, callable)


func _resolve(data) -> Node:
	var root := get_root(data)
	if root == null:
		push_error("[NodeSignalDef] 上下文缺少 root 节点, 无法连接 %s" % signal_name)
		return null
	return root.get_node_or_null(node_path)


func _to_string() -> String:
	return str("NodeSignal(", node_path, ":", signal_name, ")")
