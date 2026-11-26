extends Node3D

## VoxelRenderer（QVX 分块运行时管线）⇄ 导入 ArrayMesh（整模型单网格）渲染性能基准。

const PLAN_PATH := "user://voxel_render_bench_plan.json"
const RESULT_PATH := "user://voxel_render_bench_results.json"

@export var auto_run: bool = true

var _cam: Camera3D
var _light: DirectionalLight3D
var _env: Environment
var _stage_root: Node3D
var _hud: Label
var _results: Array = []
var _running := false

## 模型缓存：src -> {mesh, data, ext, tris, verts, chunks, ...}
var _cache: Dictionary = {}

func _ready() -> void:
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# 【必须】置顶窗口。
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	_build_world()
	_build_hud()
	# GPU 实测渲染耗时（把 GPU 光栅成本从 CPU 组织成本里分出来）
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if auto_run:
		_run()

func _build_world() -> void:
	_cam = Camera3D.new()
	_cam.name = "BenchCam"
	_cam.fov = 60.0
	_cam.near = 0.05
	_cam.far = 4000.0
	add_child(_cam)
	_cam.current = true

	_light = DirectionalLight3D.new()
	_light.name = "Sun"
	_light.light_energy = 1.1
	_light.rotation_degrees = Vector3(-52, -38, 0)
	_light.shadow_enabled = false
	add_child(_light)

	# 简化环境：关掉 SSAO/SSR/SSIL/Glow —— 这些在两个变体上完全等价，
	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.10, 0.11, 0.14)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.62, 0.68, 0.76)
	_env.ambient_light_energy = 0.40
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	we.environment = _env
	add_child(we)

	_stage_root = Node3D.new()
	_stage_root.name = "Stage"
	add_child(_stage_root)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(14, 12)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_R:
				if not _running:
					_run()

# ── 计划 ────────────────────────────────────────────────────────────────…

## 默认计划。
func _default_plan() -> Dictionary:
	return {
		"stages": [
			{"label": "baseline 空场景", "count": 0},
			{"model": "res://demo/deer.vox", "count": 1},
			{"model": "res://demo/cars.vox", "count": 1},
			{"model": "res://demo/teapot1.vox", "count": 1},
			{"model": "res://demo/teapot2.vox", "count": 1},
			{"model": "res://demo/deer.vox", "count": 100, "label": "deer ×100"},
			{"model": "res://demo/deer.vox", "count": 100, "unique": true, "label": "deer ×100 独立mesh"},
			{"model": "res://demo/deer.vox", "count": 1000, "label": "deer ×1000"},
			{"model": "res://demo/cars.vox", "count": 240, "label": "cars ×240"},
			{"model": "res://demo/teapot1.vox", "count": 16, "label": "teapot1 ×16"},
			{"model": "res://demo/teapot1.vox", "count": 16, "shadows": true, "label": "teapot1 ×16 +阴影"},
		],
	}

func _load_plan() -> Dictionary:
	if FileAccess.file_exists(PLAN_PATH):
		var txt := FileAccess.get_file_as_string(PLAN_PATH)
		var parsed: Variant = JSON.parse_string(txt)
		if parsed is Dictionary and parsed.get("stages") is Array:
			print("[VRB] 使用计划文件 %s" % PLAN_PATH)
			return parsed
		push_warning("[VRB] 计划文件解析失败，回落到默认计划: %s" % PLAN_PATH)
	return _default_plan()

# ── 模型准备（一次性，不计入帧率）─────────────────────────────────────────────

