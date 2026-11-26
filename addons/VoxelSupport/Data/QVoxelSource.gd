@tool
class_name QVoxelSource
extends Resource

## 可序列化的体素数据资源（运行时渲染 / 修改 / 破坏）。
## 【统一材质契约】（全项目权威，见 VoxelMaterial.gd）
##   - 材质ID 0 = 空：既没有体素也没有材质
##   - 存储值 == 材质ID（0 = 空），无任何 +1/-1 编码偏移
##   - 对齐后材质数组索引 == 材质ID，索引 0 恒为 null 占位

# 可见性约定：无 `_` 前缀 = 公开 API（承诺向后兼容，破坏性改动须走弃用期）；
# 带 `_` 前缀 = 内部协议，只有内核层（VoxelRenderer / VoxelEditKernel /
# VoxelViewLayer）可调用 —— QVoxelier / 用户脚本 / demo 一律不得调用，
# 也不得绕过封装直改存储。
# 锁：Scripts/Test/test_voxel_kernel_contract.gd 的 VOXEL_DATA_PUBLIC_API /
#     VOXEL_DATA_INTERNAL_PROTOCOLS 钉住了这份清单，增删公开方法必须同步改测试。

## 材质数组 (索引即材质ID，使用 VoxelMaterial)
@export var materials: Array[VoxelMaterial] = []

## 帧数量 (保留用于未来动画扩展)
@export var frame_count: int = 1

## 体素网格尺寸 (体素个数，由导入时计算)。有限尺寸同时就是**求值输出的边界盒**。
## 变化时作废已缓存的求值体积 —— 尺寸变了，旧体积的下标布局就错了。
@export var grid_size: Vector3i = Vector3i.ZERO:
	set(v):
		if grid_size == v:
			return
		grid_size = v
		_invalidate_volume()

## 缩放比例 (仅作为导入时的默认值，实际渲染缩放由 VoxelRenderer 控制)
@export var default_scale: float = 0.1

## 求值主种子（→ QVoxelEvalContext.seed）。生成工具烘焙时也用它作默认随机源。
@export var seed: int = 0:
	set(v):
		if seed == v:
			return
		seed = v
		_invalidate_volume()

## 数据层磁盘流：非空时启用按需加载 —— 内存只留已加载的 chunk，磁盘为权威。
## 流式卸载的半径必须外扩"最粗层 block 的覆盖范围"：粗层降采样要读它覆盖的 LOD0 chunk，
## 卸早了会读到假空块。
@export var stream: VoxelStream:
	set(v):
		if stream == v:
			return
		if stream != null and _dirty.has_any(0, VoxelDirtyLedger.PERSIST):
			flush()
		stream = v
		# 内存里已有、新流里没有的 chunk 必须重新标记"待写"：flush 只保证旧流完好（它已清空标记），
		# 不补标的话这些 chunk 卸载时会被当成"流里已有"丢弃，而新流从未见过它们 → 数据静默丢失。
		for ck in _chunk_buffers:
			if stream == null or not stream.has_chunk(ck, 0):
				_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
		_sync_source()

## 数据源：任意 `QVoxelNode`（World / Group / Model）。
## 与 stream 可并存，取数优先级恒为 **流 > 节点**：存过的必须权威，不能被重新求值覆盖。
@export var node: QVoxelNode:
	set(v):
		if node == v:
			return
		node = v
		_sync_source()

## 取数编排器：全项目唯一持有"在途 / 就绪"这本账的地方。
var _async := VoxelAsyncLoader.new()


## 构造期就把编排器指向自己：程序化源不需要 node/stream，若只在 setter 里 configure，
## 它会处于 source=null → request 被静默撤销 → 画面永远空白（VX-01）。
## 换源仍走 _sync_source()；这里只是给"无节点/无流"的源一个正确初值。
func _init() -> void:
	_async.configure(self)


## 换源：作废在途 / 就绪登记（旧源的请求回填进新数据会写出错坐标的数据），并交给编排器。
func _sync_source() -> void:
	_invalidate_volume()
	if _async == null:
		return
	_async.clear()
	_async.configure(self)


# 求值体积与切片（吸收自 VoxelGenerator / PcgModelGenerator）
# 这一层原本是独立的"生成器"抽象，好让渲染器不认识 node。但它做的每一件事都已在别处存在：
#   体积从哪来       → QVoxelEvalEngine.evaluate_node（已能求值任意节点）
#   整块 → 逐 chunk  → PcgModelGenerator._generate_chunk
#   缓存体积         → PcgModelGenerator._ensure_volume
# 于是三个类塌成一个字段：node。缓存 / 切片 / LOD 逻辑全项目仍只有一份 —— 就在这里。

## 整块求值结果（惰性构建一次，之后只读）。值 = 材质ID，0 = 空。
var _volume := PackedInt32Array()
var _volume_origin := Vector3i.ZERO
var _volume_grid_size := Vector3i.ZERO
var _volume_built := false
## 上一行的非空格数，惰性数一次（-1 = 还没数，见 evaluated_voxel_count）。
## **不变式：_volume 一旦被换掉，上面这些缓存字段必须一起复位**，复位只走
## _reset_volume_cache（见那里的说明）—— 逐处手写迟早有人漏掉一个字段。
var _volume_count := -1

## 构建互斥：首帧多个 worker 会同时走到 _ensure_volume，无锁则各自求值一遍。
var _volume_mutex := Mutex.new()


## 求值体积缓存的重置（**唯一收口**）：所有换掉 _volume 的地方都从这里开始。
## 【为什么必须收口】此前是在注释里承诺"三处都要记得把计数置回 -1"，而同一份清单里还躺着
## origin / grid_size / built 三个字段 —— 谁新增一个缓存字段、谁改一处赋值，就多一个没人
## 检查的漂移点（只重置一半的后果是切片按下标读旧布局的数据，静默错格）。收成一个函数后，
## 漏字段在结构上就不可能发生。
func _reset_volume_cache() -> void:
	_volume = PackedInt32Array()
	_volume_origin = Vector3i.ZERO
	_volume_grid_size = Vector3i.ZERO
	_volume_built = false
	_volume_count = -1


## 作废缓存的求值体积（换源 / 改尺寸 / 手绘编辑后必须调用）。
## 不取锁：由主线程调用，不能阻塞在途 worker；用"提交前比对尺寸"丢弃过期结果。
func _invalidate_volume() -> void:
	_reset_volume_cache()


## **求值缓存作废**：手绘体素或链参数被改动后由编辑侧调用（会话封口一笔手势时）。
## 时机必须由调用方显式给出：手绘一笔可能逐格写几万次，QVoxelModel 刻意不发逐格信号，
## 数据层无从嗅探"这一笔画完了"。
## 与 invalidate_chunk_source 的分工：那个作废切出来的 chunk 缓冲，这个作废整块求值体积。
func invalidate() -> void:
	_invalidate_volume()


## 节点求值输出盒 —— 去链后模型恒等于 node.grid_size；组 / 世界返回 ZERO（由内容算紧致盒）。
func output_grid_size() -> Vector3i:
	var m := node as QVoxelModel
	if m == null:
		return Vector3i.ZERO
	return m.grid_size


## 求值 / 边界判定用的基础盒：数据层显式声明的 grid_size 优先，未声明时问节点自己。
func _base_grid_size() -> Vector3i:
	if grid_size != Vector3i.ZERO:
		return grid_size
	return output_grid_size()


## 节点求值输出的边界盒（chunk 坐标）是否包含该 key。渲染器距离扫描高频调用，故 O(1)、零分配。
func is_in_node_bounds(key: Vector3i, lod: int = 0) -> bool:
	if node == null:
		return false
	var gs := _base_grid_size()
	if gs == Vector3i.ZERO:
		return true  # 无界：任意 chunk 可求值（组 / 世界自己按内容算紧致盒）
	var lo := Vector3i.ZERO
	var hi := VoxelChunk.chunk_of(gs - Vector3i.ONE)
	if lod >= 1:
		var span := 1 << lod
		var blo := key * span
		var bhi := blo + Vector3i(span - 1, span - 1, span - 1)
		return blo.x <= hi.x and bhi.x >= lo.x \
			and blo.y <= hi.y and bhi.y >= lo.y \
			and blo.z <= hi.z and bhi.z >= lo.z
	return key.x >= lo.x and key.x <= hi.x \
		and key.y >= lo.y and key.y <= hi.y \
		and key.z >= lo.z and key.z <= hi.z


## 统一生成入口：按 lod 分流（0 → chunk，>=1 → 粗层 block）。供 VoxelAsyncLoader 后台线程调用。
func generate(key: Vector3i, lod: int = 0) -> PackedInt32Array:
	return _generate_chunk(key) if lod == 0 else _generate_chunk_lod(key, lod)


## 惰性求值一次：无节点时返回 false（生成全空）。不判 grid_size 为零 —— 求值结果自带盒与原点，
## 模型走自己的 grid_size、组 / 世界走内容紧致盒，都不依赖调用方预先告知尺寸。
## 【并发】① 快路径先查 _volume_built（稳态下每个 chunk 都走这条路，不付锁开销）；
## ② 锁内再查一次（等锁期间别人可能已建好）；③ 提交前校验 grid_size 未变 —— setter 由主线程
## 调用且不能取锁，故用"构建完比对"丢弃过期结果；④ **空体积也要提交 _volume_built**，
## 否则每个 chunk 都会重跑一次整块求值。
func _ensure_volume() -> bool:
	if _volume_built:
		return true
	if node == null:
		return false
	_volume_mutex.lock()
	if not _volume_built:
		var gs := grid_size
		var ctx := QVoxelEvalContext.make(gs, seed)
		var res := QVoxelEvalEngine.evaluate_local(node, ctx)
		if gs == grid_size:
			# 先复位再写入：以后新增缓存字段只需改 _reset_volume_cache 一处
			_reset_volume_cache()
			_volume = res.volume
			_volume_origin = res.origin
			_volume_grid_size = res.grid_size
			_volume_built = true
	_volume_mutex.unlock()
	return _volume_built


## LOD0：从缓存体积里切出 32³ 的一块。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(VoxelChunk.CHUNK_VOLUME)
	if not _ensure_volume():
		return buf
	var vol := _volume
	if vol.is_empty():
		return buf  # 源产出空体积（空链 + 无手绘体素）：直接给全空，别去下标越界
	var gs := _volume_grid_size
	var base := VoxelChunk.origin_of(chunk_key) - _volume_origin
	for lz in VoxelChunk.CHUNK_SIZE:
		var gz := base.z + lz
		if gz < 0 or gz >= gs.z:
			continue
		for ly in VoxelChunk.CHUNK_SIZE:
			var gy := base.y + ly
			if gy < 0 or gy >= gs.y:
				continue
			var src := gy * gs.x + gz * gs.x * gs.y
			var dst := VoxelChunk.buf_index(0, ly, lz)
			for lx in VoxelChunk.CHUNK_SIZE:
				var gx := base.x + lx
				if gx < 0 or gx >= gs.x:
					continue
				var m := vol[src + gx]
				if m > 0:
					buf[dst + lx] = m
	return buf


## 粗层 LOD：每个大格取 2^lod 立方内**任一非空**体素的材质（取到即实心）。
## 不用"取格心采样"：整体产出的模型常有薄壁，取格心会把它整片采没 —— 宁可粗层偏实心。
func _generate_chunk_lod(block_key: Vector3i, lod: int) -> PackedInt32Array:
	var grid := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var buf := PackedInt32Array()
	buf.resize(grid * grid * grid)
	if not _ensure_volume():
		return buf
	var cell := 1 << lod
	var base := block_key * (grid * cell) - _volume_origin
	var gs := _volume_grid_size
	var vol := _volume
	if vol.is_empty():
		return buf
	for lz in grid:
		for ly in grid:
			for lx in grid:
				var m := _sample_cell(vol, gs, base + Vector3i(lx, ly, lz) * cell, cell)
				if m > 0:
					buf[lx + ly * grid + lz * grid * grid] = m
	return buf


## 粗格内任一非空体素的材质（无则 0）。volume / gs 由调用方捕获传入而非读成员：
## PackedInt32Array 是写时复制，局部句柄即使期间被重建也安全。
func _sample_cell(volume: PackedInt32Array, gs: Vector3i, origin: Vector3i, cell: int) -> int:
	for dz in cell:
		var z := origin.z + dz
		if z < 0 or z >= gs.z:
			continue
		for dy in cell:
			var y := origin.y + dy
			if y < 0 or y >= gs.y:
				continue
			var row := y * gs.x + z * gs.x * gs.y
			for dx in cell:
				var x := origin.x + dx
				if x < 0 or x >= gs.x:
					continue
				var m := volume[row + x]
				if m > 0:
					return m
	return 0

## 居中偏移（体素单位，渲染时叠加到网格顶点；不影响破坏 / 查询逻辑，它们基于原始数据坐标）。
## 导入时若 center 选项开启，自动使模型左右前后居中(X/Z)、上下贴底(Y=0)。
@export var center_offset: Vector3 = Vector3.ZERO

## 脏账本唯一权威（写盘 / 网格重建 / LOD 失效 / 粗层回退 / 脏区域 全在里面，见 VoxelDirtyLedger）。
## 所有修改都标记到 chunk 粒度，避免逐体素脏集合的主线程 dict 写入瓶颈（大崩塌每帧数千体素）。
var _dirty := VoxelDirtyLedger.new()

