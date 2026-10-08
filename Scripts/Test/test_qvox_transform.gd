extends TestCase

## 变换测试：纯重排数学（QVoxVoxelTransform）+ 链上的变换 / 摆放条目（PcgTransform / QVoxTransformModifier）。
##
## 【为什么这几层要一起测】变换最容易坏的不是数学，而是"尺寸怎么传下去"：核算出新盒尺寸 →
## 引擎把它记进结果 → 会话把 data.grid_size 对齐。任一处落后一步都不报错，只表现为
## "新长出来的区域永远不渲染"或"旧 chunk 留成鬼影"。这里钉死三条曾真出过问题的承诺：
##   ① 非恒等置换下 remap 不能越界（下标必须按**源轴**步长算，按目的轴顺序算会读到数组外）；
##   ② 挂 / 摘链上条目撤销再重做必须把**体素**带回来（少 commit 一次 → 尺寸对了、格子少一半）；
##   ③ 超限时 output_size() 与 reshape() 必须给出**同一个**答案（否则数组长度与盒尺寸对不上）。
##
## 体积布局 = PcgModel.index_of：x 步长 1、y 步长 w、z 步长 w*h（w=宽, h=高）。
## 材质 ID 值 0 = 空。

const MAT := 1


func _index(p: Vector3i, size: Vector3i) -> int:
	return p.x + p.y * size.x + p.z * size.x * size.y


## 一份"每格唯一且非零"的体积：重排后排序即可判定是否无损双射。
func _distinct_volume(size: Vector3i) -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(size.x * size.y * size.z)
	for i in v.size():
		v[i] = i + 1
	return v


func _nonzero_sorted(v: PackedInt32Array) -> Array:
	var out := []
	for x in v:
		if x != 0:
			out.append(x)
	out.sort()
	return out


# ----------------------------------------------------------------------------
# 纯重排数学
# ----------------------------------------------------------------------------

func test_identity_is_a_no_op() -> void:
	var t := QVoxVoxelTransform.identity()
	var old := Vector3i(3, 2, 5)
	assert_true(t.is_identity(), "默认构造就是恒等")
	assert_eq(t.new_size(old), old, "恒等不改尺寸")
	var src := _distinct_volume(old)
	assert_eq(t.remap(src, old), src, "恒等重排应逐格不变")


func test_mirror_keeps_size_and_flips_one_axis() -> void:
	var old := Vector3i(4, 2, 2)
	var t := QVoxVoxelTransform.mirror(0)
	assert_eq(t.new_size(old), old, "镜像不改尺寸")
	var src := _distinct_volume(old)
	var out := t.remap(src, old)
	assert_eq(out[_index(Vector3i(3, 0, 0), old)], src[_index(Vector3i(0, 0, 0), old)],
			"沿 X 镜像：目的 x 来自 源 (w-1-x)")
	assert_eq(out[_index(Vector3i(1, 1, 1), old)], src[_index(Vector3i(2, 1, 1), old)],
			"其余轴原样")


func test_rotate90_swaps_the_two_off_axis_dims() -> void:
	var old := Vector3i(4, 2, 2)
	var t := QVoxVoxelTransform.rotate90(2, 1)
	assert_eq(t.new_size(old), Vector3i(2, 4, 2), "绕 Z 旋转：X/Y 尺寸互换")
	# 目的轴 0 ← 源轴 1（原样）；目的轴 1 ← 源轴 0（取反）；目的轴 2 ← 源轴 2（原样）。
	var src := _distinct_volume(old)
	var out := t.remap(src, old)
	assert_eq(out[_index(Vector3i(0, 3, 0), t.new_size(old))], src[_index(Vector3i(0, 0, 0), old)])
	assert_eq(out[_index(Vector3i(1, 0, 1), t.new_size(old))], src[_index(Vector3i(3, 1, 1), old)])


func test_remap_is_a_lossless_bijection_for_permuted_axes() -> void:
	# 非立方 + 置换：这正是"按目的轴顺序套步长"会越界崩溃的用例。
	var old := Vector3i(5, 3, 2)
	var src := _distinct_volume(old)
	for t: QVoxVoxelTransform in [QVoxVoxelTransform.rotate90(2, 1),
			QVoxVoxelTransform.rotate90(0, -1), QVoxVoxelTransform.mirror(1)]:
		var ns := t.new_size(old)
		var out := t.remap(src, old)
		assert_eq(out.size(), ns.x * ns.y * ns.z, "输出体积必须正好是目标尺寸")
		var got := _nonzero_sorted(out)
		var expect := _nonzero_sorted(src)
		assert_eq(got, expect, "每一格都必须被映射到、且只映射一次（无损双射）")


