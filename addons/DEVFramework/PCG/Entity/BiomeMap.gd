class_name BiomeMap extends RefCounted
## 生物群系图生成结果 — 每个格子的群系索引 + 群系表

var width := 0
var height := 0
## 每格群系索引（对应 biomes 数组下标）
var indices := PackedInt32Array()
## 群系表（与 BiomeMapDef.biomes 一致）
var biomes: Array[BiomeEntryDef] = []

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

func index_at(x: int, y: int, out_of_bounds := -1) -> int:
	if not in_bounds(x, y):
		return out_of_bounds
	return indices[y * width + x]

## 取某格群系（越界返回 null）
func biome_at(x: int, y: int) -> BiomeEntryDef:
	var idx := index_at(x, y)
	if idx < 0 or idx >= biomes.size():
		return null
	return biomes[idx]
