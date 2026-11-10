extends TestCase

## 粒子渲染的**底层机制**契约：VoxelParticleShader 的着色器 + VoxelRenderer 的粒子接口。
##
## 【这个文件只测"机制"，不测"效果"】漂浮/消散/聚合/变形是具体项目的表现，
## 插件不实现也不测。这里钉住的是：把点云摆成方块、材质正确、遮挡正确。

const CARS := "res://demo/cars.vox"


func cleanup() -> void:
	for n in Engine.get_main_loop().root.get_children():
		if String(n.name).begins_with("__ParticleTest"):
			n.queue_free()


# ---------------------------------------------------------------- 着色器

func test_particle_shader_compiles() -> void:
	var mat := VoxelParticleShader.make_process_material()
	assert_true(mat != null, "应返回材质实例")
	assert_true(mat.shader != null, "材质应带 shader")
	assert_true(mat.shader.get_shader_uniform_list().size() > 0,
			"着色器应编译成功（uniform 列表不能为空）")


func test_draw_shaders_compile() -> void:
	var opaque := VoxelParticleShader.make_draw_material()
	var trans := VoxelParticleShader.make_draw_material_trans()
	assert_true(opaque.shader.get_shader_uniform_list().size() > 0, "不透明通道应编译成功")
	assert_true(trans.shader.get_shader_uniform_list().size() > 0, "透明通道应编译成功")


func test_all_uniforms_present() -> void:
	var mat := VoxelParticleShader.make_process_material()
	var names := {}
	for u in mat.shader.get_shader_uniform_list():
		names[String(u["name"])] = true
	var required := [
		VoxelParticleShader.U_SRC_POS, VoxelParticleShader.U_DST_POS,
		VoxelParticleShader.U_COLORS, VoxelParticleShader.U_PROPS,
		VoxelParticleShader.U_GRID_WIDTH, VoxelParticleShader.U_PROGRESS,
		VoxelParticleShader.U_ALPHA,
	]
	for key in required:
		assert_true(names.has(key), "粒子着色器缺少 uniform：%s" % key)


## 【回归：不透明通道绝对不能写 ALPHA】
## Godot 按"着色器有没有写 ALPHA"判定管线归属，不是看运行时的值。
## 一旦写了 ALPHA（哪怕恒为 1.0），材质就被归入透明管线：不写深度 -> 方块互相穿透
## （前车挡不住后车），且与透明通道之间按距离排序 -> 顺序一变画面就变。
func test_opaque_pass_must_not_write_alpha() -> void:
	var code := _code_only(VoxelParticleShader.DRAW_SHADER)
	var render_line := ""
	var has_alpha_write := false
	for line in code.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("render_mode"):
			render_line = s
		if s.begins_with("ALPHA") and s.contains("="):
			has_alpha_write = true
	assert_true(render_line != "", "不透明通道必须声明 render_mode")
	assert_false(has_alpha_write,
			"不透明通道**不能写 ALPHA** —— 写了就会被判为透明材质、失去深度写入（会透视）")


## 【回归：必须有不透明 + 透明两个通道】
## 单一材质无论选哪种 depth 模式都错一头：
##   depth_draw_opaque + ALPHA -> 完全不写深度（透视）
##   depth_prepass_alpha       -> 阈值 0.5，玻璃 0.72 被当不透明写深度（玻璃后面的东西消失）
##   depth_draw_never          -> 不透明方块也失去遮挡（透视）
func test_two_draw_passes_exist() -> void:
	var opaque := _code_only(VoxelParticleShader.DRAW_SHADER)
	var trans := _code_only(VoxelParticleShader.DRAW_TRANS_SHADER)
	assert_true(opaque.contains("discard"), "不透明通道应丢弃透明体素")
	assert_true(trans.contains("discard"), "透明通道应丢弃不透明体素（避免重复混合）")
	assert_false(trans.contains("depth_draw_opaque"),
			"透明通道不应写深度 —— 否则会裁掉它后面的体素（玻璃就会消失）")


