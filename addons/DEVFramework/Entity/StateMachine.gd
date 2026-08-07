extends RefCounted
class_name StateMachine

# 通用有限状态机，用于流程/场景级状态管理（不做小对象级状态）。
#
# 用法:
#   var sm = StateMachine.new(State.Start)
#   sm.add_transition(State.Start, State.Shop)
#   sm.on_enter(State.Shop, _on_enter_shop)     # 支持异步（带 await 函数）
#   sm.on_exit(State.Shop, _on_exit_shop)
#   await sm.transition(State.Shop)              # 异步切换（会 await guard/exit/enter）
#   sm.force_set(State.Start)                    # 强制设置（不触发回调）
#   sm.allow_self_transition(true)               # 允许自身到自身的转换
#
# 注意:
#   - transition() 是异步函数（内部可能 await 回调），需要时请 await。
#   - 不要用它替换大量短生命周期对象的状态（如每个 Symbol），适合管理流程类。
#   - 回调返回 GDScriptFunctionState 时会自动 await 完成。

signal state_changed(from, to)

var _current = -1
var _transitions = {}
var _enter_callbacks = {}
var _exit_callbacks = {}
var _guards = {}
var _allow_self_transition = false
var _debug = false

func _init(initial_state = -1):
	_current = initial_state
	if _debug:
		LogTool.log("状态机", "初始化，初始状态:", str(_current))

func current():
	return _current

func is_state(s):
	return _current == s

func add_transition(from, to):
	if not _transitions.has(from):
		_transitions[from] = []
	if not _transitions[from].has(to):
		_transitions[from].append(to)
	return self

func add_transitions(from, to_list):
	for to in to_list:
		add_transition(from, to)
	return self

func on_enter(state, callback):
	_enter_callbacks[state] = callback
	return self

func on_guard(state, guard_callable):
	_guards[state] = guard_callable
	return self

func on_exit(state, callback):
	_exit_callbacks[state] = callback
	return self

func can_transition(to):
	if _current == to and not _allow_self_transition:
		return false
	if not _transitions.has(_current):
		return false
	return _transitions[_current].has(to)

func transition(to):
	if not can_transition(to):
		if _debug:
			LogTool.warn("状态机", "无法转换", str(_current), "->", str(to))
		return false
	var from = _current
	if _guards.has(to):
		var guard_res = _guards[to].call(from, to)
		if typeof(guard_res) == TYPE_OBJECT:
			guard_res = await guard_res
		if guard_res == false:
			if _debug:
				LogTool.warn("状态机", "守卫阻止了转换", str(from), "->", str(to))
			return false
	if _exit_callbacks.has(from):
		var res = _exit_callbacks[from].call()
		if typeof(res) == TYPE_OBJECT:
			await res
	_current = to
	state_changed.emit(from, to)
	if _enter_callbacks.has(to):
		var res2 = await _enter_callbacks[to].call()
		if typeof(res2) == TYPE_OBJECT:
			await res2
	if _debug:
		LogTool.log("状态机", "转换成功", str(from), "->", str(to))
	return true

func force_set(state):
	var from = _current
	_current = state
	if from != state:
		state_changed.emit(from, state)
	if _debug:
		LogTool.log("状态机", "强制设置状态", str(from), "->", str(state))

func allow_self_transition(v):
	_allow_self_transition = v
	return self

func set_debug(v):
	_debug = v
	return self

func get_allowed_transitions(state):
	return _transitions.get(state, [])

func clear_transitions():
	_transitions.clear()

func clear_callbacks():
	_enter_callbacks.clear()
	_exit_callbacks.clear()
