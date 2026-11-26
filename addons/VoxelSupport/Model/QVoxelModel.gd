@tool
class_name QVoxelModel
extends QVoxelNode
## 模型 —— 树上的叶子，也是**唯一持有手绘体素**的节点（对标 MagicaVoxel 的「模型」、

## 本模型在文件里的 model_id（VXEL 块的键；NODE 节点按它回指）。
@export var model_id := 0

## 本模型的节点类型（QVoxelNode 的唯一抽象方法）。
func kind() -> String:
	return KIND_MODEL

## UI 显示名：优先 node_name，其次带 model_id 的默认名。
func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "Model %d" % model_id

## 分辨率（体素），同时是体积的上限。
@export var grid_size := Vector3i(32, 32, 32)

## 块边长 B（= HEAD 的 block_size）。
@export var block_size := QVoxelSpec.DEFAULT_BLOCK_SIZE

## 手绘基础体素：块坐标（Vector3i）→ PackedInt32Array(B³，块内 ZXY，值 = 材质ID，0 = 空）。
var blocks: Dictionary = {}

## 帧动画（§12）：空 = **静态模型**，零成本（P2）。
var frames: Array[QVoxelFrame] = []

## 编辑 / 预览游标：**读路径**（渲染、求值、拾取、统计）取第几帧的块表。
var active_frame := 0

## 时间轴元数据（§12.3）。
var anim_loop := QVoxelSpec.ANIM_LOOP_DEFAULT
## 缺省帧率（每秒帧数）。
var anim_fps := QVoxelSpec.ANIM_FPS_DEFAULT

## 命名区间（Aseprite 的 tag）：每项 `{name, from, to, direction, color, repeat}`。
var anim_tags: Array = []

## 基础体素的版本号 —— 每次手绘编辑自增。
var base_revision := 0

# 帧（§12）

func is_animated() -> bool:
	return not frames.is_empty()

func frame_count() -> int:
	return frames.size()

## 第 index 帧（越界返回 null）。
func frame_at(index: int) -> QVoxelFrame:
	if index < 0 or index >= frames.size():
		return null
	return frames[index]

## 第 frame 帧的块表（**活引用**，直接改它就地生效）。
func blocks_for(frame: int) -> Dictionary:
	if frames.is_empty():
		return blocks
	return frames[clampi(frame, 0, frames.size() - 1)].blocks

## 读路径当前该看的块表（渲染 / 求值 / 拾取 / 统计全走它）。
func source_blocks() -> Dictionary:
	if frames.is_empty():
		return blocks
	return frames[clampi(active_frame, 0, frames.size() - 1)].blocks

# 帧的编辑入口（UI 把这些包进 QVoxelPropertyCommand 后再调用，以保证撤销正确）

## 静态 → 动画：把现有静态内容原样搬进第 0 帧（§12.2 一个 model_id 只能有一个体素源）。
func make_animated() -> QVoxelFrame:
	if is_animated():
		return null
	var f := QVoxelFrame.new()
	f.blocks = blocks
	blocks = {}
	frames.append(f)
	active_frame = 0
	content_changed.emit()
	return f

## 插入一帧。
func add_frame(frame: QVoxelFrame, at: int = -1) -> int:
	if frame == null:
		return -1
	var idx := frames.size() if at < 0 else clampi(at, 0, frames.size())
	frames.insert(idx, frame)
	content_changed.emit()
	return idx

## 删除一帧。
func remove_frame(index: int) -> bool:
	if index < 0 or index >= frames.size() or frames.size() <= 1:
		return false
	frames.remove_at(index)
	# 游标只保证不越界。
	active_frame = clampi(active_frame, 0, frames.size() - 1)
	content_changed.emit()
	return true

## 重排（纯数据操作，与 QVoxelNode.move_modifier 同理）。
func move_frame(from: int, to: int) -> bool:
	var n := frames.size()
	if from < 0 or from >= n or to < 0 or to >= n or from == to:
		return false
	var f := frames[from]
	frames.remove_at(from)
	frames.insert(to, f)
	active_frame = clampi(active_frame, 0, frames.size() - 1)
	content_changed.emit()
	return true

# 体素存取

## 已分配的块数（当前体素源）。
func block_count() -> int:
	return source_blocks().size()

## 全空判定（块表空即空，不必遍历 —— 这正是稀疏存储换来的 O(1)）。
func is_empty() -> bool:
	return source_blocks().is_empty()

