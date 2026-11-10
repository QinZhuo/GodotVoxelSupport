extends Node3D

## 体素粒子演示 —— **项目侧如何用插件的底层接口自己做效果**。
##
## 【这个场景的定位】插件只提供"把体素显示成粒子"的机制（VoxelRenderer 的粒子模式
## + QVoxelSource 的点云导出）。至于粒子**怎么动** —— 漂浮、消散、聚合、变形 ——
## 那是项目的表现效果，本项目不实现、也不该实现。这个 demo 就是示范"怎么在项目里自己写"。
##
## 【两种自定义方式，由易到难】
##   1. 改 uniform：插件默认的 process 着色器已经有 progress / drift_amplitude 两个旋钮，
##      简单效果（漂浮、散开后再聚）改这两个值就够了 —— 本 demo 的"漂浮"就是这样做的。
##   2. 换 process_material：想要完全自定义的运动（A→B 变形、按材质分批消散……），
##      就自己写一个 shader_type particles 的材质，赋给 renderer.particle_node.process_material。
##      点云已经由插件传到 uniforms 上了，直接采样即可（见 _make_custom_process_mat）。
##
## 键位：
##   1  静态显示（不动的粒子，就是模型本身）
##   2  漂浮（改 drift uniform —— 最简单的自定义）
##   3  散开（自己写的 process 着色器：按稳定种子把粒子推远）
##   4  聚合成形（同一份自定义着色器，progress 反向）
##   空格 重放当前效果
##   T  切换粒子/网格显示
##   F  切换粒子形状（方块 / 球）

const ASSET := "res://demo/cars.vox"

## 每个体素的世界尺寸。
@export var voxel_scale: float = 0.1

## 自动轮播间隔（秒）。0 = 不轮播。
@export var auto_interval: float = 4.0

var _renderer: VoxelRenderer
var _hud: Label
var _camera: Camera3D
var _mode: String = "float"
var _timer: float = 0.0
var _t: float = 0.0
## 自定义的 process 着色器材质（本项目自己写的"散开/聚合"运动）
var _custom_mat: ShaderMaterial
## 插件给的默认 process 材质（进场景时捕获一次）。
## 【必须单独存】切换过自定义材质后，particle_node.process_material 已经不是它了，
## 再靠"读当前 process_material"回去就会拿到自定义的那个（切不回静态）。
var _default_mat: ShaderMaterial


func _ready() -> void:
	_setup_camera()
	_setup_environment()
	_setup_hud()

	var vox := VoxAsset.from_asset(ASSET)
	if vox == null:
		push_error("[particle_demo] 读取 %s 失败" % ASSET)
		return
	var src := QVoxelSource.from_voxel_data(vox, 0, QVoxelSource.OriginMode.CONTENT_CENTER)
	_renderer = VoxelRenderer.new()
	_renderer.name = "Renderer"
	_renderer.data = src
	_renderer.voxel_scale = voxel_scale
	# FULL：这个 demo 要看完整模型，不需要流式/视锥管理
	_renderer.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	_renderer.particle_surface_only = false   # 要散开，必须留完整体积
	add_child(_renderer)

	# 等一帧让渲染器建好节点，再切粒子模式
	await get_tree().process_frame
	_renderer.display_mode = VoxelRenderer.DisplayMode.PARTICLES
	if _renderer.particle_node == null:
		push_error("[particle_demo] 粒子节点未创建")
		return
	_default_mat = _renderer.particle_node.process_material as ShaderMaterial
	_custom_mat = _make_custom_process_mat()
	_frame_camera()
	_set_mode("float")


## 项目自己写的 process 着色器：按稳定种子把粒子推远 / 收回。
## 【这就是"效果由项目实现"的样子】采样插件已经传好的点云纹理，然后自己决定怎么动。
func _make_custom_process_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type particles;
render_mode disable_force, disable_velocity;

