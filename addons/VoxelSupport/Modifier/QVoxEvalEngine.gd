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
## 【手绘体素（blocks）在链里的位置】blocks 是链的**输入/种子**，不是链的一环（见 QVoxObject）。
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
static func evaluate(obj: QVoxObject, ctx: QVoxEvalContext,
		previous: QVoxEvalResult = null) -> QVoxEvalResult:
	var gs := ctx.grid_size
	var keys := inputs_key(obj, ctx)
	var sigs := step_signatures(obj)
	var sig := _join_signature(keys, sigs)
	# 【空签名永不命中缓存】obj == null（keys 为空）与"上一次被取消"（签名被清空，见循环尾）都会
	# 得到空签名；若不做这一层，两个空签名会被判成"一模一样"而互相顶替。
	if previous != null and not sig.is_empty() \
			and previous.input_signature == sig and previous.epoch == ctx.epoch:
		return previous

	var res := QVoxEvalResult.new()
	res.grid_size = gs
	res.input_signature = sig
	res.inputs_key = keys
	res.step_signatures = sigs
	res.epoch = ctx.epoch

	if obj == null or gs.x <= 0 or gs.y <= 0 or gs.z <= 0:
		return res

	var mods := obj.active_modifiers()
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
	if start > 0:
		var st: QVoxEvalResult.StepState = previous.states[start]
		for i in start:
			res.states.append(previous.states[i])
		res.states.append(st)
		field = st.field
		degraded = st.degraded
		acc = st.volume.duplicate()
	else:
		# states[0] = 链的输入（手绘体素 + 空场）。没有它，"states[i] = 跑完前 i 条"这条
		# 一一对应就从第一步起错位，_resume_index 的自洽性检查会因此永远判 0。
		res.states.append(_snapshot(field, acc, degraded))
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
					acc = _combine_volume(_left_operand(obj, acc),
							PcgSdfGenerator.rasterize_field(field, gs), lead)
			if m.is_source():
				# 自足产出型（PcgModel）：自己造一整块新体积，可与既有结果做布尔
				acc = _combine_volume(_left_operand(obj, acc), (op as PcgModel).build(gs), m.combine)
			else:
				# 就地改写型（PcgDetail）：拿到整块体积自己决定怎么改，故合成方式只能是「替换」
				#
				# 【为什么空手绘体素也要补一块全零体积】链首直接是体素算子时，它的输入语义是
				# "整块网格"，而不是"没有体积"：所有 PcgDetail 的遍历都写成
				# `for x in grid_size.x: volume[index_of(...)]`，给它们一个 size 0 的数组就是按下标越界。
				# 而"空网格上长东西"本身是合法语义（染色 / 生成型算子都要能吃空底），故补零而不是跳过。
				if acc.is_empty():
					acc = _left_operand(obj, acc)
					if acc.is_empty():
						acc = PcgModel.empty_volume(gs)
				(op as PcgDetail).apply(acc, gs, ctx.seed + m.seed)
		done += 1
		res.states.append(_snapshot(field, acc, degraded))
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
		acc = _combine_volume(_left_operand(obj, acc),
				PcgSdfGenerator.rasterize_field(field, gs), lead)

	# ---- ④ 只有手绘体素（空链 / 全旁通）：blocks 就是结果 ----
	if acc.is_empty():
		acc = obj.to_volume()

	res.field = field
	res.volume = acc
	res.domain = QVoxDomain.final_domain(obj.modifiers)
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
static func inputs_key(obj: QVoxObject, ctx: QVoxEvalContext) -> String:
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
static func step_signatures(obj: QVoxObject) -> PackedStringArray:
	var out := PackedStringArray()
	if obj == null:
		return out
	for m in obj.active_modifiers():
		out.append(m.signature())
	return out


## 输入签名 —— 参与判脏的**全部**外部输入（输入键 + 逐条签名）。
## 调用方只需比对它：同签名 + 同 epoch = 上一次结果可原样复用（见 evaluate）。
static func input_signature(obj: QVoxObject, ctx: QVoxEvalContext) -> String:
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
## 否则本函数就要知道 QVoxObject 与链的位置，而它只需要知道两个体积。
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


## 体素布尔的**左操作数**：acc 为空表示"还没有既有体积"，此时左操作数就是手绘体素。
##
## 【为什么必须显式取一次手绘体素】链首直接是体素域算子时，若把空数组当左操作数，
## _combine_volume 只能按"没有左操作数"退化：
##   UNION    → 取 b，手绘石料凭空消失（退化成 REPLACE）
##   SUBTRACT → 返回空，"用体素算子从手绘里挖一块"根本挖不动
## 而文件头承诺的"手绘 + 程序化可以混着用"恰恰就是这两种用法。场域链首没有这个问题
## （降级那一步显式把 obj.to_volume() 当左操作数），体素域链首必须在这里补齐同一条规则。
##
## 【手绘本身为空时保持空】那是真的没有左操作数，_combine_volume 的退化规则才是对的
## （SUBTRACT / INTERSECT → 空，其余 → b），也省掉一次全量分配 + 扫描。
static func _left_operand(obj: QVoxObject, acc: PackedInt32Array) -> PackedInt32Array:
	if not acc.is_empty():
		return acc
	return obj.to_volume()


## 给当前累积状态拍一张检查点（供下一次求值复用，见 QVoxEvalResult.states 的内存账）。
##
## 【体积为什么必须 duplicate()】PackedInt32Array 的赋值是**共享缓冲**：后续的就地改写型算子
## （PcgDetail.apply）会顺着共享缓冲改到已拍下的检查点，于是复用起点记的是"后来"的状态。
## 场树不必复制 —— _fold_sdf 只造新节点，从不改旧节点。
static func _snapshot(field: Sdf, acc: PackedInt32Array,
		degraded: bool) -> QVoxEvalResult.StepState:
	var s := QVoxEvalResult.StepState.new()
	s.field = field
	s.degraded = degraded
	if not acc.is_empty():
		s.volume = acc.duplicate()
	return s
