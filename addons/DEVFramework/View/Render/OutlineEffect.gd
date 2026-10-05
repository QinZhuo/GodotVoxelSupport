@tool
class_name OutlineEffect extends CompositorEffect
## 物体描边后处理（单一颜色，屏幕空间膨胀）
##
## 一个实例 = 一种描边。需要多种描边时，在 Compositor 资源里挂多个实例，
## 各自配置颜色 / 宽度 / 槽位即可，实例之间互不干扰。
## 框架只负责"标记 → 膨胀 → 合成"这套统一处理，描边长什么样完全由项目配置决定。
##
## == 公共接口 ==
##   · OutlineEffect.set_outlined(on, ...meshes)  静态快捷方式，固定走槽位 0
##     （框架内部悬停高亮等通用场景用）
##   · 实例.set_marked(on, ...meshes)             项目侧引用实例资源后直接调用
##   · outline_color / outline_width / outline_alpha / marker_slot
##     运行时可改；outline_color 逐帧修改即可实现颜色动画（如彩虹循环）
##
## == 渲染流程（全部发生在 POST_TRANSPARENT：透明绘制之后、色调映射/辉光/景深之前）==
##   ① 标记：被标记网格挂 material_overlay（blend_add + ALBEDO=0 + ALPHA=槽位标记值），
##      颜色缓冲只被抬高的 alpha，RGB 不受影响
##   ② 膨胀合成：计算着色器按 alpha 判定标记像素，把 ring 画到 outline_width 像素内的
##      "非标记"像素上
##   ③ alpha 归位：紧接一趟把标记像素的 alpha 设回 1.0，别把内部标记值留给下游
##
## == 槽位 ==
##   多实例靠标记 alpha 的量级区分。写入是线性相加（单层 = 1 + m，多层重叠 = 1 + m·k），
##   判定区间取 [m, m²+2)：既覆盖叠层范围，又与相邻槽位的区间不重叠。


#region 常量

## 各槽位的标记 alpha。相邻槽位需满足 m[i+1] >= m[i]² + 2（见文件头"槽位"说明），
## 受 rgba16f 上限约束最多 3 个。背景 alpha（不透明处为 1.0）必须小于首槽位值。
const MARKER_ALPHAS: Array[float] = [2.0, 6.0, 38.0]

## push constant 字节数：4 个 float 标量 + vec4 颜色 + vec4 附加参数（std430 下 vec4 需 16 字节对齐）
const PUSH_CONSTANT_SIZE := 48

## 标记材质的绘制顺序：放到透明队列最后，保证标记 alpha 在所有透明绘制之后才写入。
## 否则后绘制的半透明面（典型：开了 refraction 的玻璃面）会按自己的 alpha 把标记值
## 混合掉 ⇒ 像素落到判定区间之外 ⇒ 描边丢失，并在两种轮廓之间逐帧闪。
const MARKER_RENDER_PRIORITY := 127

## 计算着色器的两种模式（push constant extra.x）
const MODE_DILATE := 0.0
const MODE_RESTORE := 1.0

#endregion


#region 导出属性

@export_group("Outline", "outline_")
## 描边颜色（运行时可逐帧修改实现动画，如项目侧的彩虹循环）
@export var outline_color := Color(0.35, 0.65, 1.0, 1.0):
	set(v):
		outline_color = v
		_pc_dirty = true

## 描边宽度（像素，屏幕空间恒定）
@export var outline_width := 2.0:
	set(v):
		outline_width = v
		_pc_dirty = true

@export_range(0.0, 1.0) var outline_alpha := 1.0:
	set(v):
		outline_alpha = v
		_pc_dirty = true

## 标记槽位（0~2）：多个描边实例必须使用不同槽位，避免标记 alpha 冲突。
## 框架内部的悬停高亮固定使用槽位 0，项目自建描边请从 1 开始。
@export_range(0, 2, 1) var marker_slot: int = 0:
	set(v):
		if marker_slot == v:
			return
		if _marked_count > 0:
			push_warning("[OutlineEffect] 描边开启中修改槽位不会更新已标记网格，请先关闭描边")
		for other in _instances:
			if other != self and other.marker_slot == v:
				push_warning("[OutlineEffect] 槽位 %d 已被其它描边实例占用，两者的描边将互相干扰" % v)
				break
		marker_slot = v
		_pc_dirty = true

