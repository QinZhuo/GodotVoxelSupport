extends TestCase

## PCG 烘焙测试：把「有界数据层的产出」冻结成 .qvx 静态存档，重载后逐体素一致。
## 盯的是 PCG → 存储 这条接缝：数据层只在烘焙时跑一次，之后加载完全走既有 stream 通路
## （不再需要节点、不再逐体素采样）。故这里的比对对象是"数据层直接产出"与
## "从烘焙文件读回"两种取数结果 —— 二者一致才算烘焙没有丢数据。
## 用例只算数据、不碰场景树，编辑器进程即可运行。

const TEST_DIR := "user://pcg_bake"
const GRID := Vector3i(32, 32, 32)


## runner 在每个用例后无条件调用：清掉临时目录，避免残留污染下次运行。
func cleanup() -> void:
	_remove_dir(TEST_DIR)


# ① 烘焙 → 重载：读回的世界与数据层当前产出逐体素一致

func test_bake_then_reload_matches_source() -> void:
	var path := TEST_DIR + "/ball.qvx"
	var model := _make_model()
	var produced := model.generate(Vector3i.ZERO)

	var stream := QVoxelStream.new()
	stream.file_path = path
	assert_eq(model.bake_to(stream), 1, "32³ 有界模型应写出 1 个非空 chunk")

	# 重载侧：只给流、**不给节点** —— 烘焙若漏写，这里必然读不到体素
	var reload := QVoxelSource.new()
	reload.materials = model.materials
	var rs := QVoxelStream.new()
	rs.file_path = path
	reload.stream = rs

	# 参照物：把数据层产出直接装进另一个数据层，用同一套公开读取路径取快照
	var reference := QVoxelSource.new()
	reference.materials = model.materials
	reference._accept_chunk_buffer(Vector3i.ZERO, produced.duplicate())

	assert_ne(reference.get_voxels_dict_snapshot(), {}, "数据层本身应产出实心体素（前置条件）")
	assert_eq(reload.get_voxels_dict_snapshot(), reference.get_voxels_dict_snapshot(),
			"从烘焙文件读回的世界应与数据层产出一致")


# ② 无限世界（grid_size = ZERO）无范围可烘焙，必须拒绝而不是写出空文件

func test_bake_rejects_unbounded_data() -> void:
	var model := _make_model()
	model.grid_size = Vector3i.ZERO   # 无限世界：没有范围可烘焙

	var stream := QVoxelStream.new()
	stream.file_path = TEST_DIR + "/reject.qvx"
	# 该分支会 push_error（有意为之的 API 误用告警），故此处只看返回值
	assert_eq(model.bake_to(stream), -1, "无限世界应拒绝烘焙")


# 工具

## 一个有界 SDF 模型：球体 + 一个材质，尺寸 GRID。与 demo 里的组装方式同一套路。
func _make_model() -> QVoxelSource:
	var data := QVoxelSource.new()
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = Color(0.5, 0.5, 0.5)
	data.add_material(mat)

	var ball := SdfSphere.new()
	ball.center = Vector3(16, 16, 16)
	ball.radius = 12.0
	ball.material_id = 1

	data.grid_size = GRID
	data.node = QVoxelModel.of_source(ball, GRID)
	return data


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
