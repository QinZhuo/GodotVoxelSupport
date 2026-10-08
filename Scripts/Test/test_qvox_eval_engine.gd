extends TestCase

## P3「统一生成流水线」的契约测试：求值引擎（QVoxEvalEngine）+ 链的 VoxelGenerator 适配器
## （QVoxModelGenerator）。
##
## 钉死四条硬承诺 —— 每一条都对应一个"以后重构很容易悄悄弄坏"的点：
##   ① 手绘体素是链的**输入/种子**，不是链的一环 → 链首那条的 combine 决定它怎么与手绘相合；
##   ② 域只能单向降级，FIELD→VOXEL 的降级点由引擎自动插入，调用方看不见；
##   ③ 引擎是无状态纯函数 + 输入签名 → 连"改都没改"时零成本复用上一次结果；
##   ④ 链的产出能逐 chunk 喂给渲染管线，且与整块体积**逐格一致**（切片不重不漏）。

const GS := Vector3i(64, 32, 32)


# ----------------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------------

## 网格中心的球。半径远小于网格 → 不相交边界，暴露度断言才干净。
func _sphere(radius: float, mat: int) -> SdfSphere:
	var s := SdfSphere.new()
	s.center = Vector3(32.0, 16.0, 16.0)
	s.radius = radius
	s.material_id = mat
	return s


func _at(x: int, y: int, z: int) -> int:
	return PcgModel.index_of(x, y, z, GS)


## 中心球形的**体素域源**（_CountingModel）—— 与 _sphere() 的场域版同形状，
## 于是"场域链首"与"体素域链首"两条测试能共用同一套"角落 / 球心"断言。
func _sphere_model(radius: float, mat: int) -> _CountingModel:
	var m := _CountingModel.new()
	m.radius = radius
	m.material_id = mat
	return m


## 把算子收成一条链。接受无类型字面量、返回带类型的链 —— 否则每处都要写一遍
## `var mods: Array[QVoxModifier] = [...]`，测试会被类型注记淹没。
func _chain(mods: Array) -> Array[QVoxModifier]:
	var out: Array[QVoxModifier] = []
	out.assign(mods)
	return out


## 角落一小块手绘石料。球够不到这里 → 可用于区分"手绘"与"链产出"。
func _obj_with_blocks() -> QVoxModel:
	var obj := QVoxModel.new()
	obj.grid_size = GS
	obj.fill_box(Vector3i(1, 1, 1), Vector3i(3, 4, 4), 9)
	return obj


## 测试用的"自足产出型"源：在网格中心画一个球，并数出自己被跑了多少次。
##
## 【为什么要一个自定义源】逐步骤判脏的契约是"改链尾不得重跑链首"，而这件事只能靠**计数**证明：
## 现成算子的产出与参数强耦合（改参数就改产出），没法把"重跑与否"与"产出变了"分开看。
class _CountingModel:
	extends PcgModel

	## 累计 build 次数（进程内静态，测试开头必须清零）。
	static var builds := 0

	@export var radius := 10.0
	@export var material_id := 1

	func build(grid_size: Vector3i) -> PackedInt32Array:
		builds += 1
		var v := PcgModel.empty_volume(grid_size)
		var c := Vector3(grid_size) * 0.5
		for z in grid_size.z:
			for y in grid_size.y:
				for x in grid_size.x:
					if (Vector3(x, y, z) - c).length() <= radius:
						v[PcgModel.index_of(x, y, z, grid_size)] = material_id
		return v


# ----------------------------------------------------------------------------
# ① 手绘体素是链的输入
# ----------------------------------------------------------------------------

func test_empty_chain_returns_hand_drawn_voxels() -> void:
	var obj := _obj_with_blocks()
	var res := QVoxEvalEngine.evaluate(obj, QVoxEvalContext.make(GS, 0))
	assert_eq(res.domain, QVoxDomain.Kind.VOXEL, "空链停在体素域（只有手绘基础体素）")
	assert_eq(res.volume.size(), GS.x * GS.y * GS.z, "手绘非空 → 完整体积")
	assert_eq(res.solid_count(), obj.count_solid(), "空链的产出就是手绘体素本身")
	assert_eq(res.volume[_at(2, 2, 2)], 9, "手绘材质原样保留")


