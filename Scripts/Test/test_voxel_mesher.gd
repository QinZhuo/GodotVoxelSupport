extends TestCase

## 网格化层 `VoxelMesher` 的契约测试（编辑器进程即可，不需要游戏进程）。
##
## 【这个测试守的是什么】`VoxelMesher` 是"体素 → 几何 → ArrayMesh"的**唯一**收口点：
##   上层（STATIC 整份重建 / DYNAMIC 分组重建 / 导入路径）都只经它出几何。
##   重构时它一旦被改坏，不会立刻报错，而是以"少几个三角 / 三角形串形 / 透明面跑到实体桶"
##   这种**画面症状**暴露出来，而且往往一张图看不出、要对比才发现。
##   所以这里把它拆成三块互不重叠的契约，逐条钉住：
##     ① **分组几何学**（纯数学）：chunk ↔ group 的坐标换算。负坐标的算术右移是最经典的坑，
##        写错时只有负方向的模型会"少半组 / 组错位"，正坐标的用例全绿也发现不了；
##     ② **拼接正确性**：`append_arrays` 的索引偏移。索引不加偏移时三角形不会消失，
##        而是退化到别的顶点上 —— 这是"拼接"最容易漏、也最难肉眼发现的一处；
##     ③ **to_mesh 形状**：surface 数（0/1/2）与"三角形数守恒"，即几何数组到 mesh 这条路上不丢面。
##   再加一条**端到端等价性**（本文件最重要）：同一个模型"逐组自行按 34³ 光环算每 chunk 几何、
##   再按组原点平移拼接"的三角形总数必须等于"一次 build_all 整份生成"。它同时覆盖分组、halo、
##   拼接索引偏移、材质分桶四件事，是"分段拼装与整份生成几何等价"这个架构承诺的唯一可观测证据。
##   【拼装代码为什么内联在用例里】它原本是 `VoxelMesher.build_group`：生产路径（worker 子线程
##   按光环算好每 chunk 几何 + 帧尾纯拼接）根本不走它，全仓只剩这条测试在调用 —— 于是"留着它
##   当证据"实为养老代码。删掉后把那段拼装逐行内联到这里：**承诺本身不变**（仍是分段 ≡ 整份），
##   但不再有一个只为测试存在的生产 API。
##   期望值里 deer.vox 的 1344 是**实测确认**的导入 mesh 精确值（与 `test_voxel_mesh_kernel.gd`
##   的基线一致）；若采样资产被重烘导致它合法地变化，须同期改这个常量并说明原因。

## 小模型（快）——端到端用例的输入。资产缺失时相关用例静默跳过，不因纯净检出判红。
const DEER_VOX := "res://demo/deer.vox"
## deer.vox 走完整几何路径的三角形数基线（= 导入 mesh 的精确值）。
const DEER_CUBE_TRIS := 1344
## 端到端用例统一用导入器的默认体素尺度，便于与导入 mesh 的数字对齐。
const SCALE := 0.1


# ─────────────────────────── A. 分组几何学（纯数学） ───────────────────────────

