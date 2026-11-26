extends TestCase

## 体素网格几何内核回归测试（编辑器进程即可，无需游戏进程）。

const SAMPLES_DIR := "res://demo/samples"
## deer.qvx 端到端基线（Phase 0 对照实验：GDScript 旧路径与 C++ 新路径同为 1260）。
const DEER_CUBE_TRIS := 1344

# 内核黄金值（合成模型，不依赖任何资产）

## 单个体素 → 6 面 × 2 三角
func test_kernel_isolated_voxel() -> void:
	var m := _gen_cube(_model([[Vector3i(0, 0, 0), 1]]), [_mat(1)])
	assert_eq(m.get_surface_count(), 1, "单个体素应只有 1 个 surface")
	assert_eq(_tris(m), 12, "单个体素应为 12 三角")

## 贪婪合并：同材质共面格子并成矩形。
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
func test_kernel_seam_invisible_between_solid_materials() -> void:
	var m := _gen_cube(_model([
		[Vector3i(0, 0, 0), 1],
		[Vector3i(1, 0, 0), 2],
	]), [_mat(1), _mat(2)])
	assert_eq(m.get_surface_count(), 1, "两种实心材质应同在实体 surface")
	assert_eq(_tris(m), 20, "相邻不同实心材质应为 20 三角（接缝不可见且不跨材质合并）")

## 透明分流：实心与透明相邻时接缝两侧都可见（透明类型不同 → 可见）
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

# 端到端基线（真实 .qvx 走完整导入路径）

## deer.qvx 走 VoxelMeshGenerator.generate_mesh_from_qvx（真实导入入口）的三角形数基线。
func test_kernel_deer_sample_baseline() -> void:
	var path := SAMPLES_DIR + "/deer.qvx"
	if not FileAccess.file_exists(path):
		assert_true(false, "样例 deer.qvx 应存在（端到端基线依赖它）")
		return
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		assert_true(false, "应能从 .qvx 解析出 QVoxelAsset")
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
	var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh_from_qvx(qvx, opts, path)
	assert_true(mesh != null, "应为 deer.qvx 生成网格")
	if mesh == null:
		return
	assert_eq(_tris(mesh), DEER_CUBE_TRIS, "deer.qvx 立方体路径三角形数应与基线一致")

	# 跨格式一致性：同一个模型走 `.vox → mesh` 必须得出同一个数字。
	var vox := VoxAsset.from_asset("res://demo/deer.vox")
	assert_true(vox != null, "应能解析 deer.vox")
	if vox != null:
		var vmesh: ArrayMesh = VoxelMeshGenerator.generate_mesh(vox, opts, "res://demo/deer.vox")
		assert_true(vmesh != null, "应为 deer.vox 生成网格")
		if vmesh != null:
			assert_eq(_tris(vmesh), DEER_CUBE_TRIS, "同一模型 .vox→mesh 的三角形数应与 .qvx 一致")

# 辅助

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
