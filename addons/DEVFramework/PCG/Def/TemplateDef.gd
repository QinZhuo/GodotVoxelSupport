@tool
class_name TemplateDef extends Resource
## 手作地图模板 — 用字符串行定义，字符映射到栅格值
##
## 示例：["#####", "#...#", "#.G.#", "#####"]，'#'→墙，'.'→空地，'G'→门/出入口。
## 配合 TemplateStitchDef 随机拼合成关卡。

## 模板行（每行一个字符串，长度可不同，取最长）
@export var lines: PackedStringArray = []
## 字符 → 栅格值 映射（默认：# → 1 实体，. → 0 空地）
@export var char_map: Dictionary = {"#": 1, ".": 0}
## 出现权重
@export_range(0.1, 10.0, 0.1) var weight := 1.0

func get_size() -> Vector2i:
	var w := 0
	for line in lines:
		w = maxi(w, line.length())
	return Vector2i(w, lines.size())

## 把模板印到 grid 的 (ox, oy) 位置
func stamp(grid: GeneratedGrid, ox: int, oy: int) -> void:
	for y in lines.size():
		var line := lines[y]
		for x in line.length():
			var c := line[x]
			grid.set_cell(ox + x, oy + y, int(char_map.get(c, 0)))

## 把模板旋转后印到 grid 的 (ox, oy) 位置（rotation: 0=0° 1=90°顺时针 2=180° 3=270°）
## 门/出入口等字符随格子一起旋转，用于让建筑门朝向街道
func stamp_rotated(grid: GeneratedGrid, ox: int, oy: int, rotation := 0) -> void:
	rotation = posmod(rotation, 4)
	if rotation == 0:
		stamp(grid, ox, oy)
		return
	var size := get_size()
	for y in lines.size():
		var line := lines[y]
		for x in line.length():
			var c := line[x]
			var np := _rot_point(Vector2i(x, y), size, rotation)
			grid.set_cell(ox + np.x, oy + np.y, int(char_map.get(c, 0)))

## 模板旋转 rotation 后的尺寸
func get_rotated_size(rotation: int) -> Vector2i:
	var s := get_size()
	rotation = posmod(rotation, 4)
	return s if rotation % 2 == 0 else Vector2i(s.y, s.x)

## 点在旋转后的新坐标（size 为原模板尺寸；顺时针旋转）
static func _rot_point(p: Vector2i, size: Vector2i, rotation: int) -> Vector2i:
	match rotation % 4:
		1:
			return Vector2i(size.y - 1 - p.y, p.x)
		2:
			return Vector2i(size.x - 1 - p.x, size.y - 1 - p.y)
		3:
			return Vector2i(p.y, size.x - 1 - p.x)
	return p

func _to_string() -> String:
	var s := get_size()
	return "Template[%dx%d]" % [s.x, s.y]
