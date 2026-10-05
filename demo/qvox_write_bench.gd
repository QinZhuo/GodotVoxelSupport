class_name QVoxWriteBench
extends RefCounted

## QVox 写路径分阶段基准（可在编辑器/游戏进程内直接调用，不依赖场景）。
##
## 用法（eval_code）：
##   QVoxWriteBench.run()   → 结果通过 print 输出，用 get_logs 读取
##
## 目的：拆解 _write_file() 各段耗时，确认增量路径是否真的被走到、瓶颈在哪。

const CHUNK_SIZE := 32
const CHUNK_VOLUME := 32768


static func _us(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


## 造一个"真实感"的块：低频噪声，填充率约 40%~60%，codec 非平凡但可压缩。
static func _make_chunk(seed_pos: Vector3i, mat_base: int) -> PackedInt32Array:
	var buf := PackedInt32Array()
	buf.resize(CHUNK_VOLUME)
	var s := seed_pos.x * 73856093 ^ seed_pos.y * 19349663 ^ seed_pos.z * 83492791
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	var B := CHUNK_SIZE
	var w1 := rng.randf() * 6.283
	var w2 := rng.randf() * 6.283
	var w3 := rng.randf() * 6.283
	for z in B:
		for y in B:
			for x in B:
				var nx := float(x) / float(B)
				var ny := float(y) / float(B)
				var nz := float(z) / float(B)
				var v := sin(nx * 3.0 + w1) + cos(ny * 4.0 + w2) + sin(nz * 3.5 + w3)
				if v > 0.2:
					buf[x + y * B + z * B * B] = mat_base + int(absf(v) * 3.0) % 5 + 1
	return buf


static func run() -> void:
	var lines: Array = []
	var SIDE := 12
	var chunk_count := SIDE * SIDE
	lines.append("=== QVox 写路径分阶段基准 ===")
	lines.append("chunk=%d (%dx%d) CHUNK_SIZE=%d VOL=%d" % [chunk_count, SIDE, SIDE, CHUNK_SIZE, CHUNK_VOLUME])

	# 造数据
	var t0 := Time.get_ticks_usec()
	var chunks: Array = []
	for z in SIDE:
		for x in SIDE:
			var ck := Vector3i(x, 0, z)
			chunks.append([ck, _make_chunk(ck, 1)])
	lines.append("生成 %d 块: %.1fms" % [chunk_count, _us(t0)])

	# 清旧文件
	var dir := "user://qvox_bench"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for f in ["world.qvox", "world.qvox.tmp"]:
		var p := ProjectSettings.globalize_path(dir + "/" + f)
		if FileAccess.file_exists(dir + "/" + f) or FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

	var mats: Array = []
	for i in 8:
		mats.append(null)

	# ---- 阶段 1：首次全量写 ----
	var stream := QVoxStream.new()
	stream.file_path = dir + "/world.qvox"
	stream.set_materials(mats)

	t0 = Time.get_ticks_usec()
	for c in chunks:
		stream.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
	var t_save_all := _us(t0)

	t0 = Time.get_ticks_usec()
	stream.flush()
	var t_full := _us(t0)
	lines.append("首次全量: save×%d=%.1fms  flush=%.1fms  文件=%dKB  (增量可用=%s)"
			% [chunk_count, t_save_all, t_full, _fsize(stream.file_path) / 1024,
				str(stream._can_write_incremental())])

	# ---- 阶段 2：增量写（只改 1 块），连续 10 次 ----
	var incr: Array = []
	for i in 10:
		var ck: Vector3i = chunks[i][0]
		var ed: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			ed[(k * 7919) % CHUNK_VOLUME] = 0 if k % 2 == 0 else 6
		stream.save_chunk(ck, ed, 0)
		t0 = Time.get_ticks_usec()
		stream.flush()
		incr.append(_us(t0))
	lines.append("增量写×10(每次改1块): 均 %.2fms  %s" % [_avg(incr), _fmt(incr)])

	# ---- 阶段 3：对照全量 serialize（每次改 1 块）----
	var full: Array = []
	var f2 := QVoxStream.new()
	f2.file_path = dir + "/world2.qvox"
	f2.set_materials(mats)
	for c in chunks:
		f2.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
	f2.flush()
	for i in 10:
		var ck: Vector3i = chunks[i][0]
		var ed: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			ed[(k * 7919) % CHUNK_VOLUME] = 0 if k % 2 == 0 else 6
		f2.save_chunk(ck, ed, 0)
		t0 = Time.get_ticks_usec()
		var doc := QVoxFile.QVoxDocument.new()
		doc.head = f2._build_head()
		doc.materials = f2._materials_to_qvox()
		doc.models = f2._models_to_qvox_models()
		doc.node = {}
		doc.unknown_blocks = {}
		var bytes := QVoxFile.serialize(doc)
		full.append(_us(t0))
		f2._dirty = false
	lines.append("全量serialize×10(每次改1块): 均 %.2fms  %s" % [_avg(full), _fmt(full)])

	# ---- 阶段 4：正确性（写盘→重载→比对）----
	var stream2 := QVoxStream.new()
	stream2.file_path = stream.file_path
	stream2.clear_cache()
	var ok := true
	var checked := 0
	for i in 10:
		var ck: Vector3i = chunks[i][0]
		var got := stream2.load_chunk(ck, 0)
		var want: PackedInt32Array = (chunks[i][1] as PackedInt32Array).duplicate()
		for k in 2000:
			want[(k * 7919) % CHUNK_VOLUME] = 0 if k % 2 == 0 else 6
		if got != want:
			ok = false
		checked += 1
	lines.append("正确性(重载比对 %d 块): %s" % [checked, "PASS" if ok else "FAIL"])

	# 逐块细分：单次增量写内部各段耗时
	lines.append("--- 单次增量写内部拆解 ---")
	var ck0: Vector3i = chunks[0][0]
	var ed0: PackedInt32Array = (chunks[0][1] as PackedInt32Array).duplicate()
	for k in 2000:
		ed0[(k * 7919) % CHUNK_VOLUME] = 0 if k % 2 == 0 else 6
	stream.save_chunk(ck0, ed0, 0)
	var docn := QVoxFile.QVoxDocument.new()
	docn.head = stream._build_head()
	docn.materials = stream._materials_to_qvox()
	docn.models = stream._models_to_qvox_models()
	docn.node = {}
	docn.unknown_blocks = {}
	t0 = Time.get_ticks_usec()
	var _m := stream._models_to_qvox_models()
	var t_build := _us(t0)
	t0 = Time.get_ticks_usec()
	var old_doc := QVoxFile.QVoxDocument.new()
	old_doc.block_index = stream._block_index
	old_doc.head = stream._loaded_head
	old_doc.materials = stream._loaded_materials
	old_doc.node = stream._loaded_node
	var out := QVoxFile.serialize_incremental(stream._raw_bytes, old_doc, docn, stream._dirty_models, stream._dirty_global)
	var t_incr := _us(t0)
	t0 = Time.get_ticks_usec()
	var idx_doc := QVoxFile.parse_with_index(out)
	var t_refresh := _us(t0)
	lines.append("_models_to_qvox_models=%.2fms  serialize_incremental=%.2fms  parse_with_index(refresh)=%.2fms"
			% [t_build, t_incr, t_refresh])

	print("\n".join(PackedStringArray(lines)))


static func _fsize(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	var n := f.get_length()
	f.close()
	return n


static func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _fmt(a: Array) -> String:
	var parts: Array = []
	for v in a:
		parts.append("%.1f" % v)
	return "[" + ", ".join(PackedStringArray(parts)) + "]"
