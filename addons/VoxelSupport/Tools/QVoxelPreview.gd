@tool
class_name QVoxelPreview
extends RefCounted
## 世界 → 预览图（离屏渲染）。**不需要导入、不需要打开软件**：直接吃内存里的 `QVoxelWorld`。
## 【与导出同源】两边都走 `QVoxelMeshExport.build_mesh`，所以"看到的"就是"能导出的"。
## 【不需要导入管线】走导入就要落盘到 res:// + scan + reimport，改一次模型重来一遍；
## 这里一次求值、一块网格、渲一张图。
## 【必须在有渲染设备的进程里跑】headless 下没有渲染服务器，`can_render()` 会先拦掉。
## 【多视角 / 多帧 = 分镜表】两者都只是"这一张图拍几张"，统一成一个 shot 列表（相机位姿 + 帧号），
## 出来仍是**同一张 Image**：视角横向并排、帧纵向叠加；只有帧在变时沿横轴铺开（时间轴）。
## 单 shot 时原样返回、不拼、不加边距 —— 老调用方的行为与像素完全不变。

const DEFAULT_SIZE := 512
const DEFAULT_YAW := 35.0
const DEFAULT_PITCH := 20.0
## 相机距离 = 包围球半径 × 该系数（FOV 35° 时模型约占画面六成）。
const DEFAULT_DIST := 2.6
const FOV := 35.0
const BACKGROUND := Color(0.106, 0.106, 0.106)
## 出图前等几帧：网格上传与材质编译都发生在帧边界，喂完数据立刻抓只会拿到空场景。
const WARMUP := 3
## 拼图表总边长上限（GPU 纹理上限普遍 16384，留一半余量给 MSAA 与各后端差异）。
const MAX_SHEET := 8192
## 预设视角（yaw, pitch 度）。`top/bottom` 停在 ±85°：look_at 在 90° 会与 UP 共线而退化。
const VIEW_ANGLES := {
	"front": Vector2(0.0, 0.0),
	"back": Vector2(180.0, 0.0),
	"right": Vector2(90.0, 0.0),
	"left": Vector2(-90.0, 0.0),
	"top": Vector2(0.0, 85.0),
	"bottom": Vector2(0.0, -85.0),
	"iso": Vector2(DEFAULT_YAW, DEFAULT_PITCH),
}
const NODE_MESH := "Mesh"
const NODE_CAM := "Camera"
const NODE_LIGHT := "Light"


## 渲染成 Image。世界为空 / 进程不能渲染 / 没有几何时返回 null。
static func render(world: QVoxelWorld, opts := {}) -> Image:
	if world == null or not can_render():
		return null
	var main := Engine.get_main_loop() as SceneTree
	if main == null:
		return null
	var o := normalize(opts)
	var views: Array = o["views"]
	var frames := _resolve_frames(world, o["frames"])
	# 布局：视角横向并排、帧纵向叠加（挑视角要横着比，翻帧要顺着往下看）；
	# 只有帧在变时改沿横轴铺开 —— 那是 sprite sheet 的时间轴。
	var cols := maxi(views.size(), 1)
	var rows := frames.size()
	if cols == 1:
		cols = rows
		rows = 1
	o["size"] = _fit_size(int(o["size"]), cols, rows)

	var held := _held_frames(world)
	var tiles: Array = []
	tiles.resize(cols * rows)
	var vp: SubViewport = null
	var got := 0
	var cam := {}
	for fi in frames.size():
		_pin_frame(world, frames[fi])
		var mesh := QVoxelMeshExport.build_mesh(world)
		if mesh == null:
			continue
		if vp == null:
			vp = _build(mesh, o)
			# 挂在树根而不是场景里：SubViewport 的渲染跟着父 CanvasItem 的可见性走，
			# 挂在被收起的界面里怎么设 UPDATE_ALWAYS 都不出图。
			main.root.add_child(vp)
		else:
			(vp.get_node(NODE_MESH) as MeshInstance3D).mesh = mesh
		for vi in views.size():
			# 整张图共用一套机位（中心 + 距离）：各格缩放才对得上，动画的位移也不会被
			# "每帧重新居中"抹平 —— 这是 sprite sheet 与四视图共同的取景前提。
			if cam.is_empty():
				cam = _lock_camera(vp, views, o, _sheet_box(world, frames, vp))
			_aim(vp, views[vi], cam)
			# 首次要多等几帧（网格上传 / 材质编译），之后只换相机与几何，一帧足够。
			for i in (WARMUP if got == 0 else 1):
				await main.process_frame
			# 编辑器不主动重绘，静置的视口可能一帧都没画过。
			RenderingServer.force_draw(false)
			await main.process_frame
			var img := vp.get_texture().get_image()
			if img == null:
				continue
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)
			# 列 = 视角、行 = 帧，与上面定下的 cols/rows 是同一套 row-major（单视角时两式恰等）。
			tiles[vi + fi * views.size()] = img
			got += 1
	if vp != null:
		vp.queue_free()
	_restore_frames(world, held)
	if got == 0:
		return null
	return tiles[0] if got == 1 and cols * rows == 1 else _compose(tiles, cols, rows, o)


