@tool
class_name QVoxelRenderPreset
extends RefCounted
## 观感配方：对齐 MagicaVoxel 渲染图的那套"单太阳 + 亮天空 + 硬几何 + 照片级后期"。
## 视口与离屏快照共用这一份数值 —— 各摆一份必然漂移（此前 SSAO 半径就出现过 0.6 / 0.8 不一致）。
## 半径按**体素**给：世界单位随 voxel_scale 变（默认 0.1），写死世界值一改缩放就失效。

## 视直径同时决定软阴影半影宽度与金属里那颗太阳盘的大小。
## 1° 时影子几乎是硬边，落在光滑地面上像贴了张黑纸；4 级级联 + 8192 之后纹素够密，
## 给到 2.2° 只会得到柔和的半影，不会碎成台阶。
const SUN_ANGULAR := 2.2

## 长焦取景：压缩透视，模型才像"摆拍的模型"而不是"游戏截图"。
const FOV := 32.0

## 照着 MagicaVoxel 的「胶片」面板抄：曝光 1.0、暗角 0、ACES、2.2。
## MV 那个 2.2 是输出 gamma（Godot 的 sRGB 输出已等效，不需要再设），拿来当 ACES 白点正合适：
## 1.0 线性压到 ~0.84，白车顶保住层次、红蓝警灯还是红蓝。
## 【曾把白点开到 6、曝光补到 1.8】那是拿曲线去救"光打太猛"的高光，结果中间调一起被抬起来，
## 整幅发灰发虚 —— 根子在灯太亮（见 RIG），曲线只是背锅的。
const TONEMAP := Environment.TONE_MAPPER_ACES
const TONEMAP_WHITE := 2.2
const EXPOSURE := 0.95
## MV 是"方向明暗 × 原色"的体素着色，颜色一点不掉；PBR + ACES 只要亮面逼近 1.0 就开始掉饱和
## （青蓝车身的红通道被抬起来，看着发白）。补一层饱和把这部分拽回来，别再往灯上加。
const SATURATION := 1.20

const AO_VOXELS := 2.2
const AO_INTENSITY := 3.0
## AO 只压环境光时几乎看不见；放到 0.45 才会在凹槽与接缝上留下暗线（体素模型的"立体感"多靠它）。
const AO_LIGHT_AFFECT := 0.45
const SSIL_VOXELS := 8.0

## 泛光只该负责"发光体自己的边缘"：真正的照明已交给 GI（见下文 GI 段），屏幕光晕再压一层
## 就只有糊掉发光体轮廓。故门槛抬到 2.0（普通白面 1.0 附近不再触发）、强度压到 0.2。
## 没有 GI 时这两个值会显得偏素 —— 但"素"是安全方向，过曝的发光体是救不回来的。
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
## 【背景要给得比地面 albedo 亮】背景是**未经光照**的纯色，地面还要挨一轮太阳与环境光；
## 两者用同一个值时，地面在屏幕上明显更亮，模型四周会多出一条硬邦邦的地平线。
const STUDIO_BACKGROUND := Color(0.385, 0.395, 0.41)
## 棚拍地面的 albedo（受光后屏幕上正好落到背景那一档，见 QVoxelierApp 的 ground）。
## 【跟着 RIG 走】地面亮度 = albedo × 主光；主光一降，albedo 不提就塌成比背景暗的一条带。
const GROUND_ALBEDO := Color(0.34, 0.35, 0.365)
## 环境光只是补暗部：给满等于四面加了一层无影灯，方向光就白打了，各面亮度糊成一档。
const SKY_AMBIENT := 0.5
const AMBIENT_ENERGY := 0.15
## 快照没有天空可借，环境光只能走颜色。亮度要跟视口那份"天空 × 强度"折算后的一档，
## 否则同一批模型在视口里通透、导出就成了满屏奶白。
const SNAPSHOT_AMBIENT := Color(0.16, 0.16, 0.17)

const SHADOW_DISTANCE := 20.0

## 阴影伪影有三个来源，别混为一谈：
## 1) 受光面上的斜向细纹 —— **shadow acne**，靠 bias 压；
## 2) 半影边缘的阶梯 —— **纹素密度**，靠级联与收紧距离（实测 4096→8192 无改善，瓶颈不在这）；
## 3) 斜边台阶 —— 其实是**几何边缘**，阴影贴图再大也治不了，只能靠 MSAA（见 .tscn 的 msaa_3d）。
## 【bias 必须以体素为尺度】旧值 0.2 / 4.0 是按"室外大场景"给的量级：一台 32³ 的小车只有
## 3 个世界单位高，normal_bias 4.0 等于把整条阴影沿法线推出模型之外 —— 实测阴影**完全不出现**，
## 画面只剩环境光，所有模型都像贴纸浮在底上。1 体素 ≈ 0.1 世界单位，故取 0.06 / 1.0。
const SHADOW_BLUR := 2.6
const SHADOW_BIAS := 0.06
const SHADOW_NORMAL_BIAS := 1.0
## 满强度投出来是纯黑洞（环境光进不去、边缘又硬）；留一点直射穿透，影子才落成"灰"。
const SHADOW_OPACITY := 0.75

## 灯组：一律按**相机基准**摆位 —— 视点是最常变的东西，钉死在世界的灯一转就正对背光面。
## 方位角 0 = 正对观察者、负值偏屏幕左；仰角正值 = 灯在模型上方。
## 三点布光：主光定方向（唯一投影），辅光定暗部下限，轮廓光把边缘从深背景里剥出来，
## 底光化掉体素朝下的死黑面。
## 【能量别往 3 上堆】主光 2.9 时受光面的辐射亮度到 1.6 以上，ACES 一压就整片去饱和：
## 青蓝车身洗成灰白、橙色褪成浅桃。
## 【1.2 是量出来的，不是估的】过曝从来不是"白车顶辐射 1.0 就爆"，而是**整幅都停在
## ACES 的肩部**：白顶 0.85、蓝顶 0.86、橙 0.8，所有面挤在同一档，眼睛只看到一片亮。
## 主光 1.2 后白顶落到 0.78、蓝顶 0.79，明暗差回来了，颜色才立住。
## 别再用"把背景压暗"去救过曝 —— 那只会让模型更黑地贴在灰底上，模型本身一点没降。
## 【仰角也别抬到 48】太阳一高，顶面吃满、侧面只剩环境光，车身上半截亮下半截暗，
## 明暗差被 ACES 压成两档 —— 而 MV 的侧面同样挨光。压到 41°，侧面才回到同一亮度区间。
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
	# 满强度（1.0）投出来的影子是纯黑：环境光进不去、边缘又硬，观感像贴了张黑纸。
	# 留一点直射穿透（0.62），影子才落成"灰"而不是"洞"。
	light.shadow_opacity = SHADOW_OPACITY
	light.shadow_bias = SHADOW_BIAS
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
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
