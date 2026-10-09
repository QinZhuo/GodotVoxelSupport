class_name QVoxEvalEngine
extends RefCounted

## 求值引擎 —— 把一条修改器链跑成一块体素体积（或一棵 Sdf 树）。
##
## 【无状态、纯函数】引擎不持有对象引用、不订阅信号、不缓存上次结果。`evaluate()` 是
## 一个静态函数：同 (对象, 上下文) 恒得同一结果。于是它天然可放进 worker 线程、可并行、
## 可被测试逐参数比对。增量复用靠调用方把上一次的结果当入参传回（见 evaluate 的 previous），
## 而不是靠引擎自己记。
##
## 【为什么"无状态"是硬要求】一旦引擎缓存结果，它就必须知道"什么时候脏了"——于是要订阅
## 对象的信号、要处理线程归属、要在多对象之间分桶。这些都是纯函数不需要付出的代价，
## 而"谁改了什么"这个问题在编辑器里本来就有明确答案（改动命令知道它动了哪一条修改器）。
##
## 【增量复用 = 逐步骤判脏】调用方把上一次结果传回来时，引擎比对两半签名（inputs_key +
## 逐条 signature()），从**最长公共前缀**的检查点接着跑（见 evaluate 与 QVoxEvalResult.states）：
## 改链尾一条就只重算那一条之后的部分，链首那条最贵的程序化生成完全不重跑（§5.2 / §4.2 第 3 条）。
##
## 【域与降级】链的域只能单向降级（见 QVoxDomain）。引擎负责在需要的位置**自动插入**降级：
##   ① FIELD → VOXEL：把折叠好的 Sdf 树交给 PcgSdfGenerator.rasterize_field() 采样成体积；
##   ② VOXEL → MESH：网格算子（预留，见 mesh_ops）。
## 用户看不见降级点，只说"我在这儿加个侵蚀"，引擎自己知道那意味着"先把前面的场光栅化"。
##
## 【手绘体素（blocks）在链里的位置】blocks 是链的**输入/种子**，不是链的一环（见 QVoxModel）。
## 于是链首那一条的 combine 决定"链的产出与手绘体素怎么合"：
##   REPLACE       → 链的产出替换手绘体素（"这条 SDF 定义模型，手绘作废"）
##   UNION         → 并进手绘体素（"手绘一块石头，再长出一个球"）
##   SUBTRACT      → 从手绘体素里挖掉（"手绘一块石头，用 SDF 掏个洞"）
##   INTERSECT     → 只保留两者重叠（"用 SDF 当裁刀切手绘体素"）
##   SMOOTH_UNION  → 场内部正常平滑；与**离散**的手绘体素相合时退化为 UNION（见 _combine_volume）
## 这条规则让"手绘 + 程序化"第一次可以混着用，而不是二选一。
##
## 【FIELD 段怎么折叠】链上第 i 条修改器"如何并进已累积的结果"就是它的 combine，
## 于是线性链天然表达一棵左结合二叉树（SdfUnion / SdfSubtract / …），用户不必理解树。
## 组合算子仍留给"一个修改器内部本来就是一棵子树"的场合（十块拼成的岩石当整体被剪切）。
##
## 【树形求值：自底向上 + 紧致盒（DESIGN §2.3）】世界是一棵树，"一条链"只是树上**一个节点**的
## 局部计算。于是求值分两层：
##     eval(node) → 该节点在**自己局部盒**里的体积 + 该盒左下角在父画布里的偏移（result.origin）
##     QVoxModel: blocks → 密集体积 → 依次应用自己的链（含重排 / 平移，可改盒尺寸与摆放）
##     QVoxGroup: 把可见子节点的结果按各自 origin 并进"子树并集包围盒"，再依次应用自己的链
## 关键在**紧致盒**：组的中间体积取子树内容的并集包围盒，而不是世界级画布 —— 于是"组里只有
## 两个小模型"不会付整张 512³ 画布的代价（那是一次 537 MB 的分配），而"组的内存成本为零"
## 这条承诺才成立（组自己不存体素）。
##
## 【为什么结果要自带 origin，而不是"直接给一张父画布尺寸的体积"】摆放是链上平移条目的产出
## （见 PcgTransform.origin_delta），若求值时就把它烘进一张大体积，那"组里有几个模型、各自
## 挪了多远"就决定了组的内存；自带 origin 则每个子结果只占自己那一小块，合成时才按偏移对齐。
##
## 【为什么树的合成不走 _combine_volume】那个函数要求两个操作数**同尺寸同原点**（它按下标一一
## 对应），而树上两个子节点的盒尺寸与原点都可能不同。故树的合成是"按偏移对齐的合并"（_merge），
## 只有"链内两个同盒体积"才用 _combine_volume。


## 【结果类型为什么是独立文件而不是内部类】设计文档里写作 `QVoxEvalEngine.Result`，但内部类
## 无法被其它脚本当作类型标注（`previous: QVoxEvalEngine.Result` 不成立），而调用方恰恰需要
## 用它声明"我缓存着上一次的结果"。故提成同级文件 QVoxEvalResult，代价是名字长一点。


