extends TestCase

## 预览渲染里**不依赖窗口**的那半边：选项归一化与分镜解析。
## 真正出图要渲染服务器(带窗口的进程)，在 test_qvoxel_preview_render.gd 里。


func test_options_default() -> void:
	var o := QVoxelPreview.normalize({})
	assert_eq(o["size"], 512)
	assert_eq(o["yaw"], 35.0)
	assert_eq(o["pitch"], 20.0)
	assert_eq(o["bg"], QVoxelPreview.BACKGROUND)
	assert_false(o["transparent"])
	assert_eq((o["views"] as Array).size(), 1, "默认单视角")
	assert_eq(o["frames"], 0, "默认只看当前帧")
	assert_eq(o["gap"], 0, "默认边对边")


func test_options_clamped() -> void:
	var o := QVoxelPreview.normalize({
		"size": 9, "pitch": 200.0, "dist": 0.1, "bg": "#112233", "transparent": true, "gap": 999})
	assert_eq(o["size"], 64, "边长下限")
	assert_eq(o["pitch"], 85.0, "俯仰上限")
	assert_eq(o["dist"], 0.5, "距离下限")
	assert_eq(o["bg"], Color.html("#112233"))
	assert_true(o["transparent"])
	assert_eq(o["gap"], 64, "间距上限")
	assert_eq(QVoxelPreview.normalize({"size": 99999})["size"], 4096, "边长上限")


func test_bg_accepts_color_or_html() -> void:
	assert_eq(QVoxelPreview.normalize({"bg": Color.RED})["bg"], Color.RED, "Color 原样透传")
	assert_eq(QVoxelPreview.normalize({"bg": "#112233"})["bg"], Color.html("#112233"), "支持 #rrggbb")
	assert_eq(QVoxelPreview.normalize({"bg": "no-such-color"})["bg"],
		QVoxelPreview.BACKGROUND, "非法颜色回默认")


## 视角：名字串 / 数组 / 角度字典 / 不认识就退回单视角。
func test_views_resolve() -> void:
	var v := QVoxelPreview.normalize({"views": "front, right ,iso"})["views"] as Array
	assert_eq(v.size(), 3, "逗号(含空格)分隔")
	assert_eq(v[0], QVoxelPreview.VIEW_ANGLES["front"])
	assert_eq(v[1], QVoxelPreview.VIEW_ANGLES["right"])
	assert_eq(v[2], QVoxelPreview.VIEW_ANGLES["iso"])

	var custom := QVoxelPreview.normalize({"views": [{"yaw": 10, "pitch": 30}]})["views"] as Array
	assert_eq(custom.size(), 1)
	assert_eq(custom[0], Vector2(10.0, 30.0), "角度字典直传")

	var fallback := QVoxelPreview.normalize({"views": "no-such-view", "yaw": 60.0})["views"] as Array
	assert_eq(fallback.size(), 1, "全不认识回单个")
	assert_eq(fallback[0], Vector2(60.0, 20.0), "退回 yaw/pitch")

	var mixed := QVoxelPreview.normalize({"views": ["top", "nope", "back"]})["views"] as Array
	assert_eq(mixed.size(), 2, "只保留认得的")


## 格数多了要回缩，否则整张图超纹理上限。
func test_tile_size_shrinks_with_more_cells() -> void:
	assert_eq(QVoxelPreview._fit_size(512, 1, 1), 512, "单格不动")
	assert_eq(QVoxelPreview._fit_size(4096, 4, 1), 2048, "按格数回缩")
	assert_eq(QVoxelPreview._fit_size(4096, 1, 3), 2730)
	assert_eq(QVoxelPreview._fit_size(4096, 64, 64), 128, "极多格回缩到 8192/64")