## 渲染并落盘（`.png` / 其它按 JPG）。返回 Error。
static func render_to(world: QVoxelWorld, path: String, opts := {}) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var img: Image = await render(world, opts)
	if img == null:
		return ERR_CANT_CREATE
	var ext := path.get_extension().to_lower()
	return img.save_png(path) if ext == "png" else img.save_jpg(path)


## 当前进程能不能离屏渲染（headless / 无渲染设备时不能）。
static func can_render() -> bool:
	return DisplayServer.get_name() != "headless"


## 选项归一化。MCP 工具 / 脚本 / 界面只认这一张字段表，避免三处各写一套默认值。
static func normalize(opts: Dictionary) -> Dictionary:
	var yaw := float(opts.get("yaw", DEFAULT_YAW))
	var pitch := clampf(float(opts.get("pitch", DEFAULT_PITCH)), -85.0, 85.0)
	return {
		"size": clampi(int(opts.get("size", DEFAULT_SIZE)), 64, 4096),
		"yaw": yaw,
		"pitch": pitch,
		"dist": maxf(float(opts.get("dist", DEFAULT_DIST)), 0.5),
		"bg": _color(opts.get("bg", BACKGROUND)),
		"transparent": bool(opts.get("transparent", false)),
		"views": _views(opts.get("views", ""), yaw, pitch),
		# 0 = 保持当前帧（单张）, -1 = 全部帧, n = 前 n 帧
		"frames": int(opts.get("frames", 0)),
		"gap": clampi(int(opts.get("gap", 0)), 0, 64),
	}


# 内部

static func _build(mesh: ArrayMesh, o: Dictionary) -> SubViewport:
	var size: int = o["size"]
	var transparent: bool = o["transparent"]
	var vp := SubViewport.new()
	vp.name = "VoxelPreview"
	vp.size = Vector2i(size, size)
	# 自带世界：场景里的地板、灯光、选线框都不会跟进来。
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.transparent_bg = transparent
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var e := env.environment
	e.background_mode = Environment.BG_CLEAR_COLOR if transparent else Environment.BG_COLOR
	e.background_color = o["bg"]
	# 透明那张没有天空可借，反射/环境光都取自背景色：两种背景的明暗才不会差一档。
	e.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.8, 0.9)
	e.ambient_light_energy = 0.55
	vp.add_child(env)

	var inst := MeshInstance3D.new()
	inst.name = NODE_MESH
	inst.mesh = mesh
	vp.add_child(inst)

	var cam := Camera3D.new()
	cam.name = NODE_CAM
	cam.fov = FOV
	cam.near = 0.01
	cam.current = true
	vp.add_child(cam)

	var light := DirectionalLight3D.new()
	light.name = NODE_LIGHT
	light.light_energy = 1.7
	light.shadow_enabled = true
	vp.add_child(light)

	var box := mesh.get_aabb()
	_aim(vp, Vector2(o["yaw"], o["pitch"]), _lock_camera(vp, [Vector2(o["yaw"], o["pitch"])], o, box))
	return vp


## 把相机/灯挪到某个视角。机位由调用方给：一组分镜共用同一个中心与距离，各格才可比。
static func _aim(vp: SubViewport, view: Vector2, cam: Dictionary) -> void:
	var center: Vector3 = cam["center"]
	var dist: float = cam["dist"]
	var camera := vp.get_node(NODE_CAM) as Camera3D
	camera.far = dist * 3.0
	camera.look_at_from_position(center + _dir_of(view) * dist, center, Vector3.UP)
	# 灯跟水平角一起转：任何角度都是"相机左上方来光"，不会转到模型背面糊成一片。
	(vp.get_node(NODE_LIGHT) as DirectionalLight3D).rotation_degrees = Vector3(-50.0, 30.0 + view.x, 0.0)


## 整张图的取景框：多帧用世界网格范围（各帧共享，帧间位移不会被裁掉），
## 单帧贴紧实际网格（构图饱满，也保持老图逐像素不变）。
static func _sheet_box(world: QVoxelWorld, frames: PackedInt32Array, vp: SubViewport) -> AABB:
	if frames.size() <= 1:
		return (vp.get_node(NODE_MESH) as MeshInstance3D).mesh.get_aabb()
	var res := QVoxelEvalEngine.evaluate_world(world, QVoxelEvalContext.new())
	return AABB(Vector3(res.origin), Vector3(res.grid_size))


