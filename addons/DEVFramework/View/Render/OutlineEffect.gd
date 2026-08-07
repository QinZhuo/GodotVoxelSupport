@tool
class_name OutlineEffect extends CompositorEffect
## 选中物体描边后处理
##
## 标记阶段：material_overlay + 默认深度测试 + blend_add → ALPHA=4.0
## 膨胀阶段：4方向端点检测 → outline_width 像素内的标记
## 合成阶段：描边像素混合 outline_color


#region --- 导出属性 ---

@export_group("Outline", "outline_")
@export var outline_color := Color(0.35, 0.65, 1.0, 1.0):
	set(v):
		outline_color = v
		_pc_dirty = true
@export var outline_width := 2.0:
	set(v):
		outline_width = v
		_pc_dirty = true
@export var outline_alpha := 1.0:
	set(v):
		outline_alpha = v
		_pc_dirty = true

const MARKER_THRESHOLD := 3.5

#endregion


#region --- 静态标记管理 ---

static var _outlined_count: int = 0
static var _overlay_mat: ShaderMaterial


static func set_outlined(on: bool, ...meshes: Array) -> void:
	if on:
		_outlined_count += 1
	else:
		_outlined_count -= 1
	var mat: ShaderMaterial = _get_overlay_mat() if on else null
	for mi in meshes:
		if not mi:
			continue
		mi.material_overlay = mat


static func _get_overlay_mat() -> ShaderMaterial:
	if _overlay_mat and _overlay_mat.shader:
		return _overlay_mat
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = _make_marker_shader()
	return _overlay_mat


static func _make_marker_shader() -> Shader:
	var s := Shader.new()
	# depth_test_enabled(默认) → 被挡像素不写入，自然避免透视
	# ALPHA=4.0              → 即使对着天空也累加到 4.0 > 3.5 阈值
	# ALBEDO=0               → blend_add 不改变场景颜色
	s.code = """shader_type spatial;
render_mode blend_add, unshaded, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 4.0;
}"""
	return s

#endregion


#region --- 渲染管线 ---

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var _compiled := false

var _pc_byte_cache: PackedByteArray
var _pc_dirty := true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and shader.is_valid():
		RenderingServer.free_rid(shader)


func _ensure_shader() -> bool:
	if _compiled:
		return pipeline.is_valid()
	if not rd:
		return false

	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = COMPUTE_SHADER
	var spv := rd.shader_compile_spirv_from_source(src)
	if spv.compile_error_compute != "":
		push_error("[OutlineEffect] ", spv.compile_error_compute)
		_compiled = true
		return false

	shader = rd.shader_create_from_spirv(spv)
	if not shader.is_valid():
		_compiled = true
		return false

	pipeline = rd.compute_pipeline_create(shader)
	_compiled = true
	return pipeline.is_valid()


func _rebuild_push_constant() -> void:
	_pc_byte_cache = PackedByteArray()
	_pc_byte_cache.resize(32)
	_pc_byte_cache.encode_float(0, outline_width)
	_pc_byte_cache.encode_float(4, outline_alpha)
	_pc_byte_cache.encode_float(8, MARKER_THRESHOLD)
	_pc_byte_cache.encode_float(12, 0.0)  # std430 vec4 对齐填充
	_pc_byte_cache.encode_float(16, outline_color.r)
	_pc_byte_cache.encode_float(20, outline_color.g)
	_pc_byte_cache.encode_float(24, outline_color.b)
	_pc_byte_cache.encode_float(28, outline_color.a)
	_pc_dirty = false


func _render_callback(p_type: EffectCallbackType, p_data: RenderData) -> void:
	if _outlined_count <= 0 or outline_width <= 0.0:
		return
	if not rd or p_type != effect_callback_type or not _ensure_shader():
		return

	var bufs: RenderSceneBuffersRD = p_data.get_render_scene_buffers()
	if not bufs:
		return

	var size := bufs.get_internal_size()
	if size.x == 0 and size.y == 0:
		return

	@warning_ignore("integer_division")
	var gx := (size.x - 1) / 8 + 1
	@warning_ignore("integer_division")
	var gy := (size.y - 1) / 8 + 1

	if _pc_dirty:
		_rebuild_push_constant()

	for view in bufs.get_view_count():
		var set_rid := UniformSetCacheRD.get_cache(shader, 0, [
			_bind_image(0, bufs.get_color_layer(view)),
		])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set_rid, 0)
		rd.compute_list_set_push_constant(cl, _pc_byte_cache, 32)
		rd.compute_list_dispatch(cl, gx, gy, 1)
		rd.compute_list_end()


static func _bind_image(bind: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = bind
	u.add_id(rid)
	return u

#endregion


#region --- 计算着色器 ---

const COMPUTE_SHADER := """#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set=0, binding=0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
	float outline_width;
	float outline_alpha;
	float marker_threshold;
	float _pad;
	vec4 outline_color;
} params;

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y)
		return;

	vec4 color = imageLoad(color_image, uv);

	bool is_marked = color.a > params.marker_threshold;
	float marked_f = float(is_marked);
	bool dilated = is_marked;

	// 4方向端点检测
	if (!dilated) {
		int w = int(params.outline_width);
		ivec2 nuv;

		nuv = uv + ivec2(-w, 0);
		if (nuv.x >= 0 && imageLoad(color_image, nuv).a > params.marker_threshold) dilated = true;

		if (!dilated) {
			nuv = uv + ivec2(w, 0);
			if (nuv.x < size.x && imageLoad(color_image, nuv).a > params.marker_threshold) dilated = true;
		}

		if (!dilated) {
			nuv = uv + ivec2(0, -w);
			if (nuv.y >= 0 && imageLoad(color_image, nuv).a > params.marker_threshold) dilated = true;
		}

		if (!dilated) {
			nuv = uv + ivec2(0, w);
			if (nuv.y < size.y && imageLoad(color_image, nuv).a > params.marker_threshold) dilated = true;
		}
	}

	float blend = float(dilated) - marked_f;
	blend = blend * params.outline_alpha * params.outline_color.a;
	color.rgb = mix(color.rgb, params.outline_color.rgb, blend);
	imageStore(color_image, uv, color);
}"""

#endregion