func test_four_rotations_return_to_identity() -> void:
	var old := Vector3i(5, 3, 2)
	var src := _distinct_volume(old)
	var cur := src
	var size := old
	for i in 4:
		var t := QVoxVoxelTransform.rotate90(1, 1)
		cur = t.remap(cur, size)
		size = t.new_size(size)
	assert_eq(size, old, "转四次尺寸回到原样")
	assert_eq(cur, src, "转四次体素逐格回到原样")


func test_repeat_tiles_the_volume() -> void:
	var old := Vector3i(3, 1, 1)
	var src := _distinct_volume(old)
	assert_eq(QVoxVoxelTransform.repeat_size(old, 0, 3), Vector3i(9, 1, 1), "沿 X 铺三份")
	var out := QVoxVoxelTransform.repeat_volume(src, old, 0, 3)
	var ns := Vector3i(9, 1, 1)
	assert_eq(out[_index(Vector3i(0, 0, 0), ns)], src[_index(Vector3i(0, 0, 0), old)])
	assert_eq(out[_index(Vector3i(3, 0, 0), ns)], src[_index(Vector3i(0, 0, 0), old)], "第二份是同一内容")
	assert_eq(out[_index(Vector3i(8, 0, 0), ns)], src[_index(Vector3i(2, 0, 0), old)], "第三份的末格")


# ----------------------------------------------------------------------------
# 变换核：PcgTransform（链上的"体素变换"域）
# ----------------------------------------------------------------------------

## 一份 4×2×2 的模型，放三个可辨认的格子（原点 / 中点 / 对角）。
func _model() -> QVoxModel:
	var w := QVoxWorld.create_empty()
	w.add_material(Color(1, 0, 0)) # ID 1
	var m := w.create_model("m", Vector3i(4, 2, 2))
	m.set_voxel(0, 0, 0, MAT)
	m.set_voxel(2, 0, 0, MAT)
	m.set_voxel(3, 1, 1, MAT)
	return m


func _eval(m: QVoxModel) -> QVoxEvalResult:
	return QVoxEvalEngine.evaluate_node(m, QVoxEvalContext.make(m.grid_size, 0), null, null)


## 超限时两个入口必须给出**同一个答案**。
##
## 【为什么这条要单独钉】output_size() 说"撑到 262144 宽"，而 reshape() 原地不动的话，
## data.grid_size 就会与实际体积长度不符 —— 那是最坏的一类静默错位（渲染器读到数组外）。
## 反过来若 reshape() 撑大而 output_size() 不认，就是每次求值都白分配一块巨型数组。
func test_over_budget_is_refused_by_both_entries() -> void:
	var t := PcgTransform.repeat(0, 4096) # 64³ → 262144×64×64，远超上限
	var g := Vector3i(64, 64, 64)
	var raw := t.raw_output_size(g)
	assert_false(PcgTransform.within_budget(raw), "原始尺寸确实超限（UI 的提示靠它才看得见）")
	assert_eq(t.output_size(g), g, "超限：output_size 原样返回旧尺寸")
	var r := t.reshape(PackedInt32Array(), g)
	assert_eq(r[1], g, "超限：reshape 必须给出同一个答案")
	assert_eq((r[0] as PackedInt32Array).size(), 0, "超限：体积一格都不碰")


func test_mirror_flips_inside_the_same_box() -> void:
	var t := PcgTransform.mirror(0)
	var old := Vector3i(4, 2, 2)
	assert_eq(t.output_size(old), old, "镜像不改盒尺寸")
	var r := t.reshape(_distinct_volume(old), old)
	assert_eq(r[1], old, "尺寸原样")
	var out: PackedInt32Array = r[0]
	assert_eq(out.size(), old.x * old.y * old.z, "体积长度必须等于盒尺寸")
	assert_eq(out[_index(Vector3i(3, 0, 0), old)], 1, "第一格翻到 x=3")


func test_repeat_grows_the_box_and_the_volume() -> void:
	var t := PcgTransform.repeat(0, 3)
	var old := Vector3i(3, 1, 1)
	assert_eq(t.output_size(old), Vector3i(9, 1, 1), "平铺把 X 撑成三倍")
	var r := t.reshape(_distinct_volume(old), old)
	var ns: Vector3i = r[1]
	var out: PackedInt32Array = r[0]
	assert_eq(ns, Vector3i(9, 1, 1))
	assert_eq(out[_index(Vector3i(6, 0, 0), ns)], out[_index(Vector3i(0, 0, 0), ns)],
			"第二份与第一份内容相同")


