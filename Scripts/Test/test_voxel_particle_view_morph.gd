extends TestCase

## 点云**空间序（Morton / Z-order）**契约：VoxelMorphMap 的排序原语 + VoxelParticleView…

const CARS := "res://demo/cars.vox"

func cleanup() -> void:
	for n in Engine.get_main_loop().root.get_children():
		if String(n.name).begins_with("__MorphTest"):
			n.queue_free()

# ───────────────────────── ① 排列合法性 / ② Morton 单调…

## 排序结果是**排列**：0..n-1 每个下标恰好出现一次（漏了会把点弄丢，重了会画重影）。
func test_sorted_indices_is_a_permutation() -> void:
	var points := _grid_points(4, 4, 4, 0.1)
	var order := VoxelMorphMap.sorted_indices(points, 12)
	assert_eq(order.size(), points.size() / 12, "排序结果长度应等于点数")
	var seen := PackedByteArray()
	seen.resize(order.size())
	for i in order.size():
		var idx := order[i]
		assert_true(idx >= 0 and idx < order.size(), "下标越界：%d" % idx)
		if idx < 0 or idx >= order.size():
			return
		assert_eq(seen[idx], 0, "下标 %d 重复出现（排列里每个点只能出现一次）" % idx)
		seen[idx] = 1

## 排序后 Morton 码**单调不减** —— 这就是"空间顺序"本身，坏掉等于没排序。
func test_sorted_indices_is_monotonic_in_morton_code() -> void:
	var points := _scrambled_points(5, 5, 5, 0.1)
	var order := VoxelMorphMap.sorted_indices(points, 12)
	assert_true(order.size() > 1, "样例点云不能为空")
	var prev := -1
	for k in order.size():
		var code := _morton_code_of(points, int(order[k]), 12)
		assert_true(code >= prev, "第 %d 位的 Morton 码 %d 比前一位 %d 小 —— 排序没有真正生效" % [k, code, prev])
		if code < prev:
			return
		prev = code

## 空点云 / 非法 stride → 返回空排列（调用方据此跳过，不炸）。
func test_sorted_indices_handles_empty_input() -> void:
	assert_true(VoxelMorphMap.sorted_indices(PackedFloat32Array(), 12).is_empty(),
			"空点云应返回空排列")
	assert_true(VoxelMorphMap.sorted_indices(_grid_points(2, 2, 2, 0.1), 0).is_empty(),
			"stride <= 0 应返回空排列（否则除法无意义）")

# ───────────────────────── ③ reorder 整块搬运 ─────────────────────────

## reorder 只换顺序、不换内容：排序后的点集与原集合**逐点相同**（比较重排后的坐标集合）。
func test_reorder_preserves_point_multiset() -> void:
	var points := _scrambled_points(3, 4, 5, 0.1)
	var order := VoxelMorphMap.sorted_indices(points, 12)
	var sorted := VoxelMorphMap.reorder(points, order, 12)
	assert_eq(sorted.size(), points.size(), "重排不能改变数组长度")
	# 【不用 assert_eq】两边是上千个元素的字符串数组，断言失败时会把整份集合打进日志；
	var want := _point_key_set(points, 12)
	var got := _point_key_set(sorted, 12)
	assert_true(want == got, "重排后的点集必须与原集合完全相同（只允许换顺序）：原 %d 个 / 重排 %d 个" % [want.size(), got.size()])

## 逐点属性**跟着点一起走**：否则颜色/材质会串位（不报错，只是画面像贴图错乱）。
func test_reorder_moves_all_channels_together() -> void:
	var points := _scrambled_points(3, 3, 3, 0.1)
	var order := VoxelMorphMap.sorted_indices(points, 12)
	var sorted := VoxelMorphMap.reorder(points, order, 12)
	for k in order.size():
		var src := int(order[k]) * 12
		var dst := k * 12
		assert_eq(_slice(sorted, dst), _slice(points, src),
				"第 %d 个点的整条 stride（坐标+颜色+材质）必须原样搬过来" % k)

