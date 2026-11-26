@tool
class_name QVoxelRenderPreset
extends RefCounted
## 观感配方：对齐 MagicaVoxel 渲染图的那套"单太阳 + 亮天空 + 硬几何 + 照片级后期"。

## 视直径同时决定软阴影半影宽度与金属里那颗太阳盘的大小。
const SUN_ANGULAR := 2.2

## 长焦取景：压缩透视，模型才像"摆拍的模型"而不是"游戏截图"。
const FOV := 32.0

## 照着 MagicaVoxel 的「胶片」面板抄：曝光 1.0、暗角 0、ACES、2.2。
const TONEMAP := Environment.TONE_MAPPER_ACES
const TONEMAP_WHITE := 2.2
const EXPOSURE := 0.95
## MV 是"方向明暗 × 原色"的体素着色，颜色一点不掉；PBR + ACES 只要亮面逼近 1.0 就开始掉饱和
const SATURATION := 1.20

const AO_VOXELS := 2.2
const AO_INTENSITY := 3.0
## AO 只压环境光时几乎看不见；放到 0.45 才会在凹槽与接缝上留下暗线（体素模型的"立体感"多靠它）。
const AO_LIGHT_AFFECT := 0.45
const SSIL_VOXELS := 8.0

## 泛光只该负责"发光体自己的边缘"：真正的照明已交给 GI（见下文 GI 段），屏幕光晕再压一层
const GLOW_THRESHOLD := 2.6
const GLOW_INTENSITY := 0.2

## 天空既是环境光也是反射源，亮度直接决定通透度。
const SKY_TOP := Color(0.34, 0.42, 0.55)
const SKY_HORIZON := Color(0.66, 0.62, 0.56)
const SKY_GROUND := Color(0.18, 0.17, 0.16)
const SKY_GROUND_HORIZON := Color(0.30, 0.29, 0.27)
## 编辑层用深色平涂，别把建模界面刷成白天。
const BACKGROUND := Color(0.09, 0.10, 0.115)
## 布局层是"看图"的层级，用中灰棚底衬托模型。
const STUDIO_BACKGROUND := Color(0.385, 0.395, 0.41)
## 棚拍地面的 albedo（受光后屏幕上正好落到背景那一档，见 QVoxelierApp 的 ground）。
const GROUND_ALBEDO := Color(0.34, 0.35, 0.365)
## 环境光只是补暗部：给满等于四面加了一层无影灯，方向光就白打了，各面亮度糊成一档。
const SKY_AMBIENT := 0.5
const AMBIENT_ENERGY := 0.15
## 快照没有天空可借，环境光只能走颜色。
const SNAPSHOT_AMBIENT := Color(0.16, 0.16, 0.17)

const SHADOW_DISTANCE := 20.0

## 阴影伪影有三个来源，别混为一谈：
const SHADOW_BLUR := 2.6
const SHADOW_BIAS := 0.06
const SHADOW_NORMAL_BIAS := 1.0
## 满强度投出来是纯黑洞（环境光进不去、边缘又硬）；留一点直射穿透，影子才落成"灰"。
const SHADOW_OPACITY := 0.75

## 灯组：一律按**相机基准**摆位 —— 视点是最常变的东西，钉死在世界的灯一转就正对背光面。
const RIG := [
	{ "azimuth": -38.0, "elevation": 41.0, "energy": 1.2,
		"color": Color(1.0, 0.96, 0.91), "shadow": true, "sky": true },
	{ "azimuth": 65.0, "elevation": 6.0, "energy": 0.12,
		"color": Color(0.86, 0.90, 1.0), "shadow": false, "sky": false },
	{ "azimuth": 140.0, "elevation": 22.0, "energy": 0.16,
		"color": Color(1.0, 0.97, 0.94), "shadow": false, "sky": false },
	{ "azimuth": 0.0, "elevation": -52.0, "energy": 0.05,
		"color": Color(0.90, 0.93, 1.0), "shadow": false, "sky": false },
]

## 按配方建灯。
static func build_rig(parent: Node3D) -> Array:
	var lights := []
	if parent == null:
		return lights
	for i in RIG.size():
		var light := DirectionalLight3D.new()
		light.name = "Light%d" % i
		parent.add_child(light)
		lights.append(light)
	return lights

## 摆整组灯。
static func apply_rig(lights: Array, cam_basis: Basis, cast_shadow: bool,
		max_distance := SHADOW_DISTANCE) -> void:
	for i in mini(lights.size(), RIG.size()):
		var light := lights[i] as DirectionalLight3D
		if light == null:
			continue
		var cfg: Dictionary = RIG[i]
		_aim(light, cam_basis, cfg.azimuth, cfg.elevation)
		light.light_energy = cfg.energy
		light.light_color = cfg.color
		# 天空只能有一颗太阳：其余灯不进天空，否则天空的太阳盘会叠成一片。
		light.sky_mode = (DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY if cfg.sky
				else DirectionalLight3D.SKY_MODE_LIGHT_ONLY)
		if cfg.shadow:
			_apply_shadow(light, cast_shadow, max_distance)
		else:
			light.shadow_enabled = false

## 相机一转只调方向：能量与阴影不必重算。
static func aim_rig(lights: Array, cam_basis: Basis) -> void:
	for i in mini(lights.size(), RIG.size()):
		var light := lights[i] as DirectionalLight3D
		if light != null:
			var cfg: Dictionary = RIG[i]
			_aim(light, cam_basis, cfg.azimuth, cfg.elevation)

