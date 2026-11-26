extends Node3D

## QVX 模型预览场 —— 专注"看 QVX 模型长什么样"。

## 要预览的模型（.vox 源文件 → 显示名）。
@export var models: Array[String] = [
	"res://demo/deer.vox",
	"res://demo/cars.vox",
	"res://demo/teapot1.vox",
]

## 模型之间的水平间距（世界单位）。
@export var spacing: float = 3.25

## 模型在世界中的最大边长（自动归一化，保证大小不一的模型都好观察）
@export var target_extent: float = 2.4

## 烘焙输出目录
@export var bake_dir: String = "user://qvx_viewer"

## 强制重新烘焙（忽略已存在的 .qvx）
@export var force_rebake: bool = false

var _camera: Camera3D
var _hud: Label
var _info: Label
var _pivot: Node3D
var _renderers: Array[VoxelRenderer] = []
var _labels: Array = []

var _yaw := 0.0
var _pitch := 0.18
var _dist := 12.0
var _auto_rotate := false
var _dragging := false
var _wireframe := false
## 聚焦索引：-1 = 总览（注视原点），>=0 = 注视该模型
var _focus_index := -1

## 单个模型的烘焙/加载统计（用于 HUD 展示，证明 QVX 真的被读写过）
var _stats: Array = []

func _ready() -> void:
	_setup_camera()
	_setup_hud()
	_build_all(force_rebake)
	print("[QVoxelViewer] 初始化完成，模型数=%d" % _renderers.size())

func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 60.0
	_camera.far = 500.0

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(12, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.08, 0.09, 0.12))
	# 描边：模型颜色多变，靠描边保证任何背景下都可读
	_hud.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(_hud)

	_info = Label.new()
	_info.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_info.position = Vector2(-460, 10)
	_info.size = Vector2(448, 0)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_info.add_theme_font_size_override("font_size", 13)
	_info.add_theme_color_override("font_color", Color(0.05, 0.1, 0.2))
	_info.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_info.add_theme_constant_override("outline_size", 5)
	layer.add_child(_info)

## 构建（或重建）全部模型
func _build_all(rebake: bool) -> void:
	for r in _renderers:
		if is_instance_valid(r):
			r.queue_free()
	_renderers.clear()
	for lb in _labels:
		if is_instance_valid(lb):
			lb.queue_free()
	_labels.clear()
	_stats.clear()

	if get_node_or_null("Models") != null:
		get_node("Models").queue_free()

	_pivot = Node3D.new()
	_pivot.name = "Models"
	add_child(_pivot)

	var n := models.size()
	for i in n:
		var src: String = models[i]
		if not ResourceLoader.exists(src):
			push_warning("[QVoxelViewer] 找不到模型: %s" % src)
			continue
		var entry := _build_one(src, i, n)
		if entry.is_empty():
			continue
		_renderers.append(entry["renderer"])
		_stats.append(entry)

	_layout()
	_focus_index = -1
	_auto_frame()
	_update_hud()

