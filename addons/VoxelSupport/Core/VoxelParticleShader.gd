@tool
class_name VoxelParticleShader
extends RefCounted

## GPU 粒子着色器的**唯一出处**：顶点粒子的 process 着色器 + 粒子绘制的网格着色器（不透明/透明双通道）。

# uniform 名（与 `VoxelRenderer` 的赋值点共用，改这里即可全链路生效）
const U_SRC_POS := "src_pos_tex"
const U_DST_POS := "dst_pos_tex"
const U_COLORS := "colors_tex"
## 材质属性纹理（R=metal, G=rough, B=emission）
const U_PROPS := "props_tex"
const U_GRID_WIDTH := "grid_width"
const U_PROGRESS := "progress"
const U_ARC := "arc"
const U_STAGGER := "stagger"
const U_SPIN := "spin"
const U_DRIFT := "drift_amplitude"
const U_DRIFT_SPEED := "drift_speed"
const U_DRIFT_SCALE := "drift_scale"
## 方块世界边长（绘制着色器用）。
const U_VOXEL_SIZE := "voxel_size"
## 自发光倍率（与网格路径的 MATERIAL_EMISSION_ENERGY 同量级）
const U_EMISSION_ENERGY := "emission_energy"
const U_SEED_SALT := "seed_salt"
## 整体不透明度。
const U_ALPHA := "alpha"

## 粒子更新着色器（`shader_type particles`）。
const PARTICLE_SHADER := """
shader_type particles;
render_mode disable_force, disable_velocity;

uniform sampler2D src_pos_tex : filter_nearest, repeat_disable;
uniform sampler2D dst_pos_tex : filter_nearest, repeat_disable;
uniform sampler2D colors_tex : filter_nearest, repeat_disable;
uniform sampler2D props_tex : filter_nearest, repeat_disable;
uniform int grid_width = 256;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float arc = 0.35;
uniform float stagger = 0.35;
uniform float spin = 1.0;
uniform float drift_amplitude = 0.0;
uniform float drift_speed = 0.3;
uniform float drift_scale = 0.6;
uniform float seed_salt = 0.0;

// 采样：INDEX → 纹理坐标。grid_width 与烘焙时的排布一致，故这是一次 texel 级精确查找。
vec3 sample_pos(sampler2D tex, int idx) {
	return texelFetch(tex, ivec2(idx % grid_width, idx / grid_width), 0).xyz;
}

// 稳定伪随机（同一个 INDEX 每帧相同）：错峰、翻滚轴、漂浮相位都靠它，
// 不能用 randf 之类的每帧随机量，否则粒子会抖成一团。
float hash01(float n) {
	return fract(sin(n * 12.9898 + seed_salt) * 43758.5453);
}

float ease(float t) {
	return t * t * (3.0 - 2.0 * t);
}

void start() {
	int idx = int(INDEX);
	vec3 a = sample_pos(src_pos_tex, idx);
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = a;
	VELOCITY = vec3(0.0);
	// COLOR.rgb = 线性基色，COLOR.a = 不透明度 —— 两者都由烘焙决定，**不要在这里改**。
	COLOR = texelFetch(colors_tex, ivec2(idx % grid_width, idx / grid_width), 0);
	// CUSTOM 把材质属性带到绘制端：绘制着色器通过 INSTANCE_CUSTOM 读它。
	// 【为什么走 CUSTOM 而不是绘制端再采一次纹理】粒子绘制端拿不到自己的 INDEX
	// （INSTANCE_ID 在多 pass / 排序后并不等于烘焙时的序号），CUSTOM 是唯一可靠的通道。
	CUSTOM = texelFetch(props_tex, ivec2(idx % grid_width, idx / grid_width), 0);
}

void process() {
	int idx = int(INDEX);
	vec3 a = sample_pos(src_pos_tex, idx);
	vec3 b = sample_pos(dst_pos_tex, idx);

	// 逐粒子错峰：每个粒子有自己的一段 [delay, 1] 用来完成位移，
	// 于是整体看起来是"先后飞出去"而不是"整块平移"。
	float delay = hash01(float(idx)) * stagger;
	float t = clamp((progress - delay) / max(1.0 - delay, 0.001), 0.0, 1.0);
	float e = ease(t);

	// 二次贝塞尔弧：中点沿"起点指向终点"的反方向外扩，制造中途散开再聚合的观感。
	// arc = 0 时退化为直线插值。
	vec3 dir = normalize(a - b + vec3(0.0001));
	vec3 mid = mix(a, b, 0.5) + dir * arc;
	vec3 pos = mix(mix(a, mid, e), mix(mid, b, e), e);

	// 漂浮层（与变形正交）：不改变目标形状，只叠一层缓慢的三轴正弦位移。
	// 标题/装饰效果只需要它，不需要 morph。
	if (drift_amplitude > 0.0) {
		float ph = hash01(float(idx) + 17.0) * 6.2831853;
		float ts = TIME * drift_speed;
		pos += vec3(
			sin(ts + ph),
			cos(ts * 0.83 + ph * 1.7),
			sin(ts * 0.61 + ph * 0.9)) * drift_amplitude;
	}

	TRANSFORM[3].xyz = pos;

	// 翻滚：飞行中旋转，落位后回正（t=1 时角度为 0）。
	// 【必须构造 mat4】给 TRANSFORM 赋 mat3 会报 "运算符=的参数无效：mat4, mat3"（已实测）。
	if (spin > 0.0) {
		float ang = (1.0 - e) * 6.2831853 * spin;
		float c = cos(ang);
		float s = sin(ang);
		float seed_v = float(idx);
		vec3 axis = normalize(vec3(
			hash01(seed_v + 1.0) - 0.5,
			hash01(seed_v + 2.0) - 0.5,
			hash01(seed_v + 3.0) - 0.5) + vec3(0.0, 0.0, 1.0));
		mat3 r = mat3(
			vec3(c + axis.x * axis.x * (1.0 - c), axis.y * axis.x * (1.0 - c) + axis.z * s, axis.z * axis.x * (1.0 - c) - axis.y * s),
			vec3(axis.x * axis.y * (1.0 - c) - axis.z * s, c + axis.y * axis.y * (1.0 - c), axis.z * axis.y * (1.0 - c) + axis.x * s),
			vec3(axis.x * axis.z * (1.0 - c) + axis.y * s, axis.y * axis.z * (1.0 - c) - axis.x * s, c + axis.z * axis.z * (1.0 - c)));
		mat4 m = mat4(vec4(r[0], 0.0), vec4(r[1], 0.0), vec4(r[2], 0.0), vec4(0.0, 0.0, 0.0, 1.0));
		m[3].xyz = pos;
		TRANSFORM = m;
	}

	// 【绝对不要写 COLOR.a】颜色纹理的 A 通道承载**自发光强度**，
	// 而 COLOR 正是从那张纹理采样来的。写 `COLOR.a = alpha` 会把每颗粒子的 emission
	// 全冲成 1.0 —— 于是**所有粒子都在满强度自发光**，
	// 白色车身直接过曝成纯白（实测：网格 0 个纯白像素，粒子 3302 个）。
	// 整体透明度由绘制着色器自己的 alpha uniform 负责，与这里无关。
}

"""