## 读取体素（越界/未分配块返回 0 = 空）。
func get_voxel(x: int, y: int, z: int) -> int:
	if not _in_bounds(x, y, z):
		return 0
	var bk := QVoxelSpec.block_of(Vector3i(x, y, z), block_size)
	var blk: Variant = source_blocks().get(bk)
	if not (blk is PackedInt32Array):
		return 0
	return (blk as PackedInt32Array)[QVoxelSpec.local_index(
			x - bk.x * block_size, y - bk.y * block_size, z - bk.z * block_size, block_size)]

## 写入体素（越界安全）。
func set_voxel(x: int, y: int, z: int, material_id: int) -> bool:
	return set_frame_voxel(-1, x, y, z, material_id)

## 闭区间盒填充（自动夹取到边界内）。
func fill_box(a: Vector3i, b: Vector3i, material_id: int) -> int:
	return fill_frame_box(-1, a, b, material_id)

## 把一块盒内密集体积写进本对象（撤销重放/导入用）。
func apply_box(lo: Vector3i, dims: Vector3i, data: PackedInt32Array) -> int:
	return apply_frame_box(-1, lo, dims, data)

## 写入体素到**指定帧**（frame 的语义见 blocks_for：静态模型忽略、动画模型夹取）。
func set_frame_voxel(frame: int, x: int, y: int, z: int, material_id: int) -> bool:
	return _write_box(blocks_for(frame), Vector3i(x, y, z), Vector3i(x, y, z), material_id,
			PackedInt32Array()) > 0

## 闭区间盒填充到**指定帧**。
func fill_frame_box(frame: int, a: Vector3i, b: Vector3i, material_id: int) -> int:
	return _write_box(blocks_for(frame), a, b, material_id, PackedInt32Array())

## 密集体积写入**指定帧**。
func apply_frame_box(frame: int, lo: Vector3i, dims: Vector3i, data: PackedInt32Array) -> int:
	if dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return 0
	if data.size() < dims.x * dims.y * dims.z:
		return 0
	return _write_box(blocks_for(frame), lo, lo + dims - Vector3i.ONE, 0, data)

## 读出盒内密集体积（撤销命令抓 before/after 用）。
func read_box(lo: Vector3i, dims: Vector3i) -> PackedInt32Array:
	return _read_box_table(source_blocks(), lo, dims)

func _read_box_table(src_blocks: Dictionary, lo: Vector3i, dims: Vector3i) -> PackedInt32Array:
	var out := PackedInt32Array()
	if dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return out
	out.resize(dims.x * dims.y * dims.z)
	var bs := block_size
	var dx := dims.x
	var dxy := dx * dims.y
	var b0 := QVoxelSpec.block_of(lo, bs)
	var b1 := QVoxelSpec.block_of(lo + dims - Vector3i.ONE, bs)
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				var bk := Vector3i(bx, by, bz)
				var blk: Variant = src_blocks.get(bk)
				if not (blk is PackedInt32Array):
					continue  # 未分配的块 = 全空，整块跳过
				var o := QVoxelSpec.block_origin(bk, bs)
				# 该块与盒的交集（块内局部闭区间）
				var l0 := Vector3i(maxi(lo.x - o.x, 0), maxi(lo.y - o.y, 0), maxi(lo.z - o.z, 0))
				var l1 := Vector3i(mini(lo.x + dims.x - 1 - o.x, bs - 1),
						mini(lo.y + dims.y - 1 - o.y, bs - 1),
						mini(lo.z + dims.z - 1 - o.z, bs - 1))
				if l1.x < l0.x or l1.y < l0.y or l1.z < l0.z:
					continue
				var base := (o.x - lo.x) + (o.y - lo.y) * dx + (o.z - lo.z) * dxy
				for lz in range(l0.z, l1.z + 1):
					for ly in range(l0.y, l1.y + 1):
						var dst := base + l0.x + ly * dx + lz * dxy
						var src := QVoxelSpec.local_index(l0.x, ly, lz, bs)
						for lx in range(l0.x, l1.x + 1):
							out[dst] = (blk as PackedInt32Array)[src]
							dst += 1
							src += 1
	return out

## 摊平成一整块密集体积（布局 = VoxelVolume.index_of）—— 求值引擎与导出器的入口。
func to_volume() -> PackedInt32Array:
	if source_blocks().is_empty():
		return PackedInt32Array()
	return read_box(Vector3i.ZERO, grid_size)

## 读取整块（未分配返回空数组）。
func get_block(block_key: Vector3i) -> PackedInt32Array:
	return get_frame_block(-1, block_key)