## 求值：把对象的手绘体素 + 修改器链跑成结果。
##
## 【previous 的用法】把上一次的结果原样传回来，两种复用方式、代价依次递增：
##   ① 签名与 epoch 都没变 → 直接返回它（同一对象，一次遍历都不做）；
##   ② 只有链尾若干条变了 → 从**最长公共前缀**的检查点接着跑（见「逐步骤判脏」）。
## 连"改都没改"因此是零成本，而"改了链尾一条"只需重算那一条之后的部分。传 null 即强制全量重算。
##
## 【为什么同时比对 epoch】签名只反映"输入变了没有"，而 epoch 反映"这次请求属于哪一版"。
## 主线程改了参数、在途 worker 拿着旧结果回来时，epoch 不同即可判定作废。
##
## 【逐步骤判脏（§5.2 / §4.2 第 3 条）】每条修改器的 signature() 只随它**自己**的字段变
## （见 QVoxModifier），于是"改第 k 条"必然表现为"前 k 条签名一字不差"。引擎据此把上一次结果里的
## 检查点 states[k] 当成本次求值的起点：第 k 条之前的算子（含昂贵的程序化生成 / 场光栅化）一律
## 不重跑 —— 判脏因此不是"整链重算"与"零成本"的二选一，而是"只重算变了的尾巴"。
##
## 【为什么不用"遇到第一条不同的就全丢"】那正是"改链尾一条也要重跑整条链"的代价，而链首往往
## 恰好是最贵的一条（程序化生成整块体积）。复用最长公共前缀把代价压到"尾巴有多长"。
static func evaluate(obj: QVoxModel, ctx: QVoxEvalContext,
		previous: QVoxEvalResult = null) -> QVoxEvalResult:
	var keys := inputs_key(obj, ctx)
	var sigs := step_signatures(obj)
	var sig := _join_signature(keys, sigs)
	# 【空签名永不命中缓存】obj == null（keys 为空）与"上一次被取消"（签名被清空，见循环尾）都会
	# 得到空签名；若不做这一层，两个空签名会被判成"一模一样"而互相顶替。
	if previous != null and not sig.is_empty() \
			and previous.input_signature == sig and previous.epoch == ctx.epoch:
		return previous

	var gs := ctx.grid_size
	var res := _new_result(gs, keys, sigs, ctx)
	if obj == null or gs.x <= 0 or gs.y <= 0 or gs.z <= 0:
		return res
	# base 传空数组（而不是 obj.to_volume()）是刻意的：链不需要左操作数时就不该付摊平稀疏块的代价，
	# 由 _current() 在真正需要时按 acc → base → obj.to_volume() 的次序现取。
	return _run_chain(res, obj, PackedInt32Array(), obj.active_modifiers(), keys, sigs, gs, ctx, previous)


# ----------------------------------------------------------------------------
# 树形求值（自底向上 + 紧致盒）
# ----------------------------------------------------------------------------

## 树形求值：任一节点 → 它**自己局部盒**里的体积（+ 在父画布里的摆放 origin）。
##
## 【为什么模型走 evaluate() 而不是重写一遍】模型的"局部盒"就是它自己的 grid_size，
## 而"父画布偏移"就是它的 position —— 两者都是 evaluate() 之外的信息，故这里只做转发与补填。
## 于是"一条链怎么跑"全项目只有一份实现，树形层只是它的编排。
##
## 【previous 的含义】对模型 = 该模型上一次的链求值结果；对组 = 该组上一次的合成结果
## （见 _evaluate_group 的输入键：它由各子结果的签名拼成，故任何一个子节点变了都会失配）。
static func evaluate_node(node: QVoxNode, ctx: QVoxEvalContext,
		previous: QVoxEvalResult = null, cache: QVoxEvalCache = null) -> QVoxEvalResult:
	if node == null:
		return QVoxEvalResult.new()
	# 可见性沿树继承：父节点不可见 → 整棵子树不参与求值（父的合成循环根本不会走到这里，
	# 但直接调用本函数时也要成立，否则"隐藏的节点"会从别的入口漏进画面）。
	if not node.visible:
		return QVoxEvalResult.new()
	if node.is_model():
		var m := node as QVoxModel
		# origin 不必在这里补填：摆放已是链上的平移条目，_run_chain 已把它写进结果。
		return evaluate(m, ctx.at_grid_size(m.grid_size), previous)
	return _evaluate_group(node as QVoxGroup, ctx, previous, cache)


## 世界级求值：把所有顶层节点按 position / combine 合成进世界盒。
##
## 【世界盒也是紧致的】顶层节点同样按"内容并集包围盒"合成 —— 于是"世界"只是树的根，
## 不是一张预分配的画布。代价是"世界原点"不一定落在返回体积的 (0,0,0)：结果自带的
## origin 就是世界原点在返回体积里的位置（常为负或零）。
##
## 【为什么没有 previous 参数，而是要一个 cache】世界级结果由消费方一次性消费，而"整世界"的
## 复用其实等价于"每个节点各自复用"—— 把逐节点缓存传进来即可，不必为整世界再维护一份签名。
## cache 为 null 时退化为"每次都全量重算"（正确但慢，仅适合测试与小世界）。
static func evaluate_world(world: QVoxWorld, ctx: QVoxEvalContext,
		cache: QVoxEvalCache = null) -> QVoxEvalResult:
	if world == null:
		return QVoxEvalResult.new()
	var comp := _composite(world.nodes, ctx, cache)
	var res := QVoxEvalResult.new()
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	res.origin = comp["lo"]
	res.input_signature = comp["key"]
	res.epoch = ctx.epoch
	return res


