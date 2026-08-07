@tool
class_name GLSLShaderEffect extends CompositorEffect

@export_multiline var define_code: String = "const float SCALE = 2;":
	set(value):
		mutex.lock()
		define_code = value
		shader_is_dirty = true
		mutex.unlock()

@export_multiline var main_code: String = "color.rgb = (get_normal_roughness(uv_norm).rgb - 0.5) * SCALE;":
	set(value):
		mutex.lock()
		main_code = value
		shader_is_dirty = true
		mutex.unlock()

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var nearest_sampler: RID

var mutex := Mutex.new()
var shader_is_dirty: bool = true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()


# 系统通知，我们要对提醒我们即将被销毁的通知做出反应。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():
			# 释放我们的着色器也会释放任何依赖项，比如管线！
			RenderingServer.free_rid(shader)
		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler)


#region 此区域中的代码在渲染线程上运行。
# 检查我们的着色器是否已更改并需要重新编译。
func _check_shader() -> bool:
	if not rd:
		return false

	var new_shader_code: String = ""

	# 检查我们的着色器是否已变脏。
	mutex.lock()
	if shader_is_dirty:
		new_shader_code = TEMPLATE_SHADER.replace("#MAIN_CODE", main_code).replace("#DEFINE_CODE", define_code);
		shader_is_dirty = false
	mutex.unlock()

	# 我们没有（新）着色器？
	if new_shader_code.is_empty():
		return pipeline.is_valid()

	# 应用模板。

	# 旧的出局。
	if shader.is_valid():
		rd.free_rid(shader)
		shader = RID()
		pipeline = RID()

	# 新的入局。
	var shader_source := RDShaderSource.new()

	shader_source.language = RenderingDevice.ShaderLanguage.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = new_shader_code
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)

	if shader_spirv.compile_error_compute != "":
		LogTool.error("着色器", shader_spirv.compile_error_compute)
		LogTool.error("着色器", "输入:", new_shader_code)
		return false

	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		return false

	pipeline = rd.compute_pipeline_create(shader)

	return pipeline.is_valid()


# 每帧由渲染线程调用。
func _render_callback(p_effect_callback_type: EffectCallbackType, p_render_data: RenderData) -> void:
	if rd and p_effect_callback_type == effect_callback_type and _check_shader():
		# 获取我们的渲染场景缓冲区对象，这使我们能够访问我们的渲染缓冲区。
		# 请注意，实现因渲染器而异，因此需要进行强制转换。
		var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		var scene_data: RenderSceneData = p_render_data.get_render_scene_data()
		if render_scene_buffers and scene_data:
			# 获取我们的渲染尺寸，这是 3D 渲染分辨率！
			var size: Vector2i = render_scene_buffers.get_internal_size()
			if size.x == 0 and size.y == 0:
				return

			# 我们可以在这里使用计算着色器。
			@warning_ignore("integer_division")
			var x_groups: int = (size.x - 1) / 8 + 1
			@warning_ignore("integer_division")
			var y_groups: int = (size.y - 1) / 8 + 1
			var z_groups: int = 1

			# 创建推送常量。
			# 必须按 16 字节对齐，并且顺序与着色器中定义的相同。
			var push_constant := PackedFloat32Array([
					size.x,
					size.y,
					0.0,
					0.0,
				])

			# 确保我们有一个采样器。
			if not nearest_sampler.is_valid():
				var sampler_state: RDSamplerState = RDSamplerState.new()
				sampler_state.min_filter = RenderingDevice.SamplerFilter.SAMPLER_FILTER_LINEAR
				sampler_state.mag_filter = RenderingDevice.SamplerFilter.SAMPLER_FILTER_LINEAR
				nearest_sampler = rd.sampler_create(sampler_state)

			# 遍历视图，以防我们在进行立体渲染。如果是单目，这没有额外开销。
			var view_count: int = render_scene_buffers.get_view_count()
			for view in view_count:
				# 获取我们的场景数据缓冲区的 RID。
				var scene_data_buffers: RID = scene_data.get_uniform_buffer()

				# 获取我们颜色图像的 RID，我们将从中读取并写入它。
				var color_image: RID = render_scene_buffers.get_color_layer(view)

				# 获取我们深度图像的 RID，我们将从中读取。
				var depth_image: RID = render_scene_buffers.get_depth_layer(view)

				var normal_roughness_image: RID = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")

				# 创建一个统一集合，这将被缓存，如果我们的视口配置发生更改，缓存将被清除。
				var scene_data_uniform := RDUniform.new()
				scene_data_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				scene_data_uniform.binding = 0
				scene_data_uniform.add_id(scene_data_buffers)
				var color_uniform := RDUniform.new()
				color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				color_uniform.binding = 1
				color_uniform.add_id(color_image)
				var depth_uniform := RDUniform.new()
				depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				depth_uniform.binding = 2
				depth_uniform.add_id(nearest_sampler)
				depth_uniform.add_id(depth_image)
				var normal_roughness_uniform := RDUniform.new()
				normal_roughness_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				normal_roughness_uniform.binding = 3
				normal_roughness_uniform.add_id(nearest_sampler)
				normal_roughness_uniform.add_id(normal_roughness_image)
				var uniform_set_rid: RID = UniformSetCacheRD.get_cache(shader, 0, [scene_data_uniform, color_uniform, depth_uniform, normal_roughness_uniform])

				# 设置我们的视图。
				push_constant[2] = view

				# 运行我们的计算着色器。
				var compute_list: int = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
				rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()
#endregion


const TEMPLATE_SHADER: String = """
#version 450

#define MAX_VIEWS 2

#include "godot/scene_data_inc.glsl"

// 在 (x, y, z) 维度上的调用配置。
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std140) uniform SceneDataBlock {
	SceneData data;
	SceneData prev_data;
}
scene_data_block;

layout(rgba16f, set = 0, binding = 1) uniform image2D color_image;
layout(set = 0, binding = 2) uniform sampler2D depth_texture;
layout(set = 0, binding = 3) uniform sampler2D normal_roughness_texture;

// 我们的推送常量。
// 必须按 16 字节对齐，就像我们从脚本传递的推送常量一样。
layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float view;
	float pad;
} params;

// 将法线/粗糙度从压缩格式转换为标准格式
vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
    float roughness = p_normal_roughness.w;
    if (roughness > 0.5) {
        roughness = 1.0 - roughness;
    }
    roughness /= (127.0 / 255.0);
    return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

vec4 get_normal_roughness(vec2 uv_norm) {
	vec4 raw_normal_roughness = texture(normal_roughness_texture, uv_norm);
	return normal_roughness_compatibility(raw_normal_roughness);
}

#DEFINE_CODE

// 每个调用中要执行的代码。
void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	int view = int(params.view);

	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}

	vec2 uv_norm = vec2(uv) / params.raster_size;
	vec2 texel_size = 1.0 / params.raster_size;

	vec4 color = imageLoad(color_image, uv);
	float depth = texture(depth_texture, uv_norm).r;

	#MAIN_CODE

	imageStore(color_image, uv, color);
}
"""