## 标记体素所在 chunk 需要重建（含 6 个跨界面的边界邻居 —— 面可见性依赖邻居）。
func _mark_voxel_dirty(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
	# LOD0 用户编辑 → 失效对应高层 block 并标记需降采样（编辑数据不能用纯生成器输出）
	mark_lod_modified(pos)
	# 跨界面邻居：体素落在块边界上时，沿该方向越界的那一侧 chunk 也要重建。
	# 走 NEIGHBORS_6（唯一真值）而不是再手写一份 3 轴 if/elif —— 后者是同一张方向表的
	# 第二、第三份抄本，加一层方向就得改三处。
	var local := pos - ck * CHUNK_SIZE
	for dir: Vector3i in NEIGHBORS_6:
		var nl := local + dir
		# dir 是单位轴向量，故"越界"只可能发生在该轴上，越界后的 chunk 就是 ck + dir
		if nl.x < 0 or nl.y < 0 or nl.z < 0 or nl.x >= CHUNK_SIZE or nl.y >= CHUNK_SIZE or nl.z >= CHUNK_SIZE:
			_dirty.mark(0, ck + dir, VoxelDirtyLedger.MESH)


## 标记单个 chunk 需要重建（补建 / 流式加载 / 粗层回填路径用）。脏集合是数据层状态，不该外部直改。
func mark_chunk_dirty(ck: Vector3i) -> void:
	_dirty.mark(0, ck, VoxelDirtyLedger.MESH)


## 让一个 chunk 的**来源数据**作废：丢掉内存副本，下次取数重新按"流 > 生成器"读入。
## 【不是卸载语义】unload_chunk() 会先把内存缓冲**写回流**（把生成结果固化成用户数据），
## 此后该块永远不会再重新生成 —— 那是卸载，混用会让程序化地形"冻结"在第一帧的形态。
## 连 LOD 一起失效：粗层块由 LOD0 降采样而来，LOD0 换了而粗层不换，远处会继续显示旧形状。
## 本方法是"作废"而非"同步重载"：实际重取由流式泵按需发起。
func invalidate_chunk_source(ck: Vector3i) -> void:
	# 在途登记要撤（迟到的回填会写进已作废的块）、置"源作废"（渲染层据此**保留**旧网格防闪，
	# 与 unload_chunk 的"真卸载"相反）、粗层一起失效（LOD0 换了粗层不换 = 远处旧形状）。
	_drop_chunk(ck, {
		"cancel_async": true,
		"invalidate_source": true,
		"drop_lod": true,
		"mark_mesh": true,
		"mark_neighbors": true,
	})


## chunk 是否"源被作废、等待重新取数"（渲染层用它区分"暂时没有"与"真的没有"）。
func _is_chunk_source_invalidated(chunk_key: Vector3i) -> bool:
	return _source_invalidated.has(chunk_key)


## 让一个**体素范围**覆盖的所有 chunk 的来源数据作废（闭区间，含端点）。返回覆盖的 chunk 数。
## 只做"体素范围 → chunk 键"的换算与转发（每个消费者各写一遍只会漏掉边界情形）；
## 范围外的 chunk 缓冲保留旧内容 —— 那些内容对未编辑区域仍然正确。
func invalidate_chunk_source_range(lo: Vector3i, hi: Vector3i) -> int:
	var a := Vector3i(mini(lo.x, hi.x), mini(lo.y, hi.y), mini(lo.z, hi.z))
	var b := Vector3i(maxi(lo.x, hi.x), maxi(lo.y, hi.y), maxi(lo.z, hi.z))
	var c0 := _chunk_of(a)
	var c1 := _chunk_of(b)
	var n := 0
	for cz in range(c0.z, c1.z + 1):
		for cy in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				var ck := Vector3i(cx, cy, cz)
				invalidate_chunk_source(ck)
				# 【作废之后必须重新起一次取数】invalidate 会取消在途请求，而渲染层对
				# "源作废"的 chunk 是**剔除不重建**的（防闪）。不再请求一次，这条链就断在
				# 这里：撤销 / 删除后数据已经没了，画面上的旧网格却还在 —— 直到下次碰它
				# 才被顺带刷掉。回填（或判定为空）时 `_accept_chunk_buffer` /
				# `_maybe_erase_empty_chunk` 会清掉标记并重新标脏，渲染器届时才正确重建。
				_refill_chunk(ck)
				n += 1
	return n


## 作废之后重新排队取数：流式从存储读，非流式交给异步生成器（由求值体积产出）。
func _refill_chunk(ck: Vector3i) -> void:
	if is_stored(ck):
		preload_chunk(ck)
		return
	if node != null and is_in_node_bounds(ck):
		_async.request(ck, 0)


## 该 chunk 是否已标脏待重建。**不取走**（取走并清空请用 get_dirty_chunks）。
func is_chunk_mesh_dirty(ck: Vector3i) -> bool:
	return _dirty.has(0, ck, VoxelDirtyLedger.MESH)


## 待重建 chunk 数（渲染器每帧预算判断用；不构造数组）。
func get_dirty_mesh_chunk_count() -> int:
	return _dirty.count(0, VoxelDirtyLedger.MESH)


## chunk 数据就绪 → 标记依赖其 halo 的 6 个相邻 chunk 重建（边界 mesh 缝合）。
## 否则该 chunk 就绪后不触发邻居重建 → 边界外侧面缺失，横/竖/块状空洞固定存在。
func _mark_neighbors_dirty(chunk_key: Vector3i) -> void:
	# 方向表只从 NEIGHBORS_6（VoxelConnectivity 的真值）来 —— 此前这里每次调用现造一个
	# 6 元素字面量数组（顺便还和真值表的方向顺序不一致，改真值就会静默漏标邻居）。
	for dir: Vector3i in NEIGHBORS_6:
		var nb: Vector3i = chunk_key + dir
		if _chunk_buffers.has(nb) and not _dirty.has(0, nb, VoxelDirtyLedger.MESH):
			_dirty.mark(0, nb, VoxelDirtyLedger.MESH)


## 原生批量接口返回的`边界掩码`的**位序**（bit i → 哪个方向）。
## 【为什么不直接用 NEIGHBORS_6 的下标】原生掩码的位序是 **+x,-x,+y,-y,+z,-z**
## （voxel_native.cpp 的 boundary 约定），而 VoxelConnectivity.NEIGHBORS_6 是
## **+x,-x,+z,-z,+y,-y** —— 两者不一致。这里把"位序"显式写成一张映射表指向
## NEIGHBORS_6 的下标，于是方向真值仍只有一份，且换真值表的顺序也不会静默标错方向。
const BOUNDARY_BIT_TO_NEIGHBOR: Array[int] = [0, 1, 4, 5, 2, 3]


## 按原生`边界掩码`把相邻 chunk 标的网格重建脏标记（set_voxels 与 _remove_voxels 共用）。
## 【为什么抽出来】两处原本各有 6 个完全同构的 `if b & N: _dirty.mark(...)` —— 一字不差
## 复制两遍，改一处忘另一处就是"编辑后邻居界面不重建"的隐蔽 bug。
func _mark_boundary_dirty(chunk_key: Vector3i, mask: int) -> void:
	if mask == 0:
		return
	for bit in BOUNDARY_BIT_TO_NEIGHBOR.size():
		if (mask >> bit) & 1:
			_dirty.mark(0, chunk_key + NEIGHBORS_6[BOUNDARY_BIT_TO_NEIGHBOR[bit]], VoxelDirtyLedger.MESH)


# LOD 分层：LOD0 = 全精度 chunk；LOD i = LOD_GRID³ 大块，每格代表 2^i 体素。
#   block_key = LOD0 chunk_key >> i；block 覆盖 (LOD_GRID × 2^i)³ 体素。
#   层级数由 lod_count 控制（渲染器同步设置）。
## LOD 层级数（含 LOD0）。编辑体素时按此失效所有更高层 block；1 = 仅全精度无 LOD。
@export var lod_count: int = 2

## 大块网格边长（大格数，每格 = 2^lod 体素）；恒等于 CHUNK_SIZE（与原生 32³ 网格核心一致）
const LOD_GRID := VoxelChunk.CHUNK_SIZE

# 每级失效的 block 记在 _dirty 的粗层账里（见 VoxelDirtyLedger.LOD_MESH）



## 失效指定 LOD0 chunk 对应的所有更高层 LOD block（仅网格重建，不标记 modified）
func invalidate_lod_for_chunk(ck: Vector3i) -> void:
	for lod in range(1, maxi(lod_count, 1)):
		_mark_lod_invalid(Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod), lod)


## 用户编辑体素：失效高层 block 并标"需降采样"（编辑影响该 block，不能用纯生成器数据）。
## 金字塔增量：保留 coarse 缓存，只记脏大格区域（未脏大格复用）。
func mark_lod_modified(pos: Vector3i) -> void:
	var ck := _chunk_of(pos)
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		_mark_lod_dirty_region(bk, lod, pos, pos)


## 用户编辑 chunk（批量）：标记覆盖它的所有高层 block 需降采样（同上，脏区域为整 chunk）。
func mark_lod_modified_for_chunk(ck: Vector3i) -> void:
	var vox_min := ck * CHUNK_SIZE
	var vox_max := vox_min + Vector3i(CHUNK_SIZE - 1, CHUNK_SIZE - 1, CHUNK_SIZE - 1)
	for lod in range(1, maxi(lod_count, 1)):
		var bk := Vector3i(ck.x >> lod, ck.y >> lod, ck.z >> lod)
		_mark_lod_invalid(bk, lod)
		_mark_coarse_modified(bk, lod)
		_mark_lod_dirty_region(bk, lod, vox_min, vox_max)


## 记录 block 的脏大格区域（体素范围覆盖的 block 内大格，并集）。换算与 clamp 属几何职责，
## 留在数据层；并集记账交给账本。
func _mark_lod_dirty_region(block_key: Vector3i, lod: int, vox_min: Vector3i, vox_max: Vector3i) -> void:
	var gmin := Vector3i(vox_min.x >> lod, vox_min.y >> lod, vox_min.z >> lod) - block_key * LOD_GRID
	var gmax := Vector3i(vox_max.x >> lod, vox_max.y >> lod, vox_max.z >> lod) - block_key * LOD_GRID
	gmin = Vector3i(clampi(gmin.x, 0, LOD_GRID - 1), clampi(gmin.y, 0, LOD_GRID - 1), clampi(gmin.z, 0, LOD_GRID - 1))
	gmax = Vector3i(clampi(gmax.x, 0, LOD_GRID - 1), clampi(gmax.y, 0, LOD_GRID - 1), clampi(gmax.z, 0, LOD_GRID - 1))
	if gmax.x < gmin.x or gmax.y < gmin.y or gmax.z < gmin.z:
		return
	_dirty.mark_region(lod, block_key, gmin, gmax)


## 取并清空指定 block 的脏大格区域（渲染器增量降采样消费）
func get_lod_dirty_region(lod: int, bk: Vector3i) -> Array:
	return _dirty.take_region(lod, bk)


## 记录指定层级 block 失效（通知渲染器重建）
func _mark_lod_invalid(block_key: Vector3i, lod: int) -> void:
	_dirty.mark(lod, block_key, VoxelDirtyLedger.LOD_MESH)


## 标记粗层 block 需降采样（编辑影响该 block，不能用纯生成器数据）
func _mark_coarse_modified(block_key: Vector3i, lod: int) -> void:
	if lod < 1:
		return
	_dirty.mark(lod, block_key, VoxelDirtyLedger.COARSE_MODIFIED)


## 清空所有层级失效标记
func clear_lod_cache() -> void:
	_dirty.clear_flags_all(VoxelDirtyLedger.LOD_MESH)



## 获取指定层级的失效 block（渲染器 _process_lod 消费后重建），并清空
func get_invalidated_lod(lod: int) -> Array[Vector3i]:
	return _dirty.take(lod, VoxelDirtyLedger.LOD_MESH)


## 是否有失效的粗层 block 待重建（渲染器据此在数据变化时立即触发 LOD 处理，不等降频周期）
func has_lod_invalidated() -> bool:
	return _dirty.has_any_from(1, VoxelDirtyLedger.LOD_MESH)


## 获取所有脏 chunk（渲染器增量重建用），并清空
func get_dirty_chunks() -> Array[Vector3i]:
	return _dirty.take(0, VoxelDirtyLedger.MESH)


## Chunk 几何常量唯一权威源见 VoxelChunk，此处全部派生别名防止漂移
const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const CHUNK_SLICE := VoxelChunk.CHUNK_SLICE
## 块内最大合法下标（= CHUNK_SIZE - 1）。块边界的邻居判断用。
const CHUNK_LAST := VoxelChunk.CHUNK_SIZE - 1
const HALO := VoxelChunk.HALO
const HALO_SIZE := VoxelChunk.HALO_SIZE
const HALO_VOLUME := VoxelChunk.HALO_VOLUME

## chunk key -> 密集缓冲 (PackedInt32Array, 32³)，值 = 材质ID（0 = 空）。空 chunk 不在此字典中。
var _chunk_buffers: Dictionary = {}

## 逐体素累计伤害账（存储结构 / 生命周期规则 / 线程约定见 VoxelDamageStore）。
## 留在数据层是硬要求：它必须与 chunk 缓冲同生共死（卸载 / 清空 / origin shift /
## 载荷重建都要同步处理），破坏节点无人负责清理。
var _damage := VoxelDamageStore.new()

## 每粗 LOD 独立数据层：_coarse_buffers[level-1] = {block_key: PackedInt32Array(LOD_GRID³ 大格)}，
## 值 = 材质ID（0=空），每格 = 2^level 体素。各 LOD 数据块独立：未修改的粗层 block 由
## _generate_chunk_lod 直接生成，无需加载全部 LOD0 chunk。
var _coarse_buffers: Array[Dictionary] = []

## 需降采样回退的粗 LOD block 记在 _dirty 的粗层账里（见 VoxelDirtyLedger.COARSE_MODIFIED）。
## LOD0 编辑影响该 block 时标记，下次渲染走降采样（合并 LOD0 数据）而非生成器。

## 文件流（无粗层生成器）的粗层数据从 LOD0 chunk 降采样生成，结果缓存到 _coarse_buffers
## 并持久化到文件流，避免每次渲染都重复降采样。
## 【账本不在这里】在途去重 + 空结果重试计数由 VoxelAsyncLoader 统一持有，本类只构造快照、
## 派发 worker、交回结果，不再另存一份并行 pending 账本。

## 只读快照持有者计数：>0 表示有 worker 可能共享底层缓冲，单点写路径须先分叉（O(1) 判据）。
var _snapshot_readers: int = 0

## 存活的快照句柄（handle -> true）：世界级重置（clear / 载荷重建）时强制回收，避免泄漏句柄
## 永久钉住 _snapshot_readers；也是 end_readonly_snapshot() 兼容 shim 判断该释放哪个的依据。
var _live_snapshots: Dictionary = {}

## 每 chunk 体素计数（chunk key -> int，增量维护 O(1)）。**体素数的唯一权威**：全局总数由它
## 派生（见 get_voxel_count），无第二份存储可漂移。
## 不变式：只含 > 0 的条目（归零即移除），故 is_empty() 恒等价于"总数为 0"；
## 写入口只有 _count_delta / _count_set，其余路径一律不得直接改本字典。
## 它替代了"归零后扫 4096 格"的判定，消除破坏 / 崩塌热路径的 32³ 循环。
var _chunk_voxel_counts: Dictionary = {}

## 全场体素总数的**增量镜像**（get_voxel_count 变 O(1)，此前每次调用要对上面整张表求和）。
## 不变式：恒等于 _chunk_voxel_counts 全部值之和。改这块表的每条路径都必须经
## _count_delta / _count_set **或** _count_erase / _count_clear 同步它 —— 直接
## `_chunk_voxel_counts.erase()` 会在下一次 get_voxel_count 时把旧数字留在总数里（只增不减）。
var _voxel_count_total: int = 0

## 源被"作废"（缓冲已丢、等待按流 > 生成器重新取数）的 chunk。与"无数据"区分开：
## 前者只是暂时取不到，渲染层要**保留旧网格**直到新结果到达；后者才该清网格。
## 少了这个区分，编辑收笔时作废源缓冲会让 has_chunk 瞬时为假 → 渲染器把还看得见的网格
## 抹掉、再异步重建 → "改一下模型就闪一下"（见 invalidate_chunk_source / VoxelRenderer）。
var _source_invalidated: Dictionary = {}

## 内存中被修改过的 chunk 记在 _dirty 的 level 0 账里（VoxelDirtyLedger.PERSIST）。两个用途：
## ① 存储回写（卸载时写盘 / 变空时清盘）；② 资源持久化（只把改过的块写进载荷）。
## 故不能只在有 stream 时维护 —— 加载 / 导入路径也必须逐块登记。

## 6 方向邻居偏移别名。真值在 VoxelConnectivity.NEIGHBORS_6，此处留名以免出现第二份真值。
const NEIGHBORS_6: Array[Vector3i] = VoxelConnectivity.NEIGHBORS_6