func test_leading_combine_decides_how_chain_meets_hand_drawn() -> void:
	var corner := Vector3i(2, 2, 2)     # 球够不到的角落
	var center := Vector3i(32, 16, 16)  # 球心

	var union := _obj_with_blocks()
	var m_union := QVoxSdfModifier.of(_sphere(10.0, 1), QVoxDomain.Combine.UNION)
	union.modifiers = _chain([m_union])
	var ru := QVoxEvalEngine.evaluate(union, QVoxEvalContext.make(GS, 0))
	assert_eq(ru.volume[_at(corner.x, corner.y, corner.z)], 9, "并集：手绘石料保留")
	assert_eq(ru.volume[_at(center.x, center.y, center.z)], 1, "并集：球体也进来")

	var replace := _obj_with_blocks()
	var m_replace := QVoxSdfModifier.of(_sphere(10.0, 1), QVoxDomain.Combine.REPLACE)
	replace.modifiers = _chain([m_replace])
	var rr := QVoxEvalEngine.evaluate(replace, QVoxEvalContext.make(GS, 0))
	assert_eq(rr.volume[_at(corner.x, corner.y, corner.z)], 0, "替换：这条 SDF 定义模型，手绘作废")
	assert_eq(rr.volume[_at(center.x, center.y, center.z)], 1, "替换：球体在")

	var subtract := _obj_with_blocks()
	var m_sub := QVoxSdfModifier.of(_sphere(10.0, 1), QVoxDomain.Combine.SUBTRACT)
	subtract.modifiers = _chain([m_sub])
	var rs := QVoxEvalEngine.evaluate(subtract, QVoxEvalContext.make(GS, 0))
	assert_eq(rs.volume[_at(corner.x, corner.y, corner.z)], 9, "差集：球碰不到角落，石料留下")
	assert_eq(rs.solid_count(), subtract.count_solid(), "差集：球与石料不相交 → 结果等于石料")

	var intersect := _obj_with_blocks()
	var m_int := QVoxSdfModifier.of(_sphere(10.0, 1), QVoxDomain.Combine.INTERSECT)
	intersect.modifiers = _chain([m_int])
	var ri := QVoxEvalEngine.evaluate(intersect, QVoxEvalContext.make(GS, 0))
	assert_eq(ri.solid_count(), 0, "交集：球与角落石料不相交 → 空")


## 链首直接是**体素域源**（PcgModel）时，combine 同样决定它与手绘体素怎么合。
##
## 【为什么这条必须单独钉】场域链首靠"降级那一步"显式把 obj.to_volume() 当左操作数，
## 而体素域链首没有降级步骤，一旦把"空 acc"直接当左操作数，UNION 就退化成 REPLACE
## （手绘石料凭空消失）、SUBTRACT 退化成"挖不动"—— 恰恰是"手绘 + 程序化混着用"的两种用法。
func test_voxel_source_head_also_meets_hand_drawn() -> void:
	var corner := Vector3i(2, 2, 2)     # 源够不到的角落
	var center := Vector3i(32, 16, 16)  # 源产出（网格中心的球）所在

	var union := _obj_with_blocks()
	var m_union := QVoxModelModifier.of(_sphere_model(10.0, 1))
	m_union.combine = QVoxDomain.Combine.UNION
	union.modifiers = _chain([m_union])
	var ru := QVoxEvalEngine.evaluate(union, QVoxEvalContext.make(GS, 0))
	assert_eq(ru.volume.size(), GS.x * GS.y * GS.z, "体素源产出的也是整块体积")
	assert_eq(ru.volume[_at(corner.x, corner.y, corner.z)], 9, "并集：手绘石料保留")
	assert_eq(ru.volume[_at(center.x, center.y, center.z)], 1, "并集：源产出也进来")

	var replace := _obj_with_blocks()
	var m_replace := QVoxModelModifier.of(_sphere_model(10.0, 1))
	m_replace.combine = QVoxDomain.Combine.REPLACE
	replace.modifiers = _chain([m_replace])
	var rr := QVoxEvalEngine.evaluate(replace, QVoxEvalContext.make(GS, 0))
	assert_eq(rr.volume[_at(corner.x, corner.y, corner.z)], 0, "替换：源定义模型，手绘作废")

	var subtract := _obj_with_blocks()
	var m_sub := QVoxModelModifier.of(_sphere_model(10.0, 1))
	m_sub.combine = QVoxDomain.Combine.SUBTRACT
	subtract.modifiers = _chain([m_sub])
	var rs := QVoxEvalEngine.evaluate(subtract, QVoxEvalContext.make(GS, 0))
	assert_eq(rs.volume[_at(corner.x, corner.y, corner.z)], 9, "差集：源碰不到角落，石料留下")
	assert_eq(rs.solid_count(), subtract.count_solid(), "差集：源与石料不相交 → 结果等于石料")

	var intersect := _obj_with_blocks()
	var m_int := QVoxModelModifier.of(_sphere_model(10.0, 1))
	m_int.combine = QVoxDomain.Combine.INTERSECT
	intersect.modifiers = _chain([m_int])
	var ri := QVoxEvalEngine.evaluate(intersect, QVoxEvalContext.make(GS, 0))
	assert_eq(ri.solid_count(), 0, "交集：源与角落石料不相交 → 空")