# ----------------------------------------------------------------------------
# 链上的变换条目：尺寸传播 + 求值 + 撤销
# ----------------------------------------------------------------------------

func test_repeat_modifier_grows_the_output_box() -> void:
	var m := _model()
	m.add_modifier(QVoxTransformModifier.of(PcgTransform.repeat(0, 2)))
	assert_eq(QVoxEvalEngine.output_grid_size(m.modifiers, m.grid_size), Vector3i(8, 2, 2),
			"输出盒由链算出（纯函数，UI 靠它先把 data.grid_size 对齐）")
	var r := _eval(m)
	assert_eq(r.grid_size, Vector3i(8, 2, 2), "求值结果的盒尺寸必须跟上链")
	assert_eq(r.volume.size(), 8 * 2 * 2, "体积长度与盒尺寸一致")
	assert_eq(r.volume[_index(Vector3i(4, 0, 0), r.grid_size)], MAT, "第二份从 x=4 起")
	assert_eq(r.volume[_index(Vector3i(3, 1, 1), r.grid_size)], MAT, "原格仍在第一份里")
	assert_eq(m.grid_size, Vector3i(4, 2, 2), "手绘种子的尺寸**不被链改动**（重排只作用在输出上）")


func test_mirror_modifier_keeps_box_and_moves_voxels() -> void:
	var m := _model()
	m.add_modifier(QVoxTransformModifier.of(PcgTransform.mirror(0)))
	var r := _eval(m)
	assert_eq(r.grid_size, Vector3i(4, 2, 2), "镜像不改盒尺寸")
	assert_eq(r.volume[_index(Vector3i(3, 0, 0), r.grid_size)], MAT, "x=0 的格子翻到 x=3")
	assert_eq(r.volume[_index(Vector3i(1, 0, 0), r.grid_size)], MAT, "x=2 的格子翻到 x=1")


# ----------------------------------------------------------------------------
# 链上的摆放条目：平移（位置不再是节点字段）
# ----------------------------------------------------------------------------

## 平移 = 链上的一条摆放条目：**不改盒尺寸、不改体积**，只把结果整体挪走（origin）。
##
## 【为什么钉住"体积逐格不变"】平移若顺手重排了体积，"往右补零"就成了唯一的表达方式 ——
## 负偏移无从表达、挪回去也回不到原位（每挪一次丢一点），而那是最难查的一类不可逆。
func test_translate_modifier_keeps_box_and_moves_origin() -> void:
	var t := PcgTransform.translate(Vector3i(-2, 3, 0))
	var old := Vector3i(4, 2, 2)
	assert_eq(t.output_size(old), old, "平移不改盒尺寸")
	assert_eq(t.origin_delta(), Vector3i(-2, 3, 0), "位移由 origin_delta 单独回答")
	var r := t.reshape(_distinct_volume(old), old)
	assert_eq(r[1], old, "尺寸原样")
	assert_eq(r[0], _distinct_volume(old), "体积逐格不变（挪的是盒，不是格）")

	var m := _model()
	m.add_modifier(QVoxTransformModifier.of(PcgTransform.translate(Vector3i(-2, 3, 0))))
	var res := _eval(m)
	assert_eq(res.origin, Vector3i(-2, 3, 0), "求值结果的摆放 = 链上平移条目的累加")
	assert_eq(res.grid_size, Vector3i(4, 2, 2), "盒尺寸不变")
	assert_eq(res.volume[_index(Vector3i(0, 0, 0), res.grid_size)], MAT, "内容一格没动")


## 多条平移要**累加**，旁通的那条不算 —— 累加量是链的累积状态（见 StepState.shift）。
func test_translate_steps_accumulate_and_skip_bypassed() -> void:
	var m := _model()
	m.add_modifier(QVoxTransformModifier.of(PcgTransform.translate(Vector3i(1, 0, 0))))
	var skip := QVoxTransformModifier.of(PcgTransform.translate(Vector3i(100, 0, 0)))
	skip.enabled = false
	m.add_modifier(skip)
	m.add_modifier(QVoxTransformModifier.of(PcgTransform.translate(Vector3i(0, -1, 0))))
	assert_eq(_eval(m).origin, Vector3i(1, -1, 0), "旁通的条目不参与累加")


