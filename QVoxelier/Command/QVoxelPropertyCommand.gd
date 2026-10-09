@tool
class_name QVoxPropertyCommand
extends QVoxCommand
## 一次**属性赋值**的撤销记录 —— 对象改名、修改器参数、链的增删重排全部收敛到这一条。
##
## 【为什么"链编辑"也归它管，而不是另立一条链命令】`modifiers` 本身就是对象上的一个
## `@export var`：加一条修改器 = 它的前后两份数组，重排 = 同一个数组的两种顺序，删一条同理。
## 既然撤销要的料完全一样 ——（目标, 属性名, 改前, 改后）—— 让增/删/排各写一个命令类
## 就是同一段采集逻辑抄三遍，且迟早有一处忘了采"改后"。工具因此只剩一件事要做：
## **把改动夹在 begin() 与 commit() 之间**（QVoxModel 的链编辑入口注释即此约定）。
##
## 【为什么代价是 O(1)，以及它**不能**干什么】属性命令不抓任何体素，前后两个值就是它的全部
## 内存（数组属性也只存**引用**的浅副本），于是它不参与撤销栈的预算淘汰考量。代价是：
## **不能用它撤销 resize_grid()** —— 改分辨率会丢掉超出新尺寸的体素，而"被丢掉的体素"
## 只能由记差值的 QVoxVoxelEditCommand 记住。改分辨率请走体素命令。
##
## 【为什么由命令标脏，而不是让对象自己监听】QVoxModifier 是 Resource，Godot 不会替我们监听
## 它的 @export 改动，所以 QVoxModel 只在自己结构变化时发 content_changed；
## "改参数要标脏"由本命令在 redo/undo 之后补发（见 QVoxModel.content_changed 的注释）。
##
## 【手势即命令】滑条拖拽期间反复 set_value()，松手时 commit() 一次 —— 与体素手势同构，
## 于是全项目只有一条"**手势期间静默写数据、封口时才入栈**"的时间线，不需要 Qt 那种
## mergeWith（理由见 QVoxCommand）。set_value() 刻意**不发信号**：live 预览由发起手势的面板
## 自己刷新，否则一次拖拽会触发成千上万次整链重算。

## 被写属性的目标：QVoxModel，或它的某个 QVoxModifier 子资源。
var target: Object

## 属性名（即 target.set(property, ...) / target.get(property) 的键）。
var property: StringName

## 改动前 / 改动后的值。
var before: Variant
var after: Variant

## 需要标脏的宿主对象（改它发 content_changed）。target 本身就是节点时自动取它；
## 改修改器参数时必须显式传入 —— 否则没有对象会收到信号，视口会一直显示旧结果。
##
## 【为什么是 QVoxNode 而不是 QVoxModel】"改参数要标脏"这条对**组**的链同样成立
## （组的链作用在子树合成结果上，见 QVoxNode 的"为什么组也能挂修改器"），而 content_changed
## 就定义在 QVoxNode 上 —— 收窄成 QVoxModel 会让"改组的可见性 / 改组的链参数"当场类型报错。
var owner: QVoxNode

var _label := ""


func _init(p_target: Object, p_property: StringName, p_owner: QVoxNode = null,
		p_label := "") -> void:
	super(&"property", -1, [])
	target = p_target
	property = p_property
	owner = p_owner if p_owner != null else (p_target as QVoxNode)
	_label = p_label
	before = _snapshot(_read())


# ----------------------------------------------------------------------------
# 工具接口（调用方只碰这几个方法）
# ----------------------------------------------------------------------------

## 开始一次属性手势。**必须在任何写入之前调用**：before 只能从"还没改过"的状态里抓。
static func begin(p_target: Object, p_property: StringName, p_owner: QVoxNode = null,
		p_label := "") -> QVoxPropertyCommand:
	return QVoxPropertyCommand.new(p_target, p_property, p_owner, p_label)


## 一步到位：begin + set_value + commit。无实际变化时返回 null（调用方据此不要 push）。
static func apply(p_target: Object, p_property: StringName, value: Variant,
		p_owner: QVoxNode = null, p_label := "") -> QVoxPropertyCommand:
	var c := QVoxPropertyCommand.new(p_target, p_property, p_owner, p_label)
	c.set_value(value)
	return c if c.commit() else null


## 写入新值（手势期间可调用多次，after 取最后一次）。**不发信号**，理由见文件头。
##
## 只是个方便入口 —— 用不用它都行：把工具自己的接口（QVoxModel.add_modifier 等）夹在
## begin() 与 commit() 之间同样成立，因为封口判据看的是**首尾值**，不是"谁写的"。
func set_value(value: Variant) -> void:
	if target == null:
		return
	target.set(property, value)


## 手势结束，封口成一条可入栈的命令。返回"是否真的改了东西" ——
## 返回 false 时调用方**不要 push**（滑条拖回原位、把值设成原样都不该占一次撤销）。
##
## 【判据只有一条：首尾值是否相同】刻意不去记"中间写过没有"：拖拽的中间值没有意义，
## 用户关心的是"松手时和开始时一样不一样"；而记住"写过"反而会把
## "begin → 调工具接口写入 → commit"这条主用法（链的增删重排）误判成空手势。
func commit() -> bool:
	if target == null:
		return false
	after = _snapshot(_read())
	if before == after:
		return false
	params = [String(property)]
	if _is_audit_safe(after):
		params.append(after)
	return true


func get_label() -> String:
	return _label if not _label.is_empty() else "属性 %s" % String(property)


## O(1)：只记一个值，不抓体素。撤销栈的预算淘汰因此不会把它当负担。
func get_cost() -> int:
	return 1


func redo() -> void:
	_apply(after)


func undo() -> void:
	_apply(before)


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 写回并标脏。**必须幂等**（push() 时会调一次 redo()，而数据通常已被工具改过）。
func _apply(v: Variant) -> void:
	if target == null:
		push_error("[QVox] 属性命令的目标已不存在（%s）" % String(property))
		return
	target.set(property, v)
	if owner != null:
		owner.content_changed.emit()


func _read() -> Variant:
	return null if target == null else target.get(property)


## 抓一份"不会被后续写入改到"的值。
##
## 【必须拷贝】Array / Dictionary 是**引用**类型，直接存会让 before 与活数组别名化 ——
## 表现是"撤销后拿到的是改完之后的内容"，而且完全不报错。
## 【只能浅拷贝】深拷贝会把修改器连同它的算子树一起克隆，"撤销一次重排"就变成了"换一批
## 新资源"，对象上的链与面板里抓着的实例当场失联。
func _snapshot(v: Variant) -> Variant:
	if v is Array:
		return (v as Array).duplicate()
	if v is Dictionary:
		return (v as Dictionary).duplicate()
	return v


## 该值是否适合写进 params（命令流的可审计描述）。
## 只收标量：数组/资源写进去会让 save_data() 变成一份资源清单，违背
## "params 只记用户做了什么，不记状态本身"（同 QVoxCommand 的约定）。
func _is_audit_safe(v: Variant) -> bool:
	return v == null or v is bool or v is int or v is float or v is String
