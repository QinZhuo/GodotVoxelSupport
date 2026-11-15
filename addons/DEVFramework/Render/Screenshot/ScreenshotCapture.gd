class_name ScreenshotCapture extends Node

## 截图触发节点: 窗口就绪后延迟若干秒自动截图保存(时机见 auto_capture_delay)。
## 取图 / 颜色处理 / 落盘全部走 ScreenshotTool(唯一的画面捕获管线), 与 MCP take_screenshot /

@export_file_path("*.png") var save_path: String = "res://screenshot.png"
@export var custom_resolution: Vector2i = Vector2i(256, 256)
## 颜色处理模式: auto(默认) = 按读回缓冲的实际数据格式自动判定要不要补 sRGB 编码,
@export_enum("auto", "srgb", "raw") var color_mode: String = "auto"
## 量化到 8 位时是否做误差扩散抖动(dithering), 用于消除大面积渐变上的色阶断层(banding)。
@export var dithering: bool = false
## 截图时是否使用透明背景(**默认否**)。
@export var transparent_background: bool = false
## 窗口尺寸生效后再等多少秒自动截图并保存; <= 0 表示不自动截图。
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
func _auto_capture() -> void:
	if auto_capture_delay <= 0.0:
		return
	LogTool.log("截图", "%.1f 秒后自动截图" % auto_capture_delay)
	await get_tree().create_timer(auto_capture_delay).timeout
	await _take_screenshot()


## 取一帧并保存: 整条管线(取图 / 精确缩放 / 颜色处理 / 落盘)交给 ScreenshotTool.capture。
func _take_screenshot() -> void:
	var viewport := get_viewport()
	var original_bg := viewport.transparent_bg

	LogTool.log("截图", "开始截图: 输出=%s 目标尺寸=%s 透明背景=%s" % [save_path, custom_resolution, transparent_background])

	viewport.transparent_bg = transparent_background
	var res: Dictionary = await ScreenshotTool.capture(viewport, {
		"path": save_path, "exact_size": custom_resolution,
		"color_mode": color_mode, "dither": dithering,
	})
	viewport.transparent_bg = original_bg
	if not res.get("ok", false):
		LogTool.error("截图", str(res.get("error", "保存图像失败")))
		return
	LogTool.log("截图", "保存图像成功: %s (%dx%d)" % [
		str(res.get("res_path", save_path)), int(res.get("width", 0)), int(res.get("height", 0))])
