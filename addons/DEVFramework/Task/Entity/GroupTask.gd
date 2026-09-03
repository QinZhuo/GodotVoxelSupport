## 分组任务实体 — 由 GroupTaskDef 驱动，管理多个子任务完成。
class_name GroupTask extends Task

## 某个子任务完成(index 为其在 tasks 中的下标, child 为子任务实体) —— 供任务日志/埋点
signal child_completed(index: int, child: Task)
## 进入某个子步骤(游标所指; SEQUENTIAL 下每步一次) —— 供"分步驱动 UI"(教程/日志/进度条)直接订阅,
## 免去外部转发器。激活首步与每步推进后都会发; 被 skip 跳过的步骤不发。
signal step_entered(step: Task)

var _child_entities: Array[Task] = []
var _active_child_index: int = 0
var _completed_count: int = 0


func activate(data) -> void:
	super(data)
	if not is_active:
		return    # 终态, 或 prerequisite 未满足被拒绝(保持 INACTIVE)
	# 已有子实体时(重复 activate / 先 load_data 后 activate)从存档进度继续, 不重建子任务
	if _child_entities.is_empty():
		_activate_children(data)
	else:
		_resume_children(data)
	_emit_step_entered()

func get_current_desc() -> String:
	if _active_child_index < _child_entities.size():
		return _child_entities[_active_child_index].get_current_desc()
	return def.get_desc(null)

func get_progress() -> Vector2i:
	return Vector2i(_completed_count, _child_entities.size())

## 当前活跃子任务的 def
## 注意: 仅 SEQUENTIAL 下"活跃"唯一; ANY_ORDER / COMPLETE_ANY 可能多步并发,
## 此 getter 仅返回"游标(最早切换到的)所指"步骤, 不代表"唯一进行中"。教程用 SEQUENTIAL 无碍。
var active_child_def: TaskDef:
	get:
		var group := def as GroupTaskDef
		if not group or _active_child_index >= _child_entities.size():
			return null
		return group.tasks[_active_child_index]

## 当前活跃子任务实体
## 注意: 仅 SEQUENTIAL 下"活跃"唯一; ANY_ORDER / COMPLETE_ANY 多步并发时,
## 此 getter 返回"游标所指"的那个, 语义为"当前指向的步骤", 而非"唯一的进行中步骤"。
var active_child_entity: Task:
	get:
		if _active_child_index >= _child_entities.size():
			return null
		return _child_entities[_active_child_index]

## 重置整组(可重复任务用): 子任务全部复位, 进度归零
func reset() -> void:
	for child in _child_entities:
		child.reset()
	_recompute_progress()
	super()


func _activate_children(data) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	for i in group.tasks.size():
		var sub_def: TaskDef = group.tasks[i]
		var child := Task.create(sub_def)
		_child_entities.append(child)
		child.completed.connect(_on_child_completed.bind(i))
	# 先建齐再激活: 子任务 skip_if 命中会级联完成并推进到下一个, 依赖子任务已全部存在
	for i in _child_entities.size():
		var child := _child_entities[i]
		if group.mode == GroupTaskDef.Mode.SEQUENTIAL and i > 0:
			continue
		child.activate(data)
		if group.mode == GroupTaskDef.Mode.COMPLETE_ANY:
			break

## 组级 skip_if: 整组跳过 —— 子任务静默标记完成后整组完成(不发子任务信号/不执行 next)
func _apply_skip_if(data) -> void:
	var group := def as GroupTaskDef
	if not group or not group.skip_if or not group.skip_if.is_met(data):
		return
	if _child_entities.is_empty():
		_ensure_children()
	for child in _child_entities:
		child._mark_completed()
	_recompute_progress()
	complete()

## 从当前进度恢复子任务激活(只激活"该激活的"那几个, 已完成的不重跑)
func _resume_children(data) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	match group.mode:
		GroupTaskDef.Mode.SEQUENTIAL:
			if _active_child_index < _child_entities.size():
				_child_entities[_active_child_index].activate(data)
		GroupTaskDef.Mode.ANY_ORDER:
			for child in _child_entities:
				if not child.is_completed:
					child.activate(data)
		GroupTaskDef.Mode.COMPLETE_ANY:
			# 原语义: 只激活首个未完成的子任务, 任一完成即结束
			for child in _child_entities:
				if not child.is_completed:
					child.activate(data)
					break

## 断开全部子任务(子类清理协议; 本组状态由基类处理)
func _teardown() -> void:
	for child in _child_entities:
		child.deactivate()

func _on_child_completed(child_index: int) -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	_completed_count += 1
	match group.mode:
		GroupTaskDef.Mode.SEQUENTIAL:
			_active_child_index = child_index + 1
			if _active_child_index < _child_entities.size():
				_child_entities[_active_child_index].activate(_data)
			else:
				complete()
		GroupTaskDef.Mode.ANY_ORDER:
			if _completed_count >= _child_entities.size():
				complete()
		GroupTaskDef.Mode.COMPLETE_ANY:
			complete()
	child_completed.emit(child_index, _child_entities[child_index])
	_emit_step_entered()
	entity_changed.emit()
	progress_changed.emit()


## 发出"进入当前步骤"信号(游标所指且未完成才发; 整组完成/被跳过的步骤不发)
func _emit_step_entered() -> void:
	var step := active_child_entity
	if step and not step.is_completed:
		step_entered.emit(step)

func save_data() -> Dictionary:
	var dict: Dictionary = {
		def = _def_to_data(),
		status = _status,
		is_completed = is_completed,
		children = [],
	}
	for child in _child_entities:
		dict.children.append(child.save_data())
	return dict

func load_data(dict: Dictionary, data = null) -> void:
	if data != null:
		_data = data
	var children: Array = dict.get("children", [])
	_ensure_children()                      # 按 def 建齐子实体(幂等, 重复调用不重建)
	for i in children.size():
		if i < _child_entities.size():
			_child_entities[i].load_data(children[i])
	_recompute_progress()
	super(dict, data)                       # 还原状态 + _resume_from_save()


## 按 def 建立缺失的子实体(已存在则复用, 保证 activate/load_data 可重复调用)
func _ensure_children() -> void:
	var group := def as GroupTaskDef
	if not group:
		return
	for i in group.tasks.size():
		if i < _child_entities.size():
			continue
		var child := Task.create(group.tasks[i])
		_child_entities.append(child)
		child.completed.connect(_on_child_completed.bind(i))

## 依据子任务完成状态重算进度游标(游标 = 首个未完成子任务; 全完成时为 size)
func _recompute_progress() -> void:
	_completed_count = 0
	_active_child_index = _child_entities.size()
	for i in _child_entities.size():
		if _child_entities[i].is_completed:
			_completed_count += 1
		elif _active_child_index == _child_entities.size():
			_active_child_index = i

## 读档后恢复: 全部子任务已完成则收尾; 未完成且有上下文则激活当前步骤(不重跑已完成步骤)
func _resume_from_save() -> void:
	if is_completed:
		return
	if _active_child_index >= _child_entities.size():
		complete()
		return
	if _status == TaskDef.Status.ACTIVE and _data != null:
		_resume_children(_data)
