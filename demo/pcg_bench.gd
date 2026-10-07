class_name PcgModelBench
extends RefCounted

## PCG **造 / 存**流水线的无头基准（不依赖场景，也不依赖渲染）。
##
## 用法：
##   godot --headless --path <项目> --script res://demo/pcg_bench_headless.gd
## 或在编辑器 / 游戏进程里 eval_code：`PcgModelBench.run()`（结果用 get_logs 读）。
##
## 【为什么 headless 只测"造 / 存"】
## headless 的渲染驱动是 dummy：draw call、显存、三角面数恒为 0，测渲染毫无意义。
## 它的价值是把**纯 CPU 的那一半**测干净：
##   ① 各算子的 model.build() 耗时 —— 隔离掉生成器开销，看算子本身多重。
##   ② 经 PcgModelGenerator 按 chunk 切片 —— 全量切片耗时 / 吞吐（体素每秒）。
##   ③ 经 VoxelData + 异步编排的**端到端 chunk 就绪时间** —— 真实链路（含线程派发与回填）。
##   ④ `_volume` 常驻内存 —— 每个 Worker 生成器都会永久留一份密集体积。
##   ⑤ 确定性哈希 —— 同参数两次构建必须逐字节一致（否则"同 seed 同世界"不成立）。
##   ⑥ `build_calls == 1` —— Step 1 并发修复的无头证据（多 chunk 并发请求只 build 一次）。
##
## 每行形如 `[BENCH] key=value`，便于 `Select-String '\[BENCH\]'` 过滤掉引擎噪声。

## 交互式基准的场景见 demo/pcg_bench_demo.gd（那一侧才测渲染器数量与 draw call）。

const BENCH_HEADER := "=== PCG 造/存流水线基准（headless）==="


## 一个用于数 build 次数的探针模型（Step 1 的证据用）。
class CountingModel extends PcgModel:
	var build_calls := 0
	var reentered := false
	var _inside := false

	func build(grid_size: Vector3i) -> PackedInt32Array:
		build_calls += 1
		if _inside:
			reentered = true
		_inside = true
		var vol := PcgModel.empty_volume(grid_size)
		# 填几格，避免"空体积"让哈希失去区分度
		if vol.size() > 100:
			vol[0] = 1
			vol[50] = 2
			vol[vol.size() - 1] = 3
		_inside = false
		return vol


static func run() -> void:
	var lines := PackedStringArray()
	lines.append(BENCH_HEADER)
	lines.append("[BENCH] chunk_size=%d chunk_volume=%d" % [VoxelChunk.CHUNK_SIZE, VoxelChunk.CHUNK_VOLUME])

	for case in _cases():
		_bench_case(lines, case)

	_bench_build_calls(lines)

	print("\n".join(lines))


# ----------------------------------------------------------------------------
# 用例表
# ----------------------------------------------------------------------------

## 四个 PcgModel 算子各一档。网格按各自的"实际推荐尺寸"给（重叠式上限 24³）。
static func _cases() -> Array:
	return [
		{"name": "lsystem", "grid": Vector3i(32, 32, 32), "make": Callable(PcgModelBench, "_make_lsystem")},
		{"name": "cellular", "grid": Vector3i(64, 32, 64), "make": Callable(PcgModelBench, "_make_cellular")},
		{"name": "wfc", "grid": Vector3i(32, 48, 32), "make": Callable(PcgModelBench, "_make_wfc")},
		{"name": "wfc_overlap", "grid": Vector3i(24, 24, 24), "make": Callable(PcgModelBench, "_make_overlap")},
	]


static func _make_lsystem() -> PcgModel:
	var t := PcgLsystem.new()
	t.axiom = "F"
	t.rules = PackedStringArray(["F=FF[+F][-F][&F][^F]"])
	t.iterations = 3
	t.step = 1.6
	t.thickness = 0.8
	t.angle_degrees = 30.0
	t.material_id = 1
	return t


static func _make_cellular() -> PcgModel:
	var c := PcgCellular.new()
	c.fill_ratio = 0.50
	c.iterations = 4
	c.birth_limit = 13
	c.death_limit = 12
	c.seed = 20261007
	c.shell_is_solid = false
	c.material_id = 1
	return c


static func _make_wfc() -> PcgModel:
	var tile := Vector3i(4, 4, 4)
	var open := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "air", "air", "air"], 2.0, 0,
			func(_x, _y, _z): return false)
	var rock := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "rock", "air", "air"], 1.0, 3,
			func(_x, _y, _z): return true)
	var floor_t := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "rock", "air", "air"], 1.5, 1,
			func(_x, y, _z): return y == 0)
	var pillar := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "air", "air", "air"], 0.8, 2,
			func(x, _y, z): return x >= 1 and x <= 2 and z >= 1 and z <= 2)
	var w := PcgWfc.new()
	w.tiles = [open, rock, floor_t, pillar]
	w.seed = 20261007
	w.max_retries = 12
	return w


static func _make_overlap() -> PcgModel:
	var sample_size := Vector3i(8, 8, 8)
	var o := PcgWfcOverlap.new()
	o.sample = PcgSceneKit.overlap_sample(sample_size)
	o.sample_size = sample_size
	o.pattern_size = 3
	o.seed = 20261007
	o.max_retries = 8
	return o


# ----------------------------------------------------------------------------
# 单个用例
# ----------------------------------------------------------------------------

