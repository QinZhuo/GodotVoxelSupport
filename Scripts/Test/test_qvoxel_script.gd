extends TestCase

## 脚本层（QVoxelScript / QVoxelFileIO）的无头行为。
## 覆盖：新建 / 材质 / 写格 / 擦除 / 对象树 / 帧动画 / 相机 / 文件往返(.qvx + .vox) / 格式判定。
## 【为什么在 TestCase 里跑就是无头】`_app()` 认的是"运行时场景带 script_stats"，
## 测试进程没有 QVoxelier，天然落到内存世界 —— 这正是 MCP 在编辑器进程看到的分支。

const TMP_QVX := "user://_test_script.qvx"
const TMP_VOX := "user://_test_script.vox"


func _cleanup() -> void:
	for p in [TMP_QVX, TMP_VOX]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func test_new_model_material_paint() -> void:
	QVoxelScript.new_model(Vector3i(16, 16, 16))
	var skin := QVoxelScript.material(Color(0.8, 0.4, 0.2), 0.0, 0.7)
	assert_eq(skin, 1, "首个材质 id 为 1")
	var n := QVoxelScript.paint(VoxelPrimitives.box(Vector3i(1, 1, 1), Vector3i(3, 3, 3)), skin)
	assert_eq(n, 27, "3³ 盒应写 27 格")
	assert_eq(QVoxelScript.count_solid(), 27)
	assert_eq(QVoxelScript.get_voxel(Vector3i(2, 2, 2)), skin)
	assert_eq(QVoxelScript.get_voxel(Vector3i(9, 9, 9)), 0, "未写的位置是空气")
	assert_eq(QVoxelScript.paint([Vector3i(2, 2, 2)], skin), 0, "同值重写不算改动")
	assert_eq(QVoxelScript.erase([Vector3i(2, 2, 2), Vector3i(4, 4, 4)]), 1, "只有 1 格原本是实心")


func test_out_of_bounds_cells_dropped() -> void:
	QVoxelScript.new_model(Vector3i(8, 8, 8))
	var mat := QVoxelScript.material()
	assert_eq(QVoxelScript.paint([Vector3i(-1, 0, 0), Vector3i(8, 0, 0), Vector3i(0, 0, 0)], mat), 1)


func test_object_tree() -> void:
	QVoxelScript.new_model(Vector3i(8, 8, 8))
	var gid := QVoxelScript.add_group("parts")
	assert_true(gid < 0, "组 id 为负")
	var mid := QVoxelScript.add_model("child", Vector3i(4, 4, 4), gid)
	assert_eq(mid, 1)
	assert_eq(QVoxelScript.active(), mid, "新建模型自动成为活动模型")
	assert_eq(QVoxelScript.nodes().size(), 3, "模型 + 组 + 子模型")
	assert_true(QVoxelScript.set_offset(mid, Vector3i(3, 0, 0)))
	assert_true(QVoxelScript.set_rotation(mid, Vector3(0, 95, 0)), "非 90 度会被吸附")
	assert_true(QVoxelScript.rename_node(mid, "renamed"))
	assert_eq(QVoxelScript.models()[1]["name"], "renamed")
	assert_true(QVoxelScript.set_visible(mid, false))
	assert_true(QVoxelScript.remove_node(mid), "删掉子模型")
	assert_false(QVoxelScript.remove_node(0), "最后一个模型不能删")


func test_frames() -> void:
	QVoxelScript.new_model(Vector3i(8, 8, 8))
	var mat := QVoxelScript.material()
	QVoxelScript.paint([Vector3i(1, 1, 1)], mat)
	assert_eq(QVoxelScript.add_frame(false), 1, "静态转动画: 原体素进第 0 帧, 新帧插在其后")
	assert_eq(QVoxelScript.frames()["count"], 2)
	assert_eq(QVoxelScript.count_solid(), 0, "新帧是空的")
	assert_true(QVoxelScript.set_frame(0))
	assert_eq(QVoxelScript.count_solid(), 1, "第 0 帧接管原体素")
	assert_eq(QVoxelScript.add_frame(true), 1, "复制当前帧插在其后")
	assert_eq(QVoxelScript.frames()["count"], 3)
	assert_eq(QVoxelScript.count_solid(), 1, "复制来的帧内容相同")
	assert_true(QVoxelScript.set_frame_duration(1, 120))
	assert_eq(QVoxelScript.frames()["durations"][1], 120)
	assert_true(QVoxelScript.move_frame(1, 2))
	assert_true(QVoxelScript.remove_frame(2))
	assert_eq(QVoxelScript.frames()["count"], 2)


