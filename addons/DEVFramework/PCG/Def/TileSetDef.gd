@tool
class_name TileSetDef extends Resource
## WFC 瓦片集 — 一组 TileDef 及默认底色
##
## 直接作为 .tres 资源配置瓦片，配合 GridGenDef.Type.WFC 使用。

## 瓦片列表（最多 30 个，内部用 bitmask 表示候选集）
@export var tiles: Array[TileDef] = []
## 生成失败格的颜色（调试着色用）
@export var fallback_color := Color(0.6, 0.2, 0.2)

func _to_string() -> String:
	return "TileSet[%d 瓦片]" % tiles.size()