## 正坐标：组坐标 = chunk 坐标算术右移 group_shift 位。
## group_shift=1 → 每组边长 2^1 = 2 个 chunk，所以 0..1 属于第 0 组、2..3 属于第 1 组、
## 7 属于第 3 组、x=8 属于第 4 组（与 chunks_in_group(key, 1) 返回 8 个元素自洽）。
func test_group_of_positive_chunk_coords() -> void:
	assert_eq(VoxelMesher.group_of(Vector3i(0, 0, 0), 1), Vector3i.ZERO,
			"chunk (0,0,0) 应属于组 (0,0,0)（组原点）")
	assert_eq(VoxelMesher.group_of(Vector3i(1, 1, 1), 1), Vector3i.ZERO,
			"chunk (1,1,1) 应属于组 (0,0,0)：group_shift=1 时第 0 组覆盖 chunk 0..1")
	assert_eq(VoxelMesher.group_of(Vector3i(2, 0, 0), 1), Vector3i(1, 0, 0),
			"chunk x=2 应属于组 x=1（组坐标 = chunk 坐标 >> 1，每组 2 个 chunk）")
	assert_eq(VoxelMesher.group_of(Vector3i(7, 7, 7), 1), Vector3i(3, 3, 3),
			"chunk (7,7,7) 应属于组 (3,3,3)（7 >> 1 = 3，第 3 组覆盖 chunk 6..7）")
	assert_eq(VoxelMesher.group_of(Vector3i(8, 0, 0), 1), Vector3i(4, 0, 0),
			"chunk x=8 应属于组 x=4（组坐标 = chunk 坐标 >> 1）")
	# group_shift=3 → 每组边长 2^3 = 8 个 chunk，0..7 才全部落在第 0 组。
	# 这条把"组边长 = 2^shift 个 chunk"的口径钉死：shift 与组边长不可混为一谈。
	for x in 8:
		assert_eq(VoxelMesher.group_of(Vector3i(x, x, x), 3), Vector3i.ZERO,
				"group_shift=3 时每组 8 个 chunk/边：chunk (%d,%d,%d) 应属于组 (0,0,0)" % [x, x, x])
	assert_eq(VoxelMesher.group_of(Vector3i(8, 8, 8), 3), Vector3i(1, 1, 1),
			"group_shift=3 时 chunk (8,8,8) 应属于组 (1,1,1)（8 >> 3 = 1）")
	# 三个轴必须一致处理，不能只对 x 做移位
	assert_eq(VoxelMesher.group_of(Vector3i(7, 3, 5), 1), Vector3i(3, 1, 2),
			"每个轴都必须独立右移：chunk (7,3,5) 应属于组 (3,1,2)")
	assert_eq(VoxelMesher.group_of(Vector3i(8, 8, 8), 2), Vector3i(2, 2, 2),
			"group_shift=2 时每组 4 个 chunk/边：chunk (8,8,8) 应属于组 (2,2,2)")


## 负坐标：必须走**算术右移**（floor 语义），不是截断除法。
## 【为什么单列一条】`chunk_key / 2` 或 `int(chunk_key / 2.0)` 在正方向没问题，
## 但 -1 会被算成 0，于是负方向的最后半组数据被归到相邻组里 →
## 表现为"负坐标那一侧模型缺一块 / 组网格错位"，而且正坐标用例全绿。
func test_group_of_negative_chunk_coords() -> void:
	assert_eq(VoxelMesher.group_of(Vector3i(-1, -1, -1), 1), Vector3i(-1, -1, -1),
			"chunk (-1,-1,-1) 应属于组 (-1,-1,-1)（算术右移；写成截断除法会错误地算成组 0）")
	assert_eq(VoxelMesher.group_of(Vector3i(-8, -8, -8), 1), Vector3i(-4, -4, -4),
			"chunk (-8,-8,-8) 应属于组 (-4,-4,-4)（算术右移，不是 -8/2 之外的任何近似）")
	assert_eq(VoxelMesher.group_of(Vector3i(-2, -1, 0), 1), Vector3i(-1, -1, 0),
			"chunk (-2,-1,0) 应属于组 (-1,-1,0)：-2>>1=-1、-1>>1=-1，两格同属负向第 1 组")
	assert_eq(VoxelMesher.group_of(Vector3i(-5, 3, -9), 2), Vector3i(-2, 0, -3),
			"group_shift=2 时负坐标同样按 floor：chunk (-5,3,-9) 应属于组 (-2,0,-3)")


