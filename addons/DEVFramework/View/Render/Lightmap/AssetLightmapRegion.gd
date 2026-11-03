## 一类资源在烘焙图集里占的位置。
##
## 不存贴图本身：整张图集由 [AssetLightmapSet] 持有并共享，这里只记坐标，
## 一份光照从「四张图」缩成「一个矩形 + 一个页号」。
##
## 跟着资源走而不是跟着实例走，所以「同屏显示几个」不影响体积。
@tool
class_name AssetLightmapRegion extends Resource

## 在图集中的位置（归一化 0..1），采样时 UV2 * uv.size + uv.position
@export var uv: Rect2

## 图集页号。SH 四层固定排在 slice * 4 + 0..3
@export var slice: int

func has_area() -> bool:
	return uv.size.x > 0.0 and uv.size.y > 0.0
