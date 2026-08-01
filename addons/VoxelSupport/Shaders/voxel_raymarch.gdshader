shader_type spatial;
render_mode skip_vertex_transform, cull_front, depth_draw_always, diffuse_burley, specular_schlick_ggx;

// ============================================================================
// 体素光线步进渲染器（Voxel Raymarch）
// ----------------------------------------------------------------------------
// 参考 viktor-ferenczi/godot-voxel 的设计理念：
//   不实现自定义光照，只通过 DDA 找到体素命中点，把 PBR 材质属性
//   （ALBEDO / METALLIC / ROUGHNESS / EMISSION）交给 Godot 内置光照管线处理。
//   这样可以完整利用 Godot 的 SDFGI / LightmapGI / ReflectionProbe / Glow /
//   SSAO 等高级渲染特性，获得与原生 mesh 渲染一致的全局光照质量。
//
// 额外能力：
//   - 自发光体素：EMISSION = color * emission（发光体素直接自发光）
//   - 自发光扩散：CPU 端 voxel_light 把自发光传播到周围体素，作为 EMISSION 补充
//   - 透明体素：ALPHA 半透明输出，由 Godot 透明管线混合
// ============================================================================

// 体素数据：3D纹理，R8格式，每个纹素存储材质ID（0=空，1-255=材质）
uniform sampler3D voxel_data;
// 体素自发光光照传播纹理：RGBA(H)
uniform sampler3D voxel_light : source_color, hint_default_black;
// 是否启用了光照传播
uniform bool has_light_propagation = false;
// 自发光间接光强度系数
uniform float indirect_light_intensity : hint_range(0.0, 5.0) = 1.0;
// 体素网格尺寸（体素个数）
uniform ivec3 voxel_grid_size;
// 每个体素的世界单位大小
uniform float voxel_scale;
// 材质颜色数组（RGBA，A=不透明度 1-trans）
uniform vec4 material_colors[256];
// 材质PBR属性（metal, rough, emission, ior）
uniform vec4 material_pbrs[256];

// 最大步进次数
#define MAX_STEPS 512
// 步进安全退出边界
#define MAX_DIST 1e6
// 最小安全浮点值
#define EPSILON 1.0 / 65536.0

// 从顶点着色器传递的 flat varying
varying flat mat4 _MODELVIEW_MATRIX;
// 相机到顶点的方向向量（模型局部空间）
varying smooth vec3 RAY;

