extends TestCase

## `.vox → QVoxelWorld` 桥接 + 节点摆放统一表示的测试。
## 钉死四件事：
##   ① 图层 ↔ 组一一对应（组名 = 图层名，可见性 = 图层可见性），模型挂到所属图层的组下；
##   ② 节点摆放只写 `transform`（不再有 `pos`），且位置 + 旋转都随节点树往返；
##   ③ 求值真的应用旋转（轴对齐 90° 保持整数）；
##   ④ 逐帧摆放轨道（`transform_tracks`）随文件往返，并按 ctx.frame 采样。
## 最后用 demo 真实样例验"`.vox` 取出的体素集合"与"`.vox → 世界求值"的体素数一致 ——
## 这是"两种格式显示一致"的可测代理。

const SAMPLES_DIR := "res://demo"


# ① 图层 ↔ 组

func test_layers_map_to_groups() -> void:
	var vox := _two_layer_asset()
	var w := VoxAssetWorld.to_world(vox)

	assert_eq(w.nodes.size(), 2, "两个图层各成一个组")
	var ground := w.nodes[0] as QVoxelGroup
	var hidden := w.nodes[1] as QVoxelGroup
	assert_eq(ground.node_name, "ground", "组名 = 图层名")
	assert_true(ground.visible, "可见图层 → 可见组")
	assert_eq(hidden.node_name, "hidden", "组名 = 图层名")
	assert_false(hidden.visible, "隐藏图层 → 隐藏组")

	# 可见图层的模型挂到它的组下；隐藏图层的模型**根本不进世界**（与 .vox 取景一致）。
	assert_eq(ground.child_nodes.size(), 1, "ground 组里一个模型")
	var m0 := ground.child_nodes[0] as QVoxelModel
	assert_eq(m0.model_id, 0)
	assert_eq(m0.count_solid(), 1, "模型体素存活")
	# 摆放来自 nTRN 帧位移（本夹具模型 size=1³ ⇒ 居中偏移为 0）。位移挂在**组**上，模型在组内为 0。
	assert_eq(w.world_transform(m0).origin, Vector3(1, 2, 3), "模型的世界摆放 = 场景图位移")
	assert_eq(hidden.child_nodes.size(), 0, "隐藏图层的模型不导入（组留空）")


func test_world_eval_places_models() -> void:
	var w := VoxAssetWorld.to_world(_two_layer_asset(true, true))
	var res := QVoxelEvalEngine.evaluate_world(w, QVoxelEvalContext.new())
	assert_eq(res.solid_count(), 2, "两个模型各一个体素")
	assert_eq(res.grid_size, Vector3i(2, 4, 4), "包围盒 = 两个位移点张成的盒")
	assert_eq(res.origin, Vector3i(0, 2, 0), "盒的最小角")


# ② 摆放只写 transform

func test_world_writes_transform_not_pos() -> void:
	var w := QVoxelWorld.create_empty()
	var g := w.create_group("g")
	var m := w.create_model("m", Vector3i(4, 4, 4), g)
	m.offset = Vector3i(1, 2, 3)
	var doc := w.to_document()
	var entry: Dictionary = doc.node["nodes"][0]["children"][0]
	assert_true(entry.has("transform"), "节点摆放写进 transform 键")
	assert_false(entry.has("pos"), "不再写 pos")
	assert_eq(entry["transform"]["t"], [1.0, 2.0, 3.0], "平移在 transform.t（JSON 读回是 float）")


func test_world_rotation_roundtrips() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(3, 1, 1))
	m.set_voxel(2, 0, 0, mat)
	m.local_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(5, 0, 0))

	var rep := QVoxelFile.QVoxelReport.new()
	var parsed := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true, rep, true)
	assert_true(rep.warnings.is_empty(), "回环无告警（%s）" % str(rep.warnings))
	var w2 := QVoxelWorld.from_document(parsed)
	var m2 := w2.all_models()[0]
	assert_true(m2.local_transform.origin.is_equal_approx(Vector3(5, 0, 0)), "位置存活")
	assert_true(m2.local_transform.basis.get_rotation_quaternion().is_equal_approx(
			Quaternion(Vector3.UP, PI / 2.0)), "旋转存活")


# ③ 求值应用旋转

func test_eval_applies_axis_aligned_rotation() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(3, 1, 1))
	m.set_voxel(2, 0, 0, mat)
	m.local_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO)
	var res := QVoxelEvalEngine.evaluate_world(w, QVoxelEvalContext.new())
	assert_eq(res.solid_count(), 1, "体素数不变")
	assert_eq(res.grid_size, Vector3i(1, 1, 3), "绕 Y 转 90° 后 x/z 尺寸互换（仍是整数）")


# ④ 逐帧摆放轨道

