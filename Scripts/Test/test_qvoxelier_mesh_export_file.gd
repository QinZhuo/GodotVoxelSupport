extends TestCase

## 网格导出（glTF 2.0）的**落盘侧**契约：世界 → `.glb` → 读回一个带面的网格。
## 【为什么必须在游戏进程跑】`GLTFDocument.append_from_scene` 在编辑器进程下不导出网格
## （见 test_qvoxelier_mesh_export.gd 的说明）；而 QVoxelier 是当游戏跑的，故这里验真实路径。

const DIR := "user://qvoxelier_mesh_export_file"


## 依赖 `GLTFDocument` 的真实导出行为（编辑器进程下不成立）。
func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	var abs := ProjectSettings.globalize_path(DIR)
	for f in ["m.glb"]:
		if FileAccess.file_exists(DIR + "/" + f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "/" + f))
	if DirAccess.dir_exists_absolute(abs):
		DirAccess.remove_absolute(abs)


func test_export_glb_roundtrips() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR + "/m.glb"
	assert_eq(QVoxelMeshExport.export(_world(), path), OK, "应能导出 .glb")
	assert_true(FileAccess.file_exists(path), "文件真的落盘")

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	assert_eq(doc.append_from_file(path, state), OK, "导出的 .glb 应能被读回")
	var scene := doc.generate_scene(state)
	var found := scene.find_children("*", "MeshInstance3D", true, false)
	assert_eq(found.size(), 1, "读回一个网格实例")
	if found.size() == 1:
		assert_true((found[0].mesh as Mesh).get_surface_count() >= 1, "网格有面")


func _world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("m")
	var mat := w.add_material(Color.RED)
	var a := w.create_model("A", Vector3i(4, 4, 4))
	a.set_voxel(0, 0, 0, mat)
	a.set_voxel(3, 3, 3, mat)
	return w
