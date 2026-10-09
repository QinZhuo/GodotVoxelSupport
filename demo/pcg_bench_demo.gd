extends Node3D

## 交互式性能基准：**单场景里 N 个 VoxelRenderer** 的代价曲线（N ∈ 25 / 100 / 400 / 900）。
##
## 【这个场景要回答什么】
## 之前的 PCG demo 都只有 4~14 个渲染器，跑得再好也不能说明规模问题。本场景把渲染器
## 数量本身当作唯一变量，用一条可交互的曲线找出"主线程先到顶"还是"draw call 先到顶"。
##
## 【为什么把阵列压成固定面积，而不是固定间距】
## 每个 VoxelRenderer 每帧都有一段**与 N 无关、只与 view_distance 相关**的固定开销：
##   `_process` → `infinite_layer.process_streaming()` → `poll_all_ready()` → `check_origin_shift()`，
##   以及每 8 帧一次、半径 `view_distance / chunk_size_world` 的距离扫描。
## 若随 N 一起放大间距，`view_distance` 就得一起放大，于是"每渲染器固定开销"也一起变大——
## 两个变量纠缠在一起，测出来的曲线无法归因。
## 故本场景让阵列**始终占据约 68×68 世界单位**（`FOOTPRINT`），间距 = FOOTPRINT / ⌈√N⌉：
## N 小则稀疏、N 大则重叠成密排块。`view_distance` 因此可以全档恒定，"渲染器数量"
## 就是唯一的自变量。代价是 N 大时几何互相穿插——但**几何量恒定**（每模型都 32³ = 1 chunk）
## 正是我们要的：把 draw call 数与几何复杂度解耦。
##
## 【测法：T_load 与 F_steady 永不混谈】
##   进入 LOADING：记录起始时刻，丢弃帧样本。
##   就绪判据：已建 chunk 数 == 期望值，且**连续 30 帧不变**（不按固定帧数——
##     900 渲染器时整段可能都还在构建期，按固定帧数测到的是加载曲线而非稳态）。
##   进入 STEADY：记下 `T_load`，清空样本重新采样 → 帧时 avg / median / p99。
##   30s 仍未就绪 → 如实标 TIMEOUT，不假装有稳态数字。
##
## 【键位】
##   1/2/3/4 = 切换到 N = 25 / 100 / 400 / 900
##   V = 循环 visibility_mode（FULL → FRUSTUM → STREAMING）
##   H = 开关 DirectionalLight3D 阴影
##   L = 循环 lod_count（1 → 2 → 3）
##   R = 重建当前档位（重新开始计时）
##
## 【注意】程序化有界数据的流式驱动**恒开**（`data.node != null` 即走 `infinite_layer.process_streaming`，
## 与 visibility_mode 无关），所以 V 切 FULL/FRUSTUM 不会让远处的模型"免于加载"——
## 它改变的是"已加载 chunk 的可见性筛选"，不是"是否加载"。这一点正是本场景想让人亲眼看到。

## 体素世界尺度（32³ 模型 = 6.4 世界单位）
@export var voxel_scale: float = 0.2
## 加载半径。阵列被压在 FOOTPRINT 见方内，故全档恒定即可（见文件头）。
@export var view_distance: float = 118.0
## 阵列占地的边长（世界单位）。恒定 → 隔离出"渲染器数量"这一个变量。
@export var footprint: float = 68.0

const TIERS: Array[int] = [25, 100, 400, 900]
const TIER_NAMES: Array[String] = ["25 (5×5)", "100 (10×10)", "400 (20×20)", "900 (30×30)"]
const GRID := Vector3i(32, 32, 32)