func test_transform_tracks_roundtrip_and_eval() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(1, 1, 1))
	m.set_voxel(0, 0, 0, mat)
	m.local_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 0))
	m.transform_tracks = [Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)),
			Transform3D(Basis.IDENTITY, Vector3(0, 7, 0))]

	var rep := QVoxelFile.QVoxelReport.new()
	var parsed := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true, rep, true)
	var w2 := QVoxelWorld.from_document(parsed)
	var m2 := w2.all_models()[0]
	assert_eq(m2.transform_tracks.size(), 2, "轨道两帧存活")
	assert_eq(m2.transform_tracks[1].origin, Vector3(0, 7, 0), "第 1 帧位移存活")

	var ctx := QVoxelEvalContext.new()
	ctx.frame = 1
	var res := QVoxelEvalEngine.evaluate_world(w2, ctx)
	assert_eq(res.solid_count(), 1)
	assert_eq(res.origin, Vector3i(0, 7, 0), "求值按第 1 帧摆放")


# ⑤ demo 真实样例：.vox 取出的体素集合 ↔ .vox→世界求值（体素数一致）

func test_demo_samples_parity() -> void:
	var files := _list_vox(SAMPLES_DIR)
	assert_true(not files.is_empty(), "%s 下应至少有一个 .vox 样例" % SAMPLES_DIR)
	for path in files:
		var name := str(path).get_file()
		var vox := VoxAsset.from_asset(str(path))
		assert_true(vox != null, "应能读入 %s" % name)
		if vox == null:
			continue
		var expected := vox.get_voxels().size()
		var w := VoxAssetWorld.to_world(vox)
		var got := QVoxelEvalEngine.evaluate_world(w, QVoxelEvalContext.new()).solid_count()
		assert_eq(got, expected, "%s：.vox 体素数应与 .vox→世界求值一致" % name)
		# 同一世界经 .qvx 字节往返后仍一致（对"显示一致"的序列化侧代理）。
		var rep := QVoxelFile.QVoxelReport.new()
		var parsed := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true, rep, true)
		assert_true(parsed != null, "%s：应能解析回去（%s）" % [name, rep.summary()])
		if parsed == null:
			continue
		var w2 := QVoxelWorld.from_document(parsed)
		var got2 := QVoxelEvalEngine.evaluate_world(w2, QVoxelEvalContext.new()).solid_count()
		assert_eq(got2, expected, "%s：.qvx 往返后体素数一致" % name)


## ⑦ 编辑器：体素数据本地化（不含摆放），摆放由 world_transform 提供（渲染器承载）

func test_editor_data_is_local() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var a := w.create_model("A", Vector3i(8, 8, 8))
	a.set_voxel(0, 0, 0, mat)
	var b := w.create_model("B", Vector3i(4, 4, 4))
	b.offset = Vector3i(16, 0, 0)
	b.set_voxel(0, 0, 0, mat)

	var s := QVoxelierSession.new()
	s.install(w, a)
	var sb := s.session_for(b.model_id)
	assert_true(sb != null, "B 有编辑会话")
	if sb == null:
		return
	sb.data._ensure_volume()
	assert_true(sb.data.has_voxel(Vector3i.ZERO), "B 的数据是本地坐标（(0,0,0) 有体素）")
	assert_false(sb.data.has_voxel(Vector3i(16, 0, 0)), "摆放不再烘进数据")
	assert_eq(sb.data.output_grid_size(), Vector3i(4, 4, 4), "数据盒 = 模型尺寸")
	assert_eq(w.world_transform(b).origin, Vector3(16, 0, 0), "摆放由 world_transform 提供")


## ⑧ 改尺寸命令：可撤销，且能还原盒外被丢掉的体素

func test_resize_command_undo_restores_voxels() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(4, 4, 4))
	m.set_voxel(3, 3, 3, mat)   # 缩小到 2³ 时会被丢掉
	m.set_voxel(0, 0, 0, mat)

	var cmd := QVoxelResizeCommand.apply(m, Vector3i(2, 2, 2))
	assert_true(cmd != null, "应产生一条改尺寸命令")
	assert_eq(m.grid_size, Vector3i(2, 2, 2), "已缩小")
	assert_eq(m.count_solid(), 1, "盒外的 (3,3,3) 被丢，盒内 (0,0,0) 保留")
	cmd.undo()
	assert_eq(m.grid_size, Vector3i(4, 4, 4), "撤销恢复尺寸")
	assert_eq(m.count_solid(), 2, "撤销把被丢的体素也还原回来")
	cmd.redo()
	assert_eq(m.grid_size, Vector3i(2, 2, 2), "重做再缩小")
	assert_eq(m.count_solid(), 1, "重做后仍是盒内那一个")


## ⑨ 逐帧摆放轨道：world_transform（渲染器摆放的唯一来源）按当前帧取轨道

func test_transform_track_preview() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(1, 1, 1))
	m.set_voxel(0, 0, 0, mat)
	m.local_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	m.transform_tracks = [Transform3D(Basis.IDENTITY, Vector3.ZERO),
			Transform3D(Basis.IDENTITY, Vector3(0, 7, 0))]
	w.preview_frame = 1
	assert_eq(w.world_transform(m).origin, Vector3(0, 7, 0), "world_transform 按共享帧取摆放轨道")
	w.preview_frame = 0
	assert_eq(w.world_transform(m).origin, Vector3.ZERO, "第 0 帧回到静态摆放")


