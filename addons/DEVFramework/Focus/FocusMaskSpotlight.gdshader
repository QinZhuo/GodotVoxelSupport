shader_type canvas_item;
// 屏幕空间聚光: 读"已经画好的一帧", 目标区域内原样显示(可提亮), 区域外压暗。
// 不挖洞、不提层、不与任何 CanvasLayer / SubViewport 比较层级 —— 因此嵌套子视口天然正确。
// 描边/外发光: 3D 目标用"重渲染贴图的 alpha"当轮廓, 2D 控件用圆角矩形 SDF。
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D silhouette : filter_linear, repeat_disable;
uniform bool use_silhouette = false;
uniform int sil_index = 0;

uniform vec4 rects[16];
// 每个目标自己的圆角(取自它自己的 StyleBox): 圆形按钮就是 48, 普通按钮就小
uniform float radii[16];
uniform int rect_count = 0;
uniform vec2 screen_size = vec2(1920.0, 1200.0);
// 轮廓贴图贴在屏幕上的哪块区域(像素): 3D 用整屏, 2D 离屏快照用目标矩形
uniform vec4 sil_rect = vec4(0.0, 0.0, 1920.0, 1200.0);

uniform vec4 dim_color : source_color = vec4(0.0, 0.0, 0.0, 0.62);
uniform float corner_radius = 10.0;
uniform float focus_boost = 1.15;
uniform vec4 outline_color : source_color = vec4(1.0, 0.86, 0.55, 1.0);
uniform float outline_width = 2.5;

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// 屏幕 UV → 轮廓贴图 UV(3D 是整屏, 2D 离屏快照贴在目标矩形上)
vec2 sil_local(vec2 screen_uv) {
	return (screen_uv * screen_size - sil_rect.xy) / max(sil_rect.zw, vec2(1.0));
}

float sil_at(vec2 screen_uv) {
	vec2 l = sil_local(screen_uv);
	if (l.x < 0.0 || l.x > 1.0 || l.y < 0.0 || l.y > 1.0) {
		return 0.0;
	}
	return texture(silhouette, l).a;
}

// 轮廓描边: 在轮廓外侧 outline_width 的距离上取 alpha, 只外扩这一圈(不向外发散)
float silhouette_edge(vec2 screen_uv, float width) {
	// 偏移必须在"屏幕 UV"空间: 轮廓贴图可能是贴在目标矩形上的一小块
	vec2 px = vec2(width) / max(screen_size, vec2(1.0));
	float a = 0.0;
	a = max(a, sil_at(screen_uv + vec2(px.x, 0.0)));
	a = max(a, sil_at(screen_uv - vec2(px.x, 0.0)));
	a = max(a, sil_at(screen_uv + vec2(0.0, px.y)));
	a = max(a, sil_at(screen_uv - vec2(0.0, px.y)));
	vec2 d = px * 0.7071;
	a = max(a, sil_at(screen_uv + d));
	a = max(a, sil_at(screen_uv - d));
	a = max(a, sil_at(screen_uv + vec2(d.x, -d.y)));
	a = max(a, sil_at(screen_uv + vec2(-d.x, d.y)));
	return a;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 src = texture(screen_tex, uv).rgb;
	vec2 px_pos = uv * screen_size;

	float sil = 0.0;
	if (use_silhouette) {
		sil = smoothstep(0.35, 0.7, sil_at(uv));
	}

	float cover = 0.0;
	float ring = 0.0;
	for (int i = 0; i < 16; i++) {
		if (i >= rect_count) {
			break;
		}
		vec4 r = rects[i];
		if (use_silhouette && i == sil_index) {
			continue;
		}
		// rects 是归一化坐标 → 还原成"逻辑像素"再算圆角形状
		vec2 r_pos = r.xy * screen_size;
		vec2 r_size = r.zw * screen_size;
		vec2 center = r_pos + r_size * 0.5;
		float radius = radii[i] > 0.0 ? radii[i] : corner_radius;
		float d = sd_round_box(px_pos - center, r_size * 0.5, min(radius, min(r_size.x, r_size.y) * 0.5));
		cover = max(cover, 1.0 - smoothstep(-0.75, 0.75, d));
		// 每个矩形各自描边: 不能整体二选一, 否则多目标时只有一个有边
		float edge = 1.0 - smoothstep(outline_width - 0.75, outline_width + 0.75, abs(d));
		ring = max(ring, edge * step(d, outline_width));
	}
	cover = max(cover, sil);
	if (use_silhouette) {
		ring = max(ring, smoothstep(0.35, 0.75, silhouette_edge(uv, outline_width)) * (1.0 - sil));
	}

	vec3 dimmed = mix(src, dim_color.rgb, dim_color.a);
	vec3 col = mix(dimmed, src * focus_boost, cover);
	col = mix(col, outline_color.rgb, ring * outline_color.a);

	COLOR = vec4(col, 1.0);
}
