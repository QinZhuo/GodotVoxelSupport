@tool
class_name TownDef extends PCGGeneratorDef
## 城镇生成总控 — 可插拔步骤管线（城镇生成总控）
##
## steps 数组按序执行可插拔的 TownStepDef；留空使用内置标准链。
## 不同 steps 组合 + 参数 = 不同风格城镇（平原农耕镇/山地矿镇/渔村…）。
## 输出 ctx.output：key=TownLayout、key+_roads/_build 栅格、key+_site 选址点。
##
## 内置标准链：选址→路网→环路→巷道→广场→地块→建筑→室内→绿化→街具→农田→地形回写

@export_range(16, 512, 1) var width := 96
@export_range(16, 512, 1) var height := 96
## 从管线其它生成器取高度图（HeightMap）的 key；留空 = 平地城镇
@export var heightmap_key := ""
## 海平面（高度图水陆判定：低于此值为水）
@export_range(0.0, 1.0, 0.01) var sea_level := 0.5
## 归一高→世界格高的换算比例（渲染/导航共用）
@export_range(1.0, 24.0, 0.5) var height_scale := 8.0
## 城镇命名生成器（NAME 模式：前缀+后缀拼地名）；空 = 不命名
@export var name_gen: ContentGenDef

## —— 值语义（roads 层栅格） ——
@export var road_main_value := 3
@export var road_sec_value := 4
@export var road_alley_value := 5
@export var bridge_value := 6
@export var road_ring_value := 10
## 横穿主干道(Arterial)格值：宽阔平直的车行骨架, 现代城区感核心
@export var road_arterial_value := 12

## —— 值语义（build 层栅格） ——
@export var building_wall_value := 7
@export var building_floor_value := 8
@export var building_door_value := 9
## 广场格值
@export var plaza_value := 11

## 允许跨水架桥（主街/环路共用；false 时道路绕开水面）
@export var bridge_allowed := true
## 跨水额外代价（越高越不愿架桥）
@export_range(1.0, 64.0, 0.5) var bridge_cost := 10.0

