extends TestCase

const Baker := preload("res://addons/VoxelSupport/Model/QVoxelRigBaker.gd")

## Baker：骨骼/摆放动画 → ANIM 体素帧。
## 钉住四件事：
##   1) 每个源体素在烘焙帧里仍然只占体素格（不拉伸、不复制）；
##   2) 90° 旋转后位置正确，且跨帧的包围盒只分配一次网格；
##   3) on twos（frame_step）只采样一半帧，duration_ms 跟着变；
##   4) 关节补洞 / 隐藏模型 / 材质最近邻 / 根节点静止参考系都按选项工作。

const BS := QVoxelSpec.DEFAULT_BLOCK_SIZE


func _world() -> QVoxelWorld:
	return QVoxelWorld.create_empty()


func _count(frame: QVoxelFrame) -> int:
	return _count_blocks(frame.blocks)


func _count_blocks(blocks: Dictionary) -> int:
	var n := 0
	for bk: Vector3i in blocks:
		var buf: PackedInt32Array = blocks[bk]
		for m in buf:
			if m != 0:
				n += 1
	return n


func _materials(frame: QVoxelFrame) -> Dictionary:
	var out := {}
	for bk: Vector3i in frame.blocks:
		var buf: PackedInt32Array = frame.blocks[bk]
		for m in buf:
			if m != 0:
				out[m] = true
	return out


func test_static_part_bakes_one_frame_and_preserves_origin() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(2, 3, 4, 1)

	var baked := Baker.bake(w, root, {"padding": 0})
	assert_true(baked != null, "应能烘焙")
	if baked == null:
		return
	assert_eq(baked.frame_count(), 1, "静态部件只烘一帧")
	assert_eq(baked.grid_size, Vector3i(1, 1, 1), "单个体素时网格为 1³")
	assert_eq(baked.local_transform.origin, Vector3(2, 3, 4), "网格偏移要保住原位置")
	assert_eq(_count(baked.frame_at(0)), 1, "仍然只有一个体素")
	assert_eq(_materials(baked.frame_at(0)).keys(), [1], "材质 ID 原样保留")


func test_rotation_keeps_one_voxel_and_fits_all_frames() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(0, 0, 0, 1)
	m.transform_tracks = [
		Transform3D.IDENTITY,
		Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO),
	]

	var baked := Baker.bake(w, root, {"padding": 0})
	assert_true(baked != null)
	if baked == null:
		return
	assert_eq(baked.frame_count(), 2, "两帧轨道 → 两帧烘焙")
	assert_eq(_count(baked.frame_at(0)), 1, "第 0 帧仍是 1 个体素")
	assert_eq(_count(baked.frame_at(1)), 1, "第 1 帧仍是 1 个体素（没有被拉伸/复制）")
	# 第 0 帧体素在 (0,0,0)，第 1 帧绕 Y +90° 后在 (0,0,-1)
	assert_eq(baked.grid_size, Vector3i(1, 1, 2), "跨帧只分配一次网格")
	assert_eq(baked.local_transform.origin, Vector3(0, 0, -1), "偏移取两帧并集")


func test_rotated_cube_keeps_exact_voxel_count() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("cube", Vector3i(16, 16, 16), root)
	for z in 2:
		for y in 2:
			for x in 2:
				m.set_voxel(x, y, z, 1)
	m.transform_tracks = [
		Transform3D.IDENTITY,
		Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO),
	]

	var baked := Baker.bake(w, root, {"padding": 0})
	assert_true(baked != null)
	if baked == null:
		return
	assert_eq(_count(baked.frame_at(0)), 8, "2³ 立方体原样 8 格")
	assert_eq(_count(baked.frame_at(1)), 8, "90° 旋转后仍然 8 格（不拉伸、不重复）")


func test_on_twos_samples_every_other_frame_and_sets_duration() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(0, 0, 0, 1)
	m.transform_tracks = [
		Transform3D.IDENTITY,
		Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)),
		Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)),
		Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)),
		Transform3D(Basis.IDENTITY, Vector3(4, 0, 0)),
	]

	var baked := Baker.bake(w, root, {"frame_step": 2, "source_fps": 12, "padding": 0})
	assert_true(baked != null)
	if baked == null:
		return
	assert_eq(baked.frame_count(), 3, "0/2/4 三帧")
	assert_eq(baked.anim_fps, 12, "源帧率保留")
	for i in baked.frame_count():
		assert_eq(baked.frame_at(i).duration_ms, 167, "on twos 每帧 2×1000/12 四舍五入 = 167ms")


