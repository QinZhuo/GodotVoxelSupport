extends Node
## 体素水流循环模拟演示（大型复杂场景）
## 展示：高架水源 → 第一级瀑布 → 蓄水池A → 溢流通道 → 蓄水池B → 第二级瀑布 → 底部收集池 → 循环
## 使用元胞自动机式的水模拟规则（重力下落、下坡流动、落差溢流）
## 渲染：VoxelRenderer + 动态 VoxelDataResource + HUD 性能监控

## 体素缩放（单个体素世界边长）
@export var voxel_scale: float = 0.3

## 网格尺寸（体素个数）
const GRID_X := 40
const GRID_Y := 20
const GRID_Z := 16

## 材质 ID
const MAT_SOLID := 1      # 地形/容器壁（实心）
const MAT_WATER := 2      # 水
const MAT_EMISSIVE := 3   # 发光装饰

## 每秒生成的水滴数（受上限约束）
@export_range(0.0, 60.0) var drip_rate: float = 20.0

## 网格更新频率（帧间隔，越大更新越慢但性能越好）
@export_range(2, 10) var update_every_n_frames: int = 3

## 水体素数量上限（防止水无限累积导致 mesh 过大卡死）
@export_range(500, 8000) var max_water_voxels: int = 3000

## 水滴生成点（高架池前侧瀑布落水口上方，让水从高处直接落下形成持续瀑布）
var _drop_pos := Vector3i(7, 14, 10)

var _data: VoxelDataResource
var _renderer: VoxelRenderer
var _drip_accum: float = 0.0
var _frame: int = 0
var _water_count: int = 0

# HUD
var _hud_label: Label
var _gen_time: float = 0.0


func _ready() -> void:
	_build_terrain()
	_setup_renderer()
	_setup_hud()
	_setup_camera()


func _process(delta: float) -> void:
	_frame += 1
	if _frame % update_every_n_frames != 0:
		return

	# 生成水滴（受数量上限约束）
	if _water_count < max_water_voxels:
		_drip_accum += drip_rate * delta * update_every_n_frames
		while _drip_accum >= 1.0:
			_drip_accum -= 1.0
			_spawn_drop()

	# 更新水体
	var t0 := Time.get_ticks_usec()
	_update_water()
	# 回流泵：把底部收集池的水抽回高架池顶，形成持续循环（水永远不会静止）
	_recycle_water()
	_gen_time = (Time.get_ticks_usec() - t0) / 1000.0

	# 批量修改后一次性通知 VoxelRenderer 重建 mesh
	_data.notify_changed()

	_update_hud()