## 取（并缓存）一个模型的两条路径产物。
func _get_model(src: String) -> Dictionary:
	if _cache.has(src):
		return _cache[src]
	var out := {}
	var vox := VoxAccess.Open(src)
	if vox == null:
		push_error("[VRB] 打不开 %s" % src)
		return {}
	var t0 := Time.get_ticks_usec()
	var opts := {
		VoxelMeshImporter.scale: 0.1,
		VoxelMeshImporter.origin: VoxelWorldUtil.OriginMode.WORLD_ORIGIN,
		VoxelMeshImporter.shape: VoxelMeshImporter.Shape.cube,
		VoxelMeshImporter.sphere_subdivisions: 0,
		VoxelMeshImporter.sphere_scale: 1.0,
		VoxelMeshImporter.frame_index: 0,
		VoxelMeshImporter.unwrap_lightmap_uv2: false,
		VoxelMeshImporter.uv2_texel_size: 0.2,
		VoxelMeshImporter.import_materials_textures: false,
	}
	var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh(vox.voxel, opts)
	var t_mesh := (Time.get_ticks_usec() - t0) / 1000.0
	if mesh == null:
		push_error("[VRB] generate_mesh 失败 %s" % src)
		return {}
	var tris := 0
	var verts := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

	t0 = Time.get_ticks_usec()
	var data := QVoxelSource.from_voxel_data(vox.voxel, 0, QVoxelSource.OriginMode.WORLD_ORIGIN)
	var t_data := (Time.get_ticks_usec() - t0) / 1000.0
	var chunks := data.get_all_chunk_keys().size()
	var aabb := mesh.get_aabb()
	out = {
		"src": src,
		"mesh": mesh,
		"data": data,
		"ext": maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z),
		"tris": tris,
		"verts": verts,
		"chunks": chunks,
		"build_mesh_ms": t_mesh,
		"build_data_ms": t_data,
	}
	print("[VRB] 准备 %s: %d tri / %d chunk | 导入mesh %.1fms | QVoxelSource %.1fms"
			% [src.get_file(), tris, chunks, t_mesh, t_data])
	_cache[src] = out
	return out

# ── 主流程 ───────────────────────────────────────────────────────────────…

func _run() -> void:
	_running = true
	_results.clear()
	print("[VRB] ===== 开始 =====")
	print("[VRB] GPU=%s | CPU=%s | Godot=%s | 窗口=%s | vsync=%d"
			% [RenderingServer.get_video_adapter_name(), OS.get_processor_name(),
			   Engine.get_version_info()["string"], str(DisplayServer.window_get_size()),
			   DisplayServer.window_get_vsync_mode()])
	var plan := _load_plan()
	var stages: Array = plan.get("stages", [])
	for i in stages.size():
		var st: Dictionary = stages[i]
		var mdl: String = st.get("model", "")
		var count: int = int(st.get("count", 1))
		var target: float = float(st.get("size", 2.0))
		var shadows: bool = bool(st.get("shadows", false))
		var frames: int = int(st.get("frames", 240))
		var label: String = st.get("label", "")
		_light.shadow_enabled = shadows
		if count <= 0:
			await _run_stage({"label": "baseline 空场景", "count": 0, "shadows": shadows, "frames": frames})
			continue
		var m := _get_model(mdl)
		if m.is_empty():
			continue
		if label.is_empty():
			label = "%s ×%d" % [mdl.get_file().get_basename(), count]
		await _run_stage({
			"label": label, "model": m, "count": count, "size": target,
			"shadows": shadows, "frames": frames, "unique": bool(st.get("unique", false)),
		})
		_hud.text = "stage %d/%d 完成：%s" % [i + 1, stages.size(), label]
	_running = false
	_dump_results()
	print("[VRB] ===== 结束 =====")
	_hud.text += "\n结果已写入 %s\nR 重跑 / Esc 退出" % ProjectSettings.globalize_path(RESULT_PATH)

