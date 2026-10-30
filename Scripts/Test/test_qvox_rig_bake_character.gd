extends TestCase

## 真实角色验证：12 帧走路循环，比较 on ones / on twos / 补洞 / 留白。
## 目标不是"像素级正确"，而是确认参数对体素数、网格体积、烘焙耗时的影响，
## 并给出一组可用的默认值。

const Rig := preload("res://demo/character_rig_bake.gd")
const Baker := preload("res://addons/VoxelSupport/Model/QVoxelRigBaker.gd")

const FRAMES := 12
const FPS := 12


func _solid_count(frame: QVoxelFrame) -> int:
	var n := 0
	for bk: Vector3i in frame.blocks:
		var buf: PackedInt32Array = frame.blocks[bk]
		for m in buf:
			if m != 0:
				n += 1
	return n


func _positions(frame: QVoxelFrame, bs: int) -> Dictionary:
	var out := {}
	for bk: Vector3i in frame.blocks:
		var buf: PackedInt32Array = frame.blocks[bk]
		var origin := QVoxelSpec.block_origin(bk, bs)
		for lz in bs:
			for ly in bs:
				for lx in bs:
					if buf[QVoxelSpec.local_index(lx, ly, lz, bs)] != 0:
						out[origin + Vector3i(lx, ly, lz)] = true
	return out


func _materials(frame: QVoxelFrame) -> Dictionary:
	var out := {}
	for bk: Vector3i in frame.blocks:
		var buf: PackedInt32Array = frame.blocks[bk]
		for m in buf:
			if m != 0:
				out[m] = true
	return out


func _source_count(w: QVoxelWorld) -> int:
	var n := 0
	for m in w.all_models():
		n += m.count_solid()
	return n


func _run(w: QVoxelWorld, root: QVoxelNode, label: String, options: Dictionary) -> QVoxelModel:
	var t0 := Time.get_ticks_msec()
	var baked := Baker.bake(w, root, options)
	var ms := Time.get_ticks_msec() - t0
	assert_true(baked != null, "%s 应能烘焙" % label)
	if baked == null:
		return null
	var n := baked.frame_count()
	var total := 0
	var min_count := 1 << 30
	var max_count := 0
	for i in n:
		var c := _solid_count(baked.frame_at(i))
		assert_true(c > 0, "%s 第 %d 帧不能为空" % [label, i])
		total += c
		min_count = mini(min_count, c)
		max_count = maxi(max_count, c)
	var vol := baked.grid_size.x * baked.grid_size.y * baked.grid_size.z
	print("[角色烘焙] %-8s frames=%d grid=%s vol=%d voxels min=%d max=%d avg=%.0f time=%dms dur=%dms"
			% [label, n, baked.grid_size, vol, min_count, max_count,
			float(total) / float(maxi(n, 1)),
			ms, baked.frame_at(0).duration_ms])
	return baked


func test_character_bake_settings() -> void:
	var w := Rig.build_world()
	assert_true(w != null, "角色世界应能构建")
	if w == null:
		return
	var root := w.nodes[0]
	var src := _source_count(w)
	print("[角色烘焙] 源体素数=%d frames=%d" % [src, FRAMES])
	assert_true(src > 1500, "角色应有一定体量，实际 %d" % src)

	var ones := _run(w, root, "ones", {
		"frame_step": 1, "source_fps": FPS, "padding": 1,
		"fill_gaps": true, "gap_min_neighbors": 3,
	})
	var twos := _run(w, root, "twos", {
		"frame_step": 2, "source_fps": FPS, "padding": 1,
		"fill_gaps": true, "gap_min_neighbors": 3,
	})
	var no_gap := _run(w, root, "no_gap", {
		"frame_step": 1, "source_fps": FPS, "padding": 1,
		"fill_gaps": false,
	})
	var gap2 := _run(w, root, "gap2", {
		"frame_step": 1, "source_fps": FPS, "padding": 1,
		"fill_gaps": true, "gap_min_neighbors": 2, "gap_passes": 2,
	})
	assert_true(ones != null and twos != null and no_gap != null and gap2 != null)
	if ones == null or twos == null or no_gap == null or gap2 == null:
		return

	assert_eq(ones.frame_count(), FRAMES, "on ones 12 帧")
	assert_eq(twos.frame_count(), 6, "on twos 6 帧")
	assert_eq(twos.frame_at(0).duration_ms, 167, "on twos 每帧 167ms")
	assert_true(gap2.frame_count() == FRAMES, "补洞不改变帧数")

	var ones_total := 0
	var no_gap_total := 0
	var gap2_total := 0
	for i in FRAMES:
		ones_total += _solid_count(ones.frame_at(i))
		no_gap_total += _solid_count(no_gap.frame_at(i))
		gap2_total += _solid_count(gap2.frame_at(i))
	print("[角色烘焙] 总计数 ones=%d no_gap=%d gap2=%d (源×帧=%d)"
			% [ones_total, no_gap_total, gap2_total, src * FRAMES])
	assert_true(ones_total >= src * FRAMES * 0.7,
			"烘焙后不应明显丢体素：%d vs %d" % [ones_total, src * FRAMES])
	assert_true(ones_total <= src * FRAMES * 1.6,
			"烘焙后不应明显膨胀：%d vs %d" % [ones_total, src * FRAMES])
	assert_true(gap2_total >= no_gap_total, "补洞只会加体素，不应减少")


func test_character_materials_and_motion() -> void:
	var w := Rig.build_world()
	if w == null:
		return
	var root := w.nodes[0]
	var baked := Baker.bake(w, root, {
		"frame_step": 1, "source_fps": FPS, "padding": 1,
		"fill_gaps": true, "gap_min_neighbors": 3,
	})
	assert_true(baked != null)
	if baked == null:
		return
	var mats := _materials(baked.frame_at(0))
	print("[角色烘焙] 第 0 帧材质数=%d ids=%s" % [mats.size(), mats.keys()])
	assert_true(mats.size() >= 6, "皮肤/衣服/裤子/鞋/头发/剑等材质应保留")

	var p0 := _positions(baked.frame_at(0), baked.block_size)
	var p3 := _positions(baked.frame_at(3), baked.block_size)
	var diff := 0
	for p in p0:
		if not p3.has(p):
			diff += 1
	print("[角色烘焙] 第 0 帧 vs 第 3 帧不同位置数=%d" % diff)
	assert_true(diff > 20, "第 0 帧与第 3 帧应有明显不同（动画确实生效）")


func test_padding_controls_grid_size() -> void:
	var w := Rig.build_world()
	if w == null:
		return
	var root := w.nodes[0]
	var pad0 := Baker.bake(w, root, {
		"frame_step": 1, "source_fps": FPS, "padding": 0,
		"fill_gaps": false,
	})
	var pad2 := Baker.bake(w, root, {
		"frame_step": 1, "source_fps": FPS, "padding": 2,
		"fill_gaps": false,
	})
	assert_true(pad0 != null and pad2 != null)
	if pad0 == null or pad2 == null:
		return
	print("[角色烘焙] padding: 0 → %s, 2 → %s" % [pad0.grid_size, pad2.grid_size])
	assert_eq(pad2.grid_size - pad0.grid_size, Vector3i(4, 4, 4),
			"padding 每侧加 N，三维各多 2N 格")
