shader_type spatial;
render_mode skip_vertex_transform, cull_front, depth_draw_always, diffuse_burley, specular_schlick_ggx;

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
// 最小安全浮点值（避免除零）
#define EPSILON 1.0 / 65536.0

// 从顶点着色器传递的 flat varying
varying flat mat4 _MODELVIEW_MATRIX;
// 相机到顶点的方向向量（模型局部空间）
varying smooth vec3 RAY;

void vertex() {
	// 保存 MODELVIEW_MATRIX 作为 flat varying，避免透视插值
	_MODELVIEW_MATRIX = MODELVIEW_MATRIX;
	
	// 相机到顶点的方向向量（模型局部空间）
	// 使用 safe_vector 避免零分量
	vec3 camera_pos_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 raw_ray = VERTEX - camera_pos_local;
	RAY = sign(raw_ray) * max(vec3(EPSILON), abs(raw_ray));
	
	// 手动顶点变换：模型空间 → 视图空间
	// skip_vertex_transform 禁用了默认变换，需要手动处理
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 half_grid = vec3(voxel_grid_size) * 0.5;
	vec3 grid_size = vec3(voxel_grid_size);
	
	// 将 RAY（模型空间）转换到体素网格空间
	// 射线方向在体素空间（除以 voxel_scale 保持单位一致）
	vec3 ray_voxel = RAY / voxel_scale;
	
	// 计算相机在体素空间中的位置
	vec3 camera_pos_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 camera_pos_voxel = camera_pos_local / voxel_scale + half_grid;
	
	// 检测相机是否在体素包围盒内部
	// 当相机在盒子内部时，to_front_face_voxel 会计算出盒外的入口点，导致模型消失
	bool camera_inside = all(greaterThanEqual(camera_pos_voxel, vec3(0.0))) &&
		all(lessThanEqual(camera_pos_voxel, grid_size));
	
	// 计算 DDA 起始点
	vec3 start_voxel;
	if (camera_inside) {
		// 相机在内部：从相机位置开始遍历，沿射线方向向外步进
		start_voxel = clamp(camera_pos_voxel, vec3(0.0), grid_size);
	} else {
		// 相机在外部：使用标准射线-包围盒求交计算起始点
		// 比 to_front_face 更稳定，避免射线方向与体素轴接近平行时的数值问题
		vec3 ray_dir = normalize(ray_voxel);
		vec3 inv_dir = 1.0 / ray_dir;
		
		// 射线-包围盒求交
		vec3 t_min = (vec3(0.0) - camera_pos_voxel) * inv_dir;
		vec3 t_max = (grid_size - camera_pos_voxel) * inv_dir;
		vec3 t1 = min(t_min, t_max);
		vec3 t2 = max(t_min, t_max);
		float t_near = max(max(t1.x, t1.y), t1.z);
		
		// 从相机位置沿射线方向移动 t_near 到达盒子正面
		start_voxel = camera_pos_voxel + ray_dir * max(t_near, 0.0);
	}
	
	// 在射线方向上添加微小偏移，避免精确处于体素边界上
	// 当 start_voxel 恰好在体素边界时，t_max_step 可能为 0，导致跳过当前体素
	vec3 ray_norm = normalize(ray_voxel);
	start_voxel += ray_norm * 0.0001;
	start_voxel = clamp(start_voxel, vec3(0.0), grid_size);
	
	// ---- DDA 算法（Amanatides & Woo 经典实现） ----
	// 当前体素坐标
	ivec3 voxel = ivec3(floor(start_voxel));
	// 步进方向
	ivec3 step = ivec3(sign(ray_voxel));
	
	// 沿各轴穿过一个体素所需的t值
	vec3 ray_rec = 1.0 / ray_voxel;
	vec3 t_delta = abs(ray_rec);
	// 处理零方向分量
	if (ray_voxel.x == 0.0) t_delta.x = 1e10;
	if (ray_voxel.y == 0.0) t_delta.y = 1e10;
	if (ray_voxel.z == 0.0) t_delta.z = 1e10;
	
	// 到下一个体素边界的t值
	vec3 t_max_step;
	if (ray_voxel.x > 0.0) t_max_step.x = (ceil(start_voxel.x) - start_voxel.x) * t_delta.x;
	else if (ray_voxel.x < 0.0) t_max_step.x = (start_voxel.x - floor(start_voxel.x)) * t_delta.x;
	else t_max_step.x = 1e10;
	
	if (ray_voxel.y > 0.0) t_max_step.y = (ceil(start_voxel.y) - start_voxel.y) * t_delta.y;
	else if (ray_voxel.y < 0.0) t_max_step.y = (start_voxel.y - floor(start_voxel.y)) * t_delta.y;
	else t_max_step.y = 1e10;
	
	if (ray_voxel.z > 0.0) t_max_step.z = (ceil(start_voxel.z) - start_voxel.z) * t_delta.z;
	else if (ray_voxel.z < 0.0) t_max_step.z = (start_voxel.z - floor(start_voxel.z)) * t_delta.z;
	else t_max_step.z = 1e10;
	
	// 记录最后穿越的轴，用于计算法线和命中点
	int last_axis = 0;
	float t = 0.0;
	
	// 命中结果
	bool hit = false;
	vec3 hit_normal;
	vec4 hit_color;
	vec4 hit_pbr;
	vec3 hit_pos_voxel;
	
	// 遍历体素网格
	for (int i = 0; i < MAX_STEPS; i++) {
		// 检查是否超出网格范围
		if (voxel.x < 0 || voxel.x >= voxel_grid_size.x ||
			voxel.y < 0 || voxel.y >= voxel_grid_size.y ||
			voxel.z < 0 || voxel.z >= voxel_grid_size.z) {
			break;
		}
		
		// 采样体素数据：将体素坐标映射到[0,1]纹理坐标
		vec3 uv = (vec3(voxel) + 0.5) / grid_size;
		float id_f = texture(voxel_data, uv).r;
		int id = int(id_f * 255.0 + 0.5);
		
		if (id > 0) {
			// 命中体素
			// 计算法线（根据最后穿越的轴和步进方向）
			vec3 normal;
			if (last_axis == 0) normal = vec3(-float(step.x), 0.0, 0.0);
			else if (last_axis == 1) normal = vec3(0.0, -float(step.y), 0.0);
			else normal = vec3(0.0, 0.0, -float(step.z));
			
			hit_normal = normal;
			hit_color = material_colors[id];
			hit_pbr = material_pbrs[id];
			
			// 计算体素表面的精确命中点（在体素边界上，而非体素中心）
			// 根据最后穿越的轴，命中点位于该轴方向的体素边界面上
			if (last_axis == 0) {
				// X轴穿越：命中点在X轴边界上，Y/Z在体素中心
				hit_pos_voxel = vec3(
					float(voxel.x) + float(step.x > 0 ? 0 : 1),
					float(voxel.y) + 0.5,
					float(voxel.z) + 0.5
				);
			} else if (last_axis == 1) {
				// Y轴穿越
				hit_pos_voxel = vec3(
					float(voxel.x) + 0.5,
					float(voxel.y) + float(step.y > 0 ? 0 : 1),
					float(voxel.z) + 0.5
				);
			} else {
				// Z轴穿越
				hit_pos_voxel = vec3(
					float(voxel.x) + 0.5,
					float(voxel.y) + 0.5,
					float(voxel.z) + float(step.z > 0 ? 0 : 1)
				);
			}
			
			hit = true;
			break;
		}
		
		// DDA 步进：沿最近轴前进到下一个体素
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
		if (t > MAX_DIST) break;
	}
	
	// 根据命中结果输出或丢弃
	if (hit) {
		// 将命中点从体素网格空间转换到模型局部空间
		vec3 hit_pos_local = (hit_pos_voxel - half_grid) * voxel_scale;
		
		// 使用 _MODELVIEW_MATRIX（flat varying）计算深度
		// 确保与 vertex() 中的变换使用同一矩阵
		vec4 view_pos = _MODELVIEW_MATRIX * vec4(hit_pos_local, 1.0);
		vec4 clip_pos = PROJECTION_MATRIX * view_pos;
		float depth = clip_pos.z / clip_pos.w;
		
		// 设置 LIGHT_VERTEX 以实现正确的光照和阴影计算
		// 告诉 Godot 光照计算的"顶点"位置是体素命中点，而非盒子表面
		LIGHT_VERTEX = view_pos.xyz / view_pos.w;
		
		// 输出PBR属性
		ALBEDO = hit_color.rgb;
		ALPHA = hit_color.a;
		METALLIC = hit_pbr.x;
		ROUGHNESS = hit_pbr.y;
		EMISSION = hit_color.rgb * hit_pbr.z;
		NORMAL = hit_normal;
		DEPTH = depth;
	} else {
		discard;
	}
}