func _run_stage(st: Dictionary) -> void:
	var count: int = int(st["count"])
	var shadows: bool = bool(st["shadows"])
	var frames: int = int(st["frames"])
	var label: String = st["label"]
	var desc := "%s%s" % [label, " [阴影]" if shadows else ""]
	print("[VRB] --- stage: %s ---" % desc)

	if count <= 0:
		await _clear_stage()
		await _settle(20)
		var r0 := await _sample(frames)
		r0["label"] = desc
		r0["variant"] = "baseline"
		_results.append(r0)
		print("[VRB] %-26s | p50 %.2fms %.0ffps | p99 %.2fms 1%%low %.0ffps | draws %d | gpu %.2fms cpu %.2fms"
				% [desc, r0["frame_ms"], r0["fps_p50"], r0["p99_ms"], r0["fps_1pct_low"],
				   r0["draw_calls"], r0["gpu_ms"], r0["cpu_ms"]])
		return

	var m: Dictionary = st["model"]
	var target: float = float(st.get("size", 2.0))
	var s := target / maxf(float(m["ext"]), 0.0001)
	var cells := int(ceil(sqrt(float(count))))
	var spacing := target * 1.35
	var layout := _grid_positions(count, cells, spacing)
	var model_h := s * float(m["ext"])
	_frame_camera(layout, target, model_h)

	# ---------- A. 导入 ArrayMesh 侧 ----------
	await _clear_stage()
	# unique=true：每实例一份独立 mesh 副本（相当于"每个实例各自导入一次"）。
	var use_unique: bool = bool(st.get("unique", false))
	for p in layout:
		var mi := MeshInstance3D.new()
		mi.mesh = (m["mesh"] as ArrayMesh).duplicate() if use_unique else m["mesh"]
		mi.scale = Vector3.ONE * s
		mi.position = p
		_stage_root.add_child(mi)
	await _settle(10)
	var rm := await _sample(frames)
	rm["label"] = desc
	rm["variant"] = "mesh_unique" if use_unique else "mesh"
	rm["count"] = count
	rm["tris"] = int(m["tris"]) * count
	rm["verts"] = int(m["verts"]) * count
	rm["surfaces"] = int((m["mesh"] as ArrayMesh).get_surface_count()) * count
	rm["chunks"] = count
	_results.append(rm)
	_print_row(desc, rm)

	# ---------- B. VoxelRenderer 侧 ----------
	await _clear_stage()
	# 【关键：view_distance 必须覆盖整个排布】
	var cam_pos := _cam.global_position
	var need_d := 1.0
	for p in layout:
		need_d = maxf(need_d, cam_pos.distance_to(p) + target * 2.0)
	var t_build0 := Time.get_ticks_usec()
	var renderers: Array = []
	for p in layout:
		var r := VoxelRenderer.new()
		r.data = m["data"]
		r.voxel_scale = 0.1 * s
		# 【QVX 现状】DYNAMIC + 每 chunk 一个绘制单元 = 重构前的组织方式（对照组）
		r.draw_mode = VoxelRenderer.DrawMode.DYNAMIC
		r.group_shift = 0
		r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
		r.view_distance = need_d
		r.lod_count = 1
		r.position = p
		_stage_root.add_child(r)
		renderers.append(r)
	var ready := await _await_renderers(renderers)
	var t_build := (Time.get_ticks_usec() - t_build0) / 1000.0
	var rq := await _sample(frames)
	rq["label"] = desc
	rq["variant"] = "qvox"
	rq["count"] = count
	rq["tris"] = int(m["tris"]) * count
	rq["verts"] = int(m["verts"]) * count
	rq["surfaces"] = _count_surfaces(renderers)
	rq["chunks"] = int(m["chunks"]) * count
	rq["build_ms"] = t_build
	rq["build_ok"] = ready
	rq["view_distance"] = need_d
	_results.append(rq)
	_print_row(desc, rq)
	print("[VRB]      QVX 建网格 %d 实例 × %d chunk = %.0fms | surface %d | chunk 节点 %d"
			% [count, int(m["chunks"]), t_build, int(rq["surfaces"]), int(rq["nodes"])])

	# ---------- C. DYNAMIC(分组 8 chunk)：重构后的可编辑模式 ----------
	await _clear_stage()
	var rgs: Array = []
	var t_gs0 := Time.get_ticks_usec()
	for p in layout:
		var r := VoxelRenderer.new()
		r.data = m["data"]
		r.voxel_scale = 0.1 * s
		r.draw_mode = VoxelRenderer.DrawMode.DYNAMIC
		r.group_shift = 1          # 每 8 chunk 一个绘制单元（新默认）
		r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
		r.view_distance = need_d
		r.lod_count = 1
		r.position = p
		_stage_root.add_child(r)
		rgs.append(r)
	var ready_gs := await _await_renderers(rgs)
	var t_gs := (Time.get_ticks_usec() - t_gs0) / 1000.0
	var rg := await _sample(frames)
	rg["label"] = desc
	rg["variant"] = "qvox_group8"
	rg["count"] = count
	rg["tris"] = int(m["tris"]) * count
	rg["surfaces"] = _count_surfaces(rgs)
	rg["chunks"] = int(m["chunks"]) * count
	rg["build_ms"] = t_gs
	rg["build_ok"] = ready_gs
	_results.append(rg)
	_print_row(desc, rg)
	print("[VRB]      QVX 分组(8chunk) 建网格 %d 实例 = %.0fms | 绘制单元 %d"
			% [count, t_gs, int(rg["surfaces"])])
	await _clear_stage()

	# ---------- D. STATIC（新默认）：整份合并 + 共享 → 引擎自动合批 ----------
	await _clear_stage()
	VoxelMesher.clear_shared_meshes()
	var rst: Array = []
	var t_st0 := Time.get_ticks_usec()
	for p in layout:
		var r := VoxelRenderer.new()
		r.data = m["data"]
		r.voxel_scale = 0.1 * s
		r.draw_mode = VoxelRenderer.DrawMode.STATIC
		r.position = p
		_stage_root.add_child(r)
		rst.append(r)
	var ready_st := await _await_renderers(rst)
	var t_st := (Time.get_ticks_usec() - t_st0) / 1000.0
	var rs2 := await _sample(frames)
	rs2["label"] = desc
	rs2["variant"] = "qvox_static"
	rs2["count"] = count
	rs2["tris"] = int(m["tris"]) * count
	rs2["surfaces"] = _count_surfaces(rst)
	rs2["chunks"] = int(m["chunks"]) * count
	rs2["build_ms"] = t_st
	rs2["build_ok"] = ready_st
	_results.append(rs2)
	_print_row(desc, rs2)
	print("[VRB]      QVX STATIC 建网格 %d 实例 = %.0fms（共享 mesh 缓存 %d 份）| 对比导入 mesh %.2fms"
			% [count, t_st, VoxelMesher.shared_mesh_count(), float(rm["p50_ms"])])
	await _clear_stage()

