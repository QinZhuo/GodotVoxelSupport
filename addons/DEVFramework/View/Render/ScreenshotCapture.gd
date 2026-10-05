class_name ScreenshotCapture extends Node

## 截图触发节点: 窗口就绪后延迟若干秒自动截图保存(时机见 auto_capture_delay)。
## 颜色空间处理统一委托给 ScreenshotTool,
## 保证与 MCP take_screenshot / EditorScript 入口使用同一条管线(默认颜色正确)。

@export_file_path("*.png") var save_path: String = "res://screenshot.png"
@export var custom_resolution: Vector2i = Vector2i(256, 256)
@export var linear_to_srgb: bool = true
## 量化到 8 位时是否做误差扩散抖动(dithering), 用于消除大面积渐变上的色阶断层(banding)。
## 代价是一次全图逐像素处理(高分辨率出图时较可观); 画面细节多、或不需要防 banding 时可关掉。
@export var dithering: bool = false
## 截图时是否使用透明背景(**默认否**)。
## 透明背景便于后期合成(抠图), 但代价是 —— 引擎硬限制, 二者不可兼得:
## **透明背景视口会被引擎禁用景深(DoF)**(运行时打印 "Depth of field is not supported in
## viewports with a transparent background"), 且泛光(glow)强度也会明显减弱。
## 所以默认关闭以保留完整后处理; 确实需要抠图/合成时再勾上。
@export var transparent_background: bool = false
## 窗口尺寸生效后再等多少秒自动截图并保存; <= 0 表示不自动截图。
## 之所以要延迟: 窗口 resize、光照/阴影、后处理、材质加载都要跑几帧才稳定,
## 紧接着 resize 就截图容易得到尺寸不对或画面未收敛的图。
@export var auto_capture_delay: float = 3.0

func _ready() -> void:
	await get_tree().create_timer(1).timeout
	if Engine.is_embedded_in_editor():
		# 嵌入编辑器运行时 DisplayServer 禁止修改窗口尺寸，截图尺寸由 img.resize 保证
		LogTool.error("截图", "嵌入编辑器运行，跳过窗口 resize（输出尺寸仍为 %s）" % custom_resolution)
	else:
		_apply_resolution(custom_resolution)
	await _auto_capture()


## 把窗口调整到出图分辨率, 并按**长宽比差异自动挑选内容的取景/缩放基准轴**。
## 规则与运行时分辨率自适应是同一套（统一走 DisplayAdapter，见其文件头说明）：
##   目标比当前**更宽** ⇒ KEEP_HEIGHT —— 垂直取景范围不变, 横向自然多出内容
##   目标比当前**更高/更窄** ⇒ KEEP_WIDTH —— 水平取景范围不变, 纵向自然多出内容
## 同时作用于两个层面(项目里它们各有一套默认值, 超宽/超窄出图时容易互相打架):
##   3D 相机取景: Camera3D.keep_aspect
##   2D/UI 缩放:  Window.content_scale_aspect
## 注: 出图场景是一次性进程, 这里不还原调用前的设置。
func _apply_resolution(res: Vector2i) -> void:
	var window := get_window()
	var from := window.size
	var cam := get_viewport().get_camera_3d()
	var keep_height := DisplayTool.fit_to_target(window, cam, res)
	window.size = res
	LogTool.log("截图", "窗口 %s → %s, 比例 %.3f → %.3f ⇒ 内容保持%s%s" % [
		from, res, DisplayTool.ratio_of(from), DisplayTool.ratio_of(res),
		"高度" if keep_height else "宽度",
		"" if cam else "(场景无 3D 相机, 仅调整 UI)",
	])


## 延迟自动截图: 等画面稳定后自动截一张并保存到 save_path。
## `auto_capture_delay <= 0` 时不做事(本节点纯自动, 已无手动触发入口)。
func _auto_capture() -> void:
	if auto_capture_delay <= 0.0:
		return
	LogTool.log("截图", "%.1f 秒后自动截图" % auto_capture_delay)
	await get_tree().create_timer(auto_capture_delay).timeout
	await _take_screenshot()


## 取一帧并保存: 取图 → 缩放 → 归一化(转 RGBA8 + sRGB 校正 + 可选抖动) → 存到 save_path。
## 背景是否透明由 transparent_background 决定(缺省不透明, 保留景深/泛光)。
## 日志覆盖 开始 / 取图失败 / 保存失败 / 保存成功(含路径与尺寸)。
func _take_screenshot() -> void:
	var viewport := get_viewport()
	var original_bg := viewport.transparent_bg

	LogTool.log("截图", "开始截图: 输出=%s 目标尺寸=%s 透明背景=%s" % [save_path, custom_resolution, transparent_background])

	viewport.transparent_bg = transparent_background
	await RenderingServer.frame_post_draw

	# 取一帧画面(颜色/量化处理统一交给下面的 ScreenshotTool.normalize)
	var img := viewport.get_texture().get_image()
	viewport.transparent_bg = original_bg
	if img == null or img.is_empty():
		LogTool.error("截图", "截图失败: 视口纹理为空")
		return

	img.resize(custom_resolution.x, custom_resolution.y, Image.INTERPOLATE_LANCZOS)
	# 统一走 ScreenshotTool: 转 RGBA8 + 可选 sRGB 校正 + 可选抖动(dithering 开时先转 sRGB 浮点再量化扩散)
	ScreenshotTool.normalize(img, {"srgb": linear_to_srgb, "dither": dithering})
	var err := img.save_png(save_path)
	if err != OK:
		LogTool.error("截图", "保存图像失败: %s 错误码=%d" % [save_path, err])
		return
	LogTool.log("截图", "保存图像成功: %s (%dx%d)" % [save_path, img.get_width(), img.get_height()])
