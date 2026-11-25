extends TestCase

## QVoxelSource 的粒子点导出（build_particle_points / build_particle_textures）。
##
## 【为什么这些断言值得写】它们钉住的都是"做错了不报错"的点：
##   · 透明体素被表面过滤误删 -> 车窗整片消失（曾实测 1050 px 空洞）
##   · 颜色没转线性 -> 双重 gamma，暗部提亮一倍、画面发白变平
##   · 位置没用 center_offset -> 粒子与网格错位
##   · 抽样不确定 -> 每次运行形态不同，回放对不上

const CARS := "res://demo/cars.vox"


func _src() -> QVoxelSource:
	var vox := VoxAsset.from_asset(CARS)
	return QVoxelSource.from_voxel_data(vox, 0, QVoxelSource.OriginMode.CONTENT_CENTER)


# ---------------------------------------------------------------- 布局契约

func test_stride_and_channel_offsets() -> void:
	assert_eq(QVoxelSource.PARTICLE_STRIDE, 12, "每点应为 12 float")
	# 通道偏移必须落在 stride 内且互不重叠
	assert_eq(QVoxelSource.P_POS, 0, "位置从 0 开始（占 0..2）")
	assert_eq(QVoxelSource.P_MAT, 3, "材质 ID 在 [3]")
	assert_eq(QVoxelSource.P_COLOR, 4, "颜色从 [4] 开始（占 4..6）")
	assert_eq(QVoxelSource.P_SEED, 7, "稳定种子在 [7]")
	assert_eq(QVoxelSource.P_EMIT, 8, "自发光在 [8]")
	assert_eq(QVoxelSource.P_METAL, 9, "金属度在 [9]")
	assert_eq(QVoxelSource.P_ROUGH, 10, "粗糙度在 [10]")
	assert_eq(QVoxelSource.P_TRANS, 11, "透明度在 [11]")
	assert_true(QVoxelSource.P_TRANS < QVoxelSource.PARTICLE_STRIDE, "最后一个通道必须落在 stride 内")


func test_points_length_is_multiple_of_stride() -> void:
	var pts := _src().build_particle_points(0.1, 200000, false)
	assert_true(pts.size() > 0, "应导出点")
	assert_eq(pts.size() % QVoxelSource.PARTICLE_STRIDE, 0,
			"点数组长度必须是 stride 的整数倍")


# ---------------------------------------------------------------- 内容契约

func test_positions_match_mesh_renderer() -> void:
	# 粒子坐标必须与网格渲染的世界坐标**完全一致**：网格顶点 = (体素坐标 + center_offset) × scale。
	# 否则"模型与粒子互相切换"时会明显跳位。
	var src := _src()
	var pts := src.build_particle_points(0.1, 200000, false)
	# 用包围盒比对：取点云 AABB，与"体素 AABB + center_offset"换算出来的世界 AABB 对齐
	var voxels := src.get_voxels_dict_snapshot()
	var bounds := VoxelWorldUtil.voxel_bounds(voxels)
	var lo: Vector3i = bounds["min"]
	var hi: Vector3i = bounds["max"]
	var expect_min := (Vector3(lo) + src.center_offset) * 0.1
	var expect_max := (Vector3(hi) + src.center_offset) * 0.1
	var got_min := Vector3(INF, INF, INF)
	var got_max := -got_min
	for i in pts.size() / QVoxelSource.PARTICLE_STRIDE:
		var b := i * QVoxelSource.PARTICLE_STRIDE
		var p := Vector3(pts[b], pts[b + 1], pts[b + 2])
		got_min = Vector3(minf(got_min.x, p.x), minf(got_min.y, p.y), minf(got_min.z, p.z))
		got_max = Vector3(maxf(got_max.x, p.x), maxf(got_max.y, p.y), maxf(got_max.z, p.z))
	# 体素坐标是格心，故每个方向最多差一个体素边长
	var tol := 0.1 * 1.5
	assert_true(got_min.distance_to(expect_min) < tol,
			"点云最小角应与网格一致（期望 %s 实际 %s）" % [expect_min, got_min])
	assert_true(got_max.distance_to(expect_max) < tol,
			"点云最大角应与网格一致（期望 %s 实际 %s）" % [expect_max, got_max])


func test_transparent_voxels_are_preserved() -> void:
	# surface_only 必须保留全部透明体素：玻璃被包住时仍能看见后面。
	var src := _src()
	var full := src.build_particle_points(0.1, 200000, false)
	var surf := src.build_particle_points(0.1, 200000, true)
	var glass_full := 0
	var glass_surf := 0
	for i in full.size() / QVoxelSource.PARTICLE_STRIDE:
		if full[i * QVoxelSource.PARTICLE_STRIDE + QVoxelSource.P_TRANS] > 0.05:
			glass_full += 1
	for i in surf.size() / QVoxelSource.PARTICLE_STRIDE:
		if surf[i * QVoxelSource.PARTICLE_STRIDE + QVoxelSource.P_TRANS] > 0.05:
			glass_surf += 1
	assert_true(glass_full > 0, "cars.vox 应有透明体素")
	assert_eq(glass_surf, glass_full, "表面过滤不应删掉任何透明体素")
	assert_true(surf.size() < full.size(), "表面过滤仍应减掉不透明的内部体素")