# 资产原点（导入选项 mesh/origin）—— `.vox`/`.qvx` × mesh/data 四条链路共用的唯一约定。
## 【为什么必须统一】同一个模型经 mesh 与 data 两条路径进场景必须落在同一位置：此前 mesh 路径
## 保留 MagicaVoxel 的作者摆放、data 路径把内容 AABB 角点当原点（贴地），实测同一模型两侧底面
## 差 0.35~0.50（模型边长 2.2），看着像"位置差很多"，而体素数据其实完全一致。
## 【为什么默认 WORLD_ORIGIN】导入器不该在没被要求时移动顶点几何：这一档原样保留文件坐标，
## 也是本插件网格导入一直以来的行为（默认沿用它，已有资产不会因升级挪位），且多模型装配的
## 相对位置只有它保得住（其余两档会把每个模型各自归位）。需要"贴地居中"（角色 / 道具原点在
## 脚底中心）时再显式选 BOTTOM_CENTER。
## 【名字含义】"源文件世界的原点 (0,0,0) 就是 Godot 的原点"—— 模型停在作者摆放的位置，而不是
## 被搬到原点；是 origin 而非 center。`.qvx` 没有"世界"这一层，此档即"文件里的坐标原样"。
## 原点模式 / 求界 / 偏移已**下沉到基础层 `VoxelWorldUtil`**（网格导入不该依赖动态数据层）。
## 这里保留同名转发，使既有调用点（本层内部、外部测试、编辑器）无需改动。
const OriginMode = VoxelWorldUtil.OriginMode



## 从 VoxAsset 构造（编辑器导入时使用）。`origin_mode` 决定模型摆到哪，据此写 `center_offset`。
static func from_voxel_data(voxel_data: VoxAsset, frame_index: int = 0,
		origin_mode: int = OriginMode.WORLD_ORIGIN) -> QVoxelSource:
	var res := QVoxelSource.new()
	var raw_voxels := voxel_data.get_voxels(frame_index)

	# 体素坐标重映射到 [0, grid_size)：原始坐标落在 [offset, offset + size) 之间。
	# WORLD_ORIGIN 例外：原样保留摆放，一律不重映射（坐标为负无妨，chunk 键支持负数）。
	if not raw_voxels.is_empty():
		var bounds := VoxelWorldUtil.voxel_bounds(raw_voxels)
		var min_pos: Vector3i = bounds["min"]
		var max_pos: Vector3i = bounds["max"]
		var base := Vector3i.ZERO if origin_mode == OriginMode.WORLD_ORIGIN else min_pos

		# 【按块聚合，不逐体素走写入原语】旧实现每一格调一次 _write_buffer_impl（_chunk_of +
		# 字典查 + 标待写盘 + 清伤害账 + 下标计算，约 4~5 次哈希）。同仓 .qvx 导入路径走的是
		# _install_block_buffer（**每块一次**），同一个模型两条导入路径成本差一个数量级。
		# 这里先按 chunk 归类局部下标与材质，再每块一次装满：逐体素成本降到一次字典取 + 一次 append。
		# 【为什么用 Array 归类比"就地往块缓冲里写"快】PackedInt32Array 是值语义（CoW）：
		# 字典里还持有它时写一格会触发整块 32³ 拷贝，那正是旧实现慢的真正原因。
		var per_chunk: Dictionary = {}
		for pos_key in raw_voxels.keys():
			var mat_id: int = int(raw_voxels[pos_key])
			if mat_id <= 0:
				continue  # 0 = 空，不该落进缓冲（旧路径由 _write_buffer_impl 的 mat_id <= 0 分支跳过）
			var pos: Vector3i = (pos_key as Vector3i) - base
			var ck := _chunk_of(pos)
			var bucket: Array = per_chunk.get(ck, [])
			bucket.append(_buf_index(pos - ck * CHUNK_SIZE))
			bucket.append(mat_id)
			per_chunk[ck] = bucket
		for ck: Vector3i in per_chunk:
			var buf := PackedInt32Array()
			buf.resize(CHUNK_VOLUME)
			var bucket: Array = per_chunk[ck]
			for i in range(0, bucket.size(), 2):
				buf[int(bucket[i])] = int(bucket[i + 1])
			res._install_block_buffer(ck, buf)
			# 旧路径靠 _write_buffer_impl 标待写盘；资源载荷的取舍（有生成器时只存改过的块）依赖它。
			res._dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)

		res.grid_size = max_pos - min_pos + Vector3i(1, 1, 1)
		# 体素已重映射到"内容最小角 = 0"，故把同一套公式作用在**相对**包围盒上。
		res.center_offset = VoxelWorldUtil.origin_offset({"min": Vector3i.ZERO, "max": max_pos - base}, origin_mode)
	else:
		# 空模型：VoxAsset 没有 `size` 属性（那是 VoxelModel 的），按零尺寸处理。
		res.grid_size = Vector3i.ZERO

	# 材质数组以**数组索引**为准（索引 i 即材质ID = 体素值），来源对象的 id 字段未设置也正确。
	# 索引 0 保留为空占位（材质ID 0 = 空），不复制。
	res.materials.resize(QVoxelSpec.MATERIAL_COUNT)
	for i in range(1, voxel_data.materials.size()):
		var src: VoxelMaterial = voxel_data.materials[i]
		if src == null:
			continue
		var new_mat := VoxelMaterial.new()
		new_mat.id = i
		new_mat.color = src.color
		new_mat.trans = src.trans
		new_mat.metal = src.metal
		new_mat.rough = src.rough
		new_mat.emission = src.emission
		res.materials[i] = new_mat

	# 渲染顶点 = (体素坐标 + center_offset) * voxel_scale。
	return res


# 核心存储原语（chunk 密集缓冲）

## 体素坐标 → chunk key（floori 向下取整，正确处理负坐标）
static func _chunk_of(pos: Vector3i) -> Vector3i:
	return VoxelChunk.chunk_of(pos)


## chunk 内局部坐标 → 缓冲下标（线性化：x + y*CS + z*CS²，覆盖 0..CHUNK_VOLUME-1）
static func _buf_index(local: Vector3i) -> int:
	return VoxelChunk.buf_index(local.x, local.y, local.z)


## 缓冲下标 → chunk 内局部坐标
static func _local_from_index(i: int) -> Vector3i:
	return VoxelChunk.local_from_index(i)


## 写入体素缓冲（核心原语）：不标记脏 chunk / 不触发信号，由调用方处理。
## check_empty=true 时，若写入后该 chunk 缓冲全空则移除 chunk 键（回收内存）。
## 【绝不预建空缓冲】写入的语义是"这一格归零 / 归一"，不是"这个 chunk 从此存在"。
## 从前无条件先建一块 4096 个 0 的缓冲再写，于是"往空格子里写 0 / 删一个不存在的体素"
## 会留下一块全零缓冲：`is_empty()`（见 :525 的不变式）与 `has_chunk()` 双双撒谎，
## flush 还会把这块空气写进磁盘；而 check_empty=false 的四个调用点（读档 / 旧格式反序列化 /
## .qvx 融合体素 / 单点 set）恰好都不做回收。故先读当前值：真的什么都不用变就直接返回。
func _write_buffer_impl(pos: Vector3i, mat_id: int, check_empty: bool) -> void:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null and is_stored(ck):
		# 流式：该 chunk 在磁盘已有数据，先载入内存再修改（保留旧数据）
		preload_chunk(ck)
		buf = _chunk_buffers.get(ck)
	var idx := _buf_index(pos - ck * CHUNK_SIZE)
	var cur := 0
	if buf != null:
		cur = buf[idx]
	if mat_id <= 0 and cur <= 0:
		# 本来就没有体素可删：不建缓冲，但仍要落两笔"这一格归零"的语义账 ——
		# 清伤害（残留伤害会继承给以后放进来的体素）与清"源作废"标记（内容已确定）。
		_source_invalidated.erase(ck)
		_damage.clear_at(pos)
		return
	if buf == null:
		buf = PackedInt32Array()
		buf.resize(CHUNK_VOLUME)
		_chunk_buffers[ck] = buf
	elif _snapshot_readers > 0:
		# 只读快照在途：该缓冲可能与 worker 共享底层，先分叉再写（GDScript 逐元素写不会 COW）。
		# 新建的缓冲只有自己持有，无需分叉。
		buf = (buf as PackedInt32Array).duplicate()
		_chunk_buffers[ck] = buf
	# 写入即内容确定 → 清除"源作废"标记
	_source_invalidated.erase(ck)
	# 标待写盘：内存已变更（若最终变空由 _maybe_erase_empty_chunk 清盘）。
	_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
	# 该位置被改写或移除 → 清零其累计伤害，否则残留伤害会"继承"给新体素（一放就被秒杀）
	_damage.clear_at(pos)
	if mat_id <= 0:
		buf[idx] = 0
		_count_delta(ck, -1)
		if check_empty:
			_maybe_erase_empty_chunk(ck)
	else:
		if cur <= 0:
			_count_delta(ck, 1)
		buf[idx] = mat_id


## 非空体素数（全项目唯一实现）：原生 count(0) 比 GDScript 逐元素循环快约 40 倍。
static func _count_voxels(buf: PackedInt32Array) -> int:
	return buf.size() - buf.count(0)


## 计数账本唯一的增量写入口：保证不变式"只含 > 0 条目"（归零即移除）。
func _count_delta(ck: Vector3i, delta: int) -> void:
	var v := int(_chunk_voxel_counts.get(ck, 0)) + delta
	if v > 0:
		_chunk_voxel_counts[ck] = v
	else:
		_chunk_voxel_counts.erase(ck)
	# 总数镜像与账本同步（v <= 0 时该块整体移出，等效于减去它原有的全部计数）
	_voxel_count_total += delta


## 计数账本唯一的覆盖写入口（装入整块缓冲时用；调用方保证该块此前未计数）
func _count_set(ck: Vector3i, n: int) -> void:
	_voxel_count_total += n - int(_chunk_voxel_counts.get(ck, 0))
	if n > 0:
		_chunk_voxel_counts[ck] = n
	else:
		_chunk_voxel_counts.erase(ck)


## 计数账本的**删除**入口（连总数镜像一起减）。
## 【为什么不允许直接 erase】每次 `_chunk_voxel_counts.erase(ck)` 都得同时减总数，
## 而总数又不能对整表求和来重算（那就退回 O(chunk) 了）—— 所以删除也必须走这里，
## 否则 get_voxel_count() 会带着已消失块的计数越跑越大。
func _count_erase(ck: Vector3i) -> void:
	_voxel_count_total -= int(_chunk_voxel_counts.get(ck, 0))
	_chunk_voxel_counts.erase(ck)


## 计数账本的**清空**入口（整份块表被替换 / clear() 时用，连总数镜像一起归零）。
func _count_clear() -> void:
	_voxel_count_total = 0
	_chunk_voxel_counts.clear()


## 直接装入一块密集缓冲（导入 / 资源载荷恢复专用）：不做逐体素写。
## 【唯一装块入口】"字典赋值 + 计数账 + 清作废标记"这三件事必须一起做，否则计数账漂移或
## 渲染层继续把该块当"暂时取不到"。preload_chunk / 回填 / 载荷恢复从前各抄一份，
## 收敛后它们只在这里调一次，各自特有的后续（邻居标脏 / 网格标脏 / 粗层失效）留在外层。
## [param known_count] 调用方刚刚数过这块的非空体素数时传进来（<0 = 本函数自己数）。
##   同一块 32³ 的 count(0) 是一次原生整块扫描，而导入 / 归一化路径往往**已经为判空数过一遍**，
##   再数一次纯属白扫（见 apply_block_table 的 known_counts 与 _install_volume）。
func _install_block_buffer(chunk_key: Vector3i, buf: PackedInt32Array, known_count: int = -1) -> void:
	if buf.size() != CHUNK_VOLUME:
		push_error("[QVoxelSource] 块 %s 的缓冲长度 %d != %d，已跳过" % [chunk_key, buf.size(), CHUNK_VOLUME])
		return
	_chunk_buffers[chunk_key] = buf
	_count_set(chunk_key, known_count if known_count >= 0 else _count_voxels(buf))
	_source_invalidated.erase(chunk_key)


## 用一份块表**替换**体素内容：`{Vector3i chunk_key: PackedInt32Array}`，缓冲长度须为 CHUNK_VOLUME。
## 返回实际改动的块数（0 = 新表与当前内容逐块相同）。逐帧动画切帧的唯一入口。
## 【为什么要"替换"这个语义】`_install_block_buffer` 只解决"塞一块进去"，不含"旧块要删掉"与
## "变了才标脏"；拆开做很容易漏掉一半 —— 漏删 → 上一帧的残留块永远留在场景里；
## 漏标脏 → 网格不重建，表现成"播放没生效"。
## 【为什么逐块比对而非全清再全装】FRAM 的价值就是**块级增量**，帧间未变的块占绝大多数。
## 比对走原生 PackedInt32Array 比较（memcmp 量级），相等就整块跳过，连 duplicate 都省掉；
## 于是切帧代价与"这一帧改了多少块"成正比，而非与模型体积成正比。
## 【为什么装入副本】本资源随后会就地改缓冲，而传入的块表常来自 `QVoxelAsset` 的**共享**帧数据
## —— 共享会互相污染（同一份 .qvx 的多个实例会串帧）。
func apply_block_table(blocks: Dictionary, notify: bool = true) -> int:
	return _apply_block_table_impl(blocks, {}, notify)


## apply_block_table 的本体。[param known_counts] 调用方已经数过某块的非空体素数时预先给出
## （`{chunk_key: count}`），归一化那一趟就不必再对同一块扫 32³ 一遍 —— 内部路径（_install_volume）
## 刚刚为判空数过，外面再数一次是纯浪费；公开入口传空字典即按需现数。
## 【为什么另开私有入口而不给公开方法加参数】公开面已经够宽，把"我已经数过了"这种实现细节
## 塞进签名会让每个调用点都得读一遍；内部复用走这里，公开契约保持原样。
func _apply_block_table_impl(blocks: Dictionary, known_counts: Dictionary, notify: bool) -> int:
	# 归一化：丢掉全空缓冲，维持 "is_empty() ⟺ 一个体素都没有" 的不变式。
	# 判空那一趟顺手把数出来的非空体素数记下来，装块时直接复用 —— 同一块 32³ 的 count(0)
	# 是原生整块扫描，装了再数一遍纯属重复劳动（见 _install_block_buffer 的 known_count）。
	var table := {}
	var counts := {}
	for ck: Vector3i in blocks:
		var b: PackedInt32Array = blocks[ck]
		if b.size() != CHUNK_VOLUME:
			push_error("[QVoxelSource] 块 %s 的缓冲长度 %d != %d，已跳过" % [ck, b.size(), CHUNK_VOLUME])
			continue
		var n := int(known_counts.get(ck, -1))
		if n < 0:
			n = _count_voxels(b)
		if n == 0:
			continue
		table[ck] = b
		counts[ck] = n

	var changed := 0
	# 1) 新表里没有的块 → 删掉。先收键再删（边遍历边 erase 是未定义行为）。
	var dropped: Array[Vector3i] = []
	for ck: Vector3i in _chunk_buffers:
		if not table.has(ck):
			dropped.append(ck)
	for ck in dropped:
		# 与 _maybe_erase_empty_chunk 同样的"真·空块"语义：内容已确定为空，渲染层该清掉旧网格
		# （而不是按"源作废"继续保留），且该块对应的粗层必须一起失效 —— 漏了这两笔，
		# 切帧删掉的块会永远停在"未就绪"：旧网格不清、新网格不建（A4）。
		_drop_chunk(ck, {
			"invalidate_source": false,
			"drop_lod": true,
			"mark_mesh": true,
			"mark_neighbors": true,
		})
		changed += 1
	# 2) 新表里的块 → 变了才装
	for ck: Vector3i in table:
		var buf: PackedInt32Array = table[ck]
		var cur: Variant = _chunk_buffers.get(ck)
		if cur != null and (cur as PackedInt32Array) == buf:
			continue
		# 整块换掉：旧缓冲不动（在途的只读快照仍持有它），字典指向新副本
		_install_block_buffer(ck, buf.duplicate(), int(counts[ck]))
		# 该块的体素已被整体换掉 → 累计伤害不再属于任何体素，留着会让新体素"一出现就带伤"
		_damage.erase_chunk(ck)
		# 内存已是权威内容 → 标待写盘（有流时否则卸载即丢，或旧数据复活）；并失效高层 LOD
		_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
		mark_chunk_dirty(ck)
		_mark_neighbors_dirty(ck)
		invalidate_lod_for_chunk(ck)
		changed += 1
	if changed > 0 and notify:
		emit_changed()
	return changed


