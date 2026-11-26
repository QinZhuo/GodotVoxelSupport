@tool
class_name QVoxelEditCommand
extends QVoxelCommand
## 一次体素手势（画笔 / 盒 / 线 / 填充 / 橡皮都收敛到这一条）。

## 被编辑的对象。
var object: QVoxelModel

## 这一笔手势改的是**第几帧**（-1 = 静态源 `blocks`，§12.6）。
var frame := -1

## 块坐标 → 该块**首次被改动前**的整块内容。
var before: Dictionary = {}

## 块坐标 → 该块改动后的整块内容。
var after: Dictionary = {}

## 本次改动覆盖的体素范围（**块粒度**：按首次碰块时扩张，避免逐格比较 6 个 min/max）。
var dirty_lo := Vector3i.ZERO
var dirty_hi := Vector3i.ZERO

var _dirty := false

## 撤销栈里显示的名字（空 = 用默认的"体素编辑"）。
var label_override := ""

func _init(obj: QVoxelModel, p_frame: int = -1) -> void:
	super(&"voxel_edit", -1, [])
	object = obj
	frame = p_frame

## 开始一次手势。
static func begin(obj: QVoxelModel, frame: int = -1) -> QVoxelEditCommand:
	return QVoxelEditCommand.new(obj, frame)

# 工具接口（工具只调用这几个方法，不直接碰 object 的写入 API）

func set_voxel(x: int, y: int, z: int, material_id: int) -> bool:
	if object == null:
		return false
	_snapshot_voxel(x, y, z)
	return object.set_frame_voxel(frame, x, y, z, material_id)

func fill_box(a: Vector3i, b: Vector3i, material_id: int) -> int:
	if object == null:
		return 0
	_snapshot_box(a, b)
	return object.fill_frame_box(frame, a, b, material_id)

## 密集体积写入（整对象变换 / 导入用）。
func apply_box(lo: Vector3i, dims: Vector3i, data: PackedInt32Array) -> int:
	if object == null:
		return 0
	_snapshot_box(lo, lo + dims - Vector3i.ONE)
	return object.apply_frame_box(frame, lo, dims, data)

## 手势结束，封口成一条可入栈的命令。
func commit() -> bool:
	if object == null or not _dirty:
		return false
	var keys: Array = before.keys()
	var changed := 0
	for bk: Vector3i in keys:
		# duplicate：after 要活到这条命令被淘汰为止，不能是活视图（见类头注释）
		var now := object.get_frame_block(frame, bk).duplicate()
		if _same_block(before[bk], now):
			before.erase(bk)  # 前后一样：这次没真改到它，不该让撤销栈为它付内存
			continue
		after[bk] = now
		changed += _diff_count(before[bk], now)
	if changed <= 0:
		before.clear()
		after.clear()
		return false
	# params 只放**可序列化的描述**（可审计/可回放"用户做了什么"），体素差值留在本对象里。
	params = [object.model_id,
			dirty_lo.x, dirty_lo.y, dirty_lo.z,
			dirty_hi.x, dirty_hi.y, dirty_hi.z,
			changed,
			frame]
	return true

## 改动了多少格（commit 后有效）。
func changed_voxels() -> int:
	if params.size() < 8:
		return 0
	return int(params[7])

## 这一笔改的是第几帧（-1 = 静态源；commit 后有效）。
func edited_frame() -> int:
	return int(params[8]) if params.size() >= 9 else frame

## 只影响被抓过快照的那些块所覆盖的体素范围 —— 视口据此只让这些 chunk 重新取数。
func dirty_bounds() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not _dirty:
		return out
	out.append(dirty_lo)
	out.append(dirty_hi)
	return out

func get_label() -> String:
	if not label_override.is_empty():
		return label_override
	# 动画模型标出帧号：撤销栈里"体素编辑"与"体素编辑（第 3 帧）"是两个不同的东西，
	return "体素编辑（第 %d 帧）" % frame if frame >= 0 else "体素编辑"

## 代价 = 前后两份快照的元素数 × 4 字节（int32）。
func get_cost() -> int:
	var n := 0
	for k in before:
		n += (before[k] as PackedInt32Array).size()
	for k in after:
		n += (after[k] as PackedInt32Array).size()
	return n * 4

func redo() -> void:
	_restore(after)

func undo() -> void:
	_restore(before)

# 内部

## 把一组块内容写回对象。
func _restore(src: Dictionary) -> void:
	if object == null:
		push_error("[QVX] 体素编辑命令的目标对象已不存在（model_id=%d）" % int(params[0]))
		return
	for bk: Vector3i in src:
		# duplicate：set_block 会接管这份缓冲，而 src 还要留给下一次 undo/redo（见类头注释）
		object.set_frame_block(frame, bk, (src[bk] as PackedInt32Array).duplicate())

func _snapshot_voxel(x: int, y: int, z: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= object.grid_size.x or y >= object.grid_size.y or z >= object.grid_size.z:
		return
	_snapshot_block(QVoxelSpec.block_of(Vector3i(x, y, z), object.block_size))

func _snapshot_box(a: Vector3i, b: Vector3i) -> void:
	var bs := object.block_size
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)).clamp(
			Vector3i.ZERO, object.grid_size - Vector3i.ONE)
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)).clamp(
			Vector3i.ZERO, object.grid_size - Vector3i.ONE)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return
	var b0 := QVoxelSpec.block_of(lo, bs)
	var b1 := QVoxelSpec.block_of(hi, bs)
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				_snapshot_block(Vector3i(bx, by, bz))

func _snapshot_block(bk: Vector3i) -> void:
	if not before.has(bk):
		# duplicate：这一份要在整笔手势期间扛住后续写入，活视图会被就地改写（见类头注释）
		before[bk] = object.get_frame_block(frame, bk).duplicate()
		# 脏范围按**块**扩张：逐格记 min/max 要付出每格 6 次比较，而块粒度已经足够精确
		var o := QVoxelSpec.block_origin(bk, object.block_size)
		var e := o + Vector3i.ONE * (object.block_size - 1)
		dirty_lo = o if not _dirty else Vector3i(mini(dirty_lo.x, o.x), mini(dirty_lo.y, o.y),
				mini(dirty_lo.z, o.z))
		dirty_hi = e if not _dirty else Vector3i(maxi(dirty_hi.x, e.x), maxi(dirty_hi.y, e.y),
				maxi(dirty_hi.z, e.z))
	_dirty = true

func _same_block(a: Variant, b: Variant) -> bool:
	var x: PackedInt32Array = a if a is PackedInt32Array else PackedInt32Array()
	var y: PackedInt32Array = b if b is PackedInt32Array else PackedInt32Array()
	if x.size() != y.size():
		return false
	for i in x.size():
		if x[i] != y[i]:
			return false
	return true

func _diff_count(a: Variant, b: Variant) -> int:
	var x: PackedInt32Array = a if a is PackedInt32Array else PackedInt32Array()
	var y: PackedInt32Array = b if b is PackedInt32Array else PackedInt32Array()
	var n := maxi(x.size(), y.size())
	var d := 0
	for i in n:
		var xv := x[i] if i < x.size() else 0
		var yv := y[i] if i < y.size() else 0
		if xv != yv:
			d += 1
	return d
