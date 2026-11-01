@tool
class_name QVoxelStructureCommand
extends QVoxelCommand
## 树结构的一次变动：把节点从「变动前的位置」挪到「变动后的位置」。
## 增 = 无 → 有；删 = 有 → 无；移动 = 有 → 有 —— 三种操作共用同一条记录。
## 【为什么不做成三个类】它们对世界的效果是同一件事（节点换了个位置），差别只在两端的
## "有 / 无"，一个可空位置就表达完了，也不必为每种操作各写一遍 undo。
## 【为什么必须幂等】`push()` 会先调一次 `redo()`，而此刻数据已经被就地改过 ——
## 真正的判断在 `QVoxelierSession.place_node()`（已在目标位置就什么都不做）。

## 位置哨兵：不在树上。
const OFF_TREE := -1

var node: QVoxelNode
## 变动前的位置。`from_parent == null` 且 `from_index == OFF_TREE` 表示"当时不在树上"。
var from_parent: QVoxelGroup
var from_index := OFF_TREE
## 变动后的位置，语义同上。
var to_parent: QVoxelGroup
var to_index := OFF_TREE
## 真正执行挂 / 摘的会话（它还负责编辑会话的建与清，见 `place_node`）。
## 【为什么用弱类型】本类在 `Command/`、会话在 `Editing/`，标成 `QVoxelierSession`
## 会让两个目录的类互相引用；GDScript 多数情况下能解析，但没必要冒这个顺序风险。
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
