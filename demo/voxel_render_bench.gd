extends Node3D

## VoxelRenderer（QVX 分块运行时管线）⇄ 导入 ArrayMesh（整模型单网格）渲染性能基准。
##
## 为什么需要它：两条路径的**几何内核是同一个**（NativeLoader.generate_arrays_native /
## generate_chunk_dense，都是 6 向可见性 + 每 slice 贪婪合并），顶点/三角形数完全相同。
## 真正的差别只在"渲染组织方式"：
##   · ArrayMesh：1 个 MeshInstance3D / 1~2 个 surface = 1~2 个 draw call，整模型一个 AABB
##   · VoxelRenderer：每 chunk 1 个 MeshInstance3D = 每 chunk 1~2 个 draw call，
##     并额外承担每帧 _process（LOD 调度 / 流式扫描 / 视锥剔除）的 CPU 开销
## 本场景就是量这两件事在"单模型"和"场景内大量模型"下的差距。
##
## 用法：
##   F5 运行本场景（或 game_control(action=start, scene=res://demo/voxel_render_bench.tscn)）
##   跑完在 user://voxel_render_bench_results.json 落一份结果，并打印 [VRB] 日志。
##   计划文件（可选）：user://voxel_render_bench_plan.json，格式见 _default_plan()。
##   Esc 退出；R 重跑。
##
## 口径（务必与数字一起看）：
##   · vsync 关闭 + max_fps=0 + 窗口置顶，测的是"能跑多快"，不是"锁 60 时稳不稳"
##   · 每个 stage 先等所有 VoxelRenderer 的 chunk 网格全部就绪，再预热 30 帧后采样
##   · 每个 stage 出 4~5 行，是同一份负载的**不同渲染组织形态**（这才是本基准的价值）：
##       mesh                 导入 ArrayMesh，N 个 MeshInstance3D 共享一份资源（Godot 自动合批）
##       mesh_unique          同上但每实例复制一份 mesh（模拟"各自独立几何"）
##       qvox                 现状：每 chunk 一个 MeshInstance3D + 独立 ArrayMesh
##       qvox_no_process      同上但关掉 renderer._process → 差值 = 每帧调度 CPU 成本
##       qvox_merged          把已生成的 chunk 网格**原样合并**成每实例 1 个 ArrayMesh
##       qvox_merged_shared   再进一步：合并后的 mesh **共享**给全部实例 → 可合批
##     后两行不改一个顶点、只改渲染组织方式，用来证明"差距来自 draw call，不来自体素几何"。
##   · frame_ms 用 PerfTool.sample_frames（p50/p95/p99 + 1% low + CV），gpu_ms 取引擎
##     viewport measured render time，用来把 CPU 组织开销与 GPU 光栅开销分开
##   · 两侧共享同一份 mesh / QVoxelSource（不是每个实例各建一份数据），这才是"同一模型摆 N 份"
##     的真实用法；数据准备耗时单独打日志，不计入帧率。

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
	# 【必须】置顶窗口。引擎/驱动在"窗口被别的窗口遮住"时会把呈现节流（实测这台机器
	# 被遮住时地板从 0.95ms 变成 6.90ms / 145fps，且**与窗口大小、GPU 耗时无关**），
	# 那种状态下所有 stage 都被压在同一个地板上，横向对比全是废数据。
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
	# 留着只会把两者都压到同一水平、掩盖 draw call / 顶点吞吐的差异。
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


# ── 计划 ─────────────────────────────────────────────────────────────────────

## 默认计划。字段：
##   model   模型 .vox 路径（两侧都用 cube 形状，见 _get_model 的说明）
##   count   实例数（0 = 空场景基线）
##   size    归一化目标尺寸（世界单位，最长边），让不同模型在画面里占同一面积
##   shadows 该 stage 是否开方向光阴影（阴影 pass 会把几何成本再翻一遍，是最能放大
##           "顶点数 / draw call"差异的开关）
##   frames  采样帧数（默认 240）
##   unique  ArrayMesh 侧是否为每个实例复制一份 mesh 资源。默认 false —— 真实项目里 N 个
##           相同模型就是共享同一份 preload 的 mesh，Godot 会把它批处理成极少的 draw call
##           （实测 deer ×100 共享=19 draws / 各自唯一=118 draws）。true 是"每实例一份独立
##           几何"的对照，用来把"批处理红利"与"每实例固定开销"分开。
##   label   报告里的行名
##
## 【为什么负载要大到 5~20ms/帧】空场景的帧时间地板约 1.2ms（800fps），
## 单模型两侧都在地板上（0.9 vs 0.9ms），那种数字说明不了任何事。要看出差距必须把
## 实例数加到帧时间明显离开地板。
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
##
## 【为什么两侧都用「运行时 generate_mesh」而不是直接 load 导入产物】
## deer.vox 的导入设置是 mesh/shape=1（球体！），导入产物 5300 tri；而本仓库 QVX 渲染路径
## 走方块面（1344 tri）——两者根本不是同一份几何，拿来比帧率是错的。
## 故这里用**导入器自己的生成器**（VoxelMeshGenerator.generate_mesh，与 VoxelMeshImporter
## 同一入口），参数取 cube / scale=0.1 / world_origin；QVX 侧取同一份 voxel 数据、
## voxel_scale=0.1、center_offset=0（WORLD_ORIGIN），于是两侧几何逐三角形一致。
## cars.vox / teapot1.vox / teapot2.vox 的导入设置本来就是 cube，实测导入产物三角形数
## 与本函数产物完全相同（4638 / 39648 / 66470），可直接对照。
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


# ── 主流程 ───────────────────────────────────────────────────────────────────

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
	# 共享同一份 mesh 时 Godot 会把同 mesh + 同材质的实例合批（实测 deer×100：
	# 共享 19 draws / 各自唯一 118 draws），所以默认用共享——那才是"同一模型摆 N 份"
	# 在项目里的真实形态；unique 档专门用来把"批处理红利"从"每实例开销"里剥出来。
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
	# `_apply_built_chunk` 有一道"带外校验"：chunk 中心到相机 > lod_outer[0] + 半块 就丢弃不挂。
	# lod_count=1 时 lod_outer[0] == view_distance（默认 40）——于是**即使 visibility_mode=FULL**，
	# 离相机 40 单位以外的 chunk 也不会出现。基准里相机为了取景必须退远，不显式放大这个值
	# 就会得到"网格永远建不完 / draw call 与 surface 数凭空少一半"的假象（实测踩过：
	# deer ×400 只挂上 418/1600 个 chunk，还白等了 180 秒的超时）。
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
## 【为什么不能只按"半宽 / tan(fov)"算距离】那是"物体在原点、相机在 +Z 轴"的公式；
## 排布是二维网格时，相机按那个距离会落进网格内部（后排被背面剔除），
## 表现为 draw call 数远小于实例数、数字看着"性能很好"其实什么也没画。
## 这里改用**实测收敛**：沿视线方向逐步后退，直到包围盒 8 个角都投影进视口（留 6% 边距）。
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
## 超时也返回 false 并照测，但日志里会标出来，免得把"还没建完"当成"更快"。
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


## 采样一帧序列。用 PerfTool.sample_frames（p50/p95/p99 + 1% low + CV + 环境），
## 再补上引擎的 GPU/CPU 实测渲染耗时与本帧的绘制统计。
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