# ----------------------------------------------------------------------------
# 地形构建（多级瀑布循环场景）
# ----------------------------------------------------------------------------
func _build_terrain() -> void:
	_data = VoxelDataResource.new()
	_data.grid_size = Vector3i(GRID_X, GRID_Y, GRID_Z)

	# 材质：统一封装的 add_material 自动按材质 ID 对齐数组索引
	var solid := VoxelMaterial.new()
	solid.id = MAT_SOLID
	solid.color = Color(0.45, 0.40, 0.35)
	solid.rough = 0.95
	_data.add_material(solid)

	var water := VoxelMaterial.new()
	water.id = MAT_WATER
	water.color = Color(0.25, 0.55, 0.9, 0.85)
	water.trans = 0.15
	water.rough = 0.05
	_data.add_material(water)

	var emissive := VoxelMaterial.new()
	emissive.id = MAT_EMISSIVE
	emissive.color = Color(0.2, 0.8, 1.0)
	emissive.emission = 2.0
	_data.add_material(emissive)

	# 地面（整体）
	for x in GRID_X:
		for z in GRID_Z:
			_data.voxels[Vector3i(x, 0, z)] = MAT_SOLID

	# ---- 高架水源池 (x:5..9, z:5..9)，前侧 (z:10) 中间段 x:6..8 开放为落水槽，形成第一级瀑布 ----
	_build_container(Vector3i(5, 4, 5), Vector3i(9, 8, 10), MAT_SOLID)
	# 高架池底（y:8 实心，水存在其上方；落水槽 x:6..8, z:10 处不建底，让瀑布贯通到地面）
	for x in range(5, 10):
		for z in range(5, 11):
			if z == 10 and x >= 6 and x <= 8:
				continue  # 落水槽处留空
			_data.voxels[Vector3i(x, 8, z)] = MAT_SOLID
	# 高架池四壁 y:9..12：后壁 z=5、左壁 x=5、右壁 x=9、前壁 z=10 (仅转角 x:5, x:9)
	for y in range(9, 13):
		for x in range(5, 10):
			_data.voxels[Vector3i(x, y, 5)] = MAT_SOLID
		for z in range(5, 11):
			_data.voxels[Vector3i(5, y, z)] = MAT_SOLID
			_data.voxels[Vector3i(9, y, z)] = MAT_SOLID
	# 前壁 z:10 仅在转角 x:5, x:9 实心；中间段 x:6..8 开放为落水槽 (y:9..13 全空)
	for y in range(9, 14):
		_data.voxels[Vector3i(5, y, 10)] = MAT_SOLID
		_data.voxels[Vector3i(9, y, 10)] = MAT_SOLID

	# ---- 第一级瀑布落点：地面蓄水池A (x:5..9 下方, z:5..10)，承接瀑布 ----
	_build_container(Vector3i(5, 1, 5), Vector3i(9, 3, 10), MAT_SOLID)

	# ---- 蓄水池A 溢流缺口 → 通道 → 蓄水池B（更低）----
	# 隔断 (x:10, y:1..2 实心)，在 y:3 中间 (z:7..8) 留缺口让水溢流
	for y in range(1, 3):
		for z in range(5, 11):
			_data.voxels[Vector3i(10, y, z)] = MAT_SOLID
	# 溢流通道（x:11..15, 地面层），两壁
	_build_walls_only(Vector3i(11, 1, 5), Vector3i(15, 2, 10), MAT_SOLID)
	# 通道末端低一级 → 蓄水池B (x:16..20, 更深的池，y 从 0 起)
	_build_container(Vector3i(16, 1, 5), Vector3i(20, 4, 10), MAT_SOLID)

	# ---- 蓄水池B 溢流 → 第二级瀑布 → 底部收集池 ----
	# 蓄水池B 前侧 (x:20) 在 y:3..4 开放形成第二级瀑布
	for y in range(3, 5):
		for z in range(6, 9):
			_data.voxels.erase(Vector3i(20, y, z))
	# 第二级瀑布落点：底部收集池 (x:21..25)
	_build_container(Vector3i(21, 1, 5), Vector3i(25, 3, 10), MAT_SOLID)

	# ---- 侧边回流通道：底部收集池 → 上升回流到高架水源（形成循环）----
	# 简化：不做真实泵送，用发光条标示"回流方向"（装饰），水最终在收集池
	# 发光装饰条：沿回流路径
	for x in range(27, 34):
		_data.voxels[Vector3i(x, 4, 7)] = MAT_EMISSIVE
	for y in range(5, 13):
		_data.voxels[Vector3i(33, y, 7)] = MAT_EMISSIVE
	for x in range(8, 33):
		_data.voxels[Vector3i(x, 13, 7)] = MAT_EMISSIVE

	# ---- 预置静态水体（各池少量初始水，展示水在动）----
	_fill_water(6, 8, 9, 11, 6, 9, MAT_WATER)   # 高架水源池少量水
	_fill_water(6, 8, 2, 2, 6, 9, MAT_WATER)    # 蓄水池A 底一层
	_fill_water(17, 19, 2, 2, 6, 9, MAT_WATER)  # 蓄水池B 底一层
	_fill_water(22, 24, 2, 2, 6, 9, MAT_WATER)  # 底部收集池一层


## 构建容器（底 + 四壁），用于承接水
func _build_container(a: Vector3i, b: Vector3i, mat: int) -> void:
	# 底
	for x in range(a.x, b.x + 1):
		for z in range(a.z, b.z + 1):
			_data.voxels[Vector3i(x, a.y - 1, z)] = mat
	# 四壁
	_build_walls_only(a, b, mat)