## 链的输出盒尺寸 —— "这条链跑完，模型是多大"。
##
## 【为什么能纯函数算出来，而不必真的跑一遍】只有重排型条目会改盒尺寸（就地改写型不得改尺寸，
## 见 PcgDetail 契约），故只需沿链把 reshape 的尺寸映射叠起来。UI 据此在**求值之前**把
## `VoxelData.grid_size` 同步成"求值后的尺寸"，生成器据此知道该产出多大的体积。
static func output_grid_size(mods: Array, base: Vector3i) -> Vector3i:
	var size := base
	for item in mods:
		var m: QVoxModifier = item
		if m == null or not m.is_active() or not m.is_reshape():
			continue
		var t := m.op() as PcgTransform
		if t != null:
			size = t.output_size(size)
	return size


## 建一个空结果（公共字段一次填齐，树形与单模型两条路径共用）。
static func _new_result(gs: Vector3i, keys: String, sigs: PackedStringArray,
		ctx: QVoxEvalContext) -> QVoxEvalResult:
	var res := QVoxEvalResult.new()
	res.grid_size = gs
	res.input_signature = _join_signature(keys, sigs)
	res.inputs_key = keys
	res.step_signatures = sigs
	res.epoch = ctx.epoch
	return res


## 跑一条链。obj 与 base 二选一：模型路径给 obj（base 留空，按需摊平手绘体素），
## 组路径给 base（组不存体素，obj 为 null）。两者都为空 = 链的输入就是"空"。
static func _run_chain(res: QVoxEvalResult, obj: QVoxModel, base: PackedInt32Array,
		mods: Array[QVoxModifier], keys: String, sigs: PackedStringArray,
		gs: Vector3i, ctx: QVoxEvalContext, previous: QVoxEvalResult) -> QVoxEvalResult:
	var total := maxi(mods.size(), 1)

	# ---- ⓪ 复用：从上一次结果里最靠后的可用检查点接着跑 ----
	#
	# 【前缀检查点为什么可以共享引用】states[start] 记的是"跑完前 start 条"的结果，而本次链的
	# 前 start 条与它逐条等价（见 _resume_index 的判据）→ 那份状态就是本次的前缀，不必复制。
	# 就地改写型算子只会吃 acc（下一行的**副本**），故原检查点不会被改到。
	var start := _resume_index(previous, ctx, keys, sigs, mods)
	var field: Sdf = null
	var acc := PackedInt32Array()
	var degraded := false
	# 当前盒尺寸：随重排型条目变化（见 StepState.box）。就地改写型算子必须拿到**当前**尺寸，
	# 否则"先平铺再风化"这类链会把风化算到错误的盒上（按下标遍历整块 → 直接越界）。
	var box := gs
	# 当前摆放偏移：随平移条目变化（见 StepState.shift）。与 box 一样属于累积状态，故检查点一起存。
	var shift := Vector3i.ZERO
	if start > 0:
		var st: QVoxEvalResult.StepState = previous.states[start]
		for i in start:
			res.states.append(previous.states[i])
		res.states.append(st)
		field = st.field
		degraded = st.degraded
		box = st.box
		shift = st.shift
		acc = st.volume.duplicate()
	else:
		# states[0] = 链的输入（手绘体素 + 空场）。没有它，"states[i] = 跑完前 i 条"这条
		# 一一对应就从第一步起错位，_resume_index 的自洽性检查会因此永远判 0。
		res.states.append(_snapshot(field, acc, degraded, box, shift))
	var lead := _lead_combine(mods)
	var done := start

	# ---- ① 前向单趟：FIELD 折叠 → 自动降级 → VOXEL 改写 ----
	#
	# 【为什么合成一趟，而不是"先折完场、再跑体素"】复用点可能落在 FIELD 段**中间**，于是两者必须
	# 能被同一条循环从中途接上：分成两趟就无法表达"从第 3 条（还在场里）接着折"。语义一字未变：
	# 域只能单向降级（QVoxDomain.validate_chain），故 FIELD 必然连续地位于链首，循环遇到第一条
	# 非 FIELD 条目即进入降级分支；后面的 FIELD（非法链）在这里被跳过。
	#
	# 【active_modifiers() 已滤掉空条目】故循环里每条都必有算法核，逐条检查点与逐条签名一一对应
	# （_resume_index 依赖这个一一对应）。
	for i in mods.size():
		if i < start:
			continue
		var m := mods[i]
		var op := m.op()
		var d := m.domain()
		if d == QVoxDomain.Kind.MESH:
			# MESH 段（预留）：只登记算子，不改累积状态 —— 但检查点照样拍，好让
			# "states[i] 与第 i 条一一对应"这条不变量对任何链都成立（_resume_index 依赖它）
			res.mesh_ops.append(op)
		elif d == QVoxDomain.Kind.FIELD:
			# degraded 之后还有 FIELD = 域回升（非法链）：什么都不改，报错交给 validate_chain
			if not degraded:
				field = _fold_sdf(field, op as Sdf, m.combine, m.blend)
		else:
			# ---- ② 降级 ①：FIELD → VOXEL ----
			if not degraded:
				degraded = true
				if field != null:
					acc = _combine_volume(_current(obj, base, acc),
							PcgSdfGenerator.rasterize_field(field, box), lead)
			if m.is_reshape():
				# ---- 重排型（PcgTransform）：整块重排，**盒尺寸随之改变** ----
				#
				# 【为什么它必须先降级】重排消费的是"已光栅化的当前累积结果"；上面那一步已保证
				# field 被物化进 acc，故这里只需取当前左操作数。
				#
				# 【为什么不必 duplicate】QVoxVoxelTransform 的 remap / repeat_volume 都**新建**
				# 输出数组（从不就地改写输入），故取到 acc 本身也是安全的。
				var t := op as PcgTransform
				if t == null:
					push_error("[QVox] 重排型修改器 %d 的核不是 PcgTransform" % i)
				else:
					var pair: Array = t.reshape(_current(obj, base, acc), box)
					acc = pair[0]
					box = pair[1]
					# 平移只挪摆放（reshape 对它是恒等），故位移单独累加 —— 见 PcgTransform 类头。
					shift += t.origin_delta()
			elif m.is_source():
				# 自足产出型（PcgModel）：自己造一整块新体积，可与既有结果做布尔
				acc = _combine_volume(_current(obj, base, acc), (op as PcgModel).build(box), m.combine)
			else:
				# 就地改写型（PcgDetail）：拿到整块体积自己决定怎么改，故合成方式只能是「替换」
				#
				# 【为什么空手绘体素也要补一块全零体积】链首直接是体素算子时，它的输入语义是
				# "整块网格"，而不是"没有体积"：所有 PcgDetail 的遍历都写成
				# `for x in grid_size.x: volume[index_of(...)]`，给它们一个 size 0 的数组就是按下标越界。
				# 而"空网格上长东西"本身是合法语义（染色 / 生成型算子都要能吃空底），故补零而不是跳过。
				if acc.is_empty():
					acc = _current(obj, base, acc)
					if acc.is_empty():
						acc = PcgModel.empty_volume(box)
				(op as PcgDetail).apply(acc, box, ctx.seed + m.seed)
		done += 1
		res.states.append(_snapshot(field, acc, degraded, box, shift))
		ctx.report(float(done) / float(total))
		if ctx.cancelled():
			# 取消 = 本次求值作废：截断的轨迹与体积都不能冒充完整结果去参与复用
			res.states.clear()
			res.step_signatures = PackedStringArray()
			res.input_signature = ""
			break

	# ---- ③ 降级 ②：链尾仍停在场里（整条链都是场算子） ----
	#
	# 【为什么降级要出现在两处】主循环里的降级是"遇到第一个体素域算子"时触发的；而一条**全是场算子**
	# 的链永远不会遇到它，可它同样必须物化成体积 —— 否则 res.volume 只剩手绘体素，调用方看不见链的
	# 产出（"场域结果要留在结果里，便于换分辨率重光栅化"说的正是这件事）。两处合成一份逻辑。
	#
	# 【检查点不必补拍】这一降级不对应任何一条修改器，故 states[链长] 仍然记着"还没降级"的场树；
	# 从那里复用时会走到这里、重新光栅化一次 —— 折场没白跑，光栅化本来就要跟着分辨率走。
	if not degraded and field != null:
		degraded = true
		acc = _combine_volume(_current(obj, base, acc),
				PcgSdfGenerator.rasterize_field(field, box), lead)

	# ---- ④ 只有手绘体素（空链 / 全旁通）：链的输入就是结果 ----
	if acc.is_empty():
		acc = _current(obj, base, acc)

	res.field = field
	res.volume = acc
	res.grid_size = box
	# 摆放 = 链上平移条目的累加。组的调用方再把"子树包围盒左下角"叠上去（见 _evaluate_group）。
	res.origin = shift
	res.domain = QVoxDomain.final_domain(mods)
	return res


