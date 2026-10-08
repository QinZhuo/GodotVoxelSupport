extends TestCase

## 一期画笔工具族的契约测试：几何（QVoxBrushGeometry）+ 手势状态机（QVoxBrushTool）。
##
## 这里不碰场景树、不碰输入、不碰渲染 —— 工具被刻意设计成"产出坐标的纯逻辑"，
## 于是它的正确性可以在无头环境里逐格断言。钉死五条承诺：
##   ① 五种笔共用同一次手势骨架：按下取锚点 → 拖动更新端点 → 松手交产物；
##   ② **所见即所画**：hover() 预览与真正落笔走同一个 _stroke/_finish（不是两处逻辑对齐）；
##   ③ live（边拖边写）与 span（松手才写）由工具表声明，拖动时"补线"保证笔画不断；
##   ④ 产物一律裁到网格内 —— 越界坐标不进命令（否则撤销里会出现从未生效的格）；
##   ⑤ 面笔/填充的作用域判据来自外部闭包（显示几何），工具本身不认识 QVoxModel。

const MAT := 7
const OTHER := 3


# ----------------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------------

## 造一个拾取上下文。solid 字典的键 = 实心格，值 = 材质 id ——
## 用它替代真实的 VoxelData，测试就能在纯内存里描述任意形状。
func _pick(solid: Dictionary, hit: Vector3i, normal: Vector3i, opts := {}) -> QVoxBrushTool.Pick:
	var p := QVoxBrushTool.Pick.new()
	p.hit = hit
	p.normal = normal
	p.place = VoxelRay.placement_of(hit, normal)
	p.erase = opts.get("erase", false)
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


func _tool(m: QVoxBrushTool.Mode) -> QVoxBrushTool:
	var t := QVoxBrushTool.new()
	t.set_mode(m)
	return t


func _cells_of(v: Array[Vector3i]) -> Dictionary:
	var d := {}
	for c in v:
		d[c] = true
	return d


# ----------------------------------------------------------------------------
# 几何
# ----------------------------------------------------------------------------

func test_line_is_connected_and_lands_on_both_ends() -> void:
	var a := Vector3i(0, 0, 0)
	var b := Vector3i(5, 3, -2)
	var cells := QVoxBrushGeometry.line(a, b)
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
	var cells := QVoxBrushGeometry.line(Vector3i(2, 3, 4), Vector3i(2, 3, 4))
	assert_eq(cells.size(), 1, "零长度直线就是单格")


func test_box_is_inclusive_on_both_corners() -> void:
	var cells := QVoxBrushGeometry.box(Vector3i(2, 0, 1), Vector3i(0, 1, 3))
	assert_eq(cells.size(), 18, "实心长方体：各轴跨度（含两端）之积")
	assert_true(cells.has(Vector3i(0, 0, 1)) and cells.has(Vector3i(2, 1, 3)),
		"两个角点都必须在内（含端点）")


func test_ball_is_euclidean_not_chebyshev() -> void:
	assert_eq(QVoxBrushGeometry.ball(Vector3i(5, 5, 5), 0).size(), 1, "半径 0 = 单格")
	var r1 := QVoxBrushGeometry.ball(Vector3i(5, 5, 5), 1)
	assert_eq(r1.size(), 7, "半径 1 = 中心 + 6 个面邻")
	assert_false(r1.has(Vector3i(6, 6, 5)), "角格不属于欧氏球 r=1（切比雪夫球才会收它）")


func test_dilate_dedupes_overlaps() -> void:
	var seeds: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var cells := QVoxBrushGeometry.dilate(seeds, 1)
	assert_eq(cells.size(), 12, "两格相邻 → 各自膨胀后重叠 2 格，必须去重（同一格只写一次）")
	assert_true(cells.has(Vector3i(0, 0, 0)) and cells.has(Vector3i(1, 0, 0)), "两个原始格都还在")
	assert_eq(QVoxBrushGeometry.dilate(seeds, 1), cells, "同样的输入必须给出同样的顺序（可复现）")
	assert_eq(QVoxBrushGeometry.dilate(cells, 0), cells, "半径 0 原样返回")


func test_dilate_agrees_with_stamping_a_ball_per_cell() -> void:
	# dilate 走的是分离式距离变换（代价 O(输出体积)），而它的定义是"每格盖一个球"（代价 O(格 × 球)）。
	# 性能优化不得改变笔刷形状：这条把"快"钉在"对"上 —— 两条路径必须给出同一集合。
	var seeds: Array[Vector3i] = []
	for x in range(4):
		for y in range(2):
			seeds.append(Vector3i(x * 3 - 2, y * 2 + 1, x - y))
	for r in [1, 2, 3, 5]:
		var got := _cells_of(QVoxBrushGeometry.dilate(seeds, r))
		var want := {}
		for c in seeds:
			for off in QVoxBrushGeometry.ball_offsets(r):
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


func test_ball_offsets_are_one_shared_cached_table() -> void:
	# 球偏移只由半径决定，因此全类共用一张表：按格盖章的用法会反复算同一个球，
	# 若每次都新建一张表，就是一串无谓的三重循环（半径 15 时每次 31³）。
	var r2 := QVoxBrushGeometry.ball_offsets(2)
	assert_eq(QVoxBrushGeometry.ball(Vector3i.ZERO, 2), r2, "以原点为中心的球就是偏移表本身")
	assert_eq(QVoxBrushGeometry.ball_offsets(2), r2, "重复取用必须给出同一张表")
	assert_eq(QVoxBrushGeometry.ball_offsets(-3), QVoxBrushGeometry.ball_offsets(0),
		"半径 <= 0 一律归到 0（只有中心偏移），与 ball() 的旧语义一致")
	assert_eq(r2.count(Vector3i.ZERO), 1, "偏移表内不得有重复（去重由生成方式保证）")


func test_region_stops_at_gaps() -> void:
	var solid := {}
	for z in range(5):
		solid[Vector3i(0, 0, z)] = MAT
	solid[Vector3i(0, 0, 7)] = MAT  # 中间空两格 → 断开的柱子
	var accept := func(p: Vector3i) -> bool: return solid.has(p)
	var step := func(_p: Vector3i) -> Array[Vector3i]: return QVoxBrushGeometry.neighbors6()
	var cells := QVoxBrushGeometry.region([Vector3i(0, 0, 0)], accept, step)
	assert_eq(cells.size(), 5, "只能收到连通的 5 格")
	assert_false(cells.has(Vector3i(0, 0, 7)), "断开的部分不得被收进来")


# ----------------------------------------------------------------------------
# 手势骨架
# ----------------------------------------------------------------------------

func test_voxel_brush_click_paints_one_cell_outside_the_face() -> void:
	var tool := _tool(QVoxBrushTool.Mode.VOXEL)
	assert_true(tool.live(), "体素笔是边拖边写")
	var solid := {}
	assert_true(tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0))), "有入射面 → 可落笔")
	var cells := tool.release()
	assert_eq(cells.size(), 1, "只按下不拖动 → 画一格")
	assert_eq(cells[0], Vector3i(0, 1, 0), "落在命中格的外侧一格（place = hit + normal）")


