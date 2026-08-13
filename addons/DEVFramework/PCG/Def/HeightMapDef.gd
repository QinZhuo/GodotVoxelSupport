@tool
class_name HeightMapDef extends PCGGeneratorDef
## 高度图生成器 — 生成连续高度场（HeightMap）
##
## 多层噪声叠加（基形 + 细节 + 山峰）+ 可选岛屿/大陆掩膜 + 高度归一化映射。
## 结果写入管线 output[key]，值为 HeightMap（每格一个 0..1 高度）。
## 高度图是 2D 栅格/3D 体素的"地基"：离散化即可得任意地形形态。

@export_range(8, 1024, 1) var width := 96
@export_range(8, 1024, 1) var height := 96
## 高度图值语义：0=海平面，1=最高峰（0..1 连续）

## 基形噪声层（决定大陆/山地主体形状）
@export var base_layer: NoiseLayerDef
## 细节噪声层（叠加小尺度起伏，权重一般小于基形）
@export var detail_layer: NoiseLayerDef
## 山峰噪声层（Ridged 高频，可选，做陡峭山脊）
@export var ridge_layer: NoiseLayerDef

## 岛屿掩膜强度：0=无掩膜（噪声原样），>0 边缘沉入海（0..1 连续，1 最强）
@export_range(0.0, 1.0, 0.05) var island_strength := 0.0
## 掩膜形状：1=方形内缩，2=圆形内缩（岛屿更圆）
@export_range(1, 2, 1) var island_shape := 1

## 高度映射：输出高度的最低值（低于此视为海）
@export_range(0.0, 1.0, 0.01) var min_height := 0.0
## 高度映射：输出高度的最高值
@export_range(0.0, 1.0, 0.01) var max_height := 1.0
## 高度映射曲线（幂次，>1 抬高平地压低山峰，<1 反之）
@export_range(0.3, 3.0, 0.05) var height_curve := 1.0

## 基础种子偏移（分块世界/多地图避免相同）；0 用生成 rng 的种子
@export var seed_offset := 0

## 各层相对权重（基形 : 细节 : 山峰），默认偏重基形
@export_range(0.0, 1.0, 0.05) var base_weight := 1.0
@export_range(0.0, 1.0, 0.05) var detail_weight := 0.4
@export_range(0.0, 1.0, 0.05) var ridge_weight := 0.0

## —— 水力侵蚀（粒子模拟，让地形更真实） ——
## 侵蚀强度：0=关，越大河流/峡谷越深（用液滴数量表示）
@export_range(0, 200000, 1000) var erosion_droplets := 0
## 侵蚀惯性（0..1）：液滴保持方向的程度，越大河道越直
@export_range(0.0, 1.0, 0.05) var erosion_inertia := 0.1
## 单次侵蚀强度：越大一次削/沉越多
@export_range(0.0, 0.5, 0.01) var erosion_power := 0.2
## 液滴半径（采样邻域，越大河道越宽）
@export_range(1, 16, 1) var erosion_radius := 3
## 液滴最小高度差（低于此液滴停止）
@export_range(0.0, 0.1, 0.005) var erosion_min_slope := 0.005
## 蒸发率（0..1）：每次移动液滴携带水减少比例，控制河道长度
@export_range(0.0, 0.1, 0.005) var erosion_evaporate := 0.02
## 悬崖落差阈值（高度单位）：液滴单步下降超过此值视为悬崖 → 停止侵蚀（保留陡坡/峡谷壁）
@export_range(0.0, 1.0, 0.02) var erosion_cliff_drop := 0.0
## 沉积率（0..1）：泥沙沉积强度，越低越保留下坡陡坡（配合 cliff 保留地形锐利度）
@export_range(0.0, 1.0, 0.05) var erosion_deposition_rate := 1.0

## —— 热侵蚀（thermal erosion，平滑坡面/自然山脊） ——
## 迭代次数：0=关闭；每迭代把超休止角的高度差从高格搬运到低格，O(n) 稳定
@export_range(0, 200, 1) var thermal_iterations := 0
## 休止角（talus）：相邻格高差超过此值即搬运，越小坡越缓
@export_range(0.001, 0.2, 0.005) var thermal_talus := 0.05


func generate(ctx: PCGContext) -> void:
	var hm := PCGTool.generate_heightmap(self, ctx.rng)
	ctx.output[_effective_key()] = hm


func get_desc(_data) -> String:
	return "HeightMap %dx%d" % [width, height]

func _to_string() -> String:
	return name
