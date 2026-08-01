shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

// 体素数据：3D纹理，R8格式，每个纹素存储材质ID（0=空，1-255=材质）
uniform sampler3D voxel_data;
// 体素网格尺寸（体素个数）
uniform ivec3 voxel_grid_size;
// 每个体素的世界单位大小
uniform float voxel_scale;
// 材质颜色数组（RGBA，A=1-trans）
uniform vec4 material_colors[256];
// 材质PBR属性（metal, rough, emission, unused）
uniform vec4 material_pbrs[256];

// 最大步进次数
#define MAX_STEPS 512
// 步进安全退出边界
#define MAX_DIST 1e6

void fragment() {
	// 将相机位置转换到模型局部空间
	vec3 camera_pos_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;

	// 将片段位置从视图空间转换到模型局部空间
	vec3 frag_pos_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 frag_pos_local = (inverse(MODEL_MATRIX) * vec4(frag_pos_world, 1.0)).xyz;

	// BoxMesh 以原点居中，偏移到体素网格空间 [0, size]
	// 相机/片段在局部空间的范围是 [-size/2, size/2]
	// 体素网格空间的范围是 [0, size]
	vec3 half_grid = vec3(voxel_grid_size) * 0.5;
	vec3 camera_pos_voxel = camera_pos_local / voxel_scale + half_grid;
	vec3 frag_pos_voxel = frag_pos_local / voxel_scale + half_grid;

	// 射线方向
	vec3 ray_dir = normalize(frag_pos_voxel - camera_pos_voxel);

	// ---- 射线与体素包围盒求交 ----
	vec3 grid_min = vec3(0.0);
	vec3 grid_max = vec3(voxel_grid_size);

	vec3 inv_dir = 1.0 / ray_dir;
	vec3 t_min = (grid_min - camera_pos_voxel) * inv_dir;
	vec3 t_max = (grid_max - camera_pos_voxel) * inv_dir;
	vec3 t1 = min(t_min, t_max);
	vec3 t2 = max(t_min, t_max);
	float t_near = max(max(t1.x, t1.y), t1.z);
	float t_far = min(min(t2.x, t2.y), t2.z);

	// 射线未命中包围盒
	if (t_near > t_far || t_far < 0.0) {
		discard;
	}

	// ---- DDA 两步级算法 ----
	// 第一步：从相机位置或近交点开始
	float t = max(t_near, 0.0);
	vec3 pos = camera_pos_voxel + ray_dir * t;

	// 限制在网格范围内
	pos = clamp(pos, grid_min - 0.001, grid_max + 0.001);

	// 当前体素坐标
	ivec3 voxel = ivec3(floor(pos));
	// 步进方向
	ivec3 step = ivec3(sign(ray_dir));

	// 沿各轴穿过一个体素所需的t值
	vec3 t_delta = abs(1.0 / ray_dir);
	// 处理零方向分量
	if (ray_dir.x == 0.0) { t_delta.x = 1e10; }
	if (ray_dir.y == 0.0) { t_delta.y = 1e10; }
	if (ray_dir.z == 0.0) { t_delta.z = 1e10; }

	// 到下一个体素边界的t值
	vec3 t_max_step;
	if (ray_dir.x > 0.0) { t_max_step.x = (ceil(pos.x) - pos.x) * t_delta.x; }
	else if (ray_dir.x < 0.0) { t_max_step.x = (pos.x - floor(pos.x)) * t_delta.x; }
	else { t_max_step.x = 1e10; }

	if (ray_dir.y > 0.0) { t_max_step.y = (ceil(pos.y) - pos.y) * t_delta.y; }
	else if (ray_dir.y < 0.0) { t_max_step.y = (pos.y - floor(pos.y)) * t_delta.y; }
	else { t_max_step.y = 1e10; }

	if (ray_dir.z > 0.0) { t_max_step.z = (ceil(pos.z) - pos.z) * t_delta.z; }
	else if (ray_dir.z < 0.0) { t_max_step.z = (pos.z - floor(pos.z)) * t_delta.z; }
	else { t_max_step.z = 1e10; }

	// 记录最后穿越的轴，用于计算法线
	int last_axis = 0;

	// 命中结果（循环结束后使用）
	bool hit = false;
	vec3 hit_normal;
	vec4 hit_color;
	vec4 hit_pbr;
	float hit_depth = 0.0;

	// 第二步：遍历体素网格
	for (int i = 0; i < MAX_STEPS; i++) {
		// 检查是否超出网格范围
		if (voxel.x < 0 || voxel.x >= voxel_grid_size.x ||
			voxel.y < 0 || voxel.y >= voxel_grid_size.y ||
			voxel.z < 0 || voxel.z >= voxel_grid_size.z) {
			break;
		}

		// 采样体素数据：将体素坐标映射到[0,1]纹理坐标
		vec3 uv = (vec3(voxel) + 0.5) / vec3(voxel_grid_size);
		float id_f = texture(voxel_data, uv).r;
		int id = int(id_f * 255.0 + 0.5);

		if (id > 0) {
			// 命中体素：计算法线（根据最后穿越的轴）
			vec3 normal;
			if (last_axis == 0) { normal = vec3(-float(step.x), 0.0, 0.0); }
			else if (last_axis == 1) { normal = vec3(0.0, -float(step.y), 0.0); }
			else { normal = vec3(0.0, 0.0, -float(step.z)); }

			hit_normal = normal;
			hit_color = material_colors[id];
			hit_pbr = material_pbrs[id];

			// 计算体素命中点的世界坐标，用于深度缓冲
			// 体素网格空间 [0,gs] → 局部空间 [-gs/2, gs/2] → 世界空间
			vec3 hit_pos_voxel = vec3(voxel) + 0.5;
			vec3 hit_pos_local = (hit_pos_voxel - half_grid) * voxel_scale;
			vec3 hit_pos_world = (MODEL_MATRIX * vec4(hit_pos_local, 1.0)).xyz;
			vec4 clip_pos = PROJECTION_MATRIX * VIEW_MATRIX * vec4(hit_pos_world, 1.0);
			hit_depth = clip_pos.z / clip_pos.w;

			hit = true;
			break;
		}

		// 沿最近轴前进到下一个体素
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

		// 安全退出：超出最大距离
		if (t > MAX_DIST) {
			break;
		}
	}

	// 根据命中结果输出或丢弃
	if (hit) {
		ALBEDO = hit_color.rgb;
		ALPHA = hit_color.a;
		METALLIC = hit_pbr.x;
		ROUGHNESS = hit_pbr.y;
		EMISSION = hit_color.rgb * hit_pbr.z;
		NORMAL = hit_normal;
		DEPTH = hit_depth;
	} else {
		discard;
	}
}