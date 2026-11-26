@tool
class_name QVoxelCommand
extends GameCommand
## 一条可撤销的编辑操作 —— 撤销栈的基本单位。

## 执行/重放本命令。
func redo() -> void:
	push_error("[QVX] 命令未实现 redo()：%s" % get_label())

func undo() -> void:
	push_error("[QVX] 命令未实现 undo()：%s" % get_label())

## 展示给用户的操作名（撤销/重做菜单项直接用它，所以要说"做了什么"，不是类名）。
func get_label() -> String:
	return "操作"

## 代价估算（字节），供撤销栈按预算淘汰最老的历史。
func get_cost() -> int:
	return 1

## 这条命令影响**哪些体素范围**（[lo, hi] 闭区间），供视口只重算受影响的部分。
func dirty_bounds() -> Array[Vector3i]:
	var none: Array[Vector3i] = []
	return none
