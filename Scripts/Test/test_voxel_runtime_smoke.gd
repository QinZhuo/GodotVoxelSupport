extends TestCase

## 游戏进程级冒烟测试：把体素系统在**真实游戏进程**里完整跑一遍。
##
## 为什么必须有这一层：编辑器侧的纯逻辑用例碰不到场景树与真实主循环，拦不住
## "只有场景真跑起来才暴露"的 bug —— 例如 VoxelMeshBatch 的 Callable.bind 实参
## 错位曾让 worker 结果字典的键全部读错，编辑器里所有单测照样全绿，一开 demo 却是空白。
##
## 归属声明 needs_game_process() = true：由 MCP run_game_tests（或 headless --game）
## 在游戏进程内执行；编辑器侧 run_tests 会把它列为 skipped（不静默通过）。
##
## 覆盖：
##   ① 渲染管线端到端：数据 → 异步 worker → 帧尾 GPU 上传 → LOD0 网格落到 _lod_meshes[0]
##   ② 崩塌路径的材质收集（_collect_group_materials，原生批量）真跑不报错且世界被清空
##   ③ 全量破坏 destroy_all 走原生批量材质收集后世界清空

## 冒烟场景根节点。cleanup 兜底释放：用例中途失败/协程被中断时也能还原场景树，
## 避免残留节点污染后续用例。
var _smoke_root: Node3D = null


func needs_game_process() -> bool:
	return true


## runner 在每个用例后无条件调用（含失败/中断路径）→ 幂等释放场景根。
func cleanup() -> void:
	if _smoke_root != null and is_instance_valid(_smoke_root):
		_smoke_root.queue_free()
	_smoke_root = null


# ----------------------------------------------------------------------------
# ① 渲染管线端到端
# ----------------------------------------------------------------------------

func test_render_pipeline_produces_lod0_mesh() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var r := VoxelRenderer.new()
	r.visibility_mode = VoxelRenderer.VisibilityMode.FULL   # 不依赖相机，全量构建
	r.voxel_scale = 0.1
	r.data = _make_solid_data(8)
	_attach(tree, r)
	assert_true(r.data.get_voxel_count() > 0, "测试数据应含体素")

	# 异步 worker + 帧尾 GPU 上传限流：逐帧等待，出现即停（上限兜底防挂死）
	var meshes := 0
	for i in 600:
		await tree.process_frame
		meshes = _count_lod0_meshes(r)
		if meshes > 0:
			break

	assert_true(meshes > 0, "真实运行下应生成至少一个 LOD0 chunk 网格 (got=%d)" % meshes)
	assert_true(_lod0_vertex_total(r) > 0, "实心块应产生非零顶点 (got=%d)" % _lod0_vertex_total(r))


# ----------------------------------------------------------------------------
# ② 崩塌路径的材质收集
# ----------------------------------------------------------------------------

func test_validate_stability_collapses_floating_block() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	# 悬空 2×2×2 块（y=100 起，与世界任何贴地体素都不连通）→ 全量检测判全部失稳。
	# 这条路径会走 _collect_group_materials（原生批量）收集材质快照，再移除 + 生成掉落物。
	var d := _make_data_with_material()
	var positions: Array = []
	for x in 2:
		for y in 2:
			for z in 2:
				positions.append(Vector3i(10 + x, 100 + y, 10 + z))
	d.set_voxels(positions, 1)
	var before := d.get_voxel_count()
	assert_eq(before, positions.size(), "悬空块应被写入")

	var r := VoxelDestructible.new()
	r.voxel_scale = 0.1
	r.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_DEBRIS
	r.spawn_debris_on_damage = true
	r.data = d
	_attach(tree, r)

	r.validate_stability()
	assert_eq(d.get_voxel_count(), 0, "悬空块应被判定失稳并全部移除 (before=%d)" % before)
	assert_eq(r.last_collapse_count, before, "崩塌计数应等于悬空体素数")


# ----------------------------------------------------------------------------
# ③ 全量破坏
# ----------------------------------------------------------------------------

func test_destroy_all_removes_every_voxel() -> void:
	var tree := _main_tree()
	assert_true(tree != null, "游戏进程应存在主 SceneTree")
	if tree == null:
		return

	var d := _make_solid_data(8)
	var before := d.get_voxel_count()
	var r := VoxelDestructible.new()
	r.voxel_scale = 0.1
	r.data = d
	_attach(tree, r)

	r.destroy_all(false)   # 走原生批量材质收集 + 清空
	assert_eq(d.get_voxel_count(), 0, "destroy_all 应移除全部体素 (before=%d)" % before)


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 游戏进程的主 SceneTree（TestCase 是 RefCounted，无 get_tree()）。
func _main_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## 建一个冒烟场景根并把 node 挂进去（先 data 后 add_child，与真实场景一致）。
func _attach(tree: SceneTree, node: Node) -> void:
	_smoke_root = Node3D.new()
	_smoke_root.name = "VoxelSmokeRoot"
	tree.root.add_child(_smoke_root)
	_smoke_root.add_child(node)


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


## edge³ 实心块（单 chunk 内），材质 1。
func _make_solid_data(edge: int) -> VoxelData:
	var d := _make_data_with_material()
	var positions: Array = []
	for x in edge:
		for y in edge:
			for z in edge:
				positions.append(Vector3i(x, y, z))
	d.set_voxels(positions, 1)
	return d


## 统计 LOD0 层里"确实有网格"的 chunk 数（空块是 null 占位，不算）。
func _count_lod0_meshes(r: VoxelRenderer) -> int:
	if r._lod_meshes.is_empty():
		return 0
	var n := 0
	for bk in r._lod_meshes[0]:
		var mi = r._lod_meshes[0][bk]
		if mi != null and is_instance_valid(mi) and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			n += 1
	return n


## LOD0 层所有网格的首表面顶点数之和。
## 【为什么不读 r.last_solid_vertices】那是"最近一次应用的结果"的统计，而边界空邻居 chunk
## 也会被派发并以 has_data=false 回传（sv=0），结果到达顺序不确定 → 该字段可能被最后的空结果
## 覆盖成 0。直接量网格本身才是确定性的。
func _lod0_vertex_total(r: VoxelRenderer) -> int:
	if r._lod_meshes.is_empty():
		return 0
	var total := 0
	for bk in r._lod_meshes[0]:
		var mi = r._lod_meshes[0][bk]
		if mi != null and is_instance_valid(mi) and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			total += mi.mesh.surface_get_array_len(0)
	return total
