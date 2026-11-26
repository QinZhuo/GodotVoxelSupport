extends TestCase

## 一期画笔工具族的契约测试：几何（VoxelPrimitives）+ 手势状态机（QVoxelBrushTool）。

const MAT := 7
const OTHER := 3

# 工具

## 造一个拾取上下文。
func _pick(solid: Dictionary, hit: Vector3i, normal: Vector3i, opts := {}) -> QVoxelBrushTool.Pick:
	var p := QVoxelBrushTool.Pick.new()
	p.hit = hit
	p.normal = normal
	p.op = opts.get("op", QVoxelBrushTool.Op.ADD)
	p.place = VoxelRay.placement_of(hit, normal) if p.op == QVoxelBrushTool.Op.ADD else hit
	p.material_id = opts.get("material", MAT)
	p.grid = opts.get("grid", Vector3i.ZERO)
	p.solid = func(q: Vector3i) -> bool: return solid.has(q)
	p.material_at = func(q: Vector3i) -> int: return solid.get(q, 0)
	return p

## 一块 3×3 的水平板（y = 0），上方为空。
func _plate(mat: int) -> Dictionary:
	var solid := {}
	for x in range(3):
		for z in range(3):
			solid[Vector3i(x, 0, z)] = mat
	return solid

func _tool(m: QVoxelBrushTool.Mode) -> QVoxelBrushTool:
	var t := QVoxelBrushTool.new()
	t.set_mode(m)
	return t

func _cells_of(v: Array[Vector3i]) -> Dictionary:
	var d := {}
	for c in v:
		d[c] = true
	return d

# 几何

func test_line_is_connected_and_lands_on_both_ends() -> void:
	var a := Vector3i(0, 0, 0)
	var b := Vector3i(5, 3, -2)
	var cells := VoxelPrimitives.line(a, b)
	assert_eq(cells[0], a, "直线从起点开始")
	assert_eq(cells[cells.size() - 1], b, "直线恰好落在终点（误差累积版不漂移）")
	assert_eq(cells.size(), 6, "26-连通直线长度 = 最长轴跨度 + 1")
	var prev := a
	for c in cells:
		var d := c - prev
		assert_true(absi(d.x) <= 1 and absi(d.y) <= 1 and absi(d.z) <= 1,
			"相邻两格必须 26-连通（步长不超过一格）")
		prev = c

func test_line_of_a_single_point_is_a_dot() -> void:
	var cells := VoxelPrimitives.line(Vector3i(2, 3, 4), Vector3i(2, 3, 4))
	assert_eq(cells.size(), 1, "零长度直线就是单格")

func test_box_is_inclusive_on_both_corners() -> void:
	var cells := VoxelPrimitives.box(Vector3i(2, 0, 1), Vector3i(0, 1, 3))
	assert_eq(cells.size(), 18, "实心长方体：各轴跨度（含两端）之积")
	assert_true(cells.has(Vector3i(0, 0, 1)) and cells.has(Vector3i(2, 1, 3)),
		"两个角点都必须在内（含端点）")

func test_ball_is_euclidean_not_chebyshev() -> void:
	assert_eq(VoxelPrimitives.ball(Vector3i(5, 5, 5), 0).size(), 1, "半径 0 = 单格")
	var r1 := VoxelPrimitives.ball(Vector3i(5, 5, 5), 1)
	assert_eq(r1.size(), 7, "半径 1 = 中心 + 6 个面邻")
	assert_false(r1.has(Vector3i(6, 6, 5)), "角格不属于欧氏球 r=1（切比雪夫球才会收它）")

func test_dilate_dedupes_overlaps() -> void:
	var seeds: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var cells := VoxelPrimitives.dilate(seeds, 1)
	assert_eq(cells.size(), 12, "两格相邻 → 各自膨胀后重叠 2 格，必须去重（同一格只写一次）")
	assert_true(cells.has(Vector3i(0, 0, 0)) and cells.has(Vector3i(1, 0, 0)), "两个原始格都还在")
	assert_eq(VoxelPrimitives.dilate(seeds, 1), cells, "同样的输入必须给出同样的顺序（可复现）")
	assert_eq(VoxelPrimitives.dilate(cells, 0), cells, "半径 0 原样返回")

