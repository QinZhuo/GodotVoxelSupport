extends TestCase

## PCG 算子单元测试（编辑器进程即可，纯数据运算，不碰场景树）。
##
## 盯的是三样东西的**契约**，不是"好不好看"：
##   1. PcgModel 的下标 / 越界工具 —— 所有算子共用的那一层，错了全体错。
##   2. QVoxelSource 的切片换算 —— "整体产出 → 按 chunk / 粗层取数"全项目只此一份实现，
##      LOD0 的 chunk 偏移与粗层的"格内折叠"都必须与 VoxelChunk 的布局公式严格对齐。
##   3. 三个算子（L-系统 / 元胞自动机 / WFC）的**确定性**与**退化行为**（展开截断、矛盾重试）。
##
## 视觉正确性归 demo 实机验证；这里只钉住"换个改动不会静默算错"的底线。

## WFC 图块边长与格网尺寸（8³ / 4³ 图块 → 2×2×2 = 8 格）。
const WFC_TILE := 4
const WFC_GRID := Vector3i(8, 8, 8)


## 只在指定位置放一个体素的确定性模型 —— 用精确位置反推"整体产出 → chunk / 粗层"的换算。
## 比随机模型更适合测切片：任何一处偏移算错都会让那个唯一的体素落在别处。
class ProbeModel:
	extends PcgModel

	var at := Vector3i.ZERO
	var material := 9

	func _init(p_at := Vector3i.ZERO, p_material := 9) -> void:
		at = p_at
		material = p_material

	func build(grid_size: Vector3i) -> PackedInt32Array:
		var v := PcgModel.empty_volume(grid_size)
		PcgModel.set_voxel(v, at.x, at.y, at.z, grid_size, material)
		return v


# ----------------------------------------------------------------------------
# ① PcgModel 下标 / 越界工具：所有算子共用的地基
# ----------------------------------------------------------------------------

func test_model_index_and_bounds_helpers() -> void:
	# 布局：x 连续，再 y，再 z —— 1 + 2*4 + 3*4*5
	assert_eq(PcgModel.index_of(1, 2, 3, Vector3i(4, 5, 6)), 69, "index_of 布局应为 x + y*gx + z*gx*gy")
	assert_true(PcgModel.empty_volume(Vector3i.ZERO).is_empty(), "零尺寸体积应为空数组")
	assert_eq(PcgModel.empty_volume(Vector3i(4, 5, 6)).size(), 120, "体积长度应为 gx*gy*gz")

	# 越界写入必须静默忽略（子类绘制时依赖这一点，不必自己夹取边界）
	var gs := Vector3i(4, 4, 4)
	var v := PcgModel.empty_volume(gs)
	PcgModel.set_voxel(v, 100, 0, 0, gs, 7)
	PcgModel.set_voxel(v, -1, 0, 0, gs, 7)
	PcgModel.set_voxel(v, 0, 4, 0, gs, 7)
	assert_eq(_count_solid(v), 0, "越界写入应被忽略")

	PcgModel.set_voxel(v, 1, 1, 1, gs, 5)
	assert_eq(v[PcgModel.index_of(1, 1, 1, gs)], 5, "界内写入应落到 index_of 算出的位置")
	assert_eq(_count_solid(v), 1, "只应写入一个体素")


# ----------------------------------------------------------------------------
# ② QVoxelSource：把整块体积切成 32³ chunk
# ----------------------------------------------------------------------------

func test_source_slices_chunks() -> void:
	# 体素落在 (33,1,2) → 第 2 个 chunk（key=(1,0,0)）内，局部坐标 (1,1,2)
	var data := _source(ProbeModel.new(Vector3i(33, 1, 2), 9), Vector3i(64, 8, 8))

	assert_eq(_count_solid(data.generate(Vector3i(0, 0, 0))), 0, "第 1 个 chunk 应全空")
	var buf := data.generate(Vector3i(1, 0, 0))
	assert_eq(buf.size(), VoxelChunk.CHUNK_VOLUME, "chunk 缓冲长度应为 32³")
	assert_eq(buf[VoxelChunk.buf_index(1, 1, 2)], 9, "体素应切到局部坐标 (1,1,2)")
	assert_eq(_count_solid(buf), 1, "第 2 个 chunk 应只含这一个体素")


# ----------------------------------------------------------------------------
# ③ QVoxelSource：粗层把 2^lod 立方折叠成一格
# ----------------------------------------------------------------------------

