extends TestCase

## QVoxelBuilder 契约测试：材质 ID / 图元落笔（含 paint 任意格子）/ 落盘往返。
## 纯逻辑，编辑器进程即可（不碰场景树 / 渲染）。

const OUT := "user://test_qvoxel_builder.qvx"


func test_material_ids_and_count() -> void:
	var b := QVoxelBuilder.new()
	assert_eq(b.material_count(), 0, "初始无材质")
	var first := b.add_material(Color(1, 0, 0))
	var second := b.add_material(Color(0, 1, 0))
	assert_eq(first, 1, "首个材质 ID = 1（0 留给空气）")
	assert_eq(second, 2, "ID 递增")
	assert_eq(b.material_count(), 2, "材质计数不含空气槽")


func test_primitives_paint_cells() -> void:
	var b := QVoxelBuilder.new()
	var m := b.add_material(Color.WHITE)
	b.box(Vector3i(0, 0, 0), Vector3i(1, 1, 1), m)
	assert_eq(b.voxels().size(), 8, "2×2×2 = 8 格")
	b.line(Vector3i(3, 0, 0), Vector3i(3, 2, 0), m)
	assert_eq(b.voxels().size(), 11, "另加竖直 3 格线（不重叠）")
	b.ball(Vector3i(10, 10, 10), 0, m)
	assert_eq(b.voxels().size(), 12, "半径 0 球 = 单格")


## paint 是任意图元结果（含 dilate / region）的统一落笔口 —— 这正是本次补上的缺口。
func test_paint_stamps_arbitrary_cells() -> void:
	var b := QVoxelBuilder.new()
	var m := b.add_material(Color.WHITE)
	var grown := VoxelPrimitives.dilate([Vector3i.ZERO], 1)
	b.paint(grown, m)
	assert_eq(grown.size(), VoxelPrimitives.ball_offsets(1).size(), "半径 1 膨胀 = 半径 1 球")
	assert_eq(b.voxels().size(), grown.size(), "paint 原样盖章全部格子")
	for p in grown:
		assert_eq(b.voxels()[p], m, "每格材质一致")


func test_document_bounds_are_block_aligned() -> void:
	var b := QVoxelBuilder.new()
	var m := b.add_material(Color(0.5, 0.5, 0.5))
	b.box(Vector3i(-5, 0, 2), Vector3i(40, 3, 4), m)   # 跨块（x 跨 -1/0/1 块）
	var doc := b.to_document()
	assert_eq(int(doc.head["qvox"]), QVoxelSpec.VERSION, "版本")
	assert_eq(int(doc.head["block_size"]), 32, "默认块尺寸")
	assert_true(doc.models.has(0), "单模型 model_id=0")
	var bd: Dictionary = doc.head["bounds"]
	assert_eq(bd["min"], [-32, 0, 0], "bounds.min 按块对齐")
	assert_eq(bd["max"], [64, 32, 32], "bounds.max 按块对齐")
	assert_eq((doc.node["nodes"] as Array).size(), 1, "一个 NODE 摆放")


func test_save_roundtrip() -> void:
	var b := QVoxelBuilder.new()
	var m := b.add_material(Color(0.8, 0.2, 0.1), 0.0, 0.7)
	var m2 := b.add_material(Color(0.1, 0.3, 0.9), 0.5, 0.2, 0.4, 0.4, Color(0.1, 0.1, 0.0))
	b.box(Vector3i(3, 4, 5), Vector3i(9, 10, 11), m)
	b.ball(Vector3i(20, 6, 6), 2, m2)
	assert_true(b.save(OUT), "写出成功")

	var f := FileAccess.open(OUT, FileAccess.READ)
	assert_true(f != null, "文件可读")
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var rep := QVoxelFile.QVoxelReport.new()
	var doc := QVoxelFile.parse(bytes, true, rep, true)
	assert_true(doc != null, "解析成功")
	assert_eq(rep.errors.size(), 0, "无致命错误")
	assert_eq((doc.materials as Array).size(), 3, "材质往返（含空气槽）")
	assert_eq(QVoxelAsset.from_document(doc).voxel_count(), b.voxels().size(), "体素总数往返")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))
