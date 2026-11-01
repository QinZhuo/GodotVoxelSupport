@tool
class_name QVoxelRenderPreset
extends RefCounted
## 观感配方：对齐 MagicaVoxel 渲染图的那套"单太阳 + 亮天空 + 硬几何 + 照片级后期"。
## 视口与离屏快照共用这一份数值 —— 各摆一份必然漂移（此前 SSAO 半径就出现过 0.6 / 0.8 不一致）。
## 半径按**体素**给：世界单位随 voxel_scale 变（默认 0.1），写死世界值一改缩放就失效。

## 太阳视直径同时决定软阴影半影的宽度与金属里那颗太阳盘的大小；2° 够柔又不会糊。
const SUN_ENERGY := 2.0
const SUN_COLOR := Color(1.0, 0.95, 0.88)
const SUN_ANGULAR := 2.0
## 补光只负责"背光面别死黑"，再亮就把体素的方向感抹平。
const FILL_ENERGY := 0.15

## 长焦取景：压缩透视，模型才像"摆拍的模型"而不是"游戏截图"。
const FOV := 32.0

const TONEMAP := Environment.TONE_MAPPER_ACES
const TONEMAP_WHITE := 6.0
## white = 6 是很"压"的曲线（1.0 亮度只落到 ~0.25），曝光必须跟着补，否则整幅欠曝。
const EXPOSURE := 2.6
## 调色板本就不艳，再压一档立刻"干净"。
const SATURATION := 0.92

const AO_VOXELS := 1.6
const AO_INTENSITY := 2.2
const SSIL_VOXELS := 8.0

const GLOW_THRESHOLD := 1.0
const GLOW_INTENSITY := 0.35

## 天空既是环境光也是反射源，亮度直接决定通透度；背景另给深色平涂，别把编辑界面刷成白天。
const SKY_TOP := Color(0.34, 0.42, 0.55)
const SKY_HORIZON := Color(0.66, 0.62, 0.56)
const SKY_GROUND := Color(0.18, 0.17, 0.16)
const SKY_GROUND_HORIZON := Color(0.30, 0.29, 0.27)
const BACKGROUND := Color(0.09, 0.10, 0.115)

const SHADOW_DISTANCE := 20.0

static func sun_transform() -> Transform3D:
	return Transform3D(Vector3(-0.5, 0.35, -0.75), Vector3(0.0, 0.866, 0.5),
			Vector3(0.866, 0.35, 0.433), Vector3(0.0, 6.0, 0.0))


static func fill_transform() -> Transform3D:
	return Transform3D(Vector3(-0.70711, -0.31879, 0.63117), Vector3(0.0, 0.89262, 0.45084),
			Vector3(-0.70711, 0.31879, -0.63117), Vector3(0.0, 6.0, 0.0))


## 太阳 + 阴影。`cast_shadow = false` 用于"正在建模、只想看清形状"的层级。
static func apply_sun(light: DirectionalLight3D, cast_shadow: bool,
		max_distance := SHADOW_DISTANCE) -> void:
	if light == null:
		return
	light.transform = sun_transform()
	light.light_energy = SUN_ENERGY
	light.light_color = SUN_COLOR
	light.light_angular_distance = SUN_ANGULAR
	light.shadow_enabled = cast_shadow
	# 软度全交给视直径：再叠 blur 既糊又漏光。
	light.shadow_blur = 0.0
	light.shadow_opacity = 1.0
	light.shadow_bias = 0.03
	light.shadow_normal_bias = 1.5
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	light.directional_shadow_blend_splits = true
	# 阴影距离跟着取景走：模型小、相机近时收紧，纹素才落得准。
	light.directional_shadow_max_distance = maxf(max_distance, 5.0)
	light.directional_shadow_fade_start = 0.9


static func apply_fill(light: DirectionalLight3D) -> void:
	if light == null:
		return
	light.transform = fill_transform()
	light.light_energy = FILL_ENERGY


## `use_sky` = 有天空可借（视口）；快照背景是纯色或透明，取光只能走颜色。
## `quality = false` 关掉一切屏幕空间与后期 —— 建模时它们只会干扰判断。
static func apply_environment(env: Environment, voxel_scale: float, quality: bool,
		use_sky: bool) -> void:
	if env == null:
		return
	if use_sky:
		env.background_mode = Environment.BG_COLOR
		env.background_color = BACKGROUND
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 1.0
		env.ambient_light_energy = 1.0
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
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
	env.ssao_light_affect = 0.12
	env.ssil_radius = SSIL_VOXELS * vs
	env.ssil_intensity = 1.0
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0
	env.glow_intensity = GLOW_INTENSITY
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = GLOW_THRESHOLD
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT


## 景深挂在相机上（4.x 从 Environment 移到了 CameraAttributes），且只在出图时开：
## 浏览与编辑时糊掉当前模型只会碍事。`focus_distance <= 0` 即关闭。
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


## 天空上色。太阳盘尺寸与软阴影共用同一个视直径，金属里反射到的也就是同一颗太阳。
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