## 链的**输入**键 —— 链之前的一切外部输入（不含逐条修改器签名）。
##
## 【为什么与逐条签名拆成两半】判脏要回答两个不同的问题：① "链之前的输入变了没有"（本函数）
## —— 变了则**所有**检查点作废（连 states[0] 都不再成立）；② "哪一条修改器变了"
## （step_signatures）—— 它定位复用起点。合成一个字符串只能回答"整链有没有变"。
##
## 【含 base_revision 而不是哈希体素】手绘编辑点自己知道它改了体素（QVoxVoxelEditCommand 封口时
## 自增 base_revision），而几百万个 int 的哈希本身就不便宜。故用版本号当"体素有没有变"的答案。
##
## 【含 block_size】它决定稀疏块的下标换算（QVoxBlockCodec）；换掉它等于换了一套存储布局。
##
## 【为什么还要含对象实例 id】签名是"**这个对象的**这次求值"的缓存键。base_revision 是
## **每对象各自**的手绘版本号：两个内容不同的对象完全可以同为 0（或恰好同值），只凭它
## 会把 A 的结果当成 B 的可复用结果 —— 于是"引擎无状态"被一句复用判断破坏，两个对象互相污染。
## 实例 id 是稳定且廉价的判别项，加进来即让缓存键天然按对象分桶。
static func inputs_key(obj: QVoxModel, ctx: QVoxEvalContext) -> String:
	if obj == null:
		return ""
	var parts := PackedStringArray()
	parts.append(str(obj.get_instance_id()))
	parts.append("%d,%d,%d" % [ctx.grid_size.x, ctx.grid_size.y, ctx.grid_size.z])
	parts.append(str(ctx.seed))
	parts.append(str(obj.block_size))
	parts.append(str(obj.base_revision))
	return "|".join(parts)


