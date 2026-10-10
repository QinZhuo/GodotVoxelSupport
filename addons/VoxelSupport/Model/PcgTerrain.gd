@tool
class_name PcgTerrain
extends PcgModel

## 体素地形 —— 噪声起伏 + 分层材质 + 表面颗粒（纯体素，零贴图）。
## 【为什么要有它】PCG 各 demo 长期缺"地面"这一层：树浮在天穹前、遗迹/岩壁没有落点，
## 投影无处可落（pcg_forest_demo 此前完全没有地面节点）。而地面偏偏是画面里**面积最大**
## 的表面 —— 它的层次几乎直接决定"精致还是灰模"。本类把"一块能看的地面"固化成一个
## 可复用模型，具体的色板与幅度留给场景。
## 【细节手段（本项目不用贴图：每个体素一种颜色，细节靠"更多/更不同颜色的体素"）】
##   ① 起伏：fbm 噪声决定每列地表高度 → 出现坡与台，不再是平板。
##   ② 分层：深处 / 下层土 / 表层用不同材质 ID，剖面有层次。
##   ③ 坡度分区：**陡坡露岩、缓地长草** —— 比"纯噪声分区"更像地形，
##      因为草确实长不在陡坡上；这条同时给剪影加了"露出岩层"的水平色带。
##   ④ 三档同色系：岩与草各按分块哈希挑一档深浅，得到成片的石块/草皮而非平涂
##      （挑档用哈希不用 fbm：fbm 输出向中间聚，会把多档退化成平涂，
##       见 PcgDetail.hash01 的实测说明）。
##   ⑤ 单个体素点缀：草丛（地表插一格）与碎石（嵌一格）—— 最小尺度上的细节，
##      也是"看起来像手工摆过"和"看起来像噪声"的分界。
##   ⑥ 浅坑：按比例挖掉地表一格并把坑底压暗，打散整片平板。
## 【确定性】噪声与哈希都由 seed 派生，同 grid_size + 同参数恒得同一结果。
## 【怎么让物件站在地上】地表高度是纯函数，用 `height_voxel()` 直接问，
## 配合 PcgScatter.ground_query 摆放物件即可（见 pcg_forest_demo），
## 不需要先把地形建出来再逐体素回查。


# 起伏

## 平均地表高度（体素）。网格 y 从 0 起算，故它同时决定"地下有多厚"。
@export var base_y: int = 4
## 起伏幅度（体素，±）。取值 ≥ 网格高度会让地表触顶/触底，被自动夹住。
@export var relief_height: float = 2.5
## 起伏特征尺寸（体素）。越小越碎，越大越像大坡。
@export var cell: float = 12.0
@export_range(1, 6) var octaves: int = 3
@export var seed: int = 0


# 分层材质

## 最深处（网格底部）。只有破坏演示才看得到剖面，但分层能防止"整体一色"。
@export var deep_material_id: int = 1
## 表层下方的土/岩。
@export var subsoil_material_id: int = 2
## 桩底层厚度（体素）：地表往下多少格之内算 subsoil，再往下算 deep。
@export var subsoil_depth: int = 3
## 露岩的三档（暗→亮）。坡面用。
@export var rock_ids: PackedInt32Array = PackedInt32Array([3, 4, 5])
## 草地的三档（暗→亮）。缓坡用。
@export var grass_ids: PackedInt32Array = PackedInt32Array([6, 7, 8])
## 干土 / 砂：草与岩之间的过渡色，靠 patch 噪声混进来。
@export var dry_material_id: int = 9
## 草丛（地表往上插一格）。
@export var tuft_material_id: int = 8
## 碎石（碎石点缀）。0 = 不生成。
@export var pebble_material_id: int = 0


# 表面分区

## 分区噪声尺度（体素）：草/砂/岩的大块分布。
@export var patch_cell: float = 9.0
## 草地覆盖率 0~1（缓坡中长草的比例，其余是砂与露岩）。
@export_range(0.0, 1.0) var grass_coverage: float = 0.55
## 坡度阈值：相邻列高差 ≥ 此值即判为坡（露岩、不长草）。
@export var slope_threshold: int = 2
## 挑档的格边长（体素）。越小越碎，越大越成片。
@export var shade_cell: float = 2.0
## 草丛比例（占地表格数）。
@export_range(0.0, 1.0) var tuft_ratio: float = 0.035
## 碎石比例。
@export_range(0.0, 1.0) var pebble_ratio: float = 0.02
## 浅坑比例（挖掉地表一格 + 坑底压暗）。
@export_range(0.0, 1.0) var pit_ratio: float = 0.03


# 采样