# ───────────────────────── ④ VoxelParticleView 接线…

## 开关 spatial_sort：点集不变（按坐标排序后比较）、数量不变。
func test_particle_view_spatial_sort_preserves_point_set() -> void:
	var src := _source()
	if src == null:
		return
	var plain := _view_points(src, false)
	var sorted := _view_points(src, true)
	assert_true(plain.size() > 0, "点云不能为空（资产缺失时用例应跳过）")
	assert_eq(sorted.size(), plain.size(), "排序不能改变点数")
	var want := _point_key_set(plain, 12)
	var got := _point_key_set(sorted, 12)
	assert_true(want == got,
			"排序后的点集必须与未排序时完全相同 —— 空间排序只允许换顺序（%d vs %d 个点）"
				% [want.size(), got.size()])

## 排序后的点数组与上传的位置纹理**必须同序**。
func test_particle_view_sorted_points_match_position_texture() -> void:
	var src := _source()
	if src == null:
		return
	var view := VoxelParticleView.new()
	view.name = "__MorphTest_view"
	view.max_points = 4000
	view.surface_only = false
	view.spatial_sort = true
	var host := VoxelRenderer.new()
	host.name = "__MorphTest_host"
	host.data = src
	host.voxel_scale = 0.1
	Engine.get_main_loop().root.add_child(host)
	view.host = host
	view.rebuild()
	assert_true(view.particle_node != null, "应建出粒子节点")
	if view.particle_node == null:
		view.queue_free()
		host.queue_free()
		return
	var process_mat: ShaderMaterial = null
	if view.particle_node != null:
		process_mat = view.particle_node.process_material as ShaderMaterial
	assert_true(process_mat != null, "粒子节点应带更新材质")
	if process_mat != null:
		var tex: ImageTexture = process_mat.get_shader_parameter(VoxelParticleShader.U_SRC_POS)
		assert_true(tex != null, "位置纹理应已上传")
		if tex != null:
			var img := tex.get_image()
			var pts := view.particle_points
			var pixels := img.get_width() * img.get_height()
			# 纹理是 w*h 的矩形排布，末行可能带填充像素 -> 允许 pixels >= 点数
			assert_true(pixels >= pts.size() / 12, "纹理像素数不能少于点数")
			# 抽查前 64 个像素：纹理里的 xyz 必须等于点数组里同序的 xyz
			var checked := mini(64, pts.size() / 12)
			for i in checked:
				var px := img.get_pixel(i % img.get_width(), i / img.get_width())
				var base := i * 12
				assert_true(absf(px.r - pts[base]) < 0.0001 and absf(px.g - pts[base + 1]) < 0.0001 \
						and absf(px.b - pts[base + 2]) < 0.0001,
						"第 %d 个点：纹理 %s 与点数组 (%f,%f,%f) 不同序" % [i, px,
								pts[base], pts[base + 1], pts[base + 2]])
	# 端到端：视图里落地的点数组本身必须已经是 Morton 序（独立复算，不依赖被测实现的返回值）
	var landed := view.particle_points
	var prev := -1
	var first_bad := -1
	for k in mini(landed.size() / 12, 512):
		var code := _morton_code_of(landed, k, 12)
		if code < prev:
			first_bad = k
			break
		prev = code
	assert_eq(first_bad, -1,
			"VoxelParticleView 开启 spatial_sort 后点数组必须已是 Morton 序（首次违反在第 %d 位）" % first_bad)
	view.queue_free()
	host.queue_free()

# ─────────────────────────────── 辅助 ───────────────────────────────

func _source() -> QVoxelSource:
	var vox := VoxAsset.from_asset(CARS)
	if vox == null:
		return null
	return QVoxelSource.from_voxel_data(vox, 0, QVoxelSource.OriginMode.CONTENT_CENTER)

