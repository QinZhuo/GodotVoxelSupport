@tool
class_name TileDef3D extends Resource
## 3D WFC 瓦片定义 — 用六面 socket 标签描述体素连接
##
## 方向约定：0=+x(东), 1=-x(西), 2=+y(上), 3=-y(下), 4=+z(南), 5=-z(北)。
## socket 匹配：相邻两体素接触面 socket 字符串必须相等。

## 瓦片名
@export var name := ""
## 着色颜色（展示用）
@export var color := Color(0.7, 0.7, 0.7)
## 各面 socket
@export var east := ""    # +x
@export var west := ""    # -x
@export var up := ""      # +y
@export var down := ""    # -y
@export var south := ""   # +z
@export var north := ""   # -z
## 出现权重
@export_range(0.1, 10.0, 0.1) var weight := 1.0

func socket(dir: int) -> String:
	match dir:
		0:
			return east
		1:
			return west
		2:
			return up
		3:
			return down
		4:
			return south
		_:
			return north

func _to_string() -> String:
	return name if not name.is_empty() else "Tile3D"