## 各参与条目的 signature()（与 active_modifiers() 一一对应）。
##
## 【为什么逐条留一份而不是只留总签名】"改第 k 条"要靠"前 k 条签名一字不差"来证明，而总签名
## 只能回答"整链变了没有"。这份数组与上一次结果的逐条比对，就是复用起点的判据（见 _resume_index）。
##
## 【signature() 已含 enabled / 算子实例 / 参数 / combine / blend / seed】见 QVoxModifier，
## 故旁通翻转、参数微调、顺序调整都会逐条反映出来。
static func step_signatures(obj: QVoxModel) -> PackedStringArray:
	var out := PackedStringArray()
	if obj == null:
		return out
	for m in obj.active_modifiers():
		out.append(m.signature())
	return out


## 输入签名 —— 参与判脏的**全部**外部输入（输入键 + 逐条签名）。
## 调用方只需比对它：同签名 + 同 epoch = 上一次结果可原样复用（见 evaluate）。
static func input_signature(obj: QVoxModel, ctx: QVoxEvalContext) -> String:
	return _join_signature(inputs_key(obj, ctx), step_signatures(obj))


## 把两半拼成完整签名。
static func _join_signature(keys: String, sigs: PackedStringArray) -> String:
	if sigs.is_empty():
		return keys
	return keys + "|" + "|".join(sigs)


# ----------------------------------------------------------------------------
# FIELD 段：折叠成一棵左结合 Sdf 树
# ----------------------------------------------------------------------------

## 把下一条 Sdf 子树按 combine 并进已累积的场。
##
## 【acc 为 null = 链首那条，combine 一律退化为"就是 next"】链首的 combine 语义与链中段不同：
## 它回答的是"这棵**整**场树最终怎么与手绘体素相合"（由 evaluate 的 lead 承接，见文件头），
## 而不是"怎么并进空场"。故四种 combine 在这里一律返回 next，绝不吞掉整棵树 ——
## 否则链首 combine = SUBTRACT / INTERSECT 会把 field 折成 null，第 ② 步的降级整段失效，
## 手绘体素原样残留（"用 SDF 当裁刀切手绘"这一条用法直接失灵）。
static func _fold_sdf(acc: Sdf, next: Sdf, combine: QVoxDomain.Combine, blend: float) -> Sdf:
	if acc == null:
		return next
	match combine:
		QVoxDomain.Combine.UNION:
			var u := SdfUnion.new()
			u.a = acc
			u.b = next
			return u
		QVoxDomain.Combine.SUBTRACT:
			var s := SdfSubtract.new()
			s.a = acc
			s.b = next
			return s
		QVoxDomain.Combine.INTERSECT:
			var i := SdfIntersect.new()
			i.a = acc
			i.b = next
			return i
		QVoxDomain.Combine.SMOOTH_UNION:
			var su := SdfSmoothUnion.new()
			su.a = acc
			su.b = next
			su.k = blend
			return su
	# REPLACE（含未知值）：新子树顶掉旧的
	return next


# ----------------------------------------------------------------------------
# VOXEL 段：两个体积的离散布尔
# ----------------------------------------------------------------------------