## 组原点 chunk == chunk 坐标按位清零低 group_shift 位（每分量独立）。
## 这条与 `group_of` 互为逆运算，一起把"分组映射是 floor 而非四舍五入/截断"钉死：
## 组原点必须是**组内最小**的 chunk，且与组内任意成员相差 < 2^group_shift。
func test_group_origin_chunk_matches_bitmask_floor() -> void:
	var cases: Array[Vector3i] = [
		Vector3i(0, 0, 0), Vector3i(7, 7, 7), Vector3i(8, 0, 0),
		Vector3i(-1, -1, -1), Vector3i(-8, -8, -8), Vector3i(-3, 5, -8),
		Vector3i(31, -32, 17),
	]
	for s: int in [1, 2, 3]:
		var mask: int = ~((1 << s) - 1)
		var span: int = 1 << s
		for ck: Vector3i in cases:
			var group_key: Vector3i = VoxelMesher.group_of(ck, s)
			var got: Vector3i = VoxelMesher.group_origin_chunk(group_key, s)
			var want := Vector3i(ck.x & mask, ck.y & mask, ck.z & mask)
			assert_eq(got, want,
					"group_shift=%d 时 ck=%s 所在组的原点 chunk 应等于 ck 按位清零低 %d 位（%s），实得 %s"
					% [s, str(ck), s, str(want), str(got)])
			# 往返一致：组原点自己反查必须回到同一个组
			assert_eq(VoxelMesher.group_of(got, s), group_key,
					"组原点 %s 反查组坐标应仍是 %s（group_of / group_origin_chunk 必须互为逆运算）"
					% [str(got), str(group_key)])
			# floor 的判据：每个分量上 0 <= ck - origin < 2^s
			var delta: Vector3i = ck - got
			assert_true(delta.x >= 0 and delta.x < span and delta.y >= 0 and delta.y < span
					and delta.z >= 0 and delta.z < span,
					"组原点必须不大于组内任意 chunk，且相差小于组边长 %d：ck=%s origin=%s delta=%s"
					% [span, str(ck), str(got), str(delta)])


## group_shift=1 的组内 chunk 列表：2×2×2 = 8 个、无重复、全部反查回同一组。
## 重复会让同一个 chunk 被生成并拼接两次（浪费且可能叠面），
## 漏项则直接少几何 —— 所以"数量 + 唯一性 + 反查"三条都要。
func test_chunks_in_group_shift1() -> void:
	var key := Vector3i(-1, 2, 0)
	var chunks: Array[Vector3i] = VoxelMesher.chunks_in_group(key, 1)
	assert_eq(chunks.size(), 8,
			"group_shift=1 每组应列出 2×2×2 = 8 个 chunk（实得 %d）" % chunks.size())

	var seen := {}
	for ck: Vector3i in chunks:
		seen[ck] = true
		assert_eq(VoxelMesher.group_of(ck, 1), key,
				"chunks_in_group(%s) 列出的 %s 必须反查回同一个组（否则组网格会被贴到错误位置）"
				% [str(key), str(ck)])
	assert_eq(seen.size(), chunks.size(),
			"chunks_in_group 不应出现重复 chunk（重复会导致同一 chunk 被生成/拼接两次）")

	var origin: Vector3i = VoxelMesher.group_origin_chunk(key, 1)
	assert_true(chunks.has(origin),
			"列表必须包含组原点 chunk %s（组网格的原点靠它推出）" % str(origin))
	assert_true(chunks.has(origin + Vector3i(1, 1, 1)),
			"列表必须包含组内最后一个 chunk %s" % str(origin + Vector3i(1, 1, 1)))


## group_shift=2 的组内 chunk 列表：4×4×4 = 64 个（数量随 2^(3·shift) 增长）。
func test_chunks_in_group_shift2() -> void:
	var key := Vector3i(-1, 2, 0)
	var chunks: Array[Vector3i] = VoxelMesher.chunks_in_group(key, 2)
	assert_eq(chunks.size(), 64,
			"group_shift=2 每组应列出 4×4×4 = 64 个 chunk（实得 %d）" % chunks.size())

	var seen := {}
	for ck: Vector3i in chunks:
		seen[ck] = true
		assert_eq(VoxelMesher.group_of(ck, 2), key,
				"chunks_in_group(%s, 2) 列出的 %s 必须反查回同一个组" % [str(key), str(ck)])
	assert_eq(seen.size(), 64, "chunks_in_group(group_shift=2) 不应出现重复 chunk")


# ───────────────────────── B. 拼接正确性（索引偏移） ─────────────────────────

## 空容器形状：拼接与各生成器共用同一套键 —— 这是"几何数组长什么样"的唯一事实源。
## 少键/改名会让 append / to_mesh 静默跳过该桶（`.get(...)` 有默认值），
## 于是透明面或法线整批消失而不报错，所以这里把 8 个键逐一钉住。
func test_new_arrays_shape_is_shared_contract() -> void:
	var empty: Dictionary = VoxelMesher._new_arrays()
	for key in ["solid_verts", "solid_normals", "solid_uvs", "solid_idxs",
			"trans_verts", "trans_normals", "trans_uvs", "trans_idxs"]:
		assert_true(empty.has(key),
				"空容器必须含键 %s：append_arrays / to_mesh 都按这套键取数，缺键会静默跳过该桶" % key)
	assert_eq(VoxelMesher.triangle_count(empty), 0, "空容器的三角形数应为 0")
	assert_eq(VoxelMesher.vertex_count(empty), 0, "空容器的顶点数应为 0")


