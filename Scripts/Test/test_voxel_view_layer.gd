extends TestCase

## 游戏进程级测试：**视点层**（VoxelViewLayer）的行为安全网。

## 冒烟场景根。
var _root: Node3D = null

func needs_game_process() -> bool:
	return true

## runner 在每个用例后无条件调用（含失败/中断路径）→ 幂等释放场景根。
func cleanup() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null

# ① LOD 分带公式

## 分带是视点层的"几何骨架"：LOD0 全精度只覆盖最内层，粗层自 LOD1 起等比 ×2 到 D。
func test_lod_bands_scale_geometrically() -> void:
	# lod_count=n 时的各层外半径（view_distance=64）：
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
		var layer := _mount_layer(r)
		r.lod_count = n

		var want: Array = expected[n]
		assert_eq(layer._lod_outer.size(), want.size(),
				"lod_count=%d 应产生 %d 个分带" % [n, want.size()])
		for i in want.size():
			assert_true(absf(layer._lod_outer[i] - float(want[i])) < 0.001,
					"lod_count=%d 第 %d 层外半径应为 %s，实为 %s" % [n, i, want[i], layer._lod_outer[i]])
		# 层长度必须三处同长：内核网格账本 + 本层调度表 + 分带表。
		assert_eq(r._lod_meshes.size(), n, "lod_count=%d 网格层数应一致" % n)
		assert_eq(layer._levels.size(), n, "lod_count=%d 调度表层数应一致" % n)
		r.free()

# ② 视锥剔除

## 视锥内保留、视锥外剔除并登记 deferred（进视锥后补建）。
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
	var layer := _mount_layer(r)
	_attach(tree, r)

	var chunks: Array[Vector3i] = [front_far, behind_far, at_cam]
	var visible := layer.filter_chunks(chunks)

	assert_true(visible.has(front_far), "视锥内（相机前方）的 chunk 应保留")
	assert_true(not visible.has(behind_far), "视锥外（相机身后且超近处区）的 chunk 应被剔除")
	assert_true(layer._deferred_chunks.has(behind_far), "被剔除的 chunk 应登记进 deferred 待补建")

# ③ 近处 LOD0 区不参与视锥剔除

## 相机身后但仍在 LOD0 显示区内的 chunk 必须无条件构建。
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
	var layer := _mount_layer(r)
	_attach(tree, r)

	var chunks: Array[Vector3i] = [behind_near]
	var visible := layer.filter_chunks(chunks)

	assert_true(visible.has(behind_near), "相机身后的近处 chunk 不应被视锥剔除（否则转向/后退即空洞）")
	assert_true(not layer._deferred_chunks.has(behind_near), "近处 chunk 不应进 deferred")

# ④ 原点漂移

## 相机距数据基准超阈值时，数据 key / 渲染 key 与节点位置 / 相机位置必须**一起**平移。
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
	var layer := _mount_layer(r)

	var chunk_size_world := r.voxel_scale * VoxelChunk.CHUNK_SIZE
	# 相机放到阈值 + 44 chunk 处 → 期望平移量恰好 44（shift = delta - threshold）
	var cam_chunk_x := VoxelViewLayer.ORIGIN_SHIFT_THRESHOLD + 44
	var cam := _attach(tree, r, Vector3(float(cam_chunk_x), 0.0, 0.0) * chunk_size_world)

	# 渲染侧放一个网格节点：验证"网格 key 平移"与"节点位置同步"两件事
	var mi := MeshInstance3D.new()
	r.add_child(mi)
	r._lod_meshes[0][Vector3i(0, 0, 0)] = mi

	layer.check_origin_shift(cam)

	assert_eq(layer.origin_chunk(), Vector3i(44, 0, 0), "相机超阈值 44 chunk → 原点应平移 44")
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

# ⑤ 流式距离过滤

## 流式模式下"建网格"的距离判据：超卸载半径的 chunk 不建网格（数据由统一流式卸载负责，
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
	var layer := _mount_layer(r)
	_attach(tree, r)

	# 流式判据就是模式本身（旧实现另有一个由模式推导的 streaming_enabled 镜像字段，已删除）
	assert_eq(r.visibility_mode, VoxelRenderer.VisibilityMode.STREAMING, "用例前提：流式模式")
	assert_true(layer.unload_d() > 0.0, "卸载半径应为正（否则距离过滤失效）")

	var chunks: Array[Vector3i] = [near_ck, far_ck]
	var visible := layer.filter_chunks(chunks)

	assert_true(visible.has(near_ck), "视距内的 chunk 应建网格")
	assert_true(not visible.has(far_ck), "超卸载半径的 chunk 不应建网格")

# ⑥ 粗层真实调度（LOD1 真的在工作）