## 单个模型：.vox → QVoxelSource → .qvx → 回读 → 渲染
func _build_one(src: String, index: int, total: int) -> Dictionary:
	var name := src.get_file().get_basename()
	var t_all := Time.get_ticks_usec()

	# --- 1. 解析 .vox 为 QVoxelSource ---
	var vox := VoxAccess.Open(src)
	if vox == null:
		push_error("[QVoxelViewer] VoxAccess 打开失败: %s" % src)
		return {}
	var data := QVoxelSource.from_voxel_data(vox.voxel)
	if data == null:
		push_error("[QVoxelViewer] from_voxel_data 失败: %s" % src)
		return {}
	var t_parse := Time.get_ticks_usec()

	# --- 2. 写入 .qvx 容器（走 QVoxelStream 增量写盘）---
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(bake_dir))
	var qpath := bake_dir.path_join(name + ".qvx")
	var existed := FileAccess.file_exists(qpath)

	var stream := QVoxelStream.new()
	stream.file_path = qpath
	# 材质表：必须**保持「数组下标 == 材质ID」**的契约。
	var mats: Array = []
	mats.resize(data.materials.size())
	for i in data.materials.size():
		mats[i] = data.materials[i]
	stream.set_materials(mats)

	var t_bake_start := Time.get_ticks_usec()
	var chunks := _extract_chunks(data)
	var voxels_written := 0
	for ck in chunks:
		var buf: PackedInt32Array = chunks[ck]
		stream.save_chunk(ck, buf, 0)
		voxels_written += buf.size()
	stream.flush()
	var t_bake := Time.get_ticks_usec()

	var fsize := 0
	if FileAccess.file_exists(qpath):
		var f := FileAccess.open(qpath, FileAccess.READ)
		fsize = f.get_length()
		f.close()

	# --- 3. 从 .qvx 回读（新实例，验证磁盘数据可恢复）---
	var reader := QVoxelStream.new()
	reader.file_path = qpath
	reader.clear_cache()
	var t_read_start := Time.get_ticks_usec()
	var chunks_ok := 0
	for ck in chunks:
		var got := reader.load_chunk(ck, 0)
		if not got.is_empty():
			chunks_ok += 1
	var t_read := Time.get_ticks_usec()

	# --- 4. 用回读到的数据渲染（数据源 = QVX 文件）---
	var rdata := QVoxelSource.new()
	rdata.stream = reader
	for m in mats:
		if m != null:
			rdata.add_material(m)

	var r := VoxelRenderer.new()
	r.name = "Model_%d_%s" % [index, name]
	r.data = rdata
	r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	r.lod_count = 1
	_pivot.add_child(r)

	var t_end := Time.get_ticks_usec()

	var st := {
		"name": name,
		"path": qpath,
		"existed": existed,
		"renderer": r,
		"chunks": chunks.size(),
		"chunks_ok": chunks_ok,
		"voxels": voxels_written,
		"bytes": fsize,
		"aabb": _chunk_extent(chunks, data),
		"t_parse": (t_parse - t_all) / 1000.0,
		"t_bake": (t_bake - t_bake_start) / 1000.0,
		"t_read": (t_read - t_read_start) / 1000.0,
		"t_total": (t_end - t_all) / 1000.0,
	}
	print("[QVoxelViewer] %s: %d chunk, 写%d 读%d, %d KB, 解析%.1fms 烘焙%.1fms 回读%.1fms"
			% [name, st["chunks"], st["chunks"] as int, chunks_ok, fsize / 1024,
			   st["t_parse"], st["t_bake"], st["t_read"]])
	return st

## 从 QVoxelSource 提取每个 chunk 的 32³ 密集缓冲（键 = chunk 坐标）。
func _extract_chunks(data: QVoxelSource) -> Dictionary:
	var out: Dictionary = {}
	var raw: Dictionary = data.get("_chunk_buffers")
	for ck in raw:
		var buf: PackedInt32Array = raw[ck]
		if buf.size() > 0:
			out[ck] = buf
	return out

## 逐体素扫描，得到模型的**真实**体素 AABB（单位：体素）。
func _chunk_extent(chunks: Dictionary, _data: QVoxelSource) -> AABB:
	if chunks.is_empty():
		return AABB()
	var mn := Vector3i.MAX
	var mx := Vector3i.MIN
	var found := false
	for ck: Vector3i in chunks:
		var buf: PackedInt32Array = chunks[ck]
		if buf.size() < VoxelChunk.CHUNK_VOLUME:
			continue
		var origin := VoxelChunk.origin_of(ck)
		for i in VoxelChunk.CHUNK_VOLUME:
			if buf[i] <= 0:
				continue
			var p := origin + _local_from_index(i)
			mn.x = mini(mn.x, p.x)
			mn.y = mini(mn.y, p.y)
			mn.z = mini(mn.z, p.z)
			mx.x = maxi(mx.x, p.x)
			mx.y = maxi(mx.y, p.y)
			mx.z = maxi(mx.z, p.z)
			found = true
	if not found:
		return AABB()
	# 与 QVoxelSource._bounds_to_aabb 一致：体素 p 占据 [p, p+1)
	return AABB(Vector3(mn), Vector3(mx - mn + Vector3i.ONE))

