extends TestCase

## 外部模型体素化的**端到端**段：世界 → glTF → `MeshAccess` → 体素化 → 新世界，
## 以及"模型自带动画 → 体素帧动画"。
## 【为什么必须在游戏进程跑】`GLTFDocument.append_from_scene` 在编辑器进程下不导出网格
## （见 test_qvoxelier_mesh_export.gd 的说明），而 QVoxelier 是当游戏跑的。

const DIR := "user://mesh_voxelize_gltf"


func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	for f in ["solid.glb", "anim.glb"]:
		var p := DIR.path_join(f)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var abs := ProjectSettings.globalize_path(DIR)
	if DirAccess.dir_exists_absolute(abs):
		DirAccess.remove_absolute(abs)


## 世界 → .glb → 读回 → 体素化：几何与颜色都要活着过一遍。
func test_gltf_roundtrip_voxelizes() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR.path_join("solid.glb")
	assert_eq(QVoxelMeshExport.export(_solid_world(), path), OK, "应能导出 .glb")
	var scene := MeshAccess.load_scene(path)
	assert_true(not scene.is_empty(), "应能读回模型")
	if scene.is_empty():
		return
	var out := MeshVoxelWorld.to_world(scene, {"resolution": 16})
	assert_true(out != null, "应能体素化")
	if out == null:
		return
	var m := out.all_models()[0]
	assert_true(m.source_blocks().size() > 0, "应有体素落进块表")
	# 原模型是 6³ 实心方块，体素化后仍应是"实心块"而不是空壳
	var filled := _filled(m)
	assert_true(filled >= 120, "6³ 方块体素化后应基本实心（实得 %d）" % filled)
	assert_true(out.materials.size() >= 2, "调色板应带出至少一种颜色")


## 自带动画的 glTF → 多帧体素动画（节点变换动画，与骨骼动画同一条采样链路）。
func test_animated_gltf_becomes_voxel_frames() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR.path_join("anim.glb")
	assert_eq(_write_animated_gltf(path), OK, "应能写出带动画的 .glb")
	var scene := MeshAccess.load_scene(path)
	assert_true(not scene.is_empty(), "应能读回带动画的模型")
	if scene.is_empty():
		return
	assert_true(scene.get("animated", false), "应识别出动画")
	assert_true((scene["frames"] as Array).size() > 1, "应采样出多帧")
	var out := MeshVoxelWorld.to_world(scene, {"resolution": 8})
	assert_true(out != null, "动画模型应能体素化")
	if out == null:
		return
	var m := out.all_models()[0]
	assert_true(m.is_animated(), "应建成体素帧动画")
	assert_eq(m.frame_count(), (scene["frames"] as Array).size(), "帧数与采样帧数一致")


# 内部

func _solid_world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("solid")
	var red := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(8, 8, 8))
	m.fill_box(Vector3i(1, 1, 1), Vector3i(6, 6, 6), red)
	return w


func _filled(m: QVoxelModel) -> int:
	var data := m.read_box(Vector3i.ZERO, m.grid_size)
	var n := 0
	for v in data:
		if v > 0:
			n += 1
	return n


## 造一个"立方体 + 位移动画"的场景并写成 .glb（游戏进程下 append_from_scene 才真的导出网格）。
func _write_animated_gltf(path: String) -> Error:
	var root := Node3D.new()
	root.name = "Animated"
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var ap := AnimationPlayer.new()
	ap.name = "Anim"
	root.add_child(ap)
	ap.owner = root
	var anim := Animation.new()
	anim.length = 1.0
	var track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(track, "Body:position")
	anim.position_track_insert_key(track, 0.0, Vector3.ZERO)
	anim.position_track_insert_key(track, 1.0, Vector3(2, 0, 0))
	var lib := AnimationLibrary.new()
	lib.add_animation("move", anim)
	ap.add_animation_library("", lib)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK and state.get_meshes().is_empty():
		err = ERR_UNAVAILABLE
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err
