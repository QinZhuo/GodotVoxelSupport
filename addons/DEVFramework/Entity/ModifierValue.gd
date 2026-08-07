class_name ModifierValue extends Entity

var def: Def

var tags: Array[TagDef]:
	get(): return def.tags

var _modifiers: Array = []
var _value: int = 0
var _base_value: int = 0

var value: int:
	get:
		return _value
	set(_new_value):
		LogTool.error("修饰值", "不允许直接修改属性[", def, "]的value，请使用base_value或add_modifier", def, _new_value)

var base_value: int:
	get:
		return _base_value
	set(new_value):
		if _base_value == new_value:
			return
		_base_value = new_value
		_recompute()

func add_modifier(modifier: Modifier):
	_modifiers.append(modifier)
	_recompute(modifier)

func apply_modifier(modifier: Modifier):
	var new_value := modifier.apply(_base_value)
	if _base_value == new_value:
		return
	_base_value = new_value
	_recompute(modifier)

func remove_modifiers(source):
	var kept := []
	for m in _modifiers:
		if m.source != source:
			kept.append(m)
	if kept.size() != _modifiers.size():
		_modifiers = kept
		_recompute()

func clear_modifiers(source = null):
	if source == null:
		if not _modifiers.is_empty():
			_modifiers.clear()
			_recompute()
	else:
		remove_modifiers(source)

func reset():
	_base_value = 0
	_modifiers.clear()
	if _value != 0:
		_value = 0
		value_changed.emit(null)

func _recompute(modifier: Modifier = null):
	var v := _base_value
	for m in _modifiers:
		v = m.apply(v)
	if _value == v:
		return
	_value = v
	value_changed.emit(modifier)

signal value_changed(modifier: Modifier)

func get_view_name():
	return def.name

func get_desc(data):
	return def.get_desc(data)
