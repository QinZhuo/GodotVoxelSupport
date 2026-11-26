@tool
class_name QVoxelStructureCommand
extends QVoxelCommand
## 树结构的一次变动：把节点从「变动前的位置」挪到「变动后的位置」。

## 位置哨兵：不在树上。
const OFF_TREE := -1

var node: QVoxelNode
## 变动前的位置。
var from_parent: QVoxelGroup
var from_index := OFF_TREE
## 变动后的位置，语义同上。
var to_parent: QVoxelGroup
var to_index := OFF_TREE
## 真正执行挂 / 摘的会话（它还负责编辑会话的建与清，见 `place_node`）。
var host: Object
var label := "结构变动"

func redo() -> void:
	if host != null:
		host.call(&"place_node", node, to_parent, to_index)

func undo() -> void:
	if host != null:
		host.call(&"place_node", node, from_parent, from_index)

func get_label() -> String:
	return label

## 只持三个引用，本身体积可忽略；给个小常数供撤销栈按预算淘汰时计入。
func get_cost() -> int:
	return 64