static func _bench_case(lines: PackedStringArray, case: Dictionary) -> void:
	var name: String = case["name"]
	var grid: Vector3i = case["grid"]
	var cells := grid.x * grid.y * grid.z
	var span := _span(grid)
	var chunk_count := span.x * span.y * span.z
	lines.append("[BENCH] --- %s grid=%s cells=%d chunks=%d ---" % [name, str(grid), cells, chunk_count])

	# ① 算子本身：直接 build() 一次（不经生成器）
	var t0 := Time.get_ticks_usec()
	var model := (case["make"] as Callable).call() as PcgModel
	var t_new := _us(t0)
	t0 = Time.get_ticks_usec()
	var volume: PackedInt32Array = model.build(grid)
	var t_model := _us(t0)
	lines.append("[BENCH] %s.model_build_ms=%.1f  (new=%.3fms)" % [name, t_model, t_new])
	lines.append("[BENCH] %s.volume_bytes=%d" % [name, volume.size() * 4])

	# ② 确定性：同参数再建一次，逐字节比对（哈希）
	var again: PackedInt32Array = (case["make"] as Callable).call().build(grid)
	lines.append("[BENCH] %s.deterministic=%s hash=%d" % [name, str(again == volume), hash(volume)])

	# ③ 经生成器切片：全量 chunk 一次跑完（单线程，测纯吞吐）
	var gen := PcgModelGenerator.new()
	gen.model = (case["make"] as Callable).call() as PcgModel
	gen.set_grid_size(grid)
	var total := 0
	t0 = Time.get_ticks_usec()
	for cz in span.z:
		for cy in span.y:
			for cx in span.x:
				var buf: PackedInt32Array = gen.generate(Vector3i(cx, cy, cz))
				total += buf.size()
	var t_slice := _us(t0)
	var cps := 0.0 if t_slice <= 0.0 else float(cells) / (t_slice / 1000.0)
	lines.append("[BENCH] %s.slice_total_ms=%.1f  per_chunk_ms=%.2f  cells_per_sec=%.0f  sliced_cells=%d"
			% [name, t_slice, t_slice / float(chunk_count), cps, total])
	lines.append("[BENCH] %s.volume_mem_kb=%.0f" % [name, gen._volume.size() * 4 / 1024.0])

	# ④ 端到端：VoxelData + 异步编排（线程派发 + 主线程回填），直到全部 chunk 就绪
	var e2e := _e2e(case["make"] as Callable, grid)
	lines.append("[BENCH] %s.e2e_ms=%.1f  e2e_chunks=%d/%d  ok=%s"
			% [name, e2e["ms"], e2e["accepted"], chunk_count, str(e2e["accepted"] == chunk_count)])


# ----------------------------------------------------------------------------
# 端到端（真实链路）
# ----------------------------------------------------------------------------

## 造一个 VoxelData（有界 + 生成器），把所有 chunk 异步请求出去，
## 然后按"轮询就绪 → 回填"跑到全部就绪；返回耗时与就绪数。
##
## 这里刻意**不经过 VoxelRenderer**：渲染器会把 chunk 切成 mesh 再算绘制，
## 那是另一回事；本项只量"数据从请求到落地"这一段，与 GPU 完全无关。
static func _e2e(make: Callable, grid: Vector3i) -> Dictionary:
	var data := VoxelData.new()
	var mat := VoxelMaterial.new()
	mat.id = 1
	data.add_material(mat)
	var gen := PcgModelGenerator.new()
	gen.model = make.call() as PcgModel
	# 与 PcgSceneKit.add_model 同序：先挂生成器（会自动补内存流），再定 grid_size
	data.generator = gen
	data.grid_size = grid

	var span := _span(grid)
	var keys: Array[Vector3i] = []
	for cz in span.z:
		for cy in span.y:
			for cx in span.x:
				keys.append(Vector3i(cx, cy, cz))

	var t0 := Time.get_ticks_usec()
	for ck in keys:
		data.request_chunk_async(ck, 0)
	var accepted := 0
	var deadline := Time.get_ticks_msec() + 30000
	while accepted < keys.size() and Time.get_ticks_msec() < deadline:
		var ready := data.poll_all_ready(256)
		if ready.is_empty():
			OS.delay_msec(1)
			continue
		for r in ready:
			var ck: Vector3i = r[1]
			var buf: PackedInt32Array = r[2]
			var lod: int = r[0]
			data.accept_chunk_buffer(ck, buf, lod)
			accepted += 1
	return {"ms": _us(t0), "accepted": accepted}


# ----------------------------------------------------------------------------
# Step 1 证据：并发请求多个 chunk 时只 build 一次
# ----------------------------------------------------------------------------

static func _bench_build_calls(lines: PackedStringArray) -> void:
	# 64 宽 = x 方向 2 个 chunk，两个 key 分属不同 chunk → 无锁时两个 worker 都会走到 _ensure_volume
	var probe := CountingModel.new()
	var gen := PcgModelGenerator.new()
	gen.model = probe
	gen.set_grid_size(Vector3i(64, 32, 32))
	var ids: Array[int] = []
	for i in 2:
		var ck := Vector3i(i, 0, 0)
		ids.append(WorkerThreadPool.add_task(func() -> void: gen.generate(ck)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	lines.append("[BENCH] concurrent.build_calls=%d (期望 1)  reentered=%s"
			% [probe.build_calls, str(probe.reentered)])


# ----------------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------------

static func _span(grid: Vector3i) -> Vector3i:
	var c := VoxelChunk.CHUNK_SIZE
	return Vector3i(
		(grid.x + c - 1) / c,
		(grid.y + c - 1) / c,
		(grid.z + c - 1) / c)


static func _us(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0