## 链首直接是体素算子、且手绘体素为空 —— 输入是"整块空网格"，不是"没有体积"。
## 这是引擎里最容易踩的下标越界：所有 PcgDetail 都按 `for x in grid_size.x` 遍历。
func test_voxel_operator_on_empty_hand_drawn_grid() -> void:
	var obj := QVoxModel.new()
	obj.grid_size = GS
	var tint := PcgSurfaceTint.new()
	tint.material_ids = PackedInt32Array([1, 2])
	obj.modifiers = _chain([QVoxVolumeModifier.of(tint)])
	var res := QVoxEvalEngine.evaluate(obj, QVoxEvalContext.make(GS, 0))
	assert_eq(res.volume.size(), GS.x * GS.y * GS.z, "空手绘也必须补成全零整块，算子才不越界")
	assert_eq(res.solid_count(), 0, "空底上染色仍然是空")


# ----------------------------------------------------------------------------
# ② 域单向降级 + 链校验
# ----------------------------------------------------------------------------

func test_field_chain_is_downgraded_to_volume_automatically() -> void:
	var obj := QVoxModel.new()
	obj.grid_size = GS
	obj.modifiers = _chain([QVoxSdfModifier.of(_sphere(10.0, 3))])
	var res := QVoxEvalEngine.evaluate(obj, QVoxEvalContext.make(GS, 0))
	assert_eq(res.domain, QVoxDomain.Kind.FIELD, "链本身停在 FIELD（还能继续追加场域算子）")
	assert_true(res.field != null, "场域结果要留在结果里，便于换分辨率重光栅化")
	assert_eq(res.volume.size(), GS.x * GS.y * GS.z, "但体积已经被降级出来了")
	assert_eq(res.volume[_at(32, 16, 16)], 3, "球心是球体材质")
	assert_eq(res.volume[_at(1, 1, 1)], 0, "球外是空")


## 体力算子的输入是上一步累积出的体积。改完 SDF 之后再改体素 —— 顺序即语义。
func test_volume_operator_runs_after_sdf_downgrade() -> void:
	var obj := QVoxModel.new()
	obj.grid_size = GS
	var w := PcgWeather.new()
	w.strength = 1.0  # 阈值拉满（PcgWeather 内部上限 0.72）→ 保证一定挖得动
	w.cell = 2.0
	w.up_only = true
	w.min_exposure = 1
	w.protect_ground = true
	obj.modifiers = _chain([QVoxSdfModifier.of(_sphere(10.0, 1)), QVoxVolumeModifier.of(w)])
	var res := QVoxEvalEngine.evaluate(obj, QVoxEvalContext.make(GS, 20261007))

	var bare := PcgSdfGenerator.rasterize_field(_sphere(10.0, 1), GS)
	assert_eq(res.volume.size(), bare.size(), "体积尺寸与纯光栅化一致")
	var removed := 0
	var added := 0
	var removed_not_up_facing := 0
	for z in GS.z:
		for y in GS.y:
			for x in GS.x:
				var i := _at(x, y, z)
				if bare[i] > 0 and res.volume[i] == 0:
					removed += 1
					if y + 1 < GS.y and bare[_at(x, y + 1, z)] > 0:
						removed_not_up_facing += 1
				elif bare[i] == 0 and res.volume[i] > 0:
					added += 1
	assert_true(removed > 0, "strength 拉满且允许朝上侵蚀 → 必须真的蚀掉一些")
	assert_eq(added, 0, "风化只做减法，不得凭空加体素")
	assert_eq(removed_not_up_facing, 0, "up_only：被蚀的每一格，正上方原本必须是空的")


