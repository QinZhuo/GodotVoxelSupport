@tool
class_name PcgSurfaceTint
extends PcgDetail

## 表面材质分区 —— 按噪声把暴露体素换成别的材质，让模型摆脱"整块纯色"的调色板观感。
##
## 【为什么需要它】三条产出栈的材质 ID 都是"整块模型一个主色"（SDF 各原语各一个、
## WFC 每图块一个、L-系统一个），于是一块石头整体同色，一棵树连树干带叶子同色。
## 本算子不改 `QVoxelSource` 的调色板、不改生成器契约，只在体素域上按位置重写 ID，
## 就得到"石头有苔藓、树干深叶浅、屋顶有积尘"这类分区 —— 这是纯 demo 层拿不到的
## 效果，因为 demo 只能给整个模型选一个材质。
##
## 【单档 vs 多档：本项目的体素着色观】本项目**不用贴图**——每个体素就是一种颜色，
## 细节靠"更多/更精细的体素 + 不同颜色"表达（贴图会把体素退化成贴图载体，
## 失去体素风格）。所以"表面有颗粒层次"的正确做法是：
##   `material_id`   单档：把命中区域整体换成另一种颜色（上苔藓、挂积尘）。
##   `material_ids`  多档：给命中区域一个**同色系的调色板梯度**，逐体素挑一档。
##                   于是同一面墙上会看到深浅不一的石块，而不是一整面平涂。
## 两者的"哪些体素被改写"判定完全相同（coverage / up_bias / min_exposure / 只看源材质），
## 差别只在"改成什么"。
##
## 【典型用法】
##   石头底色 1 → 苔藓绿 2（单档）
##   石柱墙 2 → [6,7,8] 三档深浅（多档，逐体素挑）
##
## 【与 PcgWeather 配对使用】通常先 Weather 挖出表面不规则，再 Tint 给新暴露的
## 凹坑上色（暴露判定是在 Weather 之后算的，凹坑侧面自然也会被判定为暴露面）。
## 两者在链上的先后顺序即执行顺序（QVoxelModel.modifiers）；多档换色通常排在
## 苔藓之后 —— 苔藓先占掉一部分表面，剩下的才做深浅分档。


## 目标材质 ID（单档）。
@export var material_id: int = 2
## 目标材质 ID 梯度（多档）。**非空时覆盖 `material_id`**。
## 命中的体素在这些 ID 里按噪声挑一档，形成同色系的体素级深浅变化。
## 下标靠后不代表"更亮"——颜色由调色板里各 ID 的 color 决定，这里只负责选。
@export var material_ids: PackedInt32Array = PackedInt32Array()
## 挑档用的噪声尺度（体素）。越小越接近"每个体素各挑各的"（颗粒感强），
## 越大越成片（同一片区域一个色调）。仅在 `material_ids` 非空时生效。
@export var shade_cell: float = 2.0
## 只替换原本是这个材质的体素；0 = 不限（任何实心体素都可被替换）。
## 用来做"只给石头长苔藓、不动木头"这类选择性上色；多档时用来圈定"给哪一层分档"。
@export var only_source_material_id: int = 0
## 噪声尺度（体素）。越小色块越碎，越大成片。控制"哪些体素被改写"。
@export var cell: float = 4.0
## fbm 倍频数。
@export_range(1, 6) var octaves: int = 3
## 覆盖率 0~1：噪声超过此值即替换。0.5 表示约一半表面被染色。
@export_range(0.0, 1.0) var coverage: float = 0.45
## 朝上偏好 0~1：越大越偏向染"朝上的表面"（积尘、苔藓、积雪都长在朝上的一面）。
## 与 coverage 相乘形成最终阈值，因此需要把 coverage 调低才能达到预期覆盖率。
@export_range(0.0, 1.0) var up_bias: float = 0.0
## 只染暴露度 ≥ 此值的体素（0 = 内部外部都染）。默认 1 = 只染看得见的表面。
@export_range(0, 6) var min_exposure: int = 1
## 保护最底层不染色。
@export var protect_ground: bool = true
## 只染**朝上**的表面（硬过滤"正上方非空"的体素）。
## 与 up_bias 的区别：up_bias 只是"更容易命中"，朝下的面仍可能被染到；
## up_only 是硬性排除 —— 用在"苔藓只铺在台顶、绝不爬上崖壁"这类明确要求上。
@export var up_only: bool = false
## 挑档方式（仅在 `material_ids` 多于 1 档时生效）：
##   false = 分块哈希 + 噪声微扰（默认）。档位分布最均匀（三档各约 1/3），
##           同一格内同色 → 成片结构；适合**小尺度颗粒**（每格几个体素）。
##   true  = 直接用噪声挑档。边界是软的、档位分布偏中间档，
##           但**没有笔直的格线**；适合**大尺度平缓表面**——
##           宽 100 体素的台面用哈希会排出方格迷彩，20 单位宽的崖壁上看像"贴图错位"，
##           此时必须换噪声才读作"这片岩层偏亮、那片偏暗"。
@export var shade_noise: bool = false


