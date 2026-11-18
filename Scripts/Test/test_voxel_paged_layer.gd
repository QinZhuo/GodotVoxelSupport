extends TestCase

## 游戏进程级测试：**VoxelPagedLayer 接管后的等价性安全网**。
##
## 【为什么要有这个文件】`VoxelPagedLayer` 从 `VoxelInfiniteLayer` 迁入了约 570 行 LOD 粗层
## 调度（派发 / worker / 代次 / 空结果重试 / 帧尾挂载 / 层级可见性兜底）。搬迁这类代码
## 最大的风险不是"编译不过"，而是**静默行为偏差**：粗层不生成、生成后不挂载、层级不切换、
## 边界出现空洞 —— 这些在 demo 里只能靠肉眼在特定相机位置才看得出来。
##
## 【与 test_voxel_infinite_layer.gd 的关系】那个文件钉住的是**旧层**的五条行为。
## 本文件钉住的是**接管路径**的等价断言：同一套断言换到 `paged_layer` 上跑一遍，
## 从而证明"接管后行为不变"。这是允许改旧层断言后仍然安全的前提。
##
## 【覆盖】
##   ① 接管开关：enable/disable 正确翻转 `renderer.paged_layer` 与调度归属
##   ② 配置同步：enable 时从宿主拉取 view_distance / lod_count（存量调用方只在宿主上设）
##   ③ 视锥过滤：接管后 filter_chunks 与旧层 filter_visible_chunks 结论一致
##   ④ LOD 分带：接管后分带表与 VoxelLodGrid.bands 一致，且宿主网格账本层数同步
##   ⑤ 粗层真实调度：相机在粗层带时 LOD1 block 被派发并挂载出 mesh（这是搬迁的核心）
##   ⑥ 空快照防空：数据未就绪时 worker 不得崩溃（曾越界：extract_center_from_halo）
##
## 【为什么必须在游戏进程】全部依赖真实相机（get_viewport().get_camera_3d()）与真实
## WorkerThreadPool 结果回传时机。

var _root: Node3D = null


func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null


# ① 接管开关

func test_enable_disable_flips_ownership() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var host := _make_host(tree, Vector3(0, 30, 45))
	var layer := VoxelPagedLayer.new()
	host.add_child(layer)
	layer.attach(host)

	assert_false(host.uses_paged_layer(), "未 enable 前不应声称已接管")
	layer.enable()
	assert_true(host.uses_paged_layer(), "enable 后应接管")
	assert_eq(host.paged_layer, layer, "宿主应持有同一个组件引用")

	layer.disable()
	assert_false(host.uses_paged_layer(), "disable 后应交还调度权")
	assert_true(host.paged_layer == null,
			"disable 必须解除引用：否则宿主仍在问一个已停止调度的组件要可见性 → 脏列表被过滤成空")


# ② 配置同步

func test_enable_pulls_config_from_host() -> void:
	var tree := _main_tree()
	if tree == null:
		return

	# 模拟存量调用方：只改宿主上的旋钮（它们历史上就在这里）
	var host := _make_host(tree, Vector3(0, 5, 8), 128.0, 3)
	var layer := VoxelPagedLayer.new()
	host.add_child(layer)
	var before := layer.view_distance
	layer.attach(host)
	layer.enable()

	assert_ne(layer.view_distance, before, "接管后 view_distance 应被宿主值覆盖（否则接管瞬间视野变小）")
	assert_eq(layer.view_distance, host.view_distance, "view_distance 应与宿主一致")
	assert_eq(layer.lod_count, host.lod_count, "lod_count 应与宿主一致")


# ③ 视锥过滤等价

func test_filter_matches_old_layer() -> void:
	var tree := _main_tree()
	if tree == null:
		return

	var front_far := Vector3i(0, 0, -20)
	var behind_far := Vector3i(0, 0, 20)
	var behind_near := Vector3i(0, 0, 4)
	var chunks: Array[Vector3i] = [front_far, behind_far, behind_near]

	var host := _make_host(tree, Vector3.ZERO, 32.0, 1)
	_seed(host.data, chunks)
	# 先让旧层给出基线结论（此时还未接管）
	var old_visible := host.infinite_layer.filter_visible_chunks(chunks)
	_cleanup_tree()

	var host2 := _make_host(tree, Vector3.ZERO, 32.0, 1)
	_seed(host2.data, chunks)
	var layer := VoxelPagedLayer.new()
	host2.add_child(layer)
	layer.attach(host2)
	layer.enable()
	var new_visible := layer.filter_chunks(chunks)

	old_visible.sort()
	new_visible.sort()
	assert_eq(new_visible, old_visible, "接管后的视锥/距离过滤结论应与旧层完全一致")
	assert_true(new_visible.has(front_far), "视锥内 chunk 应保留")
	assert_true(not new_visible.has(behind_far), "远处身后的 chunk 应被剔除")
	assert_true(new_visible.has(behind_near), "近处身后的 chunk 不应被剔除")


