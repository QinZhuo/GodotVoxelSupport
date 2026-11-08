extends TestCase

## MeshLibrary 三种分项（model / node / frame）的回归测试。
## 钉死的是"分项产物与整网格必须一致"这件事 —— 分项最容易出的错不是崩溃，而是**静默变成另一个模型**：
##   · split_by_node 曾把整棵子树的 nTRN 变换都丢掉（只留模型居中偏移），
##     于是多部件对象的所有部件叠在同一个中心，编辑器里看到的是一团糊掉的东西；
##   · 项名曾取自 `child_mesh.resource_name`，不开 import_meshes 时它是空的 → 每一项都没有名字。
## 判据用**独立预言机**：测试里自己累乘节点树变换算出每项应有的包围盒，
## 不复用被测实现（`VoxAsset.get_voxels` 那条递归），否则它错我也错。

const SAMPLES := ["res://demo/MixTest.vox", "res://demo/cars.vox", "res://demo/deer.vox"]
## 导入器默认 scale（体素单位 → 网格单位）
const SCALE := 0.1


# ① 分项坐标语义：只丢"项根自己的摆放"，子树内部的相对摆放必须保留

## 两个部件彼此相隔 9 格。项根自己摆得再远都不该出现在分项网格里；
## 而两部件的相对间距必须原样保留（这正是旧实现丢掉的东西）。
func test_split_by_node_keeps_child_placement() -> void:
	var lib := _split(_two_part_asset(), VoxelImportOptions.MeshMode.split_by_node)
	assert_eq(lib.get_item_list().size(), 1, "一个顶级对象 → 一项")
	if lib.get_item_list().is_empty():
		return
	var aabb: AABB = lib.get_item_mesh(0).get_aabb()
	assert_true(aabb.position.is_equal_approx(Vector3.ZERO),
			"项根自身的摆放不应进分项网格（实得 %s）" % str(aabb.position))
	assert_true(aabb.size.is_equal_approx(Vector3(1, 10, 1) * SCALE),
			"两部件的相对间距必须保留（实得 %s，期望 %s）" % [str(aabb.size), str(Vector3(1, 10, 1) * SCALE)])


## demo 真实资产逐个体检：项数、项名与包围盒都必须与独立预言机一致。
## 单顶级对象时这等价于"分项网格 == 整资产网格"，原点/坐标轴/子树变换任一漂移都会失配。
func test_split_by_node_matches_oracle() -> void:
	for path in SAMPLES:
		if not FileAccess.file_exists(path):
			continue
		var vox := VoxAsset.from_asset(path)
		assert_true(vox != null, "应能解析 %s" % path)
		if vox == null:
			continue
		var tops := _top_objects(vox)
		var lib := _split(vox, VoxelImportOptions.MeshMode.split_by_node)
		assert_eq(lib.get_item_list().size(), tops.size(),
				"%s：顶级对象 %d 个，项数应相同" % [path, tops.size()])
		for node_id in tops:
			var want_name := _name_of(vox, node_id)
			var idx := lib.find_item_by_name(want_name)
			assert_true(idx >= 0, "%s：应有名为 [%s] 的项（实得 %s）"
					% [path, want_name, _item_names(lib)])
			if idx < 0:
				continue
			assert_aabb_close(lib.get_item_mesh(idx).get_aabb(), _expected_aabb(vox, node_id),
					"%s：项 [%s] 的包围盒应与预言机一致" % [path, want_name])


# ② 分项数与命名

## 三种分项的项数 / 前后缀必须与选项语义一致。
func test_split_modes_counts_and_names() -> void:
	var vox := _two_part_asset()
	var by_model := _split(vox, VoxelImportOptions.MeshMode.split_by_model)
	assert_eq(by_model.get_item_list().size(), 2, "按模型：2 个模型 → 2 项")
	assert_eq(_item_names(by_model), ["model_0", "model_1"], "按模型的项名带 model_ 前缀")

	var by_frame := _split(vox, VoxelImportOptions.MeshMode.split_by_frame)
	assert_eq(by_frame.get_item_list().size(), 1, "静态资产只有第 0 帧")
	assert_eq(_item_names(by_frame), ["frame_0"], "按帧的项名带 frame_ 前缀")


## 无名 / 重名节点必须退化为稳定编号：项名是 MeshLibrary 项的身份，
## 空名或撞名都会让 `find_item_by_name` 失效（旧实现"名字全为空"是这个坑的极端形态）。
func test_item_names_never_empty_or_duplicated() -> void:
	var vox := _two_part_asset()
	vox.nodes[2].name = "same"
	# 再加一个同名的与一个无名的顶级对象
	vox.nodes[8] = _trn(8, 9, Vector3(50, 0, 0))
	vox.nodes[8].name = "same"
	vox.nodes[9] = _shp(9, 0)
	vox.nodes[10] = _trn(10, 11, Vector3(60, 0, 0))
	vox.nodes[11] = _shp(11, 1)
	vox.nodes[1].child_nodes.append_array([8, 10])

	var lib := _split(vox, VoxelImportOptions.MeshMode.split_by_node)
	assert_eq(lib.get_item_list().size(), 3, "三个顶级对象 → 三项")
	var seen := {}
	for nm in _item_names(lib):
		assert_true(nm != "", "项名不应为空")
		assert_false(seen.has(nm), "项名 [%s] 不应重复" % nm)
		seen[nm] = true


# ③ 边界：没有场景图的 .vox 不能崩，且仍能分项