## 读取**指定帧**的整块（frame < 0 = 静态源）。
func get_frame_block(frame: int, block_key: Vector3i) -> PackedInt32Array:
	var b: Variant = blocks_for(frame).get(block_key)
	return b if b is PackedInt32Array else PackedInt32Array()

## 替换**指定帧**的整块（frame < 0 = 静态源）。
func set_frame_block(frame: int, block_key: Vector3i, buf: PackedInt32Array) -> void:
	var target := blocks_for(frame)
	if buf.is_empty():
		if target.erase(block_key):
			base_revision += 1
		return
	if buf.size() != QVoxelSpec.block_volume(block_size):
		push_error("[QVX] 块缓冲长度必须为 %d，收到 %d"
				% [QVoxelSpec.block_volume(block_size), buf.size()])
		return
	target[block_key] = buf
	base_revision += 1

## 已分配的块坐标（按 x → y → z 排序）。
func block_keys() -> Array[Vector3i]:
	return _sorted_keys(source_blocks())

## 回收全零块（空块 = 块坐标缺失）。
func compact() -> int:
	return _compact_table(source_blocks())

## 清空（整表丢弃，O(1) —— dense 方案这里要 fill 一整块内存）。
func clear() -> void:
	if blocks.is_empty() and frames.is_empty():
		return
	blocks.clear()
	frames.clear()
	active_frame = 0
	base_revision += 1
	content_changed.emit()

## 已填充的体素数量（UI 状态栏用；与已分配块数成正比，别放进热路径）。
func count_solid() -> int:
	return _count_solid(source_blocks())

## 用过的材质ID（供调色板 UI 只列出在用的档）。
func used_materials() -> Dictionary:
	var used := {}
	if not is_animated():
		return _used_materials(blocks)
	for f in frames:
		for m in _used_materials(f.blocks):
			used[m] = true
	return used

## 改分辨率：保留新旧尺寸交集内的体素，其余丢弃。
func resize_grid(new_size: Vector3i) -> void:
	if new_size.x <= 0 or new_size.y <= 0 or new_size.z <= 0 or new_size == grid_size:
		return
	blocks = _resized_table(blocks, new_size)
	for f in frames:
		f.blocks = _resized_table(f.blocks, new_size)
	grid_size = new_size
	base_revision += 1
	content_changed.emit()

# 任意点集写入（画笔、图元、脚本 paint 的共同落点）

## 批量写一批格子（当前体素源）。
func paint_cells(cells: Array[Vector3i], material_id: int) -> int:
	return _paint_cells_table(source_blocks(), cells, material_id)

# 内部：盒写入（唯一的体素写入路径，fill/set/apply/undo 全走它）

## 盒内写入。
func _write_box(target: Dictionary, a: Vector3i, b: Vector3i, material_id: int,
		data: PackedInt32Array) -> int:
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z)).clamp(
			Vector3i.ZERO, grid_size - Vector3i.ONE)
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z)).clamp(
			Vector3i.ZERO, grid_size - Vector3i.ONE)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return 0
	var const_fill := data.is_empty()
	var dims := hi - lo + Vector3i.ONE
	var dx := dims.x
	var dxy := dx * dims.y
	var bs := block_size
	var b0 := QVoxelSpec.block_of(lo, bs)
	var b1 := QVoxelSpec.block_of(hi, bs)
	var n := 0
	var touched: Array[Vector3i] = []
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				var bk := Vector3i(bx, by, bz)
				var o := QVoxelSpec.block_origin(bk, bs)
				# 该块与盒的交集（块内局部闭区间）
				var l0 := Vector3i(maxi(lo.x - o.x, 0), maxi(lo.y - o.y, 0), maxi(lo.z - o.z, 0))
				var l1 := Vector3i(mini(hi.x - o.x, bs - 1), mini(hi.y - o.y, bs - 1),
						mini(hi.z - o.z, bs - 1))
				var blk := _block_of_table(target, bk)
				if blk.is_empty():
					if const_fill and material_id == 0:
						continue  # 擦空一个未分配的块：本就不存在，不必创建
					blk = PackedInt32Array()
					blk.resize(QVoxelSpec.block_volume(bs))
				var base := (o.x - lo.x) + (o.y - lo.y) * dx + (o.z - lo.z) * dxy
				for lz in range(l0.z, l1.z + 1):
					for ly in range(l0.y, l1.y + 1):
						var dst := QVoxelSpec.local_index(l0.x, ly, lz, bs)
						var src := base + l0.x + ly * dx + lz * dxy
						for lx in range(l0.x, l1.x + 1):
							var v := material_id if const_fill else data[src]
							if blk[dst] != v:
								blk[dst] = v
								n += 1
							dst += 1
							src += 1
				# 【必须写回】字典取出的 PackedInt32Array 不保证原地改到（逐元素写虽不触发
				target[bk] = blk
				touched.append(bk)
	if n > 0:
		# 擦除后可能留下全零块：只检查本次碰过的块（不做全表扫描）
		if not const_fill or material_id == 0:
			for bk in touched:
				if _is_block_empty(target.get(bk)):
					target.erase(bk)
		base_revision += 1
	return n