## 只构建四壁（不封底），用于通道/蓄水池
func _build_walls_only(a: Vector3i, b: Vector3i, mat: int) -> void:
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			_data.voxels[Vector3i(x, y, a.z)] = mat
			_data.voxels[Vector3i(x, y, b.z)] = mat
		for z in range(a.z, b.z + 1):
			_data.voxels[Vector3i(a.x, y, z)] = mat
			_data.voxels[Vector3i(b.x, y, z)] = mat


## 填充一个 AABB 区域为指定材质
func _fill_water(min_x: int, max_x: int, min_y: int, max_y: int, min_z: int, max_z: int, mat: int) -> void:
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			for z in range(min_z, max_z + 1):
				var pos := Vector3i(x, y, z)
				if _in_bounds(pos) and _data.get_voxel(pos) < 0:
					_data.voxels[pos] = mat
					_water_count += 1


func _setup_renderer() -> void:
	_renderer = VoxelRenderer.new()
	_renderer.name = "WaterVoxels"
	_renderer.data = _data
	_renderer.voxel_scale = voxel_scale
	# 高性能 chunk 生成器 + 增量重建 + 异步生成
	_renderer.use_chunk_generator = true
	_renderer.async_generate = true
	_renderer.update_throttle_frames = 3
	add_child(_renderer)
	_renderer.global_position = Vector3(
		-(GRID_X * voxel_scale) * 0.5, 0.0, -(GRID_Z * voxel_scale) * 0.5)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_hud_label = Label.new()
	_hud_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud_label.position = Vector2(10, 10)
	_hud_label.add_theme_font_size_override("font_size", 16)
	_hud_label.add_theme_color_override("font_color", Color.WHITE)
	_hud_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud_label)


func _setup_camera() -> void:
	# 相机是脚本所在节点的兄弟节点（在 tscn 的根下），复用或创建
	var cam: Camera3D
	for child in get_parent().get_children():
		if child is Camera3D:
			cam = child
			break
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		get_parent().add_child(cam)
	cam.global_position = Vector3(GRID_X * voxel_scale * 0.5, GRID_Y * voxel_scale * 0.8, GRID_Z * voxel_scale * 2.2)
	cam.look_at(Vector3(GRID_X * voxel_scale * 0.5, GRID_Y * voxel_scale * 0.4, 0))
	cam.fov = 70


func _update_hud() -> void:
	if _hud_label == null:
		return
	var mesh := _renderer.mesh
	var tri := 0
	var verts := 0
	if mesh:
		# 统计三角形/顶点：从各 surface 索引数组长度推导（HUD 调试用，频率低可接受）
		for si in mesh.get_surface_count():
			var idxs: PackedInt32Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
			# 索引数恒为 3 的倍数，整除即为三角形数
			@warning_ignore("integer_division")
			tri += idxs.size() / 3
			var varr: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			verts += varr.size()
	_hud_label.text = """FPS: %d
帧耗时: %.2f ms
三角形: %d
顶点: %d
体素总数: %d
水体素: %d
水模拟耗时: %.2f ms
Mesh生成耗时: %.2f ms
体素缩放: %.2f
""" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 0.001),
		tri, verts, _data.voxels.size(), _water_count, _gen_time, _renderer.last_mesh_gen_time_ms, voxel_scale]


# ----------------------------------------------------------------------------
# 水模拟（元胞自动机：重力 + 下坡 + 落差溢流，平地稳定不乱动）
# ----------------------------------------------------------------------------
func _spawn_drop() -> void:
	var pos := _drop_pos + Vector3i(randi_range(-1, 1), 0, randi_range(-1, 1))
	if _in_bounds(pos) and _data.get_voxel(pos) < 0:
		_data.voxels[pos] = MAT_WATER
		_water_count += 1