## 拼接两份各 1 个三角形（3 顶点 3 索引）的几何：三角形数与顶点数都应是两份之和。
func test_append_sums_triangle_and_vertex_counts() -> void:
	var single: Dictionary = _one_tri("solid")
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, single)
	VoxelMesher.append_arrays(dst, _one_tri("solid", Vector3(10, 0, 0)))
	assert_eq(VoxelMesher.triangle_count(dst),
			VoxelMesher.triangle_count(single) * 2,
			"拼接两份各 1 三角形的几何后，三角形数应为两份之和（2）")
	assert_eq(VoxelMesher.vertex_count(dst),
			VoxelMesher.vertex_count(single) * 2,
			"拼接两份各 3 顶点的几何后，顶点数应为两份之和（6）")


## 【核心】索引偏移：第二份的索引必须整体加上第一份的顶点数。
## 若偏移漏加，索引会仍是 [0,1,2] —— 三角形不会消失，而是退化到**前一份的顶点**上，
## 表现为重叠的假三角形 / 模型缺面，肉眼极难定位。
func test_append_shifts_indices_by_vertex_base() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri("solid", Vector3(10, 0, 0)))
	assert_eq((dst["solid_verts"] as PackedVector3Array).size(), 6,
			"拼接后实体顶点应为 6（两份各 3 个，不合并顶点）")
	assert_eq(dst["solid_idxs"], PackedInt32Array([0, 1, 2, 3, 4, 5]),
			"第二份三角形的索引必须整体 +3（第一份顶点数），期望 [0,1,2, 3,4,5]；"
			+ "若仍是 [0,1,2, 0,1,2]，说明索引偏移漏加，三角形会串到第一份的顶点上")


## 实体桶与透明桶**各自独立**从 0 起算偏移 —— 两桶顶点数组互不相干，
## 共用同一个 base 会让透明三角形的索引指到实体顶点上（反之亦然）。
func test_append_offsets_solid_and_trans_independently() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri_both(Vector3.ZERO))
	VoxelMesher.append_arrays(dst, _one_tri_both(Vector3(10, 0, 0)))
	assert_eq(dst["solid_idxs"], PackedInt32Array([0, 1, 2, 3, 4, 5]),
			"实体桶索引应独立从 0 起算偏移：[0,1,2,3,4,5]")
	assert_eq(dst["trans_idxs"], PackedInt32Array([0, 1, 2, 3, 4, 5]),
			"透明桶索引也应独立从 0 起算偏移：[0,1,2,3,4,5]（两桶不能共用顶点基数）")
	assert_eq(VoxelMesher.triangle_count(dst), 4,
			"两桶各 2 个三角形，三角形总数应为 4")
	assert_eq(VoxelMesher.vertex_count(dst), 12,
			"两桶各 6 个顶点，顶点总数应为 12")


## 拼接空几何（`_new_arrays()`）必须是**纯空操作**：目标内容与顶点数都不变，
## 且返回值仍是调用前的 solid 顶点数（调用方可能无条件 append 每个 chunk，空块很常见）。
func test_append_empty_arrays_is_noop() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri_both(Vector3(10, 0, 0)))
	var before: Dictionary = dst.duplicate(true)
	var verts_before: int = VoxelMesher.vertex_count(dst)
	var solid_verts_before: int = (dst["solid_verts"] as PackedVector3Array).size()

	var ret: int = VoxelMesher.append_arrays(dst, VoxelMesher._new_arrays())
	assert_true(dst == before,
			"拼接空几何不应改变目标内容（键值全部保持原样）")
	assert_eq(VoxelMesher.vertex_count(dst), verts_before,
			"拼接空几何后顶点数应保持不变（%d）" % verts_before)
	assert_eq(ret, solid_verts_before,
			"拼接空几何的返回值仍应是调用前的 solid 顶点数 %d（base 契约不能因 src 为空而改口径）"
			% solid_verts_before)


