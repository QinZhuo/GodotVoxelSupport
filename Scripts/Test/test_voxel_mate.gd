extends TestCase

## MATE 条目语义的唯一实现（Format/QVoxelMate.gd）—— 形状与字节往返契约。

# ── 形状 ────────────────────────────────────────────────────────────────…

func test_air_entry_has_twelve_keys_and_is_all_zero() -> void:
	var e := QVoxelMate.air_entry()
	assert_eq(e.size(), 12, "空气条目必须是 12 键（8 个语义键 + r/g/b/a 展开）")
	for k in QVoxelMate.AIR_KEYS:
		assert_true(e.has(k), "空气条目缺少语义键 %s" % k)
		assert_eq(int(e[k]), 0, "空气条目 %s 必须为 0" % k)
	for ch in ["r", "g", "b", "a"]:
		assert_true(e.has(ch), "空气条目必须带 %s 通道（缺它就是洋红 bug 的来源）" % ch)
		assert_eq(int(e[ch]), 0, "空气条目 %s 通道必须为 0" % ch)
	assert_true(QVoxelMate.is_air_entry(e), "全零条目必须被判为空气")

func test_air_entry_is_a_fresh_dictionary_each_call() -> void:
	# 空气条目是"规范形态"，调用方会就地改它（with_color 之外的面板路径也会）。
	var a := QVoxelMate.air_entry()
	var b := QVoxelMate.air_entry()
	a["rgba"] = 0x11223344
	assert_eq(int(b["rgba"]), 0, "两次调用必须互不共享引用")

func test_is_air_entry_judges_by_semantic_keys_only() -> void:
	var legacy8 := {
		"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0,
		"e_r": 0, "e_g": 0, "e_b": 0,
	}
	assert_true(QVoxelMate.is_air_entry(legacy8), "8 键历史空气条目也应判为空气（判据不看通道键）")

	var colored := QVoxelMate.air_entry()
	colored["rgba"] = 0xFF0000FF
	assert_false(QVoxelMate.is_air_entry(colored), "有颜色就不是空气")

	# 冗余通道键与 rgba 不一致时，判据只认 AIR_KEYS，故不会被通道键带偏。
	var drift := QVoxelMate.air_entry()
	drift["r"] = 255
	assert_true(QVoxelMate.is_air_entry(drift), "判据不看冗余通道键")

	# reserved 字节非零的读端条目不该被误判：语义判据只在 Dictionary 上做。
	assert_false(QVoxelMate.is_air_entry(null), "非 Dictionary 不该被判成空气")
	assert_false(QVoxelMate.is_air_entry("air"), "非 Dictionary 不该被判成空气")

# ── 字节往返 ──────────────────────────────────────────────────────────────

func test_encode_decode_roundtrip_preserves_every_semantic_field() -> void:
	var entries: Array = [
		QVoxelMate.air_entry(),
		{"rgba": 0x0A141E28, "metal": 200, "rough": 100, "hardness": 7, "mass": 9,
				"e_r": 5, "e_g": 6, "e_b": 7},
	]
	var payload := QVoxelMate.encode(entries)
	assert_eq(payload.size(), 2 + entries.size() * QVoxelSpec.MATE_ENTRY_SIZE,
			"payload = uint16 count + count×12 字节")
	assert_eq(payload.decode_u16(0), entries.size(), "count 写在最前")

	var back := QVoxelMate.decode(payload)
	assert_eq(back.size(), entries.size(), "解码条目数应一致")
	for i in entries.size():
		var want: Dictionary = entries[i]
		var got: Dictionary = back[i]
		assert_eq(int(got["rgba"]), int(want["rgba"]), "条目 %d rgba 往返应一致" % i)
		for k in ["metal", "rough", "hardness", "mass", "e_r", "e_g", "e_b"]:
			assert_eq(int(got[k]), int(want[k]), "条目 %d %s 往返应一致" % [i, k])
		assert_eq(int(got["r"]), (int(want["rgba"]) >> 24) & 0xFF, "条目 %d r 由 rgba 展开" % i)
		assert_eq(int(got["a"]), int(want["rgba"]) & 0xFF, "条目 %d a 由 rgba 展开" % i)

func test_encode_writes_zero_into_reserved_byte() -> void:
	# reserved 按规范恒写 0。
	var e := QVoxelMate.air_entry()
	e["reserved"] = 0xAB
	var payload := QVoxelMate.encode([e])
	assert_eq(int(payload[2 + QVoxelSpec.MATE_ENTRY_SIZE - 1]), 0, "reserved 必须写 0")

