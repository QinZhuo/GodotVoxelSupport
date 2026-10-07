@tool
class_name QVoxUndoStack
extends CommandHistory
## 撤销栈 —— 命令流上的一个游标。
##
## 【为什么继承 CommandHistory 而不是另写一个栈】
## 撤销栈与命令日志本来就是同一串数据，只差一个游标：
##   commands[0 .. cursor)  已生效
##   commands[cursor .. ]   已撤销、可重做（"redo 分支"）
## 于是"撤销栈"= 命令流 + 游标，"回放日志"= 同一份命令流，不必各存一份、各写一遍
## 序列化。save_data()（继承而来）因此天然给出"本次会话完整命令流"。
##
## 【预算淘汰】命令流随会话增长，体素命令每条可能几十 KB。超预算时从**队首**丢最老的
## （游标随之前移）—— 这与 Godot EditorUndoRedoManager 的 history_size 限制同一思路：
## 宁可丢掉远古历史，也不能让编辑器在长会话里涨到几个 GB。

## 游标：commands[0..cursor) 已生效。
var cursor := 0

## 命令流代价上限（QVoxCommand.get_cost() 之和，单位字节）。<= 0 表示不限制。
var max_cost := 256 * 1024 * 1024

## 栈发生变化（push/undo/redo/淘汰），UI 据此刷新菜单项可用性。
signal changed


## 入栈一条**已经生效**的命令。
##
## 【为什么入栈时调 redo()】工具是"先改数据、再登记命令"，数据已经是 after 状态，
## 所以这次 redo() 必须是无副作用的幂等重放（见 QVoxCommand.redo 的说明）。这样做的好处是
## 全项目只有一条时间线：任何让状态前进的路径都必须经过 redo()，不必区分"首次执行"与"重放"。
func push(cmd: QVoxCommand) -> void:
	if cmd == null:
		return
	truncate_redo()
	cmd.tick = commands.size()  # 会话时序号：tick 单调，供回放/审计排序
	append(cmd)
	cursor = commands.size()
	cmd.redo()
	_enforce_budget()
	changed.emit()


func can_undo() -> bool:
	return cursor > 0


func can_redo() -> bool:
	return cursor < commands.size()


func undo() -> QVoxCommand:
	if not can_undo():
		return null
	cursor -= 1
	var cmd: QVoxCommand = commands[cursor]
	cmd.undo()
	changed.emit()
	return cmd


func redo() -> QVoxCommand:
	if not can_redo():
		return null
	var cmd: QVoxCommand = commands[cursor]
	cmd.redo()
	cursor += 1
	changed.emit()
	return cmd


## 下一次撤销/重做的显示名（菜单项文字，如 "撤销 体素编辑"）。
func undo_label() -> String:
	return (commands[cursor - 1] as QVoxCommand).get_label() if can_undo() else ""


func redo_label() -> String:
	return (commands[cursor] as QVoxCommand).get_label() if can_redo() else ""


## 丢弃 redo 分支（新操作入栈时调用 —— 标准撤销语义）。
func truncate_redo() -> void:
	if cursor >= commands.size():
		return
	commands.resize(cursor)


func total_cost() -> int:
	var c := 0
	for cmd in commands:
		c += (cmd as QVoxCommand).get_cost()
	return c


func clear() -> void:
	super()
	cursor = 0
	changed.emit()


## 【刻意不实现"从存档恢复"】存档里只有参数记录，没有 undo() 能用的差值，恢复出来会是一个
## "看着能撤销、按下去就报错"的栈。明确报错好过静默给一个假栈。
func load_data(_data) -> void:
	push_error("[QVox] 撤销栈是会话内的，不从存档恢复；持久化请把 CommandHistory 另存。")


func _enforce_budget() -> void:
	if max_cost <= 0:
		return
	var total := total_cost()
	while total > max_cost and commands.size() > 1:
		total -= (commands[0] as QVoxCommand).get_cost()
		commands.remove_at(0)
		cursor = maxi(cursor - 1, 0)
