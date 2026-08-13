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

func _to_string() -> String:
	var s := get_size()
	return "Template[%dx%d]" % [s.x, s.y]