func test_chain_validation_catches_illegal_chains() -> void:
	var sdf := QVoxSdfModifier.of(_sphere(10.0, 1))
	var vol := QVoxVolumeModifier.of(PcgWeather.new())
	var legal: Array[QVoxModifier] = [sdf, vol]
	assert_eq(QVoxDomain.validate_chain(legal).size(), 0, "FIELD → VOXEL 是合法链")

	var climb: Array[QVoxModifier] = [sdf, vol, QVoxSdfModifier.of(_sphere(4.0, 2))]
	assert_true(QVoxDomain.validate_chain(climb).size() > 0, "域回升（VOXEL → FIELD）必须被拦下")

	var bad_combine := QVoxVolumeModifier.of(PcgWeather.new())
	bad_combine.combine = QVoxDomain.Combine.UNION
	assert_true(QVoxDomain.validate_chain([bad_combine]).size() > 0,
			"就地改写型算子只能是「替换」，并集无意义且必须被拦下")


func test_off_chain_nodes_are_marked() -> void:
	assert_false(PcgWfcOverlap.new().chainable(), "重叠式 WFC 要全局信息 + 内部可变缓存 → 链外")
	assert_true(PcgSurfaceTint.new().chainable(), "常规体素算子默认可进链")
	assert_true(PcgWeather.new().chainable(), "常规体素算子默认可进链")
	# 散布器连链条目基类都不是（PcgModel / PcgDetail）：它的输入输出是"世界坐标 + 变换"，
	# 属于链**之后**的摆放阶段。故判据不是 chainable() == false，而是"它根本不是链上类型"
	# —— 对它调 chainable() 是 "Nonexistent function"（见 PcgModel.chainable 的清单）。
	var scatter: RefCounted = PcgScatter.new()
	assert_false(scatter is PcgModel, "散布器不是体素生成算子 → 不进链")
	assert_false(scatter is PcgDetail, "散布器不是体素处理算子 → 不进链")


# ----------------------------------------------------------------------------
# ③ 无状态纯函数 + 输入签名增量复用
# ----------------------------------------------------------------------------

func test_incremental_reuse_and_signature_busting() -> void:
	var obj := QVoxModel.new()
	obj.grid_size = GS
	var tint := PcgSurfaceTint.new()
	tint.material_ids = PackedInt32Array([4, 5])
	tint.coverage = 1.0
	obj.modifiers = _chain([QVoxSdfModifier.of(_sphere(10.0, 1)), QVoxVolumeModifier.of(tint)])
	var ctx := QVoxEvalContext.make(GS, 7)

	var first := QVoxEvalEngine.evaluate(obj, ctx)
	var second := QVoxEvalEngine.evaluate(obj, ctx, first)
	assert_true(second == first, "签名与 epoch 都没变 → 原样返回上一次结果（同一对象，零遍历）")

	tint.coverage = 0.5
	var third := QVoxEvalEngine.evaluate(obj, ctx, first)
	assert_true(third != first, "算子参数变了，不得复用旧结果")
	assert_true(third.input_signature != first.input_signature, "输入签名要反映算子参数变化")

	# 旁通（enabled = false）改变的是"活跃算子序列"，同样必须算作变化
	obj.modifiers[1].enabled = false
	var fourth := QVoxEvalEngine.evaluate(obj, ctx, third)
	assert_true(fourth.input_signature != third.input_signature, "旁通一条算子必须改变签名")

	# epoch：外部世界变了（手绘写入 / 换了源算子）→ 即使签名不变也要重算
	ctx.epoch = 1
	var fifth := QVoxEvalEngine.evaluate(obj, ctx, fourth)
	assert_true(fifth != fourth, "epoch 变了必须重算，否则在途 worker 的旧结果会被当成果")


