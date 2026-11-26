@tool
class_name QVoxelPropertyCommand
extends QVoxelCommand
## 一次**属性赋值**的撤销记录 —— 对象改名、修改器参数、链的增删重排全部收敛到这一条。

## 被写属性的目标：QVoxelModel，或它的某个 QVoxelModifier 子资源。
var target: Object

## 属性名（即 target.set(property, ...) / target.get(property) 的键）。
var property: StringName

## 改动前 / 改动后的值。
var before: Variant
var after: Variant

## 需要标脏的宿主对象（改它发 content_changed）。
var owner: QVoxelNode

## 与主属性**一起**撤销/重做的附加属性写入，每项 = {target, property, before, after}。
var extras: Array = []

var _label := ""

func _init(p_target: Object, p_property: StringName, p_owner: QVoxelNode = null,
		p_label := "") -> void:
	super(&"property", -1, [])
	target = p_target
	property = p_property
	owner = p_owner if p_owner != null else (p_target as QVoxelNode)
	_label = p_label
	before = _snapshot(_read())

## 追加一项"与本命令同生共死"的属性写入。
func also_write(p_target: Object, p_property: StringName) -> void:
	if p_target == null:
		return
	extras.append({
		"target": p_target,
		"property": p_property,
		"before": _snapshot(p_target.get(p_property)),
		"after": null,
	})

# 工具接口（调用方只碰这几个方法）

## 开始一次属性手势。
static func begin(p_target: Object, p_property: StringName, p_owner: QVoxelNode = null,
		p_label := "") -> QVoxelPropertyCommand:
	return QVoxelPropertyCommand.new(p_target, p_property, p_owner, p_label)

## 一步到位：begin + set_value + commit。
static func apply(p_target: Object, p_property: StringName, value: Variant,
		p_owner: QVoxelNode = null, p_label := "") -> QVoxelPropertyCommand:
	var c := QVoxelPropertyCommand.new(p_target, p_property, p_owner, p_label)
	c.set_value(value)
	return c if c.commit() else null

## 写入新值（手势期间可调用多次，after 取最后一次）。
func set_value(value: Variant) -> void:
	if target == null:
		return
	target.set(property, value)

## 手势结束，封口成一条可入栈的命令。
func commit() -> bool:
	if target == null:
		return false
	after = _snapshot(_read())
	var changed: bool = before != after
	for e in extras:
		# 附加项只要有一项真变了，这一笔就该入栈 —— 否则"只搬了体素源、帧数组恰好没变"的操作会丢
		e["after"] = _snapshot((e["target"] as Object).get(e["property"]))
		if e["before"] != e["after"]:
			changed = true
	if not changed:
		return false
	params = [String(property)]
	if _is_audit_safe(after):
		params.append(after)
	return true

func get_label() -> String:
	return _label if not _label.is_empty() else "属性 %s" % String(property)

## O(1)：只记一个值，不抓体素。
func get_cost() -> int:
	return 1

func redo() -> void:
	_apply(after)
	for e in extras:
		_write(e, e["after"])

func undo() -> void:
	_apply(before)
	for e in extras:
		_write(e, e["before"])

# 内部

## 写回并标脏。
func _apply(v: Variant) -> void:
	if target == null:
		push_error("[QVX] 属性命令的目标已不存在（%s）" % String(property))
		return
	target.set(property, v)
	if owner != null:
		owner.content_changed.emit()

## 写回一项附加属性。
func _write(e: Dictionary, v: Variant) -> void:
	var t: Object = e["target"]
	if t == null:
		push_error("[QVX] 属性命令的附加目标已不存在（%s）" % String(e["property"]))
		return
	t.set(e["property"], v)

func _read() -> Variant:
	return null if target == null else target.get(property)

## 抓一份"不会被后续写入改到"的值。
func _snapshot(v: Variant) -> Variant:
	if v is Array:
		return (v as Array).duplicate()
	if v is Dictionary:
		return (v as Dictionary).duplicate()
	return v

## 该值是否适合写进 params（命令流的可审计描述）。
func _is_audit_safe(v: Variant) -> bool:
	return v == null or v is bool or v is int or v is float or v is String