func test_dilate_agrees_with_stamping_a_ball_per_cell() -> void:
	# dilate 走的是分离式距离变换（代价 O(输出体积)），而它的定义是"每格盖一个球"（代价 O(格 × 球)）。
	var seeds: Array[Vector3i] = []
	for x in range(4):
		for y in range(2):
			seeds.append(Vector3i(x * 3 - 2, y * 2 + 1, x - y))
	for r in [1, 2, 3, 5]:
		var got := _cells_of(VoxelPrimitives.dilate(seeds, r))
		var want := {}
		for c in seeds:
			for off in VoxelPrimitives.ball_offsets(r):
				want[c + off] = true
		# 只报差异格：出问题时能一眼看出"多算了什么 / 漏了什么"，而不是抛两个大字典
		var only_got: Array[Vector3i] = []
		var only_want: Array[Vector3i] = []
		for k: Vector3i in got:
			if not want.has(k):
				only_got.append(k)
		for k: Vector3i in want:
			if not got.has(k):
				only_want.append(k)
		assert_eq(only_got.size(), 0, "半径 %d 多算了（距离变换偏小）: %s" % [r, str(only_got.slice(0, 8))])
		assert_eq(only_want.size(), 0, "半径 %d 漏算了（距离变换偏大）: %s" % [r, str(only_want.slice(0, 8))])

func test_dilate_ball_is_the_inscribed_sphere() -> void:
	# dilate_ball 的定义：球心是 size³ 立方的几何中心（偶数尺寸就落在半格上），直径 = size。
	var one: Array[Vector3i] = [Vector3i(0, 0, 0)]
	for size: int in [2, 3, 4, 5, 6, 8]:
		var got := _cells_of(VoxelPrimitives.dilate_ball(one, size))
		var neg := size >> 1
		var pos := (size - 1) >> 1
		var c := float(pos - neg) * 0.5
		var r2 := float(size * size) * 0.25
		var want := {}
		for z in range(-neg, pos + 1):
			for y in range(-neg, pos + 1):
				for x in range(-neg, pos + 1):
					var dz := float(z) - c
					var dy := float(y) - c
					var dx := float(x) - c
					if dx * dx + dy * dy + dz * dz <= r2:
						want[Vector3i(x, y, z)] = true
		var only_got: Array[Vector3i] = []
		var only_want: Array[Vector3i] = []
		for k: Vector3i in got:
			if not want.has(k):
				only_got.append(k)
		for k: Vector3i in want:
			if not got.has(k):
				only_want.append(k)
		assert_eq(only_got.size(), 0, "尺寸 %d 多算了: %s" % [size, str(only_got.slice(0, 8))])
		assert_eq(only_want.size(), 0, "尺寸 %d 漏算了: %s" % [size, str(only_want.slice(0, 8))])
	assert_eq(VoxelPrimitives.dilate_ball(one, 2).size(), 8, "尺寸 2 = 2×2×2 实心块")
	assert_eq(VoxelPrimitives.dilate_ball(one, 3).size(), 19, "尺寸 3 = 3³ 去 8 角")
	assert_eq(VoxelPrimitives.dilate_ball(one, 1), one, "尺寸 1 原样返回")

