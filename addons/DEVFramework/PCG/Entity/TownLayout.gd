class_name TownLayout extends RefCounted
## PCG 城镇生成结果 — 纯数据实体（运行时数据）
##
## 由 TownDef 城镇管线产出，聚合各阶段中间结果：
## 选址 / 道路图 / 街区地块 / 建筑（M2）/ 室内家具（M3）。
## 遵守框架「结果纯数据、渲染解耦」约定；可整体序列化（配合 SaveTool）。

## 城镇选址点（格坐标）
var site := Vector2i.ZERO
## 选址评分（0..1，调试/预览用）
var site_score := 0.0
## 道路层栅格：空=非道路，值语义由 TownDef 配置（主街/次街/巷道/桥）
var roads_grid: GeneratedGrid = null
## 道路图节点（格坐标浮点，与 road_edges 配套）
var road_nodes := PackedVector2Array()
## 道路边列表 [{a:int(节点下标), b:int, width:int, cls:int}]，cls 见 EdgeClass
var road_edges: Array = []

## 地块列表 [{rect:Rect2i(包围盒), cells:PackedInt32Array(格线性索引),
## frontage_dir:int(-1=无临街，否则为 _DIR4 方向索引 0上1右2下3左)}]
var parcels: Array = []
## 建筑层栅格：空=无建筑，值语义由 TownDef 配置（墙/地板/门）
var build_grid: GeneratedGrid = null
## 建筑列表 [{id, type, style, rect:Rect2i(足迹), door:Vector2i, facing:int}]
var buildings: Array = []
## 室内布局 building_id -> {slots:[{cell,item}], props:[{cell,item}], yard:[Vector2i]}
var interiors := {}
## 广场格（线性索引，site 周围空地；不放建筑）
var plaza_cells := PackedInt32Array()
## 地形高度场（透传或回写后的最终地形；消费方 y = sample(x,y) × height_scale）
var heightmap: HeightMap = null
## 城镇名（ContentGenDef NAME 模式生成；空 = 未配置命名）
var town_name := ""
## 广场中心设施（水井/喷泉…）位置与名称；item 为空表示无设施
var plaza_center := Vector2i(-1, -1)
var plaza_item := ""
## 树木（格坐标，城镇空地绿化散布 + 行道树）
var trees := PackedVector2Array()
## 灌木丛（格坐标，主干道两侧绿带低矮绿化）
var bushes := PackedVector2Array()
## 街具 {"lamps":[路灯格], "benches":[长椅格], "bins":[垃圾桶格],
##       "bus_stops":[公交站格], "hydrants":[消防栓格], "adboards":[广告牌格]}
var streets := {}
## 农田区块列表（每项为一片连片农田的格线性索引；条纹方向由消费方按坐标推算）
var farms: Array = []
## 城墙层栅格（空=无城墙；非零=墙格，已写入 build 层同值供回写/渲染复用）
var walls_grid: GeneratedGrid = null
## 城门列表 [{"pos":Vector2i, "edge":"N/E/S/W"}]（主街必开；亦是 NPC 进出锚点）
var gates: Array = []
## 语义分区统计 {"market"/"noble"/"common": {"type":String, "parcels":int}}
## （逐地块标签在 parcels[i].ward）
var wards: Dictionary = {}
## 城墙四角塔楼位（格坐标，数据预留；消费方自渲染）
var wall_towers := PackedVector2Array()

## 道路等级
enum EdgeClass { MAIN, SECONDARY, ALLEY, ARTERIAL }

func get_roads_grid() -> GeneratedGrid:
	return roads_grid


## —— 序列化（与 SaveTool 的 JSON/GZIP 兼容） ——

