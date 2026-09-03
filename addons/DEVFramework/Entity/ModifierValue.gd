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
	# 分阶段聚合(GAS 式固定公式): (base + ΣVALUE) × ΠPERCENT, 内部浮点消截断, 对外取整
	# 消除修饰器插入顺序导致的非确定性(旧实现按列表顺序逐个应用, 混用两种模式时结果依赖添加顺序)
	var acc := float(_base_value)
	var percent := 1.0
	for m in _modifiers:
		if m.mode == Modifier.Mode.VALUE:
			acc += m.value
		else:
			percent *= m.value / 100.0
	var v := int(round(acc * percent))
	if _value == v:
		return
	_value = v
	value_changed.emit(modifier)

signal value_changed(modifier: Modifier)

func get_view_name():
	return def.name

func get_desc(data):
	return def.get_desc(data)
