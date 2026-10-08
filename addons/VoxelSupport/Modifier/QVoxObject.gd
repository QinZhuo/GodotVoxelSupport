@tool
class_name QVoxObject
extends Resource
## 建模对象 —— 世界里的"一块可编辑体素模型"（对标 MagicaVoxel 的「模型」）。
##
## 【结构 = 手绘基础体素 + 非破坏链】
##   blocks    用户手绘出来的体素（画笔/盒/填充/克隆都写这里）。是"所见即所得"的那部分，
##             也是撤销栈唯一改写的体素数据。
##   modifiers 非破坏链：作用在 blocks **之上**，改参数不改数据。
##
## 【为什么手绘不能塞进链里当一个算子】画笔编辑是高频率、增量、要撤销的；链是低频率、
## 全量、参数化的。把画笔做成算子会让每次落笔触发整链重算，且撤销要回滚链参数。
## 所以：blocks 是链的**输入**，不是链的一环（同 Blender 的"编辑模式改网格" vs
## "物体模式挂修改器"）。于是两条编辑路径职责清晰且**可以组合**：手绘一块石头，
## 再挂一个 SDF 修改器 combine = SUBTRACT 挖洞。
##
## 【为什么是分块稀疏，而不是一整块 dense 数组】
##   ① 内存：512³ dense 是 5.4 亿格 ≈ 537 MB（int32），而实体往往只占其中少数几块；
##      分块稀疏只在"画到哪一块"时分配一块 32³（128 KB），空块根本不占内存。
##   ② 一致性：`.qvox` 的 VOX0 本来就是"块坐标 → 块内缓冲"（QVoxSpec §5）。常驻内存用
##      同一形状，落盘/读盘**零转换**（不必在保存时把 dense 切一遍，那正是双份布局的开端）。
##   块内布局权威是 QVoxBlockCodec（block_of / local_index），本类不另写下标公式。

## 显示名（同时写进 NODE 节点的 name 键）。
@export var object_name := "Voxel Object"

## 本对象在文件里的 model_id（VOX0 块的键；NODE 节点按它回指）。由 QVoxWorld 分配。
@export var model_id := 0

## 分辨率（体素），同时是体积的上限。采纳 MagicaVoxel 的语义：一块对象 = 一块有界体素。
##
## 【为什么是有界】体素域算子（侵蚀/风化/连通性清理）需要完整邻域，与"惰性按 chunk 生成、
## 只持有 32³"的流式架构天然冲突（插件注释里已承认过这个矛盾）。有界模型让矛盾消失。
@export var grid_size := Vector3i(32, 32, 32)

## 块边长 B（= HEAD 的 block_size）。世界级设定，由 QVoxWorld 在创建/加载时注入。
@export var block_size := QVoxSpec.DEFAULT_BLOCK_SIZE

## 手绘基础体素：块坐标（Vector3i）→ PackedInt32Array(B³，块内 ZXY，值 = 材质ID，0 = 空）。
##
## 【为什么不是 @export / 不进 .tres】几千万个 int 存成文本 .tres 是灾难。持久化由工程文件
## 负责（QVoxWorld.to_document → QVoxFile.serialize），.tres 只当"参数容器"。
## 【空块不存在】全零块 = 块坐标缺失（与文件里的"空块不写入"同一语义）。compact() 负责回收。
var blocks: Dictionary = {}

## 基础体素的版本号 —— 每次手绘编辑自增。求值引擎用它判断能否复用上一次结果。
## （不哈希数组内容：几百万元素的哈希本身就不便宜，而编辑点已经知道它变了。）
var base_revision := 0

## 非破坏链。顺序即语义（与 Blender 的修改器栈同理：换位置就是换语义）。
## 条目类型只有一种 —— QVoxModifier；域的差别由它的子类表达，不是靠探测算子。
@export var modifiers: Array[QVoxModifier] = []

