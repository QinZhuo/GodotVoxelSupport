extends TestCase

## MeshLibrary 分项**重复导入**时的重用边界：改 `.vox` 里一个模型，另外 N-1 个模型会不会跟着重建。
## 三层结论（本文件逐层钉死）：
##   ① 引擎层：一个 `.vox` = 一个导入产物，文件一改就整体重导 —— 这一层无法绕过，也不该绕；
##   ② 几何层：分项网格的落盘策略（`mesh/storage`，与 ResourceImporterScene 的 materials/extract 同构）
##      决定有没有跨导入的逐项缓存。extract_once 下未改动的项 hash 一致 → 不跑原生内核、不重写文件；
##      built_in 下每项都是新建的 ArrayMesh，缓存无从命中 → 全部重建；
##   ③ 落盘层：缓存命中的项内容与磁盘完全一致，重写它只会白刷 mtime 并让引擎丢弃资源缓存 ——
##      故 `_commit_mesh_library` 只保存本次真的重建过的项；产物一律登记进 `gen_files`，
##      由引擎纳入依赖与清理（否则项名/分项方式一变就留下孤儿文件）。
##
## 判据用**篡改哨兵**：把某一项的分项文件换成 1 个三角（3 顶点）。若该项重导后仍是 3 顶点，
## 说明它连内核都没进（缓存命中）；这是唯一能区分"重建了但结果相同"与"根本没重建"的观测手段。
##
## 另：`split_by_frame` 的每一项都是**整个资产**在某一帧的样子，改一个模型本就该让每一帧都变，
## 不存在"只重建一帧"的语义，故这里不对该模式做逐项缓存的断言。

const DIR := "user://mesh_library_reimport"


func cleanup() -> void:
	_remove_dir(DIR)


## split_by_node：改一个模型 → 只有那一项重建+落盘，其余项命中缓存（连内核都没进）。
func test_only_changed_item_is_rebuilt() -> void:
	var dir := _fresh_dir("by_node")
	var vox := _asset([1, 2, 3])
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_node, VoxelImportOptions.Storage.extract_once)
	var path := dir + "/asset.vox"

	var lib1 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_eq(_names(lib1), ["A", "B", "C"], "夹具应是三个独立顶级对象")
	var verts_before := _verts_of(lib1)

	# 篡改 C 的分项文件：清空后塞一个三角。缓存命中时它必须原样活到下一轮。
	_tamper(_child(dir, "C"))
	# mtime 只到秒，睡过一整秒才能把"重写"与"没重写"区分开。
	var mtimes_before := _mtimes(dir, ["A", "B", "C"])
	OS.delay_msec(1100)

	# 只改 A 的模型（远端加一格，与已有体素不相邻）
	vox.models[0].voxels[Vector3i(10, 0, 0)] = 1
	var lib2 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	var verts_after := _verts_of(lib2)

	assert_ne(verts_after["A"], verts_before["A"], "被改动的项应重建（顶点数应变）")
	assert_eq(verts_after["B"], verts_before["B"], "未改动的项内容应保持不变")
	assert_eq(verts_after["C"], 3, "未改动的项应命中缓存（篡改哨兵原样保留 = 连内核都没进）")

	var mtimes_after := _mtimes(dir, ["A", "B", "C"])
	assert_ne(mtimes_after["A"], mtimes_before["A"], "被改动的项应重新落盘")
	assert_eq(mtimes_after["B"], mtimes_before["B"], "未改动的项不应被重写（mtime 会被白刷）")
	assert_eq(mtimes_after["C"], mtimes_before["C"], "缓存命中的项同样不应被重写")


## split_by_model：同一套逐项缓存（按模型分项时每项就是单个模型，边界最清楚）。
func test_split_by_model_reuses_unchanged_items() -> void:
	var dir := _fresh_dir("by_model")
	var vox := _asset([1, 2, 3])
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_model, VoxelImportOptions.Storage.extract_once)
	var path := dir + "/asset.vox"

	var lib1 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_eq(_names(lib1), ["model_0", "model_1", "model_2"], "按模型分项的项名")
	var verts_before := _verts_of(lib1)
	_tamper(_child(dir, "model_1"))

	vox.models[0].voxels[Vector3i(10, 0, 0)] = 1
	var lib2 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	var verts_after := _verts_of(lib2)

	assert_ne(verts_after["model_0"], verts_before["model_0"], "被改动的项应重建")
	assert_eq(verts_after["model_1"], 3, "未改动的项应命中缓存")
	assert_eq(verts_after["model_2"], verts_before["model_2"], "其余项内容不变")