## 返回值契约：`append_arrays` 返回**调用前 solid_verts 的数量**（调用方据此当 base 累计）。
## 注意它统计的是实体桶（不是两桶之和），所以带透明桶的 src 也要按这个口径返回。
func test_append_returns_pre_call_solid_vertex_count() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	for i in 3:
		var before: int = (dst["solid_verts"] as PackedVector3Array).size()
		var ret: int = VoxelMesher.append_arrays(dst, _one_tri_both(Vector3(10.0 * i, 0, 0)))
		assert_eq(ret, before,
				"第 %d 次拼接的返回值应等于调用前 solid_verts 的数量（%d），"
				% [i + 1, before]
				+ "调用方以它作为本组顶点基数；错口径会让组间索引整体错位")
	assert_eq((dst["solid_verts"] as PackedVector3Array).size(), 9,
			"三次拼接后实体顶点应为 9（每次 3 个）")


# ─────────────────────────── C. to_mesh 形状 ───────────────────────────

## 空输入 → null：调用方据此判断"没有任何可渲染的面"（`mesh = null` 即隐藏节点）。
func test_to_mesh_empty_returns_null() -> void:
	assert_true(VoxelMesher.to_mesh({}, []) == null,
			"空字典应返回 null：调用方靠 null 判断没有可渲染的面")
	assert_true(VoxelMesher.to_mesh(VoxelMesher._new_arrays(), []) == null,
			"空容器（形状齐全但没有任何面）也应返回 null，而不是零 surface 的 ArrayMesh")


## 只有实体面 → 恰好 1 个 surface。
func test_to_mesh_solid_only_one_surface() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri("solid", Vector3(10, 0, 0)))
	var mesh: ArrayMesh = VoxelMesher.to_mesh(dst, [])
	assert_true(mesh != null, "有实体面时应产出 mesh")
	if mesh == null:
		return
	assert_eq(mesh.get_surface_count(), 1,
			"只有实体桶有面时 surface 数应为 1（实体 = surface 0）")


## 实体 + 透明都有 → 2 个 surface（0=实体、1=透明）。
## 顺序是渲染契约的一部分：透明 surface 必须排在后面才能正确混合/排序。
func test_to_mesh_solid_and_trans_two_surfaces() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri("trans"))
	var mesh: ArrayMesh = VoxelMesher.to_mesh(dst, [])
	assert_true(mesh != null, "实体与透明桶都有面时应产出 mesh")
	if mesh == null:
		return
	assert_eq(mesh.get_surface_count(), 2,
			"实体与透明都有面时 surface 数应为 2（0=实体，1=透明）")


## `materials = []`（编辑器预览 / 尚无材质时）不得崩溃，仍应产出 mesh。
func test_to_mesh_without_materials() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri("trans"))
	var mesh: ArrayMesh = VoxelMesher.to_mesh(dst, [])
	assert_true(mesh != null, "materials 为空数组时仍应产出 mesh（只是不绑材质）")
	if mesh == null:
		return
	assert_eq(mesh.get_surface_count(), 2,
			"materials 为空不应影响 surface 结构（仍应为实体 + 透明 2 个）")
	assert_eq(mesh.get_faces().size() / 3, VoxelMesher.triangle_count(dst),
			"materials 为空时三角形数仍应守恒")


## 三角形数守恒：`to_mesh` 后的面数（顶点数 / 3）必须等于几何数组里登记的三角形数。
## 这条守着"几何数组 → ArrayMesh"不丢面（例如某个桶的索引没被写进 surface 数组）。
func test_to_mesh_conserves_triangle_count() -> void:
	var dst: Dictionary = VoxelMesher._new_arrays()
	VoxelMesher.append_arrays(dst, _one_tri("solid"))
	VoxelMesher.append_arrays(dst, _one_tri("solid", Vector3(10, 0, 0)))
	VoxelMesher.append_arrays(dst, _one_tri("trans"))
	var want: int = VoxelMesher.triangle_count(dst)
	assert_eq(want, 3, "测试准备：实体 2 + 透明 1 = 3 个三角形")
	var mesh: ArrayMesh = VoxelMesher.to_mesh(dst, [])
	assert_true(mesh != null, "有面时应产出 mesh")
	if mesh == null:
		return
	assert_eq(mesh.get_faces().size() / 3, want,
			"to_mesh 后 get_faces().size()/3 应等于 triangle_count(%d)：两桶三角形都必须进 surface" % want)