func test_cameras() -> void:
	QVoxelScript.new_model()
	var i := QVoxelScript.add_camera("front")
	assert_eq(i, 0)
	assert_true(QVoxelScript.set_camera(0, "fov", 60.0))
	assert_eq(QVoxelScript.cameras()[0]["fov"], 60.0)
	assert_true(QVoxelScript.remove_camera(0))
	assert_eq(QVoxelScript.cameras().size(), 0)


func test_roundtrip_qvx() -> void:
	_cleanup()
	QVoxelScript.new_model(Vector3i(16, 16, 16))
	var mat := QVoxelScript.material(Color(0.1, 0.9, 0.3))
	QVoxelScript.paint(VoxelPrimitives.ball(Vector3i(7, 7, 7), 3), mat)
	var gid := QVoxelScript.add_group("parts")
	var mid := QVoxelScript.add_model("child", Vector3i(8, 8, 8), gid)
	QVoxelScript.set_offset(mid, Vector3i(9, 0, 0))
	var solid_before: int = QVoxelScript.models()[0]["solid"]
	assert_true(QVoxelScript.save(TMP_QVX), "存 .qvx 成功")
	assert_true(QVoxelScript.open(TMP_QVX), "重新打开")
	assert_eq(QVoxelScript.info()["models"], 2, "两个模型都还在")
	assert_eq(QVoxelScript.models()[0]["solid"], solid_before, "球体实心格数不变")
	assert_eq(QVoxelScript.nodes().size(), 3, "组也重建")
	assert_true(QVoxelScript.nodes()[1]["id"] < 0, "组的 id 从文件重建后仍为负")
	_cleanup()


func test_save_and_open_vox() -> void:
	_cleanup()
	QVoxelScript.new_model(Vector3i(12, 12, 12))
	var mat := QVoxelScript.material(Color(1.0, 0.0, 0.0))
	QVoxelScript.paint(VoxelPrimitives.box(Vector3i(0, 0, 0), Vector3i(3, 3, 3)), mat)
	assert_true(QVoxelScript.save(TMP_VOX), "存 .vox 成功")
	assert_true(QVoxelScript.open(TMP_VOX), "打开 .vox")
	assert_eq(QVoxelScript.count_solid(), 64, "体素原样读回")
	_cleanup()


func test_vox_rejects_oversize() -> void:
	_cleanup()
	QVoxelScript.new_model(Vector3i(300, 8, 8))
	var mat := QVoxelScript.material()
	QVoxelScript.paint([Vector3i(280, 4, 4)], mat)  # 超出 .vox 的 256 上限
	assert_false(QVoxelScript.save(TMP_VOX), "超尺寸模型拒绝写出 .vox")
	assert_false(FileAccess.file_exists(TMP_VOX), "失败时不留下半成品")
	_cleanup()


func test_file_io_extensions() -> void:
	assert_true(QVoxelFileIO.is_project_path("a/b.qvx"))
	assert_true(QVoxelFileIO.is_project_path("A/B.QVX"), "扩展名大小写不敏感")
	assert_true(QVoxelFileIO.is_vox_path("a/b.vox"))
	assert_false(QVoxelFileIO.is_openable("a/b.glb"))
	assert_eq(QVoxelFileIO.ensure_extension("a/b"), "a/b.qvx")
	assert_eq(QVoxelFileIO.ensure_extension("a/b.vox"), "a/b.vox")
	assert_eq(QVoxelFileIO.load_world("user://_nope.qvx"), null, "不存在的文件返回 null")