## 32³ 密集缓冲下标 → 局部坐标（与 VoxelChunk 的 lx + ly*32 + lz*1024 互逆）
static func _local_from_index(i: int) -> Vector3i:
	var lz := i / VoxelChunk.CHUNK_SLICE
	var rem := i % VoxelChunk.CHUNK_SLICE
	var ly := rem / VoxelChunk.CHUNK_SIZE
	var lx := rem % VoxelChunk.CHUNK_SIZE
	return Vector3i(lx, ly, lz)

## 归一化尺寸并横向排布。
func _layout() -> void:
	var count := _renderers.size()
	if count == 0:
		return
	for i in count:
		var r := _renderers[i]
		if r.data == null or i >= _stats.size():
			continue
		# 用真实体素 AABB（_chunk_extent 已逐体素扫描，非 chunk 粒度）
		var aabb: AABB = _stats[i]["aabb"]
		if aabb.size.length() < 0.0001:
			continue
		var extent := maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
		if extent < 0.0001:
			continue
		# 直接求解：世界尺寸 = 体素extent × voxel_scale，要它等于 target_extent。
		r.voxel_scale = target_extent / extent

		# 【关键】渲染 mesh 的顶点坐标 = 体素坐标 × voxel_scale，体素原点在 chunk 角落，
		var half := aabb.size * 0.5 * r.voxel_scale
		var slot_x := (i - (count - 1) * 0.5) * spacing
		# mesh 的 AABB 起点（局部）即体素 min × scale；用 aabb.position 精确对齐
		var aabb_min_world := aabb.position * r.voxel_scale
		r.position = Vector3(
			slot_x - (aabb_min_world.x + half.x),
			0.0,
			-(aabb_min_world.z + half.z))
		print("[QVoxelViewer] 布局 %s: 体素AABB=%s extent=%.1f voxel_scale=%.5f 世界半尺寸=%s pos=%s"
				% [r.name, str(aabb), extent, r.voxel_scale, str(half), str(r.position)])

## 视角 / 输入
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(1.0, _dist * 0.9)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(80.0, _dist * 1.1)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.01
		_pitch = clampf(_pitch + mm.relative.y * 0.01, -1.4, 1.4)
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_R:
				_auto_rotate = not _auto_rotate
			KEY_W:
				_wireframe = not _wireframe
				_apply_wireframe()
			KEY_F:
				_build_all(true)
			KEY_ESCAPE:
				get_tree().quit()
			KEY_0:
				_yaw = 0.0
				_pitch = 0.18
				_auto_frame()
				_update_hud()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				var kc := (event as InputEventKey).keycode
				var idx := kc - KEY_1
				if idx < _renderers.size():
					# 聚焦：相机推到该模型正前方，目标点切到它的中心
					_dist = target_extent * 2.6
					_focus_index = idx
					_auto_rotate = false

func _apply_wireframe() -> void:
	# 线框用一个半透明 unshaded 材质覆盖，露出内部结构便于观察体素排布
	var mat: StandardMaterial3D = null
	if _wireframe:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.92, 0.96, 1.0, 0.35)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for r in _renderers:
		var mi := r as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			mi.set_surface_override_material(i, mat)

## 排布包围盒（世界坐标）：_layout 之后由 _auto_frame 计算，供相机取景使用。
var _row_min := Vector3.ZERO
var _row_max := Vector3.ZERO