# ──────────── D. build_all / 逐组拼装的等价性（需要真实模型） ────────────

## `build_all` 对 deer.vox 的三角形数基线：1344（实测确认，等于导入 mesh 的精确值）。
## 这是"活体素渲染与导入 mesh 几何一致"的最低成本守卫：内核面可见性规则、贪婪合并粒度、
## 分块布局任一漂移都会改变这个数字。
func test_build_all_deer_baseline() -> void:
	var d := _deer()
	if d.is_empty():
		return   # 纯净检出可能没有素材，不因缺资源判失败
	var arrays: Dictionary = VoxelMesher.build_all(
			d["buffers"], d["data"].materials, SCALE, Vector3.ZERO)
	assert_false(arrays.is_empty(), "非空模型应产出几何数组（空字典表示一个面都没画出来）")
	if arrays.is_empty():
		return
	assert_eq(VoxelMesher.triangle_count(arrays), DEER_CUBE_TRIS,
			"deer.vox 整份生成的三角形数应为基线 %d（等于导入 mesh 的精确值）；"
			% DEER_CUBE_TRIS
			+ "变化说明面可见性/贪婪合并/分块布局发生了非预期漂移")
	assert_eq((arrays["solid_idxs"] as PackedInt32Array).size() % 3, 0,
			"索引数组长度必须是 3 的整数倍（否则说明三角形被写坏）")


## 【本文件最重要的一条】逐组分段拼装 ≡ 整份生成。
##
## DYNAMIC 模式把模型按 group 切成若干份、各自出几何再拼接，而 STATIC 模式一次
## `build_all`。两者几何必须**完全相同**，否则同一份体素在两种绘制模式下长得不一样。
## 这条断言同时覆盖四件事，任一处写错都会让它红：
##   ① `group_of` 分组正确（漏组/重组的 chunk 会少画或多画）；
##   ② group 外一圈邻居参与了面剔除（halo 缺数据 → 边界面被多画 → 三角数偏大）；
##   ③ `append_arrays` 的索引偏移正确（不加偏移会串形，但三角数不变 —— 由 B 段单独守）；
##   ④ 材质分桶在两条路径上一致（透明面被算进实体桶会改变桶内三角数）。
##
## 【为什么不调生产 API 而是自己拼】生产路径没有"逐组出网格"这个入口了：worker 在子线程
## 按 34³ 光环算好**每个 chunk**的几何，主线程帧尾只做纯拼接（见 VoxelRenderer._apply_built_chunk）。
## 原先调用的 `VoxelMesher.build_group` 因此全仓零生产调用，删掉后这段拼装内联在此 —— 
## 承诺不变，但被验证的东西从"一个测试专用 API"变成了"生产实际使用的 halo + 拼接组合"。
func test_group_assembly_totals_match_build_all() -> void:
	var d := _deer()
	if d.is_empty():
		return
	var buffers: Dictionary = d["buffers"]
	var materials: Array = d["data"].materials

	var whole: Dictionary = VoxelMesher.build_all(buffers, materials, SCALE, Vector3.ZERO)
	var total: int = VoxelMesher.triangle_count(whole)
	assert_true(total > 0, "测试准备：deer.vox 整份生成应产出三角形，否则等价性无从比对")
	if total <= 0:
		return

	# 按 group_shift=1 分组：只对"数据里真实存在"的 chunk 出网格
	var groups := {}
	for ck: Vector3i in buffers.keys():
		var gk: Vector3i = VoxelMesher.group_of(ck, 1)
		if not groups.has(gk):
			groups[gk] = []
		(groups[gk] as Array).append(ck)

	var aligned := VoxelMaterial.align_by_id(materials)
	var trans_flags := VoxelMaterial.build_trans_flags(aligned)
	var assembled: Dictionary = VoxelMesher._new_arrays()
	var group_tris := 0
	for gk: Vector3i in groups.keys():
		var chunk_keys: Array = groups[gk]
		var part: Dictionary = VoxelMesher._new_arrays()
		var group_origin: Vector3i = VoxelMesher.group_origin_chunk(gk, 1)
		for ck: Vector3i in chunk_keys:
			var halo := VoxelChunkGenerator.build_halo_from_buffers(buffers, ck)
			if halo.is_empty():
				continue
			# 顶点按"相对组原点"的体素偏移平移（单位=体素，原生内部乘 scale），
			# 与生产路径把组挂成一个节点时的定位方式一致。
			var rel_voxels := Vector3(ck - group_origin) * float(VoxelChunk.CHUNK_SIZE)
			var arr := VoxelChunkGenerator.generate_single_chunk_dense(
					halo, aligned, SCALE, ck, rel_voxels, trans_flags)
			if arr.is_empty():
				continue
			VoxelMesher.append_arrays(part, arr)
		group_tris += VoxelMesher.triangle_count(part)
		VoxelMesher.append_arrays(assembled, part)

	assert_eq(group_tris, total,
			"各组分段拼装的三角形数之和必须等于 build_all 的整份三角形数（%d）" % total)
	assert_eq(VoxelMesher.triangle_count(assembled), total,
			"逐组拼装再 append_arrays 拼接后的三角形总数必须等于 build_all；"
			+ "不等说明分段拼装与整份生成不等价（常见原因：halo 缺邻居导致边界面多画，或 group 映射错位）")

	# 再走一次 to_mesh：分组拼装结果转 mesh 后不应丢面（mesh 层守恒）
	var mesh: ArrayMesh = VoxelMesher.to_mesh(assembled, [])
	assert_true(mesh != null, "分组拼装结果应能转出 mesh")
	if mesh == null:
		return
	assert_eq(mesh.get_faces().size() / 3, total,
			"分组拼装 mesh 的面数应仍与整份三角形数一致（%d）" % total)