func apply(volume: PackedInt32Array, grid_size: Vector3i, seed: int) -> void:
	if coverage <= 0.0:
		return
	# 多档为空时退回单档，保证既有调用方行为一字不变。
	var ramp := material_ids
	if ramp.is_empty():
		ramp = PackedInt32Array([material_id])
	if ramp.is_empty():
		return
	# 已经是梯度里的 ID 就跳过：既保证幂等（同一份体积重复 apply 不会漂移），
	# 也让"多档排在苔藓之后"这类顺序不会互相覆盖。
	var in_ramp := {}
	for id in ramp:
		in_ramp[id] = true

	var mask := noise_at(cell, octaves, seed)
	var shade := noise_at(shade_cell, octaves, seed + 1)
	var inv := 1.0 - clampf(up_bias, 0.0, 1.0)
	var n_ramp := ramp.size()
	for z in grid_size.z:
		for y in grid_size.y:
			for x in grid_size.x:
				var idx := PcgModel.index_of(x, y, z, grid_size)
				var cur := volume[idx]
				if cur <= 0 or in_ramp.has(cur):
					continue
				if only_source_material_id > 0 and cur != only_source_material_id:
					continue
				if protect_ground and y == 0:
					continue
				# 便宜筛子放前面：挑朝上面只是一次数组访问，而噪声与暴露度都更贵。
				var is_up := PcgDetail.open_above(volume, grid_size, x, y, z)
				if up_only and not is_up:
					continue
				# 阈值：朝上的表面更易被染（阈值下调），朝下的更难（阈值上调）。
				var threshold := coverage
				if up_bias > 0.0:
					if is_up:
						threshold *= inv
					else:
						threshold *= 1.0 + up_bias
				# 噪声判定放在暴露度查询**之前**：暴露度每个体素要做 6 次数组访问，
				# 而噪声只是一次函数调用，先用便宜的筛子过滤掉大多数体素。
				if sample01(mask, x, y, z) >= threshold:
					continue
				if min_exposure > 0 and PcgDetail.exposure(volume, grid_size, x, y, z) < min_exposure:
					continue
				if n_ramp == 1:
					volume[idx] = ramp[0]
				elif shade_noise:
					volume[idx] = ramp[clampi(int(sample01(shade, x, y, z) * float(n_ramp)),
							0, n_ramp - 1)]
				else:
					volume[idx] = ramp[_shade_index(x, y, z, shade, shade_cell, seed, n_ramp)]


## 从 n_ramp 档里挑一档下标。
##
## 【不能直接拿噪声值乘档数】fbm 输出向中间聚，实测三档会变成 9% / 82% / 9% ——
## 画面照旧是一整面平涂，分档白做（详见 PcgDetail.hash01 的说明）。
##
## 【主权重给哈希，噪声只做零均值扰动】
##   主项 = 按 shade_cell 分块的确定性哈希：本身均匀 → 三档各约 1/3，
##         同一格内同色 → 保持"成片"的空间结构，不是逐体素噪点。
##   扰动 = (连续噪声 - 0.5) × 幅度：减 0.5 是关键 —— 它把向中间聚的 fbm 拉成
##         零均值，于是只把格子边界揉出波浪、**不会**再把结果推向中间档。
##         直接相加（见早期写法 0.7*hash + 0.3*noise）会重新引入偏置，
##         实测中间档仍有 51%，比 82% 好但照旧看得出平涂。
static func _shade_index(x: int, y: int, z: int, noise: FastNoiseLite,
		shade_cell: float, seed: int, n_ramp: int) -> int:
	var s := maxf(shade_cell, 0.001)
	var cell_h := PcgDetail.hash01(
			int(floor(float(x) / s)), int(floor(float(y) / s)), int(floor(float(z) / s)),
			seed + 7)
	var wobble := (sample01(noise, x, y, z) - 0.5) * 0.3
	var mix := clampf(cell_h + wobble, 0.0, 0.999999)
	return clampi(int(mix * float(n_ramp)), 0, n_ramp - 1)