func test_source_lod_folds_cells() -> void:
	var data := _source(ProbeModel.new(Vector3i(5, 5, 5), 9), Vector3i(64, 64, 64))
	var grid := VoxelChunkGenerator.LOD_BLOCK_SIZE

	# lod=1：每格 2 体素 → (5,5,5) 落在格 (2,2,2)
	var lod1 := data.generate(Vector3i(0, 0, 0), 1)
	assert_eq(lod1.size(), grid * grid * grid, "粗层缓冲长度应为 LOD_BLOCK_SIZE³")
	assert_eq(lod1[2 + 2 * grid + 2 * grid * grid], 9, "lod=1 应把体素折叠到格 (2,2,2)")
	assert_eq(_count_solid(lod1), 1, "lod=1 应只折叠出一个实心大格")

	# lod=2：每格 4 体素 → (5,5,5) 落在格 (1,1,1)；同一体素在更粗层归到更大的格
	var lod2 := data.generate(Vector3i(0, 0, 0), 2)
	assert_eq(lod2[1 + grid + grid * grid], 9, "lod=2 应把体素折叠到格 (1,1,1)")
	assert_eq(_count_solid(lod2), 1, "lod=2 应只折叠出一个实心大格")


# ----------------------------------------------------------------------------
# ④ QVoxelSource：改盒必须作废旧缓存并重建
# ----------------------------------------------------------------------------

func test_source_rebuilds_on_grid_change() -> void:
	var node := QVoxelModel.of_source(ProbeModel.new(Vector3i(40, 0, 0), 3), Vector3i(64, 4, 4))
	var data := QVoxelSource.new()
	data.grid_size = Vector3i(64, 4, 4)
	data.node = node
	assert_eq(data.generate(Vector3i(1, 0, 0))[VoxelChunk.buf_index(8, 0, 0)], 3,
			"64 宽时应能在第 2 个 chunk 的 x=8 处取到体素")

	# 缩小到 32 宽：x=40 已在界外 —— 改盒后必须作废求值缓存（data.grid_size 的 setter 会做），
	# 否则会读到旧体积、这里就非空
	node.grid_size = Vector3i(32, 4, 4)
	data.grid_size = Vector3i(32, 4, 4)
	assert_eq(_count_solid(data.generate(Vector3i(1, 0, 0))), 0, "改小尺寸后应重建为全空")

	# 无节点必须产出全空，而不是崩溃或复用旧体积
	data.node = null
	assert_eq(_count_solid(data.generate(Vector3i(0, 0, 0))), 0, "无节点应产出全空")


# ----------------------------------------------------------------------------
# ⑤ 元胞自动机：同种子恒同结果，异种子应不同，且不应退化成全空/全实
# ----------------------------------------------------------------------------

func test_cellular_is_deterministic() -> void:
	var gs := Vector3i(16, 16, 16)
	var a := _cave(0)
	var b := _cave(0)
	var c := _cave(12345)

	assert_eq(a.build(gs), b.build(gs), "同 seed 应恒得同一洞穴")
	assert_ne(a.build(gs), c.build(gs), "不同 seed 应得到不同洞穴")

	var solid := _count_solid(a.build(gs))
	var total := gs.x * gs.y * gs.z
	assert_true(solid > 0, "洞穴不应退化成全空（否则确定性断言失去意义）")
	assert_true(solid < total, "洞穴不应退化成全实（否则确定性断言失去意义）")


# ----------------------------------------------------------------------------
# ⑥ L-系统：确定性 + 展开长度上限（截断与迭代次数封顶）
# ----------------------------------------------------------------------------

func test_lsystem_is_deterministic_and_bounded() -> void:
	var gs := Vector3i(32, 32, 32)
	assert_eq(_tree().build(gs), _tree().build(gs), "同参数应恒得同一棵树")

	# 极小网格不应崩：起点与所有印章都会越界，靠 set_voxel 静默忽略兜住
	assert_eq(_tree().build(Vector3i(2, 2, 2)).size(), 8, "极小网格仍应返回对齐尺寸的模型")

	# 符号数爆炸时按 MAX_SYMBOLS 截断（12^6 ≈ 3.0M → 截到 10 万）
	var long_rules := PcgLsystem.new()
	long_rules.axiom = "F"
	long_rules.rules = PackedStringArray(["F=FFFFFFFFFFFF"])
	long_rules.iterations = 6
	assert_eq(long_rules._expand().length(), PcgLsystem.MAX_SYMBOLS, "超出上限应截断到 MAX_SYMBOLS")

	# 迭代次数封顶到 MAX_ITERATIONS（"F=FF" 每次翻倍 → 2^MAX_ITERATIONS）
	var capped := PcgLsystem.new()
	capped.axiom = "F"
	capped.rules = PackedStringArray(["F=FF"])
	capped.iterations = 99
	assert_eq(capped._expand().length(), 1 << PcgLsystem.MAX_ITERATIONS, "迭代次数应封顶")