func test_dilate_plane_agrees_with_stamping_a_square_per_cell() -> void:
	# dilate_plane 走的是"平面内两轴各一轮一维膨胀"（代价随输出走），而它的定义是
	var seeds: Array[Vector3i] = []
	for x in range(3):
		for z in range(2):
			seeds.append(Vector3i(x * 2 - 1, x - z, z * 3))
	for normal in [Vector3i(0, 1, 0), Vector3i(1, 0, 0), Vector3i(0, 0, -1)]:
		var ax := VoxelPrimitives.face_axes(normal)
		# 边长 2 / 3 / 4 / 5 一起验：偶数边长是"中心偏半格"的那一档，最容易写错边界。
		for n in [2, 3, 4, 5]:
			var got := _cells_of(VoxelPrimitives.dilate_plane(seeds, n, normal))
			var want := {}
			for c in seeds:
				for i in range(-(n >> 1), ((n - 1) >> 1) + 1):
					for j in range(-(n >> 1), ((n - 1) >> 1) + 1):
						want[c + ax[0] * i + ax[1] * j] = true
			var only_got: Array[Vector3i] = []
			var only_want: Array[Vector3i] = []
			for k: Vector3i in got:
				if not want.has(k):
					only_got.append(k)
			for k: Vector3i in want:
				if not got.has(k):
					only_want.append(k)
			assert_eq(only_got.size(), 0,
				"法线 %s 边长 %d 多算了: %s" % [str(normal), n, str(only_got.slice(0, 8))])
			assert_eq(only_want.size(), 0,
				"法线 %s 边长 %d 漏算了: %s" % [str(normal), n, str(only_want.slice(0, 8))])

func test_dilate_plane_is_flat_where_the_ball_is_round() -> void:
	# 「球 / 平面」的差别就落在这一步：球会朝法线两侧也鼓出去，平面只在面内摊开。
	var one: Array[Vector3i] = [Vector3i(5, 5, 5)]
	var flat := VoxelPrimitives.dilate_plane(one, 5, Vector3i(0, 1, 0))
	assert_eq(flat.size(), 25, "法线 +Y、边长 5 的平面 = 5×5 的一片")
	for c in flat:
		assert_eq(c.y, 5, "厚度恒为 1：平面不朝法线方向鼓")
	assert_true(VoxelPrimitives.dilate(one, 2).size() > flat.size(),
		"同样 5 格宽，球比平面厚（球会朝法线两侧也长出去）")
	assert_eq(VoxelPrimitives.dilate_plane(one, 1, Vector3i(0, 1, 0)), one, "边长 1 原样返回")
	assert_eq(VoxelPrimitives.dilate_plane(one, 4, Vector3i(0, 1, 0)),
		VoxelPrimitives.dilate_plane(one, 4, Vector3i(0, -1, 0)),
		"平面的两个朝向等价（face_axes 只看轴向，不看正负）")
	# 偶数边长（MagicaVoxel 的 2 / 4 / 8 档）：中心偏半格 —— 向负方向多一格、正方向少一格。
	assert_eq(VoxelPrimitives.dilate_plane(one, 2, Vector3i(0, 1, 0)).size(), 4, "2 体素 = 2×2")
	assert_eq(VoxelPrimitives.dilate_plane(one, 4, Vector3i(0, 1, 0)).size(), 16, "4 体素 = 4×4")
	assert_eq(VoxelPrimitives.dilate_plane(one, 8, Vector3i(0, 1, 0)).size(), 64, "8 体素 = 8×8")

func test_ball_offsets_are_one_shared_cached_table() -> void:
	# 球偏移只由半径决定，因此全类共用一张表：按格盖章的用法会反复算同一个球，
	var r2 := VoxelPrimitives.ball_offsets(2)
	assert_eq(VoxelPrimitives.ball(Vector3i.ZERO, 2), r2, "以原点为中心的球就是偏移表本身")
	assert_eq(VoxelPrimitives.ball_offsets(2), r2, "重复取用必须给出同一张表")
	assert_eq(VoxelPrimitives.ball_offsets(-3), VoxelPrimitives.ball_offsets(0),
		"半径 <= 0 一律归到 0（只有中心偏移），与 ball() 的旧语义一致")
	assert_eq(r2.count(Vector3i.ZERO), 1, "偏移表内不得有重复（去重由生成方式保证）")

func test_region_stops_at_gaps() -> void:
	var solid := {}
	for z in range(5):
		solid[Vector3i(0, 0, z)] = MAT
	solid[Vector3i(0, 0, 7)] = MAT  # 中间空两格 → 断开的柱子
	var accept := func(p: Vector3i) -> bool: return solid.has(p)
	var step := func(_p: Vector3i) -> Array[Vector3i]: return VoxelPrimitives.neighbors6()
	var cells := VoxelPrimitives.region([Vector3i(0, 0, 0)], accept, step)
	assert_eq(cells.size(), 5, "只能收到连通的 5 格")
	assert_false(cells.has(Vector3i(0, 0, 7)), "断开的部分不得被收进来")