func to_data() -> Dictionary:
	var parcel_data: Array = []
	for p in parcels:
		parcel_data.append({
			"rect": [p.rect.position.x, p.rect.position.y, p.rect.size.x, p.rect.size.y],
			"cells": p.cells,
			"frontage": int(p.frontage_dir),
			"ward": String(p.get("ward", "")),
		})
	var edge_data: Array = []
	for e in road_edges:
		edge_data.append({"a": e.a, "b": e.b, "width": e.width, "cls": int(e.cls)})
	var nodes_data := PackedFloat32Array()
	for n in road_nodes:
		nodes_data.append(n.x)
		nodes_data.append(n.y)
	var building_data: Array = []
	for b in buildings:
		building_data.append({
			"id": b.id, "type": b.type, "style": b.style,
			"rect": [b.rect.position.x, b.rect.position.y, b.rect.size.x, b.rect.size.y],
			"door": [b.door.x, b.door.y], "facing": int(b.facing),
			"layers": int(b.layers), "roof": String(b.roof),
			"ground_y": float(b.get("ground_y", 0.0)),
			"foundation": String(b.get("foundation", "terrace")),
		})
	var interior_data := {}
	for k in interiors:
		var v: Dictionary = interiors[k]
		var sl: Array = []
		for sit in v.slots:
			sl.append({"cell": [sit.cell.x, sit.cell.y], "item": String(sit.item)})
		var pr: Array = []
		for pit in v.props:
			pr.append({"cell": [pit.cell.x, pit.cell.y], "item": String(pit.item)})
		var yd := PackedInt32Array()
		for yc in v.get("yard", []):
			yd.append(yc.x)
			yd.append(yc.y)
		interior_data[str(k)] = {"slots": sl, "props": pr, "yard": yd}
	var lamps: Array = []
	for lamp in streets.get("lamps", []):
		lamps.append([lamp.x, lamp.y])
	var benches: Array = []
	for bench in streets.get("benches", []):
		benches.append([bench.x, bench.y])
	var bins: Array = []
	for bin in streets.get("bins", []):
		bins.append([bin.x, bin.y])
	var bus_stops: Array = []
	for stop in streets.get("bus_stops", []):
		bus_stops.append([stop.x, stop.y])
	var hydrants: Array = []
	for hyd in streets.get("hydrants", []):
		hydrants.append([hyd.x, hyd.y])
	var adboards: Array = []
	for adb in streets.get("adboards", []):
		adboards.append([adb.x, adb.y])
	return {
		"site": [site.x, site.y],
		"score": site_score,
		"roads": roads_grid.to_data() if roads_grid else null,
		"build": build_grid.to_data() if build_grid else null,
		"nodes": nodes_data,
		"edges": edge_data,
		"parcels": parcel_data,
		"buildings": building_data,
		"interiors": interior_data,
		"plaza": plaza_cells,
		"plaza_center": [plaza_center.x, plaza_center.y],
		"plaza_item": plaza_item,
		"trees": trees,
		"bushes": bushes,
		"streets_lamps": lamps,
		"streets_benches": benches,
		"streets_bins": bins,
		"streets_bus_stops": bus_stops,
		"streets_hydrants": hydrants,
		"streets_adboards": adboards,
		"farms": farms,
		"heightmap": heightmap.to_data() if heightmap else null,
		"town_name": town_name,
		"walls": walls_grid.to_data() if walls_grid else null,
		"gates": gates,
		"wards": wards,
		"wall_towers": wall_towers,
	}


