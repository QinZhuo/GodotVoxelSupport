shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// 网格地板：解析式抗锯齿格线（在 UV 空间按"到最近格线的像素距离"求覆盖度）。
//
// 【为什么用着色器而不是线几何】33+33 条线段在掠射角会挤进同一像素互相叠加：
// 远边糊成一片亮雾（摩尔纹），且线宽随距离失真。这里用 fwidth 把线宽归一化到像素，
// 再按"每像素跨过多少格"自动淡出 —— 远处自然消隐，不需要按相机距离手调。
// 这是画参考网格的标准做法（Blender / MagicaVoxel 一类工具同理）。
//
// 【坐标约定】只在 UV（0~1，铺满整块地板）上算，于是与 voxel_scale 完全解耦：
// 缩放节点不会让线变粗变细，格距永远等于 cell_count 等分。

uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 0.06);
uniform vec4 major_color : source_color = vec4(1.0, 1.0, 1.0, 0.14);
// 地板横竖各有多少格（= 体素网格的 x / z 尺寸）。
uniform vec2 cell_count = vec2(32.0, 32.0);
// 每几格一条粗线。
uniform float major_step = 8.0;
uniform float minor_width = 1.0;
uniform float major_width = 1.4;
// 每像素跨过多少格时开始/完全淡出：格线密到一个像素挤不下时不画，避免糊成亮雾。
uniform float density_fade_start = 0.35;
uniform float density_fade_end = 1.1;
// 靠边淡出（UV 到中心的切比雪夫距离归一化）。边界本身由足印框负责告知，地板无需硬切。
uniform float edge_fade_start = 0.9;


// 到最近格线的覆盖度：1 = 正好压在线上，0 = 离得远。
float line_coverage(vec2 g, float width_px) {
	vec2 w = fwidth(g);
	// 到最近整数的距离（格为单位）→ 除以每像素跨过的格数 → 像素距离
	vec2 d = abs(fract(g - 0.5) - 0.5) / max(w, vec2(1e-6));
	return 1.0 - clamp(min(d.x, d.y) / width_px, 0.0, 1.0);
}

void fragment() {
	vec2 g = UV * cell_count;
	float minor = line_coverage(g, minor_width);
	float major = line_coverage(g / major_step, major_width);

	float a_minor = minor * line_color.a;
	float a_major = major * major_color.a;

	// 淡出：密度（远处掠射角）与边缘。两者都是"这里不该再画线"的信号。
	vec2 w = fwidth(g);
	float density = max(w.x, w.y);
	float fade = 1.0 - smoothstep(density_fade_start, density_fade_end, density);
	float r = max(abs(UV.x - 0.5), abs(UV.y - 0.5)) * 2.0;
	fade *= 1.0 - smoothstep(edge_fade_start, 1.0, r);

	ALBEDO = mix(line_color.rgb, major_color.rgb, step(a_minor, a_major));
	ALPHA = max(a_minor, a_major) * fade;
}
