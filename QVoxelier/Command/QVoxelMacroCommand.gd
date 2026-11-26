@tool
class_name QVoxelMacroCommand
extends QVoxelCommand
## 宏 —— 把多步 UI 操作折叠成**一条**撤销单位（"改参数 + 重命名"、"批量赋材质"…）。

## 子命令（按执行顺序）。
var children: Array[QVoxelCommand] = []

## 展示名（如 "改参数"）；留空则退化为"多步操作"。
var macro_label := ""

func _init(p_label := "") -> void:
	super(&"macro", -1, [])
	macro_label = p_label
	# 命令主体标识：与"params 首个参数为命令主体"的惯例一致，也是宏唯一能记进
	params = [get_label()]

func add(cmd: QVoxelCommand) -> void:
	if cmd != null:
		children.append(cmd)

func size() -> int:
	return children.size()

func is_empty() -> bool:
	return children.is_empty()

func get_label() -> String:
	var base := macro_label if not macro_label.is_empty() else "多步操作"
	if children.size() <= 1:
		return base
	return "%s（%d 步）" % [base, children.size()]

func get_cost() -> int:
	var c := 0
	for ch in children:
		c += ch.get_cost()
	return c

## 顺放。
func redo() -> void:
	for ch in children:
		ch.redo()

## 逆收。
func undo() -> void:
	for i in range(children.size() - 1, -1, -1):
		children[i].undo()