static func from_data(data: Dictionary) -> TownLayout:
	var t := TownLayout.new()
	var s: Array = data.get("site", [0, 0])
	t.site = Vector2i(int(s[0]), int(s[1]))
	t.site_score = float(data.get("score", 0.0))
	var rd = data.get("roads")
	if rd is Dictionary and not (rd as Dictionary).is_empty():
		t.roads_grid = GeneratedGrid.from_data(rd)
	var bd = data.get("build")
	if bd is Dictionary and not (bd as Dictionary).is_empty():
		t.build_grid = GeneratedGrid.from_data(bd)
	var nodes := PackedFloat32Array(data.get("nodes", []))
	for i in range(0, nodes.size(), 2):
		t.road_nodes.append(Vector2(nodes[i], nodes[i + 1]))
	for e in data.get("edges", []):
		t.road_edges.append({
			"a": int(e.a), "b": int(e.b), "width": int(e.width), "cls": int(e.cls),
		})
	for p in data.get("parcels", []):
		var r: Array = p.rect
		t.parcels.append({
			"rect": Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])),
			"cells": PackedInt32Array(p.cells),
			"frontage_dir": int(p.frontage),
			"ward": String(p.get("ward", "")),
		})
	for b in data.get("buildings", []):
		var br: Array = b.rect
		var dr: Array = b.door
		t.buildings.append({
			"id": int(b.id), "type": String(b.type), "style": String(b.style),
			"rect": Rect2i(int(br[0]), int(br[1]), int(br[2]), int(br[3])),
			"door": Vector2i(int(dr[0]), int(dr[1])), "facing": int(b.facing),
			"layers": int(b.get("layers", 1)), "roof": String(b.get("roof", "gable")),
			"ground_y": float(b.get("ground_y", 0.0)),
			"foundation": String(b.get("foundation", "terrace")),
		})
	for k in data.get("interiors", {}):
		var v: Dictionary = data.interiors[k]
		var slots: Array = []
		for sit in v.slots:
			var sc: Array = sit.cell
			slots.append({"cell": Vector2i(int(sc[0]), int(sc[1])), "item": String(sit.item)})
		var props: Array = []
		for pit in v.props:
			var pc: Array = pit.cell
			props.append({"cell": Vector2i(int(pc[0]), int(pc[1])), "item": String(pit.item)})
		var yd := PackedInt32Array(v.get("yard", []))
		var yard: Array = []
		for yi in range(0, yd.size(), 2):
			yard.append(Vector2i(yd[yi], yd[yi + 1]))
		t.interiors[int(k)] = {"slots": slots, "props": props, "yard": yard}
	t.plaza_cells = PackedInt32Array(data.get("plaza", []))
	var pc: Array = data.get("plaza_center", [-1, -1])
	t.plaza_center = Vector2i(int(pc[0]), int(pc[1]))
	t.plaza_item = String(data.get("plaza_item", ""))
	t.trees = PackedVector2Array(data.get("trees", []))
	t.bushes = PackedVector2Array(data.get("bushes", []))
	t.farms = []
	for farm in data.get("farms", []):
		t.farms.append(PackedInt32Array(farm))
	for lamp in data.get("streets_lamps", []):
		if not t.streets.has("lamps"):
			t.streets["lamps"] = []
		t.streets["lamps"].append(Vector2i(int(lamp[0]), int(lamp[1])))
	for bench in data.get("streets_benches", []):
		if not t.streets.has("benches"):
			t.streets["benches"] = []
		t.streets["benches"].append(Vector2i(int(bench[0]), int(bench[1])))
	for bin in data.get("streets_bins", []):
		if not t.streets.has("bins"):
			t.streets["bins"] = []
		t.streets["bins"].append(Vector2i(int(bin[0]), int(bin[1])))
	for stop in data.get("streets_bus_stops", []):
		if not t.streets.has("bus_stops"):
			t.streets["bus_stops"] = []
		t.streets["bus_stops"].append(Vector2i(int(stop[0]), int(stop[1])))
	for hyd in data.get("streets_hydrants", []):
		if not t.streets.has("hydrants"):
			t.streets["hydrants"] = []
		t.streets["hydrants"].append(Vector2i(int(hyd[0]), int(hyd[1])))
	for adb in data.get("streets_adboards", []):
		if not t.streets.has("adboards"):
			t.streets["adboards"] = []
		t.streets["adboards"].append(Vector2i(int(adb[0]), int(adb[1])))
	var hmd = data.get("heightmap")
	if hmd is Dictionary and not (hmd as Dictionary).is_empty():
		t.heightmap = HeightMap.from_data(hmd)
	t.town_name = String(data.get("town_name", ""))
	var wd = data.get("walls")
	if wd is Dictionary and not (wd as Dictionary).is_empty():
		t.walls_grid = GeneratedGrid.from_data(wd)
	for g in data.get("gates", []):
		t.gates.append({"pos": Vector2i(int(g.pos.x), int(g.pos.y)), "edge": String(g.edge)})
	t.wards = data.get("wards", {})
	t.wall_towers = PackedVector2Array()
	for t2 in data.get("wall_towers", []):
		t.wall_towers.append(Vector2(int(t2.x), int(t2.y)))
	return t