## 丢掉一块 chunk 的内存副本，以及随之作废的那些附属账（**唯一实现**）。
## 【为什么必须收口】"删块"这件事本类有 4 个出处，它们清的东西**并不相同**，而且从前没有
## 一处写明为什么不同 —— 每加一个出处就靠作者自觉抄对，抄漏一笔没有运行期症状，只有画面错
## （A4 就是这么来的：丢块漏了清 `_source_invalidated`，渲染层于是永久把该块当"源作废、等回填"，
## 旧网格不清、新网格不建）。这里把差异显式化成 opts，4 个调用点各一行、读得出各自语义。
##
## 各 opts 键（缺键 = 不做）：
##   cancel_async: bool      撤销在途 / 就绪登记（否则迟到的回填会写进已丢弃的块）
##   invalidate_source: bool true = 置"源作废"标记（缓冲丢了但按流 > 生成器会重新取数，
##                               渲染层须保留旧网格防闪）；false = 清掉该标记（内容已确定为真·空）
##   drop_lod: bool          失效覆盖该块的所有更高层 LOD block（LOD0 换了粗层不换 = 远处旧形状）
##   erase_stream: bool      连流里的持久化数据一起删（世界该处确实空了；不是"等重新取数"）
##   mark_mesh: bool         标网格重建（不标 → 渲染器不会重建，旧网格留在屏幕上）
##   mark_neighbors: bool    标 6 邻居重建（跨界面的面可见性依赖该块，块消失 = 邻居外侧面要重算）
##   keep_persist_flag: bool 保留"待写盘"标记；缺省清掉（没有缓冲可写，留着只会让 flush 空转）
func _drop_chunk(ck: Vector3i, opts: Dictionary = {}) -> void:
	if opts.get("cancel_async", false):
		_async.cancel(ck, 0)
	_chunk_buffers.erase(ck)
	_count_erase(ck)
	_damage.erase_chunk(ck)
	if opts.has("invalidate_source"):
		if opts["invalidate_source"]:
			_source_invalidated[ck] = true
		else:
			_source_invalidated.erase(ck)
	if not opts.get("keep_persist_flag", false):
		_dirty.clear_flag(0, ck, VoxelDirtyLedger.PERSIST)
	if opts.get("drop_lod", false):
		invalidate_lod_for_chunk(ck)
	if opts.get("erase_stream", false) and is_stored(ck):
		stream.erase_chunk(ck)
	if opts.get("mark_mesh", false):
		_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
	if opts.get("mark_neighbors", false):
		_mark_neighbors_dirty(ck)


## 若 chunk 体素计数归零则移除该 chunk 键（O(1)，替代 4096 全量扫描）
## 语义：真·空块（确定无内容）—— 不属"源作废"，渲染层应清掉旧网格；流里的旧数据同步删掉。
## 不标 MESH 也不失效 LOD：调用方（单点写 / 批量删）已经把网格脏标记与粗层降采样标记过了，
## 这里重复标只会把同一批重建任务记两遍。
func _maybe_erase_empty_chunk(ck: Vector3i) -> void:
	if _chunk_voxel_counts.has(ck):
		return
	_drop_chunk(ck, {"invalidate_source": false, "erase_stream": true})


# 数据层磁盘流式（VoxelStream 接入）


## 无限世界：本数据层按 **origin shift** 供数（相机走远 → 整层坐标整体平移）。
## 必须显式声明而非"有节点就无限"：有界模型同样有节点但相对世界固定，平移原点会让它滑走。
## 无限与否是数据层的**用法**，由装配方声明（消费方见无限层）。
@export var infinite := false


## 数据层流式是否启用（有流可读/写，或有节点可求值）
func is_streaming() -> bool:
	return stream != null or node != null


## chunk 是否在内存中（有密集缓冲）。has_chunk 的严格子集（仅内存，不含存储）。
func is_chunk_loaded(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key)


## 该 chunk 是否**已存在流中**（纯存储事实，与"能否生成"无关）。直接问流既权威又 O(1)
## （键索引常驻内存）；曾用 _persisted_chunks 镜像，origin shift 一平移就与真实内容脱节。
func is_stored(chunk_key: Vector3i) -> bool:
	return stream != null and stream.has_chunk(chunk_key, 0)


## 【异步编排契约】该层数据是否**已存在流中**：派发前问的第一句（主线程同步、无 IO）。无流恒 false。
func has_stored_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	return stream != null and stream.has_chunk(chunk_key, lod)


## 【异步编排契约】同步读出该层数据（调用方须先 has_stored_chunk 判定）。
func load_stored_chunk(chunk_key: Vector3i, lod: int = 0) -> PackedInt32Array:
	return stream.load_chunk(chunk_key, lod) if stream != null else PackedInt32Array()


## 该 chunk 的数据能否取到：流里已存 或 本层造得出来。廉价、无 IO，供渲染器距离扫描用。
func can_supply_chunk(chunk_key: Vector3i) -> bool:
	if stream != null and stream.has_chunk(chunk_key, 0):
		return true
	return can_generate_chunk(chunk_key)


## 本层能否**造出**该 chunk 的数据（不含"存过"这一支）。派发侧统一问这一句，"造"的来源可多种。
## 【为什么单独一个虚函数】内核的造法是"求值节点 → 切出 chunk"（有界、O(1) 盒判定），而
## **无限世界**的造法是"按 key 确定性产出"（无节点、无整块体积）—— 内核不该认识扩展，但必须
## 能问出同一个问题。覆写时连带覆写 generate 与 get_vertical_half_span。
func can_generate_chunk(chunk_key: Vector3i, lod: int = 0) -> bool:
	return node != null and is_in_node_bounds(chunk_key, lod)


## 渲染器距离扫描的垂直半跨度（chunk 数）：节点存在时按输出盒高度算，否则 ±1 层。
func get_vertical_half_span() -> int:
	if node == null:
		return 1
	var gs := _base_grid_size()
	if gs == Vector3i.ZERO:
		return 1
	return maxi(VoxelChunk.chunk_of(gs - Vector3i.ONE).y, 1)


## 把 chunk 数据**同步**载入内存。已加载返回 true；取不到返回 false。
## 两条路分开处理（"存"与"造"分工的价值）：流里已存 → 同步直读（索引常驻内存，无需绕异步队列）；
## 只有生成器 → 交给异步（生成慢且会被成片调用，同步会卡死主线程；就绪后回填）。
func preload_chunk(chunk_key: Vector3i) -> bool:
	if _chunk_buffers.has(chunk_key):
		return true
	if is_stored(chunk_key):
		var buf := stream.load_chunk(chunk_key, 0)
		if buf.size() != CHUNK_VOLUME:
			# 索引说有、实际读不到（文件被外部改写等）→ 以读结果为准，顺手清掉
			stream.erase_chunk(chunk_key, 0)
			return false
		# 装块（字典 + 计数 + 清作废标记）走唯一入口；流已给出整块内容，这里顺手数一遍即可
		_install_block_buffer(chunk_key, buf)
		# halo 数据就绪 → 重建依赖该 chunk 作为 halo 的相邻 chunk（边界 mesh 缝合）
		_mark_neighbors_dirty(chunk_key)
		return true
	if node != null and is_in_node_bounds(chunk_key):
		_async.request(chunk_key, 0)
	return false


## 【内部】回填统一异步流式结果（后台生成 / 文件流读盘，主线程调用）。按 lod 分流：
## lod=0 存全精度 chunk，lod>=1 存粗层 32³ 大格。已存在则忽略。
## 内核外请用公开入口 apply_ready_results（poll + accept 的封装）。
func _accept_chunk_buffer(chunk_key: Vector3i, buf: PackedInt32Array, lod: int = 0) -> void:
	if lod == 0:
		if _chunk_buffers.has(chunk_key):
			return
		if buf.size() != CHUNK_VOLUME:
			return
		var count := _count_voxels(buf)
		# 【全 0 的缓冲没有任何信息量，不该存在】留着它会让 `has_chunk()` 撒谎：
		# 渲染器据此认为"这块还有内容"，于是既不清旧网格也不派发重建（空块本来就没网格可建），
		# 表现为"撤销 / 删除后画面上的体素还在"（实测踩到）。不装缓冲，`has_chunk` 才说真话。
		if count == 0:
			_source_invalidated.erase(chunk_key)
			_dirty.mark(0, chunk_key, VoxelDirtyLedger.MESH)
			_mark_neighbors_dirty(chunk_key)
			return
		# 装块走唯一入口：顺带清"源作废"标记（内容已回填，渲染层可安全按新内容重建）；
		# count 上面判空已经数过，直接传进去，不再白扫一遍 32³。
		_install_block_buffer(chunk_key, buf, count)
		# 数据就绪 → 标网格重建。未修改的粗层块用独立数据层，不依赖 LOD0 回填，故无需失效 ——
		# 否则每回填一个 chunk 就递增渲染器全局 gen_id，作废全部在途粗层任务。
		_dirty.mark(0, chunk_key, VoxelDirtyLedger.MESH)
		# halo 数据就绪 → 重建依赖它的相邻 LOD0 chunk（否则边界缺外侧面 → 横/竖/块状空洞）。
		_mark_neighbors_dirty(chunk_key)
		for lv in range(1, maxi(lod_count, 1)):
			var bk := Vector3i(chunk_key.x >> lv, chunk_key.y >> lv, chunk_key.z >> lv)
			if is_lod_block_modified(lv, bk):
				_mark_lod_invalid(bk, lv)
		return
	if has_lod_block(lod, chunk_key):
		return
	if buf.size() != LOD_GRID * LOD_GRID * LOD_GRID:
		return
	set_lod_block(lod, chunk_key, buf)
	# 数据就绪 → 标对应 block 网格重建。注意 key 落在 level 0 的 chunk 空间（与 is_chunk_mesh_dirty
	# 读同一张表）：粗层 block key 与 LOD0 chunk key 可能数值相同，会连带重建那个 chunk。
	_dirty.mark(0, chunk_key, VoxelDirtyLedger.MESH)


## 卸载 chunk：按需把内存数据写回磁盘（改过的写盘、变空的清盘、未改且磁盘已有的丢弃），
## 再释放内存缓冲。无 stream 时返回 false（不卸载，避免数据丢失）。
func unload_chunk(chunk_key: Vector3i) -> bool:
	if stream == null:
		return false
	if not _chunk_buffers.has(chunk_key):
		return false
	if _dirty.has(0, chunk_key, VoxelDirtyLedger.PERSIST):
		if _chunk_voxel_counts.has(chunk_key):
			stream.save_chunk(chunk_key, _chunk_buffers[chunk_key])
		elif is_stored(chunk_key):
			# 世界该处已清空 → 同步清掉存储里的旧数据，否则重载会出现"幽灵 chunk"
			stream.erase_chunk(chunk_key)
	# 写盘必须在 _drop_chunk **之前**：缓冲一丢就取不到内容了。
	# 其余一律不做：不置"源作废"（存储里已有权威数据，下次是直读回填而不是保留旧网格防闪）、
	# 不动粗层（粗层块有独立数据层，与本块内存副本无关）、不标脏（是否重建由调用方决定）；
	# 伤害账随块一起释放（_drop_chunk 内做），否则卸载后残留账目会随世界遍历无限增长。
	_drop_chunk(chunk_key, {"invalidate_source": false})
	return true


## 从流读取 chunk 数据（不缓存到内存，供全量序列化等一次性场景）
func _load_chunk_from_stream(chunk_key: Vector3i) -> PackedInt32Array:
	if stream == null:
		return PackedInt32Array()
	return stream.load_chunk(chunk_key)


## 获取内存中已加载的 chunk key 列表（流式卸载调度用）
func get_loaded_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
	return keys


## 【内部】内存中的 chunk 缓冲字典。**仅供原生批量接口直接读取**（C++ 侧按字典取缓冲，
## 省掉逐体素走 GDScript 字典查询）；不要持有引用、也不要就地改写，写入请走 set_voxel。
## 返回内部字典而非副本：这些调用点都是整世界量级读取，拷贝 32³×N 缓冲比绕过封装代价更大。
## 内核外调用者拿不到整表：粗层增量重算请走 patch_lod_block。
func _chunk_buffers_view() -> Dictionary:
	return _chunk_buffers


# 逐体素累计伤害账（体素相邻状态，随 chunk 生命周期同步）

## 【内部】累计伤害缓冲字典（chunk_key -> PackedFloat32Array(CHUNK_VOLUME)）。
## 与 _chunk_buffers_view 同样**仅供原生批量接口直接读写**。
func _damage_buffers_view() -> Dictionary:
	return _damage.buffers()


## 【内部】写回原生伤害内核修改过的伤害缓冲（契约同 remove_voxels_bulk 的 buffers 回写）。
func _set_damage_buffers(changed: Dictionary) -> void:
	_damage.write_back(changed)


## 取某 chunk 的伤害缓冲（不存在返回空数组）。
func get_damage(chunk_key: Vector3i) -> PackedFloat32Array:
	return _damage.get_chunk(chunk_key)


## 丢弃某 chunk 的伤害账（chunk 卸载 / 被清空时调用，防无界增长）。
func clear_damage(chunk_key: Vector3i) -> void:
	_damage.erase_chunk(chunk_key)


## 清零若干体素位置的累计伤害（体素被移除后调用）。
## positions 可为 Array[Vector3i]，也可为原生内核返回的 PackedVector3Array ——
## 两者都暴露 x/y/z，故按分量构造，避免依赖具体元素类型。
func clear_damage_bulk(positions: Variant) -> void:
	_damage.clear_at_bulk(positions)


## 清空全部伤害账（世界级重置用）。
func clear_all_damage() -> void:
	_damage.clear_all()


## 【内部】指定 LOD 层（level >= 1）的粗层大格数据字典（block_key → PackedInt32Array(LOD_GRID³)）。
## 与 _chunk_buffers_view 同样**仅供原生批量接口读取**；内核外的粗层重算走 patch_lod_block。
func _lod_buffers_view(level: int) -> Dictionary:
	var idx := level - 1
	if idx < 0 or idx >= _coarse_buffers.size():
		return {}
	return _coarse_buffers[idx]


# 只读快照生命周期（写时拷贝的"另一半"）