#endregion


#region 公共接口

## 本实例的槽位对应的标记 alpha（供外部查询/调试）
func marker_alpha() -> float:
	return MARKER_ALPHAS[clampi(marker_slot, 0, MARKER_ALPHAS.size() - 1)]


## 开关本实例的描边。
## meshes 为空（或全为 null）时只维护计数、不改动材质
## （用于"描边已被其它实例接管"时同步释放计数）。
func set_marked(on: bool, ...meshes: Array) -> void:
	_apply(on, meshes)


## 槽位 0 描边的静态快捷方式，供框架内部按钮悬停等通用场景使用。
## 项目侧请引用实例资源后调用 set_marked()。
static func set_outlined(on: bool, ...meshes: Array) -> void:
	for e in _instances:
		if e.marker_slot == 0:
			e._apply(on, meshes)
			return
	push_error("[OutlineEffect] 未找到槽位 0 的描边实例，请检查 Compositor 配置")

#endregion


#region 实例管理

## 已创建的实例，按创建顺序排列（_init 登记，析构移除）
static var _instances: Array[OutlineEffect] = []

## 本实例当前处于标记状态的网格集合。
## ⚠️ 计数以集合为准，而不是"开/关调用次数±1"：调用方常常对"没标过的网格"也发关闭
## （例如一次性清空所有格子），按次数计数会被钳到 0，之后网格明明带着标记材质也不再渲染描边。
var _marked := {}

## 兼容旧字段：标记中的网格数量
var _marked_count: int:
	get():
		return _marked.size()

var _material: ShaderMaterial
var _material_marker := -1.0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var _compiled := false

var _pc_dilate := PackedByteArray()
var _pc_restore := PackedByteArray()
var _pc_dirty := true

## 本效果实际运行过的视口尺寸（RenderSceneBuffersRD 的 internal size），
## 供 _viewport_runs_here() 兜底判断"这个视口跑不跑本效果"。
var _active_sizes := {}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()
	_instances.append(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_instances.erase(self)
		if shader.is_valid():
			RenderingServer.free_rid(shader)

#endregion


#region 标记

func _apply(on: bool, meshes: Array) -> void:
	for mi in meshes:
		if not mi:
			continue
		if on:
			_mark_on(mi)
		else:
			_mark_off(mi)


func _mark_on(mesh: GeometryInstance3D) -> void:
	# 该网格所在的视口不跑本效果 ⇒ 打标记画不出环，只会把标记写进那个视口的 alpha
	# （甚至被 get_image() 烘焙进缓存贴图，表现为物体永久蒙色）⇒ 直接拒绝
	if not _viewport_runs_here(mesh):
		_mark_off(mesh)
		return
	_marked[mesh] = true
	mesh.material_overlay = _get_material()


func _mark_off(mesh: GeometryInstance3D) -> void:
	_marked.erase(mesh)
	# 只清自己的标记材质，不碰别的实例（悬停等）挂上去的
	if _material and mesh.material_overlay == _material:
		mesh.material_overlay = null


## 每帧补齐标记材质：
## · 标记时还没进场景树的网格（典型：战斗开始时装备视图刚创建），进树后在这里补上；
## · 已失效的引用顺手清理。
## 已被其它实例（悬停等）接管的不抢。
func _refresh_marks() -> void:
	if _marked.is_empty():
		return
	for mesh in _marked.keys():
		if not is_instance_valid(mesh):
			_marked.erase(mesh)
			continue
		if mesh.get_viewport() == null:
			continue
		if mesh.material_overlay != null:
			continue
		mesh.material_overlay = _get_material()


## 该网格所在的视口会不会跑本效果？
## 会跑 ⇒ 打标记有意义（膨胀趟会把环画出来）；
## 不会跑 ⇒ 打标记只有害处（见 _mark_on 里的注释）。
func _viewport_runs_here(mesh: GeometryInstance3D) -> bool:
	var vp: Viewport = mesh.get_viewport()
	if vp == null:
		# 还没进场景树（典型：战斗开始时装备视图刚创建、view 尚未挂上）
		# ⇒ 先接受标记，进树后由 _refresh_marks() 补上材质
		return true
	var cam := vp.get_camera_3d()
	if cam and _compositor_has_self(cam.compositor):
		return true
	for node in vp.find_children("*", "WorldEnvironment", true, false):
		var we := node as WorldEnvironment
		if we and _compositor_has_self(we.compositor):
			return true
	# 兜底：真跑到过本效果的视口尺寸（Compositor 挂在相机/世界环境上时上面就判完了）
	if _active_sizes.has(vp.size):
		return true
	# 完全没头绪（例如还没渲染过任何一帧）：放行，避免误伤
	return _active_sizes.is_empty()


func _compositor_has_self(comp: Compositor) -> bool:
	if comp == null:
		return false
	var effects = comp.get("compositor_effects")
	if effects is Array:
		for e in effects:
			if e == self:
				return true
	return false


func _get_material() -> ShaderMaterial:
	var marker := marker_alpha()
	if _material and _material_marker == marker:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = _make_marker_shader(marker)
	# 见 MARKER_RENDER_PRIORITY：标记必须最后落笔（原因见常量注释）
	_material.render_priority = MARKER_RENDER_PRIORITY
	_material_marker = marker
	return _material


static func _make_marker_shader(marker: float) -> Shader:
	var s := Shader.new()
	# depth_test_enabled（默认）→ 被挡像素不写入，自然避免透视
	# ALPHA = 标记值           → 累加到判定区间内
	# ALBEDO = 0               → blend_add 不改变场景颜色
	s.code = "shader_type spatial;
render_mode blend_add, unshaded, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = %.1f;
}" % marker
	return s

