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
			# 岛屿掩膜：边缘压向海平面
			if def.island_strength > 0.0:
				h *= _island_falloff(x, y, def)
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

## —— 城市 ——

## 城市街区生成：道路网格分割街区，街区填充建筑/公园
static func generate_city(def: CityDef, rng: RandomNumberGenerator) -> GeneratedGrid:
	var grid := GeneratedGrid.create(def.width, def.height, def.empty_value)
	for x in def.width:
		if x % def.block_size < def.road_width:
			for y in def.height:
				grid.set_cell(x, y, def.road_value)
	for y in def.height:
		if y % def.block_size < def.road_width:
			for x in def.width:
				grid.set_cell(x, y, def.road_value)
	var blocks := Vector2i(ceili(def.width / float(def.block_size)), ceili(def.height / float(def.block_size)))
	var inner := def.block_size - def.road_width
	if inner <= def.building_gap * 2:
		return grid
	for by in blocks.y:
		for bx in blocks.x:
			var ox := bx * def.block_size + def.road_width
			var oy := by * def.block_size + def.road_width
			var is_park := rng.randf() < def.park_ratio
			var fill := def.park_value if is_park else def.building_value
			for y in range(oy + def.building_gap, mini(oy + inner - def.building_gap, def.height)):
				for x in range(ox + def.building_gap, mini(ox + inner - def.building_gap, def.width)):
					grid.set_cell(x, y, fill)
	return grid

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
	var socket_map := {}
	var next_id := 0
	var socket_ids := func(s: String) -> int:
		if not socket_map.has(s):
			socket_map[s] = next_id
			next_id += 1
		return socket_map[s]
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		for dir_i in 6:
			sockets.append(socket_ids.call(t.socket(dir_i)))
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
	var socket_map := {}
	var next_id := 0
	var socket_ids := func(s: String) -> int:
		if not socket_map.has(s):
			socket_map[s] = next_id
			next_id += 1
		return socket_map[s]
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		sockets.append(socket_ids.call(t.socket(0)))
		sockets.append(socket_ids.call(t.socket(1)))
		sockets.append(socket_ids.call(t.socket(2)))
		sockets.append(socket_ids.call(t.socket(3)))
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
