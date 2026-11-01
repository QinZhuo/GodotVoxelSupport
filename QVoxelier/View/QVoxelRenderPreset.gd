@tool
class_name QVoxelRenderPreset
extends RefCounted
## 观感配方：对齐 MagicaVoxel 渲染图的那套"单太阳 + 亮天空 + 硬几何 + 照片级后期"。
## 视口与离屏快照共用这一份数值 —— 各摆一份必然漂移（此前 SSAO 半径就出现过 0.6 / 0.8 不一致）。
## 半径按**体素**给：世界单位随 voxel_scale 变（默认 0.1），写死世界值一改缩放就失效。

## 视直径同时决定软阴影半影宽度与金属里那颗太阳盘的大小。
## 1° 就够：半影再宽一点，低纹素密度下反而碎成台阶（角直径越大，PCSS 采样越容易露馅）。
const SUN_ANGULAR := 1.0

## 长焦取景：压缩透视，模型才像"摆拍的模型"而不是"游戏截图"。
const FOV := 32.0

const TONEMAP := Environment.TONE_MAPPER_ACES
const TONEMAP_WHITE := 6.0
## white = 6 是很"压"的曲线（1.0 亮度只落到 ~0.25），曝光必须跟着补，否则整幅欠曝。
## 补过头则浅色 palette（白墙、浅灰基座）整片贴到纯白，高光全丢 —— 1.8 是两类模型的分界。
const EXPOSURE := 1.8
## 调色板本就不艳，再压一档立刻"干净"。
const SATURATION := 0.92

const AO_VOXELS := 1.6
const AO_INTENSITY := 2.2
const SSIL_VOXELS := 8.0

## 阈值压在 1.3：浅色 palette 的白面本身就在 1.0 附近，取 1.0 会让整片白墙发光、边缘发糊。
const GLOW_THRESHOLD := 1.3
const GLOW_INTENSITY := 0.35

## 天空既是环境光也是反射源，亮度直接决定通透度；背景另给深色平涂，别把编辑界面刷成白天。
const SKY_TOP := Color(0.34, 0.42, 0.55)
const SKY_HORIZON := Color(0.66, 0.62, 0.56)
const SKY_GROUND := Color(0.18, 0.17, 0.16)
const SKY_GROUND_HORIZON := Color(0.30, 0.29, 0.27)
const BACKGROUND := Color(0.09, 0.10, 0.115)

const SHADOW_DISTANCE := 20.0

## 阴影伪影有三个来源，别混为一谈：
## 1) 受光面上的斜向细纹 —— **shadow acne**，主因。bias 太小，45° 入射的梯级薄片深度梯度
##    每纹素跨一个多纹素，0.03 这种室外大场景默认值必然起斜纹，实测 0.2 才压得住；
## 2) 半影边缘的阶梯 —— **纹素密度**。4 级级联把一张图切成四份、max_distance 又把纹素摊到
##    模型不存在的地方，故用 2 级级联 + 收紧距离（实测 4096→8192 无改善，说明瓶颈不在这里）；
## 3) 斜边台阶 —— 其实是**几何边缘**，阴影贴图再大也治不了，只能靠 MSAA（见 .tscn 的 msaa_3d）。
const SHADOW_BLUR := 1.2
const SHADOW_BIAS := 0.2
## 沿法线偏移是压 acne 的另一半：bias 管深度梯度，normal_bias 管陡坡。
## 体素是厚实方块，给到 4.0 也不会像细杆模型那样明显漏光。
const SHADOW_NORMAL_BIAS := 4.0

## 灯组：一律按**相机基准**摆位 —— 视点是最常变的东西，钉死在世界的灯一转就正对背光面。
## 方位角 0 = 正对观察者、负值偏屏幕左；仰角正值 = 灯在模型上方。
## 三点布光：主光定方向（唯一投影），辅光定暗部下限，轮廓光把边缘从深背景里剥出来，
## 底光化掉体素朝下的死黑面。主辅比 3:1 上下 —— 再高只剩两块明暗，再低模型就发平。
const RIG := [
	{ "azimuth": -38.0, "elevation": 48.0, "energy": 1.7,
		"color": Color(1.0, 0.96, 0.91), "shadow": true, "sky": true },
	{ "azimuth": 65.0, "elevation": 6.0, "energy": 0.45,
		"color": Color(0.86, 0.90, 1.0), "shadow": false, "sky": false },
	{ "azimuth": 140.0, "elevation": 22.0, "energy": 0.9,
		"color": Color(1.0, 0.97, 0.94), "shadow": false, "sky": false },
	{ "azimuth": 0.0, "elevation": -52.0, "energy": 0.18,
		"color": Color(0.90, 0.93, 1.0), "shadow": false, "sky": false },
]


## 按配方建灯。数量与参数只在这份 RIG 里写一次，视口和快照各建一份同源的。
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


## 摆整组灯。`cast_shadow = false` 用于"正在建模、只想看清形状"的层级。
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
	light.shadow_opacity = 1.0
	light.shadow_bias = SHADOW_BIAS
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_blend_splits = true
	# 阴影距离跟着取景走：模型小、相机近时收紧，纹素才落得准。
	light.directional_shadow_max_distance = maxf(max_distance, 5.0)
	light.directional_shadow_fade_start = 0.9


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


## ── 自发光照明（GI）─────────────────────────────────────────────
## 材质的 emission 只让体素自己发亮，照不到邻居；"灯笼照亮屋子"只能靠 GI。
## 三条路实测：SDFGI 免烘焙，但光晕出不了几个体素（+0.1 倍亮度）；LightmapGI 质量最好，
## 却要 UV2 且只能在编辑器里烘（运行时无 API）；VoxelGI 的 `bake()` 是运行时 API，
## 一次几百毫秒 —— 于是只在**布局（非编辑）层级**烘一次，编辑时每落笔重烘做不到也不需要。
## GI 只在本盒内生效，贴边会切出硬边，故比模型大一圈。
const GI_MARGIN := 1.12
## 格边长目标（体素）：比体素小、比面片粗一点，发光体素才不会糊成一团。
## 别往 0.25 压：那会让 32³ 网格跳到 256³，实测一次烘 1.7 秒（128³ 只要 0.4 秒）。
const GI_CELL_VOXELS := 0.4
## subdiv 是**指数**：0=64³ 1=128³ 2=256³ 3=512³。
## 上限压在 2 —— 烘焙耗时随格数平方涨，512³ 在大模型上是秒级，编辑体验会崩。
const GI_SUBDIV_MAX := 2
## 世界变化后隔这么久才重烘：连续拖动 / 连笔只烘最后那一次。
const GI_BAKE_DELAY := 0.5


## 建 GI 探针。初始 `data` 为空（= 不生效），由调用方在布局层级烘。
static func build_gi(parent: Node3D) -> VoxelGI:
	if parent == null:
		return null
	var gi := VoxelGI.new()
	gi.name = "VoxelGI"
	parent.add_child(gi)
	return gi


## 把 GI 盒摆成"刚好罩住 aabb"并选好精度。
## 返回 false 表示没有可照的东西（空世界），调用方应清掉 `data`（GI 随之失效）。
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