func test_entry_from_bytes_reads_rgba_channel_bit_order() -> void:
	# rgba 位序 r<<24 | g<<16 | b<<8 | a —— 写盘与 .vox 导入两侧都依赖它。
	var payload := PackedByteArray()
	payload.resize(QVoxelSpec.MATE_ENTRY_SIZE)
	payload.encode_u32(0, 0x11223344)
	payload[4] = 11
	payload[5] = 22
	payload[6] = 33
	payload[7] = 44
	payload[8] = 55
	payload[9] = 66
	payload[10] = 77
	var e := QVoxelMate.entry_from_bytes(payload, 0)
	assert_eq(int(e["r"]), 0x11, "r 取最高字节")
	assert_eq(int(e["g"]), 0x22, "g 取次高字节")
	assert_eq(int(e["b"]), 0x33, "b 取次低字节")
	assert_eq(int(e["a"]), 0x44, "a 取最低字节")
	assert_eq(int(e["metal"]), 11, "metal 在第 5 字节")
	assert_eq(int(e["e_b"]), 77, "e_b 在第 11 字节")

# ── 坏负载必须降级并报告，而不是拖垮整个文件 ──────────────────────────────

func test_decode_reports_and_degrades_on_malformed_payload() -> void:
	var seen: Array = []
	var warn := func(msg: String) -> void:
		seen.append(msg)

	assert_eq(QVoxelMate.decode(PackedByteArray([1]), warn).size(), 0,
			"不足 2 字节（读不出 count）应降级为空材质")
	assert_eq(seen.size(), 1, "这种情况应报告一次")

	var zero := PackedByteArray()
	zero.resize(2)
	seen.clear()
	assert_eq(QVoxelMate.decode(zero, warn).size(), 0,
			"entry_count=0 违反规范（至少含空气条目），应降级")
	assert_eq(seen.size(), 1, "entry_count=0 应报告一次")

	var truncated := PackedByteArray()
	truncated.resize(2 + QVoxelSpec.MATE_ENTRY_SIZE)
	truncated.encode_u16(0, 3)
	seen.clear()
	assert_eq(QVoxelMate.decode(truncated, warn).size(), 0,
			"声明 3 条但只有 1 条的字节：越界应降级，而不是读越界内存")
	assert_eq(seen.size(), 1, "越界应报告一次")

# ── 颜色：只认 rgba ────────────────────────────────────────────────────────

func test_color_only_reads_rgba_and_never_returns_magenta_for_valid_entry() -> void:
	var e := QVoxelMate.with_color(QVoxelMate.air_entry(), Color8(10, 20, 30, 40))
	var c := QVoxelMate.color(e)
	assert_eq(QVoxelMate.color_to_rgba(c), 0x0A141E28, "颜色往返应逐字节一致")
	assert_ne(c, Color.MAGENTA, "有效条目绝不该是洋红")
	assert_eq(QVoxelMate.color(null), Color.MAGENTA, "非 Dictionary 才用洋红当可见的错误色")

	# 通道键错、rgba 对的条目：必须按 rgba 取色（历史 8 键/漂移键都不会再变洋红）。
	var drifted := QVoxelMate.air_entry()
	drifted["rgba"] = 0x0A141E28
	drifted["r"] = 255
	drifted["g"] = 0
	assert_eq(QVoxelMate.color_to_rgba(QVoxelMate.color(drifted)), 0x0A141E28,
			"权威值是 rgba，冗余通道键不该影响取色")

func test_with_color_replaces_the_dictionary_instead_of_mutating() -> void:
	# 撤销走 QVoxelPropertyCommand(world, &"materials")，快照只浅拷数组。
	var before := QVoxelMate.air_entry()
	var after := QVoxelMate.with_color(before, Color8(1, 2, 3, 255))
	assert_eq(int(before["rgba"]), 0, "原条目必须保持不变")
	assert_eq(int(after["rgba"]), QVoxelMate.color_to_rgba(Color8(1, 2, 3, 255)), "新条目带新颜色")
	assert_eq(int(after["r"]), 1, "新条目的通道已展开")
	assert_true(QVoxelMate.with_color(null, Color8(0, 0, 0, 255)).has("rgba"),
			"非 Dictionary 入口应回落成空气条目而不是崩")

func test_byte_of_rounds_and_clamps() -> void:
	assert_eq(QVoxelMate.byte_of(0.0), 0, "0.0 → 0")
	assert_eq(QVoxelMate.byte_of(1.0), 255, "1.0 → 255")
	assert_eq(QVoxelMate.byte_of(0.5), 128, "0.5 → 128（四舍五入，不是截断）")
	assert_eq(QVoxelMate.byte_of(-1.0), 0, "负值夹到 0")
	assert_eq(QVoxelMate.byte_of(2.0), 255, "超 1 夹到 255")