## hash 必须含全部几何输入。透明标志决定体素进 solid 还是 trans 桶 ——
## 它曾不在 hash 里：只改材质透明度（体素一个没动）会命中缓存、保留旧的单桶网格。
func test_material_transparency_invalidates_cache() -> void:
	var dir := _fresh_dir("trans")
	var vox := _asset_multi_material()
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_model, VoxelImportOptions.Storage.extract_once)
	var path := dir + "/asset.vox"

	var lib1 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_eq(lib1.get_item_mesh(0).get_surface_count(), 1, "两格都不透明时应只有 solid 一个 surface")

	vox.materials[2].trans = 0.5
	var lib2 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_eq(lib2.get_item_mesh(0).get_surface_count(), 2,
			"材质改透明后必须重建（旧 hash 会短路、留下单桶网格）")


## extract_overwrite：每次都重算并覆盖，缓存标记被主动丢弃。
## 这是"改生成逻辑但 hash 没变"时唯一能强制刷新的手段（built_in 之外的第二条路）。
func test_extract_overwrite_forces_rebuild() -> void:
	var dir := _fresh_dir("overwrite")
	var vox := _asset([2])
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_model,
			VoxelImportOptions.Storage.extract_overwrite)
	var path := dir + "/asset.vox"

	VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	_tamper(_child(dir, "model_0"))

	var lib := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_ne(_verts_of(lib)["model_0"], 3, "extract_overwrite 下篡改哨兵应被覆盖（每次都重建）")


## built_in：不落盘 → 没有可命中的缓存，改一个模型时所有项全部重建。
## 这是"改一个模型全量重建"这个现象的根因，也是三种策略里唯一的无散文件选项。
func test_built_in_rebuilds_every_item() -> void:
	var dir := _fresh_dir("built_in")
	var vox := _asset([1, 2])
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_node, VoxelImportOptions.Storage.built_in)
	var path := dir + "/asset.vox"

	var lib := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	assert_eq(lib.get_item_list().size(), 2, "两项都应生成")
	for i in lib.get_item_list():
		assert_eq(lib.get_item_mesh(i).resource_path, "", "built_in 下项网格不应有落盘路径")
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_item_dir(dir))),
			"不应产生分项目录（也就没有可命中的缓存）")

	var ids_before := _instance_ids(lib)
	var lib2 := VoxelMeshGenerator.generate_mesh_library(vox, opts, path)
	for i in lib2.get_item_list():
		assert_false(ids_before.has(lib2.get_item_mesh(i).get_instance_id()),
				"built_in 下项网格不可能被复用（每项都是新建的）")


## 分项网格是导入产物，**必须**登记进 gen_files：否则引擎不知道它们依赖源文件，
## 项名/分项方式一变就留下没人回收的孤儿。同时确认没登记主产物与不存在的路径。
func test_generated_items_are_registered() -> void:
	var dir := _fresh_dir("gen_files")
	var vox := _asset([1, 2])
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_node, VoxelImportOptions.Storage.extract_once)
	var gen_files: Array = []

	VoxelMeshGenerator.generate_mesh_library(vox, opts, dir + "/asset.vox", gen_files)
	var expected := [_child(dir, "A"), _child(dir, "B")]
	assert_eq(gen_files.size(), expected.size(), "两项都应登记（实得 %s）" % str(gen_files))
	for p in expected:
		assert_true(gen_files.has(p), "应登记 %s（实得 %s）" % [p, str(gen_files)])
		assert_true(FileAccess.file_exists(p), "登记前文件必须真的写出来了：%s" % p)

	# built_in 不产生文件，也就不该登记任何东西
	var quiet: Array = []
	VoxelMeshGenerator.generate_mesh_library(vox,
			_opts(VoxelImportOptions.MeshMode.split_by_node, VoxelImportOptions.Storage.built_in),
			dir + "/quiet.vox", quiet)
	assert_true(quiet.is_empty(), "built_in 下不应登记产物（实得 %s）" % str(quiet))


## `.qvx` 的分项走块级入口，但用的是同一套逐项缓存（块表 hash + 选项 + 原点偏移）。
## 修复前这里无条件重建：改一个模型，其余项全量重算。
func test_qvx_items_reuse_unchanged_items() -> void:
	const SAMPLE := "res://demo/samples/cars.qvx"
	if not FileAccess.file_exists(SAMPLE):
		return
	var qvx := QVoxelAsset.from_file(SAMPLE)
	assert_true(qvx != null, "应能解析 %s" % SAMPLE)
	if qvx == null:
		return
	var dir := _fresh_dir("qvx")
	var opts := _opts(VoxelImportOptions.MeshMode.split_by_node, VoxelImportOptions.Storage.extract_once)
	var path := dir + "/asset.qvx"

	var lib1 := VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, opts, path)
	assert_true(lib1.get_item_list().size() > 1, "夹具应有多项")
	if lib1.get_item_list().is_empty():
		return
	var target := lib1.get_item_name(0)
	assert_ne(_verts_of(lib1)[target], 3, "真实网格的顶点数不应与哨兵相同（否则本用例失效）")
	_tamper(dir + "/asset_qvx/" + target + ".res")

	var lib2 := VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, opts, path)
	assert_eq(_verts_of(lib2)[target], 3,
			"未改动的项应命中缓存（篡改哨兵原样保留）")


