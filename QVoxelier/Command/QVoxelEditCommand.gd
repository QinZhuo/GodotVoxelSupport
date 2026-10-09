@tool
class_name QVoxelEditCommand
extends QVoxelCommand
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
##
## 【快照必须是独立副本：`get_block()` 给的是活视图】本类存下的 before/after 是"点时刻的值"，
## 而 `QVoxelModel.get_block()` 返回的数组与内部 `blocks[bk]` **共享同一缓冲**（见其注释），
## `_write_box` 的逐元素写会就地改到它。曾经没拷贝的后果很隐蔽：擦除一笔时 before 被同一次
## 写入抹成"和 after 一样"，于是 commit() 判定"什么都没变"→ 返回值 false、命令不入栈、
## `undo()` 无内容可回滚，而屏幕上明明看到格子没了。所以本类**每一处留存块内容的地方**
## 都必须 `duplicate()`（共三处：抓 before、封口收 after、回放时交出），一处漏掉就会重新长出这个 bug。

## 被编辑的对象。为 null（对象已删）时撤销会明确报错，而不是静默改错对象。
var object: QVoxelModel

## 这一笔手势改的是**第几帧**（-1 = 静态源 `blocks`，§12.6）。
##
## 【为什么帧号记在命令上，而不是"撤销时看 object.active_frame"】用户在第 2 帧落笔、
## 随后把预览游标切到第 5 帧、再按撤销 —— 若命令跟着游标走，它会把第 5 帧改回去：
## 静默改错帧，且屏幕上"第 2 帧的笔迹还在"。帧号是这一笔的属性，必须随命令一起入栈。
var frame := -1

## 块坐标 → 该块**首次被改动前**的整块内容。空数组 = 该块当时不存在（撤销时要删掉它）。
var before: Dictionary = {}

## 块坐标 → 该块改动后的整块内容。commit() 时采集。
var after: Dictionary = {}

## 本次改动覆盖的体素范围（**块粒度**：按首次碰块时扩张，避免逐格比较 6 个 min/max）。
## 供视口只重算这一块区域，而不是整个对象。
var dirty_lo := Vector3i.ZERO
var dirty_hi := Vector3i.ZERO

var _dirty := false


func _init(obj: QVoxelModel, p_frame: int = -1) -> void:
	super(&"voxel_edit", -1, [])
	object = obj
	frame = p_frame


## 开始一次手势。**必须在任何写入之前调用**（before 只能从"还没改过"的状态里抓）。
## `frame < 0` = 静态源；动画模型传它当前正在编辑的那一帧。
static func begin(obj: QVoxelModel, frame: int = -1) -> QVoxelEditCommand:
	return QVoxelEditCommand.new(obj, frame)


# ----------------------------------------------------------------------------
# 工具接口（工具只调用这几个方法，不直接碰 object 的写入 API）
# ----------------------------------------------------------------------------

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


## 密集体积写入（整对象变换 / 导入用）。data 布局 = QVoxelModel.apply_box（PcgModel.index_of）。
##
## 【为什么必须有这个入口】整对象变换要一次重写整片网格：逐格走 set_voxel 会为每一格
## 各付一次"算块号 + 查字典 + 记脏"，256³ 就是 1600 万次；而 object.apply_box 本就按块推进。
##
## 【快照范围直接取整个盒，而不是懒采集】`_snapshot_box` 会把盒覆盖的**所有已分配块**
## 一次抓完 —— 变换必然改写盒内每一格，懒采集到头来也要碰到同一批块，显式声明更直白，
## 也让 dirty 范围（视口据此只重算这些 chunk）一次算准，不会漏。
func apply_box(lo: Vector3i, dims: Vector3i, data: PackedInt32Array) -> int:
	if object == null:
		return 0
	_snapshot_box(lo, lo + dims - Vector3i.ONE)
	return object.apply_frame_box(frame, lo, dims, data)


## 手势结束，封口成一条可入栈的命令。返回"是否真的改了东西" ——
## 返回 false 时调用方**不要 push**（点一下不改任何格的空手势不该占用一次撤销）。
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
	# frame 追加在**末尾**：既有下标（model_id / dirty 范围 / changed）一个都不动。
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
## 未抓过快照（空手势）返回空数组；那种命令本来也不会入栈。
func dirty_bounds() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not _dirty:
		return out
	out.append(dirty_lo)
	out.append(dirty_hi)
	return out


func get_label() -> String:
	# 动画模型标出帧号：撤销栈里"体素编辑"与"体素编辑（第 3 帧）"是两个不同的东西，
	# 用户点错了帧要能从历史里看出来（静态模型不标，-1 只是内部表示）。
	return "体素编辑（第 %d 帧）" % frame if frame >= 0 else "体素编辑"


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
		# （视口本来也按块刷新）。
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