func _print_row(desc: String, r: Dictionary) -> void:
								print("[VRB] %-26s | p50 %.2fms %.0ffps | p95 %.2fms p99 %.2fms 1%%low %.0ffps | draws %d | tris %d | nodes %d | gpu %.2fms cpu %.2fms"
																% [desc + " · " + String(r["variant"]), float(r["frame_ms"]), float(r["fps_p50"]),
																			float(r["p95_ms"]), float(r["p99_ms"]), float(r["fps_1pct_low"]),
																			int(r["draw_calls"]), int(r["tris"]), int(r["nodes"]),
																			float(r["gpu_ms"]), float(r["cpu_ms"])])

func _grid_positions(count: int, cells: int, spacing: float) -> Array:
	var out: Array = []
	var cols := cells
	var rows := int(ceil(float(count) / float(cols)))
	for i in count:
		var cx := i % cols
		var cz := i / cols
		var x := (float(cx) - (float(cols) - 1.0) * 0.5) * spacing
		var z := (float(cz) - (float(rows) - 1.0) * 0.5) * spacing
		out.append(Vector3(x, 0.0, z))
	return out

## 取景：把整个排布放进画面，并且**相机必须在包围盒外**。
func _frame_camera(positions: Array, target: float, model_h: float) -> void:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for p in positions:
		mn.x = minf(mn.x, p.x - target * 0.5)
		mx.x = maxf(mx.x, p.x + target * 0.5)
		mn.z = minf(mn.z, p.z - target * 0.5)
		mx.z = maxf(mx.z, p.z + target * 0.5)
	mn.y = 0.0
	mx.y = maxf(mx.y, model_h)
	var center := (mn + mx) * 0.5
	var corners: Array = []
	for xi in 2:
		for yi in 2:
			for zi in 2:
				corners.append(Vector3(
					mx.x if xi == 1 else mn.x,
					mx.y if yi == 1 else mn.y,
					mx.z if zi == 1 else mn.z))
	var dir := Vector3(0.0, 0.42, 1.0).normalized()
	var vp := get_viewport().get_visible_rect().size
	var margin := vp * 0.06
	var d := maxf(maxf(mx.x - mn.x, mx.z - mn.z), model_h) * 0.6
	for _i in 400:
		_cam.global_position = center + dir * d
		_cam.look_at(center, Vector3.UP)
		var ok := true
		for c in corners:
			if not _cam.is_position_in_frustum(c):
				ok = false
				break
			var sp := _cam.unproject_position(c)
			if sp.x < margin.x or sp.y < margin.y \
					or sp.x > vp.x - margin.x or sp.y > vp.y - margin.y:
				ok = false
				break
		if ok:
			return
		d *= 1.06
	push_warning("[VRB] 取景收敛失败，按 %.1f 距离直接使用" % d)