# 手势骨架

func test_voxel_brush_click_paints_one_cell_outside_the_face() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	assert_true(tool.live(), "体素笔是边拖边写")
	var solid := {}
	assert_true(tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0))), "有入射面 → 可落笔")
	var cells := tool.release()
	assert_eq(cells.size(), 1, "只按下不拖动 → 画一格")
	assert_eq(cells[0], Vector3i(0, 1, 0), "落在命中格的外侧一格（place = hit + normal）")

func test_voxel_brush_drag_emits_continuous_increments() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	var first := tool.drag(_pick(solid, Vector3i(3, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(first.size(), 4, "两次采样之间要补线，否则快速拖动会断成虚点")
	var second := tool.drag(_pick(solid, Vector3i(5, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(second.size(), 3, "第二段只交增量（上一采样点 → 现在），不重复整条线")
	assert_eq(second[0], Vector3i(3, 1, 0), "增量段与上一段首尾相接（笔迹连续）")
	assert_true(tool.release().is_empty(), "live 工具的产物已边拖边交，松手时无剩余")

func test_line_brush_only_emits_on_release() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.LINE)
	assert_false(tool.live(), "线笔松手才落笔（否则拖动过程会留下一串线）")
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	assert_true(tool.drag(_pick(solid, Vector3i(4, 0, 0), Vector3i(0, 1, 0))).is_empty(),
		"拖动过程不产出")
	var cells := tool.release()
	assert_eq(cells.size(), 5, "松手时交出整条线")
	assert_eq(cells[0], Vector3i(0, 1, 0), "起点 = 按下时的落笔格")
	assert_eq(cells[cells.size() - 1], Vector3i(4, 1, 0), "终点 = 松手时的落笔格")

func test_box_brush_spans_anchor_to_current() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.BOX)
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	tool.drag(_pick(solid, Vector3i(2, 0, 3), Vector3i(0, 1, 0)))
	var cells := tool.release()
	# 落笔格 = 命中格 + 法线，故两个角点是 (0,1,0) 与 (2,1,3)：
	assert_eq(cells.size(), 12, "盒笔 = 两个角点之间的实心长方体（含两端）")
	assert_true(cells.has(Vector3i(0, 1, 0)) and cells.has(Vector3i(2, 1, 3)),
		"两个角点都要在内")

func test_begin_rejects_hits_without_an_incidence_face() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	var solid := {}
	assert_false(tool.begin(_pick(solid, Vector3i.MIN, Vector3i.ZERO)), "没命中 → 不能落笔")
	assert_false(tool.begin(_pick(solid, Vector3i(1, 1, 1), Vector3i.ZERO)),
		"起点就在实心格内（没有入射面）→ 无处可长，不能落笔")

## 回归：拖动时把鼠标移出模型（射线落空 → 拾取里是 Vector3i.MIN 哨兵）不得污染端点。
func test_drag_ignores_picks_that_missed_the_model() -> void:
	var solid := _plate(MAT)
	var grid := Vector3i(8, 8, 8)
	var miss := _pick(solid, Vector3i.MIN, Vector3i.ZERO, {"grid": grid})
	assert_false(miss.valid(), "前提：落空的拾取本身是无效的（place 也是 MIN）")
	for m in [QVoxelBrushTool.Mode.VOXEL, QVoxelBrushTool.Mode.LINE, QVoxelBrushTool.Mode.BOX]:
		var tool := _tool(m)
		tool.begin(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0), {"grid": grid}))
		assert_true(tool.drag(miss).is_empty(), "%s：落空的拖动不产出格子" % tool.label())
		var cells := tool.release()
		assert_true(cells.size() <= grid.x * grid.y * grid.z,
			"%s：产物必须被网格体积限住（松手时端点仍是最后一次有效落笔点）" % tool.label())
		for c in cells:
			assert_true(absi(c.x) < 1000 and absi(c.y) < 1000 and absi(c.z) < 1000,
				"%s：产物里混进了哨兵坐标 %s" % [tool.label(), str(c)])

## 回归：两个角点离得极远时，产物规模也必须被限住 —— 端点裁剪要在**生成形状之前**。
func test_far_away_corners_cannot_blow_up_the_box() -> void:
	var solid := _plate(MAT)
	var grid := Vector3i(8, 8, 8)
	var tool := _tool(QVoxelBrushTool.Mode.BOX)
	tool.begin(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0), {"grid": grid}))
	# 合法但越界很远的坐标（正常拖动全程都可能出现这种点：射线打在网格外沿之外）
	tool.drag(_pick(solid, Vector3i(10_000, 0, 10_000), Vector3i(0, 1, 0), {"grid": grid}))
	var cells := tool.release()
	assert_eq(_cells_of(cells).size(), cells.size(), "产物不得有重复格")
	assert_true(cells.size() <= grid.x * grid.y * grid.z,
		"产物规模必须被网格限住，而不是随角点间距增长（got=%d）" % cells.size())
	for c in cells:
		assert_true(c.x >= 0 and c.x < grid.x and c.z >= 0 and c.z < grid.z, "全在网格内")