## 地表高度（体素 y）。世界坐标 → 网格坐标由调用方换算（见 pcg_forest_demo）。
## 【为什么单独暴露这个函数，而不是让调用方查体素】地形是"先摆物件、后建网格"
## 还是反过来的顺序都不该影响摆放结果；高度是纯函数，直接算最省事也最稳，
## 不必等 chunk 加载完（pcg_world_demo 的 _ground_y_at 就是因为要等基底加载
## 才不得不 await）。
func height_voxel(gx: float, gz: float) -> int:
	var hn := _relief_noise()
	return _height_at(hn, gx, gz, 1 << 30)


## 生成整块地形。
func build(grid_size: Vector3i) -> PackedInt32Array:
	var v := PcgModel.empty_volume(grid_size)
	if grid_size.x <= 0 or grid_size.z <= 0 or grid_size.y <= 0:
		return v

	var hn := _relief_noise()
	var pn := PcgDetail.make_noise(patch_cell, maxi(octaves - 1, 1), seed + 11)
	var sn := PcgDetail.make_noise(shade_cell, 1, seed + 23)

	var top_y := grid_size.y - 1
	var rock_n := rock_ids.size()
	var grass_n := grass_ids.size()
	# 山坡判定的取样步长：1 列。用"右邻/下邻"算梯度（前向差分），
	# 与中心差分比少一次采样，且对台阶地形更敏感（台阶是 1 格突变）。
	for z in grid_size.z:
		for x in grid_size.x:
			var h := _height_at(hn, x, z, top_y)
			var hx := _height_at(hn, x + 1, z, top_y)
			var hz := _height_at(hn, x, z + 1, top_y)
			var slope := maxi(absi(h - hx), absi(h - hz))
			var patch := PcgDetail.sample01(pn, x, 0, z)
			var is_grass := slope < slope_threshold and patch < grass_coverage

			var top_id := subsoil_material_id
			if is_grass and grass_n > 0:
				top_id = grass_ids[_shade_index(x, 0, z, sn, grass_n)]
			elif not is_grass and rock_n > 0 and patch < 0.86:
				# 露岩：坡面必露，平地里也留一点岩斑（patch 上段）。
				top_id = rock_ids[_shade_index(x, 0, z, sn, rock_n)]
			else:
				top_id = dry_material_id

			# 填柱：深处 / 下层土 / 表层
			var sub_top := maxi(h - subsoil_depth, 0)
			for y in h:
				var id := deep_material_id
				if y >= sub_top:
					id = subsoil_material_id
				v[PcgModel.index_of(x, y, z, grid_size)] = id
			v[PcgModel.index_of(x, h, z, grid_size)] = top_id

			# —— 表面颗粒（都在"地表格之上/之下"，不动结构） ——
			var r := PcgDetail.hash01(x, 0, z, seed + 51)
			if r < pit_ratio and h > sub_top + 1:
				# 浅坑：挖掉地表一格，坑底压暗 —— 打破整片平板的连贯高光
				v[PcgModel.index_of(x, h, z, grid_size)] = 0
				if rock_n > 0:
					v[PcgModel.index_of(x, h - 1, z, grid_size)] = rock_ids[0]
			elif h + 1 <= top_y:
				var r2 := PcgDetail.hash01(x, 0, z, seed + 73)
				if is_grass and r2 < tuft_ratio:
					v[PcgModel.index_of(x, h + 1, z, grid_size)] = tuft_material_id
				elif pebble_material_id > 0 and r2 >= 1.0 - pebble_ratio:
					v[PcgModel.index_of(x, h + 1, z, grid_size)] = pebble_material_id
	return v


# 内部

## 起伏噪声（同参数只建一次）。
var _relief: FastNoiseLite


func _relief_noise() -> FastNoiseLite:
	if _relief == null:
		_relief = PcgDetail.make_noise(cell, octaves, seed)
	return _relief


## fbm → 地表高度（体素）。越界安全（夹在 [1, top_y]）。
func _height_at(hn: FastNoiseLite, gx: float, gz: float, top_y: int) -> int:
	var n := PcgDetail.sample01(hn, int(gx), 0, int(gz)) * 2.0 - 1.0
	return clampi(base_y + int(round(relief_height * n)), 1, maxi(top_y, 1))


## 按 shade_cell 分块挑一档（哈希主导 + 噪声零均值扰动，理由见 PcgSurfaceTint._shade_index）。
func _shade_index(x: int, y: int, z: int, noise: FastNoiseLite, n: int) -> int:
	if n <= 1:
		return 0
	var s := maxf(shade_cell, 0.001)
	var cell_h := PcgDetail.hash01(
			int(floor(float(x) / s)), int(floor(float(y) / s)), int(floor(float(z) / s)),
			seed + 7)
	var wobble := (PcgDetail.sample01(noise, x, y, z) - 0.5) * 0.3
	return clampi(int(clampf(cell_h + wobble, 0.0, 0.999999) * float(n)), 0, n - 1)
