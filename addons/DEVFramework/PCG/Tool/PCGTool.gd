@tool
## PCG 统一入口 — 随机 / 噪声 / 网格 / 散布 / 内容 / 管线
##
## 设计要点：
##   - 一切生成从 seed 派生，同一 Def + 同一种子必可复现
##   - 管线中每个生成器使用独立派生的 RNG（derive_seed），互不干扰、顺序稳定
##   - 只包装 Godot 内置能力（FastNoiseLite 等），不自研可复用底层
class_name PCGTool

## —— 随机 ——

## 创建带种子的随机源
static func make_rng(seed: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return rng

## 从基础种子派生独立子种子（管线中不同生成器用不同 slot，保证可复现且互不干扰）
static func derive_seed(base: int, slot: int) -> int:
	return (base ^ (slot * 0x9E3779B1)) & 0x7FFFFFFF

## —— 噪声 ——

## 把噪声层渲染成灰度图（用于预览 / 纹理）
static func noise_image(layer: NoiseLayerDef, width: int, height: int, seed := 0) -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	var noise: FastNoiseLite = layer.build_noise(seed)
	for y in height:
		for x in width:
			var v := layer.sample(noise, x, y)
			img.set_pixel(x, y, Color(v, v, v))
	return img

## —— 网格 ——

static func generate_grid(def: GridGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> GeneratedGrid:
	var grid := GeneratedGrid.create(def.width, def.height, def.empty_value)
	match def.type:
		GridGenDef.Type.NOISE_TERRAIN:
			_gen_noise_terrain(grid, def, rng)
		GridGenDef.Type.CELLULAR:
			_gen_cellular(grid, def, rng)
		GridGenDef.Type.MAZE:
			_gen_maze(grid, def, rng)
		GridGenDef.Type.RANDOM_WALK:
			_gen_random_walk(grid, def, rng)
		GridGenDef.Type.BSP_ROOMS:
			_gen_bsp_rooms(grid, def, rng)
		GridGenDef.Type.WFC:
			_gen_wfc(grid, def, rng, fixed)
		GridGenDef.Type.VORONOI:
			_gen_voronoi(grid, def, rng)
	if def.connectivity != GridGenDef.Connectivity.NONE:
		_apply_connectivity(grid, def, rng)
	return grid

## —— 连通性后处理 ——

## 空区域连通性保证：KEEP_LARGEST=保留最大空区填墙，CONNECT_ALL=隧道连接全部空区
static func _apply_connectivity(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if grid.width <= 0 or grid.height <= 0:
		return
	var comps := grid.components(def.empty_value)
	if def.connectivity == GridGenDef.Connectivity.KEEP_LARGEST:
		_keep_largest(grid, def, comps)
	elif def.connectivity == GridGenDef.Connectivity.CONNECT_ALL:
		_connect_all(grid, def, comps, rng)

## 保留最大空连通域，其余填为实体
static func _keep_largest(grid: GeneratedGrid, def: GridGenDef, comps: Array[PackedInt32Array]) -> void:
	if comps.size() <= 1:
		return
	var main_idx := 0
	for i in comps.size():
		if comps[i].size() > comps[main_idx].size():
			main_idx = i
	for i in comps.size():
		if i == main_idx:
			continue
		for idx in comps[i]:
			grid.cells[idx] = def.solid_value

## 隧道连接所有空区域到主区域（有机蜿蜒：Dijkstra + 随机扰动代价，走空便宜走墙贵）
static func _connect_all(grid: GeneratedGrid, def: GridGenDef, comps: Array[PackedInt32Array], rng: RandomNumberGenerator) -> void:
	if comps.size() <= 1:
		return
	var main_idx := 0
	for i in comps.size():
		if comps[i].size() > comps[main_idx].size():
			main_idx = i
	var main_set := {}
	for idx in comps[main_idx]:
		main_set[idx] = true
	for ci in comps.size():
		if ci == main_idx:
			continue
		_connect_region(grid, def, comps[ci][0], main_set, rng)

## 从孤立区起点做带随机扰动的代价寻路，挖出有机隧道到最近主区格
static func _connect_region(grid: GeneratedGrid, def: GridGenDef, start_idx: int, main_set: Dictionary, rng: RandomNumberGenerator) -> void:
	var w := grid.width
	var start := Vector2i(start_idx % w, start_idx / w)
	var dist := {}
	dist[start] = 0.0
	var prev := {}
	prev[start] = Vector2i(-1, -1)
	var open_list := [start]
	var end := Vector2i(-1, -1)
	var guard := 0
	while not open_list.is_empty() and guard < w * grid.height * 3:
		guard += 1
		# 取代价最小格（Dijkstra）
		var cur: Vector2i = open_list[0]
		var cur_d: float = dist[cur]
		for p in open_list:
			if dist[p] < cur_d:
				cur_d = dist[p]
				cur = p
		open_list.erase(cur)
		if main_set.has(cur.y * w + cur.x):
			end = cur
			break
		for d in _DIR4:
			var np: Vector2i = cur + d
			if not grid.in_bounds(np.x, np.y):
				continue
			# 走空代价低(1)、穿墙代价高(2.5)，加随机扰动 → 隧道自然蜿蜒且尽量借道已有洞穴
			var is_wall := grid.get_cell(np.x, np.y) == def.solid_value
			var cost := (2.5 if is_wall else 1.0) + rng.randf_range(-0.3, 0.3)
			var nd: float = dist[cur] + cost
			if not dist.has(np) or nd < dist[np]:
				dist[np] = nd
				prev[np] = cur
				open_list.append(np)
	if end.x < 0:
		return
	var cur2 := end
	while cur2 != start:
		grid.set_cell(cur2.x, cur2.y, def.empty_value)
		main_set[cur2.y * w + cur2.x] = true
		cur2 = prev[cur2]
	grid.set_cell(start.x, start.y, def.empty_value)
	main_set[start.y * w + start.x] = true

## —— 3D 网格 ——

static func generate_grid_3d(def: Grid3DGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> GeneratedGrid3D:
	var grid := GeneratedGrid3D.create(def.width, def.height, def.depth, def.empty_value)
	match def.type:
		Grid3DGenDef.Type.NOISE_SURFACE:
			_gen3d_surface(grid, def, rng)
		Grid3DGenDef.Type.CAVE_3D:
			_gen3d_cave(grid, def, rng)
		Grid3DGenDef.Type.WFC_3D:
			_gen3d_wfc(grid, def, rng, fixed)
		Grid3DGenDef.Type.CAVE_NOISE_3D:
			_gen3d_noise_cave(grid, def, rng)
	return grid

## 后台线程生成网格（大图不卡主线程；GeneratedGrid 是纯数据，线程安全）
## C++ 原生类在主线程预热（首次 instantiate 线程亲和），worker 线程只调用纯函数方法
static func generate_grid_async(def: GridGenDef, seed: int) -> GeneratedGrid:
	if def.type == GridGenDef.Type.WFC:
		FrameworkNative.get_native(&"PCGWFC", [&"generate"])  # 预热(主线程)
	var grid: GeneratedGrid = await AsyncTool.thread_call(func() -> GeneratedGrid:
		return generate_grid(def, make_rng(seed))
	)
	return grid

## 后台线程生成网格 + 实时进度回调（大 WFC 不卡帧，UI 可显示进度）
## on_progress: func(p: float)，主线程每帧回调 0..1
## WFC 进度由 C++ 静态量(PCGWFC.get_last_progress)记录, 主线程每帧轮询
static func generate_grid_async_progress(def: GridGenDef, seed: int, on_progress: Callable = func(_p: float): pass) -> GeneratedGrid:
	var native: Object = null
	if def.type == GridGenDef.Type.WFC:
		native = FrameworkNative.get_native(&"PCGWFC", [&"generate", &"get_last_progress"])  # 预热(主线程)
	var data := {}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = _async_grid_work(def, seed)
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		if native != null:
			on_progress.call(native.call(&"get_last_progress"))
		await Engine.get_main_loop().process_frame
	on_progress.call(1.0)
	return data.get("result") as GeneratedGrid


## async 工作函数：WFC 走 C++（进度写 C++ 静态量，主线程读）；其他算法直接生成
static func _async_grid_work(def: GridGenDef, seed: int) -> GeneratedGrid:
	if def.type == GridGenDef.Type.WFC:
		return generate_grid_wfc_cpp(def, make_rng(seed))
	return generate_grid(def, make_rng(seed))

## WFC 走 C++ 并回报进度（供 generate_grid_async_progress 使用）
static func generate_grid_wfc_cpp(def: GridGenDef, rng: RandomNumberGenerator, progress: Dictionary = {}) -> GeneratedGrid:
	var grid := GeneratedGrid.create(def.width, def.height, def.empty_value)
	_gen_wfc(grid, def, rng, {}, progress)
	return grid

## 后台线程生成 3D 栅格（大体积不卡主线程）
static func generate_grid_3d_async(def: Grid3DGenDef, seed: int) -> GeneratedGrid3D:
	if def.type == Grid3DGenDef.Type.WFC_3D:
		FrameworkNative.get_native(&"PCGWFC3D", [&"generate"])  # 预热(主线程)
	var grid: GeneratedGrid3D = await AsyncTool.thread_call(func() -> GeneratedGrid3D:
		return generate_grid_3d(def, make_rng(seed))
	)
	return grid

## 后台线程生成 3D 栅格 + 实时进度回调（大 3D WFC 不卡帧，UI 可显示进度）
## on_progress: func(p: float)，主线程每帧回调 0..1
## 3D WFC 进度由 C++ 静态量(PCGWFC3D.get_last_progress)记录, 主线程每帧轮询
static func generate_grid_3d_async_progress(def: Grid3DGenDef, seed: int, on_progress: Callable = func(_p: float): pass) -> GeneratedGrid3D:
	var native: Object = null
	if def.type == Grid3DGenDef.Type.WFC_3D:
		native = FrameworkNative.get_native(&"PCGWFC3D", [&"generate", &"get_last_progress"])  # 预热(主线程)
	var data := {}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = _async_grid3d_work(def, seed)
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		if native != null:
			on_progress.call(native.call(&"get_last_progress"))
		await Engine.get_main_loop().process_frame
	on_progress.call(1.0)
	return data.get("result") as GeneratedGrid3D


## async 3D 工作函数：3D WFC 走 C++（进度写 C++ 静态量）；其他算法直接生成
static func _async_grid3d_work(def: Grid3DGenDef, seed: int) -> GeneratedGrid3D:
	return generate_grid_3d(def, make_rng(seed))

## 把栅格渲染成图（palette: 格值 → 颜色）
static func grid_to_image(grid: GeneratedGrid, palette: Dictionary = {}) -> Image:
	var img := Image.create(grid.width, grid.height, false, Image.FORMAT_RGB8)
	for i in grid.cells.size():
		img.set_pixel(i % grid.width, i / grid.width, palette.get(grid.cells[i], Color.BLACK))
	return img

## —— 高度图 ——

## 生成连续高度场（多层噪声叠加 + 岛屿掩膜 + 高度映射）
## 各层用独立派生种子保证互不干扰且可复现；0..1 连续高度输出
## 流程：原始混合值 → 岛屿掩膜 → 整体 min-max 归一化 → 曲线（保证岛屿中心必达 max_height）
static func generate_heightmap(def: HeightMapDef, rng: RandomNumberGenerator) -> HeightMap:
	var seed := rng.seed + def.seed_offset
	var hm := HeightMap.create(def.width, def.height)
	var base_n: FastNoiseLite = def.base_layer.build_noise(seed + 101) if def.base_layer else null
	var detail_n: FastNoiseLite = def.detail_layer.build_noise(seed + 202) if def.detail_layer else null
	var ridge_n: FastNoiseLite = def.ridge_layer.build_noise(seed + 303) if def.ridge_layer else null
	# 第一遍：算原始混合值（含掩膜），记录范围用于归一化
	var raw := PackedFloat32Array()
	raw.resize(def.width * def.height)
	var lo := INF
	var hi := -INF
	for y in def.height:
		for x in def.width:
			var h := 0.0
			var total_w := 0.0
			if base_n:
				h += def.base_layer.sample(base_n, x, y) * def.base_weight
				total_w += def.base_weight
			if detail_n:
				h += def.detail_layer.sample(detail_n, x, y) * def.detail_weight
				total_w += def.detail_weight
			if ridge_n:
				h += def.ridge_layer.sample(ridge_n, x, y) * def.ridge_weight
				total_w += def.ridge_weight
			if total_w > 0.0:
				h /= total_w
			else:
				h = 0.5
			# 岛屿掩膜：按强度向"边缘沉海"混合（0=无掩膜, 1=全强度）
			if def.island_strength > 0.0:
				h *= lerpf(1.0, _island_falloff(x, y, def), clampf(def.island_strength, 0.0, 1.0))
			raw[y * def.width + x] = h
			lo = minf(lo, h)
			hi = maxf(hi, h)
	# 第二遍：归一化 + 曲线 + 范围映射
	var span := maxf(0.0001, hi - lo)
	for i in raw.size():
		var h := (raw[i] - lo) / span
		h = pow(h, def.height_curve)
		h = def.min_height + h * (def.max_height - def.min_height)
		hm.heights[i] = clampf(h, 0.0, 1.0)
	# 水力侵蚀（粒子模拟，可选）— 纯 C++ 实现（框架强依赖 PCGErode，无 GDScript 回退）
	if def.erosion_droplets > 0:
		var native := FrameworkNative.get_native(&"PCGErode", [&"erode"])
		if native == null:
			push_error("PCGTool.generate_heightmap: 原生库 PCGErode 不可用! 请确认 Native/devecs.gdextension 已加载。")
		else:
			var out: PackedFloat32Array = native.call(&"erode",
				hm.heights, hm.width, hm.height,
				def.erosion_droplets, def.erosion_inertia, def.erosion_power,
				def.erosion_radius, def.erosion_min_slope, def.erosion_evaporate,
				rng.seed + def.seed_offset + 404,
				def.erosion_cliff_drop, def.erosion_deposition_rate)
			if out.size() == hm.heights.size():
				hm.heights = out
	# 热侵蚀（平滑坡面）— 纯 C++ 实现
	if def.thermal_iterations > 0:
		var native := FrameworkNative.get_native(&"PCGErode", [&"thermal"])
		if native == null:
			push_error("PCGTool.generate_heightmap: 原生库 PCGErode 不可用! 请确认 Native/devecs.gdextension 已加载。")
		else:
			var out: PackedFloat32Array = native.call(&"thermal",
				hm.heights, hm.width, hm.height,
				def.thermal_iterations, def.thermal_talus)
			if out.size() == hm.heights.size():
				hm.heights = out
	return hm


## 岛屿掩膜：边缘 0（海），中心 1；shape=1 方形内缩，2 圆形
static func _island_falloff(x: int, y: int, def: HeightMapDef) -> float:
	var cx := (x + 0.5) / def.width
	var cy := (y + 0.5) / def.height
	if def.island_shape == 2:
		var dx := (cx - 0.5) * 2.0
		var dy := (cy - 0.5) * 2.0
		var d := sqrt(dx * dx + dy * dy)
		return clampf(1.0 - d * 1.4, 0.0, 1.0)
	var edge := maxf(absf(cx - 0.5) * 2.0, absf(cy - 0.5) * 2.0)
	return clampf(1.0 - edge * 1.3, 0.0, 1.0)


## 高度图渲染成灰度图（黑=海，白=峰）
static func heightmap_to_image(hm: HeightMap) -> Image:
	var img := Image.create(hm.width, hm.height, false, Image.FORMAT_RGB8)
	for i in hm.heights.size():
		var v := hm.heights[i]
		img.set_pixel(i % hm.width, i / hm.width, Color(v, v, v))
	return img


## 高度图 → 2D 栅格（阈值分割：>= sea_level 为陆地 solid_value）
static func heightmap_to_grid(hm: HeightMap, sea_level := 0.5, solid_value := 1, empty_value := 0) -> GeneratedGrid:
	var grid := GeneratedGrid.create(hm.width, hm.height, empty_value)
	for i in hm.heights.size():
		grid.cells[i] = solid_value if hm.heights[i] >= sea_level else empty_value
	return grid


## 高度图 → 3D 体素（Minecraft 式：每列填到 floor(height * height_scale) 高度）
## 传入预分配的目标栅格（宽高对齐），填充实体；返回该栅格（便于复用已有 def 生成的地基）
static func heightmap_to_grid3d(hm: HeightMap, target: GeneratedGrid3D, solid_value := 1, height_scale := 1.0) -> GeneratedGrid3D:
	if target == null:
		return null
	for y in target.height:
		for z in target.depth:
			for x in target.width:
				var h_val := hm.get_height(x, z, 0.0)
				var fill_h := int(floorf(h_val * height_scale))
				target.set_cell(x, y, z, solid_value if y <= fill_h else 0)
	return target

## —— 程序化纹理 ——

## 生成程序化纹理（可复现），支持噪声/云/木纹/砖墙/水面
static func generate_texture(def: TextureGenDef, rng: RandomNumberGenerator) -> Image:
	var seed := rng.seed + def.seed_offset
	var img := Image.create(def.width, def.height, false, Image.FORMAT_RGB8)
	var noise: FastNoiseLite = def.noise_layer.build_noise(seed) if def.noise_layer else null
	# 次级噪声（砖墙扰动 / 水面波纹用）
	var detail: FastNoiseLite = null
	if def.type == TextureGenDef.Type.BRICK or def.type == TextureGenDef.Type.WATER:
		detail = FastNoiseLite.new()
		detail.seed = seed + 7
		detail.noise_type = FastNoiseLite.TYPE_PERLIN
		detail.frequency = 0.06
		detail.fractal_octaves = 3
	var grad := def.gradient if def.gradient else _default_gradient(def)
	for y in def.height:
		for x in def.width:
			var v := 0.0
			var c: Color
			match def.type:
				TextureGenDef.Type.NOISE:
					v = noise.get_noise_2d(x, y) * 0.5 + 0.5 if noise else 0.5
					c = grad.sample(clampf(v, 0.0, 1.0))
				TextureGenDef.Type.CLOUDS:
					v = noise.get_noise_2d(x, y) * 0.5 + 0.5 if noise else 0.5
					var cloud := clampf((v - def.threshold) / maxf(0.01, 1.0 - def.threshold), 0.0, 1.0)
					c = grad.sample(cloud)
				TextureGenDef.Type.WOOD:
					# 环形噪声：沿离中心距离 + 噪声扰动做条纹
					var nx := x - def.width * 0.5
					var ny := y - def.height * 0.5
					var wobble := noise.get_noise_2d(x * 0.5, y * 0.5) * 6.0 if noise else 0.0
					var r := sqrt(nx * nx + ny * ny) + wobble
					v = 0.5 + 0.5 * sin(r * def.ring_density)
					c = grad.sample(clampf(v, 0.0, 1.0))
				TextureGenDef.Type.BRICK:
					# 砖块网格：行偏移 + 噪声扰动 + 灰浆缝
					var wob := detail.get_noise_2d(x, y) * 2.0 if detail else 0.0
					var row := int(floorf((y + wob) / def.brick_height))
					var row_off := def.brick_width / 2.0 if row % 2 == 1 else 0.0
					var bx := fmod(x + row_off + wob, def.brick_width)
					var by := fmod(y + wob, def.brick_height)
					var in_mortar := bx < def.mortar_thickness or by < def.mortar_thickness
					c = grad.sample(0.0) if in_mortar else grad.sample(0.75 + 0.25 * (noise.get_noise_2d(x, y) * 0.5 + 0.5) if noise else 0.75)
				TextureGenDef.Type.WATER:
					# 低频大波 + 高频波纹
					var base_wave := noise.get_noise_2d(x, y) * 0.5 + 0.5 if noise else 0.5
					var ripple := detail.get_noise_2d(x * 3.0, y * 3.0) * 0.5 + 0.5 if detail else 0.5
					v = clampf(base_wave * (1.0 - def.ripple_strength) + ripple * def.ripple_strength, 0.0, 1.0)
					c = grad.sample(v)
			c = Color(
				clampf(pow(c.r, 1.0 / def.contrast), 0.0, 1.0),
				clampf(pow(c.g, 1.0 / def.contrast), 0.0, 1.0),
				clampf(pow(c.b, 1.0 / def.contrast), 0.0, 1.0))
			img.set_pixel(x, y, c)
	return img


## 未配置色带时的默认渐变（按纹理类型给合理配色）
static func _default_gradient(def: TextureGenDef) -> Gradient:
	var g := Gradient.new()
	match def.type:
		TextureGenDef.Type.CLOUDS:
			g.colors = PackedColorArray([Color(0.55, 0.6, 0.68), Color(0.95, 0.96, 0.98)])
		TextureGenDef.Type.WOOD:
			g.colors = PackedColorArray([Color(0.25, 0.15, 0.08), Color(0.6, 0.4, 0.2)])
		TextureGenDef.Type.BRICK:
			g.colors = PackedColorArray([Color(0.45, 0.42, 0.4), Color(0.7, 0.3, 0.22)])
		TextureGenDef.Type.WATER:
			g.colors = PackedColorArray([Color(0.1, 0.3, 0.55), Color(0.3, 0.6, 0.85)])
		_:
			g.colors = PackedColorArray([Color(0.1, 0.1, 0.1), Color(0.9, 0.9, 0.9)])
	g.offsets = PackedFloat32Array([0.0, 1.0])
	return g

## —— L-System 生长 ——

## 生成 L-System 线段集（每对相邻点 = 一条线段）
## turtle 语义：F=前进(可画线)、G=前进(不画线)、+/-(转向)、[入栈 ]出栈
static func generate_lsystem(def: LSystemDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	# 纯 C++ 实现（框架强依赖共享原生库 PCGLSystem，无 GDScript 回退）
	var native := FrameworkNative.get_native(&"PCGLSystem", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_lsystem: 原生库 PCGLSystem 不可用! 请确认 Native/devecs.gdextension 已加载。")
		return PackedVector2Array()
	return native.call(&"generate",
		def.axiom, def.rules, def.iterations,
		def.angle_deg, def.step_length, def.angle_jitter, def.draw_on_f,
		def.start_angle, def.origin, def.max_segments, rng.seed)


## 把线段集渲染成图（用于预览）
static func lsystem_to_image(segments: PackedVector2Array, image_size := Vector2i(256, 256), color := Color.WHITE, bg := Color(0.1, 0.12, 0.14)) -> Image:
	var img := Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGB8)
	img.fill(bg)
	if segments.is_empty():
		return img
	# 计算包围盒自动适配画布
	var min_p := segments[0]
	var max_p := segments[0]
	for i in segments.size():
		if i % 2 == 0:
			min_p = min_p.min(segments[i])
			max_p = max_p.max(segments[i])
	var span := max_p - min_p
	if span.length() < 0.001:
		return img
	var scale := minf((image_size.x - 16.0) / maxf(span.x, 0.001), (image_size.y - 16.0) / maxf(span.y, 0.001))
	var offset := Vector2(8, 8) - min_p * scale
	for i in range(0, segments.size(), 2):
		var a := segments[i] * scale + offset
		var b := segments[i + 1] * scale + offset
		_draw_line(img, a, b, color)
	return img


## 简单 Bresenham 画线（Image 无内建 draw_line）
static func _draw_line(img: Image, a: Vector2, b: Vector2, color: Color) -> void:
	var x0 := int(round(a.x))
	var y0 := int(round(a.y))
	var x1 := int(round(b.x))
	var y1 := int(round(b.y))
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		if x0 >= 0 and x0 < img.get_width() and y0 >= 0 and y0 < img.get_height():
			img.set_pixel(x0, y0, color)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy

## —— 生物群系 ——

## 采样多层噪声生成生物群系图（每个格子 = biomes 索引）
static func generate_biome(def: BiomeMapDef, rng: RandomNumberGenerator) -> BiomeMap:
	var result := BiomeMap.new()
	result.width = def.width
	result.height = def.height
	result.biomes = def.biomes
	result.indices.resize(def.width * def.height)
	var elev: FastNoiseLite = def.elevation_layer.build_noise(rng.seed) if def.elevation_layer else null
	var moist: FastNoiseLite = def.moisture_layer.build_noise(rng.seed) if def.moisture_layer else null
	var temp: FastNoiseLite = def.temperature_layer.build_noise(rng.seed) if def.temperature_layer else null
	for y in def.height:
		for x in def.width:
			var h := def.elevation_layer.sample(elev, x, y) if elev else 0.5
			var m := def.moisture_layer.sample(moist, x, y) if moist else 0.5
			var t := def.temperature_layer.sample(temp, x, y) if temp else 0.5
			result.indices[y * def.width + x] = _biome_pick(def.biomes, h, m, t)
	if def.smoothing_passes > 0:
		_smooth_biome(result, def)
	return result

## 群系过渡平滑：每格取 3x3 邻域中出现最多的群系（含自身），边界趋于柔和
static func _smooth_biome(bm: BiomeMap, def: BiomeMapDef) -> void:
	for _p in def.smoothing_passes:
		var next := bm.indices.duplicate()
		for y in bm.height:
			for x in bm.width:
				var counts := {}
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx := x + dx
						var ny := y + dy
						if not bm.in_bounds(nx, ny):
							continue
						var idx := bm.indices[ny * bm.width + nx]
						counts[idx] = counts.get(idx, 0) + 1
				var best_idx := bm.indices[y * bm.width + x]
				var best_n := -1
				for idx in counts:
					if counts[idx] > best_n:
						best_n = counts[idx]
						best_idx = idx
				next[y * bm.width + x] = best_idx
		bm.indices = next

## 按群系颜色渲染成图
static func biome_to_image(biome_map: BiomeMap) -> Image:
	var img := Image.create(biome_map.width, biome_map.height, false, Image.FORMAT_RGB8)
	for i in biome_map.indices.size():
		var idx := biome_map.indices[i]
		var c := biome_map.biomes[idx].color if idx >= 0 and idx < biome_map.biomes.size() else Color.BLACK
		img.set_pixel(i % biome_map.width, i / biome_map.width, c)
	return img

## 按 高度/湿度/温度 选群系（顺序优先，兜底返回最后一个）
static func _biome_pick(biomes: Array[BiomeEntryDef], h: float, m: float, t: float) -> int:
	for i in biomes.size():
		if biomes[i] and biomes[i].matches(h, m, t):
			return i
	return biomes.size() - 1

## —— 散布 ——

static func place(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	match def.mode:
		PlacementDef.Mode.POISSON_DISK:
			return _place_poisson(def, rng)
		PlacementDef.Mode.JITTER_GRID:
			return _place_jitter_grid(def, rng)
		PlacementDef.Mode.RANDOM_UNIFORM:
			return _place_random(def, rng)
	return PackedVector2Array()

## 把点集渲染成图（用于预览）
static func points_to_image(points: PackedVector2Array, image_size: Vector2i, color := Color.WHITE, bg := Color(0.1, 0.12, 0.14), point_radius := 1) -> Image:
	var img := Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGB8)
	img.fill(bg)
	for p in points:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-point_radius, point_radius + 1):
			for dx in range(-point_radius, point_radius + 1):
				var x := px + dx
				var y := py + dy
				if x >= 0 and y >= 0 and x < image_size.x and y < image_size.y:
					img.set_pixel(x, y, color)
	return img

## —— 3D 散布 ——

static func place_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	match def.mode:
		PlacementDef3D.Mode.POISSON_3D:
			return _place_poisson_3d(def, rng)
		PlacementDef3D.Mode.JITTER_GRID_3D:
			return _place_jitter_grid_3d(def, rng)
		PlacementDef3D.Mode.RANDOM_3D:
			return _place_random_3d(def, rng)
	return PackedVector3Array()

## 3D 泊松圆盘（Bridson 3D）
static func _place_poisson_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var r := maxf(def.min_distance, 0.001)
	var cell := r / sqrt(3.0)
	var gw := ceili(def.region_size.x / cell)
	var gh := ceili(def.region_size.y / cell)
	var gd := ceili(def.region_size.z / cell)
	var occupancy := {}
	var result := PackedVector3Array()
	var active := PackedVector3Array()
	var start := Vector3(
		rng.randf_range(0.0, def.region_size.x),
		rng.randf_range(0.0, def.region_size.y),
		rng.randf_range(0.0, def.region_size.z))
	result.append(start)
	active.append(start)
	occupancy[_cell_key(start, cell)] = start
	while not active.is_empty() and result.size() < def.count:
		var idx := rng.randi_range(0, active.size() - 1)
		var center: Vector3 = active[idx]
		var placed := false
		for i in def.max_attempts:
			var dir := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0).normalized()
			var cand := center + dir * rng.randf_range(r, r * 2.0)
			if cand.x < 0.0 or cand.y < 0.0 or cand.z < 0.0 or cand.x >= def.region_size.x or cand.y >= def.region_size.y or cand.z >= def.region_size.z:
				continue
			if not _poisson_ok_3d(occupancy, gw, gh, gd, _cell_key(cand, cell), cell, r, cand):
				continue
			result.append(cand)
			active.append(cand)
			occupancy[_cell_key(cand, cell)] = cand
			placed = true
			break
		if not placed:
			active.remove_at(idx)
	return result

static func _cell_key(p: Vector3, cell: float) -> Vector3i:
	return Vector3i(int(p.x / cell), int(p.y / cell), int(p.z / cell))

static func _poisson_ok_3d(occupancy: Dictionary, gw: int, gh: int, gd: int, gi: Vector3i, cell: float, r: float, cand: Vector3) -> bool:
	for dz in range(-2, 3):
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var gx := gi.x + dx
				var gy := gi.y + dy
				var gz := gi.z + dz
				if gx < 0 or gy < 0 or gz < 0 or gx >= gw or gy >= gh or gz >= gd:
					continue
				var other: Variant = occupancy.get(Vector3i(gx, gy, gz))
				if other != null and (other as Vector3).distance_to(cand) < r:
					return false
	return true

## 3D 抖动网格
static func _place_jitter_grid_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var n := ceili(pow(float(def.count), 1.0 / 3.0))
	var out := PackedVector3Array()
	for i in n:
		for j in n:
			for k in n:
				if out.size() >= def.count:
					break
				var base := Vector3(
					def.region_size.x * (i + 0.5) / n,
					def.region_size.y * (j + 0.5) / n,
					def.region_size.z * (k + 0.5) / n)
				var jx := (rng.randf() - 0.5) * (def.region_size.x / n) * def.jitter
				var jy := (rng.randf() - 0.5) * (def.region_size.y / n) * def.jitter
				var jz := (rng.randf() - 0.5) * (def.region_size.z / n) * def.jitter
				out.append(base + Vector3(jx, jy, jz))
	return out

## 3D 均匀随机
static func _place_random_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in def.count:
		out.append(Vector3(
			rng.randf() * def.region_size.x,
			rng.randf() * def.region_size.y,
			rng.randf() * def.region_size.z))
	return out

## —— 城镇（S1 选址 / S2 道路网 / S3 街区 / S4 地块细分） ——
## 城市生成统一走 TownDef 管线（旧 CityDef 均匀网格模式已按设计案移除）

## S2 张量场路网（TensorRoadStep；与 town_roads_step 二选一插拔）：
## 预计算全图主/次方向场 → 旋转格网播种 → 双向 RK2 流线追踪 → 空间哈希吸附接入 → 印刷
static func town_tensor_road_step(step: TensorRoadStep, ctx: TownGenContext) -> void:
	# TownDef 总控参数反向注入步骤实例（与其它步骤的 tres 配置生效方式一致）
	var def := ctx.def
	step.grid_angle = float(def.get("tensor_grid_angle"))
	step.radial_strength = float(def.get("tensor_radial_strength"))
	var rc = def.get("tensor_radial_center")
	if rc != null:
		step.radial_center = rc
	# 径向中心未配置(负值=关闭)时自动跟随选址点: 环形+放射大街以城镇为中心
	if step.radial_strength > 0.0 and step.radial_center.x < 0.0 and ctx.layout.site.x >= 0:
		step.radial_center = Vector2(ctx.layout.site)
	step.noise_strength = float(def.get("tensor_noise_strength"))
	step.contour_strength = float(def.get("tensor_contour_strength"))
	step.major_spacing = int(def.get("tensor_major_spacing"))
	step.minor_spacing = int(def.get("tensor_minor_spacing"))
	step.max_step_rise = float(def.get("tensor_max_step_rise"))
	step.town_radius = int(def.get("tensor_town_radius"))
	step.straight_run = float(def.get("tensor_straight_run"))
	# 城区圆心: 半径生效时优先选址点(未配置径向中心时的自动跟随同源), 否则图心
	if step.town_radius > 0:
		step.center = Vector2(ctx.layout.site) if ctx.layout.site.x >= 0 else Vector2(def.width, def.height) * 0.5
	else:
		step.center = Vector2(-1, -1)
	_tensor_roads(step, def, ctx.heightmap, ctx.layout, ctx.next_rng())


static func _tensor_roads(step: TensorRoadStep, def: TownDef, hm: HeightMap, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var roads := layout.roads_grid
	var w := def.width
	var h := def.height
	var c := deg_to_rad(step.grid_angle)
	# —— 1. 预计算方向场：对称 2x2 张量叠加(网格/径向/等高线/噪声) + 特征分解 ——
	var ang := PackedFloat32Array()
	ang.resize(w * h)
	var ang_min := PackedFloat32Array()
	ang_min.resize(w * h)
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = step.noise_scale
	for y in h:
		for x in w:
			var p := Vector2(x, y)
			var a := 0.0
			var b := 0.0
			var cc := 0.0
			if step.grid_strength > 0.0:
				var e := Vector2.from_angle(c)
				a += step.grid_strength * e.x * e.x
				b += step.grid_strength * e.x * e.y
				cc += step.grid_strength * e.y * e.y
			if step.radial_strength > 0.0 and step.radial_center.x >= 0.0:
				var rd := p - step.radial_center
				var rl := rd.length()
				if rl > 0.001:
					var u := rd / rl
					var rw := step.radial_strength * exp(-pow(rl / step.radial_radius, 2.0))
					a += rw * u.x * u.x
					b += rw * u.x * u.y
					cc += rw * u.y * u.y
			if step.contour_strength > 0.0 and hm != null:
				var g := Vector2(hm.sample(x + 1, y) - hm.sample(x - 1, y), hm.sample(x, y + 1) - hm.sample(x, y - 1))
				if g.length() > 0.0001:
					var v := g.normalized().orthogonal()  # 沿等高线
					var cw := step.contour_strength * clampf(g.length() * 20.0, 0.0, 1.0)  # 平地自动失效
					a += cw * v.x * v.x
					b += cw * v.x * v.y
					cc += cw * v.y * v.y
			if step.noise_strength > 0.0:
				var e2 := Vector2.from_angle(c + noise.get_noise_2d(x, y) * step.noise_strength * PI)
				a += step.noise_strength * e2.x * e2.x
				b += step.noise_strength * e2.x * e2.y
				cc += step.noise_strength * e2.y * e2.y
			var i := y * w + x
			if a == 0.0 and cc == 0.0 and b == 0.0:
				ang[i] = c
				ang_min[i] = c + PI * 0.5
				continue
			# 特征分解: λ± = (a+cc)/2 ± sqrt(((a-cc)/2)² + b²); 主特征向量 (λ1-cc, b)
			var l1 := (a + cc) * 0.5 + sqrt(maxf(0.0, pow((a - cc) * 0.5, 2.0) + b * b))
			var v1: Vector2
			if absf(b) > 0.0001:
				v1 = Vector2(l1 - cc, b).normalized()
			else:
				v1 = Vector2.RIGHT if a >= cc else Vector2.DOWN
			ang[i] = v1.angle()
			ang_min[i] = v1.orthogonal().angle()
	# —— 2. 流线追踪：主方向(干道) + 次方向(次街)，旋转格网播种 ——
	var occupied := {}
	for y in h:
		for x in w:
			if roads.get_cell(x, y, -1) != 0:
				occupied[Vector2i(x, y)] = true
	for pass_i in 2:
		var is_major := pass_i == 0
		var spacing := step.major_spacing if is_major else step.minor_spacing
		var base_ang := c if is_major else c + PI * 0.5
		var fwd := Vector2.from_angle(base_ang)
		var nrm := fwd.orthogonal()
		var diag := float(w + h)
		var k := -diag * 0.5
		while k <= diag * 0.5:
			k += spacing
			var jitter := rng.randf_range(-spacing * 0.15, spacing * 0.15)
			var start := Vector2(w, h) * 0.5 + nrm * (k + jitter) - fwd * diag * 0.5
			# 双向追踪拼接
			var fwd_pts := _tensor_trace(ang, ang_min, is_major, w, h, start, fwd, step, occupied, hm)
			var back_pts := _tensor_trace(ang, ang_min, is_major, w, h, start, -fwd, step, occupied, hm)
			back_pts.reverse()
			var line := back_pts
			# 播种点可在图外(旋转格网播种): 图外不加入折线, 防止图外坐标混入 road_nodes
			if start.x >= 0.0 and start.y >= 0.0 and start.x < float(w) and start.y < float(h):
				line.append(start)
			line.append_array(fwd_pts)
			if line.size() < maxi(2, step.min_len):
				continue
			# 全线在水下则丢弃
			if hm != null:
				var wet := 0
				for q in line:
					if hm.sample(q.x, q.y) < def.sea_level:
						wet += 1
				if wet >= line.size() - 1:
					continue
			var value := def.road_arterial_value if is_major else def.road_sec_value
			var width := def.arterial_width if is_major else 1
			_stamp_road_layer(roads, line, width, value, hm, def.sea_level, def.bridge_value)
			for q in line:
				occupied[Vector2i(int(q.x), int(q.y))] = true
			if is_major and line.size() >= 4:
				# 干道入图(节点=每 3 格降采样 + 首尾; 边=相邻节点, 供车流/标线/导航)
				var base_idx := layout.road_nodes.size()
				for qi in range(0, line.size(), 3):
					layout.road_nodes.append(line[qi])
				if (line.size() - 1) % 3 != 0:
					layout.road_nodes.append(line[line.size() - 1])
				var cnt := layout.road_nodes.size() - base_idx
				for ei in cnt - 1:
					layout.road_edges.append({
						"a": base_idx + ei, "b": base_idx + ei + 1,
						"width": def.arterial_width, "cls": TownLayout.EdgeClass.ARTERIAL,
					})


## 沿方向场追踪一条流线（直行锁定+轴对齐为主/少量45°+垂直穿越成十字路口），
## 出界/超长/坡度超限/平行接入既有路即停
static func _tensor_trace(ang: PackedFloat32Array, ang_min: PackedFloat32Array, is_major: bool, w: int, h: int,
		start: Vector2, dir0: Vector2, step: TensorRoadStep, occupied: Dictionary, hm: HeightMap) -> PackedVector2Array:
	var field := ang if is_major else ang_min
	var pts := PackedVector2Array()
	var p := start
	var prev_d := dir0
	var steps_n := int(step.max_len / step.step_len)
	var snap_r := int(ceilf(step.snap_dist))
	# 直行锁定: 锁定期内保持原方向, 到点才按方向场重新定向(轴对齐为主/少量45°) → 长直段+离散转向
	var recheck := maxi(1, int(roundf(step.straight_run / step.step_len)))
	var run := recheck  # 首步立即定向
	var grace := 0  # 垂直穿越既有路后的宽容步数(期间关闭吸附, 让本线穿过路口)
	var active := false  # 播种点可在界外/城区圆外(旋转格网播种), 需先滑行到有效区
	for i in steps_n:
		var cell := Vector2i(int(floorf(p.x)), int(floorf(p.y)))
		var in_map := cell.x >= 1 and cell.y >= 1 and cell.x < w - 1 and cell.y < h - 1
		var in_town := step.town_radius <= 0 or step.center.x < 0.0 \
				or p.distance_to(step.center) <= float(step.town_radius)
		if not (in_map and in_town):
			if active:
				break  # 已入图/入圈后再离开 → 截断(城区半径收拢路网, 不蔓延图缘)
			p += prev_d * step.step_len  # 滑行: 沿初始方向前进直到同时入图且入圈
			continue
		active = true
		# 吸附: 跳过起点近旁, 靠近既有路即接入; 垂直相交则穿过形成十字路口
		if grace > 0:
			grace -= 1  # 穿越既有路带宽, 期间关闭吸附
		elif i > int(3.0 / step.step_len):
			var hit_cell := Vector2i(-999, -999)
			for dy in range(-snap_r, snap_r + 1):
				for dx in range(-snap_r, snap_r + 1):
					if occupied.has(cell + Vector2i(dx, dy)):
						hit_cell = cell + Vector2i(dx, dy)
						break
			if hit_cell.x != -999:
				pts.append(p)
				# 估计既有路走向: 本线与其垂直 → 穿过成十字路口; 平行/斜交 → 接入截止
				var along_x := occupied.has(hit_cell + Vector2i(1, 0)) or occupied.has(hit_cell + Vector2i(-1, 0))
				var along_y := occupied.has(hit_cell + Vector2i(0, 1)) or occupied.has(hit_cell + Vector2i(0, -1))
				var cross_perp := (along_x and absf(prev_d.y) > 0.9) or (along_y and absf(prev_d.x) > 0.9)
				if cross_perp:
					grace = snap_r + 4
				else:
					break
		if run >= recheck:
			var d := Vector2.from_angle(field[cell.y * w + cell.x])
			if d.dot(prev_d) < 0.0:
				d = -d
			# 方向量化: 大部分吸附到网格轴(横平竖直); 仅当方向场明确指向斜向(距45°轴<15°)才走45°
			var a := d.angle()
			var k45 := roundf(a / (PI * 0.25))
			if int(absf(k45)) % 2 == 1 and absf(a - k45 * PI * 0.25) > deg_to_rad(15.0):
				k45 = roundf(a / (PI * 0.5)) * 2.0
			prev_d = Vector2.from_angle(k45 * PI * 0.25)
			run = 0
		run += 1
		var np := p + prev_d * step.step_len
		if hm != null and step.max_step_rise > 0.0:
			if absf(hm.sample(np.x, np.y) - hm.sample(p.x, p.y)) > step.max_step_rise:
				break
		pts.append(np)
		p = np
	return pts


## 生成小城镇（同 Def + 同 seed 必复现）。hm 可为 null（平地城镇）。
## def 参数容器值反向注入步骤实例（tres 配置生效），然后统一走 step.apply 执行。
static func generate_town(def: TownDef, hm: HeightMap, seed_base: int) -> TownLayout:
	var gctx := TownGenContext.new(def, hm, seed_base)
	gctx.layout.heightmap = hm
	if def.name_gen != null:
		gctx.layout.town_name = generate_name(
			def.name_gen, make_rng(derive_seed(seed_base, 10)))
	var steps_arr := def.effective_steps()
	_sync_def_to_steps(def, steps_arr)
	for s in steps_arr:
		if s == null or not s.enabled:
			continue
		s.apply(gctx)
	return gctx.layout


## 后台线程生成城镇（大城镇不卡主线程；TownLayout/TownDef 均纯数据，线程安全）
static func generate_town_async(def: TownDef, hm: HeightMap, seed_base: int) -> TownLayout:
	return await AsyncTool.thread_call(func() -> TownLayout:
		return generate_town(def, hm, seed_base)
	)


## 反向同步：def 参数容器 → 同类型 step 实例（使 tres 配置在默认链下生效）
static func _sync_def_to_steps(def: TownDef, steps_arr: Array[TownStepDef]) -> void:
	for s in steps_arr:
		if s is TownSiteStep:
			s.site_candidates = def.site_candidates
			s.site_radius = def.site_radius
			s.water_band_min = def.water_band_min
			s.water_band_max = def.water_band_max
		elif s is TownRoadStep:
			s.main_width = def.main_width
			s.street_spacing_min = def.street_spacing_min
			s.street_spacing_max = def.street_spacing_max
			s.secondary_max_len = def.secondary_max_len
			s.slope_cost_k = def.slope_cost_k
			s.street_wander = def.street_wander
			s.main_jitter = def.main_jitter
			s.bridge_allowed = def.bridge_allowed
			s.bridge_cost = def.bridge_cost
			s.set("road_min_segment", def.road_min_segment)
			s.set("street_min_run", def.street_min_run)
		elif s is TownPlazaStep:
			s.plaza_radius = def.plaza_radius
			s.plaza_feature = def.plaza_feature
		elif s is TownParcelStep:
			s.max_block_area = def.max_block_area
			s.min_block_area = def.min_block_area
			s.lot_max_area = def.lot_max_area
			s.lot_min_area = def.lot_min_area
			s.set("lot_min_edge", def.get("lot_min_edge"))
		elif s is TownBuildingStep:
			if def.houses.size() > 0:
				s.houses = def.houses
			if def.facilities.size() > 0:
				s.facilities = def.facilities
			s.house_fill_ratio = def.house_fill_ratio
			s.house_layers_min = def.house_layers_min
			s.house_layers_max = def.house_layers_max
			s.house_roof = def.house_roof
			if def.flat_roof_styles.size() > 0:
				s.flat_roof_styles = def.flat_roof_styles
			if def.style_table.size() > 0:
				s.style_table = def.style_table
			s.build_max_step = def.build_max_step
		elif s is TownInteriorStep:
			if def.furniture_tables.size() > 0:
				s.furniture_tables = def.furniture_tables
			if def.prop_table.size() > 0:
				s.prop_table = def.prop_table
			s.props_per_building = def.props_per_building
		elif s is TownGreeneryStep:
			s.tree_count = def.tree_count
			s.tree_min_distance = def.tree_min_distance
			s.street_tree_spacing = def.street_tree_spacing
		elif s is TownStreetStep:
			s.streetlamp_spacing = def.streetlamp_spacing
			s.set("bin_spacing", def.get("bin_spacing"))
			s.set("bus_stop_spacing", def.get("bus_stop_spacing"))
		elif s is TownFarmStep:
			s.farm_min_dist = def.farm_min_dist
			s.farm_min_area = def.farm_min_area
		elif s is TownConformStep:
			s.road_max_grade = def.road_max_grade
			s.terrace_blend = def.terrace_blend
		elif s is TownWallStep:
			# 防御式读取: 旧版 tres 缓存的 TownDef 可能缺新字段(nil), 缺省跳过
			var eg = def.get("extra_gates")
			if eg != null:
				s.extra_gates = int(eg)




static func town_ring_step(_step: TownRingStep, ctx: TownGenContext) -> void:
	_town_ring_road(ctx.def, ctx.heightmap, ctx.layout)
	# 防御式读取(旧缓存 tres 缺新字段时视为关闭)
	var passes := 0
	if "infill_passes" in ctx.def:
		passes = int(ctx.def.infill_passes)
	if passes > 0:
		_town_balance_infill(ctx.def, ctx.heightmap, ctx.layout, ctx.next_rng())
	_prune_dead_ends(ctx.def, ctx.layout)
	_ensure_bridges(ctx.def, ctx.layout)


static func town_ward_step(_step: TownWardStep, ctx: TownGenContext) -> void:
	if not bool(ctx.def.get("enable_wards")):
		return
	_town_wards(ctx.def, ctx.layout, ctx.heightmap)


static func town_wall_step(step: TownWallStep, ctx: TownGenContext) -> void:
	if not bool(ctx.def.get("enable_walls")):
		return
	ctx.def.set("extra_gates", step.extra_gates)
	_town_walls(ctx.def, ctx.layout, ctx.next_rng())


static func town_alley_step(_step: TownAlleyStep, ctx: TownGenContext) -> void:
	_town_alley_split(ctx.def, ctx.heightmap, ctx.layout, ctx.next_rng())


static func town_plaza_step(step: TownPlazaStep, ctx: TownGenContext) -> void:
	ctx.def.plaza_radius = step.plaza_radius
	ctx.def.plaza_feature = step.plaza_feature
	_town_plaza(ctx.def, ctx.layout)


static func town_parcel_step(step: TownParcelStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.max_block_area = step.max_block_area
	def.min_block_area = step.min_block_area
	def.lot_max_area = step.lot_max_area
	def.lot_min_area = step.lot_min_area
	var lme = step.get("lot_min_edge")
	if lme != null:
		def.set("lot_min_edge", int(lme))
	_town_parcels(def, ctx.layout, ctx.next_rng())


static func town_building_step(step: TownBuildingStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.house_fill_ratio = step.house_fill_ratio
	def.setback = step.setback
	def.house_layers_min = step.house_layers_min
	def.house_layers_max = step.house_layers_max
	def.house_roof = step.house_roof
	def.build_max_step = step.build_max_step
	# 库类字段非空才覆盖（允许 tres 全局库与步骤专属库混用）
	if not step.houses.is_empty():
		def.houses = step.houses
	if not step.facilities.is_empty():
		def.facilities = step.facilities
	if not step.style_table.is_empty():
		def.style_table = step.style_table
	_town_buildings(def, ctx.layout, ctx.next_rng())


static func town_interior_step(step: TownInteriorStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	if not step.furniture_tables.is_empty():
		def.furniture_tables = step.furniture_tables
	if not step.prop_table.is_empty():
		def.prop_table = step.prop_table
	def.props_per_building = step.props_per_building
	_town_interiors(def, ctx.layout, ctx.next_rng())


static func town_greenery_step(step: TownGreeneryStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.tree_count = step.tree_count
	def.tree_min_distance = step.tree_min_distance
	def.street_tree_spacing = step.street_tree_spacing
	_town_greenery(def, ctx.layout, ctx.next_rng())


static func town_street_step(step: TownStreetStep, ctx: TownGenContext) -> void:
	ctx.def.streetlamp_spacing = step.streetlamp_spacing
	ctx.def.set("bin_spacing", step.bin_spacing)
	ctx.def.set("bus_stop_spacing", step.bus_stop_spacing)
	ctx.def.set("adboard_spacing", step.adboard_spacing)
	_town_street_furniture(ctx.def, ctx.layout)


static func town_farm_step(step: TownFarmStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.farm_min_dist = step.farm_min_dist
	def.farm_min_area = step.farm_min_area
	_town_farms(def, ctx.layout)


static func town_conform_step(step: TownConformStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.road_max_grade = step.road_max_grade
	def.terrace_blend = step.terrace_blend
	if not step.enabled:
		return
	_conform_terrain(def, ctx.layout)


## S1 选址：最大陆地连通域内抽候选，按 平坦度/近水距离带/陆地占比 打分取最优
static func town_site_step(step: TownSiteStep, ctx: TownGenContext) -> void:
	var def := ctx.def
	def.site_candidates = step.site_candidates
	def.site_radius = step.site_radius
	def.water_band_min = step.water_band_min
	def.water_band_max = step.water_band_max
	var site := _town_site(def, ctx.heightmap, ctx.next_rng())
	ctx.site = site.pos
	ctx.site_score = site.score
	ctx.main_cells = site.main


## S1 选址：最大陆地连通域内抽候选，按 平坦度/近水距离带/陆地占比 打分取最优
static func _town_site(def: TownDef, hm: HeightMap, rng: RandomNumberGenerator) -> Dictionary:
	var fallback := Vector2i(def.width / 2, def.height / 2)
	if hm == null or hm.width <= 0 or hm.height <= 0:
		return {"pos": fallback, "score": 1.0, "main": PackedInt32Array()}
	var land := GeneratedGrid.create(hm.width, hm.height, 0)
	for i in hm.heights.size():
		land.cells[i] = 1 if hm.heights[i] >= def.sea_level else 0
	var comps := land.components(1)
	if comps.is_empty():
		push_warning("PCGTool.generate_town: 高度图无陆地，选址回退地图中心。")
		return {"pos": fallback, "score": 0.0, "main": PackedInt32Array()}
	var main := comps[0]
	for c in comps:
		if c.size() > main.size():
			main = c
	var water_dist := _distance_field(land, 0)
	# 候选采样: 评分窗口(site_radius)须完整落在地图内, 避免城镇贴边被截断;
	# 全部候选越界时回退不过滤(小地图兜底)
	var m := mini(def.site_radius, mini(land.width, land.height) / 2)
	var cands := PackedInt32Array()
	var cands_all := PackedInt32Array()
	for idx in main:
		cands_all.append(idx)
		var sx := idx % land.width
		var sy := idx / land.width
		if sx >= m and sy >= m and sx < land.width - m and sy < land.height - m:
			cands.append(idx)
	if cands.is_empty():
		cands = cands_all
	var best_idx: int = cands[0]
	var best_score := -INF
	for k in maxi(1, def.site_candidates):
		var idx: int = cands[rng.randi_range(0, cands.size() - 1)]
		var s := _site_score(def, hm, water_dist, idx % land.width, idx / land.width)
		if s > best_score:
			best_score = s
			best_idx = idx
	return {
		"pos": Vector2i(best_idx % land.width, best_idx / land.width),
		"score": clampf(best_score, 0.0, 1.0),
		"main": main,
	}


## 选址打分：0.55*平坦(含陡峭强惩罚) + 0.30*近水带宽 + 0.15*陆地占比（半径 R 内采样）
## 城镇应落在平缓地: 候选内最大坡度超过硬阈值即大幅降权, 杜绝"建在山腰上"
const _SITE_FLAT_TOL := 0.08
const _SITE_HARD_SLOPE := 0.14
static func _site_score(def: TownDef, hm: HeightMap, water_dist: PackedFloat32Array, cx: int, cy: int) -> float:
	var r := def.site_radius
	var slope_sum := 0.0
	var slope_n := 0
	var slope_max := 0.0
	var land_n := 0
	var total := 0
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var x := cx + dx
			var y := cy + dy
			if not hm.in_bounds(x, y):
				continue
			total += 1
			var sl := hm.slope(x, y)
			slope_sum += sl
			slope_max = maxf(slope_max, sl)
			slope_n += 1
			if hm.heights[y * hm.width + x] >= def.sea_level:
				land_n += 1
	var flat := clampf(1.0 - (slope_sum / maxf(1.0, slope_n)) / _SITE_FLAT_TOL, 0.0, 1.0)
	if slope_max > _SITE_HARD_SLOPE:
		flat *= 0.25
	var ratio := float(land_n) / maxf(1, total)
	var d := water_dist[cy * hm.width + cx]
	var ws := 1.0
	if d < INF:
		if d < def.water_band_min:
			ws = d / maxf(1.0, float(def.water_band_min))
		elif d > def.water_band_max:
			ws = clampf(1.0 - (d - def.water_band_max) / maxf(8.0, float(def.water_band_max)), 0.0, 1.0)
	return 0.55 * flat + 0.30 * ws + 0.15 * ratio


## 多源 BFS 距离场：到最近 source_value 格的 4 邻域步数（不可达=INF）
static func _distance_field(grid: GeneratedGrid, source_value: int) -> PackedFloat32Array:
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
		for d in _DIR4:
			var nx := cx + d.x
			var ny := cy + d.y
			if not grid.in_bounds(nx, ny):
				continue
			var ni := ny * grid.width + nx
			if dist[ni] > dist[cur] + 1.0:
				dist[ni] = dist[cur] + 1.0
				queue.append(ni)
	return dist


## S2 主干道路网：主街(site→边缘枢纽 坡度A*) + 次街(沿主街扰动垂直生长)
## S2b 横穿主干道(Arterial)：宽阔平直的车行骨架 + 沿线集散次街生长
## 业内参照 CS:Skylines 路网分级——先 Arterial 后 Collector/Local, 街区由此放大。
static func town_arterial_step(step: TownArterialStep, ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	if def.arterial_h_count <= 0 and def.arterial_v_count <= 0:
		return
	_town_arterials(def, ctx.heightmap, ctx.layout, ctx.next_rng())


static func _town_arterials(def: TownDef, hm: HeightMap, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	# 现实主干道绝大部分笔直: 60% 全程无控制点, 40% 带一个温和控制点
	# (偏移≈段长 10~20%, 转角<15°), 不做斜穿全图的大弯
	for i in def.arterial_h_count:
		var y0 := int(round((i + 1.0) / (def.arterial_h_count + 1.0) * def.height)) + rng.randi_range(-4, 4)
		y0 = clampi(y0, 4, def.height - 5)
		var wps := PackedVector2Array([Vector2(1, y0)])
		if rng.randf() < 0.4:
			var cx := def.width * rng.randf_range(0.35, 0.65)
			var cy := clampf(y0 + rng.randf_range(-1.0, 1.0) * def.width * (0.05 + def.arterial_jitter * 0.35), 4.0, def.height - 5.0)
			wps.append(Vector2(cx, cy))
		wps.append(Vector2(def.width - 2, y0))
		_stamp_arterial_line(def, hm, layout, wps, rng)
	for i in def.arterial_v_count:
		var x0 := int(round((i + 1.0) / (def.arterial_v_count + 1.0) * def.width)) + rng.randi_range(-4, 4)
		x0 = clampi(x0, 4, def.width - 5)
		var wps := PackedVector2Array([Vector2(x0, 1)])
		if rng.randf() < 0.4:
			var cz := def.height * rng.randf_range(0.35, 0.65)
			var cx := clampf(x0 + rng.randf_range(-1.0, 1.0) * def.height * (0.05 + def.arterial_jitter * 0.35), 4.0, def.width - 5.0)
			wps.append(Vector2(cx, cz))
		wps.append(Vector2(x0, def.height - 2))
		_stamp_arterial_line(def, hm, layout, wps, rng)


## 单条干道：控制点间 octilinear 两段式印刷 + 分段入图(cls=ARTERIAL) + 沿线集散次街生长
static func _stamp_arterial_line(def: TownDef, hm: HeightMap, layout: TownLayout, wps: PackedVector2Array, rng: RandomNumberGenerator) -> void:
	if wps.size() < 2:
		return
	var roads := layout.roads_grid
	# 控制点是稀疏拐点(2-3个)，_stamp_road_layer 是逐点印刷契约——
	# 必须先栅格化加密成逐格路径，否则干道只剩端点几个斑块(车流也会脱路穿房)
	var full := PackedVector2Array()
	for s in wps.size() - 1:
		var seg := _octi_segment(wps[s], wps[s + 1])
		for k in seg.size() - 1:
			full.append_array(_rasterize_line(seg[k], seg[k + 1]))
	_stamp_road_layer(roads, full, def.arterial_width, def.road_arterial_value, hm, def.sea_level, def.bridge_value)
	var start_idx := layout.road_nodes.size()
	for wp in wps:
		layout.road_nodes.append(wp)
	for s in wps.size() - 1:
		layout.road_edges.append({
			"a": start_idx + s, "b": start_idx + s + 1,
			"width": def.arterial_width, "cls": TownLayout.EdgeClass.ARTERIAL,
		})
	var spacing := maxi(4, def.arterial_collector_spacing)
	var i := spacing
	while i < full.size() - 2:
		var p := full[i]
		var nxt := full[i + 1]
		var seg := nxt - p
		if seg.length_squared() < 0.01:
			i += spacing
			continue
		var perp := Vector2(-seg.y, seg.x).normalized()
		for side in [-1.0, 1.0]:
			if rng.randf() < 0.1:
				continue
			var dir: Vector2 = perp * side
			var start := p + dir * (def.arterial_width * 0.5 + 1.0)
			_grow_street(def, hm, roads, start, dir, def.road_sec_value, def.secondary_max_len, rng, 0.12)
		i += spacing


## Octilinear 八方向工具: 方向吸附(0/45/90/...)+轴向+45°斜线的两段式连接
## 业内参照地铁图/路网示意图的 octilinear schematization(少弯折+长直线段)
static func _snap_dir8(v: Vector2) -> Vector2:
	if v.length() < 0.0001:
		return Vector2.RIGHT
	var step := PI / 4.0
	return Vector2.from_angle(roundf(v.angle() / step) * step)


## 两点间"轴向直线 + 45° 斜线"两段式路径(dx≈dy 时整段 45°)
static func _octi_segment(a: Vector2, b: Vector2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var adx := absf(dx)
	var ady := absf(dy)
	var out := PackedVector2Array([a])
	if adx > ady:
		out.append(Vector2(a.x + dx - signf(dx) * ady, a.y))
	elif ady > adx:
		out.append(Vector2(a.x, a.y + dy - signf(dy) * adx))
	out.append(b)
	return out


## 直线栅格化：返回 a→b 的逐格中心序列（含两端；先走主导轴，与 octilinear 印刷一致）
static func _rasterize_line(a: Vector2, b: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var d := b - a
	var steps := maxi(int(ceilf(d.length())), 1)
	for k in steps + 1:
		out.append(a + d * (float(k) / float(steps)))
	return out


## 折线简化为 octilinear 航点: 贪心延伸, 段方向 snap 8 向, 横向偏差超容差即截弯;
## max_bends 限定最大拐点数(现实道路以超长直线为主, 弯折是例外)
static func _octilinear_waypoints(path: PackedVector2Array, min_seg := 8, max_dev := 2.4, max_bends := 999) -> PackedVector2Array:
	if path.size() <= min_seg + 1:
		return path
	var out := PackedVector2Array([path[0]])
	var anchor := path[0]
	var i := mini(min_seg, path.size() - 1)
	while i < path.size() and out.size() - 1 < max_bends:
		var snapped := _snap_dir8(path[i] - anchor)
		var best_j := i
		var j := i
		while j < path.size():
			var rel := path[j] - anchor
			if rel.dot(snapped) < 0.0:
				break
			var lateral := absf(rel.x * snapped.y - rel.y * snapped.x)
			if lateral > max_dev:
				break
			best_j = j
			j += 1
		out.append(path[best_j])
		anchor = path[best_j]
		i = best_j + mini(min_seg, 1)
	# 拐点预算耗尽后仍须直连终点(保证主街触达边缘枢纽, 连通性不破)
	if out.size() > 0 and anchor != path[path.size() - 1]:
		out.append(path[path.size() - 1])
	return out


## 航点序列 → 分段印刷 + 多节点入图(cls 由调用方定), 返回无返回值直接写 layout
static func _stamp_octi_path(def: TownDef, hm: HeightMap, layout: TownLayout,
		wps: PackedVector2Array, width: int, value: int, cls: int) -> void:
	var roads := layout.roads_grid
	var start_idx := layout.road_nodes.size()
	for wp in wps:
		layout.road_nodes.append(wp)
	for s in wps.size() - 1:
		layout.road_edges.append({
			"a": start_idx + s, "b": start_idx + s + 1,
			"width": width, "cls": cls,
		})
	for s in wps.size() - 1:
		_stamp_road_layer(roads, _octi_segment(wps[s], wps[s + 1]), width, value, hm, def.sea_level, def.bridge_value)


static func town_roads_step(step: TownRoadStep, ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	var hm := ctx.heightmap
	var rng := ctx.next_rng()
	var roads := layout.roads_grid
	var hub := _edge_hub(def, hm, ctx.main_cells, rng)
	var main_path := _slope_astar(def, hm, roads, Vector2(layout.site), Vector2(hub), true, rng, def.main_jitter)
	if main_path.is_empty():
		push_warning("PCGTool.town_roads_step: 主街 A* 无通路，回退直线 L 路。")
		main_path = _carve_l_path(Vector2(layout.site), Vector2(hub), rng)
	# 主街: 完整印刷 A* 路径(保证 4 邻域连通); 图数据用 octilinear 航点
	# (横/竖/45° 长直段)供标线/导航消费——低 jitter 下 A* 本身已接近笔直
	_stamp_road_layer(roads, main_path, def.main_width, def.road_main_value, hm, def.sea_level, def.bridge_value)
	var raw_wps := _octilinear_waypoints(main_path, maxi(4, def.road_min_segment), 2.4, 3)
	# 去重 + 保证首尾为 site/hub
	var clean := PackedVector2Array([main_path[0]])
	for k in range(1, raw_wps.size()):
		if raw_wps[k] != clean[clean.size() - 1]:
			clean.append(raw_wps[k])
	if clean[clean.size() - 1] != main_path[main_path.size() - 1]:
		clean.append(main_path[main_path.size() - 1])
	var wps := clean
	var start_idx := layout.road_nodes.size()
	for wp in wps:
		layout.road_nodes.append(wp)
	for s in wps.size() - 1:
		layout.road_edges.append({
			"a": start_idx + s, "b": start_idx + s + 1,
			"width": def.main_width, "cls": TownLayout.EdgeClass.MAIN,
		})
	# 次街生长锚点沿主街实际路径取样
	var spacing := rng.randi_range(maxi(2, def.street_spacing_min), maxi(3, def.street_spacing_max))
	var i: int = spacing
	while i < main_path.size() - 1:
		var p := main_path[i]
		var nxt := main_path[mini(i + 1, main_path.size() - 1)]
		var seg := (nxt - p)
		var perp := Vector2(-seg.y, seg.x).normalized()
		for side in [-1.0, 1.0]:
			if rng.randf() < 0.1:
				continue
			var dir: Vector2 = perp * side
			var start := p + dir * (def.main_width * 0.5 + 1.0)
			_grow_street(def, hm, roads, start, dir, def.road_sec_value, def.secondary_max_len, rng)
		i += spacing


## 边缘枢纽：有高度图时选「最靠地图边缘的陆地格」（城门/码头，主街不出水）；
## 平地时随机挑一条边的随机点
static func _edge_hub(def: TownDef, hm: HeightMap, main_cells: PackedInt32Array, rng: RandomNumberGenerator) -> Vector2i:
	if hm != null and not main_cells.is_empty():
		var w := def.width
		var h := def.height
		var best_edges: Array = []
		var best_e := INF
		for idx in main_cells:
			var x := idx % w
			var y := idx / w
			var e := float(mini(mini(x, w - 1 - x), mini(y, h - 1 - y)))
			if e < best_e:
				best_e = e
				best_edges = [[x, y]]
			elif e == best_e and best_edges.size() < 8:
				best_edges.append([x, y])
		if not best_edges.is_empty():
			var pick: Array = best_edges[rng.randi_range(0, best_edges.size() - 1)]
			return Vector2i(int(pick[0]), int(pick[1]))
	match rng.randi_range(0, 3):
		0:
			return Vector2i(rng.randi_range(1, def.width - 2), 0)
		1:
			return Vector2i(def.width - 1, rng.randi_range(1, def.height - 2))
		2:
			return Vector2i(rng.randi_range(1, def.width - 2), def.height - 1)
	return Vector2i(0, rng.randi_range(1, def.height - 2))


## 次街贪心生长：直行偏好 + wander 随机弯折(转向后锁定 min_run 直行, 避免碎弯)；
## 碰到其他路即接入，出界/到长即止。
## bridge_allowed 时遇水段自动标桥值跨过(山谷连通关键)，否则遇水折返。
static func _grow_street(def: TownDef, hm: HeightMap, roads: GeneratedGrid, start: Vector2, dir: Vector2, value: int, max_len: int, rng: RandomNumberGenerator, wander_scale := 1.0) -> void:
	var cur := Vector2i(int(round(start.x)), int(round(start.y)))
	if not roads.in_bounds(cur.x, cur.y):
		return
	var d := _dominant_dir(dir)
	var min_run := maxi(1, def.street_min_run)
	var run := 0
	var len := 0
	for step in max_len:
		if not roads.in_bounds(cur.x, cur.y):
			return
		if roads.get_cell(cur.x, cur.y, 0) != 0 and len > 0:
			return
		var underwater := hm != null and hm.get_height(cur.x, cur.y, 1.0) < def.sea_level
		if underwater and not def.bridge_allowed:
			return
		roads.set_cell(cur.x, cur.y, def.bridge_value if underwater else value)
		len += 1
		run += 1
		var nd := d
		if run >= min_run and rng.randf() < def.street_wander * wander_scale:
			nd = _turn_left(d) if rng.randf() < 0.5 else _turn_right(d)
			run = 0
		var np := cur + nd
		if not roads.in_bounds(np.x, np.y):
			nd = _turn_left(d) if rng.randf() < 0.5 else _turn_right(d)
			run = 0
			np = cur + nd
			if not roads.in_bounds(np.x, np.y):
				return
		d = nd
		cur = np


static func _dominant_dir(v: Vector2) -> Vector2i:
	if absf(v.x) > absf(v.y):
		return Vector2i(signi(int(v.x)), 0)
	return Vector2i(0, signi(int(v.y)))


static func _turn_left(d: Vector2i) -> Vector2i:
	return Vector2i(d.y, -d.x)


static func _turn_right(d: Vector2i) -> Vector2i:
	return Vector2i(-d.y, d.x)


## 把路径以指定宽度印进道路层（水上自动标桥值）。
## int 化后相邻点呈对角关系时自动补楼梯格——保证斜线段 4 邻域连通(BFS/导航依赖)
static func _stamp_road_layer(roads: GeneratedGrid, path: PackedVector2Array, width: int, value: int, hm: HeightMap, sea_level: float, bridge_value: int) -> void:
	var hw := (width - 1) / 2
	var prev := Vector2i(2147483647, 2147483647)
	for p in path:
		var c := Vector2i(int(p.x), int(p.y))
		if c == prev:
			continue
		if prev.x != 2147483647 and c.x != prev.x and c.y != prev.y:
			# 对角跳: 补 (c.x, prev.y) 拐角格使 4 连通
			_stamp_wide(roads, Vector2i(c.x, prev.y), hw, value, hm, sea_level, bridge_value)
		_stamp_wide(roads, c, hw, value, hm, sea_level, bridge_value)
		prev = c


## 以格为中心印 width×width 道路块
static func _stamp_wide(roads: GeneratedGrid, c: Vector2i, hw: int, value: int, hm: HeightMap, sea_level: float, bridge_value: int) -> void:
	for dy in range(-hw, width_from_hw(hw) - hw):
		for dx in range(-hw, width_from_hw(hw) - hw):
			var x := c.x + dx
			var y := c.y + dy
			if not roads.in_bounds(x, y):
				continue
			var v := value
			if hm != null and hm.get_height(x, y, 1.0) < sea_level:
				v = bridge_value
			roads.set_cell(x, y, v)


static func width_from_hw(hw: int) -> int:
	return hw * 2 + 1


## 二叉最小堆（A* 开放列表；吸取线性扫描 O(n²) 教训）
class _MinHeap:
	var _keys := PackedFloat64Array()
	var _vals := PackedInt32Array()

	func push(k: float, v: int) -> void:
		_keys.append(k)
		_vals.append(v)
		var i := _keys.size() - 1
		while i > 0:
			var p := (i - 1) / 2
			if _keys[p] <= _keys[i]:
				break
			_swap(i, p)
			i = p

	func pop() -> int:
		var top := _vals[0]
		var last := _vals.size() - 1
		_keys[0] = _keys[last]
		_vals[0] = _vals[last]
		_keys.resize(last)
		_vals.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := i * 2 + 2
			var m := i
			if l < _keys.size() and _keys[l] < _keys[m]:
				m = l
			if r < _keys.size() and _keys[r] < _keys[m]:
				m = r
			if m == i:
				break
			_swap(i, m)
			i = m
		return top

	func is_empty() -> bool:
		return _keys.is_empty()

	func _swap(a: int, b: int) -> void:
		var tk := _keys[a]
		_keys[a] = _keys[b]
		_keys[b] = tk
		var tv := _vals[a]
		_vals[a] = _vals[b]
		_vals[b] = tv


## 带坡度代价的 A*（4 邻域）：cost = 1 + k*Δh²；水面=桥代价(禁桥则不通)；已有道路借道×0.4。
## jitter>0 时给每格加随机代价扰动（业内 path perturbation，让主街自然弯曲），需传 rng 保证可复现
static func _slope_astar(def: TownDef, hm: HeightMap, roads: GeneratedGrid, a: Vector2, b: Vector2, allow_bridge: bool, rng: RandomNumberGenerator = null, jitter := 0.0) -> PackedVector2Array:
	var w := roads.width
	var h := roads.height
	var start := Vector2i(clampi(int(a.x), 0, w - 1), clampi(int(a.y), 0, h - 1))
	var goal := Vector2i(clampi(int(b.x), 0, w - 1), clampi(int(b.y), 0, h - 1))
	var n := w * h
	var g := PackedFloat64Array()
	g.resize(n)
	g.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n)
	var heap := _MinHeap.new()
	var si := start.y * w + start.x
	var gi := goal.y * w + goal.x
	g[si] = 0.0
	heap.push(float(manhattan_dist(start, goal)), si)
	var found := false
	while not heap.is_empty():
		var cur := heap.pop()
		if closed[cur] == 1:
			continue
		closed[cur] = 1
		if cur == gi:
			found = true
			break
		var cx := cur % w
		var cy := cur / w
		var h_cur := hm.get_height(cx, cy, 0.5) if hm else 0.5
		var cur_water := hm != null and h_cur < def.sea_level
		for d in _DIR4:
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var ni := ny * w + nx
			if closed[ni] == 1:
				continue
			var h_next := hm.get_height(nx, ny, 0.5) if hm else 0.5
			var next_water := hm != null and h_next < def.sea_level
			if next_water and (not allow_bridge or cur_water):
				continue
			var cost := 1.0 + def.slope_cost_k * absf(h_next - h_cur) * absf(h_next - h_cur)
			if next_water:
				cost += def.bridge_cost
			if roads.get_cell(nx, ny, 0) != 0:
				cost *= 0.4
			if rng != null and jitter > 0.0:
				cost += rng.randf_range(0.0, jitter)
			var ng := g[cur] + cost
			if ng < g[ni]:
				g[ni] = ng
				prev[ni] = cur
				heap.push(ng + manhattan_dist(Vector2i(nx, ny), goal), ni)
	if not found:
		return PackedVector2Array()
	var path := PackedVector2Array()
	var ci := gi
	while ci >= 0:
		path.append(Vector2(ci % w, ci / w))
		ci = prev[ci]
	path.reverse()
	return path


static func manhattan_dist(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## S3+S2b 街区细分：对道路外包盒做递归空间细分（Parish&Müller 网格化）——
## 过大矩形沿长轴中线（抖动）刻一条完整巷道，天然形成闭合街区；
## 有高度图时跳过陡坡格、水格按桥规则处理。块提取交给 S4 的 components。
static func _town_alley_split(def: TownDef, hm: HeightMap, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var roads := layout.roads_grid
	var bounds := Rect2i()
	var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first:
					bounds = Rect2i(x, y, 1, 1)
					first = false
				else:
					bounds = bounds.expand(Vector2i(x, y))
	if first:
		return
	var root := bounds.grow(2).intersection(Rect2i(0, 0, roads.width, roads.height))
	var stack: Array[Rect2i] = [root]
	var guard := 0
	while not stack.is_empty() and guard < 512:
		guard += 1
		var r: Rect2i = stack.pop_back()
		if r.size.x * r.size.y <= def.max_block_area:
			continue
		var vertical := r.size.x >= r.size.y
		var cut_pos := -1
		var cut_len := 0
		var carved := false
		if vertical:
			cut_pos = clampi(r.position.x + int(r.size.x * rng.randf_range(0.35, 0.65)), r.position.x + 2, r.end.x - 3)
			cut_len = r.size.y
		else:
			cut_pos = clampi(r.position.y + int(r.size.y * rng.randf_range(0.35, 0.65)), r.position.y + 2, r.end.y - 3)
			cut_len = r.size.x
		for k in cut_len:
			var p := Vector2i(cut_pos, r.position.y + k) if vertical else Vector2i(r.position.x + k, cut_pos)
			if hm != null and not def.bridge_allowed and hm.get_height(p.x, p.y, 1.0) < def.sea_level:
				continue
			if roads.get_cell(p.x, p.y, 0) == 0:
				roads.set_cell(p.x, p.y, def.road_alley_value)
				carved = true
		layout.road_nodes.append(Vector2(cut_pos, r.position.y + cut_len / 2.0) if vertical else Vector2(r.position.x + cut_len / 2.0, cut_pos))
		var a: Rect2i
		var b: Rect2i
		if vertical:
			a = Rect2i(r.position, Vector2i(cut_pos - r.position.x, r.size.y))
			b = Rect2i(Vector2i(cut_pos + 1, r.position.y), Vector2i(r.end.x - cut_pos - 1, r.size.y))
		else:
			a = Rect2i(r.position, Vector2i(r.size.x, cut_pos - r.position.y))
			b = Rect2i(Vector2i(r.position.x, cut_pos + 1), Vector2i(r.size.x, r.end.y - cut_pos - 1))
		stack.append(a)
		stack.append(b)
	# 收尾清理: 仅抹除 ≤24 格的孤立小碎片(悬空巷道尾巴),
	# 大分量一律保留(主街/干道/环路各自成网, 后续步骤可自然交汇)
	var solid := GeneratedGrid.create(roads.width, roads.height, 0)
	for i in roads.cells.size():
		if roads.cells[i] != 0:
			solid.cells[i] = 1
	for c in solid.components(1):
		if c.size() <= 24:
			for idx in c:
				roads.cells[idx] = 0
	# 真实街区加密: 外包矩形切分对不规则路网(山地张量)会落空, 改为直接
	# 对面积超限的封闭口袋(实际街区)内部刻巷道, 迭代至全部 ≤ 目标街区尺度
	_town_block_densify(def, layout)


## 街区加密 — 对面积超限的真实封闭口袋刻巷道切分(每轮每口袋切一刀, 最多 16 轮至收敛)
static func _town_block_densify(def: TownDef, layout: TownLayout) -> void:
	var roads := layout.roads_grid
	# 目标街区尺度与 max_block_area(地块切分阈值, 通常很大)无关:
	# 按真实城镇街区感取 min_block_area 的 2 倍(典型 80*2=160), 超过即加密
	var target := maxi(def.min_block_area * 2, 120)
	# 轮数上限 16: 每轮每个超限口袋至少被削去 1 格(单调收敛),
	# S形/凹形口袋切单列未必断开但持续缩小, 直至 ≤ target 或无列可切
	for pass_i in 16:
		var cut_any := false
		for comp in _town_blocks(roads):
			if comp.size() <= target:
				continue
			# 跳过接触地图边界的外部区域(不是街区)
			var bbox := Rect2i()
			var first := true
			var touches_border := false
			for idx in comp:
				var c := Vector2i(idx % roads.width, idx / roads.width)
				if first:
					bbox = Rect2i(c, Vector2i.ONE)
					first = false
				else:
					bbox = bbox.expand(c)
				if c.x == 0 or c.y == 0 or c.x == roads.width - 1 or c.y == roads.height - 1:
					touches_border = true
			if touches_border:
				continue
			# 沿长轴找覆盖最多口袋格的切线(矩形切分对不规则口袋落空的补救)
			var vertical := bbox.size.x >= bbox.size.y
			var best_pos := -1
			var best_cover := 0
			if vertical:
				for cx in range(bbox.position.x + 1, bbox.end.x - 1):
					var cover := 0
					for idx in comp:
						if idx % roads.width == cx:
							cover += 1
					if cover > best_cover:
						best_cover = cover
						best_pos = cx
			else:
				for cy in range(bbox.position.y + 1, bbox.end.y - 1):
					var cover := 0
					for idx in comp:
						if idx / roads.width == cy:
							cover += 1
					if cover > best_cover:
						best_cover = cover
						best_pos = cy
			if best_pos < 0 or best_cover < 4:
				continue
			# 沿切线把口袋内格子刻成巷道(水下跳过; 山地巷道=石阶, 不查坡度)
			for idx in comp:
				var c := Vector2i(idx % roads.width, idx / roads.width)
				var on_line := (c.x == best_pos) if vertical else (c.y == best_pos)
				if not on_line or roads.get_cell(c.x, c.y, 0) != 0:
					continue
				if layout.heightmap != null and layout.heightmap.get_height(c.x, c.y, 1.0) < def.sea_level:
					continue
				roads.set_cell(c.x, c.y, def.road_alley_value)
				cut_any = true
		if not cut_any:
			break


## 街区提取：非道路连通域（复用 components）
static func _town_blocks(roads: GeneratedGrid) -> Array[PackedInt32Array]:
	var sep := GeneratedGrid.create(roads.width, roads.height, 0)
	for i in sep.cells.size():
		sep.cells[i] = 1 if roads.cells[i] != 0 else 0
	return sep.components(0)


## S4 地块细分：每街区递归交替切片，直到满足面积/长宽比；无临街的地块丢弃；
## 广场格(plaza_cells)不参与细分
static func _town_parcels(def: TownDef, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var roads := layout.roads_grid
	var plaza := {}
	for idx in layout.plaza_cells:
		plaza[int(idx)] = true
	for block in _town_blocks(roads):
		if block.size() < def.min_block_area:
			continue
		var rect := _bounds_of(block, roads.width)
		var cells := {}
		for idx in block:
			if not plaza.has(int(idx)):
				cells[idx] = true
		if cells.is_empty():
			continue
		_slice_lot(def, roads, cells, rect, 0, rng, layout.parcels)


static func _slice_lot(def: TownDef, roads: GeneratedGrid, cells: Dictionary, rect: Rect2i, depth: int, rng: RandomNumberGenerator, out: Array) -> void:
	if depth > 14:
		return
	var area := cells.size()
	if area < def.lot_min_area:
		return
	if area <= def.lot_max_area:
		# 无临街的地块丢弃（转绿地/院子由消费方处理）——保证每栋建筑都能朝街开门
		var front := _frontage_dir(roads, cells)
		if front >= 0:
			out.append({
				"rect": rect,
				"cells": PackedInt32Array(cells.keys()),
				"frontage_dir": front,
			})
		return
	var ra: Rect2i
	var rb: Rect2i
	# OBB 退化实现：以地块实际格 extents 选切轴（L 形街区不再按外包盒切出大空矩形），
	# 切点在 [pos+min_edge, end-min_edge] 内随机（Parish&Müller 随机比例），
	# 保证两半沿切轴都不窄于 lot_min_edge——防 1 格细条地块（锯齿观感根因）
	var me := maxi(1, int(def.get("lot_min_edge")) if def.get("lot_min_edge") != null else 1)
	var exn := Vector2i(2147483647, 2147483647)
	var exx := Vector2i(-2147483648, -2147483648)
	for idx in cells:
		var ep := Vector2i(int(idx) % roads.width, int(idx) / roads.width)
		exn = exn.min(ep)
		exx = exx.max(ep)
	if exx.x - exn.x >= exx.y - exn.y:
		var lo := rect.position.x + me
		var hi := rect.end.x - me
		var sx: int = rect.get_center().x if lo > hi \
				else clampi(rect.position.x + int(rect.size.x * rng.randf_range(0.35, 0.65)), lo, hi)
		ra = Rect2i(rect.position, Vector2i(sx - rect.position.x, rect.size.y))
		rb = Rect2i(Vector2i(sx, rect.position.y), Vector2i(rect.end.x - sx, rect.size.y))
	else:
		var lo2 := rect.position.y + me
		var hi2 := rect.end.y - me
		var sy: int = rect.get_center().y if lo2 > hi2 \
				else clampi(rect.position.y + int(rect.size.y * rng.randf_range(0.35, 0.65)), lo2, hi2)
		ra = Rect2i(rect.position, Vector2i(rect.size.x, sy - rect.position.y))
		rb = Rect2i(Vector2i(rect.position.x, sy), Vector2i(rect.size.x, rect.end.y - sy))
	for half in [ra, rb]:
		var sub := _cells_in_rect(cells, half, roads.width)
		if not sub.is_empty():
			_slice_lot(def, roads, sub, half, depth + 1, rng, out)


## 临街方向：统计地块内贴道路格最多的方向（_DIR4 下标 0上1右2下3左，-1=无临街）
static func _frontage_dir(roads: GeneratedGrid, cells: Dictionary) -> int:
	var counts := [0, 0, 0, 0]
	for idx in cells:
		var x: int = int(idx) % roads.width
		var y: int = int(idx) / roads.width
		for di in 4:
			var d := _DIR4[di]
			if roads.get_cell(x + d.x, y + d.y, -1) != 0:
				counts[di] += 1
	var best := -1
	var bn := 0
	for di in 4:
		if counts[di] > bn:
			bn = counts[di]
			best = di
	return best


static func _bounds_of(cells: PackedInt32Array, w: int) -> Rect2i:
	var mn := Vector2i(2147483647, 2147483647)
	var mx := Vector2i(-2147483648, -2147483648)
	for idx in cells:
		var p := Vector2i(idx % w, idx / w)
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2i(mn, mx - mn + Vector2i.ONE)


static func _cells_in_rect(cells: Dictionary, rect: Rect2i, w: int) -> Dictionary:
	var out := {}
	# 按较小的一侧遍历（矩形面积 vs 集合大小）
	if rect.size.x * rect.size.y < cells.size():
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var idx := y * w + x
				if cells.has(idx):
					out[idx] = true
	else:
		for idx in cells:
			var xi: int = int(idx) % w
			var yi: int = int(idx) / w
			if xi >= rect.position.x and xi < rect.end.x and yi >= rect.position.y and yi < rect.end.y:
				out[idx] = true
	return out

## —— 路径（河流 / 道路） ——

## 把路径点以指定宽度印到栅格上（用于把河/路叠加进地形）
static func stamp_path(grid: GeneratedGrid, path: PackedVector2Array, value: int, width := 1) -> void:
	var hw := (width - 1) / 2
	for p in path:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-hw, hw + 1):
			for dx in range(-hw, hw + 1):
				grid.set_cell(px + dx, py + dy, value)

## 河流：从高地沿梯度下降流向低处（输出路径点合并集）
static func generate_river(def: RiverDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var all := PackedVector2Array()
	if def.elevation_layer == null:
		return all
	var noise: FastNoiseLite = def.elevation_layer.build_noise(rng.seed)
	for i in def.river_count:
		var start := _river_start(def, noise, rng)
		var path := _walk_downhill(def, noise, start, rng)
		all.append_array(path)
	return all

## 道路：连接枢纽点（自生成或传入）成网，输出走廊路径点合并集
static func generate_road(def: RoadDef, rng: RandomNumberGenerator, hubs := PackedVector2Array()) -> PackedVector2Array:
	if hubs.is_empty():
		for i in def.hub_count:
			hubs.append(Vector2(rng.randf() * def.region_size.x, rng.randf() * def.region_size.y))
	var all := PackedVector2Array()
	if def.mst_only:
		var edges := _mst_edges(hubs, rng)
		for e in edges:
			all.append_array(_carve_l_path(e[0], e[1], rng))
	else:
		for i in range(1, hubs.size()):
			all.append_array(_carve_l_path(hubs[i - 1], hubs[i], rng))
	return all

static func _river_start(def: RiverDef, noise: FastNoiseLite, rng: RandomNumberGenerator) -> Vector2:
	var best := Vector2.ZERO
	var best_h := -1.0
	for attempt in 20:
		var x := rng.randi_range(1, def.map_width - 2)
		var y := rng.randi_range(1, def.map_height - 2)
		var h := (noise.get_noise_2d(x, y) + 1.0) * 0.5
		if h > best_h:
			best_h = h
			best = Vector2(x, y)
	return best

static func _walk_downhill(def: RiverDef, noise: FastNoiseLite, start: Vector2, rng: RandomNumberGenerator) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var x := int(start.x)
	var y := int(start.y)
	for step in def.max_steps:
		pts.append(Vector2(x, y))
		if x < 0 or y < 0 or x >= def.map_width or y >= def.map_height:
			break
		var h := (noise.get_noise_2d(x, y) + 1.0) * 0.5
		if h <= def.sea_level:
			break
		var best := Vector2(x, y)
		var best_h := h
		for d in _DIR8:
			var nx := x + d.x
			var ny := y + d.y
			if nx < 0 or ny < 0 or nx >= def.map_width or ny >= def.map_height:
				continue
			var nh := (noise.get_noise_2d(nx, ny) + 1.0) * 0.5
			if nh < best_h:
				best_h = nh
				best = Vector2(nx, ny)
		if rng.randf() < def.wander:
			var d: Vector2i = _DIR8[rng.randi_range(0, _DIR8.size() - 1)]
			best = Vector2(clampi(x + d.x, 0, def.map_width - 1), clampi(y + d.y, 0, def.map_height - 1))
		if best == Vector2(x, y):
			break
		x = int(best.x)
		y = int(best.y)
	return pts

static func _carve_l_path(a: Vector2, b: Vector2, rng: RandomNumberGenerator) -> PackedVector2Array:
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

static func _mst_edges(hubs: PackedVector2Array, rng: RandomNumberGenerator) -> Array:
	var n := hubs.size()
	var in_tree := []
	for i in n:
		in_tree.append(false)
	if n == 0:
		return []
	in_tree[0] = true
	var edges: Array = []
	for k in range(n - 1):
		var best_i := -1
		var best_j := -1
		var best_d := INF
		for i in n:
			if not in_tree[i]:
				continue
			for j in n:
				if in_tree[j]:
					continue
				var d := hubs[i].distance_squared_to(hubs[j])
				if d < best_d:
					best_d = d
					best_i = i
					best_j = j
		if best_j == -1:
			break
		in_tree[best_j] = true
		edges.append([hubs[best_i], hubs[best_j]])
	return edges

## —— S5 建筑放置（POI 必有建筑优先分配 + 住宅填充，门自动朝临街边） ——

## 模板约定：门字符 G 画在最底边墙上。facing(_DIR4 索引 0上1右2下3左) → 使底边转到该朝向的旋转量
const _FACING_TO_ROT := {2: 0, 3: 1, 0: 2, 1: 3}

static func _town_buildings(def: TownDef, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	layout.build_grid = GeneratedGrid.create(def.width, def.height, 0)
	if def.houses.is_empty():
		return
	var used := {}
	var bid := 0
	for fac in def.facilities:
		if fac == null:
			continue
		# count = 数量期望：整数部分必出，小数部分按概率额外 +1
		var count := int(maxf(fac.count, 0.0))
		if rng.randf() < maxf(fac.count, 0.0) - float(count):
			count += 1
		var tmpl_list: Array[TemplateDef] = fac.templates if not fac.templates.is_empty() else def.houses
		for k in count:
			var lot := _best_lot(def, layout, used, rng, fac.prefer_main_street)
			if lot < 0:
				break
			# 专属户型优先，放不下回退通用库兜底（保证「必有」语义）
			if _place_from_lists(def, layout, lot, String(fac.facility_name), bid, rng, tmpl_list, fac) \
					or _place_from_lists(def, layout, lot, String(fac.facility_name), bid, rng, def.houses, fac):
				used[lot] = true
				bid += 1
	for li in layout.parcels.size():
		if used.has(li):
			continue
		var ward: String = str(layout.parcels[li].get("ward", ""))
		# 分区消费：市集区强制满密度(商业连续性)；贵族区石砌平顶+层数+1
		var ratio := def.house_fill_ratio if ward != "market" else 1.01
		if rng.randf() > ratio:
			continue
		if _place_from_lists(def, layout, li, "住宅", bid, rng, def.houses, null):
			used[li] = true
			if ward == "noble":
				var nb: Dictionary = layout.buildings[layout.buildings.size() - 1]
				nb["layers"] = clampi(int(nb.get("layers", 1)) + 1, def.house_layers_min, maxi(def.house_layers_max, def.house_layers_min + 1))
				if not def.flat_roof_styles.is_empty():
					nb["roof"] = "flat"
			bid += 1


## 挑未占用最优地块：主街临街(可选偏好) > 面积大 > 距选址近（POI 用）
static func _best_lot(def: TownDef, layout: TownLayout, used: Dictionary, rng: RandomNumberGenerator, prefer_main := true) -> int:
	var best := -1
	var best_score := -INF
	for li in layout.parcels.size():
		if used.has(li):
			continue
		var p: Dictionary = layout.parcels[li]
		if int(p.frontage_dir) < 0:
			continue
		var score := float((p.cells as PackedInt32Array).size())
		if prefer_main and _lot_touches_main(def, layout, p):
			score += 10000.0
		var c: Vector2i = (p.rect as Rect2i).get_center()
		score -= Vector2(c).distance_to(Vector2(layout.site)) * 2.0
		score += rng.randf_range(0.0, 8.0)
		if score > best_score:
			best_score = score
			best = li
	return best


static func _lot_touches_main(def: TownDef, layout: TownLayout, p: Dictionary) -> bool:
	var roads := layout.roads_grid
	for idx in p.cells:
		var x: int = int(idx) % roads.width
		var y: int = int(idx) / roads.width
		for d in _DIR4:
			if roads.get_cell(x + d.x, y + d.y, -1) == def.road_main_value:
				return true
	return false


## 从指定户型模板列表放置一栋建筑（设施用专属库，住宅用通用库），
## 模板按面积降序逐个尝试（同面积随机次序）：大地块优先放大房子，放不下再换小户型兜底
static func _place_from_lists(def: TownDef, layout: TownLayout, li: int, type_name: String, bid: int, rng: RandomNumberGenerator, tmpl_list: Array[TemplateDef], fac: FacilityDef) -> bool:
	var parcel: Dictionary = layout.parcels[li]
	var frontage := int(parcel.frontage_dir)
	if frontage < 0 or not _FACING_TO_ROT.has(frontage):
		return false
	var rect: Rect2i = parcel.rect
	# 临街宽度（沿 frontage 方向贴路的真实格数）：楼型与朝向匹配的依据
	# —— 窄临街配窄户型、宽临街配宽户型，避免宽街一面小屋或窄巷硬塞大楼
	var roads0: GeneratedGrid = layout.roads_grid
	var dir0: Vector2i = _DIR4[frontage]
	var front_len := 0
	for idx in parcel.cells:
		var cx: int = int(idx) % roads0.width
		var cy: int = int(idx) / roads0.width
		if roads0.get_cell(cx + dir0.x, cy + dir0.y, -1) > 0:
			front_len += 1
	# 模板按面积降序尝试（同面积随机次序）：大地块优先放 大房子，放不下再换小户型兜底；
	# 同时对「沿街尺寸与临街宽度失配」的模板施加惩罚（朝向→楼型规则）
	var scored: Array = []
	for t in tmpl_list:
		if t == null or t.lines.is_empty():
			continue
		var sz := t.get_size()
		var dim_fit := absf(maxf(sz.x, sz.y) - front_len) + absf(minf(sz.x, sz.y) - front_len) * 0.5
		scored.append({"t": t, "key": float(sz.x * sz.y) - dim_fit * 1.5 + rng.randf_range(0.0, 0.5)})
	if scored.is_empty():
		return false
	scored.sort_custom(func(a, b): return float(b.key) < float(a.key))
	# 朝向尝试顺序：临街方向优先，其余方向补充（拐角地块多面临街时提高成功率）
	var dirs: Array[int] = [frontage]
	for d in [0, 1, 2, 3]:
		if d != frontage:
			dirs.append(d)
	for entry in scored:
		var tmpl: TemplateDef = entry.t
		for facing in dirs:
			if not _FACING_TO_ROT.has(facing):
				continue
			if _try_place_one(def, layout, parcel, tmpl, facing, type_name, bid, rng, li, fac):
				return true
	return false


## 单模板单朝向的锚点放置：门格必须压在「沿 facing 方向邻路的真实临街格」上，
## 从门格反推建筑位置，保证门外一格必然是道路（包围盒贴边法在不规则地块上会让门朝向落空，已弃用）
static func _try_place_one(def: TownDef, layout: TownLayout, parcel: Dictionary, tmpl: TemplateDef, facing: int, type_name: String, bid: int, rng: RandomNumberGenerator, li: int, fac: FacilityDef) -> bool:
	var rot: int = _FACING_TO_ROT[facing]
	var rect: Rect2i = parcel.rect
	# 分向退线（CGA setback）：临街面不退（门贴路），侧/后各退线；退线量来自 Def 配置
	var side_setback := 1
	if def.get("setback") != null:
		side_setback = maxi(1, int(def.setback))
	var rear_setback := side_setback + 1
	var front_setback := 0
	var avail_w: int
	var avail_h: int
	match facing:
		0, 2:
			avail_w = rect.size.x - side_setback * 2
			avail_h = rect.size.y - rear_setback - front_setback if facing == 2 else rect.size.y - front_setback
		1, 3:
			avail_h = rect.size.y - side_setback * 2
			avail_w = rect.size.x - rear_setback - front_setback if facing == 1 else rect.size.x - front_setback
	if avail_w <= 0 or avail_h <= 0:
		return false
	if avail_w <= 0 or avail_h <= 0:
		return false
	var sz2 := tmpl.get_rotated_size(rot)
	var fw := sz2.x
	var fh := sz2.y
	if fw > avail_w and fh > avail_h and fw > avail_h and fh > avail_w:
		return false
	var roads := layout.roads_grid
	var dir_v: Vector2i = _DIR4[facing]
	var build := layout.build_grid
	var door_off := Vector2i(-1, -1)
	var tsize := tmpl.get_size()
	# 深水拒绝线 = 海平面 - 岸线容差(防御式读取, 旧缓存缺字段时用默认0.08)
	var shore_tol := 0.08
	if "shore_build_tolerance" in def:
		shore_tol = float(def.shore_build_tolerance)
	var sea_reject := def.sea_level - shore_tol
	var hm2: HeightMap = layout.heightmap
	for ly in tmpl.lines.size():
		var lx := tmpl.lines[ly].find("G")
		if lx >= 0:
			door_off = TemplateDef._rot_point(Vector2i(lx, ly), tsize, rot)
			break
	if door_off.x < 0:
		return false
	var anchors: Array[Vector2i] = []
	for idx in parcel.cells:
		var ax: int = int(idx) % def.width
		var ay: int = int(idx) / def.width
		if roads.get_cell(ax + dir_v.x, ay + dir_v.y, -1) > 0:
			anchors.append(Vector2i(ax, ay) - door_off)
	var placed := false
	var ox := 0
	var oy := 0
	while not anchors.is_empty():
		var ai := rng.randi_range(0, anchors.size() - 1)
		var pos := anchors[ai]
		anchors.remove_at(ai)
		if pos.x < rect.position.x or pos.y < rect.position.y:
			continue
		if pos.x + fw > rect.end.x or pos.y + fh > rect.end.y:
			continue
		var ok := true
		for yy in range(pos.y, pos.y + fh):
			for xx in range(pos.x, pos.x + fw):
				# 允许扩展到相邻空地(非道路/非建筑)，仅硬性禁止压路/重叠/深水
				if roads.get_cell(xx, yy, -1) != 0 or build.get_cell(xx, yy, -1) != 0:
					ok = false
					break
				# 逐格水位校验: 深水格不可建(浅水由后续桩基处理)。
				# 此前用 rect 四角判水, 角落踩到地块外水域会误杀整块合法临街地(山地规模骤缩根因)
				if hm2 != null and hm2.get_height(xx, yy, 1.0) < sea_reject:
					ok = false
					break
			if not ok:
				break
		if ok:
			ox = pos.x
			oy = pos.y
			placed = true
			break
	if not placed:
		return false
	_stamp_building(tmpl, build, ox, oy, rot, def)
	var door := Vector2i(-1, -1)
	for yy in range(oy, oy + fh):
		for xx in range(ox, ox + fw):
			if build.get_cell(xx, yy, -1) == def.building_door_value:
				door = Vector2i(xx, yy)
				break
		if door.x >= 0:
			break
	var footprint := Rect2i(ox, oy, fw, fh)
	# 贴地判定：小高差切台整平、大高差/临水桩基抬升(深水已在足迹逐格校验时拒绝)
	var ground_y := 0.0
	var foundation := "terrace"
	if hm2 != null:
		var corners: Array[float] = [
			hm2.get_height(ox, oy, 0.0),
			hm2.get_height(ox + fw - 1, oy, 0.0),
			hm2.get_height(ox, oy + fh - 1, 0.0),
			hm2.get_height(ox + fw - 1, oy + fh - 1, 0.0),
		]
		var mn: float = corners[0]
		var mx: float = corners[0]
		for h4 in corners:
			mn = minf(mn, h4)
			mx = maxf(mx, h4)
		if mx - mn > def.build_max_step or mn < def.sea_level:
			foundation = "stilt"
			ground_y = mx
		else:
			ground_y = (mn + mx) * 0.5
	if door.x < 0:
		door = footprint.get_center()
		build.set_cell(door.x, door.y, def.building_floor_value)
	# 建筑语义：层数与屋顶类型（跨项目成立的事实，渲染方据此解释外观）
	var layers := 0
	var roof := ""
	if fac != null:
		layers = clampi(fac.layers, 1, 4)
		roof = fac.roof
	else:
		# 住宅层数（CGA Mass Modeling 形态规则）：
		#   中心梯度（距选址越远越矮）与地块面积梯度按 area_height_weight 加权混合
		#   —— 小地块永不产出摩天楼（面积→高度区间），市中心/大地块自然高
		var dist := Vector2(footprint.get_center()).distance_to(Vector2(layout.site))
		var t_center := clampf(1.0 - dist / maxf(1.0, def.width * 0.5), 0.0, 1.0)
		var ahw := 0.4
		if def.get("area_height_weight") != null:
			ahw = clampf(float(def.get("area_height_weight")), 0.0, 1.0)
		var t_area := clampf(float((parcel.cells as PackedInt32Array).size()) / maxf(1.0, float(def.lot_max_area)), 0.0, 1.0)
		var t := (1.0 - ahw) * t_center + ahw * t_area
		layers = def.house_layers_min + int(round(t * (def.house_layers_max - def.house_layers_min)))
		if rng.randf() < 0.25:
			layers += 1
		layers = clampi(layers, def.house_layers_min, def.house_layers_max)
		roof = def.house_roof
	var style := _pick_style(def, layout, footprint.get_center(), rng)
	if def.flat_roof_styles.has(style):
		roof = "flat"
	# 沿主干道贴线的住宅 → 商铺语义(底层商业界面), 层数 +1(临街楼更高)
	if type_name == "住宅" and _footprint_touches_arterial(def, layout, footprint):
		type_name = "商铺"
		layers = clampi(layers + 1, 1, 8)
	layout.buildings.append({
		"id": bid, "type": type_name, "style": style,
		"rect": footprint, "door": door, "facing": facing,
		"layers": layers, "roof": roof,
		"ground_y": ground_y, "foundation": foundation,
		"template": tmpl.resource_path,
		"_tmpl": tmpl, "lot": li,
	})
	return true


## footprint 外扩 1 格是否接触主干道格（沿街商业界面的判定依据）
static func _footprint_touches_arterial(def: TownDef, layout: TownLayout, footprint: Rect2i) -> bool:
	var roads := layout.roads_grid
	for yy in range(maxi(0, footprint.position.y - 1), mini(roads.height, footprint.end.y + 1)):
		for xx in range(maxi(0, footprint.position.x - 1), mini(roads.width, footprint.end.x + 1)):
			if roads.get_cell(xx, yy, -1) == def.road_arterial_value:
				return true
	return false


## 风格分配：邻近继承（12 格内最近已放建筑的风格 70% 概率沿用，形成同街区同风格分区），
## 否则从 style_table 加权抽取
static func _pick_style(def: TownDef, layout: TownLayout, anchor: Vector2i, rng: RandomNumberGenerator) -> String:
	if def.style_table.is_empty():
		return ""
	var best_d := 12 * 12
	var near_style := ""
	for b in layout.buildings:
		var st := String(b.style)
		if st.is_empty():
			continue
		var dd: int = (b.rect as Rect2i).get_center().distance_squared_to(anchor)
		if dd < best_d:
			best_d = dd
			near_style = st
	if not near_style.is_empty() and rng.randf() < 0.7:
		return near_style
	return pick_weighted(rng, def.style_table).name


## 把户型模板按旋转印到建筑层（使用 TownDef 的墙/地板/门值，不走模板自身 char_map）。
## 槽位字符(B/T/C/H/S…)与未识别字符一律印为地板——它们只进 interiors 数据，不进栅格
static func _stamp_building(tmpl: TemplateDef, build: GeneratedGrid, ox: int, oy: int, rotation: int, def: TownDef) -> void:
	var mapping := {
		"#": def.building_wall_value,
		"G": def.building_door_value,
	}
	rotation = posmod(rotation, 4)
	var size := tmpl.get_size()
	for y in tmpl.lines.size():
		var line := tmpl.lines[y]
		for x in line.length():
			var ch := line[x]
			if ch == " ":
				continue
			var v := def.building_floor_value
			if mapping.has(ch):
				v = int(mapping[ch])
			var np := TemplateDef._rot_point(Vector2i(x, y), size, rotation)
			build.set_cell(ox + np.x, oy + np.y, v)


## —— 边缘打磨（广场 / 边界环路 / 院落围栏） ——

## 城镇边界环路：沿道路覆盖范围外圈刻一圈路，收束路网形成闭合边界；
## 触地图边缘的一侧自然开口（主街通向城外）
static func _town_ring_road(def: TownDef, hm: HeightMap, layout: TownLayout) -> void:
	var roads := layout.roads_grid
	var bounds := Rect2i()
	var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first:
					bounds = Rect2i(x, y, 1, 1)
					first = false
				else:
					bounds = bounds.expand(Vector2i(x, y))
	if first:
		return
	# 环路矩形：外包盒外扩，但与地图边缘保持 1 格间距（贴边侧不封口）
	var r := bounds.grow(2).intersection(Rect2i(1, 1, roads.width - 2, roads.height - 2))
	# 张量场城区半径: 环路不越过城区圆(圆形/月牙形路网配矩形环会圈进大片空地)
	var tr = def.get("tensor_town_radius")
	if tr != null and int(tr) > 0:
		var tc := Vector2(layout.site) if layout.site.x >= 0 else Vector2(roads.width, roads.height) * 0.5
		r = r.intersection(Rect2i(int(tc.x) - int(tr), int(tc.y) - int(tr), int(tr) * 2, int(tr) * 2))
	if r.size.x < 4 or r.size.y < 4:
		return
	var edge_cells: Array[Vector2i] = []
	for x in range(r.position.x, r.end.x):
		edge_cells.append(Vector2i(x, r.position.y))
		edge_cells.append(Vector2i(x, r.end.y - 1))
	for y in range(r.position.y + 1, r.end.y - 1):
		edge_cells.append(Vector2i(r.position.x, y))
		edge_cells.append(Vector2i(r.end.x - 1, y))
	for c in edge_cells:
		if roads.get_cell(c.x, c.y, 0) != 0:
			continue
		var under_water: bool = hm != null and hm.get_height(c.x, c.y, 1.0) < def.sea_level
		if under_water and not def.bridge_allowed:
			continue
		# 水上段必须有桥语义（否则贴地回写跳过水下格，形成断崖）
		roads.set_cell(c.x, c.y, def.bridge_value if under_water else def.road_ring_value)


## 死路清理：迭代摘除 4 邻域度数≤1 的次街/巷道端头（链式短死胡同逐轮收敛）；
## 主街/干道/环路/桥不参与摘除（保持骨架与跨水连通语义完整）。
## 摘除度数 1 的格子不会破坏连通性，且 2 格宽街道的两条并行 lane 互为支撑不会被误摘。
static func _prune_dead_ends(def: TownDef, layout: TownLayout) -> void:
	var pd = def.get("prune_dead_ends")
	if pd != null and not bool(pd):
		return
	var roads := layout.roads_grid
	var keep := [def.road_main_value, def.road_arterial_value, def.road_ring_value, def.bridge_value]
	for _pass in 8:
		var to_clear: Array[Vector2i] = []
		for y in roads.height:
			for x in roads.width:
				var v := roads.get_cell(x, y, 0)
				if v == 0 or keep.has(v):
					continue
				var n := 0
				for d in _DIR4:
					if roads.get_cell(x + d.x, y + d.y, -1) != 0:
						n += 1
				if n <= 1:
					to_clear.append(Vector2i(x, y))
		if to_clear.is_empty():
			return
		for c in to_clear:
			roads.set_cell(c.x, c.y, 0)


## 桥值兜底校验：任何落在水面上的路格必须携带桥语义
## （贴地回写/导航按桥规则处理；漏标会造成水下路格断崖或断路）
static func _ensure_bridges(def: TownDef, layout: TownLayout) -> void:
	var hm := layout.heightmap
	if hm == null:
		return
	var roads := layout.roads_grid
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) == 0:
				continue
			if hm.get_height(x, y, 1.0) < def.sea_level and roads.get_cell(x, y, -1) != def.bridge_value:
				roads.set_cell(x, y, def.bridge_value)


## —— 空间均衡：环路收口后对路网稀疏象限补生次街 ——
## 动机: 选址偏一侧 + 次街预算有限时, 城镇可能只覆盖地图一角(实测某种子仅 ~40%)。
## 做法: 以环路内接矩形分四象限统计路格密度, 对最稀疏且低于阈值的象限,
## 从其外缘现有路格朝象限质心生长次街; 重复 infill_passes 轮, 全部 rng 确定性。
static func _town_balance_infill(def: TownDef, hm: HeightMap, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var roads := layout.roads_grid
	var passes := 0
	if "infill_passes" in def:
		passes = int(def.infill_passes)
	var min_density := 0.05
	if "infill_min_density" in def:
		min_density = float(def.infill_min_density)
	if passes <= 0:
		return
	var bounds := Rect2i()
	var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first:
					bounds = Rect2i(x, y, 1, 1)
					first = false
				else:
					bounds = bounds.expand(Vector2i(x, y))
	if first:
		return
	var r := bounds.grow(2).intersection(Rect2i(1, 1, roads.width - 2, roads.height - 2))
	if r.size.x < 8 or r.size.y < 8:
		return
	for _pass in passes:
		var mid := Vector2(r.get_center())
		var half := Vector2(r.size) * 0.5
		var counts := [0, 0, 0, 0]
		var seeds: Array = [[], [], [], []]
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				if roads.get_cell(x, y, 0) == 0:
					continue
				var qi := (0 if float(y) < mid.y else 2) + (0 if float(x) < mid.x else 1)
				counts[qi] += 1
				seeds[qi].append(Vector2i(x, y))
		var worst := -1
		var worst_d := INF
		for qi in range(4):
			var dens := float(counts[qi]) / maxf(half.x * half.y, 1.0)
			if dens < worst_d:
				worst_d = dens
				worst = qi
		if worst < 0 or worst_d >= min_density:
			return
		var qcx: float = mid.x + (half.x * 0.5 if worst % 2 == 1 else -half.x * 0.5)
		var qcy: float = mid.y + (half.y * 0.5 if int(worst / 2.0) == 1 else -half.y * 0.5)
		var pool: Array = seeds[worst]
		if pool.is_empty():
			continue
		pool.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return Vector2(a).distance_to(Vector2(qcx, qcy)) > Vector2(b).distance_to(Vector2(qcx, qcy)))
		var start: Vector2i = pool[rng.randi_range(0, mini(3, pool.size() - 1))]
		var dir := Vector2(qcx - start.x, qcy - start.y)
		if dir.length() < 2.0:
			continue
		_grow_street(def, hm, roads, Vector2(start), dir.normalized(), def.road_sec_value, maxi(8, def.secondary_max_len / 2), rng)


## —— 语义分区(Wards)：市集/贵族/民居 ——
## 市集区: 邻广场 2.5 倍半径; 贵族区: 有临街且均高前四分位(需高度图); 其余民居。
## 结果: parcels[i].ward 标签 + layout.wards 统计; 由建筑步消费(密度/层数/屋顶)。
static func _town_wards(def: TownDef, layout: TownLayout, hm: HeightMap) -> void:
	var parcels := layout.parcels
	if parcels.is_empty():
		return
	var pc := layout.plaza_center
	var noble_t := INF
	if hm != null:
		var elevs := []
		for p in parcels:
			elevs.append(_parcel_elev(hm, p))
		elevs.sort()
		noble_t = elevs[int(elevs.size() * 0.75)]
	var counts := {}
	for p in parcels:
		var ward := "common"
		var c: Vector2i = (p.rect as Rect2i).get_center()
		if pc.x >= 0 and Vector2(c).distance_to(Vector2(pc)) <= def.plaza_radius * 2.5:
			ward = "market"
		elif hm != null and _parcel_elev(hm, p) >= noble_t and int(p.get("frontage_dir", -1)) >= 0:
			ward = "noble"
		p["ward"] = ward
		counts[ward] = int(counts.get(ward, 0)) + 1
	var stats := {}
	for k in counts:
		stats[k] = {"type": k, "parcels": counts[k]}
	layout.wards = stats


static func _parcel_elev(hm: HeightMap, p: Dictionary) -> float:
	var sum := 0.0
	var n := 0
	for idx in p.cells:
		sum += hm.heights[int(idx)]
		n += 1
	return sum / maxf(n, 1.0)


## —— 城墙 + 城门 ——
## 沿道路覆盖外包盒再外扩一圈筑墙(写入 build 层墙值 → 免费复用地形回写/渲染/导航语义);
## 主街与墙线相交处必开城门, 另按 extra_gates 在次街交点随机开小门;
## 四角记塔楼位; 水面格不筑墙(天然护城河缺口)。门洞单格宽, 数据层记录 pos/edge。
static func _town_walls(def: TownDef, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var roads := layout.roads_grid
	var build := layout.build_grid
	if build == null or roads == null:
		return
	var bounds := Rect2i()
	var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first:
					bounds = Rect2i(x, y, 1, 1)
					first = false
				else:
					bounds = bounds.expand(Vector2i(x, y))
	if first:
		return
	var r := bounds.grow(4).intersection(Rect2i(1, 1, roads.width - 2, roads.height - 2))
	if r.size.x < 6 or r.size.y < 6:
		return
	var walls := GeneratedGrid.create(roads.width, roads.height, 0)
	layout.walls_grid = walls
	layout.gates.clear()
	layout.wall_towers.clear()
	var perim: Array = []
	for x in range(r.position.x, r.end.x):
		perim.append([Vector2i(x, r.position.y), "N"])
		perim.append([Vector2i(x, r.end.y - 1), "S"])
	for y in range(r.position.y + 1, r.end.y - 1):
		perim.append([Vector2i(r.position.x, y), "W"])
		perim.append([Vector2i(r.end.x - 1, y), "E"])
	# 主街城门: 每边最多一处(向内 3 格探测主街); 全城城门最小间距, 防止门过多失去城墙意义
	var gate_pos := {}
	var gate_edge := {}
	for it in perim:
		var pos: Vector2i = it[0]
		var edge: String = it[1]
		if gate_pos.has(pos):
			continue
		if not _wall_gate_hit(roads, pos, edge, def.road_main_value):
			continue
		var near := false
		for gp in gate_pos.keys():
			if Vector2(gp).distance_to(Vector2(pos)) < 8.0:
				near = true
				break
		if near:
			continue
		gate_pos[pos] = true
		gate_edge[pos] = edge
	# 额外小门: 次街相交点随机挑(Fisher-Yates 用步骤 rng 保证确定性)
	var sec_hits: Array = []
	for it in perim:
		var pos: Vector2i = it[0]
		if gate_pos.has(pos):
			continue
		if _wall_gate_hit(roads, pos, it[1], def.road_sec_value):
			sec_hits.append(it)
	for i in range(sec_hits.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = sec_hits[i]
		sec_hits[i] = sec_hits[j]
		sec_hits[j] = tmp
	var picked := 0
	for it in sec_hits:
		var extra := 1
		if "extra_gates" in def:
			extra = int(def.extra_gates)
		if picked >= extra:
			break
		var pos: Vector2i = it[0]
		if gate_pos.has(pos):
			continue
		# 与既有城门保持最小间距(同主街门规则)
		var near := false
		for gp in gate_pos.keys():
			if Vector2(gp).distance_to(Vector2(pos)) < 8.0:
				near = true
				break
		if near:
			continue
		gate_pos[pos] = true
		gate_edge[pos] = it[1]
		picked += 1
	# 兜底城门(筑墙前判定): 若主街/次街都未与墙线相交(山地常见), 朝选址方向强制开一门
	if gate_pos.is_empty():
		var site_v := Vector2(layout.site)
		var best_p: Vector2i = perim[0][0]
		var best_e: String = perim[0][1]
		var best_d := INF
		for it in perim:
			var dd := Vector2(it[0]).distance_to(site_v)
			if dd < best_d:
				best_d = dd
				best_p = it[0]
				best_e = it[1]
		gate_pos[best_p] = true
		gate_edge[best_p] = best_e
	# 筑墙(跳过城门/已占用/水面/道路格); 城门统一在此记录
	# 墙遇路自动留口(路格不筑墙), 杜绝城墙横在街道上
	for it in perim:
		var pos: Vector2i = it[0]
		if gate_pos.has(pos):
			layout.gates.append({"pos": pos, "edge": it[1]})
			continue
		if build.get_cell(pos.x, pos.y, 0) != 0:
			continue
		if roads.get_cell(pos.x, pos.y, 0) != 0:
			continue
		# 水面不筑墙(护城河/水门缺口)
		if layout.heightmap != null and layout.heightmap.get_height(pos.x, pos.y, 1.0) < def.sea_level:
			continue
		build.set_cell(pos.x, pos.y, def.building_wall_value)
		walls.set_cell(pos.x, pos.y, 1)
	# 四角塔楼位
	layout.wall_towers.append(Vector2i(r.position))
	layout.wall_towers.append(Vector2i(r.end.x - 1, r.position.y))
	layout.wall_towers.append(Vector2i(r.position.x, r.end.y - 1))
	layout.wall_towers.append(Vector2i(r.end.x - 1, r.end.y - 1))
	# 城门引道: 从每个门向内铺路直到接入既有路网(山地主街够不到外墙时的进出保障)
	for it in gate_pos:
		var gpos: Vector2i = it
		var edge: String = gate_edge[it]
		var d := Vector2i(0, 1)
		match edge:
			"S":
				d = Vector2i(0, -1)
			"W":
				d = Vector2i(1, 0)
			"E":
				d = Vector2i(-1, 0)
		var cur := gpos + d
		for _k in range(8):
			if not roads.in_bounds(cur.x, cur.y):
				break
			if roads.get_cell(cur.x, cur.y, 0) != 0:
				break
			# 引道不穿建筑(建筑层已占用即止)
			if build.get_cell(cur.x, cur.y, 0) != 0:
				break
			var under := layout.heightmap != null and layout.heightmap.get_height(cur.x, cur.y, 1.0) < def.sea_level
			if under and not def.bridge_allowed:
				break
			roads.set_cell(cur.x, cur.y, def.bridge_value if under else def.road_sec_value)
			cur += d


## 门洞探测: 从墙体线沿边法线向内扫 4 格, 命中指定路值即认为相交
static func _wall_gate_hit(roads: GeneratedGrid, pos: Vector2i, edge: String, value: int) -> bool:
	var d := Vector2i(0, 1)
	var sgn := 1
	match edge:
		"S":
			d = Vector2i(0, -1)
		"W":
			d = Vector2i(1, 0)
		"E":
			d = Vector2i(-1, 0)
	for k in range(4):
		var p := pos + d * k * sgn
		if roads.in_bounds(p.x, p.y) and roads.get_cell(p.x, p.y, -1) == value:
			return true
	return false


## 广场：选址点周围半径内的空地记入 plaza_cells（不放建筑、地块细分跳过），
## 并在广场质心记录中心设施（水井/喷泉…）
static func _town_plaza(def: TownDef, layout: TownLayout) -> void:
	layout.plaza_cells.clear()
	layout.plaza_center = Vector2i(-1, -1)
	layout.plaza_item = ""
	if def.plaza_radius <= 0 or layout.roads_grid == null:
		return
	var roads := layout.roads_grid
	var r := def.plaza_radius
	var sum := Vector2.ZERO
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r:
				continue
			var x := layout.site.x + dx
			var y := layout.site.y + dy
			if roads.in_bounds(x, y) and roads.get_cell(x, y, -1) == 0:
				layout.plaza_cells.append(y * roads.width + x)
				sum += Vector2(x, y)
	if not layout.plaza_cells.is_empty():
		var centroid := sum / float(layout.plaza_cells.size())
		# 质心吸附到最近的广场格
		var best := layout.plaza_cells[0]
		var best_d := INF
		for idx in layout.plaza_cells:
			var dd := Vector2(int(idx) % roads.width, int(idx) / roads.width).distance_squared_to(centroid)
			if dd < best_d:
				best_d = dd
				best = idx
		layout.plaza_center = Vector2i(int(best) % roads.width, int(best) / roads.width)
		layout.plaza_item = def.plaza_feature


## —— S6 室内布局 + 家具摆放 ——

## 对每栋建筑：按其户型模板中的槽位字符（FurnitureTableDef.slot_name 配置）抽家具变体，
## 装饰物随机撒在剩余地板；最后做「门口内侧净空 + 家具可达性」校验修复（业内 post-placement repair）
static func _town_interiors(def: TownDef, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	var tables := {}
	for ft in def.furniture_tables:
		if ft != null and not ft.slot_name.is_empty() and not ft.items.is_empty():
			tables[ft.slot_name] = ft.items
	if tables.is_empty() or layout.build_grid == null:
		return
	var build := layout.build_grid
	for b in layout.buildings:
		var tmpl: TemplateDef = b.get("_tmpl")
		if tmpl == null:
			continue
		var rot: int = _FACING_TO_ROT.get(int(b.facing), 0)
		var rect: Rect2i = b.rect
		var tsize := tmpl.get_size()
		var slots: Array = []
		var occupied := {}
		for y in tmpl.lines.size():
			var line := tmpl.lines[y]
			for x in line.length():
				var ch := line[x]
				if ch == "#" or ch == "." or ch == "G" or not tables.has(ch):
					continue
				var np := TemplateDef._rot_point(Vector2i(x, y), tsize, rot)
				var cell := Vector2i(rect.position.x + np.x, rect.position.y + np.y)
				if build.get_cell(cell.x, cell.y, -1) != def.building_floor_value:
					continue
				slots.append({"cell": cell, "item": pick_weighted(rng, tables[ch]).name})
				occupied[cell.y * def.width + cell.x] = true
		var free_cells: Array[Vector2i] = []
		for yy in range(rect.position.y, rect.end.y):
			for xx in range(rect.position.x, rect.end.x):
				var idx := yy * def.width + xx
				if build.get_cell(xx, yy, -1) == def.building_floor_value and not occupied.has(idx):
					free_cells.append(Vector2i(xx, yy))
		var props: Array = []
		for k in mini(def.props_per_building, free_cells.size()):
			if def.prop_table.is_empty():
				break
			var fi := rng.randi_range(0, free_cells.size() - 1)
			var pc := free_cells[fi]
			free_cells.remove_at(fi)
			props.append({"cell": pc, "item": pick_weighted(rng, def.prop_table).name})
		layout.interiors[int(b.id)] = {"slots": slots, "props": props}
	_town_validate_interiors(def, layout)
	_town_yards(def, layout)


## 院落围栏：建筑 footprint 外一圈、地块内的空格（临街侧留院门开口），
## 仅记录数据不进栅格——消费方按 interiors[bid].yard 渲染围栏/小径
static func _town_yards(def: TownDef, layout: TownLayout) -> void:
	if layout.build_grid == null:
		return
	var build := layout.build_grid
	for b in layout.buildings:
		var iv: Dictionary = layout.interiors.get(int(b.id), {})
		var li: int = int(b.get("lot", -1))
		if li < 0 or li >= layout.parcels.size():
			continue
		var parcel: Dictionary = layout.parcels[li]
		var fp: Rect2i = b.rect
		var facing: int = int(b.facing)
		var yard: Array = []
		for idx in parcel.cells:
			var c := Vector2i(int(idx) % def.width, int(idx) / def.width)
			if c.x >= fp.position.x and c.x < fp.end.x and c.y >= fp.position.y and c.y < fp.end.y:
				continue
			if build.get_cell(c.x, c.y, -1) != 0:
				continue
			var dx := maxi(maxi(fp.position.x - c.x, c.x - fp.end.x + 1), 0)
			var dy := maxi(maxi(fp.position.y - c.y, c.y - fp.end.y + 1), 0)
			if dx + dy != 1:
				continue
			match facing:
				0:
					if c.y < fp.position.y:
						continue
				2:
					if c.y >= fp.end.y:
						continue
				1:
					if c.x >= fp.end.x:
						continue
				3:
					if c.x < fp.position.x:
						continue
			yard.append(c)
		if not yard.is_empty():
			iv["yard"] = yard
			layout.interiors[int(b.id)] = iv


## 室内校验修复：①门口内侧净空（有家具/装饰则移除）②可达性（BFS 从门出发，
## 家具与装饰视为阻挡，不可达的物品移除——保证玩家能走到每件家具旁交互）
static func _town_validate_interiors(def: TownDef, layout: TownLayout) -> void:
	var build := layout.build_grid
	if build == null:
		return
	for b in layout.buildings:
		var data: Dictionary = layout.interiors.get(int(b.id), {})
		if data.is_empty():
			continue
		var door: Vector2i = b.door
		var inner: Vector2i = door - _DIR4[int(b.facing)]
		var slots: Array = data.slots
		var props: Array = data.props
		var slots2: Array = []
		for s in slots:
			if s.cell != inner:
				slots2.append(s)
		var props2: Array = []
		for p in props:
			if p.cell != inner:
				props2.append(p)
		var blocked := {}
		for s in slots2:
			blocked[s.cell] = true
		for p in props2:
			blocked[p.cell] = true
		var floor_set := {}
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				if build.get_cell(xx, yy, -1) == def.building_floor_value:
					floor_set[Vector2i(xx, yy)] = true
		var visited := {door: true}
		var queue: Array[Vector2i] = [door]
		while not queue.is_empty():
			var c: Vector2i = queue.pop_back()
			for d in _DIR4:
				var n: Vector2i = c + d
				if floor_set.has(n) and not blocked.has(n) and not visited.has(n):
					visited[n] = true
					queue.append(n)
		data.slots = _filter_reachable(slots2, visited)
		data.props = _filter_reachable(props2, visited)


static func _filter_reachable(items: Array, visited: Dictionary) -> Array:
	var out: Array = []
	for it in items:
		var cell: Vector2i = it.cell
		for d in _DIR4:
			if visited.has(cell + d):
				out.append(it)
				break
	return out


## 绿化：城镇空地（非道路/建筑/广场）泊松式散布树木，记录到 layout.trees
static func _town_greenery(def: TownDef, layout: TownLayout, rng: RandomNumberGenerator) -> void:
	layout.trees.clear()
	layout.bushes.clear()
	if def.tree_count <= 0:
		return
	var roads := layout.roads_grid
	var build := layout.build_grid
	var plaza := {}
	for idx in layout.plaza_cells:
		plaza[int(idx)] = true
	var candidates: Array[Vector2i] = []
	var hm := layout.heightmap
	# 张量场城区半径: 散布限定在城区圆内, 避免树木蔓延到无人区
	var tr = def.get("tensor_town_radius")
	var radius := int(tr) if tr != null else 0
	var center := Vector2(layout.site) if layout.site.x >= 0 else Vector2(roads.width, roads.height) * 0.5
	for y in roads.height:
		for x in roads.width:
			var idx := y * roads.width + x
			if plaza.has(idx) or roads.get_cell(x, y, -1) != 0 or build.get_cell(x, y, -1) != 0:
				continue
			if hm != null and hm.sample(x, y) < def.sea_level:
				continue  # 水下不种树(否则悬空于水面/虚空)
			if radius > 0 and Vector2(x, y).distance_to(center) > float(radius):
				continue
			candidates.append(Vector2i(x, y))
	if candidates.is_empty():
		return
	# 洗牌后贪心收下满足最小间距的候选
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = t
	var min_d2 := def.tree_min_distance * def.tree_min_distance
	var placed := PackedVector3Array()
	# 行道树：沿主街每 spacing 格在邻接空格种树（优先于空地散布，避免重复）
	if def.street_tree_spacing > 0:
		var walk := 0
		for y in roads.height:
			for x in roads.width:
				if roads.get_cell(x, y, -1) != def.road_main_value:
					continue
				walk += 1
				if walk % def.street_tree_spacing != 0:
					continue
				for d in _DIR4:
					var tx := x + d.x
					var ty := y + d.y
					if not roads.in_bounds(tx, ty) or roads.get_cell(tx, ty, -1) != 0 or build.get_cell(tx, ty, -1) != 0:
						continue
					var dup := false
					for p in placed:
						var ddx := float(p.x - tx)
						var ddy := float(p.y - ty)
						if ddx * ddx + ddy * ddy < min_d2:
							dup = true
							break
					if not dup:
						placed.append(Vector3(tx, ty, 0))
						layout.trees.append(Vector2i(tx, ty))
	var attempts := maxi(def.tree_count * 8, 400)
	for cand in candidates:
		if placed.size() >= def.tree_count or attempts <= 0:
			break
		attempts -= 1
		var ok := true
		for p in placed:
			var ddx := float(p.x - cand.x)
			var ddy := float(p.y - cand.y)
			if ddx * ddx + ddy * ddy < min_d2:
				ok = false
				break
		if ok:
			placed.append(Vector3(cand.x, cand.y, 0))
			layout.trees.append(cand)
	# 灌木绿带: 沿主干道两侧人行带每 3 格一丛(低矮绿化, 独立于乔木间距)
	var bush_walk := 0
	var bush_used := {}
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, -1) != def.road_arterial_value:
				continue
			bush_walk += 1
			if bush_walk % 3 != 0:
				continue
			for d in _DIR4:
				var bx := x + d.x
				var by := y + d.y
				var bi := by * roads.width + bx
				if not roads.in_bounds(bx, by) or bush_used.has(bi):
					continue
				if roads.get_cell(bx, by, -1) == 0 and build.get_cell(bx, by, -1) == 0 \
						and not plaza.has(by * roads.width + bx):
					layout.bushes.append(Vector2i(bx, by))
					bush_used[bi] = true
					break


## 街具：路灯沿主干道/环路路格取样、贴路边空格；长椅沿广场临路边缘间隔摆放；
## 垃圾桶/消防栓沿主街与干道路缘；公交站/广告牌沿干道折线间隔设置
static func _town_street_furniture(def: TownDef, layout: TownLayout) -> void:
	layout.streets = {"lamps": [], "benches": [], "bins": [], "bus_stops": [], "hydrants": [], "adboards": []}
	if layout.roads_grid == null or def.streetlamp_spacing <= 0:
		return
	var roads := layout.roads_grid
	var build := layout.build_grid
	var used := {}
	# 路灯：主街/环路/干道/次街每 spacing 个取样（含绿地路段，夜景勾出路网），灯位放路的邻接空格
	var step := maxi(1, def.streetlamp_spacing)
	var walk := 0
	for y in roads.height:
		for x in roads.width:
			var rv := roads.get_cell(x, y, -1)
			if rv != def.road_main_value and rv != def.road_ring_value \
					and rv != def.road_arterial_value and rv != def.road_sec_value:
				continue
			walk += 1
			if walk % step != 0:
				continue
			for ddir in _DIR4:
				var lx := x + ddir.x
				var ly := y + ddir.y
				var li := ly * roads.width + lx
				if not roads.in_bounds(lx, ly) or used.has(li):
					continue
				if roads.get_cell(lx, ly, -1) == 0 and build.get_cell(lx, ly, -1) == 0:
					layout.streets["lamps"].append(Vector2i(lx, ly))
					used[li] = true
					break
	# 长椅：广场中贴路的边缘格隔 2 取 1 + 干道路缘每 14 格一张(与垃圾桶错开)
	var bench_walk := 0
	for idx in layout.plaza_cells:
		var px := int(idx) % roads.width
		var py := int(idx) / roads.width
		var edge := false
		for ddir in _DIR4:
			if roads.get_cell(px + ddir.x, py + ddir.y, -1) > 0:
				edge = true
				break
		if not edge:
			continue
		bench_walk += 1
		if bench_walk % 2 == 1 and build.get_cell(px, py, -1) == 0:
			layout.streets["benches"].append(Vector2i(px, py))
	var street_bench_walk := 0
	for y in roads.height:
		for x in roads.width:
			var rv := roads.get_cell(x, y, -1)
			if rv != def.road_main_value and rv != def.road_arterial_value:
				continue
			street_bench_walk += 1
			if street_bench_walk % 14 != 0:
				continue
			for ddir in _DIR4:
				var lx := x + ddir.x
				var ly := y + ddir.y
				var li := ly * roads.width + lx
				if not roads.in_bounds(lx, ly) or used.has(li):
					continue
				if roads.get_cell(lx, ly, -1) == 0 and build.get_cell(lx, ly, -1) == 0:
					layout.streets["benches"].append(Vector2i(lx, ly))
					used[li] = true
					break
	# 垃圾桶: 主街/干道路缘空格, 每 bin_spacing 取样(与路灯错开)
	var bin_step := maxi(3, def.bin_spacing)
	var bin_walk := 0
	for y in roads.height:
		for x in roads.width:
			var rv := roads.get_cell(x, y, -1)
			if rv != def.road_main_value and rv != def.road_arterial_value:
				continue
			bin_walk += 1
			if bin_walk % bin_step != 0:
				continue
			for ddir in _DIR4:
				var lx := x + ddir.x
				var ly := y + ddir.y
				var li := ly * roads.width + lx
				if not roads.in_bounds(lx, ly) or used.has(li):
					continue
				if roads.get_cell(lx, ly, -1) == 0 and build.get_cell(lx, ly, -1) == 0:
					layout.streets["bins"].append(Vector2i(lx, ly))
					used[li] = true
					break
	# 公交站: 沿 ARTERIAL 折线每 bus_stop_spacing 格取样, 站位取路侧空格
	var stop_step := maxi(6, def.bus_stop_spacing)
	var stop_walk := 0
	for e in layout.road_edges:
		if int(e.cls) != TownLayout.EdgeClass.ARTERIAL:
			continue
		var a := layout.road_nodes[int(e.a)]
		var b := layout.road_nodes[int(e.b)]
		var n := maxi(1, int(a.distance_to(b)))
		for k in n + 1:
			stop_walk += 1
			if stop_walk % stop_step != 0:
				continue
			var p := a.lerp(b, float(k) / float(n))
			var gx := int(roundf(p.x))
			var gy := int(roundf(p.y))
			var hw := int(e.width) / 2
			for s in [-hw - 2, hw + 2]:
				var sx: int = gx if absf(b.x - a.x) >= absf(b.y - a.y) else gx + s
				var sy: int = gy + s if absf(b.x - a.x) >= absf(b.y - a.y) else gy
				var li := sy * roads.width + sx
				if not roads.in_bounds(sx, sy) or used.has(li):
					continue
				if roads.get_cell(sx, sy, -1) == 0 and build.get_cell(sx, sy, -1) == 0:
					layout.streets["bus_stops"].append(Vector2i(sx, sy))
					used[li] = true
					break
	# 消防栓: 干道路缘空格, 每 bin_spacing 取样(与垃圾桶同频但由 used 集合自然错开)
	var hyd_step := maxi(5, def.bin_spacing)
	var hyd_walk := 0
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, -1) != def.road_arterial_value:
				continue
			hyd_walk += 1
			if hyd_walk % hyd_step != 0:
				continue
			for ddir in _DIR4:
				var hx := x + ddir.x
				var hy := y + ddir.y
				var hi := hy * roads.width + hx
				if not roads.in_bounds(hx, hy) or used.has(hi):
					continue
				if roads.get_cell(hx, hy, -1) == 0 and build.get_cell(hx, hy, -1) == 0:
					layout.streets["hydrants"].append(Vector2i(hx, hy))
					used[hi] = true
					break
	# 广告牌: 沿 ARTERIAL 折线大间隔取样(垂直元素, 与公交站错开)
	var ad_step := maxi(10, def.adboard_spacing / 2)
	var ad_walk := 0
	for e in layout.road_edges:
		if int(e.cls) != TownLayout.EdgeClass.ARTERIAL:
			continue
		var a := layout.road_nodes[int(e.a)]
		var b := layout.road_nodes[int(e.b)]
		var n := maxi(1, int(a.distance_to(b)))
		for k in n + 1:
			ad_walk += 1
			if ad_walk % ad_step != 0:
				continue
			var p := a.lerp(b, float(k) / float(n))
			var gx := int(roundf(p.x))
			var gy := int(roundf(p.y))
			var hw := int(e.width) / 2
			for s in [-hw - 3, hw + 3]:
				var sx: int = gx if absf(b.x - a.x) >= absf(b.y - a.y) else gx + s
				var sy: int = gy + s if absf(b.x - a.x) >= absf(b.y - a.y) else gy
				var li := sy * roads.width + sx
				if not roads.in_bounds(sx, sy) or used.has(li):
					continue
				if roads.get_cell(sx, sy, -1) == 0 and build.get_cell(sx, sy, -1) == 0 \
						and not _near_arterial_occupied(def, layout, Vector2i(sx, sy), 2):
					layout.streets["adboards"].append(Vector2i(sx, sy))
					used[li] = true
					break


## 该格周围 margin 格内是否已有建筑(广告牌不贴楼)
static func _near_arterial_occupied(_def: TownDef, layout: TownLayout, pos: Vector2i, margin: int) -> bool:
	var build := layout.build_grid
	for yy in range(pos.y - margin, pos.y + margin + 1):
		for xx in range(pos.x - margin, pos.x + margin + 1):
			if build.get_cell(xx, yy, -1) != 0:
				return true
	return false


## —— V1 地形回写（cut & fill） ——

## 道路限坡平滑 → 广场/建筑地基整平为锚点 → 向外羽化回写高度场。
## 保护规则：水上格(原高<海平面)不回写；陆地格回写后不低于海平面（防填海/挖成水洼）。
static func _conform_terrain(def: TownDef, layout: TownLayout) -> void:
	if not def.terrain_conform or layout.heightmap == null:
		return
	# 回写必须在高度图副本上进行: layout.heightmap 可能是管线共享输入(如 heightmap_key
	# 指向的世界地形), 原地改写会污染上游数据并破坏"同 seed 复现"(第二次生成踩在已回写地形上)
	var hm: HeightMap = HeightMap.create(layout.heightmap.width, layout.heightmap.height)
	hm.heights = (layout.heightmap.heights as PackedFloat32Array).duplicate()
	layout.heightmap = hm
	var roads := layout.roads_grid
	var build := layout.build_grid
	var w := roads.width
	var n := w * roads.height
	# 1) 锚点目标高：道路(限坡平滑) → 广场(均值) → 建筑切台(ground_y, 最高优先)
	var target := PackedFloat32Array()
	target.resize(n)
	target.fill(INF)
	# 1a 道路：梯度约束松弛——相邻路格高差强制 ≤ road_max_grade（正反扫 4 轮传播约束）
	var road_h := {}
	for i in n:
		if roads.cells[i] != 0:
			road_h[i] = hm.heights[i]
	var step := def.road_max_grade
	for _pass in 24:
		for rev in [false, true]:
			var xs := range(w)
			var ys := range(roads.height)
			if rev:
				xs.reverse()
				ys.reverse()
			for yy in ys:
				for xx in xs:
					var ri: int = yy * w + xx
					if not road_h.has(ri):
						continue
					for d in _DIR4:
						var ni: int = (yy + d.y) * w + (xx + d.x)
						if not road_h.has(ni):
							continue
						road_h[ri] = clampf(float(road_h[ri]), float(road_h[ni]) - step, float(road_h[ni]) + step)
	for i in road_h:
		target[int(i)] = float(road_h[i])
	# 1b 广场：均值整平
	if not layout.plaza_cells.is_empty():
		var psum := 0.0
		for idx in layout.plaza_cells:
			psum += hm.heights[int(idx)]
		var pavg := psum / float(layout.plaza_cells.size())
		for idx in layout.plaza_cells:
			target[int(idx)] = pavg
	# 1c 建筑：ground_y 切台（最高优先，覆盖道路锚点）
	for b in layout.buildings:
		var gy: float = float(b.ground_y)
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				target[yy * w + xx] = gy
	# 2) 羽化回写：多源 BFS 从锚点向外携带目标高，随距离衰减 lerp；水上格不回写
	var blend := def.terrace_blend
	var src_h := PackedFloat32Array()
	src_h.resize(n)
	src_h.fill(INF)
	var dist2 := PackedInt32Array()
	dist2.resize(n)
	dist2.fill(-1)
	var q2: Array[int] = []
	for i in n:
		if target[i] != INF:
			dist2[i] = 0
			src_h[i] = target[i]
			q2.append(i)
	var head := 0
	while head < q2.size():
		var cur3: int = q2[head]
		head += 1
		var cx3: int = int(cur3) % w
		var cy3: int = int(cur3) / w
		for d in _DIR4:
			var nx3 := cx3 + d.x
			var ny3 := cy3 + d.y
			if nx3 < 0 or ny3 < 0 or nx3 >= w or ny3 >= roads.height:
				continue
			var ni := ny3 * w + nx3
			if dist2[ni] != -1 or dist2[cur3] + 1 > blend:
				continue
			dist2[ni] = dist2[cur3] + 1
			src_h[ni] = src_h[cur3]
			q2.append(ni)
	var sea := def.sea_level
	for i in n:
		var orig2 := hm.heights[i]
		var is_bridge := roads.cells[i] == def.bridge_value
		if orig2 < sea and not is_bridge:
			continue
		var t2 := target[i]
		if t2 != INF:
			hm.heights[i] = maxf(t2, sea - 0.01)
		elif dist2[i] > 0 and not is_bridge:
			var k := 1.0 - float(dist2[i]) / float(blend + 1)
			var blended := lerpf(orig2, src_h[i], clampf(k, 0.0, 1.0))
			hm.heights[i] = maxf(blended, sea - 0.01)


## 陆地保护：原为陆地的格回写后不得低于海平面
static func _land_safe(orig: float, target: float, sea: float) -> float:
	if orig < sea:
		return orig
	return maxf(target, sea - 0.01)


## 农田：距选址超过 farm_min_dist 的连片空地（≥farm_min_area）转农田区，
## 记入 layout.farms（条纹方向由消费方按格坐标推算）
static func _town_farms(def: TownDef, layout: TownLayout) -> void:
	layout.farms.clear()
	var roads := layout.roads_grid
	var build := layout.build_grid
	var w := roads.width
	# 候选：城区外围空地（非道路/建筑/广场/树）
	var cand := {}
	var hm := layout.heightmap
	# 张量场城区半径: 农田不越过城区圆(否则剩余空地全变农田, 蔓延到图缘/无人区)
	var tr = def.get("tensor_town_radius")
	var radius := int(tr) if tr != null else 0
	var center := Vector2(layout.site) if layout.site.x >= 0 else Vector2(w, roads.height) * 0.5
	for y in roads.height:
		for x in roads.width:
			var idx := y * w + x
			if roads.get_cell(x, y, -1) != 0 or build.get_cell(x, y, -1) != 0:
				continue
			if Vector2(x, y).distance_to(Vector2(layout.site)) < def.farm_min_dist:
				continue
			if hm != null and hm.get_height(x, y, 1.0) < def.sea_level:
				continue  # 水下不设农田
			if radius > 0 and Vector2(x, y).distance_to(center) > float(radius):
				continue
			cand[idx] = true
	if cand.is_empty():
		return
	# 候选集连通域分组
	var visited := {}
	for idx in cand:
		if visited.has(int(idx)):
			continue
		var comp := PackedInt32Array()
		var stack: Array[int] = [int(idx)]
		visited[int(idx)] = true
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			comp.append(cur)
			var cx: int = cur % w
			var cy: int = cur / w
			for d in _DIR4:
				var ni: int = (cy + d.y) * w + (cx + d.x)
				if cand.has(ni) and not visited.has(ni):
					visited[ni] = true
					stack.append(ni)
		if comp.size() >= def.farm_min_area:
			layout.farms.append(comp)


## —— 模板拼接 ——

## 随机放置多个模板（不重叠）并用走廊连接，返回拼合栅格
static func generate_template_stitch(def: TemplateStitchDef, rng: RandomNumberGenerator) -> GeneratedGrid:
	var grid := GeneratedGrid.create(def.width, def.height, def.solid_value)
	if def.templates.is_empty():
		return grid
	var placed: Array = []
	for i in def.count:
		var tmpl := _pick_template(def.templates, rng)
		if tmpl == null:
			continue
		var rect := _try_place_template(def, tmpl, placed, rng)
		if rect.size == Vector2i.ZERO:
			continue
		tmpl.stamp(grid, rect.position.x, rect.position.y)
		placed.append(rect)
	if def.connect and placed.size() > 1:
		for i in range(1, placed.size()):
			_carve_stitch(grid, (placed[i - 1] as Rect2i).get_center(), (placed[i] as Rect2i).get_center(), def, rng)
	return grid

## 模板走廊（L 型，按 corridor_width 挖空）
static func _carve_stitch(grid: GeneratedGrid, a: Vector2i, b: Vector2i, def: TemplateStitchDef, rng: RandomNumberGenerator) -> void:
	var path := _carve_l_path(Vector2(a), Vector2(b), rng)
	var hw := (def.corridor_width - 1) / 2
	var range_w := def.corridor_width - hw
	for p in path:
		for dy in range(-hw, range_w):
			for dx in range(-hw, range_w):
				grid.set_cell(int(p.x) + dx, int(p.y) + dy, def.empty_value)

## 按权重抽模板
static func _pick_template(templates: Array[TemplateDef], rng: RandomNumberGenerator) -> TemplateDef:
	var total := 0.0
	for t in templates:
		total += maxf(t.weight, 0.0)
	if total <= 0.0:
		return templates[rng.randi_range(0, templates.size() - 1)] if not templates.is_empty() else null
	var r := rng.randf() * total
	for t in templates:
		r -= maxf(t.weight, 0.0)
		if r <= 0.0:
			return t
	return templates[templates.size() - 1]

## 尝试随机放置模板（与已放置模板保持 min_gap 间距），失败返回空 Rect2i
static func _try_place_template(def: TemplateStitchDef, tmpl: TemplateDef, placed: Array, rng: RandomNumberGenerator) -> Rect2i:
	var size := tmpl.get_size()
	if size.x >= def.width - 2 or size.y >= def.height - 2:
		return Rect2i()
	for attempt in 40:
		var ox := rng.randi_range(1, maxi(1, def.width - size.x - 1))
		var oy := rng.randi_range(1, maxi(1, def.height - size.y - 1))
		var rect := Rect2i(ox, oy, size.x, size.y)
		var ok := true
		for other in placed:
			var gap := def.min_gap
			var expanded := Rect2i((other as Rect2i).position - Vector2i(gap, gap), (other as Rect2i).size + Vector2i(gap * 2, gap * 2))
			if expanded.intersects(rect):
				ok = false
				break
		if ok:
			return rect
	return Rect2i()

## —— 内容进化（遗传算法） ——

## 进化内容：个体 = base + gene_count 个基因，适应度 = 基因数值(weight)之和（越高越好）
## 返回 top count 个 [{name, fitness}]，每代 选择→交叉→变异
static func evolve_content(def: ContentEvolveDef, rng: RandomNumberGenerator) -> Array:
	var bases := def.bases
	var genes := def.genes
	if genes.is_empty():
		return []
	if bases.is_empty():
		bases = PackedStringArray(["装备"])
	var population: Array = []
	for i in def.population:
		population.append(_evolve_random_individual(def, bases.size(), genes.size(), rng))
	for gen in def.generations:
		var scored: Array = []
		for ind in population:
			scored.append({"ind": ind, "fitness": _evolve_fitness(ind, genes)})
		scored.sort_custom(func(a, b): return a.fitness > b.fitness)
		var half := maxi(2, scored.size() / 2)
		var next_pop: Array = []
		for i in half:
			next_pop.append(scored[i].ind)
		while next_pop.size() < def.population:
			var a: Dictionary = scored[rng.randi_range(0, half - 1)].ind
			var b: Dictionary = scored[rng.randi_range(0, half - 1)].ind
			var child := _evolve_crossover(a, b, rng)
			_evolve_mutate(child, def, bases.size(), genes.size(), rng)
			next_pop.append(child)
		population = next_pop
	var final_scored: Array = []
	for ind in population:
		final_scored.append({"ind": ind, "fitness": _evolve_fitness(ind, genes)})
	final_scored.sort_custom(func(a, b): return a.fitness > b.fitness)
	var out: Array = []
	for i in mini(def.count, final_scored.size()):
		var ind: Dictionary = final_scored[i].ind
		var name := bases[ind.base]
		for gi in ind.genes:
			name += "·" + genes[gi].name
		out.append({"name": name, "fitness": final_scored[i].fitness})
	return out

static func _evolve_random_individual(def: ContentEvolveDef, n_base: int, n_gene: int, rng: RandomNumberGenerator) -> Dictionary:
	var genes := PackedInt32Array()
	for i in def.gene_count:
		genes.append(rng.randi_range(0, n_gene - 1))
	return {"base": rng.randi_range(0, n_base - 1), "genes": genes}

static func _evolve_fitness(ind: Dictionary, genes: Array) -> float:
	var total := 0.0
	for gi in ind.genes:
		total += genes[gi].weight
	return total

static func _evolve_crossover(a: Dictionary, b: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var child_genes := PackedInt32Array()
	var ga: PackedInt32Array = a.genes
	var gb: PackedInt32Array = b.genes
	for i in ga.size():
		child_genes.append(ga[i] if rng.randf() < 0.5 else gb[i])
	return {"base": a.base if rng.randf() < 0.5 else b.base, "genes": child_genes}

static func _evolve_mutate(ind: Dictionary, def: ContentEvolveDef, n_base: int, n_gene: int, rng: RandomNumberGenerator) -> void:
	if rng.randf() < def.mutation_rate:
		ind.base = rng.randi_range(0, n_base - 1)
	var genes_arr: PackedInt32Array = ind.genes
	for i in genes_arr.size():
		if rng.randf() < def.mutation_rate:
			genes_arr[i] = rng.randi_range(0, n_gene - 1)
	ind.genes = genes_arr

## —— 内容 ——

static func generate_content(def: ContentGenDef, rng: RandomNumberGenerator) -> Array:
	match def.mode:
		ContentGenDef.Mode.WEIGHTED:
			var out: Array = []
			for i in def.count:
				var e := pick_weighted(rng, def.entries)
				if e:
					out.append(e)
			return out
		ContentGenDef.Mode.NAME:
			var out: Array = []
			for i in def.count:
				out.append(generate_name(def, rng))
			return out
		ContentGenDef.Mode.MARKOV:
			var out: Array = []
			for i in def.count:
				out.append(generate_markov(def, rng))
			return out
		ContentGenDef.Mode.AFFIX:
			var out: Array = []
			for i in def.count:
				out.append(generate_affix(def, rng))
			return out
	return []

## 加权抽取一个条目（按 weight 概率）
static func pick_weighted(rng: RandomNumberGenerator, entries: Array[ContentEntryDef]) -> ContentEntryDef:
	var total := 0.0
	for e in entries:
		total += maxf(e.weight, 0.0)
	if total <= 0.0:
		return entries[0] if not entries.is_empty() else null
	var r := rng.randf() * total
	for e in entries:
		r -= maxf(e.weight, 0.0)
		if r <= 0.0:
			return e
	return entries[entries.size() - 1]

## 词缀组合（基础词 + 随机前缀/后缀；未配置时用默认表）
static func generate_affix(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var bases := def.affix_bases
	var prefixes := def.affix_prefixes
	var suffixes := def.affix_suffixes
	if bases.is_empty():
		bases = PackedStringArray(["长剑", "法杖", "弓", "盾牌", "护符", "戒指"])
	if prefixes.is_empty():
		prefixes = PackedStringArray(["锋利", "燃烧", "冰霜", "雷霆", "暗影", "神圣", "剧毒", "迅捷"])
	if suffixes.is_empty():
		suffixes = PackedStringArray(["之贪婪", "之毁灭", "之守护", "之祝福", "之诅咒", "之狂怒"])
	var out := bases[rng.randi_range(0, bases.size() - 1)]
	if not prefixes.is_empty() and rng.randf() < def.affix_prefix_chance:
		out = prefixes[rng.randi_range(0, prefixes.size() - 1)] + out
	if not suffixes.is_empty() and rng.randf() < def.affix_suffix_chance:
		out += suffixes[rng.randi_range(0, suffixes.size() - 1)]
	return out

## 名字合成（前缀 + 后缀；未配置时用默认音节表）
static func generate_name(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var prefixes := def.prefixes
	var suffixes := def.suffixes
	if prefixes.is_empty():
		prefixes = PackedStringArray(["银", "暗", "星", "风", "霜", "雷", "影", "雾", "血", "岩", "火", "冰"])
	if suffixes.is_empty():
		suffixes = PackedStringArray(["之刃", "之心", "之歌", "之眼", "之翼", "之语", "之环", "之王", "之印", "之冠"])
	return prefixes[rng.randi_range(0, prefixes.size() - 1)] + suffixes[rng.randi_range(0, suffixes.size() - 1)]

## 词级马尔可夫文本（语料按空格分词）
static func generate_markov(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var words: Array[String] = []
	for sentence in def.corpus:
		for w in String(sentence).split(" "):
			if not w.is_empty():
				words.append(w)
	if words.is_empty():
		return ""
	if def.markov_order >= words.size():
		return " ".join(words)
	var table := {}
	for i in range(words.size() - def.markov_order):
		var key := PackedStringArray()
		for j in def.markov_order:
			key.append(words[i + j])
		table.get_or_add(key, []).append(words[i + def.markov_order])
	var keys: Array = table.keys()
	var key: PackedStringArray = keys[rng.randi_range(0, keys.size() - 1)]
	var out: Array[String] = []
	for i in def.markov_words:
		var nexts: Variant = table.get(key)
		if nexts == null or (nexts as Array).is_empty():
			break
		var w: String = (nexts as Array)[rng.randi_range(0, nexts.size() - 1)]
		out.append(w)
		key = key.slice(1)
		key.append(w)
	return " ".join(out)

## —— 管线 ——

## 执行 PCGDef 管线，返回 output 字典（key → 生成结果）
static func generate(def: PCGDef, seed := 0) -> Dictionary:
	var base := seed if seed != 0 else def.seed
	var ctx := PCGContext.new()
	ctx.seed = base
	var slot := 0
	for g in def.generators:
		if g == null or not g.enabled:
			continue
		ctx.rng = make_rng(derive_seed(base, slot))
		g.generate(ctx)
		slot += 1
	return ctx.output

## —— 2D 网格算法实现 ——

static func _gen_noise_terrain(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	var noise: FastNoiseLite = def.noise_layer.build_noise(rng.seed) if def.noise_layer else null
	for y in grid.height:
		for x in grid.width:
			var solid := false
			if noise:
				solid = def.noise_layer.sample(noise, x, y) >= def.threshold
			else:
				solid = rng.randf() < def.threshold
			if solid:
				grid.set_cell(x, y, def.solid_value)

static func _gen_cellular(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	for i in grid.cells.size():
		grid.cells[i] = def.solid_value if rng.randf() < def.cave_ratio else def.empty_value
	for _pass in def.smooth_passes:
		var new_cells := grid.cells.duplicate()
		for y in grid.height:
			for x in grid.width:
				var walls := 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var ov := grid.get_cell(x + dx, y + dy, def.solid_value if def.border_solid else def.empty_value)
						if ov == def.solid_value:
							walls += 1
				new_cells[y * grid.width + x] = def.solid_value if walls >= 4 else def.empty_value
		grid.cells = new_cells

static func _gen_maze(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var dirs: Array[Vector2i] = [Vector2i(0, 2), Vector2i(2, 0), Vector2i(0, -2), Vector2i(-2, 0)]
	var in_tree := {}
	var added := {}
	var active: Array[Vector2i] = []
	var start := Vector2i(1, 1)
	grid.set_cell(start.x, start.y, def.empty_value)
	in_tree[_key(start)] = true
	for d in dirs:
		var nb := start + d
		if _inside(grid, nb) and not added.has(_key(nb)):
			active.append(nb)
			added[_key(nb)] = true
	while not active.is_empty():
		var idx := rng.randi_range(0, active.size() - 1)
		var node: Vector2i = active[idx]
		active.remove_at(idx)
		if in_tree.has(_key(node)):
			continue
		var connected: Array[Vector2i] = []
		for d in dirs:
			var nb := node + d
			if _inside(grid, nb) and in_tree.has(_key(nb)):
				connected.append(nb)
		if connected.is_empty():
			continue
		var target: Vector2i = connected[rng.randi_range(0, connected.size() - 1)]
		var mid := (node + target) / 2
		grid.set_cell(mid.x, mid.y, def.empty_value)
		grid.set_cell(node.x, node.y, def.empty_value)
		in_tree[_key(node)] = true
		for d in dirs:
			var nb2 := node + d
			if _inside(grid, nb2) and not added.has(_key(nb2)):
				active.append(nb2)
				added[_key(nb2)] = true
	if def.maze_loopiness > 0.0:
		var extra := int(grid.width * grid.height * def.maze_loopiness * 0.02)
		for i in extra:
			var x := rng.randi_range(1, grid.width - 2)
			var y := rng.randi_range(1, grid.height - 2)
			if grid.get_cell(x, y) != def.solid_value:
				continue
			var l := grid.get_cell(x - 1, y) == def.empty_value
			var r := grid.get_cell(x + 1, y) == def.empty_value
			var u := grid.get_cell(x, y - 1) == def.empty_value
			var d := grid.get_cell(x, y + 1) == def.empty_value
			if (l and r) or (u and d):
				grid.set_cell(x, y, def.empty_value)

static func _gen_random_walk(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var x := grid.width / 2 if def.walk_start_center else rng.randi_range(1, maxi(1, grid.width - 2))
	var y := grid.height / 2 if def.walk_start_center else rng.randi_range(1, maxi(1, grid.height - 2))
	grid.set_cell(x, y, def.empty_value)
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in def.walk_steps:
		var d: Vector2i = dirs[rng.randi_range(0, 3)]
		x = clampi(x + d.x, 1, grid.width - 2)
		y = clampi(y + d.y, 1, grid.height - 2)
		grid.set_cell(x, y, def.empty_value)

## Voronoi 地块地形：随机种子点划分区域，每区域采样一次噪声 → 整块实体/空地
static func _gen_voronoi(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	var seeds := PackedVector2Array()
	for i in def.voronoi_cells:
		seeds.append(Vector2(rng.randf() * def.width, rng.randf() * def.height))
	var noise: FastNoiseLite = def.noise_layer.build_noise(rng.seed) if def.noise_layer else null
	var cell_solid := {}
	for i in seeds.size():
		var h := def.noise_layer.sample(noise, seeds[i].x, seeds[i].y) if noise else rng.randf()
		cell_solid[i] = h >= def.threshold
	var owner := PackedInt32Array()
	owner.resize(grid.width * grid.height)
	for y in grid.height:
		for x in grid.width:
			var best := 0
			var best_d := INF
			for i in seeds.size():
				var d := seeds[i].distance_squared_to(Vector2(x, y))
				if d < best_d:
					best_d = d
					best = i
			owner[y * grid.width + x] = best
	for i in grid.cells.size():
		grid.cells[i] = def.solid_value if cell_solid[owner[i]] else def.empty_value
	if def.voronoi_border:
		for i in grid.cells.size():
			var x := i % grid.width
			var y := i / grid.width
			var si: int = owner[i]
			for d in _DIR4:
				var nx := x + d.x
				var ny := y + d.y
				if nx < 0 or nx >= grid.width or ny < 0 or ny >= grid.height:
					continue
				if owner[ny * grid.width + nx] != si:
					grid.cells[i] = def.solid_value
					break

class _BSPLeaf:
	var rect := Rect2i()
	var left: _BSPLeaf = null
	var right: _BSPLeaf = null
	var room := Rect2i()

static func _gen_bsp_rooms(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var root := _BSPLeaf.new()
	root.rect = Rect2i(0, 0, grid.width, grid.height)
	_split(root, def.bsp_depth, def, rng)
	_make_rooms(root, grid, def, rng)

static func _split(leaf: _BSPLeaf, depth: int, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if depth <= 0:
		return
	var w := leaf.rect.size.x
	var h := leaf.rect.size.y
	if w < def.room_min_size * 3 and h < def.room_min_size * 3:
		return
	var horizontal := false
	if h > w * 1.2:
		horizontal = true
	elif w > h * 1.2:
		horizontal = false
	else:
		horizontal = rng.randf() < 0.5
	var len := h if horizontal else w
	var min_part := def.room_min_size + 1
	var max_part := len - min_part
	if max_part <= min_part:
		return
	var pos := rng.randi_range(min_part, max_part)
	var left := _BSPLeaf.new()
	var right := _BSPLeaf.new()
	if horizontal:
		left.rect = Rect2i(leaf.rect.position, Vector2i(w, pos))
		right.rect = Rect2i(leaf.rect.position + Vector2i(0, pos), Vector2i(w, h - pos))
	else:
		left.rect = Rect2i(leaf.rect.position, Vector2i(pos, h))
		right.rect = Rect2i(leaf.rect.position + Vector2i(pos, 0), Vector2i(w - pos, h))
	leaf.left = left
	leaf.right = right
	_split(left, depth - 1, def, rng)
	_split(right, depth - 1, def, rng)

static func _make_rooms(leaf: _BSPLeaf, grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if leaf == null:
		return
	if leaf.left == null and leaf.right == null:
		var rw := mini(def.room_max_size, leaf.rect.size.x - 2)
		var rh := mini(def.room_max_size, leaf.rect.size.y - 2)
		rw = maxi(rng.randi_range(def.room_min_size, rw), 1)
		rh = maxi(rng.randi_range(def.room_min_size, rh), 1)
		var rx := leaf.rect.position.x + rng.randi_range(1, maxi(1, leaf.rect.size.x - rw - 1))
		var ry := leaf.rect.position.y + rng.randi_range(1, maxi(1, leaf.rect.size.y - rh - 1))
		leaf.room = Rect2i(rx, ry, rw, rh)
		_fill_room(grid, leaf.room, def)
	else:
		_make_rooms(leaf.left, grid, def, rng)
		_make_rooms(leaf.right, grid, def, rng)
		var ra := _find_room(leaf.left)
		var rb := _find_room(leaf.right)
		if ra.size != Vector2i.ZERO and rb.size != Vector2i.ZERO:
			_carve_path(grid, ra.get_center(), rb.get_center(), def, rng)

## 递归找子树内任意房间（内部节点自身没有 room）
static func _find_room(leaf: _BSPLeaf) -> Rect2i:
	if leaf == null:
		return Rect2i()
	if leaf.room.size != Vector2i.ZERO:
		return leaf.room
	var r := _find_room(leaf.left)
	if r.size != Vector2i.ZERO:
		return r
	return _find_room(leaf.right)

static func _fill_room(grid: GeneratedGrid, room: Rect2i, def: GridGenDef) -> void:
	for y in range(room.position.y, room.end.y):
		for x in range(room.position.x, room.end.x):
			grid.set_cell(x, y, def.empty_value)

static func _carve_path(grid: GeneratedGrid, a: Vector2i, b: Vector2i, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.5:
		_carve_line(grid, a, Vector2i(b.x, a.y), def)
		_carve_line(grid, Vector2i(b.x, a.y), b, def)
	else:
		_carve_line(grid, a, Vector2i(a.x, b.y), def)
		_carve_line(grid, Vector2i(a.x, b.y), b, def)

static func _carve_line(grid: GeneratedGrid, a: Vector2i, b: Vector2i, def: GridGenDef) -> void:
	var x := a.x
	var y := a.y
	while x != b.x:
		_carve_cell(grid, x, y, def)
		x += signi(b.x - a.x)
	while y != b.y:
		_carve_cell(grid, x, y, def)
		y += signi(b.y - a.y)
	_carve_cell(grid, b.x, b.y, def)

static func _carve_cell(grid: GeneratedGrid, x: int, y: int, def: GridGenDef) -> void:
	var hw := (def.corridor_width - 1) / 2
	var range_w := def.corridor_width - hw
	for dy in range(-hw, range_w):
		for dx in range(-hw, range_w):
			grid.set_cell(x + dx, y + dy, def.empty_value)

static func _key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]

static func _inside(grid: GeneratedGrid, p: Vector2i) -> bool:
	return p.x >= 0 and p.x < grid.width and p.y >= 0 and p.y < grid.height

## —— 散布算法实现 ——

static func _place_poisson(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var r := maxf(def.min_distance, 0.001)
	var cell := r / sqrt(2.0)
	var gw := ceili(def.region_size.x / cell)
	var gh := ceili(def.region_size.y / cell)
	var occupancy := {}
	var result := PackedVector2Array()
	var active := PackedVector2Array()
	var start := Vector2(rng.randf_range(0.0, def.region_size.x), rng.randf_range(0.0, def.region_size.y))
	result.append(start)
	active.append(start)
	occupancy[Vector2i(int(start.x / cell), int(start.y / cell))] = start
	while not active.is_empty() and result.size() < def.count:
		var idx := rng.randi_range(0, active.size() - 1)
		var center: Vector2 = active[idx]
		var placed := false
		for i in def.max_attempts:
			var ang := rng.randf() * TAU
			var dist := rng.randf_range(r, r * 2.0)
			var cand := center + Vector2(cos(ang), sin(ang)) * dist
			if cand.x < 0.0 or cand.y < 0.0 or cand.x >= def.region_size.x or cand.y >= def.region_size.y:
				continue
			var gi := Vector2i(int(cand.x / cell), int(cand.y / cell))
			if not _poisson_ok(occupancy, gw, gh, gi, cell, r, cand):
				continue
			result.append(cand)
			active.append(cand)
			occupancy[gi] = cand
			placed = true
			break
		if not placed:
			active.remove_at(idx)
	return result

static func _poisson_ok(occupancy: Dictionary, gw: int, gh: int, gi: Vector2i, cell: float, r: float, cand: Vector2) -> bool:
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var gx := gi.x + dx
			var gy := gi.y + dy
			if gx < 0 or gy < 0 or gx >= gw or gy >= gh:
				continue
			var other: Variant = occupancy.get(Vector2i(gx, gy))
			if other != null and (other as Vector2).distance_to(cand) < r:
				return false
	return true

static func _place_jitter_grid(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var cols := maxi(1, ceili(sqrt(float(def.count) * def.region_size.x / maxf(def.region_size.y, 1.0))))
	var rows := maxi(1, ceili(float(def.count) / float(cols)))
	var cw := def.region_size.x / cols
	var ch := def.region_size.y / rows
	var out := PackedVector2Array()
	for i in cols:
		for j in rows:
			if out.size() >= def.count:
				break
			var base := Vector2(i * cw, j * ch)
			var jx := (rng.randf() - 0.5) * cw * def.jitter
			var jy := (rng.randf() - 0.5) * ch * def.jitter
			out.append(base + Vector2(cw, ch) * 0.5 + Vector2(jx, jy))
	return out

static func _place_random(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in def.count:
		out.append(Vector2(rng.randf() * def.region_size.x, rng.randf() * def.region_size.y))
	return out

## —— 3D 网格算法实现 ——

## 3D 地表：每 (x,z) 列按 2D 噪声高度填充实体（offset 使分块世界全局连续）
static func _gen3d_surface(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var nseed := def.noise_seed if def.noise_seed != 0 else rng.seed
	var noise: FastNoiseLite = def.noise_layer.build_noise(nseed) if def.noise_layer else null
	var base_h := def.base_height * def.height
	for x in grid.width:
		for z in grid.depth:
			var h := base_h
			if noise:
				var n := def.noise_layer.sample(noise, x + def.offset.x, z + def.offset.z)
				h += (n - 0.5) * 2.0 * def.height_amp
			h = clampi(roundi(h), 1, grid.height - 1)
			for y in h:
				grid.set_cell(x, y, z, def.solid_value)

## 3D 细胞洞穴：26 邻域平滑（经典 Rogue 扩展，阈值 ~13）— 纯 C++ 实现（框架强依赖 PCGCave3D）
static func _gen3d_cave(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var native := FrameworkNative.get_native(&"PCGCave3D", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_grid_3d: 原生库 PCGCave3D 不可用! 请确认 Native/devecs.gdextension 已加载。")
		return
	var out: PackedInt32Array = native.call(&"generate",
		grid.width, grid.height, grid.depth,
		rng.seed, def.cave_ratio, def.smooth_passes, def.border_solid,
		def.solid_value, def.empty_value)
	if out.size() == grid.cells.size():
		grid.cells = out

## 3D 噪声洞穴：3D 噪声阈值挖空（offset 世界坐标 → 分块世界跨块连续）
static func _gen3d_noise_cave(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var nseed := def.noise_seed if def.noise_seed != 0 else rng.seed
	var noise: FastNoiseLite = def.noise_layer.build_noise(nseed) if def.noise_layer else null
	for z in grid.depth:
		for y in grid.height:
			for x in grid.width:
				var v := def.noise_layer.sample_3d(noise, x + def.offset.x, y, z + def.offset.z) if noise else 0.5
				grid.cells[grid._index(x, y, z)] = def.empty_value if v > def.cave_threshold else def.solid_value

## 3D WFC：六面 socket 瓦片约束坍缩（观测→传播→回溯→重试）
## fixed 支持 Vector3i(单格) / int(线性索引) / String("x,y,z") / AABB(区域) 键，value 为瓦片索引
static func _gen3d_wfc(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> void:
	var tiles := def.tile_set3d.tiles if def.tile_set3d else []
	var n := tiles.size()
	if n <= 0 or n >= 30:
		grid.fill(def.solid_value)
		return
	var cell_count := grid.width * grid.height * grid.depth
	# 纯 C++ 实现（框架强依赖共享原生库 PCGWFC3D，无 GDScript 回退）
	var native := FrameworkNative.get_native(&"PCGWFC3D", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_grid_3d: 原生库 PCGWFC3D 不可用! 请确认 Native/devecs.gdextension 已加载。")
		grid.fill(def.solid_value)
		return
	# socket 字符串 → 连续 id（注意：lambda 捕获变量不跨调用持久，必须用显式循环编号）
	var socket_map := {}
	var next_id := 0
	for t in tiles:
		for dir_i in 6:
			var s := t.socket(dir_i)
			if not socket_map.has(s):
				socket_map[s] = next_id
				next_id += 1
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		for dir_i in 6:
			sockets.append(int(socket_map[t.socket(dir_i)]))
		weights.append(t.weight)
	var fixed_idx := PackedInt32Array()
	var fixed_tile := PackedInt32Array()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is AABB:
			var bb := key as AABB
			for k in range(int(bb.position.z), int(bb.end.z)):
				for j in range(int(bb.position.y), int(bb.end.y)):
					for i in range(int(bb.position.x), int(bb.end.x)):
						if grid.in_bounds(i, j, k):
							fixed_idx.append(grid._index(i, j, k))
							fixed_tile.append(tile_idx)
			continue
		var idx := _wfc3d_fixed_index(grid, key)
		if idx >= 0:
			fixed_idx.append(idx)
			fixed_tile.append(tile_idx)
	var out: PackedInt32Array = native.call(&"generate",
		grid.width, grid.height, grid.depth, sockets, weights,
		def.wfc_max_backtracks, def.wfc_retries, 0,
		fixed_idx, fixed_tile, rng.seed)
	if out.size() != cell_count:
		push_error("PCGTool.generate_grid_3d: PCGWFC3D 生成失败(重试耗尽)! 请调整 wfc_retries 或瓦片约束。")
		grid.fill(def.solid_value)
		return
	grid.cells = out

## 降级随机填充后重新应用固定格（保证约束不丢失）
static func _apply_wfc_fixed_3d(grid: GeneratedGrid3D, def: Grid3DGenDef, fixed: Dictionary) -> void:
	var tiles := def.tile_set3d.tiles if def.tile_set3d else []
	var n := tiles.size()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is AABB:
			var bb := key as AABB
			for k in range(int(bb.position.z), int(bb.end.z)):
				for j in range(int(bb.position.y), int(bb.end.y)):
					for i in range(int(bb.position.x), int(bb.end.x)):
						grid.set_cell(i, j, k, tile_idx)
			continue
		var idx := _wfc3d_fixed_index(grid, key)
		if idx >= 0:
			grid.cells[idx] = tile_idx

## 解析 3D 固定格 key 为线性索引（支持 Vector3i / int / "x,y,z"）
static func _wfc3d_fixed_index(grid: GeneratedGrid3D, key) -> int:
	if key is Vector3i:
		return grid._index(key.x, key.y, key.z) if grid.in_bounds(key.x, key.y, key.z) else -1
	if key is int:
		return key if key >= 0 and key < grid.cells.size() else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 3:
			var x := int(parts[0])
			var y := int(parts[1])
			var z := int(parts[2])
			if grid.in_bounds(x, y, z):
				return grid._index(x, y, z)
	return -1


## —— WFC 算法实现（C++ 共享库 PCGWFC，参数解析后调用） ——

## fixed 支持 key 为 Vector2i / int(线性索引) / String("x,y")，value 为瓦片索引。
## 冲突时优先回溯到上一次观测重选；仍失败则整体重试（wfc_retries 次），全部失败报错。
static func _gen_wfc(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}, progress: Dictionary = {}) -> void:
	var tiles := def.tile_set.tiles if def.tile_set else []
	var n := tiles.size()
	if n <= 0 or n >= 30:
		grid.fill(def.solid_value)
		return
	var cell_count := grid.width * grid.height
	# 纯 C++ 实现（框架强依赖共享原生库 PCGWFC，无 GDScript 回退）
	var native := FrameworkNative.get_native(&"PCGWFC", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_grid: 原生库 PCGWFC 不可用! 请确认 Native/devecs.gdextension 已加载。")
		grid.fill(def.solid_value)
		return
	# socket 字符串 → 连续 id（注意：lambda 捕获变量不跨调用持久，必须用显式循环编号）
	var socket_map := {}
	var next_id := 0
	for t in tiles:
		for dir_i in 4:
			var s := t.socket(dir_i)
			if not socket_map.has(s):
				socket_map[s] = next_id
				next_id += 1
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		for dir_i in 4:
			sockets.append(int(socket_map[t.socket(dir_i)]))
		weights.append(t.weight)
	var fixed_idx := PackedInt32Array()
	var fixed_tile := PackedInt32Array()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is Rect2i:
			var r := key as Rect2i
			for ry in range(maxi(0, r.position.y), mini(grid.height, r.end.y)):
				for rx in range(maxi(0, r.position.x), mini(grid.width, r.end.x)):
					fixed_idx.append(ry * grid.width + rx)
					fixed_tile.append(tile_idx)
			continue
		var idx := _wfc_fixed_index(grid, key)
		if idx >= 0:
			fixed_idx.append(idx)
			fixed_tile.append(tile_idx)
	var out: PackedInt32Array = native.call(&"generate",
		grid.width, grid.height, sockets, weights,
		def.wfc_max_backtracks, def.wfc_retries, def.wfc_max_propagations,
		fixed_idx, fixed_tile, rng.seed, progress)
	if out.size() != cell_count:
		push_error("PCGTool.generate_grid: PCGWFC 生成失败(重试耗尽)! 请调整 wfc_retries 或瓦片约束。")
		grid.fill(def.solid_value)
		return
	grid.cells = out

## 降级随机填充后重新应用固定格（保证约束不丢失）
static func _apply_wfc_fixed_2d(grid: GeneratedGrid, def: GridGenDef, fixed: Dictionary) -> void:
	var tiles := def.tile_set.tiles if def.tile_set else []
	var n := tiles.size()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is Rect2i:
			var r := key as Rect2i
			for y in range(maxi(0, r.position.y), mini(grid.height, r.end.y)):
				for x in range(maxi(0, r.position.x), mini(grid.width, r.end.x)):
					grid.set_cell(x, y, tile_idx)
			continue
		var idx := _wfc_fixed_index(grid, key)
		if idx >= 0:
			grid.cells[idx] = tile_idx


## 解析固定格 key 为线性索引（支持 Vector2i / int / "x,y"）
static func _wfc_fixed_index(grid: GeneratedGrid, key) -> int:
	if key is Vector2i:
		return key.y * grid.width + key.x if grid.in_bounds(key.x, key.y) else -1
	if key is int:
		return key if key >= 0 and key < grid.width * grid.height else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 2:
			var x := int(parts[0])
			var y := int(parts[1])
			if grid.in_bounds(x, y):
				return y * grid.width + x
	return -1


const _DIR4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const _DIR8: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
]
const _DIR6_3D: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const _OPP3D: Array[int] = [1, 0, 3, 2, 5, 4]