## 逐步骤判脏（§5.2）：改链尾一条 → 只从该条起重算，链首那条（最贵的程序化生成）不得重跑。
##
## 【为什么靠计数而不是"看产出对不对"】产出对不对在两种实现下完全一样（全量重算也得到同一个
## 体积）；能区分它们的唯一证据是"链首算子有没有被再调一次"，故这里数 build() 的调用次数。
func test_step_dirty_only_recomputes_the_tail() -> void:
	_CountingModel.builds = 0
	var obj := QVoxModel.new()
	obj.grid_size = GS
	var gen := _sphere_model(10.0, 1)
	var tint := PcgSurfaceTint.new()
	tint.material_ids = PackedInt32Array([2])
	tint.coverage = 1.0
	obj.modifiers = _chain([QVoxModelModifier.of(gen), QVoxVolumeModifier.of(tint)])
	var ctx := QVoxEvalContext.make(GS, 0)

	var first := QVoxEvalEngine.evaluate(obj, ctx)
	assert_eq(_CountingModel.builds, 1, "首次求值：源跑一次")
	assert_eq(first.states.size(), 3, "检查点 = 链长 + 1（含链的输入 states[0]）")

	tint.coverage = 0.5  # 只改链尾那条
	var second := QVoxEvalEngine.evaluate(obj, ctx, first)
	assert_eq(_CountingModel.builds, 1, "只改链尾：链首那条不得重跑（逐步骤判脏）")
	assert_true(second != first, "尾巴变了，结果必须是新的")
	assert_true(second.states[1] == first.states[1], "未变前缀的检查点原样接着用（不复制）")

	# 复用起点必须是"跑完前一条"的真实状态，而不是被就地改写型算子改过的共享缓冲
	var fresh := QVoxEvalEngine.evaluate(obj, ctx)
	assert_eq(_CountingModel.builds, 2, "全量重算（previous = null）当然要重跑源")
	assert_eq(fresh.states[1].volume, second.states[1].volume,
			"复用来的检查点与全量重算的前缀逐格一致（就地改写不得改到检查点）")
	assert_eq(fresh.volume, second.volume, "逐步骤判脏的产出与全量重算逐格一致")

	# 改链首（源）的参数 → 前缀作废，源必须重跑
	gen.radius = 12.0
	var third := QVoxEvalEngine.evaluate(obj, ctx, second)
	assert_eq(_CountingModel.builds, 3, "改链首：源必须重跑")
	assert_true(third.states[1] != second.states[1], "链首变了，前缀检查点不得再被沿用")
	assert_true(third.volume != second.volume, "源变了，产出必须跟着变")


## 取消 = 本次求值作废：截断的轨迹既不能冒充完整结果，也不能被当作复用起点。
func test_cancelled_result_is_never_reused() -> void:
	_CountingModel.builds = 0
	var obj := QVoxModel.new()
	obj.grid_size = GS
	var gen := _sphere_model(10.0, 1)
	var tint := PcgSurfaceTint.new()
	tint.material_ids = PackedInt32Array([2])
	obj.modifiers = _chain([QVoxModelModifier.of(gen), QVoxVolumeModifier.of(tint)])

	# 第二条跑完就取消（lambda 按值捕获，故用数组当可变盒子）
	var polls := [0]
	var ctx := QVoxEvalContext.make(GS, 0)
	ctx.is_cancelled_callable = func() -> bool:
		polls[0] += 1
		return polls[0] > 1
	var cut := QVoxEvalEngine.evaluate(obj, ctx)
	assert_eq(cut.input_signature, "", "取消的结果不得冒充完整结果（否则下一次会被当缓存命中）")
	assert_eq(cut.step_signatures.size(), 0, "取消的结果不得留下逐条签名")
	assert_eq(cut.states.size(), 0, "取消的结果不得留下截断的轨迹")

	# 拿它当 previous：必须全量重算，不能把截断的中间态当起点
	var full_ctx := QVoxEvalContext.make(GS, 0)
	var full := QVoxEvalEngine.evaluate(obj, full_ctx, cut)
	assert_eq(_CountingModel.builds, 2, "取消的结果不可复用 → 源重跑")
	assert_eq(full.states.size(), 3, "重新求值得到完整轨迹")
	assert_eq(full.volume, QVoxEvalEngine.evaluate(obj, full_ctx).volume, "重算结果与全量重算逐格一致")


func test_engine_is_stateless_across_objects() -> void:
	# 同一引擎跑两个对象，结果不得互相污染（引擎无状态、纯函数）
	var a := _obj_with_blocks()
	var b := QVoxModel.new()
	b.grid_size = GS
	b.fill_box(Vector3i(10, 10, 10), Vector3i(11, 11, 11), 6)
	var ctx := QVoxEvalContext.make(GS, 0)
	var ra := QVoxEvalEngine.evaluate(a, ctx)
	var rb := QVoxEvalEngine.evaluate(b, ctx, ra)
	assert_eq(rb.solid_count(), 8, "第二个对象的产出只含它自己的手绘体素")
	assert_eq(rb.volume[_at(2, 2, 2)], 0, "第一个对象的手绘不得泄漏进来")