func _clear_stage() -> void:
	for c in _stage_root.get_children():
		c.queue_free()
	_stage_root.queue_free()
	_stage_root = Node3D.new()
	_stage_root.name = "Stage"
	add_child(_stage_root)
	await get_tree().process_frame
	await get_tree().process_frame

func _settle(n: int) -> void:
	for i in n:
		await get_tree().process_frame

## 等所有 VoxelRenderer 把每个 chunk 的网格都建完（FULL 模式 = 全部 chunk）。
func _await_renderers(renderers: Array) -> bool:
	var t0 := Time.get_ticks_msec()
	var timeout := 180000
	while true:
		var pending := 0
		for r in renderers:
			var rr := r as VoxelRenderer
			if rr == null or not is_instance_valid(rr) or rr.data == null:
				continue
			var missing := false
			for ck in rr.data.get_all_chunk_keys():
				if not rr.has_chunk_mesh(ck):
					missing = true
					break
			if missing or rr.get("_batch") != null or not (rr.get("_group_dirty") as Dictionary).is_empty():
				pending += 1
		if pending == 0:
			return true
		if Time.get_ticks_msec() - t0 > timeout:
			push_warning("[VRB] 等待 VoxelRenderer 建网格超时（仍有 %d 个未就绪）" % pending)
			return false
		await get_tree().process_frame
	return true

func _count_surfaces(renderers: Array) -> int:
	var n := 0
	for r in renderers:
		if not is_instance_valid(r):
			continue
		var rr := r as VoxelRenderer
		# STATIC 的几何挂在节点自己身上（self.mesh），不是子节点
		if rr.mesh != null:
			n += rr.mesh.get_surface_count()
		for ch in rr.get_children():
			if ch is MeshInstance3D and (ch as MeshInstance3D).mesh != null:
				n += (ch as MeshInstance3D).mesh.get_surface_count()
	return n

## 采样一帧序列。
func _sample(frames: int) -> Dictionary:
	var r := await PerfTool.sample_frames(frames, 30)
	var rid := get_viewport().get_viewport_rid()
	return {
		"frame_ms": float(r.get("p50_ms", 0.0)),
		"p50_ms": float(r.get("p50_ms", 0.0)),
		"p95_ms": float(r.get("p95_ms", 0.0)),
		"p99_ms": float(r.get("p99_ms", 0.0)),
		"avg_ms": float(r.get("avg_ms", 0.0)),
		"fps_p50": float(r.get("fps_p50", 0.0)),
		"fps_1pct_low": float(r.get("fps_1pct_low", 0.0)),
		"stutter": int(r.get("stutter", 0)),
		"cv": float(r.get("cv", 0.0)),
		"draw_calls": int(r.get("draw_calls", 0)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"buffer_mem_mb": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		"mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid),
		"frames": frames,
	}

func _dump_results() -> void:
	var payload := {
		"generated_at": Time.get_datetime_string_from_system(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"cpu": OS.get_processor_name(),
		"godot": Engine.get_version_info()["string"],
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"results": _results,
	}
	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()
		print("[VRB] 结果已写入 %s" % ProjectSettings.globalize_path(RESULT_PATH))
