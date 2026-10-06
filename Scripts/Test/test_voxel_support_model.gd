extends TestCase

## 体素支撑模型回归测试（编辑器进程即可，无需游戏进程）。
##
## 覆盖崩塌判定内核 VoxelNative.find_unsupported_around（**基线规则，无横向支撑**）：
##   稳定 ⟺ LOWER_5（正下 + 4 个"水平相邻的下方" = 宽脚）里任意一个存在且未失稳；y==0 恒稳定
##   传播 = UPPER_5（竖向，无上限）+ HORIZONTAL_4（横向连带扫落，无上限）
##   —— 横向**不算支撑**：楼板（1 格厚、下方空心）自身恒无支撑，被横向连带时整层扫落。
##
## 【为什么必须有这组测试】这条规则前后改过多轮却没有自动化验收，只能手工 eval 比对。
##   这里把语义钉死：以后任何人再动它，跑一次就知道有没有偏离基线。
##
## 断言用区间，避免边缘 1~2 格抖动即红。


func _make(positions: Array) -> VoxelData:
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
	return data


## 移除 removed 后跑一次失稳判定，返回失稳体素数
func _unstable_count(data: VoxelData, removed: Array) -> int:
	data.remove_voxels(removed)
	return data.find_unsupported_around(removed).size()


## 1 厚墙：宽 w、高 h，立在 z=0，底部就是 y=0
func _wall(w: int, h: int) -> Array:
	var pl: Array = []
	for x in w:
		for y in h:
			pl.append(Vector3i(x, y, 0))
	return pl


# ----------------------------------------------------------------------------
# ① 有下方支撑就不动
# ----------------------------------------------------------------------------

## 地面板破一处：邻位还踩在地面上 → 不塌
func test_ground_hole_stays() -> void:
	var pl: Array = []
	for x in 8:
		for z in 8:
			pl.append(Vector3i(x, 0, z))
	var d := _make(pl)
	assert_eq(_unstable_count(d, [Vector3i(3, 0, 3)]), 0, "地面破一处：邻位仍有支撑 → 不塌")


## 1 厚墙削掉墙脚一格：上方那格的"水平相邻下方"还在 → 不塌
func test_wall_one_voxel_hole_stays() -> void:
	var d := _make(_wall(12, 8))
	assert_eq(_unstable_count(d, [Vector3i(6, 0, 0)]), 0, "削墙脚单格：上方仍有宽脚支撑 → 不塌")


# ----------------------------------------------------------------------------
# ② 失去下方支撑且无处可挂 → 坠落（脆感来源）
# ----------------------------------------------------------------------------

## 1×1 独立柱拆底：上方无处可挂 → 整根坠落
func test_pillar_base_removed_whole_column_falls() -> void:
	var pl: Array = []
	for y in 6:
		pl.append(Vector3i(10, y, 20))
	var d := _make(pl)
	var n := _unstable_count(d, [Vector3i(10, 0, 20)])
	assert_eq(n >= 4 and n <= 6, true, "1×1 柱拆底：整列坠落（实测 5）")


## 1 厚墙整条底边被切：上方整面墙失去支撑 → 全部坠落
func test_wall_whole_base_cut_falls() -> void:
	var d := _make(_wall(12, 8))
	var base: Array = []
	for x in 12:
		base.append(Vector3i(x, 0, 0))
	var n := _unstable_count(d, base)
	assert_eq(n >= 70, true, "整条底边被切：上方 12×7 全部坠落（实测 84）")


## 空中孤立的板（旁边没有任何结构）：破坏其邻位 → 整块坠落（横向不成支撑）
func test_isolated_floating_plate_falls() -> void:
	var pl: Array = []
	for x in 8:
		for z in 8:
			pl.append(Vector3i(x, 0, z))
	for x in range(4, 6):
		for z in 2:
			pl.append(Vector3i(x, 10, z))
	var d := _make(pl)
	assert_eq(_unstable_count(d, [Vector3i(3, 10, 0)]), 4, "孤立悬空 2×2 板：4 格全部坠落")


## 空中孤立的 2 层块（下方是悬空实心）：整块坠落（8 格）
func test_isolated_two_layer_block_falls() -> void:
	var pl: Array = []
	for x in 8:
		for z in 8:
			pl.append(Vector3i(x, 0, z))
	for x in range(4, 6):
		for y in [10, 11]:
			for z in 2:
				pl.append(Vector3i(x, y, z))
	var d := _make(pl)
	assert_eq(_unstable_count(d, [Vector3i(3, 10, 0)]), 8, "孤立悬空 2×2×2 块：8 格全部坠落")


# ----------------------------------------------------------------------------
# ③ 横向不算支撑：楼板（下方空心）被横向连带整层扫落 —— 基线固有行为
# ----------------------------------------------------------------------------

## 两墙 + 20 宽楼板，拆掉一堵墙脚 → 楼板被横向连带扫落（中间 17 列 ×5 ≈ 85）
func test_slab_swept_when_wall_cut() -> void:
	var pl: Array = []
	for y in 6:
		for z in 5:
			pl.append(Vector3i(0, y, z))
			pl.append(Vector3i(19, y, z))
	for x in 20:
		for z in 5:
			pl.append(Vector3i(x, 3, z))
	var d := _make(pl)
	var cut: Array = []
	for y in 6:
		for z in 5:
			cut.append(Vector3i(0, y, z))
	var n := _unstable_count(d, cut)
	assert_eq(n >= 70, true, "拆一堵墙脚：楼板（下方空心）被横向连带扫落（实测 85）")


# ----------------------------------------------------------------------------
# ④ 破坏 → 移除立即生效（管道不等"检测在途"）
# ----------------------------------------------------------------------------

func test_damage_applies_in_same_frame() -> void:
	var data := _make(_wall(8, 8))
	var node := VoxelDestructible.new()
	node.data = data
	node.use_voxel_health = true
	node.damage_per_voxel = 2.0
	node.spawn_debris_on_damage = false
	node.collapse_mode = VoxelDestructible.CollapseMode.COLLAPSE_NONE
	var before := data.get_voxel_count()
	node.damage_voxel(Vector3i(3, 3, 0), false)
	node._process_destruction_pipeline()
	assert_eq(data.get_voxel(Vector3i(3, 3, 0)) <= 0, true, "破坏后同帧即落地")
	assert_eq(before - data.get_voxel_count() >= 1, true, "同帧内至少移除被破坏的那一格")
	node.free()