func test_hover_previews_without_starting_a_gesture() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.BOX)
	var solid := {}
	var cells := tool.hover(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 1, "悬停时还没拖出第二个角点 → 只预览一格")
	assert_false(tool.active(), "悬停不进入手势状态")
	assert_true(tool.release().is_empty(), "没按下过 → 松手无产物")

# 作用域判据（面笔 / 填充）

func test_face_brush_paints_the_exposed_layer_only() -> void:
	var solid := _plate(MAT)
	solid[Vector3i(2, 1, 2)] = MAT  # 在 (2,0,2) 上方压一块 → 那一格不再是暴露面
	var tool := _tool(QVoxelBrushTool.Mode.FACE)
	var cells := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 8, "9 格板里有一格被压住 → 只铺 8 格")
	assert_true(cells.has(Vector3i(1, 1, 1)), "画在暴露面的外侧（沿法线一格）")
	assert_false(cells.has(Vector3i(2, 1, 2)), "被压住的格子不算暴露面（否则会撑大体积）")
	for c in cells:
		assert_eq(c.y, 1, "整片都在命中面的外侧同一层")

func test_face_brush_erase_removes_the_exposed_layer() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.FACE)
	var solid := _plate(MAT)
	var cells := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0), {"op": QVoxelBrushTool.Op.REMOVE}))
	assert_eq(cells.size(), 9, "擦除铺满整片暴露面")
	for c in cells:
		assert_eq(c.y, 0, "擦的是暴露面本身，不是它外侧的空格")
	assert_eq(tool.material(), 0, "擦除写入材质 0（内核语义：0 = 空气）")

func test_fill_brush_stops_at_material_boundary() -> void:
	var solid := {}
	for x in range(2):
		for z in range(2):
			solid[Vector3i(x, 0, z)] = MAT
			solid[Vector3i(x + 2, 0, z)] = OTHER  # 紧贴着但材质不同
	var tool := _tool(QVoxelBrushTool.Mode.FILL)
	var cells := tool.hover(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 4, "填充边界 = 材质边界（用户看到的色块就是范围）")
	assert_false(cells.has(Vector3i(2, 0, 0)), "异材质的那一块不得被吞掉")

# 尺寸与裁剪

func test_brush_size_dilates_the_stroke() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	tool.brush_size = 3
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	var cells := tool.release()
	assert_eq(cells.size(), 19, "尺寸 3 = 内切于 3³ 的球 = 27 - 8 个角")
	assert_true(cells.has(Vector3i(0, 1, 0)), "中心仍是落笔格")

