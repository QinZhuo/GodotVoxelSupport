extends SceneTree

## 验证 crc32_combine 的正确性（必须与"直接拼接后整段算 CRC"完全一致）。

func _initialize() -> void:
	run()
	quit()


func run() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var pass_count := 0
	var fail_count := 0
	for trial in 50:
		var la := rng.randi_range(1, 5000)
		var lb := rng.randi_range(1, 5000)
		var a := PackedByteArray()
		var b := PackedByteArray()
		a.resize(la)
		b.resize(lb)
		for i in la:
			a[i] = rng.randi() & 0xFF
		for i in lb:
			b[i] = rng.randi() & 0xFF
		# 直接法：拼起来算
		var ab := PackedByteArray()
		ab.append_array(a)
		ab.append_array(b)
		var direct := _crc_of(ab)
		# 组合法
		var ca := _crc_of(a)
		var cb := _crc_of(b)
		var combined := QVoxFile.crc32_combine(ca, cb, lb)
		if combined == direct:
			pass_count += 1
		else:
			fail_count += 1
			if fail_count <= 3:
				print("FAIL trial=", trial, " la=", la, " lb=", lb, " direct=", direct, " combined=", combined)
	print("COMBINE_TEST pass=", pass_count, " fail=", fail_count)


## 对一段原始字节算标准 CRC32（初值 0xFFFFFFFF + 终值异或），用 QVoxFile 的表。
func _crc_of(data: PackedByteArray) -> int:
	var table := QVoxFile._crc32_table()
	var crc := 0xFFFFFFFF
	for i in data.size():
		crc = (crc >> 8) ^ int(table[(crc ^ data[i]) & 0xFF])
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
