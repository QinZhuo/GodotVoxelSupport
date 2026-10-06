extends TestCase

## 体素网格几何内核回归测试（编辑器进程即可，无需游戏进程）。
##
## 背景：编辑器导入网格（VoxelMeshGenerator）的几何生成已全量下沉 C++
## （VoxelNative.generate_arrays_native / generate_spheres_native），GDScript 侧
## 只负责材质与引擎 API 组装。原先"GDScript 生成 ↔ C++ 生成"的对照探针是一次性的，
## 用完即删，内核一改就没有任何东西会报警。
##
## 所以这里用**手算可验证的黄金三角形数**钉住内核行为（注意贪婪合并会把共面同材质格
## 并成矩形，所以数字不是简单的"面数 × 2"）：
##   · 单个体素 = 6 面 × 2 三角 = 12（无可合并的相邻格）；
##   · 均匀材质长方体无论边长，贪婪合并后恰好塌成 6 个矩形 = 12 三角（2 体素 / 2×2×2 皆然）；
##   · 相邻不同实心材质：接缝不可见、且不跨材质合并 → 各 5 矩形 = 10，共 20；
##   · 透明体素单独进 trans 桶，与实心体素相邻时接缝仍然可见（两侧各 6 面 = 12/12）；
##   · icosphere 细分 0/2 分别为 20 / 320 三角（20 × 4^sub）;
##   · deer.qvox 全量走一遍真实导入路径，钉住端到端基线。
##
## 这些数字一旦变化就说明内核发生了非预期漂移（贪心合并粒度、面可见性规则、
## 分桶逻辑、球体细分等），而不是"测试写错了"——改动内核时刻意调整数字须同期说明。

const SAMPLES_DIR := "res://demo/samples"
## deer.qvox 端到端基线（Phase 0 对照实验：GDScript 旧路径与 C++ 新路径同为 1260）。
##
## 【为什么现在是 1344】贪婪合并**逐 32³ 块**进行，模型跨块时面片会在块边界被切开，所以这个
## 数字依赖的是**分块布局**，不只是体素排列：旧样例把坐标重映射到 (0,0,0) 起（整只鹿落在 1 个
## 块内）→ 1260；样例改按 `world_origin` 坐标重烘后跨 4 个块 → 1344——而这正是 `.vox` 网格
## 一直以来的值（下面的跨格式断言即是守卫）。重烘样例时这个数字合法地会变，须同期说明原因。
const DEER_CUBE_TRIS := 1344


# ----------------------------------------------------------------------------
# 内核黄金值（合成模型，不依赖任何资产）
# ----------------------------------------------------------------------------

## 单个体素 → 6 面 × 2 三角
func test_kernel_isolated_voxel() -> void:
	var m := _gen_cube(_model([[Vector3i(0, 0, 0), 1]]), [_mat(1)])
	assert_eq(m.get_surface_count(), 1, "单个体素应只有 1 个 surface")
	assert_eq(_tris(m), 12, "单个体素应为 12 三角")


## 贪婪合并：同材质共面格子并成矩形。
## 均匀材质的轴对齐长方体最终恰好塌成 6 个矩形 = 12 三角（与边长无关）。
## 这同时钉住了"接缝不可见"——否则 2 体素会是 20 而非 12。
func test_kernel_greedy_merge_uniform_box() -> void:
	var two := _gen_cube(_model([
		[Vector3i(0, 0, 0), 1],
		[Vector3i(1, 0, 0), 1],
	]), [_mat(1)])
	assert_eq(two.get_surface_count(), 1, "同材质应合并到同一 surface")
	assert_eq(_tris(two), 12, "2 个同材质体素应合并为 6 矩形 = 12 三角")

	var cells := []
	for z in 2:
		for y in 2:
			for x in 2:
				cells.append([Vector3i(x, y, z), 1])
	var cube := _gen_cube(_model(cells), [_mat(1)])
	assert_eq(cube.get_surface_count(), 1, "实心块应只有 1 个 surface")
	assert_eq(_tris(cube), 12, "2×2×2 均匀实心块应塌成 6 矩形 = 12 三角")


## 实心-实心接缝不可见（面可见性规则），且不同材质共面**不可**合并：
## 两个体素各失去 1 个接缝面 → 各 5 矩形 = 10 三角，共 20。
## 与上一条组合即可区分"接缝隐藏"与"贪婪合并"两种效应。
func test_kernel_seam_invisible_between_solid_materials() -> void:
	var m := _gen_cube(_model([
		[Vector3i(0, 0, 0), 1],
		[Vector3i(1, 0, 0), 2],
	]), [_mat(1), _mat(2)])
	assert_eq(m.get_surface_count(), 1, "两种实心材质应同在实体 surface")
	assert_eq(_tris(m), 20, "相邻不同实心材质应为 20 三角（接缝不可见且不跨材质合并）")


## 透明分流：实心与透明相邻时接缝两侧都可见（透明类型不同 → 可见）
## 因此实体桶 12 三角 + 透明桶 12 三角，且必须落到两个 surface
func test_kernel_transparent_split() -> void:
	var m := _gen_cube(_model([
		[Vector3i(0, 0, 0), 1],
		[Vector3i(1, 0, 0), 2],
	]), [_mat(1), _mat(2, 0.5)])
	assert_eq(m.get_surface_count(), 2, "实心/透明应分成两个 surface")
	assert_eq(_tris_of_surface(m, 0), 12, "实体 surface 应为 12 三角")
	assert_eq(_tris_of_surface(m, 1), 12, "透明 surface 应为 12 三角")
	assert_eq(_tris(m), 24, "合计应为 24 三角（接缝两侧均可见）")