## 只读快照句柄 —— **所有权式**的快照生命周期。
## 【为什么不用裸计数 begin/end 配对】裸计数下任何一条提前返回路径漏掉 end，计数就永久 >0，
## 此后每次单点写都分叉整块 32³ 缓冲 —— 静默的性能塌陷且外部无从察觉（曾真实发生）。
## 改为句柄后"谁持有谁释放"由引用关系表达，句柄被回收时还有 PREDELETE 兜底。
## 【为什么是句柄而非 bool】粗层降采样与渲染批次可并发持有多个快照，裸计数无法区分该释放哪个。
class ReadonlySnapshot extends RefCounted:
	var _data: QVoxelSource = null
	var _released := false

	func _init(d: QVoxelSource) -> void:
		_data = d

	## 释放快照（幂等）。调用后不得再使用本句柄。
	func release() -> void:
		if _released:
			return
		_released = true
		var d := _data
		_data = null
		# QVoxelSource 可能已先被释放（资源换世界/退出）：此时没有账可还，直接返回。
		if d != null and is_instance_valid(d):
			d._on_snapshot_released(self)

	## 泄漏兜底：句柄被 GC 而从未 release 时也把计数还回去，否则一次漏释放就让写路径**永久**分叉。
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and not _released:
			release()


## 声明"缓冲即将交给后台线程只读"。返回的句柄负责释放（可并发多批）。
## 实测 GDScript 对 PackedInt32Array 的逐元素写不触发写时拷贝，故浅拷贝快照并不安全：
## 快照活跃期内单点写必须先分叉（见 _write_buffer_impl）。选写侧守卫而非读侧脱钩，是因为后者
## 要按快照集深拷贝（约 27MB/批），写侧只在真的写时付一次（实测约 5µs/次）。
func begin_readonly_snapshot() -> ReadonlySnapshot:
	_snapshot_readers += 1
	var handle := ReadonlySnapshot.new(self)
	_live_snapshots[handle] = true
	return handle


## 句柄释放回调（由 ReadonlySnapshot.release 调用；幂等性由句柄自身的 _released 保证）。
func _on_snapshot_released(handle: ReadonlySnapshot) -> void:
	if _live_snapshots.erase(handle):
		_snapshot_readers = maxi(_snapshot_readers - 1, 0)


## 【兼容入口】释放最近一次 begin 的句柄。仅在"begin/end 严格配对"时语义正确（本类内部与
## 渲染器的粗层任务恰好如此）；每个句柄至多释放一次，故 LIFO 释放了"另一个"聚合计数依然正确。
## 新的可并发调用点请直接使用 begin 返回的句柄。
func end_readonly_snapshot() -> void:
	if _live_snapshots.is_empty():
		return
	var handles := _live_snapshots.keys()
	(handles[handles.size() - 1] as ReadonlySnapshot).release()


## 强制回收全部存活快照（clear / 载荷重建等**世界级重置**专用）。
## 只断链不改缓冲：调用方必须已保证此刻没有 worker 在读这些缓冲
## （渲染器先取消其批次，再调用 data.clear()，见 VoxelRenderer._cancel_async）。
## 不这么做的话，一个泄漏的句柄会让 _snapshot_readers 永久 >0，
## 于是此后**每一次**单点写都要复制一整块 32³ 缓冲。
func _force_release_snapshots() -> void:
	for h in _live_snapshots.keys():
		(h as ReadonlySnapshot)._released = true
	_live_snapshots.clear()
	_snapshot_readers = 0


# 取数在途查询 / 取消（账本在 VoxelAsyncLoader；查询走 is_chunk_pending）

## 撤销该 chunk/block 的在途 / 就绪登记（流式卸载用：迟到的回填会因登记已撤销而被丢弃）。
func cancel_chunk_request(chunk_key: Vector3i, lod: int = 0) -> void:
	_async.cancel(chunk_key, lod)


## 某层全部**在途（未就绪）**的取数 key（流式卸载时批量取消用）。
func get_unready_chunk_keys(lod: int = 0) -> Array:
	return _async.get_unready_keys(lod)


## 获取流中已存但不在内存的 chunk key 列表（流式补建调度用）
func get_unloaded_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if stream == null:
		return keys
	for ck in stream.get_all_chunk_keys(0):
		if not _chunk_buffers.has(ck):
			keys.append(ck)
	return keys


## 流中已存但不在内存的 chunk 数量。**不构造数组**，供 HUD 等每帧读取者使用。
## 算法 = 流中总数 − 内存里"流中也有"的那些（只遍历已加载的小集合，has_chunk 是 O(1)）。
func get_unloaded_chunk_count() -> int:
	if stream == null:
		return 0
	var n := stream.get_chunk_count(0)
	for ck in _chunk_buffers:
		if stream.has_chunk(ck, 0):
			n -= 1
	return n


## 当前 chunk 总数 = 内存里已加载的块 + 流里还没加载的块（**O(1) 辅助量，不合并、不去重**）。
## 【为什么需要它】渲染器 / HUD 只想报一个"世界有多少块"的数字，从前写
## `get_all_chunk_keys().size()` —— 那是把内存键与流键合表再数组去重，纯诊断数字付一次全表合并。
## 这里直接复用已有的两笔 O(1) 账（_chunk_buffers.size() 与 get_unloaded_chunk_count），
## 二者互斥（前者是内存块，后者是流中不在内存的块），相加即不重不漏。
func chunk_count() -> int:
	return _chunk_buffers.size() + get_unloaded_chunk_count()


## 把内存中所有被修改的 chunk 写回磁盘（存档 / 退出前调用）
func flush() -> void:
	if stream == null:
		return
	# QVX 流：先注入材质调色板，使 .qvx 自带 MATE（文件自包含，P2 每条事实只存一次）
	var qs := stream as QVoxelStream
	if qs != null:
		qs.set_materials(materials)
	for ck in _dirty.keys(0, VoxelDirtyLedger.PERSIST):
		var buf: PackedInt32Array = _chunk_buffers.get(ck)
		if buf == null:
			_dirty.clear_flag(0, ck, VoxelDirtyLedger.PERSIST)
			continue
		if _chunk_voxel_counts.has(ck):
			stream.save_chunk(ck, buf)
		elif is_stored(ck):
			stream.erase_chunk(ck)
	_dirty.clear_flags(0, VoxelDirtyLedger.PERSIST)
	stream.flush()



## 由一份**整块求值结果**装配一个数据源：装体积 + 装调色板 + 标脏，一次做完。
## 【用途】把"整世界 / 整节点求值完"的结果当成**静态资产**渲染：快照、离线出图，等等。
## 【为什么必须收成一条入口】拆成三个 API 让调用方自己拼迟早漏掉第三件：漏了标脏 →
## 渲染器的重建粒度就是"数据层给的脏账"，脏账空 = 一块网格都不建，表现为**画面全空且不报错**。
## 【为什么不做成逐格入口】逐格写 256³ 就是 1600 万次字典写入 + 逐格分派，
## 而这里的数据本来就是**按块连续**的。
static func from_eval_result(world: QVoxelWorld, res: QVoxelEvalResult) -> QVoxelSource:
	var src := QVoxelSource.new()
	if res == null or res.volume.is_empty():
		return src
	# 调色板：索引 0 恒为空气占位，故从 1 开始；MATE 条目 → 材质的解释复用唯一的 from_mate。
	if world != null:
		for i in range(1, world.materials.size()):
			src.add_material(VoxelMaterial.from_mate(world.materials[i], i))
	# 顺序不能反：grid_size 的 setter 会作废求值体积缓存（旧体积的下标布局就错了）。
	src.grid_size = res.grid_size
	src._install_volume(res.volume, res.origin, res.grid_size)
	return src


## 把一整块已求值的体积切进 chunk 缓冲（`from_eval_result` 的第二段）。
## 切块必须走 _generate_chunk："体积下标 → chunk 缓冲"的换算在数据层只有那一处实现，
## 重写一遍迟早分叉，表现是"快照少了一角"且不报错。
## 装入必须走 apply_block_table：脏标记 / 邻居标记 / LOD 失效 / 变更信号都在那个唯一入口里。
func _install_volume(volume: PackedInt32Array, origin: Vector3i, size: Vector3i) -> void:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return
	if volume.size() < size.x * size.y * size.z:
		push_error("[QVoxelSource] 体积长度 %d 与尺寸 %s 不符，已跳过" % [volume.size(), size])
		return
	# 让 LOD0 的唯一切块实现直接读到它（_ensure_volume 见 _volume_built 即返回，不会二次求值）。
	_reset_volume_cache()
	_volume = volume
	_volume_origin = origin
	_volume_grid_size = size
	_volume_built = true
	var table := {}
	# 判空时数出来的计数一并带下去：同一块 32³ 的 count(0) 不必在归一化里再扫一遍
	var counts := {}
	var first := VoxelChunk.chunk_of(origin)
	var last := VoxelChunk.chunk_of(origin + size - Vector3i.ONE)
	for cz in range(first.z, last.z + 1):
		for cy in range(first.y, last.y + 1):
			for cx in range(first.x, last.x + 1):
				var ck := Vector3i(cx, cy, cz)
				var buf := _generate_chunk(ck)
				var n := _count_voxels(buf)
				if n == 0:
					continue
				table[ck] = buf
				counts[ck] = n
	_apply_block_table_impl(table, counts, true)


## 获取所有有数据的 chunk key（内存 + 流中已存的）
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var seen := {}
	for ck: Vector3i in _chunk_buffers:
		keys.append(ck)
		seen[ck] = true
	if stream != null:
		for ck in stream.get_all_chunk_keys(0):
			if not seen.has(ck):
				keys.append(ck)
				seen[ck] = true
	return keys


## 平移所有 chunk key（origin shift）：相机远离时调用，使相机附近 chunk 回到小坐标，
## 避免 float 精度损失。offset = 平移的 chunk 数。
func shift_origin(offset: Vector3i) -> void:
	if offset == Vector3i.ZERO:
		return
	_chunk_buffers = VoxelChunk.shift_key_dict(_chunk_buffers, offset)
	_chunk_voxel_counts = VoxelChunk.shift_key_dict(_chunk_voxel_counts, offset)
	_source_invalidated = VoxelChunk.shift_key_dict(_source_invalidated, offset)
	# 脏账本各层一起平移：漏平移会让它与数据基准脱节（残留旧坐标条目）。
	_dirty.shift(offset)
	# 伤害账同样以 chunk 为键，漏平移会让它与数据基准脱节（残留旧坐标条目）
	_damage.shift(offset)
	for i in _coarse_buffers.size():
		_coarse_buffers[i] = VoxelChunk.shift_key_dict(_coarse_buffers[i], offset)
	# 在途 / 就绪登记的 key 同样要平移，否则回填会写到旧坐标（数据落在错误的 chunk 上）；
	# 节点自身坐标由 node 负责平移。
	_async.shift_keys(offset)



## 【内部】chunk 的 34³ 密集"光环缓冲"（覆盖内部 + 1 体素外缘），供子线程只读使用。
## 流式下先确保 chunk 及其 27 邻居已加载（跨界面的面可见性需要邻居）。
func _chunk_halo(chunk: Vector3i) -> PackedInt32Array:
	if stream != null:
		for nz in 3:
			for ny in 3:
				for nx in 3:
					preload_chunk(chunk + Vector3i(nx - HALO, ny - HALO, nz - HALO))
	return VoxelChunkGenerator.build_halo_from_buffers(_chunk_buffers, chunk)


## 【内部】生成"受影响区域"的 chunk 缓冲快照（chunk key → PackedInt32Array 独立副本）。
## 只快照 rebuild_chunks 及其 27 邻居（构建 halo 需要），避免整世界深拷贝；主线程一次性调用，
## 随后供各 worker 从快照构建自己的 halo（线程安全只读）。流式下先把相关 chunk 从磁盘载入内存。
## 快照由原生 C++ 完成：COW 共享 PackedInt32Array（worker 只读，主线程写时触发拷贝），
## 省去逐 chunk 64KB 深拷贝。
func _snapshot_chunks_halo(rebuild_chunks: Array[Vector3i]) -> Dictionary:
	if stream != null:
		# 【先去重再预载】相邻 chunk 的 3×3×3 邻域大面积重叠：一次派发 4 个 chunk 时旧写法会对同一个
		# 邻居反复调 preload_chunk（4×27=108 次调用里真正不同的通常不到 40 个），而其中没在内存的
		# 每一次都是**主线程同步读盘**。先收进集合，同步 IO 次数直接按"缺几个"付，而不是按"问几次"付。
		var wanted := {}
		for ck in rebuild_chunks:
			for nz in 3:
				for ny in 3:
					for nx in 3:
						wanted[ck + Vector3i(nx - HALO, ny - HALO, nz - HALO)] = true
		for nk: Vector3i in wanted:
			if not _chunk_buffers.has(nk):
				preload_chunk(nk)
	return NativeLoader.snapshot_chunks_halo(_chunk_buffers, rebuild_chunks)


## 【内部】LOD 大块（LOD_GRID³ 大格，覆盖 2^lod³ 个 chunk）异步生成快照：大块自身 chunk +
## 外扩 ±2^lod 层 chunk（halo 边界大格降采样需要），COW 共享。
## 仅 preload 大块自身的 chunk，外扩部分只从内存快照（不 preload 磁盘）。
func _snapshot_lod_block_chunks(block_key: Vector3i, lod: int) -> Dictionary:
	return _snapshot_lod_block_chunks_impl(block_key, lod, true)


## 【内部】纯只读 halo 快照：不 preload / 不写状态，仅快照 _chunk_buffers 中已存在的数据
## （缺失 chunk 视为空）。外扩 ±2^lod 层收集 halo 邻居：缺边界邻居数据则 block 边界缺面 → 空洞。
## 调用方在**主线程**构造好后交给 worker 只读。
func _snapshot_lod_block_chunks_readonly(block_key: Vector3i, lod: int) -> Dictionary:
	return _snapshot_lod_block_chunks_impl(block_key, lod, false)


## 上面两个入口的**共同实现**（收敛前是逐行复制的两份，只差一处 preload 与一处 has 判断）。
## 两个公开的 `_` 入口名都保留：契约测试 VOXEL_DATA_INTERNAL_PROTOCOLS 钉着它们。
##
## [param preload_center] = true  → 中心 chunk 一律 preload 并无条件纳入快照（异步生成路径：
##     数据必须先就位，哪怕磁盘上还没有，也由原生快照按缺失=空处理）；
##                                  false → 只纳入**已在内存**的 chunk（只读路径：worker 侧
##     绝不允许触发 IO 或改状态，否则就是主线程之外的写入）。
## halo 外扩区两种模式都只看内存（外扩只为补边界大格，不值得为它拉磁盘）。
func _snapshot_lod_block_chunks_impl(block_key: Vector3i, lod: int, preload_center: bool) -> Dictionary:
	var chunks_per_axis := 1 << lod
	var cks: Array[Vector3i] = []
	var seen := {}
	var base := block_key * chunks_per_axis
	for cz in chunks_per_axis:
		for cy in chunks_per_axis:
			for cx in chunks_per_axis:
				var ck := base + Vector3i(cx, cy, cz)
				if preload_center:
					preload_chunk(ck)
					seen[ck] = true
					cks.append(ck)
				elif _chunk_buffers.has(ck):
					seen[ck] = true
					cks.append(ck)
	for oz in range(-chunks_per_axis, 3 * chunks_per_axis):
		for oy in range(-chunks_per_axis, 3 * chunks_per_axis):
			for ox in range(-chunks_per_axis, 3 * chunks_per_axis):
				var ck := base + Vector3i(ox, oy, oz)
				if not seen.has(ck) and _chunk_buffers.has(ck):
					seen[ck] = true
					cks.append(ck)
	return NativeLoader.snapshot_chunks_halo(_chunk_buffers, cks)