## 所属图层下标（写进 NODE 节点的 layer 键，§5.1）。缺省 0 = 隐含缺省层。
##
## 【为什么是对象自己的字段，而不是让世界去改 JSON】与 modifiers → nodes[].steps 同一道理：
## 编辑模型里能改的东西必须是**编辑模型自己的属性**。若把它做成"世界去 node 里找那个节点、
## 改它的键"，那么刚 create_object() 出来、还没写进 node 的对象就无处安放（静默改不动），
## 而且撤销要绕一大圈。放这里则改它就是改一个属性，落盘点由 _node_with_objects() 统一补。
@export var layer := 0

## 结构性改动（链增删/重排、修改器参数变化、清空、改分辨率）。
##
## 【体素写入刻意不发这个信号】一笔画下来可能改几千格，逐格发信号会把 UI 拖死。
## 手绘的刷新时机由"手势封口"决定：工具在松手时构造 QVoxVoxelEditCommand 并入栈，
## 视口监听撤销栈的通知（或直接读命令的 dirty_lo/dirty_hi）做局部重算。
##
## 【修改器参数变化为什么不在这里自动监听】QVoxModifier 是 Resource，Godot 不会替我们监听
## 它的 @export 改动，所以"改参数要标脏"由改参数的那条命令负责（QVoxPropertyCommand 在
## redo/undo 之后 emit 本信号），本类只管自己结构变化时发出。
signal content_changed


# ----------------------------------------------------------------------------
# 体素存取
# ----------------------------------------------------------------------------

## grid_size 对应的元素总数（非法尺寸返回 0）。**仅供参考/UI**：稀疏存储不按它分配内存。
func volume_size() -> int:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return 0
	return grid_size.x * grid_size.y * grid_size.z


## 已分配的块数。
func block_count() -> int:
	return blocks.size()


## 全空判定（块表空即空，不必遍历 —— 这正是稀疏存储换来的 O(1)）。
func is_empty() -> bool:
	return blocks.is_empty()


## 读取体素（越界/未分配块返回 0 = 空）。
func get_voxel(x: int, y: int, z: int) -> int:
	if not _in_bounds(x, y, z):
		return 0
	var bk := QVoxSpec.block_of(Vector3i(x, y, z), block_size)
	var blk: Variant = blocks.get(bk)
	if not (blk is PackedInt32Array):
		return 0
	return (blk as PackedInt32Array)[QVoxSpec.local_index(
			x - bk.x * block_size, y - bk.y * block_size, z - bk.z * block_size, block_size)]


## 写入体素（越界安全）。返回是否真的改了（便于"无变化不入栈"）。
## **不走撤销栈** —— 撤销由工具在手势两端构造一条命令处理（拖拽中逐格入栈会瞬间撑爆栈，
## 60fps 下也不该付这个代价）。
func set_voxel(x: int, y: int, z: int, material_id: int) -> bool:
	return _write_box(Vector3i(x, y, z), Vector3i(x, y, z), material_id, PackedInt32Array()) > 0


## 闭区间盒填充（自动夹取到边界内）。返回实际改动的格数（0 = 无变化）。
func fill_box(a: Vector3i, b: Vector3i, material_id: int) -> int:
	return _write_box(a, b, material_id, PackedInt32Array())


## 把一块盒内密集体积写进本对象（撤销重放/导入用）。
## data 布局 = PcgModel.index_of(局部坐标, dims)，dims = 盒尺寸（即 hi - lo + 1）。
func apply_box(lo: Vector3i, dims: Vector3i, data: PackedInt32Array) -> int:
	if dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return 0
	if data.size() < dims.x * dims.y * dims.z:
		return 0
	return _write_box(lo, lo + dims - Vector3i.ONE, 0, data)


