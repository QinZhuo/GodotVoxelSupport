class_name ChunkedWorld extends RefCounted
## 分块世界 — 以 (base_seed, chunk坐标) 确定性懒加载每个 chunk
##
## 同一 seed_base + 同一 (cx, cy) 必然生成同一 chunk，天然支持无限世界 / 存档复现。
## 用法:
##   var world := ChunkedWorld.new()
##   world.seed_base = 20260811
##   world.grid_def = grid_gen_def          # 任意 GridGenDef，chunk 尺寸自动按 chunk_size 覆写
##   var g := world.get_chunk(3, -2)        # 懒生成
##   var v := world.get_cell(50, 30)        # 直接按世界坐标取值

## chunk 边长（像素格）
var chunk_size := 16
## 世界基础种子
var seed_base := 0
## 每 chunk 的生成定义（width/height 会被 chunk_size 覆写，不污染原 Def）
var grid_def: GridGenDef
var _chunks := {}  # Vector2i → GeneratedGrid
var _chunk_count := 0
## 玩家修改记录：{"x,y" → 值}，存档只存 seed + 改动，加载后重新生成并应用
var _modified := {}


## 获取 chunk（不存在则按种子确定性生成并缓存）
func get_chunk(cx: int, cy: int) -> GeneratedGrid:
	var key := Vector2i(cx, cy)
	if not _chunks.has(key):
		var g := _generate_chunk(cx, cy)
		_chunks[key] = g
		_chunk_count += 1
	return _chunks[key]

## 手动放入已生成的 chunk（配合异步后台生成使用）
func add_chunk(cx: int, cy: int, grid: GeneratedGrid) -> void:
	var key := Vector2i(cx, cy)
	if _chunks.has(key):
		return
	_chunks[key] = grid
	_chunk_count += 1

## 已加载 chunk 列表（Vector2i → GeneratedGrid），供渲染/导航构建遍历
func get_loaded_chunks() -> Dictionary:
	return _chunks.duplicate()

## 后台线程生成 chunk（按 chunk_size 覆写定义尺寸，与 _generate_chunk 同种子逻辑）
func generate_chunk_async(cx: int, cy: int) -> GeneratedGrid:
	var d: GridGenDef = grid_def.duplicate() as GridGenDef if grid_def else null
	if d == null:
		return GeneratedGrid.create(chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	var seed := _chunk_seed(seed_base, cx, cy)
	return await PCGTool.generate_grid_async(d, seed)

## 批量后台生成一批 chunk 并实时回报整体进度，完成后全部缓存。
## chunk_keys: Array[Vector2i]；on_progress: func(p: float) 主线程每帧回调 0..1。
## 调用前主线程预热 C++ 原生类，worker 线程只调纯函数方法，保证线程安全。
func generate_chunks_async(chunk_keys: Array, on_progress: Callable = func(_p: float): pass) -> void:
	if chunk_keys.is_empty():
		return
	# 主线程预热 C++ 原生类(worker 线程只调纯函数方法)
	if grid_def and grid_def.type == GridGenDef.Type.WFC:
		FrameworkNative.get_native(&"PCGWFC", [&"generate"])
	var total := chunk_keys.size()
	var defs := []  # 与 chunk_keys 一一对应: {key, def, seed}
	for key in chunk_keys:
		var v2: Vector2i = key
		var d: GridGenDef = grid_def.duplicate() as GridGenDef if grid_def else null
		if d != null:
			d.width = chunk_size
			d.height = chunk_size
		defs.append({"key": v2, "def": d, "seed": _chunk_seed(seed_base, v2.x, v2.y)})
	# 并行后台生成(worker 线程只调 PCGTool.generate_grid 纯函数)
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
		var v2: Vector2i = key
		add_chunk(v2.x, v2.y, results[key])


## worker 线程生成单个 chunk(接收预构建的 def 副本, 不碰 self)
func _chunk_worker(item: Dictionary, results: Dictionary) -> void:
	var d: GridGenDef = item.def
	var g: GeneratedGrid
	if d == null:
		g = GeneratedGrid.create(chunk_size, chunk_size, 1)
	else:
		g = PCGTool.generate_grid(d, PCGTool.make_rng(item.seed))
	results[item.key] = g

## 是否已生成过该 chunk
func has_chunk(cx: int, cy: int) -> bool:
	return _chunks.has(Vector2i(cx, cy))

## 已生成的 chunk 数量
func get_chunk_count() -> int:
	return _chunk_count

## 清空已缓存 chunk（内存释放，重新 get 会按同一种子重建）
func clear_chunks() -> void:
	_chunks.clear()
	_chunk_count = 0

## 按世界坐标取格值（越界返回 out_of_bounds；自动懒生成所在 chunk；玩家修改优先）
func get_cell(world_x: int, world_y: int, out_of_bounds := -1) -> int:
	var mkey := "%d,%d" % [world_x, world_y]
	if _modified.has(mkey):
		return _modified[mkey]
	var cx := floori(world_x / float(chunk_size))
	var cy := floori(world_y / float(chunk_size))
	var lx := world_x - cx * chunk_size
	var ly := world_y - cy * chunk_size
	var g := get_chunk(cx, cy)
	return g.get_cell(lx, ly, out_of_bounds)


## 修改世界格值（记录进增量存档，下次读档后重新生成并应用）
func set_cell(world_x: int, world_y: int, v: int) -> void:
	_modified["%d,%d" % [world_x, world_y]] = v


## 全部玩家改动（Dictionary "x,y" → int）
func get_modified() -> Dictionary:
	return _modified


func clear_modified() -> void:
	_modified.clear()


## —— 存档（seed + 增量改动，世界本身由 seed 确定性重建） ——

func save_data() -> Dictionary:
	return {
		"seed": seed_base,
		"chunk_size": chunk_size,
		"grid_def": grid_def.save_data() if grid_def else "",
		"modified": _modified,
	}


func load_data(data: Dictionary) -> void:
	seed_base = int(data.get("seed", seed_base))
	chunk_size = int(data.get("chunk_size", chunk_size))
	var def_path: String = data.get("grid_def", "")
	if not def_path.is_empty():
		var d: Def = GridGenDef.load_data(def_path)
		if d is GridGenDef:
			grid_def = d as GridGenDef
	_modified = data.get("modified", {})
	clear_chunks()

func _generate_chunk(cx: int, cy: int) -> GeneratedGrid:
	var d: GridGenDef = grid_def.duplicate() as GridGenDef if grid_def else null
	if d == null:
		return GeneratedGrid.create(chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	var seed := _chunk_seed(seed_base, cx, cy)
	return PCGTool.generate_grid(d, PCGTool.make_rng(seed))

## chunk 坐标 → 确定性种子（大质数混合，不同坐标不同种子）
static func _chunk_seed(base: int, cx: int, cy: int) -> int:
	var h := (cx * 73856093) ^ (cy * 19349663)
	return (base ^ h) & 0x7FFFFFFF