## 【回归：两个通道都要输出 PBR 通道】
## 早期用 unshaded + 自算 lambert：颜色对但材质不对（金属没金属感、玻璃没透明）。
func test_both_passes_output_pbr_channels() -> void:
	for pair in [["opaque", VoxelParticleShader.DRAW_SHADER],
			["transparent", VoxelParticleShader.DRAW_TRANS_SHADER]]:
		var code := _code_only(String(pair[1]))
		var label := String(pair[0])
		assert_true(code.contains("METALLIC"), "%s 通道必须输出 METALLIC" % label)
		assert_true(code.contains("ROUGHNESS"), "%s 通道必须输出 ROUGHNESS" % label)
		assert_true(code.contains("EMISSION"), "%s 通道必须输出 EMISSION" % label)


func test_draw_shader_scales_by_uniform() -> void:
	var code := _code_only(VoxelParticleShader.DRAW_SHADER)
	assert_true(code.contains("voxel_size"), "绘制着色器必须暴露 voxel_size")
	assert_true(code.contains("VERTEX = VERTEX * voxel_size"),
			"顶点必须按 voxel_size 缩放，否则尺寸不可调")


# ---------------------------------------------------------------- VoxelRenderer 粒子接口

func _renderer_with_data() -> VoxelRenderer:
	var vox := VoxAsset.from_asset(CARS)
	var src := QVoxelSource.from_voxel_data(vox, 0, QVoxelSource.OriginMode.CONTENT_CENTER)
	var r := VoxelRenderer.new()
	r.name = "__ParticleTest_renderer"
	r.data = src
	r.voxel_scale = 0.1
	r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	Engine.get_main_loop().root.add_child(r)
	return r


func test_display_mode_enum_creates_node() -> void:
	var r := _renderer_with_data()
	assert_eq(r.display_mode, VoxelRenderer.DisplayMode.MESH, "默认应为网格模式")
	r.display_mode = VoxelRenderer.DisplayMode.PARTICLES
	assert_eq(r.display_mode, VoxelRenderer.DisplayMode.PARTICLES, "应进入粒子模式")
	assert_true(r.particle_node != null, "应创建粒子节点")
	assert_true(r.particle_node.amount > 0, "粒子数应大于 0")
	assert_true(r.particle_points.size() > 0, "点数据应被导出")
	assert_eq(r.particle_node.get_draw_pass_mesh(0) != null, true, "应有第 1 个绘制通道")
	assert_eq(r.particle_node.get_draw_pass_mesh(1) != null, true, "应有第 2 个绘制通道")
	r.queue_free()


func test_particle_voxel_size_follows_scale() -> void:
	var r := _renderer_with_data()
	r.voxel_scale = 0.1
	r.particle_scale = 1.0
	assert_true(absf(r.particle_voxel_size() - 0.1) < 0.0001,
			"粒子边长应等于体素边长（否则拼不严或互相重叠）")
	r.particle_scale = 2.0
	assert_true(absf(r.particle_voxel_size() - 0.2) < 0.0001, "particle_scale 应线性缩放")
	r.queue_free()


func test_display_mode_switches_visibility() -> void:
	var r := _renderer_with_data()
	assert_eq(r.display_mode, VoxelRenderer.DisplayMode.MESH, "默认应为网格")
	r.display_mode = VoxelRenderer.DisplayMode.PARTICLES
	assert_true(r.particle_node.visible, "切到粒子模式后粒子应可见")
	r.display_mode = VoxelRenderer.DisplayMode.MESH
	assert_false(r.particle_node.visible, "切回网格后粒子应隐藏")
	r.queue_free()


