@tool
class_name QVoxelResizeCommand
extends QVoxelCommand
## 改分辨率（`QVoxelModel.resize_grid`）的撤销记录。

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
