@tool
class_name TileSetDef3D extends Resource
## 3D WFC 瓦片集 — 一组 TileDef3D（六面 socket）
##
## 配合 Grid3DGenDef.Type.WFC_3D 使用。

## 瓦片列表（最多 30 个，内部用 bitmask 表示候选集）
@export var tiles: Array[TileDef3D] = []

func _to_string() -> String:
	return "TileSet3D[%d 瓦片]" % tiles.size()
