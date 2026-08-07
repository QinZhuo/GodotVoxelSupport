@tool
class_name CreateLUT extends EditorScript

func _run() -> void:
	create_lut("res://lut.png")

func create_lut(path: String, size: int = 33) -> void:
	var image = Image.create(size * size, size, false, Image.FORMAT_RGB8)

	for z in size:
		for x in size:
			for y in size:
				image.set_pixel(size * z + x, y, Color8(
						roundi((x / float(size - 1)) * 255),
						roundi((y / float(size - 1)) * 255),
						roundi((z / float(size - 1)) * 255)
				))

	image.save_png(path)
	EditorInterface.get_resource_filesystem().scan_sources()
	prints("create", path)
