@tool
class_name PcgWeather
extends PcgDetail

## 风化 / 侵蚀 —— 按噪声把**暴露在外面的**体素按概率挖空，让规整体块表面出现
## 缺角、凹坑与不规则轮廓。这是把"数学上正确的方块/球"变成"看起来像被风化过的
## 石质资产"最省力的一步，且对所有形态来源（SDF / WFC / 元胞 / L-系统）统一生效。
##
## 【噪声取向】用 fbm 多倍频而不是单层 value：单层会得到规则圆斑（像华夫饼），
## 多层叠加才是不规则的侵蚀痕。
##
## 【为什么只动暴露体素】内部体素看不见，挖它只会让模型变瘦、失去结构；
## 暴露度越高（棱角、凸起、细枝末端）越容易被蚀，对应现实里"棱角先磨损"。
##
## 【不要开太狠】strength 建议 0.15~0.35。超过 0.5 会把模型啃成海绵，
## 且稀疏体素模型（树、栅栏）会散架 —— 这是本算子唯一需要调参把守的地方。


## 侵蚀强度 0~1（= 单个体素被挖掉的概率上限）。建议 0.15~0.35。
@export_range(0.0, 1.0) var strength: float = 0.22
## 噪声尺度（体素）。越小侵蚀痕越细碎，越大越成片。
@export var cell: float = 5.0
## fbm 倍频数，越高细节层次越多。
@export_range(1, 6) var octaves: int = 3
## 棱角偏好 0~1：越大，暴露度高的位置越容易被蚀（棱角磨损）。
@export_range(0.0, 1.0) var edge_bias: float = 0.6
## 只侵蚀暴露度 ≥ 此值的体素。1 = 只动至少有一个面露在外面的（默认）；
## 设为 6 则只蚀孤立块与细枝末端。
@export_range(0, 6) var min_exposure: int = 1
## 保护最底层不挖 —— 保证模型与地面/底座仍然接触，不会看起来悬空。
@export var protect_ground: bool = true
## 保护顶层不挖。留给需要完整顶面（地板、屋顶）的模型。
@export var protect_top: bool = false

## 阈值上限：即便参数拉满也不会把侵蚀概率推到 1，
## 否则 strength=1 时会整片消失（对树这类稀疏模型是灾难）。
const MAX_THRESHOLD := 0.72


func apply(volume: PackedInt32Array, grid_size: Vector3i, seed: int) -> void:
	if strength <= 0.0:
		return
	var noise := noise_at(cell, octaves, seed)
	for z in grid_size.z:
		for y in grid_size.y:
			for x in grid_size.x:
				var idx := PcgModel.index_of(x, y, z, grid_size)
				if volume[idx] <= 0:
					continue
				if protect_ground and y == 0:
					continue
				if protect_top and y == grid_size.y - 1:
					continue
				var exp := PcgDetail.exposure(volume, grid_size, x, y, z)
				if exp < min_exposure:
					continue
				var bias := 0.0
				if edge_bias > 0.0:
					bias = edge_bias * float(exp - min_exposure) / float(maxi(6 - min_exposure, 1))
					bias = clampf(bias, 0.0, 1.0)
				var threshold := minf(strength * (0.35 + 0.65 * bias), MAX_THRESHOLD)
				if sample01(noise, x, y, z) < threshold:
					volume[idx] = 0
