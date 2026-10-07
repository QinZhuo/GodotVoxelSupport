@tool
class_name QVoxVoxelEditCommand
extends QVoxCommand
## 一次体素手势（画笔 / 盒 / 线 / 填充 / 橡皮都收敛到这一条）。
##
## 【为什么所有手绘工具共用一个命令类】它们的差别只在"哪些格被改成什么"，而撤销需要的
## 数据完全一样：被改动的块 + 改动前后的内容。让每个工具各写一份 = 同一段 before/after
## 采集逻辑抄五遍，且迟早有一处忘了采集 after（那种 bug 表现为"重做后贴图错一格"，
## 极难复现）。工具因此只剩一件事要做：**把写入过一遍本命令**。
##
## 【采集方式：块被"首次改动"时抓整块快照】
## 手势开始前不知道最终包围盒（自由笔画的包围盒要到松手才知道），所以不能像盒选那样
## "先算范围再快照"。做法是懒采集：
##   写入时 → 若该块还没被抓过，先抓一块"改动前"的整块快照，再写
##   松手时 → 对抓过的块收集"改动后"内容，并丢掉前后相同的块（空操作零成本）
## 代价是几百万格的对象里只有被碰过的块占内存；收益是任意长笔画都能精确撤销。
##
## 【为什么按块而不是按"手势包围盒"存两份密集体积】长对角线笔画在 256³ 里画一条线，
## 包围盒是整整 256³（64 MB × 2）。按块存只占这条线穿过的那些块（约几十块 = 几 MB）。
##
## 【为什么工具不该"先写数据、事后补命令"】那样 before 已经被覆盖，只能靠"重跑一遍反向
## 操作"来撤销 —— 而反向操作对笔刷/雕刻这类算子不总是可逆的（浮点、随机种子）。
## 快照式撤销永远精确，代价是内存，而懒采集把内存压到了"实际改动量"。

## 被编辑的对象。为 null（对象已删）时撤销会明确报错，而不是静默改错对象。
var object: QVoxObject

## 块坐标 → 该块**首次被改动前**的整块内容。空数组 = 该块当时不存在（撤销时要删掉它）。
var before: Dictionary = {}

## 块坐标 → 该块改动后的整块内容。commit() 时采集。
var after: Dictionary = {}

## 本次改动覆盖的体素范围（**块粒度**：按首次碰块时扩张，避免逐格比较 6 个 min/max）。
## 供视口只重算这一块区域，而不是整个对象。
var dirty_lo := Vector3i.ZERO
var dirty_hi := Vector3i.ZERO

var _dirty := false


func _init(obj: QVoxObject) -> void:
	super(&"voxel_edit", -1, [])
	object = obj


## 开始一次手势。**必须在任何写入之前调用**（before 只能从"还没改过"的状态里抓）。
static func begin(obj: QVoxObject) -> QVoxVoxelEditCommand:
	return QVoxVoxelEditCommand.new(obj)


# ----------------------------------------------------------------------------
# 工具接口（工具只调用这几个方法，不直接碰 object 的写入 API）
# ----------------------------------------------------------------------------

func set_voxel(x: int, y: int, z: int, material_id: int) -> bool:
	if object == null:
		return false
	_snapshot_voxel(x, y, z)
	return object.set_voxel(x, y, z, material_id)


func fill_box(a: Vector3i, b: Vector3i, material_id: int) -> int:
	if object == null:
		return 0
	_snapshot_box(a, b)
	return object.fill_box(a, b, material_id)


## 手势结束，封口成一条可入栈的命令。返回"是否真的改了东西" ——
## 返回 false 时调用方**不要 push**（点一下不改任何格的空手势不该占用一次撤销）。
func commit() -> bool:
	if object == null or not _dirty:
		return false
	var keys: Array = before.keys()
	var changed := 0
	for bk: Vector3i in keys:
		var now := object.get_block(bk)
		if _same_block(before[bk], now):
			before.erase(bk)  # 前后一样：这次没真改到它，不该让撤销栈为它付内存
			continue
		after[bk] = now
		changed += _diff_count(before[bk], now)
	if changed <= 0:
		before.clear()
		after.clear()
		return false
	# params 只放**可序列化的描述**（可审计/可回放"用户做了什么"），体素差值留在本对象里
	params = [object.model_id,
			dirty_lo.x, dirty_lo.y, dirty_lo.z,
			dirty_hi.x, dirty_hi.y, dirty_hi.z,
			changed]
	return true


## 改动了多少格（commit 后有效）。
func changed_voxels() -> int:
	if params.size() < 8:
		return 0
	return int(params[7])


func get_label() -> String:
	return "体素编辑"


## 代价 = 前后两份快照的元素数 × 4 字节（int32）。撤销栈按它淘汰最老的历史。
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


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

## 把一组块内容写回对象。src 里出现空数组 = 该块应当不存在（set_block 的空数组语义）。
func _restore(src: Dictionary) -> void:
	if object == null:
		push_error("[QVox] 体素编辑命令的目标对象已不存在（model_id=%d）" % int(params[0]))
		return
	for bk: Vector3i in src:
		object.set_block(bk, src[bk])


func _snapshot_voxel(x: int, y: int, z: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= object.grid_size.x or y >= object.grid_size.y or z >= object.grid_size.z:
		return
	_snapshot_block(QVoxSpec.block_of(Vector3i(x, y, z), object.block_size))


func _snapshot_box(a: Vector3i, b: Vector3i) -> void:
	var bs := object.block_size
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)).clamp(
			Vector3i.ZERO, object.grid_size - Vector3i.ONE)
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)).clamp(
			Vector3i.ZERO, object.grid_size - Vector3i.ONE)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return
	var b0 := QVoxSpec.block_of(lo, bs)
	var b1 := QVoxSpec.block_of(hi, bs)
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				_snapshot_block(Vector3i(bx, by, bz))


func _snapshot_block(bk: Vector3i) -> void:
	if not before.has(bk):
		before[bk] = object.get_block(bk)
		# 脏范围按**块**扩张：逐格记 min/max 要付出每格 6 次比较，而块粒度已经足够精确
		# （视口本来也按块刷新）。
		var o := QVoxSpec.block_origin(bk, object.block_size)
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
