extends TestCase

## 真出图 —— 需要渲染服务器，故整个文件标 `needs_game_process`（编辑器进程侧会列为 SKIP）。
## 选项归一化那半边不依赖窗口，在 test_qvoxel_preview.gd 里。
## 用 `QVoxelBuilder` 造独立世界：不碰 `QVoxelScript`，免得测试改写正在运行的 QVoxelier 场景。

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
	var world := _cube_world()
	var img: Image = await QVoxelPreview.render(world, {"size": 64})
	assert_ne(img, null, "应出图")
	if img == null:
		return
	assert_eq(img.get_size(), Vector2i(64, 64))
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
