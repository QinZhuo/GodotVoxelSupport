extends TestCase

## 快照（`QVoxelSnapshot`）的契约测试 —— "有哪些选项 / 叫什么 / 该不该渲"这一段纯逻辑。
## 【为什么这几件事值得单独钉】它们错了都不会报错，只产出**看起来正常**的错东西：
##   ① 视图表 —— 键写错，七个角度里有几个渲出来是同一个角度；
##   ② 文件名 —— 两次快照写同一个路径，用户以为存了七张，其实只剩最后一张；
##   ③ 拒绝判据 —— 空世界渲出来是一张纯背景图，用户会当成"渲染坏了"而不是"世界是空的"。
## 离屏渲染那一层（SubViewport / 相机 / 等网格）只能在有窗口时跑、无头测不了 ——
## 这正是这三件事必须住在纯逻辑类里、由本用例逐条钉住的原因。

const VIEW_COUNT := 7  ## 前 / 后 / 左 / 右 / 顶 / 底 / 等轴（FREE 不算）


# 视图 / 尺寸 / 镜头三张选项表

## 视图表必须与视口那套角度表**一一对应**：同一颗"顶视图"两处解释不同，且两处都不报错。
func test_views_match_view_camera_table() -> void:
	var views := QVoxelSnapshot.views()
	assert_eq(views.size(), VIEW_COUNT, "七个标准视图各一项")
	for spec in views:
		var v: int = spec.value
		assert_true(QVoxelViewCamera.VIEW_ANGLES_DEG.has(v), "每个 value 都对应一个真实角度")
		assert_eq(spec.text, QVoxelViewCamera.VIEW_NAMES[v], "显示名取自视口的视图名表")


## FREE 的语义是"不改变角度"—— 列进快照只会给出一张"沿用上一次角度"的图，故必须排除。
func test_views_exclude_free() -> void:
	for spec in QVoxelSnapshot.views():
		assert_ne(spec.value, QVoxelViewCamera.View.FREE, "自由视图不进快照选项")


## 尺寸档：三个、且默认值就在其中（否则打开面板时没有任何一颗是亮的）。
func test_sizes_cover_default() -> void:
	var sizes := QVoxelSnapshot.sizes()
	assert_eq(sizes.size(), 3, "512 / 1K / 2K 三档")
	var values := []
	for spec in sizes:
		values.append(spec.value)
	assert_true(values.has(QVoxelSnapshot.DEFAULT_SIZE), "默认尺寸是其中一档")


## 镜头表覆盖透视与正交两种 —— 正交是体素素材的常规出图方式，不能缺。
func test_lenses_cover_both() -> void:
	var lenses := QVoxelSnapshot.lenses()
	assert_eq(lenses.size(), 2, "透视 / 正交")
	var values := []
	for spec in lenses:
		values.append(spec.value)
	assert_true(values.has(QVoxelViewCamera.Lens.PERSPECTIVE), "有透视")
	assert_true(values.has(QVoxelViewCamera.Lens.ORTHO), "有正交")


# 文件名

## 名字要带视图名：否则"同一个世界出七个角度"会七张互相覆盖（覆盖不报错，用户以为存了七张）。
func test_file_stem_carries_view_name() -> void:
	assert_eq(QVoxelSnapshot.file_stem("城堡", QVoxelViewCamera.View.FRONT), "城堡_前",
			"世界名 + 视图名")
	assert_ne(QVoxelSnapshot.file_stem("城堡", QVoxelViewCamera.View.FRONT),
			QVoxelSnapshot.file_stem("城堡", QVoxelViewCamera.View.ISO),
			"不同角度得到不同主干，不会互相覆盖")


## 消毒规则全项目一份（见 QVoxelNaming）：路径分隔符必须换掉，否则会写到别的目录去。
func test_file_stem_sanitizes_illegal_chars() -> void:
	assert_eq(QVoxelSnapshot.file_stem("a/b", QVoxelViewCamera.View.FRONT), "a_b_前",
			"`/` 被换成 `_`，中文与视图名保留")


# 取景盒

## 取景盒 = 求值结果的 origin + grid_size，再乘 voxel_scale。
## 它与导出用的是同一组数，故"快照框住的"与"导出写出的"必然是同一块空间。
func test_frame_aabb_scales_by_voxel_scale() -> void:
	var res := QVoxelEvalResult.new()
	res.origin = Vector3i(1, 2, 3)
	res.grid_size = Vector3i(4, 5, 6)
	res.volume = PackedInt32Array([0, 1, 0, 0])  # 非空即算"有内容"
	var box := QVoxelSnapshot.frame_aabb(res, 2.0)
	assert_eq(box.position, Vector3(2, 4, 6), "原点按 voxel_scale 放大")
	assert_eq(box.size, Vector3(8, 10, 12), "尺寸按 voxel_scale 放大")


## 空体积给一个零盒 —— 交给调用方（渲染器 / 相机）自己判定"没有可框的东西"。
func test_frame_aabb_empty_volume_is_zero() -> void:
	var res := QVoxelEvalResult.new()
	res.origin = Vector3i(1, 2, 3)
	res.grid_size = Vector3i(4, 5, 6)
	assert_eq(QVoxelSnapshot.frame_aabb(res, 2.0).size, Vector3.ZERO, "空体积不框")


# 该不该渲

## 空世界的渲染会成功、也会存下一张纯背景图 —— 它不报任何错，用户第一反应是"渲染坏了"。
## 宁可明确回话，也不产出一张"看起来像截图、其实什么都没有"的图。
func test_blocker_rejects_empty_world() -> void:
	assert_true(not QVoxelSnapshot.blocker(null).is_empty(), "没有世界要回一句原因")
	var w := QVoxelWorld.create_empty()
	assert_true(not QVoxelSnapshot.blocker(w).is_empty(), "世界空着也要回一句原因")


## 有模型就该放行（返回空串）。
func test_blocker_allows_world_with_model() -> void:
	var w := QVoxelWorld.create_empty()
	w.create_model("M", Vector3i(4, 4, 4))
	assert_eq(QVoxelSnapshot.blocker(w), "", "有模型即放行")


# 用户文案

## 描述要带上**真实像素数**：尺寸档显示的是 1K / 2K 这类短名，用户想确认"到底渲了多大"看这里。
func test_describe_reports_real_pixels() -> void:
	var text := QVoxelSnapshot.describe(2048, QVoxelViewCamera.View.ISO, QVoxelViewCamera.Lens.ORTHO)
	assert_true(text.contains("2048"), "报出真实像素数而不是 2K")
	assert_true(text.contains(QVoxelViewCamera.VIEW_NAMES[QVoxelViewCamera.View.ISO]), "报出视图名")
	assert_true(text.contains(QVoxelViewCamera.LENS_NAMES[QVoxelViewCamera.Lens.ORTHO]), "报出镜头名")


## 落盘后的提示要报出"渲了多大"与"存到哪儿"。
func test_summary_reports_size_and_path() -> void:
	var text := QVoxelSnapshot.summary("D:/out/城堡_前.png", 512)
	assert_true(text.contains("512"), "报出像素数")
	assert_true(text.contains("D:/out/城堡_前.png"), "报出落地路径")