## 走真实数据层导出一份点云，并（可选）按空间序重排 —— 等价于 VoxelParticleView.rebuild() 的那两步，
func _view_points(src: QVoxelSource, spatial: bool) -> PackedFloat32Array:
	var tex := src.build_particle_textures(0.1, 4000, false)
	var pts: PackedFloat32Array = tex.get("points", PackedFloat32Array())
	if not spatial or pts.is_empty():
		return pts
	var order := VoxelMorphMap.sorted_indices(pts, 12)
	return VoxelMorphMap.reorder(pts, order, 12)

## 规则网格点云：每个格心一个点，其余 stride 通道填可区分的值。
func _grid_points(nx: int, ny: int, nz: int, step: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(nx * ny * nz * 12)
	var i := 0
	for z in nz:
		for y in ny:
			for x in nx:
				var b := i * 12
				out[b] = float(x) * step
				out[b + 1] = float(y) * step
				out[b + 2] = float(z) * step
				out[b + 3] = 1.0
				out[b + 4] = float(x) / float(maxi(nx, 1))
				out[b + 5] = float(y) / float(maxi(ny, 1))
				out[b + 6] = float(z) / float(maxi(nz, 1))
				out[b + 7] = 0.5
				out[b + 8] = 0.0
				out[b + 9] = 0.0
				out[b + 10] = 1.0
				out[b + 11] = 0.0
				i += 1
	return out

## 同一批格点，但**插入顺序被打乱**：用来验证排序真的在按空间重排，
func _scrambled_points(nx: int, ny: int, nz: int, step: float) -> PackedFloat32Array:
	var grid := _grid_points(nx, ny, nz, step)
	var n := grid.size() / 12
	var idx := PackedInt32Array()
	idx.resize(n)
	for i in n:
		idx[i] = i
	var rng := RandomNumberGenerator.new()
	rng.seed = 20251125
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := idx[i]
		idx[i] = idx[j]
		idx[j] = t
	var out := PackedFloat32Array()
	out.resize(grid.size())
	for i in n:
		for c in 12:
			out[i * 12 + c] = grid[idx[i] * 12 + c]
	return out

## 复刻 VoxelMorphMap._morton_of 的计算（用于独立验证"排序后单调"，不依赖被测实现的返回值）。
func _morton_code_of(points: PackedFloat32Array, index: int, stride: int) -> int:
	var n := points.size() / stride
	var min_v := Vector3(INF, INF, INF)
	var max_v := -min_v
	for i in n:
		var b := i * stride
		var p := Vector3(points[b], points[b + 1], points[b + 2])
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	var size := max_v - min_v
	var inv := Vector3(1023.0 / maxf(size.x, 0.000001), 1023.0 / maxf(size.y, 0.000001),
			1023.0 / maxf(size.z, 0.000001))
	var b2 := index * stride
	var x := clampi(int((points[b2] - min_v.x) * inv.x), 0, 1023)
	var y := clampi(int((points[b2 + 1] - min_v.y) * inv.y), 0, 1023)
	var z := clampi(int((points[b2 + 2] - min_v.z) * inv.z), 0, 1023)
	return _interleave(x) | (_interleave(y) << 1) | (_interleave(z) << 2)

## 10 位 -> 30 位展开（3 位间隔）。
func _interleave(v: int) -> int:
	var r := 0
	for b in 10:
		r |= ((v >> b) & 1) << (3 * b)
	return r

## 点集指纹：把所有点的坐标拼成"排序后的键列表"，用于"两个数组是否是同一个集合"的比较。
func _point_key_set(points: PackedFloat32Array, stride: int) -> PackedStringArray:
	var keys := PackedStringArray()
	var n := points.size() / stride
	keys.resize(n)
	for i in n:
		var b := i * stride
		keys[i] = "%.6f,%.6f,%.6f" % [points[b], points[b + 1], points[b + 2]]
	keys.sort()
	return keys

func _slice(points: PackedFloat32Array, base: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for c in 12:
		out[c] = points[base + c]
	return out
