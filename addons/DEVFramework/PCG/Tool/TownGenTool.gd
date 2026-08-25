class_name TownGenTool extends RefCounted
## 城镇生成共享算法工具 — 被多个 TownStepDef 复用的通用算法
## (从 PCGTool 拆出, 城镇算法独立演进不污染通用 PCG 工具)

static var DIR4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
static var FACING_TO_ROT := {0: 2, 1: 3, 2: 0, 3: 1}


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


static func turn_left(d: Vector2i) -> Vector2i:
	return Vector2i(d.y, -d.x)


static func turn_right(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)


static func dominant_dir(v: Vector2) -> Vector2i:
	if absf(v.x) > absf(v.y):
		return Vector2i(signi(int(v.x)), 0)
	return Vector2i(0, signi(int(v.y)))


## 多源 BFS 距离场：到最近 source_value 格的 4 邻域步数
static func distance_field(grid: GeneratedGrid, source_value: int) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(grid.width * grid.height)
	dist.fill(INF)
	var queue := PackedInt32Array()
	for i in grid.cells.size():
		if grid.cells[i] == source_value:
			dist[i] = 0.0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		var cx := cur % grid.width
		var cy := cur / grid.width
		for d in DIR4:
			var nx := cx + d.x
			var ny := cy + d.y
			if not grid.in_bounds(nx, ny):
				continue
			var ni := ny * grid.width + nx
			if dist[ni] > dist[cur] + 1.0:
				dist[ni] = dist[cur] + 1.0
				queue.append(ni)
	return dist


## L 型走廊路径点
static func carve_l_path(a: Vector2, b: Vector2, rng: RandomNumberGenerator) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var x := int(a.x)
	var y := int(a.y)
	pts.append(a)
	if rng.randf() < 0.5:
		while x != int(b.x):
			x += signi(int(b.x) - x)
			pts.append(Vector2(x, y))
		while y != int(b.y):
			y += signi(int(b.y) - y)
			pts.append(Vector2(x, y))
	else:
		while y != int(b.y):
			y += signi(int(b.y) - y)
			pts.append(Vector2(x, y))
		while x != int(b.x):
			x += signi(int(b.x) - x)
			pts.append(Vector2(x, y))
	return pts


## 把路径以指定宽度印到栅格（水上自动标桥）
static func stamp_road_layer(roads: GeneratedGrid, path: PackedVector2Array,
		width: int, value: int, hm: HeightMap, sea_level: float, bridge_value: int) -> void:
	var hw := (width - 1) / 2
	for p in path:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-hw, width - hw):
			for dx in range(-hw, width - hw):
				var x := px + dx
				var y := py + dy
				if not roads.in_bounds(x, y):
					continue
				var v := value
				if hm != null and hm.get_height(x, y, 1.0) < sea_level:
					v = bridge_value
				roads.set_cell(x, y, v)


## 街区提取：非道路连通域
static func extract_blocks(roads: GeneratedGrid) -> Array[PackedInt32Array]:
	var sep := GeneratedGrid.create(roads.width, roads.height, 0)
	for i in sep.cells.size():
		sep.cells[i] = 1 if roads.cells[i] != 0 else 0
	return sep.components(0)


## 地块包围盒
static func bounds_of(cells: PackedInt32Array, w: int) -> Rect2i:
	var mn := Vector2i(2147483647, 2147483647)
	var mx := Vector2i(-2147483648, -2147483648)
	for idx in cells:
		var p := Vector2i(idx % w, idx / w)
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2i(mn, mx - mn + Vector2i.ONE)


## 临街方向统计
static func frontage_dir(roads: GeneratedGrid, cells_set: Dictionary) -> int:
	var counts := [0, 0, 0, 0]
	for idx in cells_set:
		var x: int = int(idx) % roads.width
		var y: int = int(idx) / roads.width
		for di in 4:
			var d: Vector2i = DIR4[di]
			if roads.get_cell(x + d.x, y + d.y, -1) != 0:
				counts[di] += 1
	var best := -1
	var bn := 0
	for di in 4:
		if counts[di] > bn:
			bn = counts[di]
			best = di
	return best


static func rot_point(p: Vector2i, sz: Vector2i, rot: int) -> Vector2i:
	match posmod(rot, 4):
		1: return Vector2i(sz.y - 1 - p.y, p.x)
		2: return Vector2i(sz.x - 1 - p.x, sz.y - 1 - p.y)
		3: return Vector2i(p.y, sz.x - 1 - p.x)
	return p