## 按模型排布总宽自适应相机距离，保证整排模型都在视野内。
func _auto_frame() -> void:
	var count := _renderers.size()
	if count <= 0:
		return
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var any := false
	for i in count:
		if i >= _stats.size():
			continue
		var aabb: AABB = _stats[i]["aabb"]
		var r := _renderers[i]
		if aabb.size.length() < 0.0001:
			continue
		var w := aabb.size.x * r.voxel_scale
		var h := aabb.size.y * r.voxel_scale
		var d := aabb.size.z * r.voxel_scale
		# 该模型的世界包围盒：position.x/z 是槽位中心，y 恒为 0（底面贴地）
		var cx := r.position.x
		var cz := r.position.z
		mn.x = minf(mn.x, cx - w * 0.5)
		mn.y = minf(mn.y, 0.0)
		mn.z = minf(mn.z, cz - d * 0.5)
		mx.x = maxf(mx.x, cx + w * 0.5)
		mx.y = maxf(mx.y, h)
		mx.z = maxf(mx.z, cz + d * 0.5)
		any = true
	if not any:
		return
	_row_min = mn
	_row_max = mx
	var row_width := mx.x - mn.x
	var row_height := maxf(mx.y - mn.y, 0.001)

	var fov_v := deg_to_rad(_camera.fov)
	var aspect := 16.0 / 9.0
	var vp := get_viewport()
	if vp != null and vp.get_visible_rect().size.y > 0.0:
		aspect = vp.get_visible_rect().size.x / vp.get_visible_rect().size.y
	var fov_h := 2.0 * atan(tan(fov_v * 0.5) * aspect)
	var d_w := (row_width * 0.5) / tan(fov_h * 0.5)
	var d_h := (row_height * 0.5) / tan(fov_v * 0.5)
	# 余量 1.6：模型有深度(本帧还含 Z 向 ±0.93)、俯角会让上缘外扩、透视在边缘放大，
	_dist = clampf(maxf(d_w, d_h) * 1.6, 3.0, 80.0)
	_yaw = 0.0
	_pitch = 0.12
	_focus_index = -1
	print("[QVoxelViewer] 自动取景: 排宽=%.2f 最高=%.2f 中心=(%.2f,%.2f,%.2f) aspect=%.2f dist=%.2f (d_w=%.2f d_h=%.2f)"
			% [row_width, row_height, (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, (mn.z + mx.z) * 0.5,
			   aspect, _dist, d_w, d_h])

func _process(delta: float) -> void:
	if _auto_rotate and not _dragging:
		_yaw += delta * 0.4
	# 目标点：总览看排布包围盒中心（未必在原点），聚焦看单个模型中心
	var target := Vector3.ZERO
	if _focus_index >= 0 and _focus_index < _renderers.size():
		target = _renderers[_focus_index].position
	else:
		target = (_row_min + _row_max) * 0.5
	var radius := _dist
	var px := target.x + radius * cos(_pitch) * sin(_yaw)
	var py := target.y + radius * sin(_pitch)
	var pz := target.z + radius * cos(_pitch) * cos(_yaw)
	_camera.global_position = Vector3(px, py, pz)
	_camera.look_at(target, Vector3.UP)
	_update_hud()

func _update_hud() -> void:
	var fps := Engine.get_frames_per_second()
	var draw := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var tri := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	_hud.text = "QVX 模型预览    FPS: %d    DrawCalls: %d\n" % [fps, draw] + \
			"模型数: %d    自动旋转: %s    线框: %s    聚焦: %s\n" % [
				_renderers.size(), "ON" if _auto_rotate else "OFF",
				"ON" if _wireframe else "OFF",
				"总览" if _focus_index < 0 else str(_focus_index + 1)] + \
			"左键拖拽旋转  滚轮缩放\n" + \
			"R:自动旋转  W:线框  F:重烘焙  1-9:聚焦  0:复位  Esc:退出"

	var lines: Array = ["QVX 容器（.vox → .qvx → 渲染）", ""]
	for st in _stats:
		lines.append("%s" % st["name"])
		lines.append("  %d chunk | 回读 %d | %d KB" % [st["chunks"], st["chunks_ok"], st["bytes"] / 1024])
		lines.append("  解析 %.1f / 烘焙 %.1f / 回读 %.1f ms" % [st["t_parse"], st["t_bake"], st["t_read"]])
	_info.text = "\n".join(PackedStringArray(lines))
