extends TestCase

## 预览渲染里**不依赖窗口**的那半边：选项归一化。
## 真正出图要渲染服务器(带窗口的进程)，不放进测试 —— 用 MCP `voxel_render`
## 或 `await QVoxelScript.preview(...)` 手动看。


func test_options_default() -> void:
	var o := QVoxelPreview.normalize({})
	assert_eq(o["size"], 512)
	assert_eq(o["yaw"], 35.0)
	assert_eq(o["pitch"], 20.0)
	assert_eq(o["bg"], QVoxelPreview.BACKGROUND)
	assert_false(o["transparent"])


func test_options_clamped() -> void:
	var o := QVoxelPreview.normalize({
		"size": 9, "pitch": 200.0, "dist": 0.1, "bg": "#112233", "transparent": true})
	assert_eq(o["size"], 64, "边长下限")
	assert_eq(o["pitch"], 85.0, "俯仰上限")
	assert_eq(o["dist"], 0.5, "距离下限")
	assert_eq(o["bg"], Color.html("#112233"))
	assert_true(o["transparent"])
	assert_eq(QVoxelPreview.normalize({"size": 99999})["size"], 4096, "边长上限")


func test_bg_accepts_color_or_html() -> void:
	assert_eq(QVoxelPreview.normalize({"bg": Color.RED})["bg"], Color.RED, "Color 原样透传")
	assert_eq(QVoxelPreview.normalize({"bg": "#112233"})["bg"], Color.html("#112233"), "支持 #rrggbb")
	assert_eq(QVoxelPreview.normalize({"bg": "no-such-color"})["bg"],
		QVoxelPreview.BACKGROUND, "非法颜色回默认")