## 粒子绘制用的着色器（**两个通道**：不透明 + 透明）。

## 不透明通道：只画完全不透明的体素。
const DRAW_SHADER := """
shader_type spatial;
// 不写 ALPHA + only-opaque 粒子 = 材质判为不透明 -> 深度正常写入 -> 遮挡 100% 正确。
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// 方块的世界边长（= 体素边长 × point_scale），由 CPU 每帧写入。
uniform float voxel_size = 0.1;
// 【只在整体淡出时用】alpha >= 0.999 时本通道照常画不透明粒子；
// alpha < 0.999（淡出中）时本通道整体让位给透明通道，由那边统一混合。
uniform float alpha = 1.0;
// 自发光强度倍率：与网格路径的 MATERIAL_EMISSION_ENERGY 同量级。
uniform float emission_energy = 20.0;

varying vec4 v_color;
varying vec4 v_props;   // (metal, rough, emission, 未用)

void vertex() {
	// 只缩放、不改朝向：MODEL_MATRIX 由粒子 transform 提供（位置 + 飞行时的翻滚旋转）
	VERTEX = VERTEX * voxel_size;
	v_color = COLOR;
	v_props = INSTANCE_CUSTOM;
}

/*
 * 【为什么走真 PBR，而不是 unshaded + 自算 lambert】
 * 早期用 unshaded + 手写 lambert：颜色能对上，但**材质对不上**——
 * 金属没有金属感（手写高光顶不出环境反射与菲涅尔）、玻璃没有透明。
 * 网格路径用的是 StandardMaterial3D（真 PBR），两条路径永远差一层。
 * 现在把材质属性原样交给引擎，由它跑同一套 BRDF，金属/粗糙度/自发光自动一致。
 */
void fragment() {
	// 透明体素（玻璃）交给 DRAW_TRANS_SHADER；这里必须丢弃，
	// 否则它们会写深度、把后面的体素裁掉（"玻璃后面空了一块"）。
	if (v_color.a < 0.999) {
		discard;
	}
	// 整体淡出期间让位给透明通道（那边会画所有粒子并正常混合）
	if (alpha < 0.999) {
		discard;
	}

	ALBEDO = v_color.rgb;
	METALLIC = v_props.r;
	ROUGHNESS = v_props.g;
	EMISSION = v_color.rgb * v_props.b * emission_energy;
}
"""

## 透明通道：画玻璃（alpha < 0.999），以及整体淡出期间的**所有**粒子。
const DRAW_TRANS_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform float voxel_size = 0.1;
uniform float alpha = 1.0;
uniform float emission_energy = 20.0;

varying vec4 v_color;
varying vec4 v_props;

void vertex() {
	VERTEX = VERTEX * voxel_size;
	v_color = COLOR;
	v_props = INSTANCE_CUSTOM;
}

void fragment() {
	// 只有两种情况在这里画：① 玻璃；② 整体淡出中（alpha < 1，所有粒子都要半透明）。
	bool is_glass = v_color.a < 0.999;
	bool fading = alpha < 0.999;
	if (!is_glass && !fading) {
		discard;
	}

	ALBEDO = v_color.rgb;
	// 逐点不透明度（玻璃 0.72）× 整体淡出
	ALPHA = v_color.a * alpha;
	METALLIC = v_props.r;
	ROUGHNESS = v_props.g;
	EMISSION = v_color.rgb * v_props.b * emission_energy;
}
"""

## 生成粒子绘制用的材质（每次调用返回新实例，调用方按需缓存）。
static func make_draw_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = DRAW_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

## 生成透明通道的绘制材质。
static func make_draw_material_trans() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = DRAW_TRANS_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

## 生成粒子更新材质。
static func make_process_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = PARTICLE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat
