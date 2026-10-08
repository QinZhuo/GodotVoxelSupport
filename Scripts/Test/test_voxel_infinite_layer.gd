extends TestCase

## 游戏进程级测试：**无限层**（P2-1 要迁出 VoxelRenderer 的那一部分）的行为安全网。
##
## 【为什么必须单独建这一层】现有 test_voxel_runtime_smoke 只用
## `VisibilityMode.FULL`（注释原话："不依赖相机，全量构建"）—— 也就是说
## LOD 分带 / 视锥剔除 / 流式距离过滤 / 原点漂移 这四块，在搬迁前后
## **完全没有自动化覆盖**。P2-1 要移动约 1300 行这类代码，没有这张网，
## "搬迁"就退化成"重写"：搬完只能靠肉眼在 demo 里看，出了偏差（远处空洞、
## 闪烁、幽灵网格、精度抖动）也无法定位。
##
## 【为什么必须在游戏进程】四条行为都依赖真实相机（get_viewport().get_camera_3d()）
## 与真实主循环，编辑器侧拿不到当前相机 → 只能 needs_game_process。
##
## 【覆盖】
##   ① LOD 分带公式：等比 2 倍分带，最外层 = view_distance（层数组长度必须一致）
##   ② 视锥剔除：视锥内保留；视锥外剔除并登记 deferred 待补建
##   ③ 近处 LOD0 区不参与视锥剔除（相机身后的近处 chunk 也要建 —— 防"越改越近"回归）
##   ④ 原点漂移：数据 chunk key / 网格 key 与节点位置 / 相机位置**三者同步**平移
##   ⑤ 流式距离过滤：视距内建网格，超卸载半径不建
##
## 【写法约定】经 `r.infinite_layer` 调用视点方法 / 读其账本并断言可观测结果 —— 与仓库既有
## 风格一致（本文件本就直读 `infinite_layer._deferred_chunks`，smoke 测试也直读内核
## `r._lod_meshes`）。P2-1 期 2 把剔除 / 流式调度搬进 VoxelInfiniteLayer，期 4 又把 LOD 分带
## 与全部调度账本（`_lod_outer` / `_lod_pending_tasks` / `_lod_rebuild`）一并搬入，
## 这些调用点随之改到新归属；断言本身不动，从而能逐条对照"行为是否等价"。

## 冒烟场景根。cleanup 兜底释放：用例中途失败/协程被中断时也能还原场景树。
var _smoke_root: Node3D = null


func needs_game_process() -> bool:
	return true


## runner 在每个用例后无条件调用（含失败/中断路径）→ 幂等释放场景根。
func cleanup() -> void:
	if _smoke_root != null and is_instance_valid(_smoke_root):
		_smoke_root.queue_free()
	_smoke_root = null


# ----------------------------------------------------------------------------
# ① LOD 分带公式
# ----------------------------------------------------------------------------

## 分带是无限层的"几何骨架"：LOD0 全精度只覆盖最内层，粗层自 LOD1 起等比 ×2 到 D。
## 这里把公式钉死（含 lod_count=1 的退化情形），搬迁后必须一模一样。
func test_lod_bands_scale_geometrically() -> void:
	# lod_count=n 时的各层外半径（view_distance=64）：
	#   n=1 → [64]；n=2 → [16, 64]；n=3 → [8, 32, 64]；n=4 → [4, 16, 32, 64]
	var expected := {
		1: [64.0],
		2: [16.0, 64.0],
		3: [8.0, 32.0, 64.0],
		4: [4.0, 16.0, 32.0, 64.0],
	}
	for n in expected:
		var r := VoxelRenderer.new()
		r.voxel_scale = 0.1
		r.view_distance = 64.0
		r.data = _make_data_with_material()
		r.lod_count = n
		r._configure_lod()

		var want: Array = expected[n]
		# 分带表随 LOD 调度一起归无限层（内核只留网格账本 _lod_meshes）。
		assert_eq(r.infinite_layer._lod_outer.size(), want.size(),
				"lod_count=%d 应产生 %d 个分带" % [n, want.size()])
		for i in want.size():
			assert_true(absf(r.infinite_layer._lod_outer[i] - float(want[i])) < 0.001,
					"lod_count=%d 第 %d 层外半径应为 %s，实为 %s" % [n, i, want[i], r.infinite_layer._lod_outer[i]])
		# 层平行数组长度必须一致（configure_lod 是唯一维护点，任何一处漏 append 都会错位）：
		# 内核网格账本 + 无限层 4 张调度表（待办 / 重建 / 重试 / 代次）长度必须同长。
		assert_eq(r._lod_meshes.size(), n, "lod_count=%d 网格层数应一致" % n)
		assert_eq(r.infinite_layer._lod_pending_tasks.size(), n, "lod_count=%d 待建表层数应一致" % n)
		assert_eq(r.infinite_layer._lod_rebuild.size(), n, "lod_count=%d 重建表层数应一致" % n)
		r.free()