#endregion


#region 渲染管线

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
	_pc_dilate = _pack(MODE_DILATE)
	_pc_restore = _pack(MODE_RESTORE)
	_pc_dirty = false


func _pack(mode: float) -> PackedByteArray:
	var marker := marker_alpha()
	# 判定区间 [marker, marker² + 2)：
	# · 单层实际值是 1 + marker（blend_add 对 alpha 线性相加，实测）；
	# · 同一像素上多层被标记网格重叠时会累加（1 + marker·k），
	#   该上界给每个槽位留出足够的叠层头寸（槽位 1 可撑到 k≈6），且相邻槽位区间不重叠。
	var marker_lo := marker
	var marker_hi := marker * marker + 2.0
	var params := PackedFloat32Array([
		outline_width, outline_alpha, marker_lo, marker_hi,
		outline_color.r, outline_color.g, outline_color.b, outline_color.a,
		mode, float(_gap_reach()), 0.0, 0.0,
	])
	return params.to_byte_array()


## 细缝判定半径（像素）：两侧各扫到这么远都有标记 ⇒ 判定为"被标记区域内部的窄缝"。
## 取 outline_width + 2（宽度 2 时 = 4，即早年调好的值）：能盖住模型自身的细缝
## （典型 ≈1px，上下两半拼出的牌面之间那道）与外壳内部的小缺口，
## 又远小于格子之间的正常间隙（十几像素），不会误伤整格的外轮廓
## （轮廓外侧是空的，"两侧都有标记"不成立，所以不管半径多大都不会吃掉外圈）。
func _gap_reach() -> int:
	return int(outline_width) + 2


