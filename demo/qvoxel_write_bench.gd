class_name QVoxelWriteBench
extends RefCounted

## QVX 写路径端到端基准（可在编辑器 / 游戏进程内直接调用，不依赖场景）。
##
## 用法（eval_code）：
##   QVoxelWriteBench.run()   → 结果通过 print 输出，用 get_logs 读取
##
## 【为什么只测公开接口】存储层已把"增量怎么写、旧字节怎么搬运"收进
## QVoxelFile.serialize_incremental（按块索引 + 写入覆盖层 + 删除集）。基准若再伸手去调
## 那些内部函数，等于把实现细节抄第二遍——实现一变基准先坏。故这里只调 VoxelStream 的
## 公开契约：save_chunk / flush / load_chunk / has_chunk / is_dirty / get_chunk_count。
##
## 口径：把 N 块写进空世界（无旧块可搬 → 必然全量写）作为基线，与"已落盘世界里改 1 块
## 再写"（必然增量写）对比 —— 两者之差即增量写省下的重编码 + 重写量。

const CHUNK_SIZE := 32
const CHUNK_VOLUME := 32768

## 世界尺寸：SIDE² 个 chunk（y 固定为 0）。
const SIDE := 12

## 增量写重复次数 / 全量重建对照次数（对照较慢，次数少些）。
const INCR_ROUNDS := 10
const FULL_ROUNDS := 3

const BENCH_DIR := "user://qvx_bench"


static func _us(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


## 造一个"真实感"的块：低频噪声，填充率约 40%~60%，codec 非平凡但可压缩。
static func _make_chunk(seed_pos: Vector3i, mat_base: int = 1) -> PackedInt32Array:
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


## 模拟一次真实编辑：把约 2000 个体素换成 0 / 6。
static func _edit(src: PackedInt32Array) -> PackedInt32Array:
	var ed := src.duplicate()
	for k in 2000:
		ed[(k * 7919) % CHUNK_VOLUME] = 0 if k % 2 == 0 else 6
	return ed


static func _reset_files(names: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BENCH_DIR))
	for n in names:
		var p := ProjectSettings.globalize_path(BENCH_DIR + "/" + String(n))
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


static func run() -> void:
	var lines: Array = []
	var chunk_count := SIDE * SIDE
	lines.append("=== QVX 写路径基准（端到端）===")
	lines.append("chunk=%d (%dx%d) CHUNK_SIZE=%d VOL=%d" % [chunk_count, SIDE, SIDE, CHUNK_SIZE, CHUNK_VOLUME])

	# 造数据
	var t0 := Time.get_ticks_usec()
	var chunks: Array = []
	for z in SIDE:
		for x in SIDE:
			var ck := Vector3i(x, 0, z)
			chunks.append([ck, _make_chunk(ck)])
	lines.append("生成 %d 块: %.1fms" % [chunk_count, _us(t0)])

	var mats: Array = []
	for i in 8:
		mats.append(null)

	# ---- 阶段 1：首次全量写（空世界，无旧块可搬 → 必然全量）----
	_reset_files(["world.qvx", "world2.qvx"])
	var stream := QVoxelStream.new()
	stream.file_path = BENCH_DIR + "/world.qvx"
	stream.set_materials(mats)

	t0 = Time.get_ticks_usec()
	for c in chunks:
		stream.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
	var t_save_all := _us(t0)
	t0 = Time.get_ticks_usec()
	stream.flush()
	var t_full := _us(t0)
	lines.append("首次全量: save×%d=%.1fms  flush=%.1fms  文件=%dKB  落盘后仍脏=%s"
			% [chunk_count, t_save_all, t_full, _fsize(stream.file_path) / 1024,
				str(stream.is_dirty())])

	# ---- 阶段 2：增量写 ×N（每次只改 1 块）----
	var incr: Array = []
	for i in INCR_ROUNDS:
		var ck: Vector3i = chunks[i][0]
		stream.save_chunk(ck, _edit(chunks[i][1] as PackedInt32Array), 0)
		t0 = Time.get_ticks_usec()
		stream.flush()
		incr.append(_us(t0))
	lines.append("增量写×%d(每次改1块): 均 %.2fms  %s" % [INCR_ROUNDS, _avg(incr), _fmt(incr)])

	# ---- 阶段 3：对照 —— 从零重建整个世界（每次都要重编码全部块）----
	var full: Array = []
	for _r in FULL_ROUNDS:
		var s := QVoxelStream.new()
		s.file_path = BENCH_DIR + "/world2.qvx"
		s.set_materials(mats)
		t0 = Time.get_ticks_usec()
		for c in chunks:
			s.save_chunk(c[0] as Vector3i, c[1] as PackedInt32Array, 0)
		s.flush()
		full.append(_us(t0))
	lines.append("全量重建×%d(每次写全部%d块): 均 %.2fms  %s"
			% [FULL_ROUNDS, chunk_count, _avg(full), _fmt(full)])

	# ---- 阶段 4：正确性（重载磁盘逐块比对）+ 内存有界 ----
	var r := QVoxelStream.new()
	r.file_path = stream.file_path
	var ok := true
	for i in INCR_ROUNDS:
		var ck: Vector3i = chunks[i][0]
		if r.load_chunk(ck, 0) != _edit(chunks[i][1] as PackedInt32Array):
			ok = false
	lines.append("正确性(重载比对 %d 块): %s  落盘后未写状态为空=%s  磁盘块数=%d"
			% [INCR_ROUNDS, "PASS" if ok else "FAIL",
				str(not stream.is_dirty()), stream.get_chunk_count(0)])

	# ---- 阶段 5：粗层（CACH）往返：按需读盘 + 来源校验 ----
	var coarse := PackedInt32Array()
	coarse.resize(CHUNK_VOLUME)
	coarse[VoxelChunk.buf_index(3, 3, 3)] = 2
	stream.save_chunk(Vector3i.ZERO, coarse, 1)
	t0 = Time.get_ticks_usec()
	stream.flush()
	var t_cach := _us(t0)
	var r2 := QVoxelStream.new()
	r2.file_path = stream.file_path
	var coarse_ok := r2.has_chunk(Vector3i.ZERO, 1) and r2.load_chunk(Vector3i.ZERO, 1) == coarse
	lines.append("粗层 CACH: 写盘=%.2fms  重载命中且逐体素一致=%s  (世界文件 %dKB)"
			% [t_cach, str(coarse_ok), _fsize(stream.file_path) / 1024])

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