## 帧时采样窗口（约 4 秒 @60fps；p99 需要足够样本才稳定）
const FRAME_WINDOW := 240
## 稳态判定：已建 chunk 数连续多少帧不变
const STABLE_FRAMES := 30
## 加载超时（毫秒）——超时后如实标 TIMEOUT。
## 实测单个 32³ 渲染器的 LOD0 建网格约 120ms（调试版 + 调试器挂载），于是 N=400 约 48s、
## N=900 约 108s。取 180s 才能让四档全部跑到 STEADY、打出各自的 T_load 与 F_steady。
const LOAD_TIMEOUT_MS := 180000
## HUD 刷新间隔（秒）
const HUD_INTERVAL := 0.5

enum RunState { LOADING, STEADY, TIMEOUT }

var _tier := 0
var _state: RunState = RunState.LOADING
var _container: Node3D
var _models: Array[Node3D] = []
## 所有模型共用的**同一个** QVoxelModel：隔离"模型构建"这个变量，
## 同时让那份稀疏体积只留 1 份（否则 900 份 × 128 KiB）。
var _model: QVoxelModel
var _materials: Array = []

var _camera: Camera3D
var _light: DirectionalLight3D
var _hud: Label

var _run_start_ms := 0
var _t_load_ms := -1
var _frames: Array[float] = []
var _stable_count := 0
var _last_built := -1
var _hud_timer := 0.0

var _prev := {}


func _ready() -> void:
	_setup_environment()
	_build_model()
	_rebuild()


# ----------------------------------------------------------------------------
# 装配
# ----------------------------------------------------------------------------

func _setup_environment() -> void:
	_light = get_node_or_null("DirectionalLight3D") as DirectionalLight3D

	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 60.0
	_camera.far = 600.0
	_camera.global_position = Vector3(0.0, 42.0, 58.0)
	_camera.look_at(Vector3(0.0, 3.0, 0.0), Vector3.UP)

	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(10, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)


## 唯一一份 QVoxelModel：模型是 4³ 图块拼出的多层遗迹（确定性、快、1 chunk）。
func _build_model() -> void:
	var tile := Vector3i(4, 4, 4)
	var open := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "air", "air", "air"], 2.0, 0,
			func(_x, _y, _z): return false)
	var rock := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "rock", "air", "air"], 1.0, 3,
			func(_x, _y, _z): return true)
	var floor_t := PcgSceneKit.wfc_tile(tile, ["air", "air", "air", "rock", "air", "air"], 1.5, 1,
			func(_x, y, _z): return y == 0)
	var pillar := PcgSceneKit.wfc_tile(tile, ["air", "air", "rock", "air", "air", "air"], 0.8, 2,
			func(x, _y, z): return x >= 1 and x <= 2 and z >= 1 and z <= 2)

	var wfc := PcgWfc.new()
	wfc.tiles = [open, rock, floor_t, pillar]
	wfc.seed = 20261007
	wfc.max_retries = 12

	_model = QVoxelModel.of_source(wfc, GRID)
	_materials = PcgSceneKit.materials([
		[1, Color(0.55, 0.45, 0.3), 0.9],
		[2, Color(0.75, 0.7, 0.6), 0.95],
		[3, Color(0.42, 0.4, 0.4), 0.95],
	])


## 按当前档位重建整个阵列，并重新开始计时。
func _rebuild() -> void:
	if _container != null and is_instance_valid(_container):
		# 只 queue_free，**不要**先 remove_child：remove_child 会让渲染器立刻离开场景树，
		# 而它本帧已排入的 _process 仍会执行（Godot 在帧首收集处理列表），其中的
		# global_position 在树外取值 → 每次换档刷 500 条 "!is_inside_tree()" 报错。
		# 留在树内到帧末释放即可，没有任何副作用。
		for c in _container.get_children():
			c.queue_free()
	else:
		_container = Node3D.new()
		_container.name = "Models"
		add_child(_container)

	_models.clear()
	var count: int = TIERS[_tier]
	var rows := int(ceil(sqrt(float(count))))
	var spacing := footprint / float(rows)
	var half := (rows - 1) * 0.5 * spacing
	var built := 0
	for r in rows:
		for c in rows:
			if built >= count:
				break
			var pos := Vector3(-half + c * spacing, 0.0, -half + r * spacing)
			var node := PcgSceneKit.add_model(_container, "R_%d_%d" % [r, c], pos,
					_model, GRID, _materials, false, voxel_scale)
			(node as VoxelRenderer).view_distance = view_distance
			_models.append(node)
			built += 1

	_begin_run()


