extends TestCase

## 真出图 —— 需要渲染服务器，故整个文件标 `needs_game_process`（编辑器进程侧会列为 SKIP）。
## 选项归一化与分镜解析不依赖窗口，在 test_qvoxel_preview.gd 里。
## 用 `QVoxelBuilder` / `QVoxelWorld` 造独立世界：不碰 `QVoxelScript`，免得测试改写正在运行的 QVoxelier 场景。

const OUT := "user://_test_preview_render.png"


func needs_game_process() -> bool:
	return true


func cleanup() -> void:
	if FileAccess.file_exists(OUT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))


## 世界渲染出图、尺寸正确、画面里确有模型像素（不是一整张背景色）。
func test_render_shows_model() -> void:
	if not QVoxelPreview.can_render():
		return  # headless: 没有渲染服务器, 出图无从谈起
	var img: Image = await QVoxelPreview.render(_cube_world(), {"size": 64})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	assert_eq(img.get_size(), Vector2i(64, 64), "单视角单帧: 原样一张, 不拼")
	var bg := QVoxelPreview.BACKGROUND
	var lit := 0
	for y in 64:
		for x in 64:
			if not img.get_pixel(x, y).is_equal_approx(bg):
				lit += 1
	assert_true(lit > 100, "画面里应有模型像素(got=%d)" % lit)


## 空世界直接返回 null：不产出"纯背景色"的假图。
func test_render_empty_world_returns_null() -> void:
	var img: Image = await QVoxelPreview.render(QVoxelWorld.new(), {"size": 64})
	assert_true(img == null, "空世界不出图")


## 多视角：横排 N 格，每格 size 见方。
func test_render_views_row() -> void:
	if not QVoxelPreview.can_render():
		return
	var img: Image = await QVoxelPreview.render(_cube_world(),
			{"views": "front,right,top,iso", "size": 64, "gap": 4})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	assert_eq(img.get_size(), Vector2i(64 * 4 + 4 * 3, 64), "4 视角横排 + 3 道缝")


## 多帧：只有帧在变时，时间沿横轴铺开。
func test_render_frames_row() -> void:
	if not QVoxelPreview.can_render():
		return
	var img: Image = await QVoxelPreview.render(_animated_world(), {"frames": -1, "size": 64})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	assert_eq(img.get_size(), Vector2i(64 * 2, 64), "2 帧横排（size 下限 64）")


## 机位固定：两帧造型不同，两格画面就不能完全相同（每帧重新居中会把位移抹平）。
func test_render_frames_keep_placement() -> void:
	if not QVoxelPreview.can_render():
		return
	var img: Image = await QVoxelPreview.render(_animated_world(), {"frames": -1, "size": 64})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	var diff := 0
	for y in 64:
		for x in 64:
			if not img.get_pixel(x, y).is_equal_approx(img.get_pixel(x + 64, y)):
				diff += 1
	assert_true(diff > 100, "两帧画面应有差异(got=%d)" % diff)


## 视角 × 帧：视角横排、帧纵叠。
func test_render_views_by_frames_grid() -> void:
	if not QVoxelPreview.can_render():
		return
	var img: Image = await QVoxelPreview.render(_animated_world(),
			{"views": "front,back", "frames": -1, "size": 64, "gap": 2})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	assert_eq(img.get_size(), Vector2i(64 * 2 + 2, 64 * 2 + 2), "2×2 网格 + 缝")


## 出图不该顺手改用户正在看的那一帧。
func test_render_keeps_active_frame() -> void:
	if not QVoxelPreview.can_render():
		return
	var world := _animated_world()
	var m := world.all_models()[0]
	m.active_frame = 1
	await QVoxelPreview.render(world, {"frames": -1, "size": 64})
	assert_eq(m.active_frame, 1, "渲染后帧游标复原")


## 落盘路径：按扩展名写 PNG。
func test_render_to_writes_png() -> void:
	if not QVoxelPreview.can_render():
		return
	assert_eq(await QVoxelPreview.render_to(_cube_world(), OUT, {"size": 32}), OK)
	assert_true(FileAccess.file_exists(OUT), "PNG 应落盘")


func _cube_world() -> QVoxelWorld:
	var b := QVoxelBuilder.new()
	b.box(Vector3i(0, 0, 0), Vector3i(7, 7, 7), b.add_material(Color(0.9, 0.2, 0.2)))
	return QVoxelWorld.from_document(b.to_document())


## 两帧的动画模型：两帧造型不同（一低一高，各 4 格），拼图才看得出是不是同一颗。
func _animated_world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	var m := w.create_model("anim", Vector3i(8, 8, 8))
	var mid := w.add_material(Color(0.2, 0.6, 0.9))
	for dz in 2:
		m.set_voxel(1, 1, 1 + dz, mid)
		m.set_voxel(2, 1, 1 + dz, mid)
	m.make_animated()
	m.add_frame(QVoxelFrame.new(), 1)
	for dz in 2:
		m.set_frame_voxel(1, 5, 5, 5 + dz, mid)
		m.set_frame_voxel(1, 6, 5, 5 + dz, mid)
	return w
