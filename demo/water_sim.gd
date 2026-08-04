extends Node
## 体素水流循环模拟演示（大型复杂场景）
## 展示：高架水源 → 第一级瀑布 → 蓄水池A → 溢流通道 → 蓄水池B → 第二级瀑布 → 底部收集池 → 循环
## 使用元胞自动机式的水模拟规则（重力下落、下坡流动、落差溢流）
## 渲染：VoxelRenderer + 动态 VoxelData + HUD 性能监控

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

var _data: VoxelData
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
	_gen_time = (Time.get_ticks_usec() - t0) / 1000.0

	# 批量修改后一次性通知 VoxelRenderer 重建 mesh
	_data.notify_changed()

	_update_hud()


# ----------------------------------------------------------------------------
# 地形构建（多级瀑布循环场景）
# ----------------------------------------------------------------------------
func _build_terrain() -> void:
	_data = VoxelData.new()
	_data.grid_size = Vector3i(GRID_X, GRID_Y, GRID_Z)

	# 材质：统一封装的 add_material 自动按材质 ID 对齐数组索引
	var solid := VoxelMaterial.new()
	solid.id = MAT_SOLID
	solid.color = Color(0.45, 0.40, 0.35)
	solid.rough = 0.95
	_data.add_material(solid)

	var water := VoxelMaterial.new()
	water.id = MAT_WATER
	water.color = Color(0.25, 0.55, 0.9)
	water.trans = 0.35
	water.rough = 0.05
	_data.add_material(water)

	var emissive := VoxelMaterial.new()
	emissive.id = MAT_EMISSIVE
	emissive.color = Color(0.3, 0.75, 1.0)
	emissive.emission = 0.4
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
	# 蓄水池A (x:5..9) 与通道 (x:11..15) 之间用低矮隔断 x:10 (仅 y:1)，
	# y:2 层在 z:7..8 处开口，水蓄到 y:2 后从缺口流入通道
	for y in range(1, 2):
		for z in range(5, 11):
			_data.voxels[Vector3i(10, y, z)] = MAT_SOLID
	# 蓄水池A 右壁 x:9 在 y:2 中间段 (z:6..9) 开放，与隔断缺口对齐，水可水平流入通道
	for z in range(6, 10):
		_data.voxels.erase(Vector3i(9, 2, z))
	# 溢流通道（x:11..15, 地面层），两侧壁 (z:5, z:10) 建到 y:2
	for y in range(1, 3):
		for x in range(11, 16):
			_data.voxels[Vector3i(x, y, 5)] = MAT_SOLID
			_data.voxels[Vector3i(x, y, 10)] = MAT_SOLID
	# 通道末端 → 蓄水池B (x:16..20)
	_build_container(Vector3i(16, 1, 5), Vector3i(20, 3, 10), MAT_SOLID)

	# ---- 蓄水池B 溢流 → 第二级瀑布 → 底部收集池 ----
	# 蓄水池B 前侧 (x:20) 在 y:2..3 开放形成第二级瀑布
	for y in range(2, 4):
		for z in range(6, 9):
			_data.voxels.erase(Vector3i(20, y, z))
	# 第二级瀑布落点：底部收集池 (x:21..25)
	_build_container(Vector3i(21, 1, 5), Vector3i(25, 2, 10), MAT_SOLID)

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
		_data.set_voxel(pos, MAT_WATER)
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

		# 3. 水平流动：先向"目标下方为空"的方向流（下坡/悬崖，有明确向下趋势），
		#    若无下坡方向，再向普通空位流（含池壁缺口，使水能溢流到下一层）
		#    双缓冲机制保证同一帧所有水同时移动，不会来回振荡
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
		if moved:
			continue
		# 无下坡方向时，向普通空位流动（池壁缺口溢流、水面铺平）
		for d: Vector3i in dirs:
			var side: Vector3i = pos + d
			if _is_empty(side):
				moves[pos] = side
				moved = true
				break

	# 第二步：统一应用移动（所有水的目标基于第一步快照，冲突目标由较晚写入者覆盖，可接受）
	# 用框架批量接口而非直接改 voxels 字典：批量接口会维护 dirty_voxels，
	# 让 VoxelRenderer 走增量重建（只重建受影响 chunk）+ 支撑/索引缓存保持正确。
	# 【关键】必须用 claimed 记录本帧已被占用的目标：若两个水同时想移入同一格，
	# 只有先者搬入，后者原地不动（不搬走 source），否则后者的 source 会被删除、
	# 却没有新 position 写入 → 每帧丢水，永远攒不起来。
	var claimed: Dictionary = {}   # 本帧已分配的目标位置 -> true
	var from_list: Array = []
	var to_list: Array = []
	for from in moves:
		var to: Vector3i = moves[from]
		if _data.get_voxel(from) != MAT_WATER:
			continue
		if not _is_empty(to) or claimed.has(to):
			continue  # 目标被占用/本帧已被分配：保持原位，不搬走 source
		claimed[to] = true
		from_list.append(from)
		to_list.append(to)
	if not from_list.is_empty():
		_data.remove_voxels(from_list, false)
		_data.set_voxels(to_list, MAT_WATER)


func _is_empty(pos: Vector3i) -> bool:
	return _in_bounds(pos) and _data.get_voxel(pos) < 0


func _in_bounds(pos: Vector3i) -> bool:
	return pos.x >= 0 and pos.y >= 0 and pos.z >= 0 \
		and pos.x < GRID_X and pos.y < GRID_Y and pos.z < GRID_Z


func _move_water(from: Vector3i, to: Vector3i) -> void:
	_data.voxels.erase(from)
	_data.voxels[to] = MAT_WATER
