@tool
class_name QVoxelResizeCommand
extends QVoxelCommand
## 改分辨率（`QVoxelModel.resize_grid`）的撤销记录。
## 【为什么不能用 QVoxelPropertyCommand】改分辨率会**丢掉超出新尺寸的体素**，而属性命令只存
## 前后两个值（grid_size），丢掉的体素无从还原 —— 撤销后模型会缺一块。故这里存的是
## "改前 / 改后"的完整（浅拷贝）块表 + 尺寸：`resize_grid` 用 `_resized_table` **新建**表、
## 不就地改旧数组，于是浅拷贝的旧表引用依然完整，撤销即整体写回。
## 【为什么是浅拷贝也够】块表的值是 `PackedInt32Array`（写时拷贝），旧数组在 resize 后无人再改，
## 故两份状态互不干扰；深拷贝几百万格纯属浪费。
## 【代价】结构级操作，影响整对象（dirty_bounds 返回空数组）。

var object: QVoxelModel
var new_size: Vector3i
var _before: Dictionary
var _after: Dictionary


func _init(p_object: QVoxelModel = null, p_size := Vector3i.ZERO) -> void:
	# 与 QVoxelPropertyCommand 同一套基类约定（type / tick / params）。
	super(&"resize", -1, [])
	object = p_object
	new_size = p_size
	if _valid():
		_before = _snapshot(object)


## 立即改分辨率并返回一条可入栈的命令；无变化 / 非法尺寸返回 null（调用方据此不入栈）。
static func apply(p_object: QVoxelModel, p_size: Vector3i) -> QVoxelResizeCommand:
	if p_object == null or p_size.x <= 0 or p_size.y <= 0 or p_size.z <= 0 \
			or p_size == p_object.grid_size:
		return null
	var c := QVoxelResizeCommand.new(p_object, p_size)
	p_object.resize_grid(p_size)
	c._after = _snapshot(p_object)
	return c


func _valid() -> bool:
	return object != null and new_size.x > 0 and new_size.y > 0 and new_size.z > 0


static func _snapshot(o: QVoxelModel) -> Dictionary:
	var frames: Array = []
	for f in o.frames:
		frames.append(f.blocks.duplicate())
	return {"grid": o.grid_size, "blocks": o.blocks.duplicate(), "frames": frames}


func _apply(s: Dictionary) -> void:
	if object == null:
		push_error("[QVX] 改尺寸命令的目标已不存在")
		return
	object.grid_size = s["grid"]
	object.blocks = s["blocks"]
	var fblocks: Array = s["frames"]
	for i in mini(object.frames.size(), fblocks.size()):
		object.frames[i].blocks = fblocks[i]
	object.base_revision += 1
	object.content_changed.emit()


func redo() -> void:
	_apply(_after)


func undo() -> void:
	_apply(_before)


func get_label() -> String:
	return "改尺寸"


func get_cost() -> int:
	var n := 0
	for _k in _before.get("blocks", {}):
		n += 1
	return maxi(1, n)