## 体积布尔。**空数组（size 0）表示"还没有既有体积"**：
##   空 ∖ b = 空、空 ∩ b = 空，其余（替换 / 并 / 平滑并）都取 b。
## 于是"手绘体素为空"不必特判，也省掉一次无谓的全量分配 + 扫描（512³ = 537 MB）。
##
## 【调用方要先过一遍 _left_operand】"acc 为空"在本函数里只被理解为"没有左操作数"，而"链首
## 直接是体素域算子"时真正的左操作数是**手绘体素**（见 _left_operand）—— 两者不能在这里合并，
## 否则本函数就要知道 QVoxModel 与链的位置，而它只需要知道两个体积。
##
## 【SMOOTH_UNION 为何退化成 UNION】平滑并需要**两个连续**操作数才能算过渡宽度，
## 而这里的一方是光栅化后的离散体素。场内部的平滑并照常生效（见 _fold_sdf），
## 只有"场与手绘体素相合"这一步没有连续语义可用，故退化为并 —— 与
## QVoxDomain.validate_chain 禁止体素域使用 SMOOTH_UNION 是同一条理由。
static func _combine_volume(a: PackedInt32Array, b: PackedInt32Array,
		combine: QVoxDomain.Combine) -> PackedInt32Array:
	if combine == QVoxDomain.Combine.REPLACE:
		return b
	if a.is_empty():
		if combine == QVoxDomain.Combine.SUBTRACT or combine == QVoxDomain.Combine.INTERSECT:
			return a
		return b
	if b.is_empty():
		return PackedInt32Array() if combine == QVoxDomain.Combine.INTERSECT else a
	if a.size() != b.size():
		push_error("[QVox] 体积布尔要求同尺寸，收到 %d 与 %d" % [a.size(), b.size()])
		return a
	var n := a.size()
	var out := PackedInt32Array()
	out.resize(n)
	match combine:
		QVoxDomain.Combine.SUBTRACT:
			for i in n:
				out[i] = 0 if b[i] > 0 else a[i]
		QVoxDomain.Combine.INTERSECT:
			for i in n:
				out[i] = a[i] if b[i] > 0 else 0
		_:
			# UNION / SMOOTH_UNION：空缺处由 b 补上（a 实心处保留 a 的材质）
			for i in n:
				var av := a[i]
				out[i] = av if av != 0 else b[i]
	return out


# ----------------------------------------------------------------------------
# 判脏与检查点（§5.2 的逐步骤判脏）
# ----------------------------------------------------------------------------

## 上一次结果里**最靠后的可用检查点**下标。返回 k = "前 k 条与本链逐条等价，可从 states[k] 接着跑"。
##
## 【三个前提，缺一即返回 0（全量重算）】
##   ① epoch 相同：与"整链复用"同一条理由 —— 上一次求值的产物可能是在输入被改到一半时读出来的
##      （torn read），它的检查点同样不可信；
##   ② inputs_key 相同：链**之前**的输入（手绘体素 / 网格 / 种子 / 块大小）没变，否则连
##      states[0] 都不成立，全部检查点作废；
##   ③ 逐条签名相同的前缀 = k：第 k 条就是"第一条变了的"，它之前的状态天然与本次链等价。
##
## 【为什么要"最靠后"】k 越大、要重跑的尾巴越短：改链尾一条参数时 k = 链长 - 1，链首那条
## （往往是最贵的程序化生成）完全不重算 —— 这正是 §5.2 要的逐步骤判脏。
##
## 【链变长 / 变短都成立】n 取两个逐条签名数组的较短者：末尾**追加**一条时全部旧步骤都复用
## （k = 旧链长），中间**删掉**一条时在删除点停下（那里的状态就是删除前的前缀）。
static func _resume_index(previous: QVoxEvalResult, ctx: QVoxEvalContext, keys: String,
		sigs: PackedStringArray, mods: Array[QVoxModifier]) -> int:
	if previous == null or previous.inputs_key != keys or previous.epoch != ctx.epoch:
		return 0
	# 轨迹自洽性：states[i] 与第 i 条一一对应。取消过的结果会被清空（见 evaluate），
	# 但"清空"这件事不该只由写入方保证 —— 这里再验一次，免得截断的轨迹被当起点。
	if previous.states.size() != previous.step_signatures.size() + 1:
		return 0
	var n := mini(previous.step_signatures.size(), sigs.size())
	var k := 0
	while k < n:
		if previous.step_signatures[k] != sigs[k]:
			break
		if mods[k].domain() == QVoxDomain.Kind.MESH:
			break  # MESH 段是预留（无实现、无检查点），故不越过它续跑
		k += 1
	return k


## 链首那条 FIELD 条目的 combine —— 它回答"整棵场树怎么与手绘体素相合"（见文件头），
## 与"它怎么并进已累积的场"是两件事（后者由 _fold_sdf 按同一条 combine 处理链中段）。
##
## 【为什么算成链的纯函数，而不是折叠循环里的"第一次遇到"】复用可能从 FIELD 段**中间**开始，
## 那时循环里已经看不到链首那条了，而降级点仍然要用它。纯函数则与"从哪儿开始跑"无关。
static func _lead_combine(mods: Array[QVoxModifier]) -> QVoxDomain.Combine:
	for m in mods:
		if m.domain() == QVoxDomain.Kind.FIELD:
			return m.combine
	return QVoxDomain.Combine.REPLACE