# ----------------------------------------------------------------------------
# ④ 链的产出逐 chunk 供数（QVoxModelGenerator）
# ----------------------------------------------------------------------------

func test_generator_slices_match_engine_volume_exactly() -> void:
	var obj := _obj_with_blocks()
	obj.modifiers = _chain([QVoxSdfModifier.of(_sphere(10.0, 2))])
	var gen := QVoxModelGenerator.new()
	gen.object = obj
	gen.eval_seed = 3
	gen.set_grid_size(GS)

	var expect := QVoxEvalEngine.evaluate(obj, QVoxEvalContext.make(GS, 3)).volume
	var chunk := gen.generate(Vector3i.ZERO)
	assert_eq(chunk.size(), VoxelChunk.CHUNK_VOLUME, "chunk 缓冲长度固定")

	var mismatch_a := 0
	for z in VoxelChunk.CHUNK_SIZE:
		for y in VoxelChunk.CHUNK_SIZE:
			for x in VoxelChunk.CHUNK_SIZE:
				if chunk[VoxelChunk.buf_index(x, y, z)] != expect[_at(x, y, z)]:
					mismatch_a += 1
	assert_eq(mismatch_a, 0, "chunk (0,0,0) 必须与引擎体积逐格一致")

	# 第二个 chunk：切片偏移写错时第一个 chunk 仍会通过，故必须验第二块
	var side := VoxelChunk.CHUNK_SIZE
	var chunk_b := gen.generate(Vector3i(1, 0, 0))
	var mismatch_b := 0
	for z in side:
		for y in side:
			for x in side:
				if chunk_b[VoxelChunk.buf_index(x, y, z)] != expect[_at(x + side, y, z)]:
					mismatch_b += 1
	assert_eq(mismatch_b, 0, "chunk (1,0,0) 必须与引擎体积对应区段逐格一致")

	# 网格之外（gs.x = 64，chunk 3 从 96 开始）必须全空，而不是回绕成别的块
	var far := gen.generate(Vector3i(3, 0, 0))
	assert_eq(far.size(), VoxelChunk.CHUNK_VOLUME, "越界 chunk 也要返回对齐长度")
	var far_solid := 0
	for m in far:
		if m != 0:
			far_solid += 1
	assert_eq(far_solid, 0, "越界 chunk 必须全空")


func test_generator_lod_and_empty_source() -> void:
	var obj := _obj_with_blocks()
	obj.modifiers = _chain([QVoxSdfModifier.of(_sphere(10.0, 2))])
	var gen := QVoxModelGenerator.new()
	gen.object = obj
	gen.set_grid_size(GS)
	var grid := VoxelChunkGenerator.LOD_BLOCK_SIZE
	var lod := gen.generate(Vector3i.ZERO, 1)
	assert_eq(lod.size(), grid * grid * grid, "LOD 块缓冲长度 = LOD_BLOCK_SIZE³")
	var solid := 0
	for m in lod:
		if m > 0:
			solid += 1
	assert_true(solid > 0, "LOD1 采样球体应有实心格")

	# 空对象（空链 + 无手绘）：必须返回全空缓冲，而不是越界崩溃
	var blank := QVoxModel.new()
	blank.grid_size = GS
	var gen_blank := QVoxModelGenerator.new()
	gen_blank.object = blank
	gen_blank.set_grid_size(GS)
	var buf := gen_blank.generate(Vector3i.ZERO)
	assert_eq(buf.size(), VoxelChunk.CHUNK_VOLUME, "空源也要返回对齐长度")
	var blank_solid := 0
	for m in buf:
		if m != 0:
			blank_solid += 1
	assert_eq(blank_solid, 0, "空源必须全空")

	# 无源（object = null）：同样全空，不崩
	var gen_none := QVoxModelGenerator.new()
	gen_none.set_grid_size(GS)
	var buf2 := gen_none.generate(Vector3i.ZERO)
	assert_eq(buf2.size(), VoxelChunk.CHUNK_VOLUME, "无源也要返回对齐长度")