func test_material_channels_are_baked() -> void:
	var pts := _src().build_particle_points(0.1, 200000, false)
	var metal := 0
	var trans := 0
	var emit := 0
	for i in pts.size() / QVoxelSource.PARTICLE_STRIDE:
		var b := i * QVoxelSource.PARTICLE_STRIDE
		if pts[b + QVoxelSource.P_METAL] > 0.05: metal += 1
		if pts[b + QVoxelSource.P_TRANS] > 0.05: trans += 1
		if pts[b + QVoxelSource.P_EMIT] > 0.05: emit += 1
	assert_true(metal > 0, "cars.vox 有金属材质，应烘出 metal>0 的点")
	assert_true(trans > 0, "cars.vox 有透明材质，应烘出 trans>0 的点")
	assert_true(emit > 0, "cars.vox 有自发光材质，应烘出 emission>0 的点")


func test_seed_is_stable_per_voxel() -> void:
	# 同一次构建里，同一坐标必得同一个种子；两次构建也必须一致。
	var a := _src().build_particle_points(0.1, 200000, false)
	var b := _src().build_particle_points(0.1, 200000, false)
	assert_eq(a, b, "两次导出必须完全一致（确定性）")


# ---------------------------------------------------------------- 抽样契约

func test_downsample_respects_limit_and_is_deterministic() -> void:
	var src := _src()
	# 先取"无上限"的全量候选数（max_points 极大 → stride=1 → 全取），才能判断是否真的超上限
	var total := src.build_particle_points(0.1, 2000000000, true).size() / QVoxelSource.PARTICLE_STRIDE
	var d1 := src.build_particle_points(0.1, 5000, true)
	var d2 := src.build_particle_points(0.1, 5000, true)
	var n := d1.size() / QVoxelSource.PARTICLE_STRIDE
	assert_true(n <= 5000, "抽样后点数不能超过上限（实际 %d）" % n)
	assert_true(n > 0, "抽样后不应为空")
	assert_eq(d1, d2, "抽样必须确定性（两次结果一致）")
	# 语义只有一条：stride = ceil(total/max)（未超上限则 stride=1），点数 = ceil(total/stride)。
	# 注意整数步长的粒度：total=5001 时 stride=2 → 2501 点，这是该语义的必然结果，
	# 故断言钉的是"按这条公式算出的数"，而不是"必须接近 5000"。
	var stride := 1 if total <= 5000 else int(ceil(float(total) / 5000.0))
	var expect := int(ceil(float(total) / float(stride)))
	assert_eq(n, expect,
			"抽样点数应为 ceil(total/stride)（total=%d stride=%d 期望 %d）" % [total, stride, expect])
	if total > 5000:
		# 旧实现（判定恒假 → 退化成"取前 max 个"）只在未超上限时与真值一致 |
		# 超上限时它给出恰好等于"靠前若干整块之和"的偏小值 —— 那两个数一般对不上。
		assert_true(n > 5000 / 2, "超上限时不应退化成截断（actual=%d）" % n)


## 40×16×16 = 10240 体素，横跨 x 方向 2 个 chunk（x 0..31 与 32..39）。
## [param reverse_order] 用倒序灌入同样的体素集合 → _chunk_buffers 的插入序相反。
func _make_slab(reverse_order: bool) -> QVoxelSource:
	var d := QVoxelSource.new()
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var mat := VoxelMaterial.new()
	mat.id = 1
	mats[1] = mat
	d.materials = mats
	var positions: Array = []
	for x in 40:
		for y in 16:
			for z in 16:
				positions.append(Vector3i(x, y, z))
	if reverse_order:
		positions.reverse()
	d.set_voxels(positions, 1, false)
	return d


