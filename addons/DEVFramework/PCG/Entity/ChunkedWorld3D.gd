class_name ChunkedWorld3D extends RefCounted
## 3D 分块世界 — 以 (seed, chunk坐标) 确定性懒加载体素 chunk
##
## 地表/噪声洞穴模式用世界坐标偏移采样噪声，相邻 chunk 连续；
## 细胞洞穴每 chunk 独立生成（洞穴本就不需跨块连续）。
## 同一 seed + 同一 (cx,cy,cz) 必然复现同一 chunk。

## chunk 边长（体素格）
var chunk_size := 8
## 世界基础种子
var seed_base := 0
## 每 chunk 的 3D 生成定义（尺寸会被 chunk_size 覆写，offset 设世界坐标）
var grid3d_def: Grid3DGenDef

var _chunks := {}  # Vector3i → GeneratedGrid3D
var _chunk_count := 0
## 玩家修改记录：{"x,y,z" → 值}，存档只存 seed + 改动
var _modified := {}


## 获取 chunk（不存在则按种子确定性生成并缓存）
func get_chunk(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var key := Vector3i(cx, cy, cz)
	if not _chunks.has(key):
		var g := _generate_chunk(cx, cy, cz)
		_chunks[key] = g
		_chunk_count += 1
	return _chunks[key]


## 已加载 chunk 列表（Vector3i → GeneratedGrid3D），供渲染/导航构建遍历
func get_loaded_chunks() -> Dictionary:
	return _chunks.duplicate()


func has_chunk(cx: int, cy: int, cz: int) -> bool:
	return _chunks.has(Vector3i(cx, cy, cz))


func get_chunk_count() -> int:
	return _chunk_count


## 手动放入已生成的 chunk（配合异步生成）
func add_chunk(cx: int, cy: int, cz: int, grid: GeneratedGrid3D) -> void:
	var key := Vector3i(cx, cy, cz)
	if _chunks.has(key):
		return
	_chunks[key] = grid
	_chunk_count += 1


## 后台线程生成 chunk（尺寸覆写 + 世界坐标偏移，与 get_chunk 同种子逻辑）
func generate_chunk_async(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var d: Grid3DGenDef = grid3d_def.duplicate() as Grid3DGenDef if grid3d_def else null
	if d == null:
		return GeneratedGrid3D.create(chunk_size, chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	d.depth = chunk_size
	if d.type == Grid3DGenDef.Type.NOISE_SURFACE or d.type == Grid3DGenDef.Type.CAVE_NOISE_3D:
		d.offset = Vector3i(cx * chunk_size, 0, cz * chunk_size)
		d.noise_seed = seed_base  # 所有 chunk 同一种子，offset 保证全局连续
	var seed := _chunk_seed(seed_base, cx, cy, cz)
	return await PCGTool.generate_grid_3d_async(d, seed)


## 批量后台生成一批 chunk 并实时回报整体进度，完成后全部缓存。
## chunk_keys: Array[Vector3i]；on_progress: func(p: float) 主线程每帧回调 0..1。
## 在调用前会预热 C++ 原生类(主线程)，worker 线程只调纯函数方法，保证线程安全。
func generate_chunks_async(chunk_keys: Array, on_progress: Callable = func(_p: float): pass) -> void:
	if chunk_keys.is_empty():
		return
	# 主线程预热 C++ 原生类(worker 线程只调纯函数方法, 保证线程安全)
	if grid3d_def and grid3d_def.type == Grid3DGenDef.Type.WFC_3D:
		FrameworkNative.get_native(&"PCGWFC3D", [&"generate"])
	var total := chunk_keys.size()
	var defs := []  # 与 chunk_keys 一一对应: {key, def, seed}
	for key in chunk_keys:
		var v3: Vector3i = key
		var d: Grid3DGenDef = grid3d_def.duplicate() as Grid3DGenDef if grid3d_def else null
		if d != null:
			d.width = chunk_size
			d.height = chunk_size
			d.depth = chunk_size
			if d.type == Grid3DGenDef.Type.NOISE_SURFACE or d.type == Grid3DGenDef.Type.CAVE_NOISE_3D:
				d.offset = Vector3i(v3.x * chunk_size, 0, v3.z * chunk_size)
				d.noise_seed = seed_base
		defs.append({"key": v3, "def": d, "seed": _chunk_seed(seed_base, v3.x, v3.y, v3.z)})
	# 并行后台生成(worker 线程只调 PCGTool.generate_grid_3d 纯函数)
	var results := {}
	var task_ids := []
	for item in defs:
		task_ids.append(WorkerThreadPool.add_task(_chunk_worker.bind(item, results)))
	# 主线程轮询完成数报进度
	while not WorkerThreadPool.is_task_completed(task_ids[task_ids.size() - 1]):
		var completed := 0
		for tid in task_ids:
			if WorkerThreadPool.is_task_completed(tid):
				completed += 1
		on_progress.call(float(completed) / float(total))
		await Engine.get_main_loop().process_frame
	on_progress.call(1.0)
	# 全部完成后缓存
	for key in results:
		var v3: Vector3i = key
		add_chunk(v3.x, v3.y, v3.z, results[key])


## worker 线程生成单个 chunk(接收预构建的 def 副本, 不碰 self)
func _chunk_worker(item: Dictionary, results: Dictionary) -> void:
	var d: Grid3DGenDef = item.def
	var g: GeneratedGrid3D
	if d == null:
		g = GeneratedGrid3D.create(chunk_size, chunk_size, chunk_size, 1)
	else:
		g = PCGTool.generate_grid_3d(d, PCGTool.make_rng(item.seed))
	results[item.key] = g


## 清空已缓存 chunk（重新取会按同一种子重建）
func clear_chunks() -> void:
	_chunks.clear()
	_chunk_count = 0


## 按世界坐标取体素值（自动懒生成所在 chunk；玩家修改优先）
func get_cell(wx: int, wy: int, wz: int, out_of_bounds := -1) -> int:
	var mkey := "%d,%d,%d" % [wx, wy, wz]
	if _modified.has(mkey):
		return _modified[mkey]
	var cx := floori(wx / float(chunk_size))
	var cy := floori(wy / float(chunk_size))
	var cz := floori(wz / float(chunk_size))
	var lx := wx - cx * chunk_size
	var ly := wy - cy * chunk_size
	var lz := wz - cz * chunk_size
	var g := get_chunk(cx, cy, cz)
	return g.get_cell(lx, ly, lz, out_of_bounds)


## 修改世界体素值（记录进增量存档）
func set_cell(wx: int, wy: int, wz: int, v: int) -> void:
	_modified["%d,%d,%d" % [wx, wy, wz]] = v


func get_modified() -> Dictionary:
	return _modified


func clear_modified() -> void:
	_modified.clear()


## —— 存档（seed + 增量改动） ——

func save_data() -> Dictionary:
	return {
		"seed": seed_base,
		"chunk_size": chunk_size,
		"grid_def": grid3d_def.save_data() if grid3d_def else "",
		"modified": _modified,
	}


func load_data(data: Dictionary) -> void:
	seed_base = int(data.get("seed", seed_base))
	chunk_size = int(data.get("chunk_size", chunk_size))
	var def_path: String = data.get("grid_def", "")
	if not def_path.is_empty():
		var d: Def = Grid3DGenDef.load_data(def_path)
		if d is Grid3DGenDef:
			grid3d_def = d as Grid3DGenDef
	_modified = data.get("modified", {})
	clear_chunks()


func _generate_chunk(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var d: Grid3DGenDef = grid3d_def.duplicate() as Grid3DGenDef if grid3d_def else null
	if d == null:
		return GeneratedGrid3D.create(chunk_size, chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	d.depth = chunk_size
	if d.type == Grid3DGenDef.Type.NOISE_SURFACE or d.type == Grid3DGenDef.Type.CAVE_NOISE_3D:
		d.offset = Vector3i(cx * chunk_size, 0, cz * chunk_size)
		d.noise_seed = seed_base  # 所有 chunk 同一种子，offset 保证全局连续
	var seed := _chunk_seed(seed_base, cx, cy, cz)
	return PCGTool.generate_grid_3d(d, PCGTool.make_rng(seed))


## chunk 坐标 → 确定性种子
static func _chunk_seed(base: int, cx: int, cy: int, cz: int) -> int:
	var h := (cx * 73856093) ^ (cy * 19349663) ^ (cz * 83492791)
	return (base ^ h) & 0x7FFFFFFF
