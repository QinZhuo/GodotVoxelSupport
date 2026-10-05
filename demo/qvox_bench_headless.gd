extends SceneTree

## 无头基准运行器：直接跑 QVox 写路径基准并退出，不依赖编辑器/游戏窗口。
## 用法：
##   godot --headless --path <proj> --script res://demo/qvox_bench_headless.gd

func _initialize() -> void:
	# SceneTree 已就绪，直接同步跑
	run_bench()
	quit()


func run_bench() -> void:
	const CS := 32
	const CV := 32768
	var lines: Array = []
	var SIDE := 12
	var chunk_count := SIDE * SIDE
	lines.append("=== QVox 写路径基准（headless）===")
	lines.append("chunk=%d (%dx%d) B=%d N=%d" % [chunk_count, SIDE, SIDE, CS, CV])

	# 造数据
	var t0 := Time.get_ticks_usec()
	var chunks: Array = []
	for z in SIDE:
		for x in SIDE:
			var ck := Vector3i(x, 0, z)
			chunks.append([ck, _make_chunk(ck)])
	lines.append("生成 %d 块: %.1fms" % [chunk_count, _us(t0)])

	# 清旧文件
	var dir := "user://qvox_bench"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var wp := ProjectSettings.globalize_path(dir + "/world.qvox")
	if FileAccess.file_exists(wp):
		DirAccess.remove_absolute(wp)

	var mats: Array = []
	for i in 8:
		mats.append(null)

	# ---- 首次全量写 ----
	var stream := QVoxStream.new()
	stream.file_path = dir + "/world.qvox"
	stream.set_materials(mats)
	t0 = Time.get_ticks_usec()
	for c in chunks:
		stream.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
	var t_save := _us(t0)
	t0 = Time.get_ticks_usec()
	stream.flush()
	var t_full := _us(t0)
	lines.append("首次全量: save×%d=%.2fms flush=%.1fms 文件=%dKB 增量可用=%s"
			% [chunk_count, t_save, t_full, _fsize(stream.file_path) / 1024, str(stream._can_write_incremental())])

	# ---- 增量写 ×10（每次改 1 块）----
	var incr: Array = []
	for i in 10:
		var ck: Vector3i = chunks[i][0]
		var ed: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			ed[(k * 7919) % CV] = 0 if k % 2 == 0 else 6
		stream.save_chunk(ck, ed, 0)
		t0 = Time.get_ticks_usec()
		stream.flush()
		incr.append(_us(t0))
	lines.append("增量写×10: 均 %.2fms %s" % [_avg(incr), _fmt(incr)])

	# ---- 对照：全量 serialize ×10 ----
	var f2 := QVoxStream.new()
	f2.file_path = dir + "/world2.qvox"
	f2.set_materials(mats)
	for c in chunks:
		f2.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
	f2.flush()
	var fullt: Array = []
	for i in 10:
		var ck2: Vector3i = chunks[i][0]
		var ed2: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			ed2[(k * 7919) % CV] = 0 if k % 2 == 0 else 6
		f2.save_chunk(ck2, ed2, 0)
		t0 = Time.get_ticks_usec()
		var doc := QVoxFile.QVoxDocument.new()
		doc.head = f2._build_head()
		doc.materials = f2._materials_to_qvox()
		doc.models = f2._models_to_qvox_models()
		doc.node = {}
		doc.unknown_blocks = {}
		var _b := QVoxFile.serialize(doc)
		fullt.append(_us(t0))
		f2._dirty = false
	lines.append("全量serialize×10: 均 %.2fms %s" % [_avg(fullt), _fmt(fullt)])

	# ---- 正确性 ----
	var s2 := QVoxStream.new()
	s2.file_path = stream.file_path
	s2.clear_cache()
	var ok := true
	for i in 10:
		var ck3: Vector3i = chunks[i][0]
		var got := s2.load_chunk(ck3, 0)
		var want: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			want[(k * 7919) % CV] = 0 if k % 2 == 0 else 6
		if got != want:
			ok = false
	lines.append("正确性(重载比对10块): %s" % ("PASS" if ok else "FAIL"))

	# ---- 单次增量写内部拆解 ----
	var ck0: Vector3i = chunks[0][0]
	var ed0: PackedInt32Array = (chunks[0][1] as PackedInt32Array).duplicate()
	for k in 2000:
		ed0[(k * 7919) % CV] = 0 if k % 2 == 0 else 6
	stream.save_chunk(ck0, ed0, 0)
	var docn := QVoxFile.QVoxDocument.new()
	docn.head = stream._build_head()
	docn.materials = stream._materials_to_qvox()
	docn.models = stream._models_to_qvox_models()
	docn.node = {}
	docn.unknown_blocks = {}
	t0 = Time.get_ticks_usec()
	var _m = stream._models_to_qvox_models()
	var t_m2q := _us(t0)
	t0 = Time.get_ticks_usec()
	var old_doc := QVoxFile.QVoxDocument.new()
	old_doc.block_index = stream._block_index
	old_doc.head = stream._loaded_head
	old_doc.materials = stream._loaded_materials
	old_doc.node = stream._loaded_node
	var out := QVoxFile.serialize_incremental(stream._raw_bytes, old_doc, docn, stream._dirty_models, stream._dirty_global, true, stream._dirty_chunks, stream._vox0_index)
	var t_incr := _us(t0)
	t0 = Time.get_ticks_usec()
	var _idx = QVoxFile.scan_block_index(out)
	var t_scan := _us(t0)
	lines.append("拆解: models_to_qvox=%.2fms serialize_incremental=%.2fms scan_index=%.3fms" % [t_m2q, t_incr, t_scan])

	# 进一步拆解 serialize_incremental 内部
	var vbi: Dictionary = {}
	for bi in stream._block_index:
		if bi["type"] == "VOX0":
			vbi = bi
	t0 = Time.get_ticks_usec()
	var enc: PackedByteArray = QVoxFile._try_encode_model_incremental(stream._raw_bytes, vbi, 0, docn.models["0"], stream._dirty_chunks, 32, stream._vox0_index.get(0, {}))
	var t_enc := _us(t0)
	lines.append("  子块编码=%.2fms payload=%d (旧=%d)" % [t_enc, enc.size(), vbi["total"] - 12])
	t0 = Time.get_ticks_usec()
	var _pick := QVoxBlockCodec.pick_codec(stream.load_chunk(ck0, 0), CV)
	lines.append("  单块 pick_codec=%.2fms" % _us(t0))

	# ---- 字节级等价性：增量写结果 == 全量 serialize 结果 ----
	# 关键回归：增量写的字节必须与"全量 serialize"**逐字节一致**（含块 CRC），
	# 否则只是变快而已。
	var doc_full := QVoxFile.QVoxDocument.new()
	doc_full.head = stream._build_head()
	doc_full.materials = stream._materials_to_qvox()
	doc_full.models = stream._models_to_qvox_models()
	doc_full.node = {}
	doc_full.unknown_blocks = {}
	var full_bytes := QVoxFile.serialize(doc_full)
	if full_bytes == out:
		lines.append("字节等价(增量==全量): PASS (%d bytes)" % out.size())
	else:
		lines.append("字节等价(增量==全量): FAIL 增量=%d 全量=%d" % [out.size(), full_bytes.size()])
		var d := -1
		for i in mini(out.size(), full_bytes.size()):
			if out[i] != full_bytes[i]:
				d = i
				break
		lines.append("  首个差异偏移=%d" % d)

	# ---- CRC 校验：重新解析增量产物，确认所有块 CRC 通过 ----
	# 解析告警（含"块 X 的 CRC 不匹配，已跳过"）汇集在 QVoxReport.warnings 里。
	var rep := QVoxFile.QVoxReport.new()
	var reparsed := QVoxFile.parse_with_index(out, true, rep)
	var bad := 0
	for w in rep.warnings:
		if String(w).contains("CRC"):
			bad += 1
	lines.append("重解析+CRC校验: %s (models=%d, crc告警=%d, 其余告警=%d)"
			% ["PASS" if bad == 0 else "FAIL", reparsed.models.size(), bad, rep.warnings.size() - bad])

	print("\n".join(PackedStringArray(lines)))


func _make_chunk(sp: Vector3i) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(32768)
	var rng := RandomNumberGenerator.new()
	rng.seed = sp.x * 73856093 ^ sp.y * 19349663 ^ sp.z * 83492791
	var w1 := rng.randf() * 6.283
	var w2 := rng.randf() * 6.283
	var w3 := rng.randf() * 6.283
	for z in 32:
		for y in 32:
			for x in 32:
				var v := sin(x / 32.0 * 3.0 + w1) + cos(y / 32.0 * 4.0 + w2) + sin(z / 32.0 * 3.5 + w3)
				if v > 0.2:
					buf[x + y * 32 + z * 1024] = 1 + int(absf(v) * 3.0) % 5
	return buf


func _us(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _fsize(p: String) -> int:
	var ap := ProjectSettings.globalize_path(p)
	if not FileAccess.file_exists(ap):
		return 0
	var f := FileAccess.open(ap, FileAccess.READ)
	var n := f.get_length()
	f.close()
	return n


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _fmt(a: Array) -> String:
	var p: Array = []
	for v in a:
		p.append("%.1f" % v)
	return "[" + ", ".join(PackedStringArray(p)) + "]"