## 读出盒内密集体积（撤销命令抓 before/after 用）。布局与 apply_box 相同。
##
## 【为什么按块推进，而不是逐格 get_voxel】逐格读要为每个体素查一次字典再算一次下标
## （512³ 是 1.3 亿次），而**未分配的块本来就是空的**，整块跳过即可。这里只遍历与盒相交的
## 已分配块，成本与块数成正比 —— 与 _write_box 同一条思路，公式也刻意保持同形。
##
## to_volume() 是本函数在整块范围上的特例，于是"稀疏 → 密集"全项目只有一份实现。
func read_box(lo: Vector3i, dims: Vector3i) -> PackedInt32Array:
	var out := PackedInt32Array()
	if dims.x <= 0 or dims.y <= 0 or dims.z <= 0:
		return out
	out.resize(dims.x * dims.y * dims.z)
	var bs := block_size
	var dx := dims.x
	var dxy := dx * dims.y
	var b0 := QVoxSpec.block_of(lo, bs)
	var b1 := QVoxSpec.block_of(lo + dims - Vector3i.ONE, bs)
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				var bk := Vector3i(bx, by, bz)
				var blk: Variant = blocks.get(bk)
				if not (blk is PackedInt32Array):
					continue  # 未分配的块 = 全空，整块跳过
				var o := QVoxSpec.block_origin(bk, bs)
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
						var src := QVoxSpec.local_index(l0.x, ly, lz, bs)
						for lx in range(l0.x, l1.x + 1):
							out[dst] = (blk as PackedInt32Array)[src]
							dst += 1
							src += 1
	return out


## 摊平成一整块密集体积（布局 = PcgModel.index_of）—— 求值引擎与导出器的入口。
## read_box 在整块范围上的特例，故与它共用一份实现。
##
## 【空对象返回 size 0，而不是一整块零】求值引擎用"空数组"表示"还没有既有体积"，
## 于是"手绘为空"这个情形不必特判，也省掉一次无谓的全量分配 + 扫描（512³ = 537 MB）。
##
## 【但它不代表"链首没有左操作数"】链首那条的 combine 仍要作用在**手绘体素**上（见引擎文件头），
## 故引擎在合并前会显式取一次本函数的结果当左操作数（QVoxEvalEngine._left_operand）：若把
## "空数组"直接当左操作数，UNION 会退化成 REPLACE（手绘石料凭空消失）、SUBTRACT 会退化成
## "挖不动"—— 恰恰是"手绘 + 程序化混着用"的两种用法。
func to_volume() -> PackedInt32Array:
	if blocks.is_empty():
		return PackedInt32Array()
	return read_box(Vector3i.ZERO, grid_size)


## 读取整块（未分配返回空数组）。供落盘/撤销按块搬运。
##
## 【返回的是**活视图**，不是快照】返回的数组与内部 `blocks[block_key]` 共享同一缓冲：
## 逐元素写（`_write_box` 的写法）不会因写时拷贝而自动分身，实测会**就地改到调用方手里这份**。
## 因此：只读走一遍（落盘、生成器采样）可以直接用它；一旦要**留存**（撤销的 before/after 快照、
## 缓存），必须先 `duplicate()` —— 否则那一笔之后的任何编辑都会悄悄改写你留存的"点时刻的值"。
func get_block(block_key: Vector3i) -> PackedInt32Array:
	var b: Variant = blocks.get(block_key)
	return b if b is PackedInt32Array else PackedInt32Array()


## 整体替换一块（长度必须为 B³）。**空缓冲 = 删除该块**。
## 供加载与撤销命令整块搬运（撤销不必逐格 set_voxel 再走一遍"建块/回收"分支）。
##
## 【接管传入的缓冲，不拷贝】调用方若还要留着这份数据（撤销栈要留着，供下次 redo），
## 必须自己传 `duplicate()` —— 否则对象随后的就地编辑会改到你手上这一份。
func set_block(block_key: Vector3i, buf: PackedInt32Array) -> void:
	if buf.is_empty():
		if blocks.erase(block_key):
			base_revision += 1
		return
	if buf.size() != QVoxSpec.block_volume(block_size):
		push_error("[QVox] 块缓冲长度必须为 %d，收到 %d"
				% [QVoxSpec.block_volume(block_size), buf.size()])
		return
	blocks[block_key] = buf
	base_revision += 1