## 组按**各子结果自己的 origin**（链的产出）并成紧致盒 —— 子节点挪了，组的盒与摆放都要跟上。
##
## 【为什么这条最关键】"摆放从节点字段搬到链上"改的正是这里：组若仍读节点字段，
## 子节点的平移会被整段忽略，表现为"挪了没反应"，且不报任何错。
func test_group_places_children_by_their_chain_origin() -> void:
	var w := QVoxWorld.create_empty()
	w.add_material(Color(1, 0, 0))
	var g := w.create_group("g")
	var a := w.create_model("a", Vector3i(2, 2, 2), g)
	a.set_voxel(0, 0, 0, MAT)
	var b := w.create_model("b", Vector3i(2, 2, 2), g)
	b.set_voxel(0, 0, 0, MAT)
	b.add_modifier(QVoxTransformModifier.of(PcgTransform.translate(Vector3i(5, 0, 0))))
	var res := QVoxEvalEngine.evaluate_node(g, QVoxEvalContext.make(Vector3i(2, 2, 2), 0), null, null)
	assert_eq(res.origin, Vector3i.ZERO, "组的摆放取子树包围盒左下角")
	assert_eq(res.grid_size, Vector3i(7, 2, 2), "包围盒把挪到 x=5 的子节点也算进去")
	assert_eq(res.volume[_index(Vector3i(0, 0, 0), res.grid_size)], MAT, "a 留在原点")
	assert_eq(res.volume[_index(Vector3i(5, 0, 0), res.grid_size)], MAT, "b 在链上挪到了 x=5")


## 负平移要把**盒的左下角**也挪出去（origin 为负）—— 这正是"往盒里补零"表达不了的半边。
func test_negative_translate_moves_the_composite_box_origin() -> void:
	var w := QVoxWorld.create_empty()
	w.add_material(Color(1, 0, 0))
	var g := w.create_group("g")
	var a := w.create_model("a", Vector3i(2, 2, 2), g)
	a.set_voxel(0, 0, 0, MAT)
	var b := w.create_model("b", Vector3i(2, 2, 2), g)
	b.set_voxel(0, 0, 0, MAT)
	b.add_modifier(QVoxTransformModifier.of(PcgTransform.translate(Vector3i(-5, 0, 0))))
	var res := QVoxEvalEngine.evaluate_node(g, QVoxEvalContext.make(Vector3i(2, 2, 2), 0), null, null)
	assert_eq(res.origin, Vector3i(-5, 0, 0), "盒左下角被挪到 -5")
	assert_eq(res.grid_size, Vector3i(7, 2, 2), "盒跟着变长，而不是把内容截掉")
	assert_eq(res.volume[_index(Vector3i(0, 0, 0), res.grid_size)], MAT, "b 落在盒的最左端")
	assert_eq(res.volume[_index(Vector3i(5, 0, 0), res.grid_size)], MAT, "a 退到 x=5")


## 挂 / 摘条目必须是一条撤销单位，且**显示层分辨率要跟着链走**。
##
## 【为什么钉住显示层那一半】链改了输出盒，而 data.grid_size 落后一步的话，新长出来的区域
## 永远不渲染、缩小时旧 chunk 又留成鬼影 —— 两者都不报错，只表现为"画面不对"。
func test_chain_edit_is_undoable_and_box_follows() -> void:
	var w := QVoxWorld.create_empty()
	w.add_material(Color(1, 0, 0))
	var obj := w.create_model("m", Vector3i(4, 2, 2))
	obj.set_voxel(0, 0, 0, MAT)
	var s := QVoxEditSession.create_for(obj, w)

	var cmd := QVoxPropertyCommand.begin(obj, &"modifiers", obj, "挂修改器")
	obj.add_modifier(QVoxTransformModifier.of(PcgTransform.repeat(0, 3)))
	assert_true(cmd.commit(), "先 commit 才抓得到 after 态（否则撤销能回、重做回不来）")
	s.history.push(cmd)
	s.rebuild()

	assert_eq(s.output_size(), Vector3i(12, 2, 2), "会话看到的输出盒随链变")
	assert_eq(s.data.grid_size, Vector3i(12, 2, 2), "显示层分辨率必须跟上")

	assert_true(s.undo(), "挂条目是一条撤销单位")
	assert_eq(obj.modifiers.size(), 0, "撤销把条目摘掉")
	assert_eq(s.output_size(), Vector3i(4, 2, 2), "输出盒缩回去")
	assert_eq(s.data.grid_size, Vector3i(4, 2, 2), "显示层分辨率同样缩回去（否则旧 chunk 留成鬼影）")

	assert_true(s.redo())
	assert_eq(obj.modifiers.size(), 1, "重做把条目装回来")
	assert_eq(s.data.grid_size, Vector3i(12, 2, 2), "重做时显示层分辨率再跟上")
