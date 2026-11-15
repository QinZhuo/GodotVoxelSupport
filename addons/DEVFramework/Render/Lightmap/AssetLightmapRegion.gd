## 一类资源在烘焙图集里占的位置。
@tool
class_name AssetLightmapRegion extends Resource

## 在图集中的位置（归一化 0..1），采样时 UV2 * uv.size + uv.position
@export var uv: Rect2

## 图集页号。SH 四层固定排在 slice * 4 + 0..3
@export var slice: int

func has_area() -> bool:
	return uv.size.x > 0.0 and uv.size.y > 0.0
