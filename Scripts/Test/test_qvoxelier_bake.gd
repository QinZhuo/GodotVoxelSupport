extends TestCase

## 批量烘焙（`QVoxelBake`）的契约测试 —— "切几份 / 叫什么 / 跳哪些"这一段纯逻辑。
##
## 【为什么这三件事值得单独钉】它们错了都不会报错，只会让用户拿到**看起来正常**的错东西：
## 文件名里的 `/` 把文件写到别处去了；两个同名节点互相覆盖（少了文件却找不出少了谁）；
## 超 256³ 的文件被 MagicaVoxel 静默截断（"导出成功了，可模型少了一层壳"）。
## 视口那一层没法测这些 —— 这正是切分逻辑必须住在纯逻辑类里、而不是视口里的原因。

const DIR := "user://qvoxelier_bake_test"


## 每例之后清干净：本用例只往 DIR 这一个目录里写，故整体扫掉即可（幂等）。
func cleanup() -> void:
	var dir := DirAccess.open(DIR)
	if dir != null:
		for f in dir.get_files():
			dir.remove(f)
	DirAccess.remove_absolute(DIR)


# ----------------------------------------------------------------------------
# 切几份
# ----------------------------------------------------------------------------

func test_world_scope_yields_one_batch() -> void:
	var batches := QVoxelBake.plan(_world(), QVoxelBake.Scope.WORLD)
	assert_eq(batches.size(), 1, "整个世界 ⇒ 一个文件（与单次导出同一语义）")
	assert_eq(batches[0].name, "世界", "文件名取世界名")
	assert_true(batches[0].asset.fits_magica(), "8³ 的盒子远在上限之内")


func test_node_scope_covers_every_node() -> void:
	var w := _world()
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.NODE)
	assert_eq(batches.size(), w.all_nodes().size(), "每个节点各一份（组也在内）")
	assert_eq(w.all_nodes().size(), 3, "本例：一个组 + 两个模型")


func test_model_scope_covers_only_leaves() -> void:
	var w := _world()
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.MODEL)
	assert_eq(batches.size(), w.all_models().size(), "每个模型各一份")
	assert_true(batches.size() < w.all_nodes().size(), "组不产出，故比「每个节点」少")


## 帧内容要真的跟着帧走 —— 三个文件长得一模一样也"不报错"，但那说明逐帧求值没生效。
func test_frame_scope_bakes_frame_content() -> void:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("W")
	var m := w.create_model("M", Vector3i(8, 8, 8))
	m.set_voxel(1, 1, 1, 1)
	m.make_animated()  # 静态内容搬进第 0 帧
	m.add_frame(QVoxelFrame.new())  # 第 1 帧是空的
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.FRAME)
	assert_eq(batches.size(), 2, "两帧 ⇒ 两个文件")
	assert_eq(batches[0].asset.voxel_count(), 1, "第 0 帧就是改动画前的样子")
	assert_eq(batches[1].asset.voxel_count(), 0, "第 1 帧是空的 —— 说明确实逐帧求值了")


## 帧游标是"正在看第几帧"的瞬态状态：烘完必须放回去，否则用户会发现"导出之后画面停在最后一帧"。
func test_frame_scope_restores_active_frame() -> void:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("W")
	var m := w.create_model("M", Vector3i(8, 8, 8))
	m.set_voxel(1, 1, 1, 1)
	m.make_animated()
	m.add_frame(QVoxelFrame.new())
	m.add_frame(QVoxelFrame.new())
	m.active_frame = 0
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.FRAME)
	assert_eq(batches.size(), 3, "三帧 ⇒ 三个文件")
	assert_eq(batches[0].name, "W_f000", "帧号定宽零填充，否则 _f10 会排在 _f9 前面")
	assert_eq(batches[2].name, "W_f002", "末帧")
	assert_eq(m.active_frame, 0, "烘完把游标放回去")


## 没有动画时"每个帧"退化成一整块：用户点了它却只该得到一个文件，名字也不该带 _f000。
func test_frame_scope_without_animation_degrades_to_one() -> void:
	var batches := QVoxelBake.plan(_world(), QVoxelBake.Scope.FRAME)
	assert_eq(batches.size(), 1, "没有动画 ⇒ 退化成整个世界一块")
	assert_eq(batches[0].name, "世界", "不带 _f000 后缀")


func test_null_world_yields_nothing() -> void:
	assert_eq(QVoxelBake.plan(null, QVoxelBake.Scope.WORLD).size(), 0, "没有世界就没有产物")


# ----------------------------------------------------------------------------
# 叫什么
# ----------------------------------------------------------------------------

## 重名节点必须各自落地：覆盖的后果是"少了文件，却找不出少了谁"。
func test_duplicate_names_are_disambiguated() -> void:
	var batches := QVoxelBake.plan(_world(), QVoxelBake.Scope.MODEL)
	assert_eq(batches[0].name, "方块", "第一个用本名")
	assert_eq(batches[1].name, "方块_2", "第二个加序号，而不是覆盖前一个")