func test_fill_gaps_closes_one_voxel_joint_gap() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var a := w.create_model("a", Vector3i(16, 16, 16), root)
	a.set_voxel(0, 0, 0, 1)
	var b := w.create_model("b", Vector3i(16, 16, 16), root)
	b.set_voxel(2, 0, 0, 1)

	var raw := Baker.bake(w, root, {"padding": 0, "fill_gaps": false})
	assert_true(raw != null)
	if raw == null:
		return
	assert_eq(_count(raw.frame_at(0)), 2, "不补洞时中间是空的")

	var filled := Baker.bake(w, root, {
		"padding": 0, "fill_gaps": true, "gap_min_neighbors": 2})
	assert_true(filled != null)
	if filled == null:
		return
	assert_eq(_count(filled.frame_at(0)), 3, "6 邻域达到阈值后补上关节洞")


func test_hidden_models_can_be_skipped() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var a := w.create_model("a", Vector3i(16, 16, 16), root)
	a.set_voxel(0, 0, 0, 1)
	var b := w.create_model("b", Vector3i(16, 16, 16), root)
	b.set_voxel(4, 0, 0, 2)
	b.visible = false

	var hidden := Baker.bake(w, root, {"padding": 0})
	assert_true(hidden != null)
	if hidden == null:
		return
	assert_eq(_count(hidden.frame_at(0)), 1, "隐藏模型默认不参与")

	var all := Baker.bake(w, root, {"padding": 0, "include_hidden": true})
	assert_true(all != null)
	if all == null:
		return
	assert_eq(_count(all.frame_at(0)), 2, "include_hidden=true 时一起烘")


func test_materials_stay_nearest_neighbour() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var a := w.create_model("a", Vector3i(16, 16, 16), root)
	a.set_voxel(0, 0, 0, 1)
	a.set_voxel(1, 0, 0, 2)

	var baked := Baker.bake(w, root, {"padding": 0})
	assert_true(baked != null)
	if baked == null:
		return
	var mats := _materials(baked.frame_at(0))
	assert_true(mats.has(1) and mats.has(2), "材质 ID 只做最近邻搬运，不做颜色混合")


func test_bake_returns_detached_model_and_can_attach_after() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(0, 0, 0, 1)

	var baked := Baker.bake(w, root, {"padding": 0, "name": "Baked"})
	assert_true(baked != null)
	if baked == null:
		return
	assert_false(w.all_models().has(baked), "bake 不自动挂进世界（否则会被当成源部件）")
	assert_true(w.attach_node(baked, root, -1), "烘焙后可挂到根组下")
	assert_eq(w.find_parent(baked), root, "产物挂在根组下，跟着根节点的运动走")


func test_hidden_nodes_are_not_imported() -> void:
	var w := _world()
	w.add_material(Color.RED)
	var root := w.create_group("Rig")
	root.visible = false
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(0, 0, 0, 1)

	var doc := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()))
	assert_true(doc != null, "工程应能往返")
	if doc == null:
		return
	var asset := QVoxelAsset.from_document(doc)
	assert_true(asset.all_model_ids().is_empty(), "隐藏子树里的模型不进运行时资产")
	assert_true(asset.fused_voxels(0).is_empty(), "隐藏模型不产生融合体素")
	assert_true(asset.is_empty(), "只有隐藏模型的资产视为空")


func test_bake_into_rejects_target_inside_source_subtree() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.set_voxel(0, 0, 0, 1)
	var target := w.create_model("target", Vector3i(16, 16, 16), root)

	assert_false(Baker.bake_into(w, root, target, {"padding": 0}),
			"目标在源子树里时必须拒绝，避免边读边写")


func test_model_root_bakes_its_own_tracks_even_with_root_motion_flag() -> void:
	var w := _world()
	var m := w.create_model("root", Vector3i(16, 16, 16))
	m.set_voxel(0, 0, 0, 1)
	m.transform_tracks = [
		Transform3D.IDENTITY,
		Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)),
	]

	# 根是模型时没有"另一个节点"可以承载 root motion，它的轨道必须烘进体素。
	var baked := Baker.bake(w, m, {"padding": 0, "exclude_root_motion": true})
	assert_true(baked != null)
	if baked == null:
		return
	assert_eq(baked.frame_count(), 2, "单模型根的轨道也要烘")
	assert_eq(_count(baked.frame_at(0)), 1)
	assert_eq(_count(baked.frame_at(1)), 1)


func test_bake_space_uses_root_rest_and_keeps_offset() -> void:
	var w := _world()
	var root := w.create_group("Rig")
	root.local_transform.origin = Vector3(10, 0, 0)
	var m := w.create_model("part", Vector3i(16, 16, 16), root)
	m.local_transform.origin = Vector3(2, 0, 0)
	m.set_voxel(0, 0, 0, 1)

	var baked := Baker.bake(w, root, {"padding": 0})
	assert_true(baked != null)
	if baked == null:
		return
	assert_eq(baked.local_transform.origin, Vector3(2, 0, 0),
			"烘焙空间是根节点局部空间：根自己的偏移不烘进体素")
