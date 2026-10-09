@tool
class_name QVoxelModel
extends QVoxelNode
## 模型 —— 树上的叶子，也是**唯一持有手绘体素**的节点（对标 MagicaVoxel 的「模型」、
## 作图软件里的「图层」）。
##
## 【结构 = 手绘基础体素 + 非破坏链】
##   blocks    用户手绘出来的体素（画笔/盒/填充/克隆都写这里）。是"所见即所得"的那部分，
##             也是撤销栈唯一改写的体素数据。
##   modifiers 非破坏链：作用在 blocks **之上**，改参数不改数据。
##   frames    帧动画（§12）：**空 = 静态模型**（零成本）。非空时体素源换成"当前帧的块表"，
##             blocks 退居不用 —— 一个 model_id 恰好一个体素源（VXEL XOR FRAM，§12.2）。
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
##   ② 一致性：`.qvx` 的 VXEL 本来就是"块坐标 → 块内缓冲"（QVoxelSpec §5）。常驻内存用
##      同一形状，落盘/读盘**零转换**（不必在保存时把 dense 切一遍，那正是双份布局的开端）。
##   块内布局权威是 QVoxelBlockCodec（block_of / local_index），本类不另写下标公式。

## 本模型在文件里的 model_id（VXEL 块的键；NODE 节点按它回指）。由 QVoxelWorld 分配。
@export var model_id := 0


## 本模型的节点类型（QVoxelNode 的唯一抽象方法）。
func kind() -> String:
	return KIND_MODEL


## UI 显示名：优先 node_name，其次带 model_id 的默认名。
func display_name() -> String:
	if not node_name.is_empty():
		return node_name
	return "Model %d" % model_id


## 造一个"以算子为链"的模型 —— **程序化产出的标准装配**：有界盒 + 一条链，模型自身不含手绘体素。
##
## 【为什么收成一个入口】"造一个程序化模型"在 demos / 测试里出现几十次。原先每处都要先 new 一个
## 适配器再接线，而接线漏一步的表现是"画了没反应"而不是报错；收成一句之后那种空间就不存在了。
##
## op_ 可以是 PcgModel（整体产出）/ Sdf（逐点采样）/ PcgTransform（重排）/ PcgDetail（体素域改写），
## 域由 QVoxelModifier.of_op 按类型判定；details 是接在源之后的条目（如风化 / 染色），
## detail_seed 是它们共用的种子 —— 同一 seed 下"换算子顺序"不会各自掷出不同的骰子，
## 便于逐算子比对（沿用原 detail_seed 的既定语义）。
## 某一条要单独的随机时，直接设它的 QVoxelModifier.seed 覆盖。
static func of_source(op_: Resource, grid_size: Vector3i, details: Array = [],
		detail_seed := 0) -> QVoxelModel:
	var m := QVoxelModel.new()
	m.grid_size = grid_size
	m.add_op(op_)
	for item in details:
		var mod := m.add_op(item)
		if mod != null:
			mod.seed = detail_seed
	return m

## 分辨率（体素），同时是体积的上限。采纳 MagicaVoxel 的语义：一块对象 = 一块有界体素。
##
## 【为什么是有界】体素域算子（侵蚀/风化/连通性清理）需要完整邻域，与"惰性按 chunk 生成、
## 只持有 32³"的流式架构天然冲突（插件注释里已承认过这个矛盾）。有界模型让矛盾消失。
@export var grid_size := Vector3i(32, 32, 32)

## 块边长 B（= HEAD 的 block_size）。世界级设定，由 QVoxelWorld 在创建/加载时注入。
@export var block_size := QVoxelSpec.DEFAULT_BLOCK_SIZE

## 手绘基础体素：块坐标（Vector3i）→ PackedInt32Array(B³，块内 ZXY，值 = 材质ID，0 = 空）。
##
## 【为什么不是 @export / 不进 .tres】几千万个 int 存成文本 .tres 是灾难。持久化由工程文件
## 负责（QVoxelWorld.to_document → QVoxelFile.serialize），.tres 只当"参数容器"。
## 【空块不存在】全零块 = 块坐标缺失（与文件里的"空块不写入"同一语义）。compact() 负责回收。
var blocks: Dictionary = {}

## 帧动画（§12）：空 = **静态模型**，零成本（P2）。非空时本模型的体素源是"当前帧的块表"，
## `blocks` 退居不用 —— 一个 model_id 恰好对应**一个体素源**（`VXEL` XOR `FRAM`，§12.2），
## 于是"既是静态又是动画"这种自相矛盾的状态在本类里根本表示不出来。
##
## 【为什么每帧存**完整**块表，而不是"相对上一帧的增量"】见 QVoxelFrame 类头：增量是纯存储
## 编解码（写盘时算、读盘时还原），编辑态必须每帧都独立 —— 落笔 / 求值 / 撤销都只看一帧。
var frames: Array[QVoxelFrame] = []

