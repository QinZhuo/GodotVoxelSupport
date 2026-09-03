@tool
class_name OutlineEffect extends CompositorEffect
## 物体描边后处理（单一颜色）
##
## 一个实例 = 一种描边。需要多种描边时，在 Compositor 资源里挂多个实例，
## 各自配置颜色 / 宽度 / 标记通道即可，实例之间互不干扰。
## 框架只负责"标记 → 膨胀 → 合成"这套统一处理，描边长什么样完全由项目配置决定。
##
## 使用方式：
##   · 项目侧：@export 直接引用实例资源，调用实例的 set_marked() 控制开关、
##     修改 outline_color 驱动颜色动画（参考项目的 RainbowOutlineStyle）
##   · 框架内部：悬停高亮等通用场景走 set_outlined() 静态快捷方式（固定使用通道 0）
##
## 标记阶段：material_overlay + 默认深度测试 + blend_add → ALPHA = 本实例的标记值
## 膨胀阶段：4 方向端点检测 → outline_width 像素内且属于本实例的标记
## 合成阶段：描边像素混合 outline_color
##
## 多实例靠标记 ALPHA 的量级区分：marker_slot 决定写入值，
## 判定区间取 [m, m²+2)，该区间在 blend_add 两种可能的混合模型下都成立，
## 且相邻槽位的区间互不重叠（因此不受官方文档未标注 alpha 因子的影响）。


#region --- 常量 ---

## 各槽位的标记 ALPHA。相邻槽位需满足 m[i+1] >= m[i]² + 2，
## 受 rgba16f 上限（65504）约束，最多 3 个槽位。
## 注意：背景 ALPHA（天空 1.0 + 半透明叠加）必须小于首槽位的 2.0，
## 否则无标记的背景像素会被误判为已标记。
const MARKER_ALPHAS: Array[float] = [2.0, 6.0, 38.0]
## push constant 字节数：4 个 float 参数 + vec4 颜色
const PUSH_CONSTANT_SIZE := 32

#endregion


#region --- 导出属性 ---

@export_group("Outline", "outline_")
## 描边颜色（运行时可逐帧修改实现动画，如项目侧的彩虹循环）
@export var outline_color := Color(0.35, 0.65, 1.0, 1.0):
	set(v):
		outline_color = v
		_pc_dirty = true
@export var outline_width := 2.0:
	set(v):
		outline_width = v
		_pc_dirty = true
@export_range(0.0, 1.0) var outline_alpha := 1.0:
	set(v):
		outline_alpha = v
		_pc_dirty = true
## 标记通道（0~2）：多个描边实例必须使用不同通道，避免标记 ALPHA 冲突。
## 框架内部的悬停高亮固定使用通道 0，项目自建描边请从 1 开始。
@export_range(0, 2, 1) var marker_slot: int = 0:
	set(v):
		if marker_slot == v:
			return
		if _marked_count > 0:
			push_warning("[OutlineEffect] 描边开启中修改槽位不会更新已标记网格，请先关闭描边")
		for other in _instances:
			if other != self and other.marker_slot == v:
				push_warning("[OutlineEffect] 标记通道 %d 已被其它描边实例占用，两者的描边将互相干扰" % v)
				break
		marker_slot = v
		_pc_dirty = true

#endregion


#region --- 实例管理 ---

## 已创建的实例，按创建顺序排列（每个实例在 _init 时登记，析构时移除）
static var _instances: Array[OutlineEffect] = []

## 本实例当前处于开启状态的网格数量
var _marked_count := 0
var _material: ShaderMaterial
var _material_marker := -1.0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var _compiled := false

