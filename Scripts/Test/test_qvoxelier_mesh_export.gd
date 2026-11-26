extends TestCase

## 网格导出（glTF 2.0）的**几何侧**契约：世界 → ArrayMesh。

func test_build_mesh_has_surfaces() -> void:
	var mesh := QVoxelMeshExport.build_mesh(_world())
	assert_true(mesh != null, "有体素的世界应能生成网格")
	if mesh != null:
		assert_true(mesh.get_surface_count() >= 1, "网格应有面")
		assert_true((mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() > 0,
				"第一个 surface 应含顶点")

func test_empty_world_has_no_mesh() -> void:
	assert_true(QVoxelMeshExport.build_mesh(QVoxelWorld.create_empty()) == null,
			"空世界没有网格可导")

func test_extensions_declared() -> void:
	assert_eq(QVoxelMeshExport.EXTENSIONS, ["glb", "gltf"], "支持 .glb 与 .gltf 两种写法")

func _world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("m")
	var mat := w.add_material(Color.RED)
	var a := w.create_model("A", Vector3i(4, 4, 4))
	a.set_voxel(0, 0, 0, mat)
	a.set_voxel(3, 3, 3, mat)
	return w