## 编辑 / 预览游标：**读路径**（渲染、求值、拾取、统计）取第几帧的块表。
##
## 【为什么是模型上的瞬态状态，而不是每个调用方各持一个】渲染要的是"这一帧长什么样"，
## 而求值引擎、拾取、状态栏读的都是同一个 `source_blocks()` —— 把游标放在模型上，
## "切一帧"就退化成一次赋值 + 一次作废，整条现有渲染链**一行都不用改**（§12.6 的播放预览）。
## **不落盘**：它是"正在看第几帧"，不是数据（同 expanded_in_tree 的定位）。
var active_frame := 0

## 时间轴元数据（写进 NODE 节点条目的 `anim` 键，§12.3）。只在 `is_animated()` 时有意义。
var anim_loop := true
var anim_fps := 12

## 命名区间（Aseprite 的 tag）：每项 `{name, from, to, direction}`，
## `direction ∈ {forward, reverse, pingpong}`。缺省空（不写 anim.tags）。
var anim_tags: Array = []

## 基础体素的版本号 —— 每次手绘编辑自增。求值引擎用它判断能否复用上一次结果。
## （不哈希数组内容：几百万元素的哈希本身就不便宜，而编辑点已经知道它变了。）
var base_revision := 0


# ----------------------------------------------------------------------------
# 帧（§12）
# ----------------------------------------------------------------------------

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
##
## 静态模型：恒返回 `blocks`（没有帧这一维，`frame` 被忽略）。
## 动画模型：`frame` **夹到 [0, frame_count-1]** —— "写一个不存在的帧"没有第三种合理去处，
##   夹到最近的有效帧至少保证数据仍然合法（写进 `blocks` 反而会造出 VXEL+FRAM 并存的文件，
##   那在序列化时是 FATAL）。
func blocks_for(frame: int) -> Dictionary:
	if frames.is_empty():
		return blocks
	return frames[clampi(frame, 0, frames.size() - 1)].blocks


## 读路径当前该看的块表（渲染 / 求值 / 拾取 / 统计全走它）。`active_frame` 同样夹取 ——
## 删掉几帧后游标可能越界，那时"看最后一帧"比"看一片空白"更接近用户预期。
func source_blocks() -> Dictionary:
	if frames.is_empty():
		return blocks
	return frames[clampi(active_frame, 0, frames.size() - 1)].blocks


# ----------------------------------------------------------------------------
# 帧的编辑入口（UI 把这些包进 QVoxelPropertyCommand 后再调用，以保证撤销正确）
# ----------------------------------------------------------------------------
# 【为什么这些方法不自己入栈】与链编辑入口（QVoxelNode.add_modifier 等）同一约定：
# 命令要能在**改动之前**抓到旧值，所以 begin 必须在调用方手里、在本函数之前。

## 静态 → 动画：把现有静态内容原样搬进第 0 帧（§12.2 一个 model_id 只能有一个体素源）。
## 已经是动画则返回 null 且不动它 —— 否则会把帧内容覆盖成静态源，静默丢帧。
##
## 【为什么由本类做这次搬迁】`blocks` 与 `frames[0].blocks` 是**同一形状**的块表，
## 搬迁只是换个持有者（零拷贝：字典直接交出去，再让静态源空掉）；让调用方自己搬
## 就得把"两个字段谁有效"的知识散到 UI 里去，那正是 §12.2 不变量最容易被破坏的地方。
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


## 插入一帧。`at < 0` = 追加到末尾。返回落点下标（-1 = 入参为 null）。
func add_frame(frame: QVoxelFrame, at: int = -1) -> int:
	if frame == null:
		return -1
	var idx := frames.size() if at < 0 else clampi(at, 0, frames.size())
	frames.insert(idx, frame)
	content_changed.emit()
	return idx


## 删除一帧。**最后一帧不删**：删掉它模型会退回静态，而静态源是空的 —— 那是静默清空整份内容。
## "退回静态"是一个会丢帧的显式操作，不该由删帧隐式代劳（真要退回，就先把某帧的块表写回静态源）。
func remove_frame(index: int) -> bool:
	if index < 0 or index >= frames.size() or frames.size() <= 1:
		return false
	frames.remove_at(index)
	# 游标只保证不越界。要不要"跟着被删的那一帧走"是呈现选择，交给调用方（它知道用户的意图）。
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


