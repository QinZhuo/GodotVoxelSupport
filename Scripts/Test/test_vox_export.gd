extends TestCase

## `.vox` 导出测试：`VoxAccess.Save` 必须是 `VoxAccess.Open` 的逆运算，且"世界 → `.vox`"
## 不能把模型镜像掉。
##
## 为什么值得单独钉一遍：`.vox` 的坐标不是随手挑的约定，而是 MagicaVoxel 的 Z-up 经一次旋转
## `(x,y,z)→(x,z,-y)` 后的样子，且 `VoxelModel.size` 还额外带着"按尺寸居中 + Z 取反"那一套。
## 读写两侧一旦不再互为逆运算，症状是"导出的文件看着挺对、其实整体镜像或错开一格"——
## 对称的模型翻转后长得一模一样，肉眼几乎发现不了；而本项目**没有打开 `.vox` 的入口**
## （`.vox` 是单向出口），走一遍 UI 也验不出来。所以只能靠这里的往返比对。
##
## 覆盖：① 手搓资产逐格往返（体素 / 尺寸 / 偏移 / 调色板 / 图层）；
##      ② demo 里所有真实样例往返（含多模型 + 场景图摆放 + 隐藏图层 + 真实调色板）；
##      ③ 世界导出不镜像（Z 轴方向）；④ 文件头合法。

const TEST_DIR := "user://vox_export_test"
const SAMPLES_DIR := "res://demo"


func cleanup() -> void:
	_remove_dir(TEST_DIR)


## 写前建目录：`FileAccess.open(..., WRITE)` 不会替你造父目录，目录不存在时直接失败。
## runner 每个 test_ 方法后都会跑 cleanup 删掉 TEST_DIR，故这里每次写都要重新建。
func _save(path: String, asset: VoxAsset) -> Error:
	_ensure_dir(TEST_DIR)
	return VoxAccess.Save(path, asset)


func _ensure_dir(dir_path: String) -> void:
	var abs := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


# ----------------------------------------------------------------------------
# ① 手搓资产：把每一种落盘字段都摆上一份，逐格比对
# ----------------------------------------------------------------------------

func test_roundtrip_hand_built() -> void:
	var src := _build_asset()
	var path := TEST_DIR + "/hand.vox"
	assert_eq(_save(path, src), OK, "应能写出文件")
	var back := VoxAsset.from_asset(path)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	assert_eq(back.models.size(), 1, "模型数应一致")
	assert_eq(back.models[0].size, src.models[0].size,
			"尺寸应逐轴一致（读口的 SIZE 分支做过轴向重排，写口必须正好反着来）")
	assert_eq(back.models[0].offset, src.models[0].offset, "居中偏移由尺寸推出，故也应一致")
	assert_eq(back.models[0].voxels, src.models[0].voxels, "体素表（原始坐标）应逐格一致")
	for i in [1, 42, 200, 255]:
		assert_eq(back.materials[i].color, src.materials[i].color, "调色板 %d 号色应一致" % i)
	assert_eq(back.layers.size(), src.layers.size(), "图层数应一致")
	for id in src.layers:
		assert_eq(back.layers[id].isVisible, src.layers[id].isVisible, "图层 %d 的可见性应一致" % id)


func test_roundtrip_scene_graph() -> void:
	var src := _build_asset()
	# 多摆一个模型，并给根节点加一个带位移的帧 —— 这样写出时才会真的落 nTRN / nGRP / nSHP。
	var second := VoxAsset.VoxelModel.new()
	second.size = Vector3(4, 4, 4)
	second.voxels[Vector3i(0, 0, 0)] = 7
	src.models.append(second)
	var root := VoxAsset.VoxelNode.new()
	root.id = 0
	root.child_nodes.append(1)
	root.frames[0] = VoxAsset.VoxelFrame.new()
	root.frames[0].position = Vector3(5, 3, -2)
	var group := VoxAsset.VoxelNode.new()
	group.id = 1
	group.child_nodes.append(2)
	group.child_nodes.append(3)
	for i in src.models.size():
		var shape := VoxAsset.VoxelNode.new()
		shape.id = 2 + i
		shape.frames[0] = VoxAsset.VoxelFrame.new()
		shape.frames[0].model_id = i
		src.nodes[shape.id] = shape
	src.nodes[0] = root
	src.nodes[1] = group

	var path := TEST_DIR + "/scene.vox"
	assert_eq(_save(path, src), OK, "应能写出文件")
	var back := VoxAsset.from_asset(path)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	assert_eq(back.nodes.size(), 4, "场景图节点数应一致（根 nTRN + nGRP + 两个 nSHP）")
	# 取出的体素集合把"场景图摆放 + 居中偏移"串了一遍：这是唯一能验出镜像 / 错位的那条断言。
	assert_eq(back.get_voxels(), src.get_voxels(), "按场景图摆放取出的体素集合应逐格一致")


# ----------------------------------------------------------------------------
# ② demo 里的真实样例：多模型 / 场景图 / 隐藏图层 / 真实调色板一次过
# ----------------------------------------------------------------------------