## 尺寸是**边长**（MagicaVoxel 的 size）：球内切于 size³ 的立方，平面直接铺成 size×size。
func test_brush_size_is_edge_length() -> void:
	# 球：2 → 2×2×2 实心块（8 格）、3 → 3³ 去 8 角（19 格）、5 → 半径 2.5 的球（81 格）。
	var ball_want := {1: 1, 2: 8, 3: 19, 4: 32, 5: 81}
	for size in ball_want:
		var ball := _tool(QVoxelBrushTool.Mode.VOXEL)
		ball.brush_size = size
		ball.begin(_pick({}, Vector3i(4, 0, 4), Vector3i(0, 1, 0)))
		assert_eq(ball.release().size(), int(ball_want[size]), "尺寸 %d 的球格数" % size)
	# 平面：边长就是实际宽度，偶数也精确（2×2 / 4×4 / 8×8）。
	var plane_want := {1: 1, 2: 4, 4: 16, 8: 64}
	for size in plane_want:
		var plane := _tool(QVoxelBrushTool.Mode.VOXEL)
		plane.brush_size = size
		plane.set_shape(QVoxelBrushTool.Shape.PLANE)
		plane.begin(_pick({}, Vector3i(8, 0, 8), Vector3i(0, 1, 0)))
		assert_eq(plane.release().size(), int(plane_want[size]), "尺寸 %d 的平面片格数" % size)

func test_plane_shape_keeps_a_wide_stroke_on_the_surface() -> void:
	# 体素笔 + 平面形态：在地板上刷一笔，产物是贴在落笔层的一片，而不是半个球埋进地板。
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	tool.brush_size = 3
	tool.set_shape(QVoxelBrushTool.Shape.PLANE)
	var solid := {}
	tool.begin(_pick(solid, Vector3i(4, 0, 4), Vector3i(0, 1, 0)))
	var cells := tool.release()
	assert_eq(cells.size(), 9, "尺寸 3 → 3×3 的平面片")
	for c in cells:
		assert_eq(c.y, 1, "整片都在落笔层（法线 +Y），没有一格陷进地板或飘在空中")
	assert_eq(_tool(QVoxelBrushTool.Mode.VOXEL).brush_shape, QVoxelBrushTool.Shape.BALL,
		"默认形态仍是球：既有行为一字未改")

func test_out_of_grid_cells_are_dropped() -> void:
	var tool := _tool(QVoxelBrushTool.Mode.VOXEL)
	tool.brush_size = 3
	var solid := {}
	var grid := Vector3i(4, 4, 4)
	tool.begin(_pick(solid, Vector3i(3, 2, 3), Vector3i(0, 1, 0), {"grid": grid}))
	var cells := tool.release()
	assert_true(cells.size() < 19, "球有一半伸出网格 → 越界格必须被裁掉")
	for c in cells:
		assert_true(c.x < grid.x and c.y < grid.y and c.z < grid.z, "产物必须全在网格内")

# 工具表

func test_mode_table_is_complete_and_hotkeys_are_unique() -> void:
	var seen := {}
	for m in QVoxelBrushTool.Mode.values():
		var row := QVoxelBrushTool.info(m)
		assert_eq(row.mode, m, "每个枚举值都要在工具表里有行")
		assert_false(seen.has(row.hotkey), "热键不得重复（单键切工具的前提）")
		seen[row.hotkey] = true
		assert_eq(QVoxelBrushTool.mode_by_hotkey(row.hotkey), m, "热键要能反查回模式")
	assert_eq(QVoxelBrushTool.mode_by_hotkey(KEY_3), QVoxelBrushTool.Mode.FACE, "3 = 面笔")
	assert_eq(QVoxelBrushTool.mode_by_hotkey(KEY_1), QVoxelBrushTool.Mode.VOXEL, "1 = 点笔")
	assert_eq(QVoxelBrushTool.info(QVoxelBrushTool.Mode.BOX).label, "块", "工具栏读的就是这张表")

func test_preview_matches_the_actual_stroke_for_every_mode() -> void:
	# 所见即所画：悬停预览与"按下后原地松手"必须给出同一批格子。
	var solid := _plate(MAT)
	for m in QVoxelBrushTool.Mode.values():
		var tool := _tool(m)
		var preview := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
		tool.begin(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
		var painted := tool.release()
		assert_eq(_cells_of(preview), _cells_of(painted), "%s：预览与落笔必须同源" % tool.label())