# ----------------------------------------------------------------------------
# 体素存取
# ----------------------------------------------------------------------------

## grid_size 对应的元素总数（非法尺寸返回 0）。**仅供参考/UI**：稀疏存储不按它分配内存。
func volume_size() -> int:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		return 0
	return grid_size.x * grid_size.y * grid_size.z


## 已分配的块数（当前体素源）。
func block_count() -> int:
	return source_blocks().size()


## 全空判定（块表空即空，不必遍历 —— 这正是稀疏存储换来的 O(1)）。
func is_empty() -> bool:
	return source_blocks().is_empty()


## 读取体素（越界/未分配块返回 0 = 空）。**读的是当前帧**（source_blocks）。
func get_voxel(x: int, y: int, z: int) -> int:
	if not _in_bounds(x, y, z):
		return 0
	var bk := QVoxelSpec.block_of(Vector3i(x, y, z), block_size)
	var blk: Variant = source_blocks().get(bk)
	if not (blk is PackedInt32Array):
		return 0
	return (blk as PackedInt32Array)[QVoxelSpec.local_index(
			x - bk.x * block_size, y - bk.y * block_size, z - bk.z * block_size, block_size)]


## 写入体素（越界安全）。返回是否真的改了（便于"无变化不入栈"）。
## **不走撤销栈** —— 撤销由工具在手势两端构造一条命令处理（拖拽中逐格入栈会瞬间撑爆栈，
## 60fps 下也不该付这个代价）。
##
## 【为什么写 API 全带 frame 参数，而不是"写 active_frame"】撤销命令必须**帧显式**：用户在第 2 帧
## 落笔、随后把游标切到第 5 帧、再按撤销 —— 若命令跟着游标走，它会把第 5 帧改回去（静默改错帧）。
## 命令因此记住"我改的是第几帧"（§12.6），而 `active_frame` 只影响**读**（渲染看哪一帧）。
func set_voxel(x: int, y: int, z: int, material_id: int) -> bool:
	return set_frame_voxel(-1, x, y, z, material_id)


## 闭区间盒填充（自动夹取到边界内）。返回实际改动的格数（0 = 无变化）。
func fill_box(a: Vector3i, b: Vector3i, material_id: int) -> int:
	return fill_frame_box(-1, a, b, material_id)


## 把一块盒内密集体积写进本对象（撤销重放/导入用）。
## data 布局 = PcgModel.index_of(局部坐标, dims)，dims = 盒尺寸（即 hi - lo + 1）。
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
	var src_blocks := source_blocks()
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


## 摊平成一整块密集体积（布局 = PcgModel.index_of）—— 求值引擎与导出器的入口。
## read_box 在整块范围上的特例，故与它共用一份实现。
##
## 【空对象返回 size 0，而不是一整块零】求值引擎用"空数组"表示"还没有既有体积"，
## 于是"手绘为空"这个情形不必特判，也省掉一次无谓的全量分配 + 扫描（512³ = 537 MB）。
##
## 【但它不代表"链首没有左操作数"】链首那条的 combine 仍要作用在**手绘体素**上（见引擎文件头），
## 故引擎在合并前会显式取一次本函数的结果当左操作数（QVoxelEvalEngine._current）：若把
## "空数组"直接当左操作数，UNION 会退化成 REPLACE（手绘石料凭空消失）、SUBTRACT 会退化成
## "挖不动"—— 恰恰是"手绘 + 程序化混着用"的两种用法。
func to_volume() -> PackedInt32Array:
	if source_blocks().is_empty():
		return PackedInt32Array()
	return read_box(Vector3i.ZERO, grid_size)


## 读取整块（未分配返回空数组）。供落盘/撤销按块搬运。
##
## 【返回的是**活视图**，不是快照】返回的数组与内部 `blocks[block_key]` 共享同一缓冲：
## 逐元素写（`_write_box` 的写法）不会因写时拷贝而自动分身，实测会**就地改到调用方手里这份**。
## 因此：只读走一遍（落盘、生成器采样）可以直接用它；一旦要**留存**（撤销的 before/after 快照、
## 缓存），必须先 `duplicate()` —— 否则那一笔之后的任何编辑都会悄悄改写你留存的"点时刻的值"。
func get_block(block_key: Vector3i) -> PackedInt32Array:
	return get_frame_block(-1, block_key)


## 整体替换一块（长度必须为 B³）。**空缓冲 = 删除该块**。
## 供加载与撤销命令整块搬运（撤销不必逐格 set_voxel 再走一遍"建块/回收"分支）。
##
## 【接管传入的缓冲，不拷贝】调用方若还要留着这份数据（撤销栈要留着，供下次 redo），
## 必须自己传 `duplicate()` —— 否则对象随后的就地编辑会改到你手上这一份。
func set_block(block_key: Vector3i, buf: PackedInt32Array) -> void:
	set_frame_block(-1, block_key, buf)