var _pc_byte_cache := PackedByteArray()
var _pc_dirty := true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	_instances.append(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_instances.erase(self)
		if shader.is_valid():
			RenderingServer.free_rid(shader)


## 默认描边（标记通道 0）的快捷方式，供框架内部按钮悬停等通用场景使用。
## 项目侧请直接引用实例资源，调用实例的 set_marked()。
static func set_outlined(on: bool, ...meshes: Array) -> void:
	for e in _instances:
		if e.marker_slot == 0:
			e._apply(on, meshes)
			return
	push_error("[OutlineEffect] 未找到标记通道 0 的描边实例，请检查 Compositor 配置")


## 开关本实例的描边
## meshes 为空（或全为 null）时只维护计数、不改动材质
## （用于"描边已被其它实例接管"时同步释放计数）
func set_marked(on: bool, ...meshes: Array) -> void:
	_apply(on, meshes)


func _apply(on: bool, meshes: Array) -> void:
	_marked_count = maxi(0, _marked_count + (1 if on else -1))
	var mat: Material = null
	for mi in meshes:
		if not mi:
			continue
		# 材质惰性生成：仅计数模式（无有效网格）时不会白白创建
		if on and not mat:
			mat = _get_material()
		mi.material_overlay = mat


func marker_alpha() -> float:
	return MARKER_ALPHAS[clampi(marker_slot, 0, MARKER_ALPHAS.size() - 1)]


func _get_material() -> ShaderMaterial:
	var m := marker_alpha()
	if _material and _material_marker == m:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = _make_marker_shader(m)
	_material_marker = m
	return _material


static func _make_marker_shader(marker: float) -> Shader:
	var s := Shader.new()
	# depth_test_enabled(默认) → 被挡像素不写入，自然避免透视
	# ALPHA=marker        → 即使对着天空也累加到判定区间内
	# ALBEDO=0            → blend_add 不改变场景颜色
	s.code = "shader_type spatial;
render_mode blend_add, unshaded, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = %.1f;
}" % marker
	return s

#endregion


#region --- 渲染管线 ---

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
	var params := PackedFloat32Array([
		outline_width, outline_alpha, _marker_lo(), _marker_hi(),
		outline_color.r, outline_color.g, outline_color.b, outline_color.a,
	])
	_pc_byte_cache = params.to_byte_array()
	_pc_dirty = false


## 判定区间的下界：本实例写入的标记值
func _marker_lo() -> float:
	return marker_alpha()


## 判定区间的上界：m² + 2
## blend_add 对 alpha 的因子存在两种可能：
##   线性 m + dst.a   → 实际值域 [m,     m + 1)
##   平方 m² + dst.a  → 实际值域 [m²,    m² + 1)
## 两者的并集都落在 [m, m²+2) 内，故该上界对两种模型都成立。
func _marker_hi() -> float:
	var m := marker_alpha()
	return m * m + 2.0


func _render_callback(p_type: EffectCallbackType, p_data: RenderData) -> void:
	if _marked_count <= 0 or outline_width <= 0.0:
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
		rd.compute_list_set_push_constant(cl, _pc_byte_cache, PUSH_CONSTANT_SIZE)
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
	float marker_lo;
	float marker_hi;
	vec4 outline_color;
} params;

// 判定像素 ALPHA 是否属于本实例的标记（区间 [m, m²+2) 对两种混合模型都成立）
bool mine(float a) {
	return a >= params.marker_lo && a < params.marker_hi;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y)
		return;

	vec4 color = imageLoad(color_image, uv);

	bool is_marked = mine(color.a);
	bool dilated = is_marked;

	// 4 方向端点检测
	if (!dilated) {
		int w = int(params.outline_width);
		ivec2 nuv;

		nuv = uv + ivec2(-w, 0);
		if (nuv.x >= 0 && mine(imageLoad(color_image, nuv).a))
			dilated = true;

		if (!dilated) {
			nuv = uv + ivec2(w, 0);
			if (nuv.x < size.x && mine(imageLoad(color_image, nuv).a))
				dilated = true;
		}

		if (!dilated) {
			nuv = uv + ivec2(0, -w);
			if (nuv.y >= 0 && mine(imageLoad(color_image, nuv).a))
				dilated = true;
		}

		if (!dilated) {
			nuv = uv + ivec2(0, w);
			if (nuv.y < size.y && mine(imageLoad(color_image, nuv).a))
				dilated = true;
		}
	}

	float blend = (float(dilated) - float(is_marked)) * params.outline_alpha * params.outline_color.a;
	if (blend <= 0.0)
		return;

	color.rgb = mix(color.rgb, params.outline_color.rgb, blend);
	imageStore(color_image, uv, color);
}"""

#endregion