uniform sampler2D src_pos_tex : filter_nearest, repeat_disable;
uniform sampler2D colors_tex : filter_nearest, repeat_disable;
uniform int grid_width = 256;
// 0 = 原位，1 = 完全散开
uniform float scatter : hint_range(0.0, 1.0) = 0.0;
// 散开半径（世界单位）
uniform float radius = 2.0;
uniform float spin = 1.0;

vec3 sample_pos(int idx) {
	return texelFetch(src_pos_tex, ivec2(idx % grid_width, idx / grid_width), 0).xyz;
}

void start() {
	int idx = int(INDEX);
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = sample_pos(idx);
	VELOCITY = vec3(0.0);
	COLOR = texelFetch(colors_tex, ivec2(idx % grid_width, idx / grid_width), 0);
}

void process() {
	int idx = int(INDEX);
	vec3 p0 = sample_pos(idx);
	// 用索引做确定性方向，避免每帧抖动（同名索引永远同方向）
	float a = float(idx) * 0.6180339;
	float b = float(idx) * 0.3819660;
	vec3 dir = normalize(vec3(cos(a * 6.283), sin(b * 6.283), sin(a * 3.1 + b)));
	// 二次缓动：散开过程前快后慢
	float e = scatter * scatter * (3.0 - 2.0 * scatter);
	vec3 pos = p0 + dir * radius * e;
	TRANSFORM[3].xyz = pos;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	# 【关键：复用插件已经上传好的点云纹理】它们就挂在默认 process 材质上，
	# 直接照抄过来即可，不必自己再问数据层要一遍。
	var defaults := _default_mat
	if defaults != null:
		for key in [VoxelParticleShader.U_SRC_POS, VoxelParticleShader.U_DST_POS,
				VoxelParticleShader.U_COLORS, VoxelParticleShader.U_PROPS,
				VoxelParticleShader.U_GRID_WIDTH]:
			mat.set_shader_parameter(key, defaults.get_shader_parameter(key))
	return mat


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 38.0
	add_child(_camera)


## 按点云的包围盒自动取景：写死位置在换模型后必然构图失衡。
## 【为什么用点云包围盒而不是体素包围盒】画面里看到的就是点云，用它的范围最直接；
## 散开效果会把粒子推远，故取景时额外留 60% 余量。
func _frame_camera() -> void:
	if _camera == null or _renderer == null or _renderer.particle_points.is_empty():
		return
	var pts := _renderer.particle_points
	var stride := QVoxelSource.PARTICLE_STRIDE
	var min_v := Vector3(INF, INF, INF)
	var max_v := -min_v
	for i in pts.size() / stride:
		var b := i * stride
		var p := Vector3(pts[b], pts[b + 1], pts[b + 2])
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	var center := (min_v + max_v) * 0.5
	var longest := (max_v - min_v).length()
	if longest <= 0.001:
		return
	# 只按点云本身取景。散开时粒子会飞出画面一部分 —— 那是对的：
	# 预留太多会把模型缩成一群尘埃，反而看不清形状。
	var half_fov := deg_to_rad(_camera.fov * 0.5)
	var dist := (longest * 0.5) / tan(half_fov) / 0.85
	var dirv := Vector3(0.45, 0.38, 0.81).normalized()
	_camera.look_at_from_position(center + dirv * dist, center)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.82, 0.9)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.7
	sun.rotation_degrees = Vector3(-35, 25, 0)
	add_child(sun)


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(24, 20)
	_hud.add_theme_font_size_override("font_size", 16)
	layer.add_child(_hud)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1: _set_mode("static")
		KEY_2: _set_mode("float")
		KEY_3: _set_mode("scatter")
		KEY_4: _set_mode("gather")
		KEY_SPACE: _set_mode(_mode)
		KEY_T:
			_renderer.display_mode = (
				VoxelRenderer.DisplayMode.MESH
				if _renderer.display_mode == VoxelRenderer.DisplayMode.PARTICLES
				else VoxelRenderer.DisplayMode.PARTICLES)
		KEY_F:
			# 形状是渲染器的机制（方块 / 球），网格与粒子共用同一个开关
			_renderer.voxel_shape = (
				VoxelRenderer.VoxelShape.SPHERE
				if _renderer.voxel_shape == VoxelRenderer.VoxelShape.CUBE
				else VoxelRenderer.VoxelShape.CUBE)


