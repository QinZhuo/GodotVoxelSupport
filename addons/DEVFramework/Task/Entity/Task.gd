@abstract
## 任务实体抽象基类。子类：SignalTask（信号驱动）、CountTask（计数）、GroupTask（分组）。
##
## 状态机: INACTIVE → ACTIVE → COMPLETED / FAILED / CANCELLED（终态不可再激活）。
## 存档约定: save_data() 只存 "Def 路径 + 状态 + 子进度", 不存运行时信号连接;
## 读档用 Task.restore(dict, data) 一步重建(含子任务树), 或 task.load_data(dict) 就地恢复。
class_name Task extends Entity

var def: TaskDef:
	set(value):
		def = value
		entity_changed.emit()

signal completed()
## 失败(超时/判定不通过, 由外部或派生逻辑调用 fail() 触发)
signal failed()
## 取消(玩家放弃/被替换, 调 cancel() 触发; 与 stop 的区别: stop 不发任何终态信号)
signal cancelled()
## 前置条件未满足, activate 被拒绝(任务保持 INACTIVE)
signal blocked()
## 进度变化(子任务推进/计数累加) —— 供 UI(进度条/"第 2/5 步")刷新。
## 与 entity_changed 的区别: 后者表示"当前指向的 def 变了", 前者表示"完成进度变了"。
signal progress_changed()

var _data
var _handler: Callable
var _status = TaskDef.Status.INACTIVE  # TaskDef.Status(不注解枚举类型, 便于从存档 int 还原)


## 任务状态(只读; 由 activate/complete/fail/cancel 驱动)
var status: TaskDef.Status:
	get:
		return _status

var is_active: bool:
	get:
		return _status == TaskDef.Status.ACTIVE

var is_completed: bool:
	get:
		return _status == TaskDef.Status.COMPLETED

## 是否终态(完成/失败/取消, 不可再激活或重置)
var is_terminal: bool:
	get:
		return _status >= TaskDef.Status.COMPLETED


static func create(task_def: TaskDef) -> Task:
	return task_def.create_entity()


## 由存档重建任务实体(含 def 与子任务结构), 无需先 activate。
## [param dict] save_data() 的返回值
## [param data] 可选上下文; 提供则立即激活到存档进度, 否则由调用方稍后 activate(data)(会从存档进度继续, 不重跑已完成步骤)
## [return] 还原出的任务; def 缺失或资源加载失败返回 null
static func restore(dict: Dictionary, data = null) -> Task:
	var task_def := _def_from_data(dict)
	if task_def == null:
		LogTool.warn("任务", "存档中的 def 无法还原, 丢弃该任务: ", dict.get("def", ""))
		return null
	var task := create(task_def)
	task.load_data(dict, data)
	return task


## 激活: 状态 → ACTIVE 并接入完成监听。
## 终态任务不可激活; 配了 prerequisite 且条件未满足时拒绝激活(保持 INACTIVE, 发 blocked)。
func activate(data) -> void:
	if is_terminal:
		return
	if def and def.prerequisite and not def.prerequisite.is_met(data):
		blocked.emit()
		return
	if _status == TaskDef.Status.ACTIVE:
		_teardown()             # 重复激活: 先断旧监听
	_data = data
	_status = TaskDef.Status.ACTIVE
	_apply_skip_if(data)

## skip_if 门控: 条件已满足则视为"已达成"直接完成(GroupTask 覆写为整组语义)
func _apply_skip_if(data) -> void:
	if def and def.skip_if and def.skip_if.is_met(data):
		complete()

## 静默置为完成(不发信号/不执行 next) —— 供 GroupTask 整组跳过时标记子任务
func _mark_completed() -> void:
	if is_terminal:
		return
	_teardown()
	_status = TaskDef.Status.COMPLETED

## 停用: 断开监听, 状态回到 INACTIVE(终态任务不受影响)
func deactivate() -> void:
	if is_terminal:
		return
	_teardown()
	_status = TaskDef.Status.INACTIVE

## 断开监听/清理挂起回调(子类覆写; 与状态无关的纯机械清理)
func _teardown() -> void:
	pass

## 手动完成: 状态 → COMPLETED, 先执行 next 再广播 completed
func complete() -> void:
	if is_terminal:
		return
	_teardown()
	_status = TaskDef.Status.COMPLETED
	_apply_next()
	completed.emit()

## 失败(终态)
func fail() -> void:
	if is_terminal:
		return
	_teardown()
	_status = TaskDef.Status.FAILED
	failed.emit()

## 取消(终态)
func cancel() -> void:
	if is_terminal:
		return
	_teardown()
	_status = TaskDef.Status.CANCELLED
	cancelled.emit()

## 重置回未激活(可重复任务用; 清空进度但不重放奖励)
func reset() -> void:
	_teardown()
	_status = TaskDef.Status.INACTIVE

## 当前描述的文本
func get_current_desc() -> String:
	return def.get_desc(null)

## 完成进度: x = 已完成数, y = 总数。无子进度的任务为 0/1 或 1/1。
func get_progress() -> Vector2i:
	return Vector2i(1 if is_completed else 0, 1)

## 序列化
func save_data() -> Dictionary:
	return {def = _def_to_data(), status = _status, is_completed = is_completed}

## 反序列化(就地恢复到存档状态; def 由 restore() 负责还原, 这里不动)。
## [param dict] save_data() 的返回值
## [param data] 上下文; 为空时沿用 activate() 传入的上下文(可先载档、后激活)
func load_data(dict: Dictionary, data = null) -> void:
	if data != null:
		_data = data
	if dict.has("status"):
		_status = clampi(int(dict.get("status")), 0, TaskDef.Status.CANCELLED)
	else:
		# 兼容只有 is_completed 的旧存档
		_status = TaskDef.Status.COMPLETED if dict.get("is_completed", false) else TaskDef.Status.INACTIVE
	_resume_from_save()
	entity_changed.emit()
	progress_changed.emit()

## 读档后重建监听(状态为 ACTIVE 且已有上下文时; 子类覆写)
func _resume_from_save() -> void:
	pass


# --- 内部 ---

## 执行任务完成动作(apply 以 activate 传入的上下文)
func _apply_next() -> void:
	if def and def.next:
		def.next.apply(_data)

## Def → 存档值(相对 res://Assets/Def/ 的短路径; 无路径的内置 Def 无法还原)
func _def_to_data():
	if def == null:
		return ""
	if def.resource_path.is_empty():
		# 运行时 new 出来 / 内嵌 SubResource 的 Def 没有资源路径, 存档后无法还原
		LogTool.warn("任务", "Def 无资源路径, 存档后无法还原: ", def)
		return ""
	return def.save_data()

## 存档值 → TaskDef(兼容直接内嵌 Def 对象与路径两种写法)
static func _def_from_data(dict: Dictionary) -> TaskDef:
	var raw = dict.get("def")
	if raw is TaskDef:
		return raw
	if raw is String and not (raw as String).is_empty():
		return Def.load_data(raw) as TaskDef
	return null
