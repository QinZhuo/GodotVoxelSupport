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
const TMP_DIR := "user://bridge_test"


func cleanup() -> void:
	_remove_dir(TMP_DIR)


# ① 图层 ↔ 组

func test_layers_map_to_groups() -> void:
	var vox := _two_layer_asset()
	var w := vox.to_world()

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
	var w := _two_layer_asset(true, true).to_world()
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
		var w := vox.to_world()
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


# ⑥ 世界 → .vox（结构保留）→ 读回 → 世界：逐格一致

func test_world_vox_roundtrip_structured() -> void:
	_ensure_dir(TMP_DIR)
	var w := QVoxelWorld.create_empty()
	var mat := w.add_material(Color.RED)
	var g := w.create_group("layerA")
	var a := w.create_model("A", Vector3i(8, 8, 8), g)
	a.set_voxel(1, 1, 1, mat)
	a.set_voxel(6, 0, 3, mat)
	var b := w.create_model("B", Vector3i(4, 4, 4), g)
	b.set_voxel(0, 0, 0, mat)
	b.set_voxel(3, 3, 3, mat)
	b.offset = Vector3i(20, 5, -3)
	var c := w.create_model("C", Vector3i(2, 2, 2))
	c.set_voxel(1, 1, 1, mat)

	var asset := VoxAsset.from_world(w)
	assert_eq(asset.models.size(), 3, "每个模型一块（结构保留）")
	assert_eq(asset.layers.size(), 1, "一个顶层组 → 一条 LAYR")
	assert_eq(asset.layers[0].name, "layerA", "图层名 = 组名")

	var path := TMP_DIR + "/roundtrip.vox"
	assert_eq(VoxAccess.Save(path, asset), OK, "应能写出")
	var back := VoxAsset.from_asset(path)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	var w2 := back.to_world()
	assert_eq(w2.all_models().size(), 3, "读回后三个模型")
	var grp: QVoxelGroup = null
	for n in w2.nodes:
		if n is QVoxelGroup and n.node_name == "layerA":
			grp = n
	assert_true(grp != null, "读回后有名为 layerA 的组")
	if grp != null:
		assert_eq(_count_models(grp), 2, "layerA 子树里两个模型")
	# `.vox` 的 "nTRN 包 nGRP" 结构壳应在导入时被折叠 —— 不应出现匿名组。
	for n in w2.all_nodes():
		if n is QVoxelGroup:
			assert_true(not n.node_name.is_empty(), "不应有匿名组（%s）" % n.display_name())

	var s1 := _world_set(w)
	var s2 := _world_set(w2)
	assert_eq(s2.size(), s1.size(), "往返后体素总数一致")
	var missing := 0
	for k in s1:
		if not s2.has(k):
			missing += 1
	assert_eq(missing, 0, "往返后每个世界坐标都能对上（差 %d）" % missing)


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


func _count_models(group: QVoxelGroup) -> int:
	var n := 0
	for c in group.child_nodes:
		if c is QVoxelModel:
			n += 1
		elif c is QVoxelGroup:
			n += _count_models(c)
	return n


func _world_set(world: QVoxelWorld) -> Dictionary:
	var res := QVoxelEvalEngine.evaluate_world(world, QVoxelEvalContext.new())
	var out := {}
	var gs := res.grid_size
	var o := res.origin
	var i := 0
	for z in gs.z:
		for y in gs.y:
			for x in gs.x:
				if res.volume[i] > 0:
					out[Vector3i(o.x + x, o.y + y, o.z + z)] = true
				i += 1
	return out


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


func _ensure_dir(dir_path: String) -> void:
	var abs := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _remove_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path.path_join(name)))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