void vertex() {
	_MODELVIEW_MATRIX = MODELVIEW_MATRIX;
	vec3 camera_pos_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 raw_ray = VERTEX - camera_pos_local;
	RAY = sign(raw_ray) * max(vec3(EPSILON), abs(raw_ray));
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// DDA 命中结果
struct Hit {
	bool hit;
	vec3 pos;      // 体素网格空间命中点
	vec3 normal;   // 体素网格空间法线
	ivec3 voxel;   // 命中体素坐标
	vec4 color;    // 材质颜色
	vec4 pbr;      // 材质PBR
};

// Amanatides-Woo DDA 体素遍历，返回最近的非空命中
Hit trace_ray(vec3 origin, vec3 dir, vec3 grid_size) {
	Hit result;
	result.hit = false;

	vec3 cam_voxel = origin;
	vec3 rd = normalize(dir);

	bool inside = all(greaterThanEqual(cam_voxel, vec3(0.0))) &&
		all(lessThanEqual(cam_voxel, grid_size));

	vec3 start_voxel;
	if (inside) {
		start_voxel = clamp(cam_voxel, vec3(0.0), grid_size);
	} else {
		vec3 inv_dir = 1.0 / rd;
		vec3 t_min = (vec3(0.0) - cam_voxel) * inv_dir;
		vec3 t_max = (grid_size - cam_voxel) * inv_dir;
		vec3 t1 = min(t_min, t_max);
		vec3 t2 = max(t_min, t_max);
		float t_near = max(max(t1.x, t1.y), t1.z);
		if (t_near > MAX_DIST) return result;
		start_voxel = cam_voxel + rd * max(t_near, 0.0);
	}

	start_voxel += rd * 0.0001;
	start_voxel = clamp(start_voxel, vec3(0.0), grid_size);

	ivec3 voxel = ivec3(floor(start_voxel));
	ivec3 step = ivec3(sign(rd));

	vec3 ray_rec = 1.0 / rd;
	vec3 t_delta = abs(ray_rec);
	if (rd.x == 0.0) t_delta.x = 1e10;
	if (rd.y == 0.0) t_delta.y = 1e10;
	if (rd.z == 0.0) t_delta.z = 1e10;

	vec3 t_max_step = vec3(1e10);
	if (rd.x > 0.0) {
		t_max_step.x = (ceil(start_voxel.x) - start_voxel.x) * t_delta.x;
	} else if (rd.x < 0.0) {
		t_max_step.x = (start_voxel.x - floor(start_voxel.x)) * t_delta.x;
	}
	if (rd.y > 0.0) {
		t_max_step.y = (ceil(start_voxel.y) - start_voxel.y) * t_delta.y;
	} else if (rd.y < 0.0) {
		t_max_step.y = (start_voxel.y - floor(start_voxel.y)) * t_delta.y;
	}
	if (rd.z > 0.0) {
		t_max_step.z = (ceil(start_voxel.z) - start_voxel.z) * t_delta.z;
	} else if (rd.z < 0.0) {
		t_max_step.z = (start_voxel.z - floor(start_voxel.z)) * t_delta.z;
	}

	int last_axis = 0;
	float t = 0.0;

	for (int i = 0; i < MAX_STEPS; i++) {
		if (voxel.x < 0 || voxel.x >= voxel_grid_size.x ||
			voxel.y < 0 || voxel.y >= voxel_grid_size.y ||
			voxel.z < 0 || voxel.z >= voxel_grid_size.z) {
			break;
		}

		vec3 uv = (vec3(voxel) + 0.5) / grid_size;
		float id_f = texture(voxel_data, uv).r;
		int id = int(id_f * 255.0 + 0.5);

		if (id > 0) {
			vec3 normal;
			if (last_axis == 0) normal = vec3(-float(step.x), 0.0, 0.0);
			else if (last_axis == 1) normal = vec3(0.0, -float(step.y), 0.0);
			else normal = vec3(0.0, 0.0, -float(step.z));

			vec3 hit_pos_voxel;
			if (last_axis == 0) {
				hit_pos_voxel = vec3(
					float(voxel.x) + float(step.x > 0 ? 0 : 1),
					float(voxel.y) + 0.5,
					float(voxel.z) + 0.5);
			} else if (last_axis == 1) {
				hit_pos_voxel = vec3(
					float(voxel.x) + 0.5,
					float(voxel.y) + float(step.y > 0 ? 0 : 1),
					float(voxel.z) + 0.5);
			} else {
				hit_pos_voxel = vec3(
					float(voxel.x) + 0.5,
					float(voxel.y) + 0.5,
					float(voxel.z) + float(step.z > 0 ? 0 : 1));
			}

			result.hit = true;
			result.pos = hit_pos_voxel;
			result.normal = normal;
			result.voxel = voxel;
			result.color = material_colors[id];
			result.pbr = material_pbrs[id];
			return result;
		}

		// DDA 步进
		if (t_max_step.x < t_max_step.y) {
			if (t_max_step.x < t_max_step.z) {
				t = t_max_step.x;
				voxel.x += step.x;
				t_max_step.x += t_delta.x;
				last_axis = 0;
			} else {
				t = t_max_step.z;
				voxel.z += step.z;
				t_max_step.z += t_delta.z;
				last_axis = 2;
			}
		} else {
			if (t_max_step.y < t_max_step.z) {
				t = t_max_step.y;
				voxel.y += step.y;
				t_max_step.y += t_delta.y;
				last_axis = 1;
			} else {
				t = t_max_step.z;
				voxel.z += step.z;
				t_max_step.z += t_delta.z;
				last_axis = 2;
			}
		}
		if (t > MAX_DIST) break;
	}
	return result;
}

// 在表面外侧采样自发光间接光
vec3 sample_indirect(vec3 hit_pos, vec3 normal, vec3 grid_size) {
	if (!has_light_propagation) return vec3(0.0);
	vec3 sample_pos = hit_pos + normal * 0.6;
	ivec3 sv = ivec3(floor(sample_pos));
	sv = clamp(sv, ivec3(0), ivec3(voxel_grid_size) - ivec3(1));
	vec3 light_uv = (vec3(sv) + 0.5) / grid_size;
	vec4 light = texture(voxel_light, light_uv);
	return clamp(light.rgb * indirect_light_intensity, vec3(0.0), vec3(1.0));
}

void fragment() {
	vec3 half_grid = vec3(voxel_grid_size) * 0.5;
	vec3 grid_size = vec3(voxel_grid_size);

	vec3 ray_voxel = RAY / voxel_scale;
	vec3 camera_pos_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 camera_pos_voxel = camera_pos_local / voxel_scale + half_grid;
	vec3 cam_origin_voxel = camera_pos_voxel;

	Hit hit = trace_ray(cam_origin_voxel, ray_voxel, grid_size);

	if (hit.hit) {
		vec3 hit_pos_local = (hit.pos - half_grid) * voxel_scale;
		vec4 view_pos = _MODELVIEW_MATRIX * vec4(hit_pos_local, 1.0);
		vec4 clip_pos = PROJECTION_MATRIX * view_pos;
		float depth = clip_pos.z / clip_pos.w;

		// 设置 LIGHT_VERTEX，让 Godot 在体素命中点计算光照/阴影
		LIGHT_VERTEX = view_pos.xyz / view_pos.w;

		vec4 color = hit.color;
		vec4 pbr = hit.pbr;
		float opacity = color.a;   // 不透明度 (1-trans)
		float metallic = pbr.x;
		float emission = pbr.z;

		// 输出 PBR 材质属性，交给 Godot 原生光照管线处理
		ALBEDO = color.rgb;
		ALPHA = opacity;
		METALLIC = metallic;
		ROUGHNESS = pbr.y;

		// 自发光：发光体素自身发光
		EMISSION = color.rgb * emission;

		// 非自发光体素接收相邻自发光扩散的间接光（作为自发光照明补充）
		if (has_light_propagation && emission <= 0.0) {
			EMISSION += sample_indirect(hit.pos, hit.normal, grid_size);
		}

		// 法线：模型空间 → 视图空间
		NORMAL = normalize((_MODELVIEW_MATRIX * vec4(hit.normal, 0.0)).xyz);
		DEPTH = depth;
	} else {
		discard;
	}
}
