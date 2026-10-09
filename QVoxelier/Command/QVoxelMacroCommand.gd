@tool
class_name QVoxMacroCommand
extends QVoxCommand
## 宏 —— 把多步 UI 操作折叠成**一条**撤销单位（"改参数 + 重命名"、"批量赋材质"…）。
##
## 【为什么要有它，而不是让调用方连推三条】用户心里的一次操作就该是一次 Ctrl+Z。
## 连推三条会让撤销变成"按三次、还要记住按了几次"，而且中途插进别的操作就会撤错对象。
##
## 【为什么是"装命令"而不是"合并参数"】子命令各自知道怎么还原自己（体素的差值、属性的前后值），
## 宏只需按序 redo、逆序 undo —— 于是宏**不需要理解任何一种命令的语义**，将来加新命令类也自动适用。
## 这正是 Qt 的 `beginMacro` / `endMacro` 与 Godot `EditorUndoRedoManager.create_action` /
## `commit_action` 的形状；本项目沿用 Qt 的命名（QVoxelier/DESIGN.md §6.2）。
##
## 【代价 = 子命令之和】预算淘汰因此能把"一大团宏"当作一个大单位衡量，
## 而不是被"一条命令看起来很小"骗过去。
##
## 【子命令不进撤销栈】宏只把**自己**交给 QVoxUndoStack；子命令是它的内部结构。
## 于是"一次撤销"的粒度天然正确，游标与菜单项文字也只需要看宏这一层。

## 子命令（按执行顺序）。空宏由 QVoxUndoStack 拦截，不入栈。
var children: Array[QVoxCommand] = []

## 展示名（如 "改参数"）；留空则退化为"多步操作"。
var macro_label := ""


func _init(p_label := "") -> void:
	super(&"macro", -1, [])
	macro_label = p_label
	# 命令主体标识：与"params 首个参数为命令主体"的惯例一致，也是宏唯一能记进
	# 可回放记录里的东西 —— 子命令的语义差异已经被宏名概括了。
	params = [get_label()]


func add(cmd: QVoxCommand) -> void:
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


## 顺放。**必须幂等**（push() 时会调一次，而数据通常已被工具改过）。
func redo() -> void:
	for ch in children:
		ch.redo()


## 逆收。逆序是必须的：后做的事先撤 —— 否则"先删掉某条修改器、再改它的参数"这类组合，
## 恢复时会先复活那条修改器、再回头去改一个已经不在链上的实例。
func undo() -> void:
	for i in range(children.size() - 1, -1, -1):
		children[i].undo()