## 整张图共用的机位：中心取整组取景框，距离取 `dist` 松紧偏好与"每个视角都不裁"的最大者。
static func _lock_camera(vp: SubViewport, views: Array, o: Dictionary, box: AABB) -> Dictionary:
	var d := maxf(box.size.length() * 0.5, 0.5) * float(o["dist"])
	for v in views:
		d = maxf(d, _fit(box, _dir_of(v)) * 1.06)
	return {"center": box.get_center(), "dist": d}


## 相机方向（由中心指向相机）。`top/bottom` 停在 ±85° 正是为了让叉乘不退化。
static func _dir_of(view: Vector2) -> Vector3:
	var azimuth := deg_to_rad(view.x)
	var pitch := deg_to_rad(view.y)
	return Vector3(cos(pitch) * sin(azimuth), sin(pitch), cos(pitch) * cos(azimuth))


## 这一视角下把 AABB 整个装进画面所需的距离。保守式：把深度整体后移，比精确透视裁切略松 ——
## 宁可多留白，也不要切掉模型的角。
static func _fit(box: AABB, dir: Vector3) -> float:
	var f := -dir
	var r := f.cross(Vector3.UP).normalized()
	var u := r.cross(f)
	var half := box.size * 0.5
	var hx := absf(r.x) * half.x + absf(r.y) * half.y + absf(r.z) * half.z
	var hy := absf(u.x) * half.x + absf(u.y) * half.y + absf(u.z) * half.z
	var hd := absf(f.x) * half.x + absf(f.y) * half.y + absf(f.z) * half.z
	return maxf(hx, hy) / tan(deg_to_rad(FOV * 0.5)) + hd


## 单格边长：格数多了就回缩，否则整张图会撞纹理上限（宁可见小，也要看得见）。
static func _fit_size(size: int, cols: int, rows: int) -> int:
	return clampi(size, 64, maxi(64, MAX_SHEET / maxi(maxi(cols, rows), 1)))


## 分镜拼成一张 contact sheet：行 = 视角、列 = 帧。空格留背景色。
static func _compose(tiles: Array, cols: int, rows: int, o: Dictionary) -> Image:
	var w: int = o["size"]
	var gap := int(o["gap"])
	var step := w + gap
	var sheet := Image.create(cols * w + (cols - 1) * gap, rows * w + (rows - 1) * gap, false,
			Image.FORMAT_RGBA8)
	# 透明模式下留空处就该真的空（create 出来已是全透明），不去糊背景色。
	if not o["transparent"]:
		sheet.fill(o["bg"])
	for i in tiles.size():
		var t: Image = tiles[i]
		if t != null:
			sheet.blit_rect(t, Rect2i(0, 0, w, w), Vector2i((i % cols) * step, (i / cols) * step))
	return sheet


## 视角表 → [[yaw, pitch], ...]。认 `"front,side"` 串 / 名称数组 / `{yaw, pitch}` 数组；
## 空或全不认识就退回单个 yaw/pitch（即老的单视角行为）。
static func _views(v: Variant, yaw: float, pitch: float) -> Array:
	var fallback := [Vector2(yaw, pitch)]
	var items: Array = []
	if v is String:
		items = str(v).replace(" ", ",").split(",", false)
	elif v is Array:
		items = v
	else:
		return fallback
	var out: Array = []
	for item in items:
		if item is Dictionary:
			out.append(Vector2(float(item.get("yaw", yaw)), float(item.get("pitch", pitch))))
		elif VIEW_ANGLES.has(str(item).strip_edges().to_lower()):
			out.append(VIEW_ANGLES[str(item).strip_edges().to_lower()])
	return out if not out.is_empty() else fallback


## 帧列表：`0` = 保持现状（单张）, `-1` = 全部, `n` = 前 n 帧。-1 是"别动 active_frame"。
static func _resolve_frames(world: QVoxelWorld, spec: int) -> PackedInt32Array:
	if spec == 0:
		return PackedInt32Array([-1])
	var total := 1
	for m in world.all_models():
		total = maxi(total, m.frame_count())
	return PackedInt32Array(range(total if spec < 0 else mini(spec, total)))


## 记下各模型当前帧，渲完还回去 —— 出图不该顺手改用户正在看的那一帧。
static func _held_frames(world: QVoxelWorld) -> Dictionary:
	var held := {}
	for m in world.all_models():
		if m.is_animated():
			held[m] = m.active_frame
	return held


static func _pin_frame(world: QVoxelWorld, frame: int) -> void:
	if frame < 0:
		return
	for m in world.all_models():
		if m.is_animated():
			m.active_frame = mini(frame, m.frame_count() - 1)


static func _restore_frames(world: QVoxelWorld, held: Dictionary) -> void:
	for m in held:
		(m as QVoxelModel).active_frame = held[m]


## 背景色：接受 Color 或 `#rrggbb` 字符串（MCP 传参一律走字符串）。
static func _color(v: Variant) -> Color:
	if v is Color:
		return v
	var s := str(v).strip_edges()
	return Color.html(s) if Color.html_is_valid(s) else BACKGROUND