func test_downsample_is_uniform_and_order_independent() -> void:
	# 10240 候选、上限 1000 → stride = ceil(10240/1000) = 11 → 点数 = ceil(10240/11) = 931。
	# 钉住 stride 的**具体语义**（点数而非"前 N 个"）：换实现方式时这个数字会立刻变化。
	var a := _make_slab(false)
	var b := _make_slab(true)
	var d1 := a.build_particle_points(0.1, 1000, false)
	var d2 := b.build_particle_points(0.1, 1000, false)
	var n := d1.size() / QVoxelSource.PARTICLE_STRIDE
	assert_eq(n, 931, "10240 候选 / 上限 1000 应得 ceil(10240/11)=931 点")
	# 与 chunk 插入序无关：同一份体素、不同灌入顺序必须给出完全相同的结果
	# （旧实现按字典插入序编号，倒序灌入会得到另一份点云 → 回放/烘焙不可复现）。
	assert_eq(d1, d2, "下采样结果必须与 chunk 插入序无关（同输入同输出）")
	# 均匀性：截断式下采样会把后加载的 chunk **整块丢掉**（上限 < 首块点数时该块 0 点）。
	# 这里两个 chunk 都必须有点，且抽样量与其体素数之比（8192:2048 = 4:1）成比例。
	var per := {}
	for i in n:
		var vx := roundi(d1[i * QVoxelSource.PARTICLE_STRIDE] / 0.1)
		var key := vx / 32
		per[key] = int(per.get(key, 0)) + 1
	assert_eq(per.size(), 2, "两个 chunk 都应被抽样覆盖（截断式会整块丢掉后加载的 chunk）")
	var c0 := int(per.get(0, 0))
	var c1 := int(per.get(1, 0))
	assert_true(c0 > 0 and c1 > 0, "两个 chunk 的抽样点数都应 > 0（实际 %d / %d）" % [c0, c1])
	var ratio := float(c0) / float(maxi(c1, 1))
	assert_true(absf(ratio - 4.0) < 0.5,
			"各 chunk 抽样量应与其体素数成比例（期望约 4:1，实际 %d:%d）" % [c0, c1])


# ---------------------------------------------------------------- 纹理契约

func test_textures_built_and_sized() -> void:
	var tex := _src().build_particle_textures(0.1, 200000, true)
	assert_true(tex["count"] > 0, "应产出纹理")
	var pos: ImageTexture = tex["positions"]
	var col: ImageTexture = tex["colors"]
	var props: ImageTexture = tex["props"]
	assert_true(pos != null and col != null and props != null, "三张纹理都应构建成功")
	assert_eq(pos.get_size(), col.get_size(), "三张纹理尺寸应一致")
	assert_eq(col.get_size(), props.get_size(), "三张纹理尺寸应一致")
	assert_eq(pos.get_format(), Image.FORMAT_RGBAF, "位置纹理应为 RGBAF")
	var w := int(pos.get_size().x)
	assert_eq(w, int(tex["grid_width"]), "纹理宽度应等于 grid_width")
	assert_true(w * int(pos.get_size().y) >= int(tex["count"]), "纹理格子数应足以容纳全部点")


func test_color_texture_is_linear() -> void:
	# 颜色纹理必须是**线性**值：直接把 sRGB 塞进 RGBAF 会造成双重 gamma，
	# 暗部整体提亮一倍以上（#444444 显示成 #8d8d8d），画面又白又平。
	var src := _src()
	var pts := src.build_particle_points(0.1, 200000, true)
	var tex := src.build_particle_textures(0.1, 200000, true)
	var img: ImageTexture = tex["colors"]
	var im := img.get_image()
	for i in mini(tex["count"], 200):
		var b := i * QVoxelSource.PARTICLE_STRIDE
		var srgb := Color(pts[b + QVoxelSource.P_COLOR],
				pts[b + QVoxelSource.P_COLOR + 1], pts[b + QVoxelSource.P_COLOR + 2])
		var expect := srgb.srgb_to_linear()
		var got: Color = im.get_pixel(i % int(tex["grid_width"]), i / int(tex["grid_width"]))
		assert_true(absf(got.r - expect.r) < 0.01 and absf(got.g - expect.g) < 0.01
				and absf(got.b - expect.b) < 0.01,
				"颜色纹理应为线性值（双重 gamma 会让暗部提亮一倍）")
		# A 通道承载不透明度 = 1 - trans
		assert_true(absf(got.a - (1.0 - pts[b + QVoxelSource.P_TRANS])) < 0.01,
				"颜色纹理的 A 应为不透明度(1-trans)")


func test_props_texture_channels() -> void:
	var src := _src()
	var pts := src.build_particle_points(0.1, 200000, true)
	var tex := src.build_particle_textures(0.1, 200000, true)
	var im: Image = (tex["props"] as ImageTexture).get_image()
	var w := int(tex["grid_width"])
	for i in mini(tex["count"], 200):
		var b := i * QVoxelSource.PARTICLE_STRIDE
		var got: Color = im.get_pixel(i % w, i / w)
		assert_true(absf(got.r - pts[b + QVoxelSource.P_METAL]) < 0.01, "R 应为 metal")
		assert_true(absf(got.g - pts[b + QVoxelSource.P_ROUGH]) < 0.01, "G 应为 rough")
		assert_true(absf(got.b - pts[b + QVoxelSource.P_EMIT]) < 0.01, "B 应为 emission")