func _begin_run() -> void:
	_state = RunState.LOADING
	_run_start_ms = Time.get_ticks_msec()
	_t_load_ms = -1
	_frames.clear()
	_stable_count = 0
	_last_built = -1
	print("[PCG基准] N=%d（%s）开始构建，view_distance=%.0f" % [TIERS[_tier], TIER_NAMES[_tier], view_distance])


# ----------------------------------------------------------------------------
# 每帧：计时 + 收敛判定
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	_frames.append(delta)
	if _frames.size() > FRAME_WINDOW:
		_frames.remove_at(0)

	match _state:
		RunState.LOADING:
			_poll_loading()
		RunState.STEADY:
			pass

	_handle_input()

	_hud_timer += delta
	if _hud_timer >= HUD_INTERVAL:
		_hud_timer = 0.0
		_update_hud()


func _poll_loading() -> void:
	var b := _built_chunks()
	if b == _expected_chunks() and b == _last_built:
		_stable_count += 1
		if _stable_count >= STABLE_FRAMES:
			_t_load_ms = Time.get_ticks_msec() - _run_start_ms
			_state = RunState.STEADY
			# 加载期的帧不是稳态帧，不能混进 avg/median/p99
			_frames.clear()
			print("[PCG基准] N=%d 收敛，T_load=%.0fms" % [TIERS[_tier], _t_load_ms])
	else:
		_stable_count = 0
	_last_built = b

	if _state == RunState.LOADING and Time.get_ticks_msec() - _run_start_ms > LOAD_TIMEOUT_MS:
		_state = RunState.TIMEOUT
		print("[PCG基准] N=%d 超过 %ds 仍未收敛（已建 %d / 期望 %d）"
				% [TIERS[_tier], LOAD_TIMEOUT_MS / 1000, b, _expected_chunks()])


# ----------------------------------------------------------------------------
# 键位
# ----------------------------------------------------------------------------

func _handle_input() -> void:
	if _pressed(KEY_1):
		_set_tier(0)
	if _pressed(KEY_2):
		_set_tier(1)
	if _pressed(KEY_3):
		_set_tier(2)
	if _pressed(KEY_4):
		_set_tier(3)
	if _pressed(KEY_V):
		_cycle_visibility()
	if _pressed(KEY_H):
		if _light != null:
			_light.shadow_enabled = not _light.shadow_enabled
	if _pressed(KEY_L):
		_cycle_lod()
	if _pressed(KEY_R):
		_rebuild()


func _pressed(key: int) -> bool:
	var down := Input.is_key_pressed(key)
	var was: bool = _prev.get(key, false)
	_prev[key] = down
	return down and not was


func _set_tier(idx: int) -> void:
	if idx == _tier:
		return
	_tier = idx
	_rebuild()


## 切换可见性模式。注意：对有界程序化数据，切 FULL 不会让远处模型"免于加载"
## （流式驱动恒开），它改变的是已加载 chunk 的可见性筛选 → 切完必须重新等收敛再读稳态数字。
func _cycle_visibility() -> void:
	var modes: Array[int] = [VoxelRenderer.VisibilityMode.FULL, VoxelRenderer.VisibilityMode.FRUSTUM,
			VoxelRenderer.VisibilityMode.STREAMING]
	var cur: int = modes[0]
	if not _models.is_empty():
		cur = (_models[0] as VoxelRenderer).visibility_mode
	var next: int = modes[(modes.find(cur) + 1) % modes.size()]
	for m in _models:
		(m as VoxelRenderer).visibility_mode = next
	_begin_run()


