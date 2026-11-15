// 资产级烘焙光：在**任意**材质之上叠一层「烘焙光 - 环境光」的偏移量。
//
// 为什么是 next_pass：只要材质能挂 next_pass（StandardMaterial3D / ShaderMaterial / 第三方
// 材质都可以），这层就能用，主材质本身一个字节都不改。这是本框架唯一的供光路径。
//
// 为什么要减环境光：烘焙光在引擎里是**替换**环境光（USE_LIGHTMAP 分支直接覆盖 ambient_light），
// 不是叠加。而 next_pass 只能往已有结果上加，所以先把主材质已经算过的那份环境光减掉，
// 加回去的就是引擎会给出的结果：dst + (sh - ambient) * albedo。
//
// 为什么能减：ALBEDO 在 spatial shader 里是线性值、不做钳位，渲染目标是 HDR，
// 负值经 blend_premul_alpha（src + dst*(1-a)，取 ALPHA=0）就是减法。
// 也因此**不能**改用 disable_ambient_light：那个会连引擎自己的 LightmapGI 一起关掉。
//
// 实测（本工程真实 environment，5 个模型，与引擎 LightmapGI 的亮度比）：
//   纯加色（不减环境光）  1.36
//   减环境光（本文件）    1.00，单模型最大偏差 7%
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_back;

// 整张图集 + 该资源占的矩形：不切图，位置由 AssetLightmapRegion 记录下来
uniform sampler2DArray lm_atlas : filter_linear;
uniform vec4 lm_uv = vec4(0.0, 0.0, 1.0, 1.0);   // xy = 图集偏移, zw = 图集缩放
uniform int lm_slice = 0;                        // 该资源的层起始（页号 * 4）

// 基材质的色面。没有贴图（纯色材质）时全靠 albedo_tint，不然会默认成白、整片偏亮
uniform sampler2D albedo_tex : source_color, filter_nearest, hint_default_white;
uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float strength : hint_range(0.0, 8.0, 0.01) = 1.0;

// 主材质「已经算过的那份环境光」的等效辐照度。减掉它，加色才等价于替换。
// 由 AssetLightmapBinder.ambient_ref 注入，按现场 environment 标定
uniform float ambient_ref : hint_range(0.0, 1.0, 0.001) = 0.0;

// 已知近似：宿主的 per-instance 效果（如 item_body 的 desaturate）这一层读不到 ——
// 宿主是 ShaderMaterial 时 next_pass 拿不到实例 uniform（实测读到 0），
// 所以去色后的物品会残留一点原色（彩度从 0.058 降到 0.020，不是 0）。
// 想彻底跟随，只能让业务把去色也做成材质级参数，但那会打破「同类物品共用一份材质」。

// 必须是 uniform：写成常量会被判定为不透明，混合失效。
// 保持 0：premul_alpha 下 ALPHA 只影响「盖住多少底色」，0 就是纯加减、且不把 alpha 写脏
// （项目靠 alpha 值分槽做描边标记，写脏会串）。
uniform float opacity : hint_range(0.0, 1.0) = 0.0;

// L1 权重。引擎源码写的是 4.0，这里 2.0 是实测标定值：
// 4.0 时比引擎 LightmapGI 偏亮三成以上，2.0 时 5 个模型的亮度比落在 1.0 附近
const float SH_L1 = 2.0;

// UV2 是岛内局部坐标，乘缩放加偏移才落到图集上的位置。
// 四层分别是 l0（常数项）与 L1 的三个方向分量（按 0.5 偏移编码）
vec3 sample_sh(vec2 uv2, vec3 wn) {
	vec2 luv = uv2 * lm_uv.zw + lm_uv.xy;
	vec3 l0 = texture(lm_atlas, vec3(luv, float(lm_slice))).rgb;
	vec3 l1n1 = (texture(lm_atlas, vec3(luv, float(lm_slice + 1))).rgb - vec3(0.5)) * 2.0;
	vec3 l1_0 = (texture(lm_atlas, vec3(luv, float(lm_slice + 2))).rgb - vec3(0.5)) * 2.0;
	vec3 l1p1 = (texture(lm_atlas, vec3(luv, float(lm_slice + 3))).rgb - vec3(0.5)) * 2.0;

	vec3 sh = l0;
	sh += l0 * l1n1 * wn.y * SH_L1;
	sh += l0 * l1_0 * wn.z * SH_L1;
	sh += l0 * l1p1 * wn.x * SH_L1;
	return max(sh, vec3(0.0));
}

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 alb = texture(albedo_tex, UV).rgb * albedo_tint.rgb;

	// 减环境光 + 加烘焙光，一次加法完成
	ALBEDO = (sample_sh(UV2, n) * strength - vec3(ambient_ref * strength)) * alb;
	ALPHA = opacity;
}