## `build_all` 传空字典 → 返回空字典、三角形数 0（渲染核心据此把 mesh 置空）。
func test_build_all_empty_buffers() -> void:
	var arrays: Dictionary = VoxelMesher.build_all({}, [], SCALE, Vector3.ZERO)
	assert_true(arrays.is_empty(),
			"空缓冲字典应返回空字典（{}），表示没有可渲染的几何")
	assert_eq(VoxelMesher.triangle_count(arrays), 0, "空缓冲的三角形数应为 0")
	assert_eq(VoxelMesher.vertex_count(arrays), 0, "空缓冲的顶点数应为 0")
	assert_true(VoxelMesher.to_mesh(arrays, []) == null,
			"空缓冲转 mesh 应为 null（调用方据此隐藏节点）")


# ─────────────────────────────── 辅助 ───────────────────────────────

## 构造**一个三角形**的几何数组（3 顶点 3 索引），只填指定桶。
## 作用是把"拼接 / to_mesh"的用例与实际几何内核彻底隔离：手算即可验证，不依赖资产。
func _one_tri(prefix: String, offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var a: Dictionary = VoxelMesher._new_arrays()
	a[prefix + "_verts"] = PackedVector3Array([
		offset,
		offset + Vector3(1, 0, 0),
		offset + Vector3(0, 1, 0),
	])
	a[prefix + "_normals"] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	a[prefix + "_uvs"] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	a[prefix + "_idxs"] = PackedInt32Array([0, 1, 2])
	return a


## 实体 + 透明各一个三角形（两桶的顶点原点相同，便于验证"各自独立偏移"）。
func _one_tri_both(offset: Vector3 = Vector3.ZERO) -> Dictionary:
	var a: Dictionary = _one_tri("solid", offset)
	var t: Dictionary = _one_tri("trans", offset)
	for suffix in ["verts", "normals", "uvs", "idxs"]:
		a["trans_" + suffix] = t["trans_" + suffix]
	return a


## 加载 deer.vox 的活体素数据（与世界原点模式一致，便于与导入 mesh 对比）。
## 返回 {data, buffers}；资产缺失或解析失败时返回 {}，各用例据此跳过。
func _deer() -> Dictionary:
	if not ResourceLoader.exists(DEER_VOX):
		return {}
	var vox := VoxAccess.Open(DEER_VOX)
	if vox == null:
		return {}
	var data := QVoxelSource.from_voxel_data(vox.voxel, 0, QVoxelSource.OriginMode.WORLD_ORIGIN)
	if data == null:
		return {}
	return {"data": data, "buffers": data._chunk_buffers_view()}
