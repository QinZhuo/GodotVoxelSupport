@tool
class_name TensorRoadStep extends TownStepDef
## S2 替代方案 — 张量场路网 (Chen et al. 2008 "Interactive Procedural Street Modeling")
## 方向场(网格场+径向场+噪声场+等高线场 RBF 混合) → 流线追踪(RK2) → 空间哈希吸附成路口 → 印刷入图
## 平地+网格场自动退化为曼哈顿格网; 径向场造环形+放射大街; 噪声场造有机街区;
## 等高线场让道路贴山走(需高度图)。与 TownRoadStep 互斥, 二选一插拔。

## 网格场整体角度(度): 道路主走向
@export_range(-90.0, 90.0, 1.0) var grid_angle := 0.0
## 网格场权重(0=关闭)
@export_range(0.0, 2.0, 0.05) var grid_strength := 1.0
## 径向场中心(格坐标, 负值=关闭): 环形+放射大街
@export var radial_center := Vector2(-1, -1)
## 径向场权重
@export_range(0.0, 2.0, 0.05) var radial_strength := 0.0
## 径向场影响半径(格)
@export_range(8.0, 256.0, 1.0) var radial_radius := 64.0
## 噪声场权重: 街道弯曲有机感
@export_range(0.0, 1.5, 0.05) var noise_strength := 0.0
@export_range(0.01, 0.3, 0.005) var noise_scale := 0.06
## 等高线场权重: 道路沿等高线走(需高度图; 平地自动失效)
@export_range(0.0, 2.0, 0.05) var contour_strength := 0.0
## 主街线间距(格)
@export_range(8, 64, 1) var major_spacing := 24
## 次街线间距(格)
@export_range(4, 32, 1) var minor_spacing := 10
## 追踪步长(格)
@export_range(0.3, 2.0, 0.05) var step_len := 0.8
## 直行锁定(格): 流线保持直行的最短长度, 到点才按方向场重新定向
## 方向量化以网格轴为主(横平竖直), 方向场明确指向斜向时才产生45°; 垂直相交穿过成十字路口
@export_range(1.0, 32.0, 0.5) var straight_run := 10.0
## 单线最大长度(格)
@export_range(16, 512, 4) var max_len := 320
## 吸附距离: 靠近既有路即接入成路口(格)
@export_range(1.0, 6.0, 0.1) var snap_dist := 2.2
## 短于该长度的线丢弃(防碎片)
@export_range(0, 32, 1) var min_len := 10
## 坡度限制: 流线单步高差超过该值即截断(0=不限制)
@export_range(0.0, 1.0, 0.01) var max_step_rise := 0.03
## 城区半径(格, 0=铺满全图): 流线以圆心(center)为界只在该半径内追踪, 出圈即断
@export_range(0, 256, 1) var town_radius := 0
## 城区圆心(格坐标; 由 TownGenContext 注入选址点, 独立使用时默认图心)
var center := Vector2(-1, -1)


func apply(ctx: TownGenContext) -> void:
	PCGTool.town_tensor_road_step(self, ctx)
