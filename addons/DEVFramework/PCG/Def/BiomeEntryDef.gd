@tool
class_name BiomeEntryDef extends Resource
## 生物群系条目 — 用 高度/湿度/温度 数值区间描述一个群系
##
## 匹配规则：三个采样值同时落在对应区间即命中（区间含端点）。
## 定义顺序即优先级，先匹配先得；建议把"兜底群系"（如海洋）放最后。

## 群系名
@export var name := "平原"
## 展示颜色（群系图着色用）
@export var color := Color(0.4, 0.7, 0.3)
## 高度区间
@export_range(0.0, 1.0, 0.01) var height_min := 0.0
@export_range(0.0, 1.0, 0.01) var height_max := 1.0
## 湿度区间
@export_range(0.0, 1.0, 0.01) var moisture_min := 0.0
@export_range(0.0, 1.0, 0.01) var moisture_max := 1.0
## 温度区间
@export_range(0.0, 1.0, 0.01) var temperature_min := 0.0
@export_range(0.0, 1.0, 0.01) var temperature_max := 1.0

func matches(h: float, m: float, t: float) -> bool:
	return h >= height_min and h <= height_max \
		and m >= moisture_min and m <= moisture_max \
		and t >= temperature_min and t <= temperature_max

func _to_string() -> String:
	return name