func _set_mode(mode: String) -> void:
	_mode = mode
	_timer = 0.0
	_t = 0.0
	if _renderer == null or _renderer.particle_node == null:
		return
	var defaults: ShaderMaterial = _default_mat
	if defaults == null:
		return

	match mode:
		"static":
			# 什么都不改：插件默认着色器 progress=0 就是"第 i 颗粒子站在第 i 个点上"
			if _custom_mat != null and defaults != _custom_mat:
				_renderer.particle_node.process_material = defaults
			defaults.set_shader_parameter(VoxelParticleShader.U_DRIFT, 0.0)
			defaults.set_shader_parameter(VoxelParticleShader.U_PROGRESS, 0.0)
		"float":
			# 最简单的自定义：只改插件给的 drift uniform
			_renderer.particle_node.process_material = defaults
			defaults.set_shader_parameter(VoxelParticleShader.U_DRIFT, voxel_scale * 0.9)
			defaults.set_shader_parameter(VoxelParticleShader.U_PROGRESS, 0.0)
		"scatter", "gather":
			# 完全自定义：换成我们自己的 process 着色器
			_custom_mat.set_shader_parameter("radius", maxf(_model_radius(), 1.0))
			_custom_mat.set_shader_parameter("scatter", 0.0)
			_renderer.particle_node.process_material = _custom_mat
	_update_hud()


## 模型的世界半径（散开距离按它取，换模型也不会散得太近/太远）。
func _model_radius() -> float:
	if _renderer == null or _renderer.data == null:
		return 1.0
	var b := VoxelWorldUtil.voxel_bounds(_renderer.data.get_voxels_dict_snapshot())
	if b.is_empty():
		return 1.0
	var lo: Vector3i = b["min"]
	var hi: Vector3i = b["max"]
	return ((Vector3(hi) - Vector3(lo)) * voxel_scale).length() * 0.5


func _process(delta: float) -> void:
	if _renderer == null or _renderer.particle_node == null:
		return
	_t += delta
	if _mode == "scatter" or _mode == "gather":
		# 0 -> 1 用 1.5 秒，来回循环
		var cycle := fmod(_t, 3.0) / 1.5
		var s := cycle if cycle <= 1.0 else 2.0 - cycle
		if _mode == "gather":
			s = 1.0 - s
		_custom_mat.set_shader_parameter("scatter", clampf(s, 0.0, 1.0))

	if auto_interval > 0.0:
		_timer += delta
		if _timer >= auto_interval:
			_timer = 0.0
			var modes := ["static", "float", "scatter", "gather"]
			_set_mode(modes[(modes.find(_mode) + 1) % modes.size()])
	_update_hud()


func _update_hud() -> void:
	if _hud == null or _renderer == null:
		return
	var titles := {
		"static": "静态粒子（插件默认着色器，progress=0）",
		"float": "漂浮（只改 drift uniform —— 最简单的自定义）",
		"scatter": "散开（自己写的 process 着色器）",
		"gather": "聚合成形（同一着色器，scatter 反向）",
	}
	var n := 0
	if _renderer.particle_points.size() > 0:
		n = _renderer.particle_points.size() / QVoxelSource.PARTICLE_STRIDE
	_hud.text = "\n".join([
		"体素粒子 —— 项目侧自定义效果示例",
		"当前：%s" % titles.get(_mode, _mode),
		"粒子 %d  ·  形状 %s  ·  FPS %d" % [n,
			"球" if _renderer.voxel_shape == VoxelRenderer.VoxelShape.SPHERE else "方块",
			Engine.get_frames_per_second()],
		"",
		"1 静态   2 漂浮   3 散开   4 聚合   空格 重放   T 切网格/粒子   F 切形状",
	])