func _render_callback(p_type: EffectCallbackType, p_data: RenderData) -> void:
	if _marked_count <= 0 or outline_width <= 0.0:
		return
	# 补上"标记时还没进树"的网格（见 _viewport_runs_here）
	_refresh_marks()
	if not rd or p_type != effect_callback_type or not _ensure_shader():
		return

	var bufs: RenderSceneBuffersRD = p_data.get_render_scene_buffers()
	if not bufs:
		return

	var size := bufs.get_internal_size()
	if size.x == 0 and size.y == 0:
		return
	# 记下"本效果确实在这个尺寸的视口里跑过"，供 _viewport_runs_here() 兜底
	_active_sizes[size] = true

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
		# ① 膨胀合成、② 标记 alpha 归位，必须分两个 compute list：
		#    同一列表内第二次 set_push_constant 不生效，归位趟会拿着膨胀参数再跑一遍，
		#    表现为 alpha 永远留着污染（被标记物体蒙色）。
		#    RD 会在两个列表之间自动插屏障，"膨胀先于归位"因此有保证。
		for pc in [_pc_dilate, _pc_restore]:
			var cl := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(cl, pipeline)
			rd.compute_list_bind_uniform_set(cl, set_rid, 0)
			rd.compute_list_set_push_constant(cl, pc, PUSH_CONSTANT_SIZE)
			rd.compute_list_dispatch(cl, gx, gy, 1)
			rd.compute_list_end()


static func _bind_image(bind: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = bind
	u.add_id(rid)
	return u

#endregion


#region 计算着色器

const COMPUTE_SHADER := """#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set=0, binding=0) uniform image2D color_image;

layout(push_constant, std430) uniform Params {
	float outline_width;
	float outline_alpha;
	float marker_lo;   // 判定区间下界（含）= 本实例标记值
	float marker_hi;   // 判定区间上界（不含）= marker² + 2
	vec4 outline_color;
	vec4 extra;        // x = 模式（0 膨胀合成 / 1 alpha 归位），y = 细缝判定半径
} params;

// 该像素的 alpha 是否属于本实例的标记
bool mine(float a) {
	return a >= params.marker_lo && a < params.marker_hi;
}

// 该方向上 1..reach 像素内是否存在本实例的标记
bool marked_within(ivec2 uv, ivec2 dir, int reach, ivec2 size) {
	for (int i = 1; i <= reach; i++) {
		ivec2 p = uv + dir * i;
		if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y)
			return false;
		if (mine(imageLoad(color_image, p).a))
			return true;
	}
	return false;
}

void main() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (uv.x >= size.x || uv.y >= size.y)
		return;

	vec4 color = imageLoad(color_image, uv);

	// ② alpha 归位：标记值只是给本条管线看的，用完立刻恢复，别留给下游。
	//    ⚠️ 必须直接设回 1.0，不能"减一个常数"：
	//      · blend_add 对 alpha 是线性相加（实测槽位 1 单层 = 1 + 6 = 7.0）；
	//      · 多个被标记网格在同一像素重叠时会叠加（α = 1 + 6·层数），减一个 m 减不干净；
	//      · 减多了（如误按 m² 减 36）会得到负 alpha，下游合成直接变成"蒙上一层色"。
	//    设成 1.0 是幂等的，且对被标记网格（不透明）就是精确原值。
	if (params.extra.x > 0.5) {
		if (mine(color.a)) {
			color.a = 1.0;
			imageStore(color_image, uv, color);
		}
		return;
	}

	// ① 膨胀合成
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

	// 细缝保护：本像素未被标记，却在同一轴的两侧 reach 像素内都有标记 ⇒ 它落在一道窄缝里
	// （典型：上下两半拼出的牌面之间那道 ≈1px 的缝）。这种像素画出来只会多一根忽隐忽现的线。
	if (dilated && params.extra.y > 0.5) {
		int reach = int(params.extra.y);
		bool neg_x = marked_within(uv, ivec2(-1, 0), reach, size);
		bool pos_x = marked_within(uv, ivec2(1, 0), reach, size);
		bool neg_y = marked_within(uv, ivec2(0, -1), reach, size);
		bool pos_y = marked_within(uv, ivec2(0, 1), reach, size);
		if ((neg_x && pos_x) || (neg_y && pos_y))
			return;
	}

	float blend = (float(dilated) - float(is_marked)) * params.outline_alpha * params.outline_color.a;
	if (blend <= 0.0)
		return;

	color.rgb = mix(color.rgb, params.outline_color.rgb, blend);
	imageStore(color_image, uv, color);
}"""

#endregion