## 当前的**左操作数**：acc 为空表示"还没有既有体积"，此时左操作数就是链的输入。
##
## 【链的输入有三层来源，按代价从低到高】① acc 本身（链已经产出过东西）；② base（组路径：
## 子树的合并结果）；③ obj.to_volume()（模型路径：把稀疏手绘块摊平成密集体积）。
## 前两层是白拿的，第三层才要付摊平 + 全量分配的代价，故放在最后 —— 于是"链自己造了整块体积"
## 的场合（绝大多数）一次都不摊平手绘体素。
##
## 【为什么必须显式取一次链的输入】链首直接是体素域算子时，若把空数组当左操作数，
## _combine_volume 只能按"没有左操作数"退化：
##   UNION    → 取 b，手绘石料凭空消失（退化成 REPLACE）
##   SUBTRACT → 返回空，"用体素算子从手绘里挖一块"根本挖不动
## 而文件头承诺的"手绘 + 程序化可以混着用"恰恰就是这两种用法。场域链首没有这个问题
## （降级那一步显式把链的输入当左操作数），体素域链首必须在这里补齐同一条规则。
##
## 【手绘本身为空时保持空】那是真的没有左操作数，_combine_volume 的退化规则才是对的
## （SUBTRACT / INTERSECT → 空，其余 → b），也省掉一次全量分配 + 扫描。
static func _current(obj: QVoxModel, base: PackedInt32Array, acc: PackedInt32Array) -> PackedInt32Array:
	if not acc.is_empty():
		return acc
	if not base.is_empty():
		return base
	return obj.to_volume() if obj != null else PackedInt32Array()


## 给当前累积状态拍一张检查点（供下一次求值复用，见 QVoxEvalResult.states 的内存账）。
##
## 【体积为什么必须 duplicate()】PackedInt32Array 的赋值是**共享缓冲**：后续的就地改写型算子
## （PcgDetail.apply）会顺着共享缓冲改到已拍下的检查点，于是复用起点记的是"后来"的状态。
## 场树不必复制 —— _fold_sdf 只造新节点，从不改旧节点。
static func _snapshot(field: Sdf, acc: PackedInt32Array,
		degraded: bool, box: Vector3i, shift: Vector3i) -> QVoxEvalResult.StepState:
	var s := QVoxEvalResult.StepState.new()
	s.field = field
	s.degraded = degraded
	s.box = box
	s.shift = shift
	if not acc.is_empty():
		s.volume = acc.duplicate()
	return s


# ----------------------------------------------------------------------------
# 树形合成：按摆放对齐的合并（DESIGN §2.3 的紧致盒）
# ----------------------------------------------------------------------------

## 一个组 → 它局部盒里的体积 + 在父画布里的 origin。
##
## 【组的链作用于"已经摆好的子树合并结果"】顺序即语义：先按各子结果的 origin 合成子树
## （这是组的"内容"），再依次应用组自己的滤镜（这是"在层级上挂滤镜"）。
static func _evaluate_group(g: QVoxGroup, ctx: QVoxEvalContext,
		previous: QVoxEvalResult, cache: QVoxEvalCache) -> QVoxEvalResult:
	var comp := _composite(g.child_nodes, ctx, cache)
	var box: Vector3i = comp["size"]
	var keys: String = comp["key"]
	var sigs := _step_signatures_of(g.active_modifiers())
	var sig := _join_signature(keys, sigs)
	if previous != null and not sig.is_empty() \
			and previous.input_signature == sig and previous.epoch == ctx.epoch:
		return previous

	var res := _new_result(box, keys, sigs, ctx)
	if box.x <= 0 or box.y <= 0 or box.z <= 0:
		# 组里没有任何可见内容（或全被差集挖空）：结果为空盒，链无从作用，摆放也无从谈起
		res.domain = QVoxDomain.final_domain(g.active_modifiers())
		return res
	var vol: PackedInt32Array = comp["volume"]
	var lo: Vector3i = comp["lo"]
	_run_chain(res, null, vol, g.active_modifiers(), keys, sigs, box,
			ctx.at_grid_size(box), previous)
	# 组的摆放 = 子树包围盒左下角 + 链上平移条目（_run_chain 已把后者写进 res.origin）
	res.origin += lo
	return res


## 把一组节点按各自结果的 origin 合成成一块**紧致**体积。
## 返回 {"volume", "lo", "size", "key"}：
##   volume —— 合并结果（size 0 = 没有任何可见内容）
##   lo     —— 本体积的 (0,0,0) 在**父画布**里的偏移（= 各子盒左下角的最小值）
##   size   —— 紧致盒尺寸（= 各子盒的并集包围盒）
##   key    —— 输入键（各子结果签名 + 摆放），供上层判脏
##
## 【为什么树这一层恒为并集】"我怎么并进父画布"是个**父侧**问题：要回答它，得同时看见
## 父已累积的内容与本子节点的内容，而子节点的链只能看见自己（链上的 combine 是"并进本链
## 已累积的结果"，两回事）。既然摆放已经入链，跨节点的差集 / 交集就不再有载体 —— 于是
## 这里退化成纯并集，而"挖空"改由节点自己的链表达（链上的差集条目）。
static func _composite(nodes: Array, ctx: QVoxEvalContext,
		cache: QVoxEvalCache) -> Dictionary:
	var acc := PackedInt32Array()
	var lo := Vector3i.ZERO
	var size := Vector3i.ZERO
	var parts := PackedStringArray()
	for item in nodes:
		var c: QVoxNode = item
		if c == null or not c.visible:
			continue
		var cr := evaluate_node(c, ctx, cache.previous_of(c) if cache != null else null, cache)
		if cache != null:
			cache.store(c, cr)
		# 【为什么要含子结果的签名】组的输入 = "子树合并结果"，而合并结果只能靠各子结果的身份
		# 与参数间接表达（哈希整块体积既贵又没必要）。任何一个子节点变了，这里就失配。
		# 摆放取 cr.origin（链的产出），不再是节点字段 —— 所以"链上挪了一下"也在这里失配。
		parts.append("%s@%d,%d,%d" % [cr.input_signature,
				cr.origin.x, cr.origin.y, cr.origin.z])
		if cr.volume.is_empty() or cr.grid_size.x <= 0:
			continue
		var merged := _merge(acc, lo, size, cr.volume, cr.origin, cr.grid_size)
		acc = merged["volume"]
		lo = merged["lo"]
		size = merged["size"]
	return {"volume": acc, "lo": lo, "size": size, "key": "|".join(parts)}


