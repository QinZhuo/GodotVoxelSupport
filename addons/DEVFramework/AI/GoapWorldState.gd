class_name GoapWorldState extends RefCounted

## GOAP 世界状态 — 一组键值对，描述 Agent 对世界的认知。
## 键通常为 StringName，值为任意可比较的 Variant（bool / int / String 等）。
## 提供"部分匹配"与"应用效果"两个核心操作，供规划器与行动使用。

var _values: Dictionary = {}

signal changed(key, old_value, new_value)


func set_value(key, value) -> void:
	var old := _values.get(key, null)
	if old == value:
		return
	_values[key] = value
	changed.emit(key, old, value)


func get_value(key, default = null):
	return _values.get(key, default)


func has(key) -> bool:
	return _values.has(key)


func has_value(key, value) -> bool:
	return _values.has(key) and _values[key] == value


func erase(key) -> bool:
	if not _values.has(key):
		return false
	_values.erase(key)
	changed.emit(key, null, null)
	return true


## partial 中的每一项都与当前状态一致则视为"满足"。
## 当前状态可以包含 partial 之外的键（允许额外信息）。
func matches(partial: Dictionary) -> bool:
	for key in partial:
		if not _values.has(key) or _values[key] != partial[key]:
			return false
	return true


## 将 effects 合并进当前状态（行动成功后调用）。
func apply(dict: Dictionary) -> void:
	for key in dict:
		set_value(key, dict[key])


## 用另一份字典整体覆盖（用于初始化）。
func reset(dict: Dictionary = {}) -> void:
	_values = dict.duplicate()


func copy() -> GoapWorldState:
	var ws := GoapWorldState.new()
	ws._values = _values.duplicate()
	return ws


func to_dict() -> Dictionary:
	return _values.duplicate()


func clear() -> void:
	_values.clear()


func size() -> int:
	return _values.size()


func _to_string() -> String:
	return str(_values)