## 相机在粗层带时：LOD0 不该有网格（会与粗层重叠），LOD1 block 必须被派发并挂载出真网格。
func test_lod1_blocks_are_built_when_camera_far() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	# 相机拉远到粗层带：LOD0 不该有网格，LOD1 应该有
	var r := _make_host(tree, Vector3(0, 30, 45), 64.0, 2)
	var layer := _mount_layer(r)
	assert_true(layer.lod_level_count() >= 2, "lod_count=2 时应有 LOD1 层")

	await _frames(90)

	var lod0_count: int = (r._lod_meshes[0] as Dictionary).size()
	var lod1_map: Dictionary = r._lod_meshes[1]
	assert_eq(lod0_count, 0, "相机在粗层带时不应有 LOD0 chunk 网格（会与粗层重叠）")
	assert_true(lod1_map.size() > 0, "相机在粗层带时 LOD1 粗层 block 必须被派发并挂载")
	# 每个挂载的粗层 block 必须是**真网格**（不是只占了个 key 的空壳）
	for bk in lod1_map:
		var mi: MeshInstance3D = lod1_map[bk]
		assert_true(mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0,
				"LOD1 block %s 应挂载出真实网格（空壳说明 worker 结果被丢弃/未应用）" % str(bk))

# ⑦ 空快照防空（曾经崩溃）

func test_worker_survives_empty_snapshot() -> void:
	# 数据未就绪是**正常情况**。
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers({}, Vector3i.ZERO, 1)
	assert_true(halo.size() == 0 or halo.size() == VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME,
			"空缓冲的 halo 只允许是空数组或尺寸正确的全 0 数组，实为 %d" % halo.size())
	# 全 0 的 halo 降采样出的中心块必然全空 —— 上层据此走重试计数，不会产生空壳 mesh
	if halo.size() == VoxelChunkGenerator.LOD_BLOCK_HALO_VOLUME:
		var buf := VoxelChunk.extract_center_from_halo(halo)
		# 中心块体积 = LOD_BLOCK_SIZE³（32³），不是 halo 体积
		assert_eq(buf.size(), VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE * VoxelChunkGenerator.LOD_BLOCK_SIZE,
				"尺寸正确的 halo 必须能安全取出中心块（这条曾是崩溃点）")
		assert_eq(buf.count(0), buf.size(), "空数据降采样出的中心块应全为 0（无体素）")

# 辅助

## 游戏进程的主 SceneTree（TestCase 是 RefCounted，无 get_tree()）。
func _main_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

## 挂一个视点层到渲染器（代码装配：先入父，再 attach 认父并同步分带）。
func _mount_layer(r: VoxelRenderer) -> VoxelViewLayer:
	var layer := VoxelViewLayer.new()
	layer.name = "ViewLayer"
	r.add_child(layer)
	layer.attach(r)
	assert_eq(r.view_layer, layer, "attach 应把组件登记到宿主的 view_layer")
	return layer

## 建冒烟场景根 + 挂渲染器 + 挂一台**当前相机**（视点层经 get_camera_3d() 取相机）。
func _attach(tree: SceneTree, node: Node3D, cam_pos: Vector3 = Vector3.ZERO) -> Camera3D:
	_root = Node3D.new()
	_root.name = "VoxelViewRoot"
	tree.root.add_child(_root)
	_root.add_child(node)
	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.global_position = cam_pos
	cam.make_current()
	return cam

## 建一个挂 deer 数据 + 相机的渲染器（DYNAMIC + FRUSTUM，LOD 调度会真的跑）。
func _make_host(tree: SceneTree, cam_pos: Vector3, view_d: float = 32.0,
		lod_n: int = 1) -> VoxelRenderer:
	_root = Node3D.new()
	_root.name = "VoxelViewRoot"
	tree.root.add_child(_root)

	var vox := VoxAccess.Open("res://demo/deer.vox")
	var data := QVoxelSource.from_voxel_data(vox.voxel, 0, QVoxelSource.OriginMode.WORLD_ORIGIN)

	var r := VoxelRenderer.new()
	r.voxel_scale = 0.1
	r.draw_mode = VoxelRenderer.DrawMode.DYNAMIC
	r.visibility_mode = VoxelRenderer.VisibilityMode.FRUSTUM
	r.view_distance = view_d
	r.lod_count = lod_n
	r.data = data
	_root.add_child(r)

	var cam := Camera3D.new()
	_root.add_child(cam)
	cam.global_position = cam_pos
	cam.make_current()
	return r

## 等 N 帧（让 WorkerThreadPool 结果回传 + 帧尾限量挂载跑完）。
func _frames(n: int) -> void:
	var tree := _main_tree()
	if tree == null:
		return
	for i in n:
		await tree.process_frame

## 一个挂单材质（ID=1）的空 QVoxelSource。
func _make_data_with_material() -> QVoxelSource:
	var d := QVoxelSource.new()
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = Color(0.6, 0.6, 0.65)
	mat.rough = 0.8
	mat.hardness = 1.0
	mat.mass = 1.0
	d.add_material(mat)
	return d

## 在每个指定 chunk 的中心附近各放 1 个体素（保证 has_chunk 为真 ——
func _seed_chunks(d: QVoxelSource, chunk_keys: Array) -> void:
	for ck in chunk_keys:
		d.set_voxel(Vector3i(ck) * VoxelChunk.CHUNK_SIZE + Vector3i(16, 16, 16), 1)
