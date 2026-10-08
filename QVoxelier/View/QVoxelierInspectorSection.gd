@tool
class_name QVoxelierInspectorSection
extends QVoxelierSection
## 右侧抽屉·修改器参数分组 —— 选中链上某条修改器后，按 @export 反射生成它的参数控件。
##
## 【为什么参数面板不需要按算子写】见 QVoxelierInspector 的类头：算子种类是**开放**的，
## 手写面板等于"每加一个算子改一次 UI"。这里只是把那份通用编辑器包成抽屉里的一段分组，
## 于是"改参数"这件事对全部算子（含 SDF / 体素生成 / 体素处理 / 体素重排）只有一份实现。
##
## 【手势原样上报，不在本层写数据】本分组与 QVoxelierColorSection 同构：只把
## edit_began / value_changed / edit_ended 三段信号转出去，由 App 夹成一条 QVoxPropertyCommand。
## 于是"一次拖动 = 一条撤销"的语义在 App 一处成立，本层不必懂撤销。

## 手势三段（与 QVoxelierInspector 同构，target 即被改的算子资源）。
signal edit_began(target: Object, prop: StringName)
signal value_changed(target: Object, prop: StringName, value: Variant)
signal edit_ended(target: Object, prop: StringName)

var _inspector: QVoxelierInspector


func section_title() -> String:
	return "修改器参数"


func _build_body(body: VBoxContainer) -> void:
	_inspector = QVoxelierInspector.new()
	body.add_child(_inspector)
	_inspector.edit_began.connect(func(t: Object, p: StringName) -> void: edit_began.emit(t, p))
	_inspector.value_changed.connect(func(t: Object, p: StringName, v: Variant) -> void:
		value_changed.emit(t, p, v))
	_inspector.edit_ended.connect(func(t: Object, p: StringName) -> void: edit_ended.emit(t, p))


## 绑定一条修改器（或它的算子）并重建控件。传 null = 清空。
func bind(target: Object) -> void:
	if _inspector != null:
		_inspector.bind(target)


## 是否正处在一次连续手势中（App 据此避免重建面板把正在拖的滑条销毁）。
func is_editing() -> bool:
	return _inspector != null and _inspector.is_editing()