## —— 步骤参数容器（由 steps 数组中的同名参数在运行时同步进来；
##    直接调用 generate_town 时也可手动赋值） ——
## [选址]
@export_range(4, 128, 1) var site_candidates := 32
@export_range(2, 32, 1) var site_radius := 8
@export_range(0, 32, 1) var water_band_min := 3
@export_range(4, 96, 1) var water_band_max := 24
## [路网]
@export_range(1, 4, 1) var main_width := 2
@export_range(3, 24, 1) var street_spacing_min := 5
@export_range(4, 32, 1) var street_spacing_max := 9
@export_range(6, 128, 1) var secondary_max_len := 56
@export_range(0.0, 1.0, 0.01) var street_wander := 0.3
@export_range(0.0, 2.0, 0.05) var main_jitter := 0.2
@export_range(0.0, 4.0, 0.05) var slope_cost_k := 1.5
## [Octilinear 八方向约束] 主街 A* 路径简化的最小直线段长（格）：
## 简化后道路只含 横/竖/45°斜 的长直段, 告别逐格碎弯
@export_range(4, 24, 1) var road_min_segment := 8
## 次街转向后最少直行格数（避免七扭八歪的碎弯）
@export_range(1, 16, 1) var street_min_run := 10
## [干道] 横穿主干道条数(0=关闭)：一横一纵即得"车行主干道穿城"的现代城区骨架。
## 业内参照 Cities: Skylines 路网分级——先 Arterial 骨架再向下生长次街/巷道,
## 干道宽阔平直(低抖动)、交叉口稀疏、街区放大。
@export_range(0, 3, 1) var arterial_h_count := 0
@export_range(0, 3, 1) var arterial_v_count := 0
@export_range(2, 5, 1) var arterial_width := 3
## 干道路径抖动幅度(远小于主街, 保证平直可通行感)
@export_range(0.0, 1.5, 0.05) var arterial_jitter := 0.25
## 沿干道两侧生长集散次街的间距(格)
@export_range(6, 32, 1) var arterial_collector_spacing := 12
## [广场]
@export_range(0, 12, 1) var plaza_radius := 4
@export var plaza_feature := "水井"
## [地块]
@export_range(16, 1024, 4) var max_block_area := 260
@export_range(4, 128, 1) var min_block_area := 32
@export_range(16, 512, 2) var lot_max_area := 60
@export_range(4, 64, 1) var lot_min_area := 18
## 地块最短边（格）：切分时保证两半沿切轴都不窄于此值，防 1 格细条地块
@export_range(1, 8, 1) var lot_min_edge := 2
## [建筑]
@export var houses: Array[TemplateDef] = []
@export var facilities: Array[FacilityDef] = []
@export_range(0.0, 1.0, 0.01) var house_fill_ratio := 0.85
@export_range(0, 4, 1) var setback := 1
@export_range(1, 8, 1) var house_layers_min := 1
@export_range(1, 8, 1) var house_layers_max := 3
## 面积→高度权重（CGA Mass Modeling：0=纯中心距离梯度, 1=纯地块面积驱动）
@export_range(0.0, 1.0, 0.05) var area_height_weight := 0.4
@export var house_roof := "gable"
@export var flat_roof_styles: Array[String] = ["石砌", "砖混"]
@export var style_table: Array[ContentEntryDef] = []
@export_range(0.02, 0.3, 0.01) var build_max_step := 0.08
## [室内]
@export var furniture_tables: Array[FurnitureTableDef] = []
@export var prop_table: Array[ContentEntryDef] = []
@export_range(0, 8, 1) var props_per_building := 3
## [绿化]
@export_range(0, 600, 5) var tree_count := 140
@export_range(1.0, 8.0, 0.5) var tree_min_distance := 2.5
@export_range(0, 16, 1) var street_tree_spacing := 5
## [街具]
@export_range(2, 16, 1) var streetlamp_spacing := 6
## 垃圾桶沿主街/干道的取样间距（格）
@export_range(4, 24, 1) var bin_spacing := 9
## 公交站沿干道的取样间距（格）
@export_range(8, 32, 1) var bus_stop_spacing := 18
## 广告牌沿干道的取样间距（格）
@export_range(16, 64, 2) var adboard_spacing := 32
## [农田]
@export_range(4, 64, 1) var farm_min_dist := 14
@export_range(8, 512, 4) var farm_min_area := 60
## [均衡] 环路收口后对路网稀疏象限补生次街的轮数（0=关闭）
@export_range(0, 6, 1) var infill_passes := 3
## 象限最低路格密度阈值（该象限路格数/象限面积，低于即触发补生长）
@export_range(0.0, 0.25, 0.005) var infill_min_density := 0.05
## 死路清理：迭代摘除 4 邻域度数≤1 的次街/巷道端头（主街/干道/环路/桥不动）
@export var prune_dead_ends := true
## 路网模式: false=主街A*+次街生长(TownRoadStep), true=张量场路网(TensorRoadStep)
## 张量场: 网格/径向/噪声/等高线四场 RBF 混合 → 流线追踪 → 吸附成网
@export var use_tensor_roads := false
## [张量场路网] 以下参数在 use_tensor_roads=true 时生效（总控，同步到 TensorRoadStep）
## 网格场整体角度(度)
@export_range(-90.0, 90.0, 1.0) var tensor_grid_angle := 0.0
## 径向场权重与中心(格坐标, 负值=关闭): 环形+放射大街
@export_range(0.0, 2.0, 0.05) var tensor_radial_strength := 0.0
@export var tensor_radial_center := Vector2(-1, -1)
## 噪声场权重: 街道弯曲有机感
@export_range(0.0, 1.5, 0.05) var tensor_noise_strength := 0.0
## 等高线场权重: 道路沿等高线走(需高度图, 平地自动失效)
@export_range(0.0, 2.0, 0.05) var tensor_contour_strength := 0.0
## 主街/次街线间距(格)
@export_range(8, 64, 1) var tensor_major_spacing := 24
@export_range(4, 32, 1) var tensor_minor_spacing := 10
## 坡度限制: 流线单步高差超过该值即截断(0=不限制); 山地次街存活关键, 过严会截断大量街段
@export_range(0.0, 1.0, 0.01) var tensor_max_step_rise := 0.03
## 城区半径(格, 0=铺满全图): 流线以选址点为圆心只在该半径内追踪, 出圈即断
## 防止路网+路灯延伸到无人区/图缘(A* 模式天然选址居中, 张量场需显式限定)
@export_range(0, 256, 1) var tensor_town_radius := 0
## 直行锁定(格): 道路保持直行的最短长度, 到点才重新定向
## 方向量化以网格轴(横平竖直)为主, 仅当方向场明确指向斜向时才产生45°道路
@export_range(1.0, 32.0, 0.5) var tensor_straight_run := 10.0
## [分区] 启用语义分区（市集/贵族/民居，写入 parcels[i].ward 与 layout.wards）
@export var enable_wards := true
## [城墙] 启用城墙+城门（墙写入 build 层；门洞记录到 layout.gates）
@export var enable_walls := true
## 主街城门之外额外开设的小门数
@export_range(0, 4, 1) var extra_gates := 1
## [贴地] 岸线建设容差：角部低于海平面但在容差内 → 桩基跨水而非弃建（山地/水岸规模关键）
@export_range(0.0, 0.2, 0.01) var shore_build_tolerance := 0.08
## [回写]
@export_range(0.02, 0.3, 0.01) var road_max_grade := 0.1
@export_range(0, 6, 1) var terrace_blend := 3
## 是否执行地形回写（ConformStep 的 enabled 同样可控制）
@export var terrain_conform := true