## 点集写入（按表）。
func _paint_cells_table(target: Dictionary, cells: Array[Vector3i], material_id: int) -> int:
	var bs := block_size
	var buckets := {}
	for p in cells:
		if p.x < 0 or p.y < 0 or p.z < 0 \
				or p.x >= grid_size.x or p.y >= grid_size.y or p.z >= grid_size.z:
			continue
		var bk := QVoxelSpec.block_of(p, bs)
		var o := QVoxelSpec.block_origin(bk, bs)
		var idx := QVoxelSpec.local_index(p.x - o.x, p.y - o.y, p.z - o.z, bs)
		var list: PackedInt32Array = buckets.get(bk, PackedInt32Array())
		list.append(idx)
		buckets[bk] = list
	var n := 0
	for bk: Vector3i in buckets:
		var blk := _block_of_table(target, bk)
		if blk.is_empty():
			if material_id == 0:
				continue  # 擦空一个未分配的块：本就不存在
			blk = PackedInt32Array()
			blk.resize(QVoxelSpec.block_volume(bs))
		for idx in buckets[bk]:
			if blk[idx] != material_id:
				blk[idx] = material_id
				n += 1
		target[bk] = blk
		if material_id == 0 and _is_block_empty(blk):
			target.erase(bk)
	if n > 0:
		base_revision += 1
	return n

func _block_of_table(target: Dictionary, bk: Vector3i) -> PackedInt32Array:
	var b: Variant = target.get(bk)
	return b if b is PackedInt32Array else PackedInt32Array()

## 单块是否全空。
func _is_block_empty(b: Variant) -> bool:
	if not (b is PackedInt32Array):
		return true
	return QVoxelBlockCodec.is_empty_block(b as PackedInt32Array)

## 全零块回收（按表）。
func _compact_table(target: Dictionary) -> int:
	var empty: Array[Vector3i] = []
	for k: Vector3i in target:
		if _is_block_empty(target[k]):
			empty.append(k)
	for k in empty:
		target.erase(k)
	return empty.size()

## 排序块键（按表）。
func _sorted_keys(target: Dictionary) -> Array[Vector3i]:
	return QVoxelBlockCodec.sorted_keys(target)

func _count_solid(target: Dictionary) -> int:
	var n := 0
	for k in target:
		for m in (target[k] as PackedInt32Array):
			if m > 0:
				n += 1
	return n

func _used_materials(target: Dictionary) -> Dictionary:
	var used := {}
	for k in target:
		for m in (target[k] as PackedInt32Array):
			if m > 0:
				used[m] = true
	return used

## 重采样一张块表到 new_size（保留交集内的体素）。
func _resized_table(old: Dictionary, new_size: Vector3i) -> Dictionary:
	var out := {}
	var bs := block_size
	for bk: Vector3i in old:
		var o := QVoxelSpec.block_origin(bk, bs)
		if o.x >= new_size.x or o.y >= new_size.y or o.z >= new_size.z:
			continue  # 整块在外：直接丢，不必逐格判
		var blk: PackedInt32Array = old[bk]
		for lz in bs:
			for ly in bs:
				for lx in bs:
					var gx := o.x + lx
					var gy := o.y + ly
					var gz := o.z + lz
					if gx >= new_size.x or gy >= new_size.y or gz >= new_size.z:
						continue
					var m := blk[QVoxelSpec.local_index(lx, ly, lz, bs)]
					if m != 0:
						_set_solid(out, gx, gy, gz, m)
	return out

func _set_solid(target: Dictionary, x: int, y: int, z: int, material_id: int) -> void:
	var bk := QVoxelSpec.block_of(Vector3i(x, y, z), block_size)
	var blk := _block_of_table(target, bk)
	if blk.is_empty():
		blk = PackedInt32Array()
		blk.resize(QVoxelSpec.block_volume(block_size))
	blk[QVoxelSpec.index_in_block(Vector3i(x, y, z), block_size)] = material_id
	target[bk] = blk

func _in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 and x < grid_size.x and y < grid_size.y and z < grid_size.z