# ----------------------------------------------------------------------------
# ② 视锥剔除
# ----------------------------------------------------------------------------

## 视锥内保留、视锥外剔除并登记 deferred（进视锥后补建）。
## 取距离 > lod0 带 + margin，才能绕开"近处无条件可见"分支，真正走到视锥判定。
func test_frustum_filter_keeps_front_drops_behind() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var front_far := Vector3i(0, 0, -20)   # 相机前方，中心距 ≈ 65.6 世界单位
	var behind_far := Vector3i(0, 0, 20)   # 相机身后，同距离
	var at_cam := Vector3i(0, 0, 0)

	var d := _make_data_with_material()
	_seed_chunks(d, [front_far, behind_far, at_cam])

	var r := VoxelRenderer.new()
	r.visibility_mode = VoxelRenderer.VisibilityMode.FRUSTUM
	r.voxel_scale = 0.1
	r.view_distance = 32.0
	r.lod_count = 1
	r.data = d
	_attach(tree, r)

	var chunks: Array[Vector3i] = [front_far, behind_far, at_cam]
	var visible := r.infinite_layer.filter_visible_chunks(chunks)

	assert_true(visible.has(front_far), "视锥内（相机前方）的 chunk 应保留")
	assert_true(not visible.has(behind_far), "视锥外（相机身后且超近处区）的 chunk 应被剔除")
	assert_true(r.infinite_layer._deferred_chunks.has(behind_far), "被剔除的 chunk 应登记进 deferred 待补建")


# ----------------------------------------------------------------------------
# ③ 近处 LOD0 区不参与视锥剔除
# ----------------------------------------------------------------------------

## 相机身后但仍在 LOD0 显示区内的 chunk 必须无条件构建。
## 这是"快速转向/后退时近处不出现空洞"的保证；历史上曾因取 lod0 边界写错
## （用 "count>1 否则 0" 而非 _lod_outer[0]）退化成"所有 chunk 都走视锥剔除"→"越改越近"。
func test_near_lod0_area_is_not_frustum_culled() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var behind_near := Vector3i(0, 0, 4)   # 相机身后，中心距 ≈ 14.4 < lod0 带 32
	var d := _make_data_with_material()
	_seed_chunks(d, [behind_near])

	var r := VoxelRenderer.new()
	r.visibility_mode = VoxelRenderer.VisibilityMode.FRUSTUM
	r.voxel_scale = 0.1
	r.view_distance = 32.0
	r.lod_count = 1
	r.data = d
	_attach(tree, r)

	var chunks: Array[Vector3i] = [behind_near]
	var visible := r.infinite_layer.filter_visible_chunks(chunks)

	assert_true(visible.has(behind_near), "相机身后的近处 chunk 不应被视锥剔除（否则转向/后退即空洞）")
	assert_true(not r.infinite_layer._deferred_chunks.has(behind_near), "近处 chunk 不应进 deferred")


# ----------------------------------------------------------------------------
# ④ 原点漂移
# ----------------------------------------------------------------------------

