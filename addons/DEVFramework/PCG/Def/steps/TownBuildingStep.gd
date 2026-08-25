@tool
class_name TownBuildingStep extends TownStepDef
## 建筑放置 — 设施(必有建筑)优先分配 → 住宅填充；锚点定位保证门临街；
## 贴地判定(切台/桩基/水上弃建)；层数按距选址衰减；风格邻近继承

## 户型模板库（门字符 G 画在最底边墙上，旋转后门自动朝向临街边）
@export var houses: Array[TemplateDef] = []
## 功能设施表（酒馆/教堂/铁匠铺…：数量期望 + 主街偏好 + 层数屋顶 + 专属户型）
@export var facilities: Array[FacilityDef] = []
## 其余地块的住宅填充比例
@export_range(0.0, 1.0, 0.01) var house_fill_ratio := 0.85
## 建筑足迹距地块边缘的退线（格）
@export_range(0, 4, 1) var setback := 1
## 住宅随机层数下限/上限（实际层数受距选址距离衰减：中心高外围矮）
@export_range(1, 4, 1) var house_layers_min := 1
@export_range(1, 4, 1) var house_layers_max := 3
## 住宅默认屋顶类型（gable=双坡 / flat=平顶）
@export var house_roof := "gable"
## 这些风格强制平顶（石砌/砖混搭配平顶更合理）
@export var flat_roof_styles: Array[String] = ["石砌", "砖混"]
## 建筑风格加权表（同街区邻近建筑倾向同风格）
@export var style_table: Array[ContentEntryDef] = []
## footprint 四角高差超过此值转桩基（有高度图时生效）
@export_range(0.02, 0.3, 0.01) var build_max_step := 0.08


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_building_step(self, ctx)