## —— 可插拔步骤链（留空 = 内置标准链） ——
@export var steps: Array[TownStepDef] = []


func _to_string() -> String:
	return name


func get_desc(_data) -> String:
	return "城镇 %dx%d · %d 步骤" % [width, height, effective_steps().size()]


## 生效步骤链：steps 非空用配置，否则返回内置标准链
func effective_steps() -> Array[TownStepDef]:
	if not steps.is_empty():
		return steps
	return TownDef.default_steps(use_tensor_roads, enable_walls)


## 内置标准链（每次调用生成新实例，资源间互不干扰）
## use_walls=false(现代城市等) 时不挂城墙步骤, 链里完全没有墙/门逻辑
static func default_steps(use_tensor: bool = false, use_walls: bool = true) -> Array[TownStepDef]:
	var list: Array[TownStepDef] = []
	list.append(TownSiteStep.new())
	# S2 路网二选一: A*主街生长 / 张量场流线追踪
	list.append(TensorRoadStep.new() if use_tensor else TownRoadStep.new())
	# 张量场主街已承担干道骨架+集散次街职责, ArterialStep 仅在 A* 模式追加
	if not use_tensor:
		list.append(TownArterialStep.new())
	list.append(TownRingStep.new())
	list.append(TownAlleyStep.new())
	list.append(TownPlazaStep.new())
	list.append(TownParcelStep.new())
	list.append(TownWardStep.new())
	list.append(TownBuildingStep.new())
	# 城墙+城门: 仅古城/要塞类城镇挂载(现代城市 enable_walls=false 时整步跳过)
	if use_walls:
		list.append(TownWallStep.new())
	list.append(TownInteriorStep.new())
	list.append(TownGreeneryStep.new())
	list.append(TownStreetStep.new())
	list.append(TownFarmStep.new())
	list.append(TownConformStep.new())
	return list


func generate(ctx: PCGContext) -> void:
	var hm: HeightMap = null
	if not heightmap_key.is_empty():
		hm = ctx.get_result(heightmap_key) as HeightMap
	var gctx := TownGenContext.new(self, hm, int(ctx.rng.seed))
	gctx.layout.heightmap = hm
	# 城镇命名（独立种子槽，不随步骤增减变化）
	if name_gen != null:
		gctx.layout.town_name = PCGTool.generate_name(
			name_gen, PCGTool.make_rng(PCGTool.derive_seed(int(ctx.rng.seed), 10)))
	for s in effective_steps():
		if s == null or not s.enabled:
			continue
		s.apply(gctx)
	ctx.output[_effective_key()] = gctx.layout
	ctx.output[_effective_key() + "_roads"] = gctx.layout.roads_grid
	ctx.output[_effective_key() + "_build"] = gctx.layout.build_grid
	ctx.output[_effective_key() + "_site"] = gctx.layout.site