## 各条目的 signature()（与 active_modifiers() 一一对应）。组路径用。
static func _step_signatures_of(mods: Array[QVoxModifier]) -> PackedStringArray:
	var out := PackedStringArray()
	for m in mods:
		out.append(m.signature())
	return out


## 把一个子体积**并**进累积盒。**盒可能因此扩大** —— 紧致盒取各子盒的并集包围盒。
##
## 【与 _combine_volume 的分工】那个函数要求两个操作数同尺寸同原点（链内语义）；本函数处理
## "尺寸与原点都可能不同"的树合成，故必须按偏移对齐着搬（见 _blit）。
##
## 【为什么没有 combine 参数】见 _composite：树这一层恒为并集。于是"第一个有效子节点要特判
## 差集 / 交集"（空 ∖ b = 空）这条链首规则在这里也不再需要 —— 空盒并 b 就是 b。
static func _merge(a: PackedInt32Array, a_lo: Vector3i, a_size: Vector3i,
		b: PackedInt32Array, b_lo: Vector3i, b_size: Vector3i) -> Dictionary:
	if b.is_empty() or b_size.x <= 0 or b_size.y <= 0 or b_size.z <= 0:
		return {"volume": a, "lo": a_lo, "size": a_size}
	if a.is_empty() or a_size.x <= 0 or a_size.y <= 0 or a_size.z <= 0:
		return {"volume": b.duplicate(), "lo": b_lo, "size": b_size}
	var lo := Vector3i(mini(a_lo.x, b_lo.x), mini(a_lo.y, b_lo.y), mini(a_lo.z, b_lo.z))
	var hi := Vector3i(
			maxi(a_lo.x + a_size.x - 1, b_lo.x + b_size.x - 1),
			maxi(a_lo.y + a_size.y - 1, b_lo.y + b_size.y - 1),
			maxi(a_lo.z + a_size.z - 1, b_lo.z + b_size.z - 1))
	var size := hi - lo + Vector3i.ONE
	var out := PcgModel.empty_volume(size)
	_blit(out, size, lo, a, a_lo, a_size)
	_fill_gaps(out, size, lo, b, b_lo, b_size)
	return {"volume": out, "lo": lo, "size": size}


## 把 src 的非空体素按偏移搬进 out（src 覆盖不到的格子保持 out 原样）。
static func _blit(out: PackedInt32Array, out_size: Vector3i, out_lo: Vector3i,
		src: PackedInt32Array, src_lo: Vector3i, src_size: Vector3i) -> void:
	if src.is_empty():
		return
	var off := src_lo - out_lo
	var sxy := src_size.x * src_size.y
	var oxy := out_size.x * out_size.y
	for z in src_size.z:
		var oz := off.z + z
		if oz < 0 or oz >= out_size.z:
			continue
		for y in src_size.y:
			var oy := off.y + y
			if oy < 0 or oy >= out_size.y:
				continue
			var srow := y * src_size.x + z * sxy
			var orow := oy * out_size.x + oz * oxy
			for x in src_size.x:
				var v := src[srow + x]
				if v != 0:
					out[orow + off.x + x] = v


## 把 b 补进 out 的**空缺处**（两者**同盒**，只是原点不同；out 已有的实心处保留自己的材质）。
##
## 【为什么不复用 _blit】_blit 是"谁后到谁说话"（后到的覆盖），并集要的是"先到的说话"
## （只填空缺）—— 两者对"b 实心且 out 也实心"这一格的处理正好相反，故各写一趟。
##
## 【为什么在这里重写一遍遍历，而不复用 _combine_volume】那个函数按下标一一对应（同原点），
## 而这里两个操作数原点不同 —— 必须逐格先算偏移再判。
static func _fill_gaps(out: PackedInt32Array, out_size: Vector3i, out_lo: Vector3i,
		b: PackedInt32Array, b_lo: Vector3i, b_size: Vector3i) -> void:
	if b.is_empty():
		return
	var off := b_lo - out_lo
	var bxy := b_size.x * b_size.y
	var oxy := out_size.x * out_size.y
	for z in b_size.z:
		var oz := off.z + z
		if oz < 0 or oz >= out_size.z:
			continue
		for y in b_size.y:
			var oy := off.y + y
			if oy < 0 or oy >= out_size.y:
				continue
			var brow := y * b_size.x + z * bxy
			var orow := oy * out_size.x + oz * oxy
			for x in b_size.x:
				var v := b[brow + x]
				if v != 0 and out[orow + off.x + x] == 0:
					out[orow + off.x + x] = v
