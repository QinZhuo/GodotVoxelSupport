extends SceneTree

## 命令行验证脚本：测试 VoxelNative.generate_chunk_dense 原生实现
## 用法: godot --headless -s res://native/test_native.gd

func _init() -> void:
	print("=== Native test ===")
	print("VoxelNative registered: ", ClassDB.class_exists("VoxelNative"))
	if not ClassDB.class_exists("VoxelNative"):
		print("FAIL: VoxelNative not loaded")
		quit(1)
		return

	# 1. 构造一个 18³ 光环，中间放 2x2x2 实心方块（材质1）
	var halo := PackedInt32Array()
	halo.resize(18 * 18 * 18)
	for z in 3:
		for y in 3:
			for x in 3:
				var idx := (x + 1) + (y + 1) * 18 + (z + 1) * 324
				halo[idx] = 1

	var trans_flags := PackedByteArray([0, 0])  # 索引0=空占位, 索引1=材质1 不透明

	var t0 := Time.get_ticks_usec()
	var res: Dictionary = VoxelNative.generate_chunk_dense(halo, trans_flags, 0.1, Vector3i(0, 0, 0), true, Vector3.ZERO)
	var elapsed := (Time.get_ticks_usec() - t0) / 1000.0

	print("generate_chunk_dense: ", elapsed, " ms")
	var solid_idxs: PackedInt32Array = res.get("solid_idxs", PackedInt32Array())
	var trans_idxs: PackedInt32Array = res.get("trans_idxs", PackedInt32Array())
	print("solid verts: ", (res.get("solid_verts", PackedVector3Array()) as PackedVector3Array).size())
	print("solid idxs: ", solid_idxs.size())
	print("trans idxs: ", trans_idxs.size())

	# 2x2x2 方块应有 6 面 × 4 顶点 = 24 顶点，24 索引
	if solid_idxs.size() == 24 and trans_idxs.is_empty():
		print("PASS: 2x2x2 cube = 24 solid indices")
	else:
		print("FAIL: expected 24 solid indices, got ", solid_idxs.size())

	# 2. 性能基准：真实大小 chunk 多次调用
	var big_halo := PackedInt32Array()
	big_halo.resize(18 * 18 * 18)
	for i in big_halo.size():
		big_halo[i] = (i * 7) % 5  # 伪随机材质 0-4
	var big_flags := PackedByteArray([0, 1, 1, 1, 1, 0])

	t0 = Time.get_ticks_usec()
	var iters := 500
	for k in iters:
		VoxelNative.generate_chunk_dense(big_halo, big_flags, 0.1, Vector3i(0, 0, 0), true, Vector3.ZERO)
	var per_op := (Time.get_ticks_usec() - t0) / 1000.0 / iters
	print("native generate avg: %.3f ms/op (%d iters)" % [per_op, iters])

	quit(0)