## 已分配的块坐标（按 x → y → z 排序）。
##
## 【为什么必须排序】Dictionary 的迭代顺序不保证稳定，而落盘顺序、增量写的块搬运、
## 回归测试的逐字节哈希都要求确定性 —— 排序让"同一份数据"恒得"同一串字节"。
func block_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for k in blocks:
		keys.append(k)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	return keys


## 回收全零块（空块 = 块坐标缺失）。返回丢弃的块数。
func compact() -> int:
	var empty: Array[Vector3i] = []
	for k: Vector3i in blocks:
		if _is_block_empty(blocks[k]):
			empty.append(k)
	for k in empty:
		blocks.erase(k)
	return empty.size()


## 清空（整表丢弃，O(1) —— dense 方案这里要 fill 一整块内存）。
func clear() -> void:
	if blocks.is_empty():
		return
	blocks.clear()
	base_revision += 1
	content_changed.emit()


## 已填充的体素数量（UI 状态栏用；与已分配块数成正比，别放进热路径）。
func count_solid() -> int:
	var n := 0
	for k in blocks:
		for m in (blocks[k] as PackedInt32Array):
			if m > 0:
				n += 1
	return n


## 用过的材质ID（供调色板 UI 只列出在用的档）。
func used_materials() -> Dictionary:
	var used := {}
	for k in blocks:
		for m in (blocks[k] as PackedInt32Array):
			if m > 0:
				used[m] = true
	return used


## 改分辨率：保留新旧尺寸交集内的体素，其余丢弃。
## 这是"重采样"级操作，UI 必须把它做成一条显式命令（提示代价），而不是随手可拖的滑条。
func resize_grid(new_size: Vector3i) -> void:
	if new_size.x <= 0 or new_size.y <= 0 or new_size.z <= 0 or new_size == grid_size:
		return
	var old := blocks
	blocks = {}
	grid_size = new_size
	for bk: Vector3i in old:
		var o := QVoxSpec.block_origin(bk, block_size)
		if o.x >= new_size.x or o.y >= new_size.y or o.z >= new_size.z:
			continue  # 整块在外：直接丢，不必逐格判
		var blk: PackedInt32Array = old[bk]
		for lz in block_size:
			for ly in block_size:
				for lx in block_size:
					var gx := o.x + lx
					var gy := o.y + ly
					var gz := o.z + lz
					if gx >= new_size.x or gy >= new_size.y or gz >= new_size.z:
						continue
					var m := blk[QVoxSpec.local_index(lx, ly, lz, block_size)]
					if m != 0:
						_set_solid(gx, gy, gz, m)
	base_revision += 1
	content_changed.emit()


# ----------------------------------------------------------------------------
# 链的编辑入口（UI 把这些包进 QVoxPropertyCommand 后再调用，以保证撤销正确）
# ----------------------------------------------------------------------------

## 追加一条修改器。
##
## 【为什么不接受"算子 + 合成方式"两个裸参数】条目必须自带开关与合成方式，而这些属于修改器
## 而不属于算子（同一棵 Sdf 树既能被并进去，也能被减掉）。所以由调用方先
## `QVoxModifierSerializer.new_modifier(kind)` 造一个空条目、填好核再追加，而不是在这里替它猜默认值。
func add_modifier(modifier: QVoxModifier) -> QVoxModifier:
	if modifier == null:
		return null
	modifiers.append(modifier)
	content_changed.emit()
	return modifier


func remove_modifier(index: int) -> void:
	if index < 0 or index >= modifiers.size():
		return
	modifiers.remove_at(index)
	content_changed.emit()


