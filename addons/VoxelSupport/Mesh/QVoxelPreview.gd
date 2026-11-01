@tool
class_name QVoxelPreview
extends RefCounted
## 世界 → 预览图（离屏渲染）。**不需要导入、不需要打开软件**：直接吃内存里的 `QVoxelWorld`。
## 【与导出同源】两边都走 `QVoxelMeshExport.build_mesh`，所以"看到的"就是"能导出的"。
## 【不需要导入管线】走导入就要落盘到 res:// + scan + reimport，改一次模型重来一遍；
## 这里一次求值、一块网格、渲一张图。
## 【必须在有渲染设备的进程里跑】headless 下没有渲染服务器，`can_render()` 会先拦掉。

const DEFAULT_SIZE := 512
const DEFAULT_YAW := 35.0
const DEFAULT_PITCH := 20.0
## 相机距离 = 包围球半径 × 该系数（FOV 35° 时模型约占画面六成）。
const DEFAULT_DIST := 2.6
const FOV := 35.0
const BACKGROUND := Color(0.106, 0.106, 0.106)
## 出图前等几帧：网格上传与材质编译都发生在帧边界，喂完数据立刻抓只会拿到空场景。
const WARMUP := 3


## 渲染成 Image。世界为空 / 进程不能渲染 / 没有几何时返回 null。
static func render(world: QVoxelWorld, opts := {}) -> Image:
	var o := normalize(opts)
	if world == null or not can_render():
		return null
	var mesh := QVoxelMeshExport.build_mesh(world)
	if mesh == null:
		return null
	var main := Engine.get_main_loop() as SceneTree
	if main == null:
		return null
	var vp := _build(mesh, o)
	# 挂在树根而不是场景里：SubViewport 的渲染跟着父 CanvasItem 的可见性走，
	# 挂在被收起的界面里怎么设 UPDATE_ALWAYS 都不出图。
	main.root.add_child(vp)
	for i in WARMUP:
		await main.process_frame
	# 编辑器不主动重绘，静置的视口可能一帧都没画过。
	RenderingServer.force_draw(false)
	await main.process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


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
	return {
		"size": clampi(int(opts.get("size", DEFAULT_SIZE)), 64, 4096),
		"yaw": float(opts.get("yaw", DEFAULT_YAW)),
		"pitch": clampf(float(opts.get("pitch", DEFAULT_PITCH)), -85.0, 85.0),
		"dist": maxf(float(opts.get("dist", DEFAULT_DIST)), 0.5),
		"bg": _color(opts.get("bg", BACKGROUND)),
		"transparent": bool(opts.get("transparent", false)),
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
	inst.mesh = mesh
	vp.add_child(inst)

	var box := mesh.get_aabb()
	var center := box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.5)
	var yaw := float(o["yaw"])
	var pitch := deg_to_rad(float(o["pitch"]))
	var azimuth := deg_to_rad(yaw)
	var dir := Vector3(cos(pitch) * sin(azimuth), sin(pitch), cos(pitch) * cos(azimuth))
	var cam := Camera3D.new()
	cam.fov = FOV
	cam.near = 0.01
	cam.far = radius * 50.0
	cam.look_at_from_position(center + dir * radius * float(o["dist"]), center, Vector3.UP)
	cam.current = true
	vp.add_child(cam)

	# 灯跟水平角一起转：任何角度都是"相机左上方来光"，不会转到模型背面糊成一片。
	var light := DirectionalLight3D.new()
	light.light_energy = 1.7
	light.shadow_enabled = true
	light.rotation_degrees = Vector3(-50.0, 30.0 + yaw, 0.0)
	vp.add_child(light)
	return vp


## 背景色：接受 Color 或 `#rrggbb` 字符串（MCP 传参一律走字符串）。
static func _color(v: Variant) -> Color:
	if v is Color:
		return v
	var s := str(v).strip_edges()
	return Color.html(s) if Color.html_is_valid(s) else BACKGROUND