func test_voxel_brush_drag_emits_continuous_increments() -> void:
	var tool := _tool(QVoxBrushTool.Mode.VOXEL)
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	var first := tool.drag(_pick(solid, Vector3i(3, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(first.size(), 4, "两次采样之间要补线，否则快速拖动会断成虚点")
	var second := tool.drag(_pick(solid, Vector3i(5, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(second.size(), 3, "第二段只交增量（上一采样点 → 现在），不重复整条线")
	assert_eq(second[0], Vector3i(3, 1, 0), "增量段与上一段首尾相接（笔迹连续）")
	assert_true(tool.release().is_empty(), "live 工具的产物已边拖边交，松手时无剩余")


func test_line_brush_only_emits_on_release() -> void:
	var tool := _tool(QVoxBrushTool.Mode.LINE)
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
	var tool := _tool(QVoxBrushTool.Mode.BOX)
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	tool.drag(_pick(solid, Vector3i(2, 0, 3), Vector3i(0, 1, 0)))
	var cells := tool.release()
	# 落笔格 = 命中格 + 法线，故两个角点是 (0,1,0) 与 (2,1,3)：
	# x 0..2 (3) × y 1..1 (1) × z 0..3 (4) = 12
	assert_eq(cells.size(), 12, "盒笔 = 两个角点之间的实心长方体（含两端）")
	assert_true(cells.has(Vector3i(0, 1, 0)) and cells.has(Vector3i(2, 1, 3)),
		"两个角点都要在内")


func test_begin_rejects_hits_without_an_incidence_face() -> void:
	var tool := _tool(QVoxBrushTool.Mode.VOXEL)
	var solid := {}
	assert_false(tool.begin(_pick(solid, Vector3i.MIN, Vector3i.ZERO)), "没命中 → 不能落笔")
	assert_false(tool.begin(_pick(solid, Vector3i(1, 1, 1), Vector3i.ZERO)),
		"起点就在实心格内（没有入射面）→ 无处可长，不能落笔")


## 回归：拖动时把鼠标移出模型（射线落空 → 拾取里是 Vector3i.MIN 哨兵）不得污染端点。
##
## 【这条曾经是"画几下整机卡死"的现场】MIN 是"没有落笔点"的哨兵，不是坐标。它一旦写进端点，
## 盒 / 线笔就会拿 -2^31 当角点去生成格子：`box()` 的 range 变成 21 亿次 append，
## 内存打穿后引擎**逐次**报 OOM（连调用栈一起打），实测刷出 1.27GB 日志、游戏与编辑器双双卡死。
## 所以这里断言的不是"行为好看"，而是**产物规模必须有界** —— 它一旦随"鼠标跑到多远"增长，就是灾难。
func test_drag_ignores_picks_that_missed_the_model() -> void:
	var solid := _plate(MAT)
	var grid := Vector3i(8, 8, 8)
	var miss := _pick(solid, Vector3i.MIN, Vector3i.ZERO, {"grid": grid})
	assert_false(miss.valid(), "前提：落空的拾取本身是无效的（place 也是 MIN）")
	for m in [QVoxBrushTool.Mode.VOXEL, QVoxBrushTool.Mode.LINE, QVoxBrushTool.Mode.BOX]:
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
## 先生成再裁是"先造再扔"：间距一大就是拿内存换垃圾（与上一条同源，只是入口不同）。
func test_far_away_corners_cannot_blow_up_the_box() -> void:
	var solid := _plate(MAT)
	var grid := Vector3i(8, 8, 8)
	var tool := _tool(QVoxBrushTool.Mode.BOX)
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
	var tool := _tool(QVoxBrushTool.Mode.BOX)
	var solid := {}
	var cells := tool.hover(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 1, "悬停时还没拖出第二个角点 → 只预览一格")
	assert_false(tool.active(), "悬停不进入手势状态")
	assert_true(tool.release().is_empty(), "没按下过 → 松手无产物")


# ----------------------------------------------------------------------------
# 作用域判据（面笔 / 填充）
# ----------------------------------------------------------------------------

func test_face_brush_paints_the_exposed_layer_only() -> void:
	var solid := _plate(MAT)
	solid[Vector3i(2, 1, 2)] = MAT  # 在 (2,0,2) 上方压一块 → 那一格不再是暴露面
	var tool := _tool(QVoxBrushTool.Mode.FACE)
	var cells := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 8, "9 格板里有一格被压住 → 只铺 8 格")
	assert_true(cells.has(Vector3i(1, 1, 1)), "画在暴露面的外侧（沿法线一格）")
	assert_false(cells.has(Vector3i(2, 1, 2)), "被压住的格子不算暴露面（否则会撑大体积）")
	for c in cells:
		assert_eq(c.y, 1, "整片都在命中面的外侧同一层")


func test_face_brush_erase_removes_the_exposed_layer() -> void:
	var tool := _tool(QVoxBrushTool.Mode.FACE)
	var solid := _plate(MAT)
	var cells := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0), {"erase": true}))
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
	var tool := _tool(QVoxBrushTool.Mode.FILL)
	var cells := tool.hover(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	assert_eq(cells.size(), 4, "填充边界 = 材质边界（用户看到的色块就是范围）")
	assert_false(cells.has(Vector3i(2, 0, 0)), "异材质的那一块不得被吞掉")


# ----------------------------------------------------------------------------
# 尺寸与裁剪
# ----------------------------------------------------------------------------

func test_brush_size_dilates_the_stroke() -> void:
	var tool := _tool(QVoxBrushTool.Mode.VOXEL)
	tool.brush_size = 2
	var solid := {}
	tool.begin(_pick(solid, Vector3i(0, 0, 0), Vector3i(0, 1, 0)))
	var cells := tool.release()
	assert_eq(cells.size(), 7, "笔刷尺寸 2 → 半径 1 的球（中心 + 6 面邻）")
	assert_true(cells.has(Vector3i(0, 1, 0)), "中心仍是落笔格")


func test_out_of_grid_cells_are_dropped() -> void:
	var tool := _tool(QVoxBrushTool.Mode.VOXEL)
	tool.brush_size = 2
	var solid := {}
	var grid := Vector3i(4, 4, 4)
	tool.begin(_pick(solid, Vector3i(3, 2, 3), Vector3i(0, 1, 0), {"grid": grid}))
	var cells := tool.release()
	assert_eq(cells.size(), 4, "球有一半伸出网格 → 越界格必须被裁掉")
	for c in cells:
		assert_true(c.x < grid.x and c.y < grid.y and c.z < grid.z, "产物必须全在网格内")


# ----------------------------------------------------------------------------
# 工具表
# ----------------------------------------------------------------------------

func test_mode_table_is_complete_and_hotkeys_are_unique() -> void:
	var seen := {}
	for m in QVoxBrushTool.Mode.values():
		var row := QVoxBrushTool.info(m)
		assert_eq(row.mode, m, "每个枚举值都要在工具表里有行")
		assert_false(seen.has(row.hotkey), "热键不得重复（单键切工具的前提）")
		seen[row.hotkey] = true
		assert_eq(QVoxBrushTool.mode_by_hotkey(row.hotkey), m, "热键要能反查回模式")
	assert_eq(QVoxBrushTool.mode_by_hotkey(KEY_F), QVoxBrushTool.Mode.FACE, "F = 面笔")
	assert_eq(QVoxBrushTool.info(QVoxBrushTool.Mode.BOX).label, "盒笔", "工具栏读的就是这张表")


func test_preview_matches_the_actual_stroke_for_every_mode() -> void:
	# 所见即所画：悬停预览与"按下后原地松手"必须给出同一批格子。
	# 这条断言是结构性的 —— 一旦有人把预览改成"另算一遍"，它会立刻红。
	var solid := _plate(MAT)
	for m in QVoxBrushTool.Mode.values():
		var tool := _tool(m)
		var preview := tool.hover(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
		tool.begin(_pick(solid, Vector3i(1, 0, 1), Vector3i(0, 1, 0)))
		var painted := tool.release()
		assert_eq(_cells_of(preview), _cells_of(painted), "%s：预览与落笔必须同源" % tool.label())
