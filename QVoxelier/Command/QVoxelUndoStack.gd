@tool
class_name QVoxelUndoStack
extends CommandHistory
## 撤销栈 —— 命令流上的一个游标。
## 【为什么继承 CommandHistory 而不是另写一个栈】
## 撤销栈与命令日志本来就是同一串数据，只差一个游标：
##   commands[0 .. cursor)  已生效
##   commands[cursor .. ]   已撤销、可重做（"redo 分支"）
## 于是"撤销栈"= 命令流 + 游标，"回放日志"= 同一份命令流，不必各存一份、各写一遍
## 序列化。save_data()（继承而来）因此天然给出"本次会话完整命令流"。
## 【预算淘汰】命令流随会话增长，体素命令每条可能几十 KB。超预算时从**队首**丢最老的
## （游标随之前移）—— 这与 Godot EditorUndoRedoManager 的 history_size 限制同一思路：
## 宁可丢掉远古历史，也不能让编辑器在长会话里涨到几个 GB。

## 游标：commands[0..cursor) 已生效。
var cursor := 0

## 命令流代价上限（QVoxelCommand.get_cost() 之和，单位字节）。<= 0 表示不限制。
var max_cost := 256 * 1024 * 1024

## 栈发生变化（push/undo/redo/淘汰），UI 据此刷新菜单项可用性。
signal changed

## 正在累积的宏（**栈式**：允许嵌套 —— 内层结束后并入外层，等最外层 end_macro 一次入栈）。
var _macro_open: Array[QVoxelMacroCommand] = []


## 入栈一条**已经生效**的命令。
## 【为什么入栈时调 redo()】工具是"先改数据、再登记命令"，数据已经是 after 状态，
## 所以这次 redo() 必须是无副作用的幂等重放（见 QVoxelCommand.redo 的说明）。这样做的好处是
## 全项目只有一条时间线：任何让状态前进的路径都必须经过 redo()，不必区分"首次执行"与"重放"。
## 【宏内入栈只攒着】这里转发给当前宏而不真正入栈 —— 于是"宏 = 一条命令"对游标、
## changed 通知与预算淘汰三处同时成立，这三处都不必知道宏的存在。
func push(cmd: QVoxelCommand) -> void:
	if cmd == null:
		return
	if not _macro_open.is_empty():
		_macro_open.back().add(cmd)
		return
	_push_now(cmd)


## 开始一段宏：其间的 push() 都攒进同一条，end_macro() 一次性入栈。
## 【为什么值得有】"改参数 + 重命名"在用户眼里是一次操作。攒起来还有个附带好处：
## 中间过程不触碰游标、不发信号 —— UI 不会在拖拽中闪出一串中间态的历史项。
func begin_macro(label := "") -> QVoxelMacroCommand:
	var m := QVoxelMacroCommand.new(label)
	_macro_open.append(m)
	return m


## 结束最近的宏，返回入栈的那条（空宏返回 null）。**空宏不入栈** —— 与"空手势不入栈"同一约定。
func end_macro() -> QVoxelMacroCommand:
	if _macro_open.is_empty():
		push_error("[QVX] end_macro() 没有配对的 begin_macro()")
		return null
	var m: QVoxelMacroCommand = _macro_open.pop_back()
	if m.is_empty():
		return null
	if not _macro_open.is_empty():
		_macro_open.back().add(m)  # 嵌套：并入外层，等外层结束再一起入栈
		return m
	_push_now(m)
	return m


## 当前是否有未结束的宏（UI 据此禁用"新建操作"之类的入口）。
func in_macro() -> bool:
	return not _macro_open.is_empty()


## 真正入栈。宏内外共用这一条路径，宏只走它一次。
func _push_now(cmd: QVoxelCommand) -> void:
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


func undo() -> QVoxelCommand:
	if not can_undo():
		return null
	cursor -= 1
	var cmd: QVoxelCommand = commands[cursor]
	cmd.undo()
	changed.emit()
	return cmd


func redo() -> QVoxelCommand:
	if not can_redo():
		return null
	var cmd: QVoxelCommand = commands[cursor]
	cmd.redo()
	cursor += 1
	changed.emit()
	return cmd


## 下一次撤销/重做的显示名（菜单项文字，如 "撤销 体素编辑"）。
func undo_label() -> String:
	return (commands[cursor - 1] as QVoxelCommand).get_label() if can_undo() else ""


func redo_label() -> String:
	return (commands[cursor] as QVoxelCommand).get_label() if can_redo() else ""


## 丢弃 redo 分支（新操作入栈时调用 —— 标准撤销语义）。
func truncate_redo() -> void:
	if cursor >= commands.size():
		return
	commands.resize(cursor)


func total_cost() -> int:
	var c := 0
	for cmd in commands:
		c += (cmd as QVoxelCommand).get_cost()
	return c


func clear() -> void:
	super()
	_macro_open.clear()  # 开着的宏一并丢弃：clear() 的语义是"完全重置"，留半截宏只会让下次 end_macro 打在对不上的地方
	cursor = 0
	changed.emit()


## 【刻意不实现"从存档恢复"】存档里只有参数记录，没有 undo() 能用的差值，恢复出来会是一个
## "看着能撤销、按下去就报错"的栈。明确报错好过静默给一个假栈。
func load_data(_data) -> void:
	push_error("[QVX] 撤销栈是会话内的，不从存档恢复；持久化请把 CommandHistory 另存。")


func _enforce_budget() -> void:
	if max_cost <= 0:
		return
	var total := total_cost()
	while total > max_cost and commands.size() > 1:
		total -= (commands[0] as QVoxelCommand).get_cost()
		commands.remove_at(0)
		cursor = maxi(cursor - 1, 0)