# ④ LOD 分带与层数同步

func test_bands_and_level_count_synced() -> void:
	var tree := _main_tree()
	if tree == null:
		return

	var host := _make_host(tree, Vector3(0, 5, 8), 64.0, 3)
	var layer := VoxelPagedLayer.new()
	host.add_child(layer)
	layer.attach(host)
	layer.enable()
	# 触发一次分带重算（内部会在层数变化时同步宿主账本）
	layer.lod_count = 3
	var bands := layer.lod_outer()

	var want := VoxelLodGrid.bands(host.view_distance, 3)
	assert_eq(bands.size(), want.size(), "分带数量应等于 lod_count")
	for i in want.size():
		assert_true(absf(bands[i] - float(want[i])) < 0.001,
				"第 %d 层外半径应为 %s，实为 %s" % [i, want[i], bands[i]])
	assert_eq((host.get("_lod_meshes") as Array).size(), 3,
			"接管后宿主网格账本层数应由本组件的 _ensure_bands 同步")
	assert_eq((layer.get("_lod_pending_tasks") as Array).size(), 3,
			"本组件调度表长度应与网格账本同长（否则层索引会错位）")


# ⑤ 粗层真实调度（核心：搬迁后的 LOD 真的在工作）

func test_lod1_blocks_are_built_when_camera_far() -> void:
	var tree := _main_tree()
	if tree == null:
		return

	# 相机拉远到粗层带：LOD0 不该有网格，LOD1 应该有
	var host := _make_host(tree, Vector3(0, 30, 45), 64.0, 2)
	var layer := VoxelPagedLayer.new()
	host.add_child(layer)
	layer.attach(host)
	layer.enable()

	await _frames(90)

	var lod0_count: int = (host.get("_lod_meshes")[0] as Dictionary).size()
	var lod1_map: Dictionary = host.get("_lod_meshes")[1]
	assert_eq(lod0_count, 0, "相机在粗层带时不应有 LOD0 chunk 网格（会与粗层重叠）")
	assert_true(lod1_map.size() > 0, "相机在粗层带时 LOD1 粗层 block 必须被派发并挂载（搬迁核心断言）")
	# 每个挂载的粗层 block 必须是**真网格**（不是只占了个 key 的空壳）
	for bk in lod1_map:
		var mi: MeshInstance3D = lod1_map[bk]
		assert_true(mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0,
				"LOD1 block %s 应挂载出真实网格（空壳说明 worker 结果被丢弃/未应用）" % str(bk))


# ⑥ 空快照防空（曾经崩溃）

func test_worker_survives_empty_snapshot() -> void:
	# 数据未就绪是**正常情况**。历史上 worker 直接调 `extract_center_from_halo(halo)`，
	# 而空缓冲能拿到尺寸为 0 的 halo → 越界崩溃（`Out of bounds get index '1191'`）。
	#
	# 【实测行为】原生对空缓冲返回的是**尺寸正确但全 0** 的 halo（39304 = 34³），
	# 不是空数组。所以真正的防护不是"halo 一定是空"，而是 worker 里判 `size != 期望值`
	# 就早退 —— 两种返回形态（0 尺寸 / 全 0）都不能进 extract。
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

func _main_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## 建一个挂好数据 + 相机的渲染器（不启用 paged_layer，调用方自行决定）。
func _make_host(tree: SceneTree, cam_pos: Vector3, view_d: float = 32.0,
		lod_n: int = 1) -> VoxelRenderer:
	_root = Node3D.new()
	_root.name = "VoxelPagedLayerRoot"
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


## 释放当前场景根（同一用例里要建两个宿主做对照时用）。
func _cleanup_tree() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null


## 等 N 帧（让 WorkerThreadPool 结果回传 + 帧尾挂载跑完）。
## 【为什么用 _root.get_tree() 而不是 get_tree()】TestCase 是 RefCounted，没有 get_tree()。
func _frames(n: int) -> void:
	var tree := _main_tree()
	if tree == null:
		return
	for i in n:
		await tree.process_frame


## 在若干 chunk 中心各放 1 个体素（空 chunk 会被过滤器直接跳过）。
func _seed(data: QVoxelSource, chunk_keys: Array) -> void:
	for ck in chunk_keys:
		data.set_voxel(Vector3i(ck) * VoxelChunk.CHUNK_SIZE + Vector3i(16, 16, 16), 1)