## 球体细分：icosphere 面数 = 20 × 4^subdivisions
func test_kernel_sphere_subdivisions() -> void:
	var cells := [[Vector3i(0, 0, 0), 1]]
	for subs in [[0, 20], [2, 320]]:
		var sub: int = subs[0]
		var want: int = subs[1]
		var m := _gen_sphere(_model(cells), [_mat(1)], sub)
		assert_eq(_tris(m), want, "球体细分 %d 应为 %d 三角" % [sub, want])


# ----------------------------------------------------------------------------
# 端到端基线（真实 .qvox 走完整导入路径）
# ----------------------------------------------------------------------------

## deer.qvox 走 VoxelMeshGenerator.generate_mesh_from_qvox（真实导入入口）的三角形数基线。
## 与合成模型互补：合成模型测规则，这里测"真实数据 + 真实编排"的整体结果。
## 两条路径（旧：稀疏字典 + generate_arrays_native；新：块级 halo + dense）用的是同一个
## 面生成内核与同一套块边界面归属规则，故三角形数应与基线一致——这正是本用例的意义。
func test_kernel_deer_sample_baseline() -> void:
	var path := SAMPLES_DIR + "/deer.qvox"
	if not FileAccess.file_exists(path):
		assert_true(false, "样例 deer.qvox 应存在（端到端基线依赖它）")
		return
	var qvox := QVoxAsset.from_file(path)
	if qvox == null:
		assert_true(false, "应能从 .qvox 解析出 QVoxAsset")
		return
	var opts := {
		VoxelMeshImporter.scale: 0.1,
		VoxelMeshImporter.shape: VoxelMeshImporter.Shape.cube,
		VoxelMeshImporter.sphere_subdivisions: 0,
		VoxelMeshImporter.sphere_scale: 1.0,
		VoxelMeshImporter.frame_index: 0,
		VoxelMeshImporter.unwrap_lightmap_uv2: false,
		VoxelMeshImporter.uv2_texel_size: 0.2,
		VoxelMeshImporter.import_materials_textures: false,
	}
	var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh_from_qvox(qvox, opts, path)
	assert_true(mesh != null, "应为 deer.qvox 生成网格")
	if mesh == null:
		return
	assert_eq(_tris(mesh), DEER_CUBE_TRIS, "deer.qvox 立方体路径三角形数应与基线一致")

	# 跨格式一致性：同一个模型走 `.vox → mesh` 必须得出同一个数字。
	# 这是"两种格式导入结果一致"在几何层面的守卫——原点模式、坐标或分块布局任一漂移都会打破它。
	var vox := VoxAsset.from_asset("res://demo/deer.vox")
	assert_true(vox != null, "应能解析 deer.vox")
	if vox != null:
		var vmesh: ArrayMesh = VoxelMeshGenerator.generate_mesh(vox, opts, "res://demo/deer.vox")
		assert_true(vmesh != null, "应为 deer.vox 生成网格")
		if vmesh != null:
			assert_eq(_tris(vmesh), DEER_CUBE_TRIS, "同一模型 .vox→mesh 的三角形数应与 .qvox 一致")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 由 [位置, 材质ID] 列表构造稀疏体素字典
func _model(cells: Array) -> Dictionary[Vector3i, int]:
	var model: Dictionary[Vector3i, int] = {}
	for c in cells:
		model[c[0]] = c[1]
	return model


## 构造材质（trans > 0 即透明），id 与体素值一致（0 保留为空）
func _mat(id: int, trans: float = 0.0) -> VoxelMaterial:
	var m := VoxelMaterial.new()
	m.id = id
	m.trans = trans
	return m


## 走 cube 路径生成网格；直接复用 VoxelMeshGenerator 的生成阶段，
## 绕过 VoxAsset/材质文件 IO（测试只关心几何内核）
func _gen_cube(model: Dictionary[Vector3i, int], mats: Array) -> ArrayMesh:
	return _gen(model, mats, VoxelMeshImporter.Shape.cube, 0)


## 走 sphere 路径生成网格
func _gen_sphere(model: Dictionary[Vector3i, int], mats: Array, subdivisions: int) -> ArrayMesh:
	return _gen(model, mats, VoxelMeshImporter.Shape.sphere, subdivisions)


func _gen(model: Dictionary[Vector3i, int], mats: Array, shape: int, subdivisions: int) -> ArrayMesh:
	var gen := VoxelMeshGenerator.new(null, {}, "")
	# runtime_materials 非空时优先于 voxel.materials（voxel 为 null，故必须提供）
	gen.runtime_materials = [null] + mats
	gen.materials = [StandardMaterial3D.new(), StandardMaterial3D.new()]
	gen.shape = shape
	gen.sphere_subdivisions = subdivisions
	gen.start_generate_mesh(model)
	return gen.wait_finished(false, 0.2)


## 整个网格的三角形数（索引长度 / 3）
func _tris(mesh: ArrayMesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		n += _tris_of_surface(mesh, s)
	return n


## 单个 surface 的三角形数
func _tris_of_surface(mesh: ArrayMesh, surface: int) -> int:
	var arrays := mesh.surface_get_arrays(surface)
	var idx = arrays[Mesh.ARRAY_INDEX]
	if idx is PackedInt32Array:
		return (idx as PackedInt32Array).size() / 3
	var verts = arrays[Mesh.ARRAY_VERTEX]
	return (verts as PackedVector3Array).size() / 3