# ----------------------------------------------------------------------------
# ⑦ WFC：socket 约束真的在起作用 —— 只有同名接口能相邻
# ----------------------------------------------------------------------------

func test_wfc_enforces_socket_constraint() -> void:
	# 两块都全实心、材质不同，但接口名不同（"a" 与 "b"）：任何方向都拼不上异类，
	# 于是整图必须同色 —— 若约束失效会拼出错综的混色（distinct 变 2）而被抓出。
	var wfc := PcgWfc.new()
	wfc.tiles = [_solid_tile("a", 1), _solid_tile("b", 2)]
	wfc.seed = 7

	var vol := wfc.build(WFC_GRID)
	assert_eq(vol.size(), WFC_GRID.x * WFC_GRID.y * WFC_GRID.z, "输出长度应等于网格体积")
	assert_eq(_count_solid(vol), WFC_GRID.x * WFC_GRID.y * WFC_GRID.z, "两块图块都是实心 → 应填满")
	assert_eq(_distinct_values(vol).size(), 1, "接口名不同则整图必须同色（socket 约束生效的判据）")


# ----------------------------------------------------------------------------
# ⑧ WFC：矛盾时按 max_retries 重试，全失败则输出空模型（长度仍对齐）
# ----------------------------------------------------------------------------

func test_wfc_retries_and_gives_up_on_contradiction() -> void:
	# 两块接口都是 ["a","b","a","b","a","b"] → OPPOSITE 把偶/奇下标互换，
	# 任何方向都要求"a 对面是 b"却又要求同名，故必然矛盾。
	var wfc := PcgWfc.new()
	wfc.tiles = [
		_solid_tile_sockets(PackedStringArray(["a", "b", "a", "b", "a", "b"]), 1),
		_solid_tile_sockets(PackedStringArray(["a", "b", "a", "b", "a", "b"]), 2),
	]
	wfc.seed = 3
	wfc.max_retries = 2

	var vol := wfc.build(WFC_GRID)
	assert_eq(vol.size(), WFC_GRID.x * WFC_GRID.y * WFC_GRID.z, "放弃时也应返回对齐尺寸的缓冲")
	assert_eq(_count_solid(vol), 0, "全重试都矛盾应输出空模型")


# ----------------------------------------------------------------------------
# ⑨ 重叠式 WFC：图案从样例"数"出来 —— 沿 x 交替的样例必须学出 2 种图案、输出严格交替
# ----------------------------------------------------------------------------

func test_wfc_overlap_learns_patterns_from_sample() -> void:
	# 样例 4×2×2、沿 x 交替 1/2；N=2 的滑窗只有 3 个：
	#   x=0..1 → [1,2]、x=1..2 → [2,1]、x=2..3 → [1,2] → 去重后 2 种，权重 2 与 1。
	var ov := _overlap(_alt_sample(), Vector3i(4, 2, 2), 2)
	ov.seed = 5
	var gs := Vector3i(8, 2, 2)
	var vol := ov.build(gs)

	assert_eq(ov._patterns.size(), 2, "沿 x 交替的样例应去重出 2 种图案（多于 2 说明去重没按内容比较）")
	assert_eq(ov._weights.size(), 2, "权重数组应与图案一一对应")
	var w0 := int(ov._weights[0])
	var w1 := int(ov._weights[1])
	assert_true((w0 == 1 and w1 == 2) or (w0 == 2 and w1 == 1), "两种图案的出现次数应为 2 与 1")

	assert_eq(vol.size(), gs.x * gs.y * gs.z, "输出长度应等于网格体积")
	assert_eq(_distinct_values(vol).size(), 2, "输出应只用样例里出现过的材质")

	# 相容表要求 [1,2] 后必接 [2,1]、[2,1] 后必接 [1,2] → 沿 x 严格交替（相邻必不同色）。
	for z in gs.z:
		for y in gs.y:
			for x in gs.x - 1:
				var i := PcgModel.index_of(x, y, z, gs)
				assert_ne(vol[i], vol[i + 1], "沿 x 相邻格必须交替（重叠区约束生效的判据）")


# ----------------------------------------------------------------------------
# ⑩ 重叠式 WFC：确定性 + 退化输入（样例过小 / 全同样例）
# ----------------------------------------------------------------------------