## 【兼容别名】particle_mode 读写都应同步 display_mode。
## 保留它是因为早期版本用它；枚举是新的正式接口。
func test_particle_mode_alias_keeps_enum_in_sync() -> void:
	var r := _renderer_with_data()
	r.particle_mode = true
	assert_eq(r.display_mode, VoxelRenderer.DisplayMode.PARTICLES,
			"写 particle_mode=true 应同步到枚举")
	assert_true(r.particle_mode, "读 particle_mode 应等价于枚举比较")
	r.particle_mode = false
	assert_eq(r.display_mode, VoxelRenderer.DisplayMode.MESH,
			"写 particle_mode=false 应同步到枚举")
	r.queue_free()


## 【形状】立方体与球都要能切换，且切换不重建粒子节点。
## 网格路径早就有 cube/sphere 两种形状；粒子若只能方块，"小球粒子"类效果就得项目自己做 mesh。
func test_particle_shape_switches() -> void:
	var r := _renderer_with_data()
	r.display_mode = VoxelRenderer.DisplayMode.PARTICLES
	var node_before := r.particle_node

	r.particle_shape = VoxelRenderer.ParticleShape.CUBE
	var cube := r.particle_node.get_draw_pass_mesh(0)
	assert_true(cube is BoxMesh, "CUBE 形状应使用 BoxMesh（拼起来严丝合缝）")

	r.particle_shape = VoxelRenderer.ParticleShape.SPHERE
	var sphere := r.particle_node.get_draw_pass_mesh(0)
	assert_true(sphere is SphereMesh, "SPHERE 形状应使用 SphereMesh")
	# 切换到球后，两个通道（不透明/透明）都应是球
	assert_true(r.particle_node.get_draw_pass_mesh(1) is SphereMesh,
			"透明通道也要跟着换形状，否则一块玻璃是球、另一块是方块")

	# 【关键】换形状不应重建粒子节点（否则粒子状态会丢、位置会跳）
	assert_true(node_before == r.particle_node, "换形状不应重建粒子节点")
	r.queue_free()


## 球的尺寸：单位直径 × voxel_size 后应内切于体素格（不溢出、不留大缝）。
func test_sphere_radius_fits_voxel() -> void:
	var r := _renderer_with_data()
	r.display_mode = VoxelRenderer.DisplayMode.PARTICLES
	r.particle_sphere_scale = 1.0
	r.particle_shape = VoxelRenderer.ParticleShape.SPHERE
	var sphere := r.particle_node.get_draw_pass_mesh(0) as SphereMesh
	assert_true(sphere != null, "应为球网格")
	# 半径 0.5 = 直径 1，乘 voxel_size 后正好等于体素边长
	assert_true(absf(sphere.radius - 0.5) < 0.001,
			"球半径应为 0.5（单位直径，缩放到 voxel_size 后内切于体素）")
	r.queue_free()


func test_surface_only_reduces_points() -> void:
	var r := _renderer_with_data()
	r.particle_surface_only = false
	r.show_as_particles(true)
	var full := r.particle_points.size()
	r.particle_surface_only = true
	r.rebuild_particles()
	var surf := r.particle_points.size()
	assert_true(surf > 0 and surf < full,
			"只渲染表面应减少点数（%d -> %d）" % [full, surf])
	r.queue_free()


## 剥掉注释后只留有效代码。
## 【为什么必须这么做】着色器注释里会**特意写出**被禁止的写法
## （"不是 unshaded"、"绝对不要写 COLOR.a"），直接 contains 会命中注释造成假失败。
func _code_only(src: String) -> String:
	var no_block := ""
	var depth := 0
	var i := 0
	while i < src.length():
		if i + 1 < src.length() and src[i] == "/" and src[i + 1] == "*":
			depth += 1
			i += 2
			continue
		if i + 1 < src.length() and src[i] == "*" and src[i + 1] == "/" and depth > 0:
			depth -= 1
			i += 2
			continue
		if depth == 0:
			no_block += src[i]
		i += 1
	var out := PackedStringArray()
	for line in no_block.split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("//") or stripped.begins_with("#"):
			continue
		out.append(line)
	return "\n".join(out)