func test_prefix_is_prepended() -> void:
	var batches := QVoxelBake.plan(_world(), QVoxelBake.Scope.MODEL, "rock_")
	assert_eq(batches[0].name, "rock_方块", "前缀接在本名之前（用户按批次区分用途）")


## 文件名消毒：非法字符换掉、中文保留、结尾的点与空格去掉（Windows 会悄悄吃掉它们）。
func test_sanitize_keeps_cjk_and_drops_path_separators() -> void:
	assert_eq(QVoxelNaming.sanitize("石/头"), "石_头", "`/` 会被当成子目录，必须换掉")
	assert_eq(QVoxelNaming.sanitize("a:b*c?"), "a_b_c_", "Windows 非法字符一律换掉")
	assert_eq(QVoxelNaming.sanitize("第 3 关"), "第 3 关", "中文与空格是合法字符，保留")
	assert_eq(QVoxelNaming.sanitize("尾巴."), "尾巴", "结尾的点会被 Windows 吃掉")
	assert_eq(QVoxelNaming.sanitize("尾巴  "), "尾巴", "结尾的空格同理")


## 名字消毒成空时给个兜底名 —— 否则会写出一个叫 "." 的文件（Windows 直接失败）。
func test_blank_name_falls_back() -> void:
	var w := QVoxelWorld.create_empty()
	w.create_model("...", Vector3i(4, 4, 4))
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.MODEL)
	assert_eq(batches[0].name, "unnamed", "消毒后为空 ⇒ 兜底名，而不是空串")


# ----------------------------------------------------------------------------
# 跳哪些
# ----------------------------------------------------------------------------

## 落盘：真的写出文件、真的读得回来；写不了的**明确跳过并说明**，而不是产出残缺文件。
func test_write_lands_files_and_reports_skips() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var w := _world()
	w.create_model("空模型", Vector3i(4, 4, 4))  # 没有体素、也没有修改器
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.MODEL)
	var report := QVoxelBake.write(DIR, batches)
	assert_eq(int(report.written) + report.skipped.size(), batches.size(),
			"每一份都要有下文：写出去了，或者被跳过并说明")
	assert_eq(report.written, 2, "两个有体素的模型写出来了")
	assert_eq(report.skipped["空模型"], "没有可写的体积", "跳过的原因要说得出口")
	var path := DIR.path_join("方块.vox")
	assert_true(FileAccess.file_exists(path), "文件真的落在盘上")
	# 走自己的读口验一遍：**文件在 ≠ 文件能被读回**（`.vox` 是二进制容器，写歪了照样有个文件）
	var acc := VoxAccess.Open(path)
	assert_ne(acc, null, "写出的 .vox 能被自己读回")
	assert_eq(acc.voxel.models.size(), 1, "读回来是一个模型")
	assert_eq(acc.voxel.models[0].voxels.size(), 1, "体素数量往返不变")


## 超过 256³ 的盒子必须被跳过并说明 —— 写出去 MagicaVoxel 会**静默截断**，用户以为成功了。
func test_oversized_box_is_skipped_not_truncated() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var w := QVoxelWorld.create_empty()
	var big := w.create_model("巨块", Vector3i(VoxAccess.MODEL_LIMIT + 44, 4, 4))
	big.set_voxel(0, 0, 0, 1)
	var batches := QVoxelBake.plan(w, QVoxelBake.Scope.MODEL)
	assert_false(batches[0].asset.fits_magica(), "单轴超限即不算装得下")
	var report := QVoxelBake.write(DIR, batches)
	assert_eq(report.written, 0, "一个都不该写")
	assert_true(str(report.skipped["巨块"]).contains(str(VoxAccess.MODEL_LIMIT)),
			"跳过原因里要带上限数字，用户才知道超在哪儿")
	assert_false(FileAccess.file_exists(DIR.path_join("巨块.vox")),
			"不产出会被 MagicaVoxel 静默截断的文件")


## 提示语是用户唯一能看到"发生了什么"的地方：报数、且不把几百个名字糊一屏。
func test_summary_reports_counts_not_a_flood() -> void:
	var report := {"written": 7, "skipped": {"a": "没有可写的体积", "b": "写入失败（错误码 7）"}}
	var text := QVoxelBake.summary(report, "D:/out")
	assert_true(text.contains("7"), "要报出写了几个")
	assert_true(text.contains("D:/out"), "要报出写到哪儿")
	assert_true(text.contains("a") and text.contains("b"), "跳过的名字要露面")
	assert_true(text.contains("没有可写的体积"), "跳过原因要露面")


# ----------------------------------------------------------------------------
# 夹具
# ----------------------------------------------------------------------------

## 一棵"每一档都有东西"的树：带路径分隔符的组名、两个**同名**模型（钉去重）、8³ 的小盒。
func _world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("世界")
	w.add_material(Color(1.0, 0.0, 0.0))
	var g := w.create_group("组/一")
	var a := w.create_model("方块", Vector3i(8, 8, 8), g)
	a.set_voxel(1, 1, 1, 1)
	var b := w.create_model("方块", Vector3i(8, 8, 8))  # 与 a 重名
	b.set_voxel(2, 2, 2, 1)
	return w