static func _aim(light: Light3D, cam_basis: Basis, azimuth_deg: float, elevation_deg: float) -> void:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	# 相机空间里 +Z 朝观察者、+X 朝屏幕右：先给"相对视线"的方位，再整体转到世界。
	var to_sun := cam_basis * Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	# 灯沿 -Z 照射，故让 -Z 指向太阳的反方向。
	var up := Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.RIGHT
	light.global_transform = Transform3D(Basis.looking_at(-to_sun, up), light.global_position)

static func _apply_shadow(light: DirectionalLight3D, enabled: bool, max_distance: float) -> void:
	light.shadow_enabled = enabled
	if not enabled:
		return
	light.light_angular_distance = SUN_ANGULAR
	light.shadow_blur = SHADOW_BLUR
	# 满强度（1.0）投出来的影子是纯黑：环境光进不去、边缘又硬，观感像贴了张黑纸。
	light.shadow_opacity = SHADOW_OPACITY
	light.shadow_bias = SHADOW_BIAS
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	light.directional_shadow_blend_splits = true
	# 阴影距离跟着取景走：模型小、相机近时收紧，纹素才落得准。
	light.directional_shadow_max_distance = maxf(max_distance, 5.0)
	light.directional_shadow_fade_start = 0.9

## `use_sky` = 有天空可借（视口）；快照背景是纯色或透明，取光只能走颜色。
static func apply_environment(env: Environment, voxel_scale: float, quality: bool,
		use_sky: bool) -> void:
	if env == null:
		return
	if use_sky:
		env.background_mode = Environment.BG_COLOR
		env.background_color = STUDIO_BACKGROUND if quality else BACKGROUND
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = SKY_AMBIENT
		env.ambient_light_energy = AMBIENT_ENERGY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = SNAPSHOT_AMBIENT
		env.ambient_light_energy = 1.0
	env.tonemap_mode = TONEMAP
	env.tonemap_white = TONEMAP_WHITE
	env.tonemap_exposure = EXPOSURE
	env.adjustment_enabled = true
	env.adjustment_saturation = SATURATION
	env.ssao_enabled = quality
	env.ssil_enabled = quality
	env.glow_enabled = quality
	env.ssr_enabled = quality and use_sky
	if not quality:
		return
	var vs := maxf(voxel_scale, 0.001)
	env.ssao_radius = AO_VOXELS * vs
	env.ssao_intensity = AO_INTENSITY
	env.ssao_detail = 0.5
	# 只压环境光（0.12）时 AO 几乎看不见；放到 0.45 才在体素的凹槽与接缝上留下暗线。
	env.ssao_light_affect = AO_LIGHT_AFFECT
	env.ssil_radius = SSIL_VOXELS * vs
	env.ssil_intensity = 1.0
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0
	env.glow_intensity = GLOW_INTENSITY
	env.glow_bloom = 0.012
	env.glow_hdr_threshold = GLOW_THRESHOLD
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

## ── 自发光照明（GI）─────────────────────────────────────────────
const GI_MARGIN := 1.12
## 格边长目标（体素）：比体素小、比面片粗一点，发光体素才不会糊成一团。
const GI_CELL_VOXELS := 0.4
## subdiv 是**指数**：0=64³ 1=128³ 2=256³ 3=512³。
const GI_SUBDIV_MAX := 2
## 世界变化后隔这么久才重烘：连续拖动 / 连笔只烘最后那一次。
const GI_BAKE_DELAY := 0.5

## 建 GI 探针。
static func build_gi(parent: Node3D) -> VoxelGI:
	if parent == null:
		return null
	var gi := VoxelGI.new()
	gi.name = "VoxelGI"
	parent.add_child(gi)
	return gi

## 把 GI 盒摆成"刚好罩住 aabb"并选好精度。
static func fit_gi(gi: VoxelGI, aabb: AABB, voxel_scale: float) -> bool:
	if gi == null or aabb.size == Vector3.ZERO:
		return false
	var size := aabb.size * GI_MARGIN
	gi.position = aabb.get_center()
	gi.size = size
	var cell := maxf(voxel_scale * GI_CELL_VOXELS, 0.0001)
	gi.subdiv = _subdiv_for(maxf(size.x, maxf(size.y, size.z)) / cell) as VoxelGI.Subdiv
	return true

static func _subdiv_for(cells: float) -> int:
	var sub := 0
	while sub < GI_SUBDIV_MAX and (64 << sub) < cells:
		sub += 1
	return sub

## 景深挂在相机上（4.x 从 Environment 移到了 CameraAttributes），且只在出图时开：
static func apply_dof(camera: Camera3D, focus_distance: float) -> void:
	if camera == null:
		return
	var attrs := camera.attributes as CameraAttributesPractical
	if attrs == null:
		attrs = CameraAttributesPractical.new()
		camera.attributes = attrs
	attrs.dof_blur_far_enabled = focus_distance > 0.0
	attrs.dof_blur_near_enabled = false
	if attrs.dof_blur_far_enabled:
		attrs.dof_blur_far_distance = focus_distance * 1.15
		attrs.dof_blur_far_transition = focus_distance * 0.6
		attrs.dof_blur_amount = 0.05

## 天空上色。
static func apply_sky(sky: Sky) -> void:
	if sky == null or not (sky.sky_material is ProceduralSkyMaterial):
		return
	var mat := sky.sky_material as ProceduralSkyMaterial
	mat.sky_top_color = SKY_TOP
	mat.sky_horizon_color = SKY_HORIZON
	mat.ground_bottom_color = SKY_GROUND
	mat.ground_horizon_color = SKY_GROUND_HORIZON
	mat.sky_energy_multiplier = 1.0
	mat.ground_energy_multiplier = 1.0
	mat.sun_angle_max = SUN_ANGULAR
	mat.sun_curve = 0.25