# 每 LOD 独立数据层（Voxel Tools 式：粗 LOD block 数据独立，未修改块由生成器直接生成）

func _ensure_coarse_arrays(level: int) -> void:
	VoxelWorldUtil.ensure_layer(_coarse_buffers, level - 1)
	_dirty.ensure_level(level)


## 取指定 LOD 的数据块（level 0 = LOD0 chunk；>=1 = 粗层 32³ 大格数据）。无则返回空数组。
func get_lod_block(level: int, key: Vector3i) -> PackedInt32Array:
	if level == 0:
		return _chunk_buffers.get(key, PackedInt32Array())
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return PackedInt32Array()
	return _coarse_buffers[idx].get(key, PackedInt32Array())


func has_lod_block(level: int, key: Vector3i) -> bool:
	if level == 0:
		return _chunk_buffers.has(key)
	var idx := level - 1
	return idx < _coarse_buffers.size() and _coarse_buffers[idx].has(key)


func set_lod_block(level: int, key: Vector3i, buf: PackedInt32Array) -> void:
	if level == 0:
		_chunk_buffers[key] = buf
		_mark_neighbors_dirty(key)
		return
	_ensure_coarse_arrays(level)
	_coarse_buffers[level - 1][key] = buf
	# 数据已同步（全量降采样或增量 patch）→ 清 modified，worker 据此从 coarse 直接生成 mesh，
	# 不再全量从 L0 降采样覆盖。
	_dirty.clear_flag(level, key, VoxelDirtyLedger.COARSE_MODIFIED)


## 粗层降采样结果落地（**唯一入口**）：写入内存权威 + 按需持久化。
## 【为什么归数据层】"下来源是否支持 LOD 层 / 何时该落盘"这条规则此前散在三处（本类的降采样
## 回填 + 渲染器的两个结果回调），且渲染器为了落盘直接伸手拿 `data.stream` 绕过数据层。
## 现在渲染器只报告"降采样结果就绪"，落盘判断与写入统一由本层负责。
func store_lod_block(level: int, block_key: Vector3i, buf: PackedInt32Array) -> void:
	if buf.is_empty():
		return
	set_lod_block(level, block_key, buf)
	if stream != null and stream.supports_lod_layer():
		stream.save_chunk(block_key, buf, level)


## 擦除一个 LOD block 的**数据**，并同步清掉只对"该块数据"才有意义的附属账本。
## 【为什么必须一起清】COARSE_MODIFIED / 脏大格区域都以 block key 为键，块数据擦除后不会自动
## 消失 → 随探索 / 编辑**无界增长**；更隐蔽的是残留 `modified=true` 会让
## `_can_mesh_lod_block_standalone()` 永久返回 false，使该 block 永远只能走全量 LOD0 降采样。
## 【为什么清 modified 是安全的】粗层数据的**唯一**生产者是 `_start_lod_downsample`（严格从
## LOD0 缓冲降采样），不存在"纯生成器输出粗层"的写入路径；块既已擦除，标记没有指代对象。
## 【为什么不连 LOD_MESH 一起清】它是"网格重建"账，块擦除后仍有在途网格任务要收尾，
## 由 get_invalidated_lod 消费时自清。
func erase_lod_block(level: int, key: Vector3i) -> void:
	if level == 0:
		_chunk_buffers.erase(key)
		return
	var idx := level - 1
	if idx < _coarse_buffers.size():
		_coarse_buffers[idx].erase(key)
	_dirty.clear_flag(level, key, VoxelDirtyLedger.COARSE_MODIFIED)
	_dirty.erase_region(level, key)


## 指定 LOD 层的所有数据块 key
func get_lod_block_keys(level: int) -> Array:
	if level == 0:
		return _chunk_buffers.keys()
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return []
	return _coarse_buffers[idx].keys()


## 修改过的粗层 block 写盘（stream 记录修改），再释放内存（卸载时调用）
func flush_lod_block(level: int, key: Vector3i) -> void:
	var buf := get_lod_block(level, key)
	var s := stream
	if s != null and buf.size() > 0:
		s.save_chunk(key, buf, level)
	erase_lod_block(level, key)


## 该粗层 block 是否被编辑过（需降采样合并 LOD0 数据，而非纯生成器输出）
func is_lod_block_modified(level: int, key: Vector3i) -> bool:
	return _dirty.has(level, key, VoxelDirtyLedger.COARSE_MODIFIED)


## 【金字塔增量】重算该粗层 block 的脏大格并就地更新其数据（消费脏区域）。
## level==1 从 LOD0 chunk 降采样；level>=2 从上一层粗层降采样（省 64 倍 LOD0 读取）。
## 返回 true = 确实 patch 了（调用方随后应重建该 block 的 mesh）；false = 无脏区域或 block 不存在。
## 【为何收进数据层】源缓冲（_chunk_buffers / _coarse_buffers）是内部存储，内核外不该拿整表；
## 把"取源 → 重算 → 写回"绑成一个动作，无限层不再触碰 get_chunk_buffers / get_lod_buffers。
func patch_lod_block(level: int, block_key: Vector3i) -> bool:
	if level < 1:
		return false
	var region := get_lod_dirty_region(level, block_key)
	if region.is_empty() or not has_lod_block(level, block_key):
		return false
	var coarse := get_lod_block(level, block_key)
	var patched: PackedInt32Array
	if level == 1:
		patched = VoxelChunkGenerator.patch_lod_block(
			_chunk_buffers, block_key, level, coarse, region[0], region[1])
	else:
		patched = VoxelChunkGenerator.patch_lod_block_from_lod(
			_lod_buffers_view(level - 1), block_key, level, coarse, region[0], region[1])
	set_lod_block(level, block_key, patched)
	return true


## 【内部】该粗层 block 能否**只靠自身与 6 邻居的大格数据**网格化（无需回退 LOD0 降采样）。
## 供渲染器在派发 worker 前判定数据来源，从而把快照构造留在主线程（线程安全）。
func _can_mesh_lod_block_standalone(level: int, key: Vector3i) -> bool:
	if is_lod_block_modified(level, key) or not has_lod_block(level, key):
		return false
	for d in NEIGHBORS_6:
		if not has_lod_block(level, key + d):
			return false
	return true


# ── 粗层快照的公开面（供 VoxelViewLayer 的 LOD 调度使用）────────────────────
#
# 【为什么需要这三个方法】粗层 mesh 的生成必须**在主线程造好只读快照**再交给 worker
# （快照是 COW 共享的深拷贝，worker 只读它，绝不触碰 QVoxelSource 的活动字典）。
# 这三件事只能在数据层内部做（要摸 `_chunk_buffers` / `_coarse_buffers`），但调用方是
# 视点层的 LOD 调度 —— 它是一个独立的 Node 组件，不该读数据层的私有成员。
# 故开三个薄壳转发：签名与语义完全等同原私有方法，**只是把"谁可以调"从"同类内部"放宽到公开**。
# 原私有方法保留（内部仍在使用，且测试 oracle 依赖）。

## 该粗层 block 能否只靠自身与 6 邻居大格数据网格化（决定快照走哪条路径）。
func can_mesh_lod_block_standalone(level: int, block_key: Vector3i) -> bool:
	return _can_mesh_lod_block_standalone(level, block_key)


## 粗层独立数据快照（block 自身 + 27 邻居大格，COW 共享）。**必须在主线程调用**。
## 返回空字典表示该层粗层缓存里没有这块数据（调用方应回退 LOD0 降采样路径）。
func read_lod_block_data_snapshot(block_key: Vector3i, level: int) -> Dictionary:
	return _snapshot_lod_block_data(block_key, level)


## LOD0 chunk 缓冲的 halo 快照（降采样路径用）。**必须在主线程调用**。
## [param readonly] true = 纯只读（不 preload / 不写状态，缺失 chunk 视为空）；
##   false = 会 preload 大块自身的 chunk（慢，但磁盘流下能拿到更多数据）。
func read_lod_block_chunk_snapshot(block_key: Vector3i, level: int, readonly: bool = true) -> Dictionary:
	if readonly:
		return _snapshot_lod_block_chunks_readonly(block_key, level)
	return _snapshot_lod_block_chunks(block_key, level)


## 请求异步生成/加载 chunk/block 数据（后台线程：程序化走生成器，文件流走 region 读盘）。
## 统一带 lod 参数（0 = LOD0 chunk，>=1 = 粗层 block）。数据就绪后经 poll_all_ready 回填。
func request_chunk_async(chunk_key: Vector3i, lod: int = 0) -> void:
	if has_lod_block(lod, chunk_key):
		return
	# 统一编排：流里已存（含 QVX 的粗层 CACH 缓存）→ 主线程直读；否则生成器可生成 → 后台生成。
	_async.request(chunk_key, lod)
	# 粗层再兜底：两个数据源都没有（如纯文件流且没存过粗层缓存）→ 从 LOD0 降采样得到。
	# 粗层本就是 LOD0 的派生数据，降采样是最保底的来源（结果同样落 CACH 缓存）。
	if lod >= 1 and not has_lod_block(lod, chunk_key) and not _async.is_pending(chunk_key, lod):
		_start_lod_downsample(chunk_key, lod)


## 文件流粗层降采样：快照在主线程构造（preload 磁盘回读 + 内存读取）。在途去重交给编排器；
## 快照构造前声明只读快照，使主线程其间的单点写先分叉（否则 worker 可能读到被改过的缓冲）。
func _start_lod_downsample(block_key: Vector3i, lod: int) -> void:
	if not _async.begin_derived(block_key, lod):
		return
	# 句柄随任务走到底、由回填方释放：不依赖"另一个调用点的 end"配对，与渲染批次并发也不会释放错。
	var snapshot := begin_readonly_snapshot()
	var cell := 1 << lod
	var chunks_per_block := (VoxelChunkGenerator.LOD_BLOCK_SIZE * cell) / VoxelChunk.CHUNK_SIZE
	var base_chunk := block_key * chunks_per_block
	var buffers := {}
	for cz in chunks_per_block:
		for cy in chunks_per_block:
			for cx in chunks_per_block:
				var ck := base_chunk + Vector3i(cx, cy, cz)
				if not _chunk_buffers.has(ck):
					preload_chunk(ck)
				if _chunk_buffers.has(ck):
					buffers[ck] = _chunk_buffers[ck]
	if buffers.is_empty():
		call_deferred("_on_lod_downsample_ready", block_key, lod, PackedInt32Array(), snapshot)
		return
	WorkerThreadPool.add_task(_lod_downsample_worker.bind(block_key, lod, buffers, snapshot))


## 后台线程：从 LOD0 chunk 降采样生成粗层 block（32³ 大格，每格 = 2^lod 体素）。buffers 为
## 主线程只读快照；结果经 call_deferred 回主线程，snapshot 句柄随参数带过去保证释放方唯一。
func _lod_downsample_worker(block_key: Vector3i, lod: int, buffers: Dictionary,
		snapshot: ReadonlySnapshot) -> void:
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(buffers, block_key, lod)
	# 【必须防空 halo】`buffers` 非空只代表**整块区域里有些 chunk**，不代表本 block 的
	# 3×3×3 halo 覆盖范围内有足够数据 —— 边界 block（区域边缘 / 半加载状态）会返回空 halo。
	# 直接交给 extract_center_from_halo 会越界崩溃（实测 1191 > 0）。空 halo 是正常情况
	# （数据还没到），按空结果回报，由上层走重试计数即可。
	if halo.size() != VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		call_deferred("_on_lod_downsample_ready", block_key, lod, PackedInt32Array(), snapshot)
		return
	var buf := VoxelChunk.extract_center_from_halo(halo)
	call_deferred("_on_lod_downsample_ready", block_key, lod, buf, snapshot)


## 主线程：粗层降采样完成 → 缓存 _coarse_buffers + 持久化文件流（重启保留），供渲染器复用
func _on_lod_downsample_ready(block_key: Vector3i, lod: int, buf: PackedInt32Array,
		snapshot: ReadonlySnapshot) -> void:
	snapshot.release()
	if buf.is_empty():
		# LOD0 可能尚未加载（粗层 request 早于 LOD0 就绪）→ 结束在途登记但保留重试计数。
		_async.end_derived(block_key, lod, true)
		_retry_lod_downsample(block_key, lod)
		return
	_async.end_derived(block_key, lod)
	store_lod_block(lod, block_key, buf)


## 粗层降采样空结果延迟重试：LOD0 常晚于粗层 request 就绪（流式加载），延迟 0.5s 跨帧重试；
## 上限防空区域死循环。重试计数由编排器持有（账本唯一）。
func _retry_lod_downsample(block_key: Vector3i, lod: int) -> void:
	if not _async.note_derived_retry(block_key, lod):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(0.5).timeout.connect(
			func() -> void: _start_lod_downsample(block_key, lod))
	else:
		_start_lod_downsample(block_key, lod)


## 该 chunk/block 是否已有后台任务进行中或结果就绪（渲染器每帧预算限流用，避免重复提交）。
func is_chunk_pending(chunk_key: Vector3i, lod: int = 0) -> bool:
	if has_lod_block(lod, chunk_key):
		return true
	if _async.is_pending(chunk_key, lod):
		return true
	# 粗层降采样任务进行中（防重复降采样；账本在编排器）
	if lod >= 1 and _async.is_derived(chunk_key, lod):
		return true
	return false


## 【内部】粗 LOD 数据块快照（block 自身 + 27 邻居大格，COW 共享）：供独立数据层网格生成 worker 使用。
func _snapshot_lod_block_data(block_key: Vector3i, level: int) -> Dictionary:
	var out := {}
	var idx := level - 1
	if idx >= _coarse_buffers.size():
		return out
	var cb: Dictionary = _coarse_buffers[idx]
	for nz in 3:
		for ny in 3:
			for nx in 3:
				var bk := block_key + Vector3i(nx - 1, ny - 1, nz - 1)
				if cb.has(bk):
					out[bk] = cb[bk]
	return out


## 主线程批量取回异步就绪的 chunk/block 数据。返回 [[lod, key, PackedInt32Array], ...]。
func poll_all_ready(max_count: int) -> Array:
	return _async.poll_ready(max_count)


## 主线程批量取回异步结果并**直接回填**（poll + accept 的封装），返回回填条数。
## 这是内核外驱动数据供给的**唯一公开入口**：缓冲校验 / 体素计数 / 网格脏标记 / 粗层失效
## 全在数据层内部完成，调用方不必持有 accept 那一半协议。
func apply_ready_results(max_count: int) -> int:
	var applied := 0
	for r in _async.poll_ready(max_count):
		_accept_chunk_buffer(r[1], r[2], r[0])
		applied += 1
	return applied


# 基本访问