func test_wfc_overlap_deterministic_and_degenerate() -> void:
	var gs := Vector3i(4, 4, 4)
	assert_eq(_overlap(_alt_sample(), Vector3i(4, 2, 2), 2).build(gs),
			_overlap(_alt_sample(), Vector3i(4, 2, 2), 2).build(gs), "同参数同 seed 应恒得同一结果")

	# 样例边长 2 < N=3 → 学不到图案：返回对齐尺寸的空模型，而不是崩溃
	var tiny := PcgWfcOverlap.new()
	tiny.sample_size = Vector3i(2, 2, 2)
	tiny.sample = PackedInt32Array([1, 1, 1, 1, 1, 1, 1, 1])
	tiny.pattern_size = 3
	assert_eq(tiny.build(gs).size(), gs.x * gs.y * gs.z, "样例过小也应返回对齐尺寸的缓冲")
	assert_eq(_count_solid(tiny.build(gs)), 0, "样例过小应输出空模型")

	# 全同样例 → 只有 1 种图案（域一开始即为单元素）→ 输出必须全为同一材质
	var flat := PcgWfcOverlap.new()
	flat.sample_size = Vector3i(4, 4, 4)
	var fv := PackedInt32Array()
	fv.resize(64)
	fv.fill(5)
	flat.sample = fv
	flat.pattern_size = 2
	var out := flat.build(gs)
	assert_eq(_count_solid(out), 64, "全同样例应填满")
	assert_eq(_distinct_values(out).size(), 1, "全同样例应只有 1 种材质")


# ----------------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------------

## 把模型挂到数据层上并设好尺寸（与 demo / QVoxelSource 的组装方式一致）。
func _source(model: PcgModel, grid_size: Vector3i) -> QVoxelSource:
	var data := QVoxelSource.new()
	data.grid_size = grid_size
	data.node = QVoxelModel.of_source(model, grid_size)
	return data


## 元胞自动机洞穴：关掉实心外壳以便看到内腔（与 demo 同参数风格）。
func _cave(seed_value: int) -> PcgCellular:
	var ca := PcgCellular.new()
	ca.fill_ratio = 0.44
	ca.iterations = 4
	ca.seed = seed_value
	ca.shell_is_solid = false
	return ca


## 可辨认的 3D 树：主干每轮翻倍 + 四方向分枝（与 demo 同参数）。
func _tree() -> PcgLsystem:
	var ls := PcgLsystem.new()
	ls.axiom = "F"
	ls.rules = PackedStringArray(["F=FF[+F][-F][&F][^F]"])
	ls.iterations = 2
	ls.step = 2.2
	return ls


## 六面同名的全实心图块。
func _solid_tile(face_socket: String, material: int) -> PcgWfcTile:
	var sockets := PackedStringArray()
	for _i in 6:
		sockets.append(face_socket)
	return _solid_tile_sockets(sockets, material)


## 指定六面接口的全实心图块。
func _solid_tile_sockets(sockets: PackedStringArray, material: int) -> PcgWfcTile:
	var size := Vector3i(WFC_TILE, WFC_TILE, WFC_TILE)
	var vox := PackedInt32Array()
	vox.resize(size.x * size.y * size.z)
	vox.fill(material)
	return PcgWfcTile.make(size, vox, sockets)


## 非空体素个数。
func _count_solid(volume: PackedInt32Array) -> int:
	var n := 0
	for m in volume:
		if m != 0:
			n += 1
	return n


## 出现过的材质集合（键 = 材质ID）。
func _distinct_values(volume: PackedInt32Array) -> Dictionary:
	var seen := {}
	for m in volume:
		seen[m] = true
	return seen


## 重叠式 WFC：挂上样例与图案尺寸（与 demo 的组装方式一致）。
func _overlap(sample: PackedInt32Array, sample_size: Vector3i, n: int) -> PcgWfcOverlap:
	var ov := PcgWfcOverlap.new()
	ov.sample = sample
	ov.sample_size = sample_size
	ov.pattern_size = n
	return ov


## 沿 x 交替 1/2、其余两轴恒定的小样例（N=2 时恰能学出 2 种图案）。
func _alt_sample() -> PackedInt32Array:
	var s := Vector3i(4, 2, 2)
	var v := PackedInt32Array()
	v.resize(s.x * s.y * s.z)
	for z in s.z:
		for y in s.y:
			for x in s.x:
				v[x + y * s.x + z * s.x * s.y] = 1 if x % 2 == 0 else 2
	return v