## 相机距数据基准超阈值时，数据 key / 渲染 key 与节点位置 / 相机位置必须**一起**平移。
## 这是无限移动世界的 float 精度前提；三者任一漏平移都会产生难以定位的症状：
##   漏数据 → 体素落在错误 chunk；漏节点位置 → 停在旧世界坐标的幽灵网格；漏相机 → 相机瞬移。
## 判定（何时平移）与相机补偿在无限层；渲染层账本平移在内核 `shift_render`（见本层类注释）。
func test_origin_shift_moves_data_mesh_and_camera_together() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var d := _make_data_with_material()
	d.set_voxel(Vector3i(16, 16, 16), 1)   # 落在 chunk (0,0,0)

	var r := VoxelRenderer.new()
	r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	r.voxel_scale = 0.1
	r.lod_count = 1
	r.data = d

	var chunk_size_world := r.voxel_scale * VoxelChunk.CHUNK_SIZE
	# 相机放到阈值 + 44 chunk 处 → 期望平移量恰好 44（shift = delta - threshold）
	var cam_chunk_x := VoxelInfiniteLayer.ORIGIN_SHIFT_THRESHOLD + 44
	var cam := _attach(tree, r, Vector3(float(cam_chunk_x), 0.0, 0.0) * chunk_size_world)

	# 渲染侧放一个网格节点：验证"网格 key 平移"与"节点位置同步"两件事
	var mi := MeshInstance3D.new()
	r.add_child(mi)
	r._lod_meshes[0][Vector3i(0, 0, 0)] = mi

	r.infinite_layer.check_origin_shift(cam)

	assert_eq(r.infinite_layer.origin_chunk(), Vector3i(44, 0, 0), "相机超阈值 44 chunk → 原点应平移 44")
	# 数据：chunk key 整体平移 44 → 体素从 chunk (0,0,0) 落到 chunk (44,0,0)
	assert_true(d.has_voxel(Vector3i(16 + 44 * VoxelChunk.CHUNK_SIZE, 16, 16)),
			"数据 chunk key 应随原点平移")
	assert_true(not d.has_voxel(Vector3i(16, 16, 16)), "旧坐标不应残留体素")
	# 渲染：key 与节点位置同步（只平移 key 会留下停在旧世界坐标的幽灵网格）
	assert_true(not r._lod_meshes[0].has(Vector3i(0, 0, 0)), "旧 mesh key 不应残留")
	assert_true(r._lod_meshes[0].has(Vector3i(44, 0, 0)), "mesh key 应随原点平移")
	assert_true(mi.position.is_equal_approx(Vector3(44, 0, 0) * chunk_size_world),
			"mesh 节点位置应同步平移，实为 %s" % mi.position)
	# 相机：被反向补偿，回到阈值边界内（漏补偿 → 相机瞬移）
	assert_true(is_equal_approx(cam.global_position.x, float(cam_chunk_x - 44) * chunk_size_world),
			"相机应被反向补偿，实为 %s" % cam.global_position.x)


# ----------------------------------------------------------------------------
# ⑤ 流式距离过滤
# ----------------------------------------------------------------------------

## 流式模式下"建网格"的距离判据：超卸载半径的 chunk 不建网格（数据由统一流式卸载负责，
## 重进范围再按需重载）。判据门控在 infinite_layer.streaming_enabled（由 visibility_mode 推导）。
func test_streaming_builds_inside_view_distance_only() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var near_ck := Vector3i(0, 0, 0)    # 中心距 ≈ 1.6
	var far_ck := Vector3i(0, 0, 20)    # 中心距 ≈ 65.6 > unload 半径（32 × 1.2 = 38.4）
	var d := _make_data_with_material()
	_seed_chunks(d, [near_ck, far_ck])

	var r := VoxelRenderer.new()
	r.visibility_mode = VoxelRenderer.VisibilityMode.STREAMING
	r.voxel_scale = 0.1
	r.view_distance = 32.0
	r.lod_count = 1
	r.data = d
	_attach(tree, r)

	assert_true(r.infinite_layer.streaming_enabled, "STREAMING 模式下 _ready 应启用流式距离过滤")

	var chunks: Array[Vector3i] = [near_ck, far_ck]
	var visible := r.infinite_layer.filter_visible_chunks(chunks)

	assert_true(visible.has(near_ck), "视距内的 chunk 应建网格")
	assert_true(not visible.has(far_ck), "超卸载半径的 chunk 不应建网格")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 游戏进程的主 SceneTree（TestCase 是 RefCounted，无 get_tree()）。
func _main_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## 建冒烟场景根 + 挂渲染器 + 挂一台**当前相机**（无限层全部经 get_camera_3d() 取相机）。
## 相机默认朝向 -Z（Camera3D 单位基），故只需给位置。
func _attach(tree: SceneTree, node: Node3D, cam_pos: Vector3 = Vector3.ZERO) -> Camera3D:
	_smoke_root = Node3D.new()
	_smoke_root.name = "VoxelInfiniteRoot"
	tree.root.add_child(_smoke_root)
	_smoke_root.add_child(node)
	var cam := Camera3D.new()
	_smoke_root.add_child(cam)
	cam.global_position = cam_pos
	cam.make_current()
	return cam


## 一个挂单材质（ID=1）的空 VoxelData。材质表由 add_material 自动补索引 0 空占位。
func _make_data_with_material() -> VoxelData:
	var d := VoxelData.new()
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = Color(0.6, 0.6, 0.65)
	mat.rough = 0.8
	mat.hardness = 1.0
	mat.mass = 1.0
	d.add_material(mat)
	return d


## 在每个指定 chunk 的中心附近各放 1 个体素（保证 has_chunk 为真 ——
## 无数据的空 chunk 会被 filter_visible_chunks 直接跳过，不参与网格管理）。
func _seed_chunks(d: VoxelData, chunk_keys: Array) -> void:
	for ck in chunk_keys:
		d.set_voxel(Vector3i(ck) * VoxelChunk.CHUNK_SIZE + Vector3i(16, 16, 16), 1)
