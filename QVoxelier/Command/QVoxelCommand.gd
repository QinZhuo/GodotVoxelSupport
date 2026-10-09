@tool
class_name QVoxelCommand
extends GameCommand
## 一条可撤销的编辑操作 —— 撤销栈的基本单位。
##
## 【为什么继承框架的 GameCommand，而不是自造一套记录格式】
## 撤销栈与会话命令日志记录的是同一件事：**一次操作**。区别只在于"还能不能撤"：
##   GameCommand   参数记录 —— 可序列化、可回放、可审计（框架 CommandHistory 的用途）
##   QVoxelCommand   + 活的对象引用与 undo()/redo() —— 只有栈里的实例需要
## 于是不必另立格式：命令**本身就是**一条 GameCommand —— type 是操作类型、tick 是会话
## 时序号、params 是操作参数。save_data() / load_data() 白得，撤销历史因此天然是一份
## 可审计、可回放的记录流，而不是一个只能原地撤销的黑盒。
##
## 【分层：本类在应用层（QVoxelier），不在插件内核】
## 它需要引用 DEVFramework，而 addons/VoxelSupport 与 addons/DEVFramework 两个插件之间
## 必须零引用（否则任一插件都无法独立装卸、独立演化）。撤销是**应用**能力（谁响应 Ctrl+Z、
## 是否连框架的历史一起记、UI 怎么展示），不是内核能力 —— 内核只提供被操作的数据。
## 依赖方向因此是单向的：QVoxelier → {VoxelSupport, DEVFramework}。
##
## 【两条设计约束，都源于"体素数据太大"】
## ① 只记差值，不记全量快照：256³ 是 64 MB，每落一笔存一份会瞬间爆内存。
##    QVoxelEditCommand 只在**块被首次改动时**抓该块的原地快照。
## ② 手势即命令（不学 Qt 的 QUndoCommand.mergeWith）：合并要处理包围盒并集与中间态，
##    很容易错。改为"拖拽期间写数据，松手时封口成一条命令"，对外语义相同，
##    但一行合并逻辑都不需要。
##
## 【params 里不放重量级数据】撤销栈是会话内的（Blender / MagicaVoxel 都不存撤销历史），
## 所以体素差值由子类持有即可、不进 params —— 否则 save_data() 出来的"可回放记录"会变成
## 一份体素存档。该回放的是"用户做了什么"（动作、位置、笔刷半径），不是"每个格子原来是什么"。

## 执行/重放本命令。
##
## 【必须幂等】语义是"把状态置为 after"，而不是"施加一个增量"。因为多数情况下数据已被工具
## 就地改过：push() 时会调一次 redo()，那次调用必须无副作用（否则数据被改两遍）。
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
##
## 【返回空数组 = 影响整对象】结构性改动（换修改器链、改分辨率、换材质表）没有"局部"可言。
## 默认给空数组而不是"一个空范围"：空范围的含义是"什么都没变"，而基类的默认语义恰恰相反 ——
## 未覆写的命令一定动了某些非体素的东西，保守地整对象刷新才是安全的那一侧。
##
## 【为什么做成虚函数而不是让视口判类型】视口若写 `if cmd is QVoxelEditCommand`，每加一种
## 命令都要回去改视口；而"刷新粒度"本来就是命令自己的知识 —— 只有它知道自己动了哪儿。
func dirty_bounds() -> Array[Vector3i]:
	var none: Array[Vector3i] = []
	return none