## 读取**指定帧**的整块（frame < 0 = 静态源）。活视图语义同 get_block。
func get_frame_block(frame: int, block_key: Vector3i) -> PackedInt32Array:
	var b: Variant = blocks_for(frame).get(block_key)
	return b if b is PackedInt32Array else PackedInt32Array()


## 替换**指定帧**的整块（frame < 0 = 静态源）。空缓冲 = 删除该块。
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
##
## 【为什么必须排序】Dictionary 的迭代顺序不保证稳定，而落盘顺序、增量写的块搬运、
## 回归测试的逐字节哈希都要求确定性 —— 排序让"同一份数据"恒得"同一串字节"。
func block_keys() -> Array[Vector3i]:
	return _sorted_keys(source_blocks())


## 回收全零块（空块 = 块坐标缺失）。返回丢弃的块数。
func compact() -> int:
	return _compact_table(source_blocks())


## 清空（整表丢弃，O(1) —— dense 方案这里要 fill 一整块内存）。
## **连帧一起清**：`clear()` 的语义是"这个模型什么都没有了"，只清当前帧会留下几帧孤儿体素。
func clear() -> void:
	if blocks.is_empty() and frames.is_empty():
		return
	blocks.clear()
	frames.clear()
	active_frame = 0
	base_revision += 1
	content_changed.emit()


## 已填充的体素数量（UI 状态栏用；与已分配块数成正比，别放进热路径）。统计当前帧。
func count_solid() -> int:
	return _count_solid(source_blocks())


## 用过的材质ID（供调色板 UI 只列出在用的档）。
##
## 【动画模型为什么扫**所有**帧】调色板是"这份工程用了哪些材质"，而调色板本身是世界的
## （MATE 只存一次）；只看当前帧会让"只在第 7 帧出现过的颜色"在调色板里凭空消失。
func used_materials() -> Dictionary:
	var used := {}
	if not is_animated():
		return _used_materials(blocks)
	for f in frames:
		for m in _used_materials(f.blocks):
			used[m] = true
	return used


## 改分辨率：保留新旧尺寸交集内的体素，其余丢弃。
## 这是"重采样"级操作，UI 必须把它做成一条显式命令（提示代价），而不是随手可拖的滑条。
##
## 【动画模型为什么逐帧重采样】分辨率是模型的属性（一份 FRAM 共用一个盒），
## 只改静态源会让每一帧与新的 grid_size 对不上（越界体素被静默丢掉 / 帧比盒子还大）。
func resize_grid(new_size: Vector3i) -> void:
	if new_size.x <= 0 or new_size.y <= 0 or new_size.z <= 0 or new_size == grid_size:
		return
	blocks = _resized_table(blocks, new_size)
	for f in frames:
		f.blocks = _resized_table(f.blocks, new_size)
	grid_size = new_size
	base_revision += 1
	content_changed.emit()


# ----------------------------------------------------------------------------
# 内部：盒写入（唯一的体素写入路径，fill/set/apply/undo 全走它）
# ----------------------------------------------------------------------------

## 盒内写入。data 为空 = 用 material_id 填满；否则 data 是按 PcgModel.index_of 布局的
## 盒内密集体积。逐**块**推进（而不是逐体素查字典），块创建/空块回收都在这里收口。
##
## 【为什么 target 是显式形参，而不是"写 self.blocks"】同一套写入逻辑要服务两种体素源
## （静态 `blocks` 与某一帧的块表）—— 让 target 进来，块创建 / 空块回收 / 标脏只有一份实现，
## 两个入口（set_voxel / set_frame_voxel）只是各传一个字典（rule：能统一就统一）。
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
				# 写时拷贝，但依赖这一点是隐式契约）；写回一次块的代价可忽略。
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


func _block_of_table(target: Dictionary, bk: Vector3i) -> PackedInt32Array:
	var b: Variant = target.get(bk)
	return b if b is PackedInt32Array else PackedInt32Array()


func _is_block_empty(b: Variant) -> bool:
	if not (b is PackedInt32Array):
		return true
	for m in (b as PackedInt32Array):
		if m != 0:
			return false
	return true


## 全零块回收（按表）。compact() 的实现在此，静态源与帧共用。
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
	var keys: Array[Vector3i] = []
	for k in target:
		keys.append(k)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	return keys


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


## 重采样一张块表到 new_size（保留交集内的体素）。resize_grid 的实现在此，静态源与帧共用。
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
