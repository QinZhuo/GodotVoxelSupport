@tool
class_name TileDef extends Resource
## WFC 瓦片定义 — 每个瓦片用四方向 socket 标签描述连接关系
##
## socket 匹配规则：相邻两瓦片接触侧的 socket 字符串必须相等。
## 例如 0=up, 1=right, 2=down, 3=left：瓦片A 的 up("road") 邻接 瓦片B 的 down("road")。

## 瓦片名（用于调试/着色）
@export var name := ""
## 着色颜色（展示用）
@export var color := Color(0.7, 0.7, 0.7)
## 上侧 socket
@export var up := ""
## 右侧 socket
@export var right := ""
## 下侧 socket
@export var down := ""
## 左侧 socket
@export var left := ""
## 出现权重（用于观测时的加权随机）
@export_range(0.1, 10.0, 0.1) var weight := 1.0

func socket(dir: int) -> String:
	match dir:
		0:
			return up
		1:
			return right
		2:
			return down
		_:
			return left

func _to_string() -> String:
	return name if not name.is_empty() else ("%s|%s|%s|%s" % [up, right, down, left])