## 无 NODE 块的文件由 `check_nodes` 兜出一个合成根节点：
## split_by_node 此时应产出 1 项且有几何，而不是空库或越界报错（本用例只钉"不崩"这一层）。
func test_split_by_node_without_scene_graph() -> void:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	vox.models.append(_unit_model())
	vox.models.append(_unit_model())
	vox.check_nodes()

	var lib := _split(vox, VoxelImportOptions.MeshMode.split_by_node)
	assert_eq(lib.get_item_list().size(), 1, "无场景图 → 全部内容归一项")
	assert_true(lib.get_item_mesh(0).get_surface_count() > 0, "该项应有几何")


# 辅助：被测入口

func _split(vox: VoxAsset, mode: int) -> MeshLibrary:
	var opts := VoxelMeshLibraryImporter.default_options()
	opts[VoxelImportOptions.MESH_MODE] = mode
	return VoxelMeshGenerator.generate_mesh_library(vox, opts, "")


func _item_names(lib: MeshLibrary) -> Array:
	var out: Array = []
	for i in lib.get_item_list():
		out.append(lib.get_item_name(i))
	return out


# 辅助：夹具

## 根 nTRN(0) → nGRP(1) → 项根 nTRN(2, _t=100) → nGRP(3) → 两个部件（间距 9 格）。
func _two_part_asset() -> VoxAsset:
	var vox := VoxAsset.new()
	vox.materials.resize(256)
	for i in range(1, 256):
		var mat := VoxelMaterial.new()
		mat.id = i
		mat.color = Color8(i, 255 - i, 0, 255)
		vox.materials[i] = mat
	vox.models.append(_unit_model())
	vox.models.append(_unit_model())

	vox.nodes[0] = _trn(0, 1, Vector3.ZERO)
	vox.nodes[1] = _grp(1, [2])
	var item_root := _trn(2, 3, Vector3(100, 0, 0))
	item_root.name = "Obj"
	vox.nodes[2] = item_root
	vox.nodes[3] = _grp(3, [4, 5])
	vox.nodes[4] = _trn(4, 6, Vector3.ZERO)
	vox.nodes[6] = _shp(6, 0)
	vox.nodes[5] = _trn(5, 7, Vector3(0, 9, 0))
	vox.nodes[7] = _shp(7, 1)
	return vox


## size=1³ ⇒ 居中偏移为 0，于是"变换 = 帧位移"，夹具断言可以手算。
func _unit_model() -> VoxAsset.VoxelModel:
	var m := VoxAsset.VoxelModel.new()
	m.size = Vector3(1, 1, 1)
	m.voxels[Vector3i(0, 0, 0)] = 1
	return m


func _trn(id: int, child: int, pos: Vector3) -> VoxAsset.VoxelNode:
	var n := VoxAsset.VoxelNode.new()
	n.id = id
	n.layerId = -1
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


# 辅助：独立预言机（不复用 VoxAsset.get_voxels 的递归）

## 顶级对象 = 根 nTRN 的孩子里容器 nGRP 的孩子（MagicaVoxel 的标准样板层级）。
func _top_objects(vox: VoxAsset) -> Array:
	if not vox.nodes.has(0) or vox.nodes[0] == null or vox.nodes[0].child_nodes.is_empty():
		return []
	var container: VoxAsset.VoxelNode = vox.nodes.get(vox.nodes[0].child_nodes[0])
	if container == null:
		return []
	return container.child_nodes


func _name_of(vox: VoxAsset, node_id: int) -> String:
	return vox.nodes[node_id].get_name(vox, 0)


## 项应有的包围盒（体素单位）：从项根开始累乘子树变换，但**不乘项根自身的变换**。
func _expected_aabb(vox: VoxAsset, node_id: int) -> AABB:
	# 体素界用数组承载：Vector3i 是值类型，递归里改副本传不出来。
	var box := {"mn": Vector3i(2147483647, 2147483647, 2147483647),
			"mx": Vector3i(-2147483648, -2147483648, -2147483648)}
	_walk(vox, node_id, Transform3D.IDENTITY, true, box)
	var mn: Vector3i = box["mn"]
	var mx: Vector3i = box["mx"]
	if mn.x > mx.x:
		return AABB()
	return AABB(Vector3(mn), Vector3(mx - mn + Vector3i.ONE))


func _walk(vox: VoxAsset, node_id: int, xf: Transform3D, is_root: bool, box: Dictionary) -> void:
	var n: VoxAsset.VoxelNode = vox.nodes.get(node_id)
	if n == null:
		return
	if not is_root:
		xf = xf * n.get_frame(0, true).transform
	var f: VoxAsset.VoxelFrame = n.frames.get(0)
	if f != null and f.model_id >= 0 and f.model_id < vox.models.size():
		var model: VoxAsset.VoxelModel = vox.models[f.model_id]
		for pos: Vector3i in model.voxels:
			var p := Vector3i(xf * (Vector3(pos) + model.offset))
			var mn: Vector3i = box["mn"]
			var mx: Vector3i = box["mx"]
			box["mn"] = Vector3i(mini(mn.x, p.x), mini(mn.y, p.y), mini(mn.z, p.z))
			box["mx"] = Vector3i(maxi(mx.x, p.x), maxi(mx.y, p.y), maxi(mx.z, p.z))
	for c in n.child_nodes:
		_walk(vox, int(c), xf, false, box)


## 包围盒比较：网格顶点是"体素单位 × scale"，故预言机结果乘 scale 再比。
func assert_aabb_close(got: AABB, want_voxels: AABB, msg: String) -> void:
	var want := AABB(want_voxels.position * SCALE, want_voxels.size * SCALE)
	var delta := (got.position - want.position).length() + (got.size - want.size).length()
	assert_true(delta < 0.01, "%s（got=%s want=%s Δ=%.4f）" % [msg, str(got), str(want), delta])