## 重排（纯数据操作，不依赖任何 context —— 与 Blender 的 modifiers.move 同理）。
func move_modifier(from: int, to: int) -> void:
	var n := modifiers.size()
	if from < 0 or from >= n or to < 0 or to >= n or from == to:
		return
	var m := modifiers[from]
	modifiers.remove_at(from)
	modifiers.insert(to, m)
	content_changed.emit()


## 参与求值的修改器（保持原顺序）。
func active_modifiers() -> Array[QVoxModifier]:
	var out: Array[QVoxModifier] = []
	for m in modifiers:
		if m != null and m.is_active():
			out.append(m)
	return out


# ----------------------------------------------------------------------------
# 内部：盒写入（唯一的体素写入路径，fill/set/apply/undo 全走它）
# ----------------------------------------------------------------------------

## 盒内写入。data 为空 = 用 material_id 填满；否则 data 是按 PcgModel.index_of 布局的
## 盒内密集体积。逐**块**推进（而不是逐体素查字典），块创建/空块回收都在这里收口。
func _write_box(a: Vector3i, b: Vector3i, material_id: int, data: PackedInt32Array) -> int:
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
	var b0 := QVoxSpec.block_of(lo, bs)
	var b1 := QVoxSpec.block_of(hi, bs)
	var n := 0
	var touched: Array[Vector3i] = []
	for bz in range(b0.z, b1.z + 1):
		for by in range(b0.y, b1.y + 1):
			for bx in range(b0.x, b1.x + 1):
				var bk := Vector3i(bx, by, bz)
				var o := QVoxSpec.block_origin(bk, bs)
				# 该块与盒的交集（块内局部闭区间）
				var l0 := Vector3i(maxi(lo.x - o.x, 0), maxi(lo.y - o.y, 0), maxi(lo.z - o.z, 0))
				var l1 := Vector3i(mini(hi.x - o.x, bs - 1), mini(hi.y - o.y, bs - 1),
						mini(hi.z - o.z, bs - 1))
				var blk := get_block(bk)
				if blk.is_empty():
					if const_fill and material_id == 0:
						continue  # 擦空一个未分配的块：本就不存在，不必创建
					blk = PackedInt32Array()
					blk.resize(QVoxSpec.block_volume(bs))
				var base := (o.x - lo.x) + (o.y - lo.y) * dx + (o.z - lo.z) * dxy
				for lz in range(l0.z, l1.z + 1):
					for ly in range(l0.y, l1.y + 1):
						var dst := QVoxSpec.local_index(l0.x, ly, lz, bs)
						var src := base + l0.x + ly * dx + lz * dxy
						for lx in range(l0.x, l1.x + 1):
							var v := material_id if const_fill else data[src]
							if blk[dst] != v:
								blk[dst] = v
								n += 1
							dst += 1
							src += 1
				# 【必须写回】字典取出的 PackedInt32Array 不保证原地改到（逐元素写虽不触发
				# 写时拷贝，但依赖这一点是隐式契约）；写回一次块的代价可忽略。
				blocks[bk] = blk
				touched.append(bk)
	if n > 0:
		# 擦除后可能留下全零块：只检查本次碰过的块（不做全表扫描）
		if not const_fill or material_id == 0:
			for bk in touched:
				if _is_block_empty(blocks.get(bk)):
					blocks.erase(bk)
		base_revision += 1
	return n


func _set_solid(x: int, y: int, z: int, material_id: int) -> void:
	var bk := QVoxSpec.block_of(Vector3i(x, y, z), block_size)
	var blk := get_block(bk)
	if blk.is_empty():
		blk = PackedInt32Array()
		blk.resize(QVoxSpec.block_volume(block_size))
	blk[QVoxSpec.index_in_block(Vector3i(x, y, z), block_size)] = material_id
	blocks[bk] = blk


func _is_block_empty(b: Variant) -> bool:
	if not (b is PackedInt32Array):
		return true
	for m in (b as PackedInt32Array):
		if m != 0:
			return false
	return true


func _in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 and x < grid_size.x and y < grid_size.y and z < grid_size.z