## ⑩ `.vox` 多帧 nTRN → transform_tracks（摆放动画导入）

func test_vox_transform_animation_import() -> void:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	vox.models.append(_one_voxel_model())
	# node0 root → node1 nGRP → node2 nTRN(两帧位移) → node3 nSHP(model0)
	vox.nodes[0] = _trn(0, 1, -1, Vector3.ZERO)
	vox.nodes[1] = _grp(1, [2])
	var anim := VoxAsset.VoxelNode.new()
	anim.id = 2
	anim.child_nodes.append(3)
	var fa := VoxAsset.VoxelFrame.new()
	fa.position = Vector3(0, 0, 0)
	var fb := VoxAsset.VoxelFrame.new()
	fb.position = Vector3(0, 7, 0)
	anim.frames[0] = fa
	anim.frames[1] = fb
	vox.nodes[2] = anim
	vox.nodes[3] = _shp(3, 0)

	var w := VoxAssetWorld.to_world(vox)
	var found: QVoxelGroup = null
	for n in w.all_nodes():
		if n is QVoxelGroup and n.transform_tracks.size() == 2:
			found = n
	assert_true(found != null, "应导入一个带逐帧摆放轨道的组")
	if found != null:
		w.preview_frame = 1
		assert_eq(w.world_transform(found).origin, Vector3(0, 7, 0), "第 1 帧位移")
		w.preview_frame = 0
		assert_eq(w.world_transform(found).origin, Vector3.ZERO, "第 0 帧位移")


## ⑪ 模型内部旋转：绕选区中心，90° 整数旋转，四圈归位

func test_rotate_selection_in_model() -> void:
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(8, 8, 8))
	m.set_voxel(0, 1, 0, mat)
	var s := QVoxelierSession.new()
	s.install(w, m)
	var sess := s.session_for(m.model_id)
	assert_true(sess != null, "有编辑会话")
	if sess == null:
		return
	# 3×3 的对称盒：绕中心转 90° 后盒形不变，故连转四圈必回原位。
	sess.selection = QVoxelSelection.from_corners(Vector3i(0, 0, 0), Vector3i(2, 2, 0))
	assert_true(sess.rotate_selection(1, 1) > 0, "绕 Y 转 90° 应改动体素")
	assert_eq(m.count_solid(), 1, "旋转不改变体素数")
	assert_true(sess.rotate_selection(1, 3) > 0, "再转 270°")
	assert_true(m.get_voxel(0, 1, 0) > 0, "转满 360° 回到原位")


# 夹具

## 两个图层 + 两个单格模型 + 带位移的场景图。模型 size=1³ ⇒ 居中偏移为 0，摆放即帧位移。
func _two_layer_asset(a_visible := true, b_visible := false) -> VoxAsset:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	for i in range(1, 256):
		var mat := VoxelMaterial.new()
		mat.id = i
		mat.color = Color8(i, 255 - i, 0, 255)
		vox.materials[i] = mat
	vox.models.append(_one_voxel_model())
	vox.models.append(_one_voxel_model())

	var l0 := VoxAsset.VoxelLayer.new()
	l0.id = 0
	l0.name = "ground"
	l0.isVisible = a_visible
	vox.layers[0] = l0
	var l1 := VoxAsset.VoxelLayer.new()
	l1.id = 1
	l1.name = "hidden"
	l1.isVisible = b_visible
	vox.layers[1] = l1

	# 场景图：node0 nTRN(根) → node1 nGRP → { node2 nTRN(layer0) → node3 nSHP(model0),
	#                                            node4 nTRN(layer1) → node5 nSHP(model1) }
	vox.nodes[0] = _trn(0, 1, -1, Vector3.ZERO)
	vox.nodes[1] = _grp(1, [2, 4])
	vox.nodes[2] = _trn(2, 3, 0, Vector3(1, 2, 3))
	vox.nodes[3] = _shp(3, 0)
	vox.nodes[4] = _trn(4, 5, 1, Vector3(0, 5, 0))
	vox.nodes[5] = _shp(5, 1)
	return vox


func _one_voxel_model() -> VoxAsset.VoxelModel:
	var m := VoxAsset.VoxelModel.new()
	m.size = Vector3(1, 1, 1)
	m.voxels[Vector3i(0, 0, 0)] = 1
	return m


func _trn(id: int, child: int, layer: int, pos: Vector3) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	n.layerId = layer
	n.child_nodes.append(child)
	var f := VoxAsset.VoxelFrame.new()
	if pos != Vector3.ZERO:
		f.position = pos
	n.frames[0] = f
	return n


func _grp(id: int, children: Array) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	for c in children:
		n.child_nodes.append(c)
	return n


func _shp(id: int, model_id: int) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	var f := VoxAsset.VoxelFrame.new()
	f.model_id = model_id
	n.frames[0] = f
	return n


func _list_vox(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".vox"):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