func _update_water() -> void:
	# 双缓冲元胞水模拟：
	# 第一步：基于当前状态计算每个水的"目标位置"（不立即移动）
	# 第二步：统一应用移动（同一帧内所有水同时移动，避免相邻水来回振荡/乱动）
	# 规则优先级：重力下落 > 下坡流动 > 水平扩散(向空位铺平)

	# 第一步：收集所有水，计算移动计划 (from -> to)
	var moves: Dictionary = {}   # key: from(Vector3i), value: to(Vector3i)
	for pos in _data.voxels:
		if _data.voxels[pos] != MAT_WATER:
			continue

		# 1. 重力：正下方为空则下落
		var below := pos + Vector3i(0, -1, 0)
		if _is_empty(below):
			moves[pos] = below
			continue

		# 2. 下坡流动：斜下方为空则沿坡流下
		var down_dirs := [
			Vector3i(1, -1, 0), Vector3i(-1, -1, 0),
			Vector3i(0, -1, 1), Vector3i(0, -1, -1),
		]
		down_dirs.shuffle()
		var moved := false
		for d: Vector3i in down_dirs:
			var side: Vector3i = pos + d
			if _is_empty(side):
				moves[pos] = side
				moved = true
				break
		if moved:
			continue

		# 3. 水平流动：优先向"目标下方为空"的方向（下坡/悬崖），水流有明确向下的趋势
		#    只有目标下方为空时才流动，避免在高位无方向地来回晃动
		var dirs := [
			Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		]
		dirs.shuffle()
		for d: Vector3i in dirs:
			var side: Vector3i = pos + d
			if _is_empty(side) and _is_empty(side + Vector3i(0, -1, 0)):
				moves[pos] = side
				moved = true
				break

	# 第二步：统一应用移动（所有水的目标基于第一步快照，冲突目标由较晚写入者覆盖，可接受）
	for from in moves:
		var to: Vector3i = moves[from]
		if _data.get_voxel(from) == MAT_WATER and _is_empty(to):
			_data.voxels.erase(from)
			_data.voxels[to] = MAT_WATER


## 回流泵：将系统中"最低层"的水抽回高架池顶，形成持续水循环
## 不依赖某个池满水，只要水量足够就从最底部抽水，保证水永远在流动
func _recycle_water() -> void:
	# 收集所有水的位置
	var water_positions: Array[Vector3i] = []
	for pos in _data.voxels:
		if _data.voxels[pos] == MAT_WATER:
			water_positions.append(pos)

	# 水量过少时仅靠水滴即可，暂不回流（避免泵把少量水抽空导致观感断裂）
	if water_positions.size() < 20:
		return

	# 优先抽"最低层"的水（y 最小的），让水从高处源源不断补下，形成连续瀑布
	water_positions.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		if a.x != b.x:
			return a.x < b.x
		return a.z < b.z)

	# 抽水量：总量的 1/6，最少 1 格，最多不超过 20（避免一帧抽太多影响观感）
	@warning_ignore("integer_division")
	var pump := clampi(water_positions.size() / 6, 1, 20)
	for i in mini(pump, water_positions.size()):
		# 回流到高架池内部水面（优先找池内空位），数量不变仅位置改变
		var target := _find_recycle_target()
		if target == Vector3i(-1, -1, -1):
			continue  # 找不到空位则不抽，避免水量流失
		_data.voxels.erase(water_positions[i])
		_data.voxels[target] = MAT_WATER


## 找一个可放置回流水的空位：优先在"瀑布落水槽"顶部 (高架池前侧 x:6..8, y:12..13, z:10)，
## 让回流的水从落水槽直接落下形成瀑布，而不是放回池内蓄水（避免池内高位晃动）
func _find_recycle_target() -> Vector3i:
	# 落水槽顶部 (x:6..8, y:13..12, z:10) 找空位，水从顶部开始下落
	for y in range(13, 11, -1):
		for x in range(6, 9):
			var p := Vector3i(x, y, 10)
			if _in_bounds(p) and _data.get_voxel(p) < 0:
				return p
	# 池顶生成点附近兜底
	var t := _drop_pos + Vector3i(randi_range(-1, 1), 0, randi_range(-1, 1))
	if _in_bounds(t) and _data.get_voxel(t) < 0:
		return t
	return Vector3i(-1, -1, -1)


func _is_empty(pos: Vector3i) -> bool:
	return _in_bounds(pos) and _data.get_voxel(pos) < 0


func _in_bounds(pos: Vector3i) -> bool:
	return pos.x >= 0 and pos.y >= 0 and pos.z >= 0 \
		and pos.x < GRID_X and pos.y < GRID_Y and pos.z < GRID_Z


func _move_water(from: Vector3i, to: Vector3i) -> void:
	_data.voxels.erase(from)
	_data.voxels[to] = MAT_WATER