## 切换 LOD 层数。lod_count > 1 时，超出 LOD0 带的 chunk 会被换成粗层大块 mesh，
## 画面与三角面数都会变——同样需要重新等收敛。
func _cycle_lod() -> void:
	var cur := 1
	if not _models.is_empty():
		cur = (_models[0] as VoxelRenderer).lod_count
	var next := 1 if cur >= 3 else cur + 1
	for m in _models:
		(m as VoxelRenderer).lod_count = next
	_begin_run()


# ----------------------------------------------------------------------------
# 统计
# ----------------------------------------------------------------------------

func _expected_chunks() -> int:
	# 32³ 模型 = 1×1×1 chunk
	return _models.size()


func _built_chunks() -> int:
	var n := 0
	for m in _models:
		var d: QVoxelSource = (m as VoxelRenderer).data
		if d != null and d.is_chunk_loaded(Vector3i.ZERO):
			n += 1
	return n


func _mesh_nodes() -> int:
	var n := 0
	for m in _models:
		for c in (m as VoxelRenderer).get_children():
			if c is MeshInstance3D:
				n += 1
	return n


func _snapshot_readers() -> int:
	var n := 0
	for m in _models:
		var d: QVoxelSource = (m as VoxelRenderer).data
		if d != null:
			n += d._snapshot_readers
	return n


## 从当前帧样本里算 avg / median / p99（毫秒）。
func _frame_stats() -> Array:
	if _frames.is_empty():
		return [0.0, 0.0, 0.0]
	var sorted := _frames.duplicate()
	sorted.sort()
	var total := 0.0
	for f in _frames:
		total += f
	var avg := total / float(_frames.size())
	var median: float = sorted[sorted.size() / 2]
	var p99: float = sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)]
	return [avg * 1000.0, median * 1000.0, p99 * 1000.0]


# ----------------------------------------------------------------------------
# HUD
# ----------------------------------------------------------------------------

func _update_hud() -> void:
	if _hud == null:
		return
	var fs := _frame_stats()
	var draw := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var mode_names := ["FULL", "FRUSTUM", "STREAMING"]
	var first: VoxelRenderer = _models[0] as VoxelRenderer if not _models.is_empty() else null
	var mode: String = mode_names[first.visibility_mode] if first != null else "?"
	var lod: int = first.lod_count if first != null else 1

	var head := "===== PCG 渲染器规模基准 ====="
	match _state:
		RunState.LOADING:
			head = "===== LOADING… %.1fs（已建 %d / 期望 %d）=====" % [
					(Time.get_ticks_msec() - _run_start_ms) / 1000.0, _built_chunks(), _expected_chunks()]
		RunState.STEADY:
			head = "===== STEADY  T_load %.0f ms =====" % _t_load_ms
		RunState.TIMEOUT:
			head = "===== TIMEOUT  %ds 未收敛（已建 %d / 期望 %d）=====" % [
					LOAD_TIMEOUT_MS / 1000, _built_chunks(), _expected_chunks()]

	_hud.text = """%s
N=%d  %s   visibility=%s   lod_count=%d   阴影=%s
F_steady(avg / median / p99): %.2f / %.2f / %.2f ms
FPS(引擎自报): %d    draw calls: %d
TIME_PROCESS: %.2f ms    primitives: %d
节点: %d    资源: %d    静态内存: %.1f MB    纹理: %.1f MB
已建 chunk: %d / %d    mesh 节点: %d    快照读者: %d

[1/2/3/4] 换 N    [V] 可见性    [H] 阴影    [L] lod_count    [R] 重建
""" % [
		head, _models.size(), TIER_NAMES[_tier], mode, lod, str(_light.shadow_enabled if _light else false),
		fs[0], fs[1], fs[2],
		Engine.get_frames_per_second(), draw,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		_built_chunks(), _expected_chunks(), _mesh_nodes(), _snapshot_readers(),
	]