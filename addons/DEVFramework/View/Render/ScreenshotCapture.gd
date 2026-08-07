class_name ScreenshotCapture extends Node

@export_file_path("*.png") var save_path: String = "res://screenshot.png"
@export var custom_resolution: Vector2i = Vector2i(256, 256)
@export var linear_to_srgb: bool = true

func _ready() -> void:
	await await get_tree().create_timer(1).timeout
	get_window().size = custom_resolution
	printerr("set ", custom_resolution)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed() and event.is_double_click():
		_take_screenshot()


func _take_screenshot() -> void:
	var viewport := get_viewport()
	var original_bg := viewport.transparent_bg

	viewport.transparent_bg = true
	await RenderingServer.frame_post_draw

	var img := viewport.get_texture().get_image()
	img.resize(custom_resolution.x, custom_resolution.y, Image.INTERPOLATE_LANCZOS)
	_apply_dithering(img)
	img.convert(Image.FORMAT_RGBA8)
	if linear_to_srgb:
		img.linear_to_srgb()
	img.save_png(save_path)
	viewport.transparent_bg = original_bg

	LogTool.log("截图", "保存图像成功", save_path)

func _apply_dithering(img: Image) -> void:
	var width := img.get_width()
	var height := img.get_height()
	for y in range(height):
		for x in range(width):
			var color := img.get_pixel(x, y)
			var quantized := _quantize_color(color)
			img.set_pixel(x, y, quantized)
			var error := color - quantized
			_distribute_error(img, x, y, error, width, height)

func _quantize_color(color: Color) -> Color:
	return Color(
		round(color.r * 255.0) / 255.0,
		round(color.g * 255.0) / 255.0,
		round(color.b * 255.0) / 255.0,
		color.a
	)

func _distribute_error(img: Image, x: int, y: int, error: Color, width: int, height: int) -> void:
	var factor := 1.0 / 16.0
	if x + 1 < width:
		var c1 := img.get_pixel(x + 1, y)
		img.set_pixel(x + 1, y, c1 + error * (7.0 * factor))
	if y + 1 < height:
		if x - 1 >= 0:
			var c2 := img.get_pixel(x - 1, y + 1)
			img.set_pixel(x - 1, y + 1, c2 + error * (3.0 * factor))
		var c3 := img.get_pixel(x, y + 1)
		img.set_pixel(x, y + 1, c3 + error * (5.0 * factor))
		if x + 1 < width:
			var c4 := img.get_pixel(x + 1, y + 1)
			img.set_pixel(x + 1, y + 1, c4 + error * (1.0 * factor))
