class_name GoapWorldState extends RefCounted

## GOAP 世界状态 — 一组键值对，描述 Agent 对世界的认知。

var _values: Dictionary = {}

signal changed(key, old_value, new_value)

## 稳定指纹(键排序) —— 供计划缓存做 key: 只反映**值**, 不含对象身份。
func fingerprint() -> String:
	var keys := _values.keys()
	keys.sort_custom(func(a, b) -> bool: return str(a) < str(b))
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(_values[k])])
	return ";".join(parts)

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
