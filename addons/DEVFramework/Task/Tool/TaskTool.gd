class_name TaskTool

## 任务跟踪表(可选基建): 显式注册任务, 提供"活动列表 / 按 Def 查找 / 聚合存读档"。
##
## 框架不做隐式生命周期 —— 注册与注销由调用方控制(与 Task 系统的"外部驱动"一致);
## 任务进入终态(完成/失败/取消)时自动从 active 移入 finished。
## 典型用法: 教程/任务管理器共用一张表 —— 界面读 get_active() 画任务日志, 存档时 save_all()。
##
## 注意: 静态表持有任务强引用, 场景销毁时请 untrack(或整表 clear), 否则任务不会被释放。

static var _active: Array[Task] = []
static var _finished: Array[Task] = []


## 注册任务(重复注册忽略; 终态时自动转入 finished)
static func track(task: Task) -> void:
	if task == null or _active.has(task) or _finished.has(task):
		return
	_active.append(task)
	task.completed.connect(_on_terminal.bind(task))
	task.failed.connect(_on_terminal.bind(task))
	task.cancelled.connect(_on_terminal.bind(task))


## 注销任务(场景销毁/不再关心时调用, 释放强引用)
static func untrack(task: Task) -> void:
	if task == null:
		return
	_active.erase(task)
	_finished.erase(task)


## 活动中任务(含前置被拒而未激活的)
static func get_active() -> Array[Task]:
	return _active

## 已结束任务(终态)
static func get_finished() -> Array[Task]:
	return _finished


## 按 Def 查找(先活动表后已结束表; key 为 Def 相对路径, 内置 Def 退化为 resource_name)
static func find(def_key: String) -> Task:
	for t in _all():
		if _key_of(t) == def_key:
			return t
	return null


## 聚合存档: {def_key: save_data}。无 Def 路径的内置任务无法还原, 跳过并告警。
static func save_all() -> Dictionary:
	var out := {}
	for t in _all():
		var key := _key_of(t)
		if key.is_empty():
			continue
		out[key] = t.save_data()
	return out


## 聚合读档: 按存档逐条 Task.restore 并注册, 返回还原出的任务列表。
## [param data] 上下文(全部任务共用一份; 通常为宿主节点)
static func load_all(saved: Dictionary, data = null) -> Array[Task]:
	var out: Array[Task] = []
	for key: String in saved:
		var task := Task.restore(saved[key], data)
		if task == null:
			continue
		track(task)
		out.append(task)
	return out


## 清空跟踪表(不 touch 任务本身)
static func clear() -> void:
	_active.clear()
	_finished.clear()


static func _all() -> Array:
	var out: Array = []
	out.append_array(_active)
	out.append_array(_finished)
	return out

## 存档键: 优先 Def 相对路径; 无路径的内置 Def 用 resource_name(仅运行期查找用, 不可存档)
static func _key_of(task: Task) -> String:
	if task.def == null:
		return ""
	if task.def.resource_path.is_empty():
		return task.def.name
	return task.def.save_data()

static func _on_terminal(task: Task) -> void:
	_active.erase(task)
	if not _finished.has(task):
		_finished.append(task)