# 辅助：被测入口

func _opts(mode: int, storage: int) -> Dictionary:
	var opts := VoxelMeshLibraryImporter.default_options()
	opts[VoxelImportOptions.MESH_MODE] = mode
	opts[VoxelImportOptions.STORAGE] = storage
	return opts


## 分项目录（与 VoxelMeshGenerator._item_dir 同一规则：<stem>_<ext>）。
func _item_dir(dir: String) -> String:
	return dir + "/asset_vox"


func _child(dir: String, name: String) -> String:
	return _item_dir(dir) + "/" + name + ".res"


## 项名 → 首 surface 的顶点数。空网格记 0。
func _verts_of(lib: MeshLibrary) -> Dictionary:
	var out := {}
	for i in lib.get_item_list():
		var mesh: ArrayMesh = lib.get_item_mesh(i)
		out[lib.get_item_name(i)] = mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	return out


func _names(lib: MeshLibrary) -> Array:
	var out: Array = []
	for i in lib.get_item_list():
		out.append(lib.get_item_name(i))
	return out


## 项网格实例 id 集合：用来判定"这一项是不是上一轮那个对象"（复用 = 走了磁盘缓存）。
func _instance_ids(lib: MeshLibrary) -> Dictionary:
	var out := {}
	for i in lib.get_item_list():
		out[lib.get_item_mesh(i).get_instance_id()] = true
	return out


## 把分项网格换成"1 个三角"的哨兵：重建过的项不可能还是 3 顶点。
func _tamper(child_path: String) -> void:
	var mesh := ResourceLoader.load(child_path, "", ResourceLoader.CACHE_MODE_REPLACE) as ArrayMesh
	assert_true(mesh != null, "应有可篡改的分项文件 %s" % child_path)
	if mesh == null:
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(1, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	ResourceSaver.save(mesh, child_path)


func _mtimes(dir: String, names: Array) -> Dictionary:
	var out := {}
	for n in names:
		out[n] = FileAccess.get_modified_time(_child(dir, n))
	return out


func _fresh_dir(name: String) -> String:
	var dir := DIR + "/" + name
	_remove_dir(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _remove_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_remove_dir(full)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))


# 辅助：夹具（每个模型一个顶级对象，名字 A/B/C；counts 决定各自的体素数）

func _asset(counts: Array) -> VoxAsset:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	for i in range(1, 4):
		vox.materials[i] = _mat(i)
	vox.nodes[0] = _trn(0, 1)
	vox.nodes[1] = _grp(1, [])
	for i in counts.size():
		var model := VoxAsset.VoxelModel.new()
		model.size = Vector3(1, 1, 1)
		for k in int(counts[i]):
			model.voxels[Vector3i(k, 0, 0)] = 1
		vox.models.append(model)
		var trn_id := 2 + i * 2
		var shape_id := trn_id + 1
		var trn := _trn(trn_id, shape_id)
		trn.name = String.chr(65 + i)
		var shape := VoxAsset.VoxelNode.new()
		shape.id = shape_id
		shape.frames[0] = VoxAsset.VoxelFrame.new()
		shape.frames[0].model_id = i
		vox.nodes[trn_id] = trn
		vox.nodes[shape_id] = shape
		vox.nodes[1].child_nodes.append(trn_id)
	return vox


## 单模型两格、两种材质（不相邻 → 不参与合并），用于验证"只改透明度"必须让缓存失效。
func _asset_multi_material() -> VoxAsset:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	for i in range(1, 4):
		vox.materials[i] = _mat(i)
	vox.nodes[0] = _trn(0, 1)
	var shape := VoxAsset.VoxelNode.new()
	shape.id = 1
	shape.frames[0] = VoxAsset.VoxelFrame.new()
	shape.frames[0].model_id = 0
	vox.nodes[1] = shape
	var model := VoxAsset.VoxelModel.new()
	model.size = Vector3(1, 1, 1)
	model.voxels[Vector3i(0, 0, 0)] = 1
	model.voxels[Vector3i(2, 0, 0)] = 2
	vox.models.append(model)
	return vox


func _mat(id: int) -> VoxelMaterial:
	var m := VoxelMaterial.new()
	m.id = id
	m.color = Color8(40 * id, 200 - 20 * id, 60, 255)
	return m


func _trn(id: int, child: int) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	n.layerId = -1
	n.child_nodes.append(child)
	n.frames[0] = VoxAsset.VoxelFrame.new()
	return n


func _grp(id: int, children: Array) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	for c in children:
		n.child_nodes.append(c)
	return n