func test_roundtrip_demo_samples() -> void:
	var files := _list_vox(SAMPLES_DIR)
	assert_true(not files.is_empty(), "%s 下应至少有一个 .vox 样例" % SAMPLES_DIR)
	for src_path in files:
		var src := VoxAsset.from_asset(str(src_path))
		var name := str(src_path).get_file()
		assert_true(src != null, "应能读入 %s" % name)
		if src == null:
			continue
		var out := TEST_DIR + "/" + name
		assert_eq(_save(out, src), OK, "应能写出 %s" % name)
		var back := VoxAsset.from_asset(out)
		assert_true(back != null, "应能读回 %s" % name)
		if back == null:
			continue
		assert_eq(back.models.size(), src.models.size(), "%s 模型数应一致" % name)
		for i in src.models.size():
			assert_eq(back.models[i].size, src.models[i].size, "%s 模型 %d 尺寸应一致" % [name, i])
			assert_eq(back.models[i].voxels, src.models[i].voxels, "%s 模型 %d 体素应一致" % [name, i])
		for i in range(1, 256):
			assert_eq(back.materials[i].color, src.materials[i].color, "%s 调色板 %d 应一致" % [name, i])
		assert_eq(back.layers.size(), src.layers.size(), "%s 图层数应一致" % name)
		assert_eq(back.get_voxels(), src.get_voxels(), "%s 取出的体素集合应逐格一致" % name)


# ----------------------------------------------------------------------------
# ③ 世界 → .vox：Z 轴方向不能被翻掉
# ----------------------------------------------------------------------------

func test_world_export_is_not_mirrored() -> void:
	# 世界盒是 Y-up，而 `.vox` 的原始坐标是 Z-up 旋转后的样子（Z 落在 (-size.z, 0]）。若把
	# 世界的 z 直接取负（看起来更"对称"），导出的模型会沿 Z 前后翻转 —— 用一个只在 z 方向
	# 不对称的标记体素就能验出来。
	var world := QVoxelWorld.create_empty()
	var model := world.create_model("m", Vector3i(8, 8, 8))
	model.set_voxel(0, 0, 0, 1)
	model.set_voxel(0, 0, 7, 2)

	var asset := VoxAsset.from_world(world)
	assert_eq(asset.models.size(), 1, "整个世界应导出成一个模型")
	if asset.models.size() != 1:
		return
	assert_eq(asset.models[0].size, Vector3(8, 8, 8), "模型尺寸应取世界盒")
	assert_eq(asset.models[0].voxels.size(), 2, "两个标记体素都应在")

	var path := TEST_DIR + "/world.vox"
	assert_eq(_save(path, asset), OK, "应能写出文件")
	var back := VoxAsset.from_asset(path)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	var rendered := back.get_voxels()
	assert_eq(rendered.size(), 2, "读回后仍是两个体素")
	var low := Vector3i.ZERO
	var high := Vector3i.ZERO
	for pos in rendered:
		if rendered[pos] == 1:
			low = pos
		elif rendered[pos] == 2:
			high = pos
	assert_true(low != Vector3i.ZERO or high != Vector3i.ZERO, "两个标记体素都应被认出来")
	# 世界的 z=7 必须落在渲染后更大的 z 上；镜像会让它反过来。
	assert_true(high.z > low.z, "z=7 的体素应落在更大的 z 上（镜像会反过来：low=%s high=%s）"
			% [low, high])
	assert_eq(high.x, low.x, "x 方向不应被挪动")
	assert_eq(high.y, low.y, "y 方向不应被挪动")


# ----------------------------------------------------------------------------
# ④ 文件头与越界保护
# ----------------------------------------------------------------------------

func test_header_and_out_of_range_guard() -> void:
	var src := _build_asset()
	# 一个落在盒外的原始坐标：写进去会被 put_8 截成另一个合法字节，读回来就是"别处多了个体素"。
	# 正确行为是丢弃它（并给出警告），而不是静默写出一个变了形的模型。
	src.models[0].voxels[Vector3i(99, 99, 99)] = 3
	var path := TEST_DIR + "/guard.vox"
	assert_eq(_save(path, src), OK, "越界体素不应让写出失败")
	var back := VoxAsset.from_asset(path)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	assert_eq(back.models[0].voxels.size(), src.models[0].voxels.size() - 1, "越界体素应被丢弃")

	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "文件应存在")
	if f == null:
		return
	assert_eq(f.get_buffer(4).get_string_from_ascii(), VoxAccess.VOX_MAGIC, "魔数应是 'VOX '")
	assert_eq(f.get_32(), VoxAccess.VOX_VERSION, "版本号应是 %d" % VoxAccess.VOX_VERSION)
	f.close()


# ----------------------------------------------------------------------------
# 夹具
# ----------------------------------------------------------------------------

func _build_asset() -> VoxAsset:
	var src := VoxAsset.new()
	src.materials.resize(256)
	for i in range(1, 256):
		var m := VoxelMaterial.new()
		m.id = i
		m.color = Color8(i, 255 - i, (i * 7) & 0xFF, 255)
		src.materials[i] = m
	var model := VoxAsset.VoxelModel.new()
	model.size = Vector3(8, 6, 4)
	# 原始坐标的 Z 落在 (-size.z, 0]（见 VoxAccess.Save 的映射说明），故这里全取负值区间。
	model.voxels[Vector3i(0, 0, 0)] = 1
	model.voxels[Vector3i(7, 5, -3)] = 200
	model.voxels[Vector3i(3, 2, -1)] = 42
	src.models.append(model)
	var layer := VoxAsset.VoxelLayer.new()
	layer.id = 0
	layer.isVisible = false
	src.layers[0] = layer
	return src


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
