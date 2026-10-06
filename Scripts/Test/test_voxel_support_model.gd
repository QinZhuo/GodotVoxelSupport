extends TestCase

## 体素支撑模型回归测试（编辑器进程即可，无需游戏进程）。
##
## 覆盖崩塌判定内核 VoxelNative.find_unsupported_around ——**基线模型**：
##   体素稳定 ⟺ LOWER_5（正下 + 4 个水平相邻的下方，即"宽脚"）中任意 1 个存在且未失稳；
##             贴地 y==0 恒稳定。
##   破坏 R 后从 R 的 UPPER_5（上方 5）+ HORIZONTAL_4（水平 4）出发传播：
##     竖向 UPPER_5 无上限（真失去下方支撑就该塌 = 破坏脆感来源）
##     横向 HORIZONTAL_4 无上限（连带扫落"本就下方悬空"的板 = 大范围崩塌的来源）
##
## 【为什么需要这组测试】这套判定前后被改过好几轮却没有自动化测试，只能手工 eval 比对，
## 每次改动都要重新手工验证且容易漏。这里把基线行为钉死，作为"回归到基线"的验收标准：
##   以后任何人（包括我）再动这条规则，跑一次就知道有没有偏离。
##
## 断言用区间而不是精确值，避免边缘 1~2 格抖动即红。

## 造一份世界 + 材质表。返回 [VoxelData, {}]
func _make(positions: Array) -> Array:
	var data := VoxelData.new()
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.hardness = 1.0
	mat.connection_strength = 9999.0
	mats[1] = mat
	data.materials = mats
	data.set_voxels(positions, 1, false)
	return [data, {}]


## 移除 removed 后跑一次失稳判定，返回失稳体素数
func _unstable_count(data: VoxelData, removed: Array) -> int:
	data.remove_voxels(removed)
	return data.find_unsupported_around(removed).size()


# ----------------------------------------------------------------------------
# ① 宽脚支撑：正下 / 水平相邻的下方任意一个存在即稳定
# ----------------------------------------------------------------------------

## 地面板破一处：被移除体的邻位都还踩在地面上 → 不塌
func test_ground_hole_stays() -> void:
	var pl: Array = []
	for x in 8:
		for z in 8:
			pl.append(Vector3i(x, 0, z))
	var w := _make(pl)
	var n := _unstable_count(w[0], [Vector3i(3, 0, 3)])
	assert_eq(n, 0, "地面破一处：邻位仍有支撑 → 不塌（实测 0）")


## 1 厚墙削掉墙脚一格：上方那格的"水平相邻的下方"还在 → 不塌（不会出 1 格宽竖井）
func test_wall_one_voxel_hole_stays() -> void:
	var pl: Array = []
	for x in 12:
		for y in 8:
			pl.append(Vector3i(x, y, 0))
	var w := _make(pl)
	var n := _unstable_count(w[0], [Vector3i(6, 0, 0)])
	assert_eq(n, 0, "1 厚墙削墙脚单格：上方仍有宽脚支撑 → 不塌（实测 0）")


# ----------------------------------------------------------------------------
# ② 竖向传播无上限：真正失去下方支撑 → 整列跟着塌（脆感来源）
# ----------------------------------------------------------------------------

## 1×1 独立柱拆底：上方逐格失去支撑 → 整根坠落
func test_pillar_base_removed_whole_column_falls() -> void:
	var pl: Array = []
	for y in 6:
		pl.append(Vector3i(10, y, 20))
	var w := _make(pl)
	var n := _unstable_count(w[0], [Vector3i(10, 0, 20)])
	assert_eq(n >= 4 and n <= 6, true, "1×1 柱拆底：上方整列失去宽脚支撑 → 坠落（实测 5）")


## 1 厚墙整条底边(y=0)被切：上方整面墙失去宽脚支撑 → 全部坠落
func test_wall_whole_base_cut_falls() -> void:
	var pl: Array = []
	for x in 12:
		for y in 8:
			pl.append(Vector3i(x, y, 0))
	var w := _make(pl)
	var base: Array = []
	for x in 12:
		base.append(Vector3i(x, 0, 0))
	var n := _unstable_count(w[0], base)
	assert_eq(n >= 70, true, "1 厚墙整条底边被切：上方 12×7 失去支撑 → 整面坠落（实测 84）")


# ----------------------------------------------------------------------------
# ③ 横向传播无上限：连带扫落"本就下方悬空"的板（大范围崩塌的来源）
# ----------------------------------------------------------------------------

## 两堵端墙 + 中间一层楼板（板下方是空气）：拆一堵墙脚 → 楼板被连带扫落
## 【这是基线模型的固有行为，也是"大面积崩塌"手感的来源；刻意钉住，避免以后被"优化"掉】
func test_slab_swept_when_support_cut() -> void:
	var pl: Array = []
	for y in 6:
		for z in 5:
			pl.append(Vector3i(0, y, z))
			pl.append(Vector3i(19, y, z))
	for x in 20:
		for z in 5:
			pl.append(Vector3i(x, 3, z))
	var w := _make(pl)
	var cut: Array = []
	for y in 6:
		for z in 5:
			cut.append(Vector3i(0, y, z))
	var n := _unstable_count(w[0], cut)
	assert_eq(n >= 80, true, "拆一堵墙脚：中间楼板（下方是空气）被横向连带扫落（实测 ~90）")


# ----------------------------------------------------------------------------
# ④ 破坏 → 移除立即生效（管道不等"检测在途"）
# ----------------------------------------------------------------------------

## 破坏后同一帧内调用一次管道，体素就应消失（不依赖下一帧 / 检测回填）
func test_damage_applies_in_same_frame() -> void:
	var data := VoxelData.new()
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.hardness = 1.0
	mat.connection_strength = 10.0
	mats[1] = mat
	data.materials = mats
	var pl: Array = []
	for x in 8:
		for y in 8:
			pl.append(Vector3i(x, y, 0))
	data.set_voxels(pl, 1, false)
	var node := VoxelDestructible.new()
	node.data = data
	node.use_voxel_health = true
	node.damage_per_voxel = 2.0
	node.spawn_debris_on_damage = false
	node.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_NONE
	var before := data.get_voxel_count()
	node.damage_voxel(Vector3i(3, 3, 0), false)
	node._process_destruction_pipeline()
	assert_eq(data.get_voxel(Vector3i(3, 3, 0)) <= 0, true, "破坏后同帧即落地（不依赖下一帧/检测回填）")
	assert_eq(before - data.get_voxel_count() >= 1, true, "同帧内至少移除被破坏的那一格")
	node.free()