## 内部迭代统一入口：遍历所有内存中的非空体素，调用 cb(pos, mat_id)。
## 目前只有 get_voxels_dict_snapshot 用它（要建字典，原生没有对应返回形态）。
## 【为什么不是所有遍历都走它】get_positions / get_voxels_aabb / 序列化都有原生整块快路
## （collect_all_positions / collect_bounds / collect_all_flat），逐体素 GDScript 回调在
## 百万级体素上慢一个数量级；非热路径才用本函数，回调开销可接受。
func _for_each_non_empty_voxel(cb: Callable) -> void:
	for ck: Vector3i in _chunk_buffers:
		var buf = _chunk_buffers[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				cb.call(origin + _local_from_index(i), buf[i])


## "内存 + 流里已存但未加载"这份合并逻辑的**流那一半**：遍历只在磁盘上、不在内存的 chunk，
## 对每块的非空体素调用 cb(pos, mat_id)。
## 【为什么要抽】这段"建 seen 集合 → 扫 stream 全部 key → 跳过已加载 → 临时读盘 → 逐体素回调"
## 原本在 get_voxels_dict_snapshot / get_positions / _serialize_all_voxels 里各写一遍，
## 任一处忘了跳过已加载的块（就会把内存里改过的旧值用磁盘值覆盖）或忘了跳过空块，
## 都会表现成"改了却读到旧数据"。**内存那一半刻意不统一**：get_positions 走原生
## collect_all_positions 快路（逐体素 GDScript 装箱慢一个数量级），其余走 _for_each_non_empty_voxel，
## 强行合并会把快路退化掉。
## 临时读盘**不写回 _chunk_buffers**（不污染缓存驻留集合）。
func _for_each_stream_only_chunk(cb: Callable) -> void:
	if stream == null:
		return
	var loaded := {}
	for ck: Vector3i in _chunk_buffers:
		loaded[ck] = true
	for ck in stream.get_all_chunk_keys(0):
		if loaded.has(ck):
			continue
		var buf := _load_chunk_from_stream(ck)
		if buf.is_empty():
			continue
		cb.call(ck, buf)


func get_voxels_dict_snapshot() -> Dictionary[Vector3i, int]:
	var out: Dictionary[Vector3i, int] = {}
	_for_each_non_empty_voxel(func(pos: Vector3i, mat_id: int): out[pos] = mat_id)
	_for_each_stream_only_chunk(func(ck: Vector3i, buf: PackedInt32Array):
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out[origin + _local_from_index(i)] = buf[i])
	return out


## 获取指定位置的体素材质ID，不存在返回 -1
## 流式模式下若该 chunk 在磁盘上有数据则自动载入内存（保证读语义一致）
## 【chunk 缓冲缺失时回落到求值体积】编辑收笔会作废相关 chunk 的缓冲（等流式泵重新取数），
## 而渲染器填回缓冲要等到下一帧。若拾取恰好落在这段窗口里，就会"刚画的格打不到"——
## 表现为"画一格后没法在它上面再画"。求值体积是同步、权威的那一份，故缺失时回落到它。
func get_voxel(pos: Vector3i) -> int:
	# 注意对外契约：**无体素返回 -1**，而不是全项目其它处的 0=空。这是历史契约，别顺手统一
	# （调用点普遍写 `if get_voxel(p) > 0`，改 0 会让"空"和"素材 0"撞上）。
	return _probe_voxel(pos)


## 是否存在体素（流式模式下磁盘上的 chunk 会自动载入内存）
func has_voxel(pos: Vector3i) -> bool:
	return _probe_voxel(pos) > 0


## 读一格体素（**取数与回落逻辑的唯一实现**）：返回材质 id，无体素返回 -1。
## 【为什么要抽出来】get_voxel / has_voxel 从前把那 6 行"取块 → 缓冲缺失 → 流里已存就同步载入 →
## 仍缺失则回落求值体积"逐行抄了两遍 —— 这是本类最热的读路径，任何一处补漏（比如将来加缓存层、
## 改回落优先级）都得记着改第二份，漏掉就是两个查询对同一格给出互相矛盾的答案。
func _probe_voxel(pos: Vector3i) -> int:
	var ck := _chunk_of(pos)
	var buf = _chunk_buffers.get(ck)
	if buf == null:
		# 流里已存 → 同步直读（读语义必须与"已加载"一致，否则同一格两次读结果不同）
		if is_stored(ck):
			preload_chunk(ck)
			buf = _chunk_buffers.get(ck)
		if buf == null:
			# 缓冲缺失（编辑收笔后到渲染器取数前的窗口）→ 回落求值体积，那份是同步且权威的
			return _volume_voxel(pos)
	var v: int = buf[_buf_index(pos - ck * CHUNK_SIZE)]
	return v if v > 0 else -1


## 从求值体积里读一格（缺失缓冲时的权威回落）。越界 / 无体积返回 -1。
func _volume_voxel(pos: Vector3i) -> int:
	if node == null or not _ensure_volume() or _volume.is_empty():
		return -1
	# 走到这里说明体积已建好且非空：读 _volume 必须满足这个不变式，否则下标会打到过期/空缓冲上
	# （_volume 被换掉时的复位收敛在 _reset_volume_cache，这里只做哨兵）。
	assert(_volume_built)
	var p := pos - _volume_origin
	var gs := _volume_grid_size
	if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= gs.x or p.y >= gs.y or p.z >= gs.z:
		return -1
	var m := _volume[p.x + p.y * gs.x + p.z * gs.x * gs.y]
	return m if m > 0 else -1


## 获取所有体素位置（内存 + 磁盘流中已持久化的，磁盘部分临时加载不缓存）
func get_positions() -> Array:
	# 内存部分整体下沉原生（逐体素枚举 + 逐体素 append 装箱 → 一次调用）：
	# GDScript 版实测约 1.28s / 200 万体素（≈20ms/chunk），原生化后约十分之一。
	var out: Array = NativeLoader.collect_all_positions(_chunk_buffers)
	# 合并"磁盘已存但不在内存"的 chunk（临时加载，不污染内存缓存）；这部分通常只有少数块。
	# 走统一 helper（与 get_voxels_dict_snapshot 同一份跳过规则），内存部分保持上面的原生快路。
	_for_each_stream_only_chunk(func(ck: Vector3i, buf: PackedInt32Array):
		var origin := VoxelChunk.origin_of(ck)
		for i in CHUNK_VOLUME:
			if buf[i] > 0:
				out.append(origin + _local_from_index(i)))
	return out


## 获取体素数量。**派生查询**：与唯一权威 _chunk_voxel_counts 恒等的 O(1) 增量镜像
## （_voxel_count_total），无第二份存储可漂移。流式下仅统计内存中已加载的体素。
## 热路径判空请用 is_empty()（等价且 O(1)）。
func get_voxel_count() -> int:
	# O(1)：增量镜像由 _count_delta / _count_set / _count_erase / _count_clear 共同维护
	# （此前每帧对整张 _chunk_voxel_counts 求和，调用点 demo/water_sim.gd 每帧一次）。
	return _voxel_count_total


## 求值输出里的体素总数（**链作用后**：含程序化产出与重排 / 镜像 / 平铺的结果）。
## 【为什么 get_voxel_count 给不出这个数】那个数求和于 chunk 缓冲的计数账本，而缓冲是**渲染现场**：
## 编辑后受影响的块会被 invalidate_chunk_source_range **丢掉**（等渲染器重新取数），于是落笔的那一刻
## 账本里恰好少了刚编辑的那几块 —— "画完却报 0 体素"的根因就在这里。
## 【为什么敢在此强制构建体积】那份体积**本来就要在本次编辑后被算一次**（渲染器取被作废的 chunk
## 时会走 _ensure_volume），这里只是把同一次求值提前到读数这一刻，之后渲染器反而命中缓存 ——
## 总工作量不变，而读数不再依赖"谁先跑"。数字与屏幕上的几何同源（都是求值输出）。
func evaluated_voxel_count() -> int:
	if not _ensure_volume():
		return 0
	if _volume_count < 0:
		_volume_count = _count_voxels(_volume)
	return _volume_count


## 是否完全没有体素
func is_empty() -> bool:
	return _chunk_buffers.is_empty()


## 设置指定位置的体素 (material_id <= 0 时移除；0 = 空)
func set_voxel(pos: Vector3i, material_id: int, notify: bool = true) -> void:
	if material_id <= 0:
		remove_voxel(pos, notify)
		return
	_write_buffer_impl(pos, material_id, false)
	_mark_voxel_dirty(pos)
	if notify:
		emit_changed()


## 移除指定位置的体素
func remove_voxel(pos: Vector3i, notify: bool = true) -> void:
	_remove_voxels([pos], notify)


## 清空所有体素（同时清除磁盘流中的持久化数据）
func clear(notify: bool = true) -> void:
	_chunk_buffers.clear()
	# 世界级重置：泄漏句柄必须在此断链，否则 _snapshot_readers 永久 >0（调用方须先取消批次）。
	_force_release_snapshots()
	_damage.clear_all()
	_count_clear()
	_source_invalidated.clear()
	# 脏账本一并归零：漏清会让旧坐标的脏 chunk / 失效块 / 脏区域在换世界后继续驱动渲染器
	# 重建（而它们的体素早已不存在）。
	_dirty.clear_all()
	for d in _coarse_buffers:
		d.clear()
	if stream != null:
		for ck in stream.get_all_chunk_keys(0):
			stream.erase_chunk(ck)
	_async.clear()
	if notify:
		emit_changed()


## 计算全部体素的包围盒 (AABB)，用于场景摆放 / 居中；空体素返回零 AABB。
## min/max 为值类型，lambda 按值捕获无法回写 → 只能内联循环（下面走原生）。
func get_voxels_aabb() -> AABB:
	if _chunk_voxel_counts.is_empty():
		return AABB()
	# 原生一次遍历：GDScript 逐体素扫描实测 1.4ms/chunk（1400 chunk 世界约 2 秒）。
	var bounds: Array = NativeLoader.collect_bounds(_chunk_buffers)
	if bounds.is_empty():
		return AABB()
	return _bounds_to_aabb(bounds)


## 计算一组体素的包围盒 (AABB)，空集合返回 null
static func _bounds_to_aabb(bounds: Array) -> AABB:
	if bounds.is_empty():
		return AABB()
	var min_pos: Vector3i = bounds[0]
	var max_pos: Vector3i = bounds[1]
	var extents := (max_pos - min_pos + Vector3i(1, 1, 1))
	return AABB(Vector3(min_pos), Vector3(extents))


## 批量移除指定位置的体素 (公开接口，供破坏/崩塌等系统调用)
func remove_voxels(positions: Array, notify: bool = true) -> Array:
	return _remove_voxels(positions, notify)


## 批量设置体素为同一材质（供水模拟等高频动态系统使用）。相比逐个 set_voxel：只 emit_changed
## 一次、只重建受影响 chunk。语义与 set_voxel 一致：material_id <= 0 视为批量移除。
## 走原生 C++ set_voxels_bulk（按 chunk 分组直接改 PackedInt32Array），替代逐体素字典写
## （每体素 5~8 次哈希）。
func set_voxels(positions: Array, material_id: int, notify: bool = true) -> void:
	if positions.is_empty():
		return
	if material_id <= 0:
		_remove_voxels(positions, notify)
		return
	# 流式下先 preload 涉及 chunk（否则原生会建空 buffer 覆盖磁盘旧数据）；用原生
	# collect_chunks 去重（遍历在 C++）。非流式无需 preload，bulk 会为全新 chunk 建空 buffer。
	if stream != null:
		var ck_list: Array = NativeLoader.collect_chunks(positions)
		for ck in ck_list:
			if not _chunk_buffers.has(ck) and is_stored(ck):
				preload_chunk(ck)
	var res: Dictionary = NativeLoader.set_voxels_bulk(_chunk_buffers, positions, material_id)
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_set: Dictionary = res["chunk_set"]
	for ck in chunk_set:
		_chunk_buffers[ck] = modified_buffers[ck]
		_count_delta(ck, int(chunk_set[ck]))
		_source_invalidated.erase(ck)
		# 流式：批量写入标记写盘（否则 chunk 被流式卸载时未 dirty → 存储里旧数据残留）
		_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
	# 标记脏 chunk + 跨界面邻居（用 C++ 返回的边界掩码按 chunk 标，避免逐体素的 dict 写入瓶颈）。
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		_mark_boundary_dirty(ck, int(boundary[ck]))
	if notify:
		emit_changed()


## 批量移除指定位置的体素（内部统一实现，供各 remove_* 复用）。
## 写 buffer 由原生 C++ 完成（按 chunk 分组直接改 PackedInt32Array），替代逐体素循环 ——
## 大崩塌（每帧 4096+ 体素）主线程大幅提速。GDScript 只做计数维护 + chunk 级脏标记
## （避免逐体素 dict 写入瓶颈；边界邻居由 _mark_voxel_dirty 一并标记）。
func _remove_voxels(positions: Array, notify: bool = true) -> Array:
	if positions.is_empty():
		return []
	if stream != null:
		# 流式：确保涉及 chunk 已加载（磁盘上的 chunk 未加载时删除会被跳过 → 数据丢失）
		var _preload_ck := {}
		for pos in positions:
			_preload_ck[_chunk_of(pos)] = true
		for ck in _preload_ck:
			preload_chunk(ck)
	# 原生批量移除（C++ 按 chunk 分组改 buffer，返回修改后的 buffer + 每 chunk 移除数 + 边界掩码）
	var res: Dictionary = NativeLoader.remove_voxels_bulk(_chunk_buffers, positions)
	var modified_buffers: Dictionary = res["buffers"]
	var chunk_removed: Dictionary = res["chunk_removed"]
	var touched: Dictionary = {}
	for ck in chunk_removed:
		_chunk_buffers[ck] = modified_buffers[ck]  # 覆盖为修改后的 buffer
		_count_delta(ck, -int(chunk_removed[ck]))
		_source_invalidated.erase(ck)
		# 流式：批量删除同样标写盘（否则卸载时未 dirty → 直接丢弃，重载后体素"复活"）。
		_dirty.mark(0, ck, VoxelDirtyLedger.PERSIST)
		touched[ck] = true
	# 标记脏 chunk + 跨界面邻居（用 C++ 边界掩码按 chunk 标，避免逐体素 7 次 dict 写入的瓶颈）。
	var boundary: Dictionary = res["boundary"]
	for ck in boundary:
		_dirty.mark(0, ck, VoxelDirtyLedger.MESH)
		# LOD0 用户批量编辑 → 失效高层 block 并标记需降采样
		mark_lod_modified_for_chunk(ck)
		_mark_boundary_dirty(ck, int(boundary[ck]))
	# 清零这些位置的累计伤害。用**请求列表**而非原生返回的 removed —— 后者是"实际移除的
	# 体素数"（int），不是位置数组；对本来就没有体素的位置清零也无害。
	clear_damage_bulk(positions)
	# 批量移除后统一回收被清空的 chunk 键（O(1) 计数判断）
	for ck in touched:
		_maybe_erase_empty_chunk(ck)
	if notify:
		emit_changed()
	return positions


## 添加材质，按材质 ID 对齐数组索引（体素存的 ID 即可直接作数组索引）。索引 0 保留为空；
## 该 ID 位置已有材质则覆盖。
func add_material(mat: VoxelMaterial, notify: bool = false) -> VoxelMaterial:
	if mat == null or mat.id <= 0:
		return null
	# 确保数组长度足够容纳索引 id
	while materials.size() <= mat.id:
		materials.append(null)
	materials[mat.id] = mat
	if notify:
		emit_changed()
	return mat



## 触发 changed 信号 (批量修改后手动调用)
func notify_changed() -> void:
	emit_changed()


# 存档 / 重建
#
# 【职责边界】"哪些块该落盘 / 怎么编解码"归 VoxelPersistence（唯一决策函数
# blocks_to_persist）；本类只提供上下文（内存块表 / 脏账 / 流 / 生成器）与
# 落地回调（_install_block_buffer / _write_buffer_impl 维护计数与脏账不变式）。
# 下面这些函数保留原名，是因为它们是本类的**私有实现细节**（契约测试只钉公开面），
# 同时 _get / _set / save_data / load_data 早已按名字在调；改名收益为零、风险不小。

## 持久化上下文（每次现取；不缓存，stream/node/dirty 都是可变字段）。
func _persist_ctx() -> Dictionary:
	return VoxelPersistence.ctx(_chunk_buffers, _dirty, stream, node, grid_size, materials)


## 把**全部要落盘的体素**序列化成一维扁平数组，布局 (x, y, z, mat_id) 四元组连续排列。
## 【为什么是扁平数组】逐体素一个 4 元素 Array 在 200 万体素时实测 1.97s / ~300MB；
## 扁平形式 14ms / 32MB（NativeLoader.collect_all_flat 一次原生收集）。
## 【"哪些块"的唯一决策在 VoxelPersistence.blocks_to_persist】有生成器只取用户改过的块
## （未改的块由生成器确定性重算，全量落盘会把 .tscn 撑成上百 MB）；无生成器取内存全部块
## ∪ 流中全部块（存档接口要给出"完整世界"，磁盘那部分也得合并进来）。流中那部分是
## **临时读盘**，不写回 _chunk_buffers —— 一次性存档不该改变缓存驻留集合。
## save_data() 用此完整版；资源持久化走 _collect_persist_blocks（块表），不经过逐体素序列化。
func _serialize_all_voxels() -> PackedInt32Array:
	return VoxelPersistence.serialize_flat(_persist_ctx())


## origin_mode 见 OriginMode（与 from_voxel_data 同一套语义与默认值）。
## QVX 的体素坐标就是文件里的块坐标（**不重映射**），故这里只需写对 center_offset ——
## 渲染顶点 = (块坐标 + center_offset) * voxel_scale，结果与 .vox 路径逐体素一致。
## 【frame 只在这里切，不做"当前帧"状态】本函数产出**某一帧的静态快照**（默认第 0 帧）。
## 帧是入参而非 QVoxelSource 的隐式状态：后者会污染它的存档与哈希语义。
## 运行时连续播放需要自己持有"当前帧"并按帧重建（不在本次范围）。
static func from_qvx(qvx: QVoxelAsset, origin_mode: int = OriginMode.WORLD_ORIGIN,
		frame: int = 0) -> QVoxelSource:
	var res := QVoxelSource.new()
	res.materials = qvx.materials
	if qvx.is_block_importable():
		var blocks: Dictionary = qvx.block_buffers(frame)
		for key in blocks:
			# duplicate：本资源随后会就地修改缓冲，不得与 QVoxelAsset 共享
			res._install_block_buffer(key, (blocks[key] as PackedInt32Array).duplicate())
	else:
		var voxels: Dictionary = qvx.fused_voxels(frame)
		for pos in voxels:
			res._write_buffer_impl(pos, voxels[pos], false)
	res.grid_size = qvx.grid_size(frame)
	res.center_offset = qvx.origin_offset(origin_mode, frame)
	return res


## 反序列化体素。接受两种载荷：扁平 PackedInt32Array（当前格式，原生整块装回）与
## Array of [x, y, z, mat]（旧格式，保留读取分支）。调用前应已 clear()，故直接装入不合并。
## 格式判别与整块装回都在 VoxelPersistence；这里只提供两个落地回调（维护计数与脏账）。
func _deserialize_voxels(voxel_list: Variant) -> void:
	VoxelPersistence.deserialize(voxel_list, _on_persisted_block, _on_persisted_voxel)


## 持久化回填一块（_install_block_buffer 维护计数账 / 作废标记等不变式）
func _on_persisted_block(chunk_key: Vector3i, buf: PackedInt32Array) -> void:
	_install_block_buffer(chunk_key, buf)


## 持久化回填一个体素（旧格式用；_write_buffer_impl 维护脏账与伤害账）
func _on_persisted_voxel(pos: Vector3i, material_id: int) -> void:
	_write_buffer_impl(pos, material_id, false)
# 资源持久化：materials/grid_size/default_scale/center_offset/frame_count 已由 @export 持久化；
# _chunk_buffers 非 @export，通过隐藏 storage 属性在此序列化（编辑器不可见，随资源保存）。
# 【防超大 .tscn】双保险：① 程序化流只序列化"用户改过的 chunk"；② 载荷 GZIP 压缩后 base64。
# 帧格式（魔数 / GZIP / base64）与版本校验的唯一实现在 VoxelPayloadCodec。

## 声明隐藏的 storage 属性（PROPERTY_USAGE_STORAGE：不显示在编辑器，但随资源保存/加载）
func _get_property_list() -> Array[Dictionary]:
	return [{
		"name": "voxel_data_payload",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_STORAGE,
	}]


func _get(property: StringName) -> Variant:
	if property == &"voxel_data_payload":
		return _encode_payload()
	return null


## 编码资源载荷：组装 {v, grid_size, blocks} 后交给 VoxelPayloadCodec 过帧。
## 【为什么是"块表"而非逐体素列表】体素本就按 chunk 对齐存在 `_chunk_buffers`，直接搬运零转换；
## 逐体素列表要先构造百万级 Array of Arrays 再序列化，峰值内存与耗时都是数倍。
func _encode_payload() -> String:
	return VoxelPersistence.encode_payload(_persist_ctx())


## 收集"需随资源持久化"的块缓冲 {chunk_key: PackedInt32Array}。
## 取舍**不再在这里**：唯一决策是 VoxelPersistence.blocks_to_persist(c, false) ——
## 有生成器存改过的块、无生成器存内存全部块（磁盘流那部分由 stream 自己负责，不进载荷）。
func _collect_persist_blocks() -> Dictionary:
	return VoxelPersistence.collect_persist_blocks(_persist_ctx())


## 从载荷恢复块缓冲（块表：chunk_key → PackedInt32Array）。缺字段即视为空载荷。
func _load_payload_blocks(payload: Dictionary) -> void:
	VoxelPersistence.apply_payload_blocks(payload, _on_persisted_block)


## 解码资源载荷；返回 null 即载荷无效（调用方按空载荷处理，不猜着读）。
func _decode_payload(value: String) -> Variant:
	return VoxelPersistence.decode_payload(value)


func _set(property: StringName, value: Variant) -> bool:
	if property == &"voxel_data_payload":
		# 只清内存缓冲，不动 stream 的磁盘持久化数据——场景加载时 stream 已先赋值，
		# 若调 clear() 会走 stream.erase_chunk 误删磁盘上已持久化的修改 chunk。
		_chunk_buffers.clear()
		_force_release_snapshots()
		_damage.clear_all()
		_count_clear()
		_dirty.clear_all()
		for d in _coarse_buffers:
			d.clear()
		var payload: Variant = _decode_payload(str(value))
		if payload is Dictionary:
			# 尺寸字段形状不对时保持原尺寸（payload_grid_size 返回 null）
			var gs: Variant = VoxelPersistence.payload_grid_size(payload)
			if gs != null:
				grid_size = gs
			_load_payload_blocks(payload)
		return true
	return false


## 将体素数据和材质序列化为可 JSON 保存的结构，load_data 可完整重建。
## { "grid_size": [x, y, z], "materials": [...], "voxels": [x, y, z, mat_id, ...] }
func save_data() -> Dictionary:
	var data := {}
	data["grid_size"] = [grid_size.x, grid_size.y, grid_size.z]
	# 材质序列化（保留非 null 材质，材质自身负责存档）
	var mats := []
	for mat in materials:
		if mat == null:
			continue
		mats.append(mat.save_data())
	data["materials"] = mats
	# 体素序列化（复用唯一权威序列化器；流式模式下含磁盘持久化数据）
	data["voxels"] = _serialize_all_voxels()
	return data


## 从 save_data() 返回的数据重建体素和材质（先清空当前内容）
func load_data(data: Variant) -> void:
	clear(false)
	if data == null or not data is Dictionary:
		emit_changed()
		return
	# 材质重建（材质自身负责从数据恢复）
	materials = []
	if data.has("materials"):
		for mat_data in data["materials"]:
			var mat: VoxelMaterial = VoxelMaterial.load_data(mat_data)
			if mat != null:
				while materials.size() <= mat.id:
					materials.append(null)
				materials[mat.id] = mat
	# 网格尺寸
	if data.has("grid_size") and data["grid_size"] is Array and data["grid_size"].size() >= 3:
		grid_size = Vector3i(int(data["grid_size"][0]), int(data["grid_size"][1]), int(data["grid_size"][2]))
	# 体素重建（复用唯一权威反序列化器）
	_deserialize_voxels(data.get("voxels", null))
	emit_changed()



## O(1) 判断指定 chunk 数据是否已就绪（内存已加载 / 流中已存）。可生成但尚未生成的返回 false。
func has_chunk(chunk_key: Vector3i) -> bool:
	return _chunk_buffers.has(chunk_key) or is_stored(chunk_key)


## 批量收集一组世界坐标处的体素材质 ID，返回 {Vector3i: int}（无体素 / 未加载 → -1）。
## 【为什么需要这个公开薄壳】破坏组件要一次读回成百上千个位置的材质（大崩塌时是数万次
## 逐体素 get_voxel 哈希，全在主线程），而它此前直接调内部协议 _chunk_buffers_view()
## 把内部字典交给原生接口 —— 内核外组件不得触碰存储布局（见 test_voxel_kernel_contract
## 的 VOXEL_DATA_INTERNAL_PROTOCOLS）。这里把"取缓冲 → 批量读"封成一个动作：
## 既保住单次原生调用，也不再泄漏存储布局。
func collect_materials_at(positions: Array) -> Dictionary:
	if positions.is_empty():
		return {}
	return NativeLoader.collect_materials(_chunk_buffers, positions)


# ── 粒子点数据（把体素导出成 GPU 可直接消费的点云）──────────────────────────
# 【实现已整体搬走】导出是**纯派生计算**（块表 + 材质表 → 点云），与存储不变式（计数账 /
# 脏账 / 快照 / 流式）无关，现在全部在 VoxelPointCloudExporter。本层只留两样东西：
#   ① 常量别名 —— 既有调用方（demo/particle_demo.gd、test_voxel_particle_points.gd）继续写
#      QVoxelSource.PARTICLE_STRIDE，而**真值只有一份**，在 exporter 里；
#   ② 同名同签名的两个公开方法 —— 调用方（VoxelParticleView）不需要知道实现搬走了。
# 这不是 @deprecated 转发壳：导出实现在全项目仍只有一份，本层这两行就是唯一公开面。

## 每个粒子点的 float 数（真值见 VoxelPointCloudExporter.PARTICLE_STRIDE）
const PARTICLE_STRIDE := VoxelPointCloudExporter.PARTICLE_STRIDE
## 通道偏移（布局下标，真值见 VoxelPointCloudExporter）
const P_POS := VoxelPointCloudExporter.P_POS      ## +0..2 世界坐标
const P_MAT := VoxelPointCloudExporter.P_MAT      ## 材质 ID
const P_COLOR := VoxelPointCloudExporter.P_COLOR  ## +0..2 sRGB 基色
const P_SEED := VoxelPointCloudExporter.P_SEED    ## 稳定随机 0..1
const P_EMIT := VoxelPointCloudExporter.P_EMIT    ## 自发光 0..1
const P_METAL := VoxelPointCloudExporter.P_METAL  ## 金属度 0..1
const P_ROUGH := VoxelPointCloudExporter.P_ROUGH  ## 粗糙度 0..1
const P_TRANS := VoxelPointCloudExporter.P_TRANS  ## 透明度 0..1（0 = 不透明）

## 默认粒子点上限（真值见 VoxelPointCloudExporter.PARTICLE_DEFAULT_MAX）
const PARTICLE_DEFAULT_MAX := VoxelPointCloudExporter.PARTICLE_DEFAULT_MAX

## 惰性创建的导出器。它不持有本资源（上下文按次传入）→ 不会形成引用环，
## 也不会出现"点云是旧的"两套真值问题。
var _particle_exporter: VoxelPointCloudExporter = null


## 现取一份导出上下文：块表与材质表每次都取当前值（派生查询，刻意不缓存）。
func _particle_ctx() -> Dictionary:
	return VoxelPointCloudExporter.as_context(
			_chunk_buffers, materials, center_offset, default_scale)


## 把当前体素导出成**连续定长**的粒子点数组（GPU 可直接消费）。
## 布局（每点 PARTICLE_STRIDE = 12 float）：世界坐标 xyz / 材质 ID / sRGB 基色 / 稳定随机种子 /
## emission / metal / rough / trans。语义与下采样规则见 VoxelPointCloudExporter.build_particle_points：
## [param max_points] 是**硬上限**，总候选数超过时按 `stride = ceil(total / max_points)` 全局等步长
## 抽样（确定性、与 chunk 加载顺序无关），不是"取前 N 个"。
## [param surface_only] 只留表面体素；**透明体素永远保留**（玻璃被包住也能看见后面）。
func build_particle_points(scale: float = -1.0, max_points: int = PARTICLE_DEFAULT_MAX,
		surface_only: bool = true) -> PackedFloat32Array:
	if _particle_exporter == null:
		_particle_exporter = VoxelPointCloudExporter.new()
	return _particle_exporter.build_particle_points(_particle_ctx(), scale, max_points, surface_only)


## 把点数据上传成 GPU 纹理。返回字典字段（points / count / grid_width / stride /
## positions / colors / props / bounds）见 VoxelPointCloudExporter.build_particle_textures。
func build_particle_textures(scale: float = -1.0, max_points: int = PARTICLE_DEFAULT_MAX,
		surface_only: bool = true) -> Dictionary:
	if _particle_exporter == null:
		_particle_exporter = VoxelPointCloudExporter.new()
	return _particle_exporter.build_particle_textures(_particle_ctx(), scale, max_points, surface_only)


# 连通性检测（崩塌支撑判定）：算法与 NEIGHBORS_6 真值都在 VoxelConnectivity，本类只做薄转发，
# 判据以 Callable 传入（has_voxel / get_positions）。转发壳保留是为了不破坏既有调用方。

## 泛洪标记与 seeds 连通的体素集合（Dictionary 作 Set）。见 VoxelConnectivity.flood_fill
func flood_fill(seeds, restrict: Dictionary = {}) -> Dictionary:
	return VoxelConnectivity.flood_fill(seeds, has_voxel, restrict)




## 找出"悬空"体素（与地面断开的连通分量）。空世界守卫留在本类（读存储侧权威计数）。
func find_unsupported(voxels_set: Dictionary = {}) -> Dictionary:
	if voxels_set.is_empty() and _chunk_voxel_counts.is_empty():
		return {}
	return VoxelConnectivity.find_unsupported(voxels_set, get_positions, has_voxel)


## 找出"悬空"体素（局部检测，原生列支撑）。见 VoxelConnectivity.find_unsupported_around
func find_unsupported_around(removed: Array) -> Dictionary:
	return VoxelConnectivity.find_unsupported_around(_chunk_buffers, removed)
