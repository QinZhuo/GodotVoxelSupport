// 资产级烘焙光叠加：按 Godot 引擎 scene.glsl 复现 SH 光贴图（漫反射 + 方向性高光）。
//
// 引擎原文（简化）：
//   uvw.xy = uv2 * lightmap_uv_scale.zw + lightmap_uv_scale.xy
//   uvw.z  = float(lightmap_slice)                // SH 占 4 层，调用方已乘 4
//   l0   = tex(uvw + 0)
//   l1n1 = (tex(uvw + 1) - 0.5) * 2.0  … 其余两个同理
//   sh = l0 + l0*l1n1*n.y*4 + l0*l1_0*n.z*4 + l0*l1p1*n.x*4
//   ambient_light += sh;  ambient_light *= albedo;
//   // USE_LIGHTMAP_SPECULAR：由 l1 反推光方向，跑一次 light_compute 得到 lightmap_specular_light
//
// 由 AssetLightmapBinder 作为 next_pass 接到实例的 surface 材质后面，主材质资源不需要任何改动。
// 加色但不动 alpha：blend_add 的 RGB 会乘 src.a（src_alpha, one），alpha 又跟着累加，
// 落在同一像素上的描边标记（靠 alpha 值分槽）会被搅乱；premul_alpha 是 (one, one_minus_src_alpha)，
// 取 ALPHA = 0 时 RGB 全加、alpha 保持原值。
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_back;

// 整张图集 + 该资源占的矩形：不切图，位置由 AssetLightmapRegion 记录下来
uniform sampler2DArray lm_atlas : filter_linear;
uniform vec4 lm_uv;          // xy = 图集偏移, zw = 图集缩放
uniform int lm_slice;        // 该资源的层起始（页号 * 4）

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D roughness_tex : filter_linear;

uniform float metallic : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_default : hint_range(0.04, 1.0) = 0.5;
uniform float strength : hint_range(0.0, 8.0, 0.01) = 1.0;
// 必须是 uniform：写成常量会被判定为不透明，混合失效。
// 保持 0：premul_alpha 下 ALPHA 只影响「盖住多少底色」，0 就是纯加色、且不把 alpha 写脏。
uniform float opacity : hint_range(0.0, 1.0) = 0.0;

const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
const float PI_F = 3.14159265359;

void fragment() {
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);

	// UV2 是岛内局部坐标，乘缩放加偏移才落到图集上的位置
	vec2 luv = UV2 * lm_uv.zw + lm_uv.xy;
	vec3 l0 = texture(lm_atlas, vec3(luv, float(lm_slice))).rgb;
	vec3 l1n1 = (texture(lm_atlas, vec3(luv, float(lm_slice + 1))).rgb - vec3(0.5)) * 2.0;
	vec3 l1_0 = (texture(lm_atlas, vec3(luv, float(lm_slice + 2))).rgb - vec3(0.5)) * 2.0;
	vec3 l1p1 = (texture(lm_atlas, vec3(luv, float(lm_slice + 3))).rgb - vec3(0.5)) * 2.0;

	// ---- 漫反射：SH 求值后乘 albedo（对应 ambient_light *= albedo）----
	vec3 sh = l0;
	sh += l0 * l1n1 * n.y * 4.0;
	sh += l0 * l1_0 * n.z * 4.0;
	sh += l0 * l1p1 * n.x * 4.0;
	sh = max(sh, vec3(0.0)) * strength;

	vec3 alb = texture(albedo_tex, UV).rgb;
	vec3 color = sh * alb;

	// ---- 方向性高光：照抄 USE_LIGHTMAP_SPECULAR ----
	vec3 l1 = vec3(dot(l0 * l1p1, LUM), dot(l0 * l1n1, LUM), dot(l0 * l1_0, LUM));
	float l1_len = length(l1);
	float l0_lum = dot(l0, LUM);
	if (l1_len > 1e-5 && l0_lum > 1e-5) {
		vec3 light_dir = l1 / l1_len;
		float NdotL = max(dot(n, light_dir), 0.0);
		if (NdotL > 1e-4) {
			vec3 spec_color = sh / max(NdotL, 0.1);
			float directionality = clamp(l1_len / l0_lum, 0.0, 1.0);

			float rough = texture(roughness_tex, UV).g;
			rough = clamp(rough <= 0.0 ? roughness_default : rough, 0.04, 1.0);
			vec3 f0 = mix(vec3(0.04), alb, metallic);

			vec3 H = normalize(light_dir + V);
			float NdotV = max(dot(n, V), 1e-4);
			float NdotH = max(dot(n, H), 0.0);
			float LdotH = max(dot(light_dir, H), 0.0);

			float a = rough * rough;
			float a2 = a * a;
			float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
			float D = a2 / (PI_F * denom * denom);
			float k = a * 0.5;
			float G = (NdotL / (NdotL * (1.0 - k) + k)) * (NdotV / (NdotV * (1.0 - k) + k));
			vec3 F = f0 + (1.0 - f0) * pow(1.0 - LdotH, 5.0);

			float intensity = directionality * 2.0;
			color += D * G * F / (4.0 * NdotL * NdotV + 1e-4) * spec_color * NdotL * intensity;
		}
	}

	ALBEDO = color;
	ALPHA = opacity;
}
