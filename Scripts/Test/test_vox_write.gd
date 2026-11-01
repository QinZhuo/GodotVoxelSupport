extends TestCase

## `.vox` 写入的契约：世界 → 字节 → 读回，几何 / 颜色 / 摆放都要活着过一遍。
## 同时钉住读取侧的行为（体素总数与颜色数）—— `VoxSpace` 的抽取动了那条代码路径，
## 行为必须一字不差。

const TMP := "user://vox_write_test.vox"


func cleanup() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


# 约定层

func test_axis_roundtrip() -> void:
	var v := Vector3i(3, 7, 11)
	assert_eq(VoxSpace.to_godot_pos(VoxSpace.to_vox_pos(v)), v, "体素坐标换算应互逆")
	assert_eq(VoxSpace.to_godot_size(VoxSpace.to_vox_size(v)), v, "尺寸换算应互逆")


## 合法朝向恰好 24 个，且每个都满足 `encode(decode(code)) == code`。
func test_rotation_roundtrip_24() -> void:
	var valid := 0
	for code in 128:
		if VoxSpace.encode_rotation(VoxSpace.decode_rotation(code)) == code:
			valid += 1
	assert_eq(valid, 24, "合法朝向应恰好 24 个")


func test_rotation_rejects_oblique() -> void:
	assert_eq(VoxSpace.encode_rotation(Basis(Vector3.UP, deg_to_rad(45))), -1,
			"非 90° 倍数的旋转应被拒绝")


# 往返

func test_write_read_roundtrip() -> void:
	var w := _box_world()
	var bytes := VoxWriter.encode(w)
	assert_true(not bytes.is_empty(), "应能编码出字节")
	if bytes.is_empty():
		return
	assert_eq(_save(bytes), OK, "应能落盘")
	var vox := VoxAsset.from_asset(TMP)
	assert_true(vox != null, "写出的文件应能被读回")
	if vox == null:
		return
	var back := VoxAssetWorld.to_world(vox)
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	var m := back.all_models()[0]
	assert_eq(m.grid_size, Vector3i(4, 4, 4), "尺寸应保持")
	assert_eq(_count(m), 64, "体素数应保持（4³ 实心）")
	assert_true(_same_color(back.material_color(1), w.material_color(1)), "第一种颜色应保持")
	assert_true(_same_color(back.material_color(2), w.material_color(2)), "第二种颜色应保持")


## 摆放：nTRN 的 `_t` 必须把"模型居中偏移 + 坐标平移"补偿干净，否则整体偏半个尺寸。
## 【比较体素的世界坐标，而不是节点原点】读端会把模型紧致化（去掉空边），节点原点因此会平移
## 一个 `base`；但每个体素落在世界里的位置必须一模一样 —— 那才是"摆对了"的定义。
func test_world_position_preserved() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	var m := w.create_model("m", Vector3i(5, 5, 5))
	m.fill_box(Vector3i(1, 1, 1), Vector3i(3, 3, 3), c)
	m.local_transform = Transform3D(Basis(Vector3.UP, PI / 2), Vector3(5, 2, -3))
	var want := _voxel_world(w, m)
	var bytes := VoxWriter.encode(w)
	assert_true(not bytes.is_empty(), "带旋转与平移的模型应能编码")
	if bytes.is_empty():
		return
	_save(bytes)
	var back := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	assert_eq(_voxel_world(back, back.all_models()[0]), want, "每个体素的世界坐标应保持")


## **收敛后**的编码必须逐字节稳定：读回的世界再写一遍，与上一次落盘的字节完全相同。
## 【为什么不是"第一次 == 第二次"】手造世界的 `local_transform` 是恒等，而读回来的世界是
## `T(base + offset)`（读端把模型紧致化后必须补回居中偏移）—— 两者几何等价，但 `_t` 的
## 写法不同。真正该守住的是"再写一次不再变"这个不动点。
func test_encode_is_stable() -> void:
	var w := _box_world()
	_save(VoxWriter.encode(w))
	var back := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	var first := VoxWriter.encode(back)
	_save(first)
	var back2 := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	if back2 == null:
		return
	# 用 assert_true 而不是 assert_eq：失败时不要把几 KB 的字节数组整个打印出来。
	var second := VoxWriter.encode(back2)
	assert_true(second == first, "读回后再编码应逐字节稳定（长度 %d vs %d）"
			% [first.size(), second.size()])


func test_material_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color(1, 0, 0))
	w.set_material_scalar(c, &"metal", 0.8)
	w.set_material_scalar(c, &"rough", 0.3)
	var m := w.create_model("m", Vector3i(2, 2, 2))
	m.set_voxel(0, 0, 0, c)
	_save(VoxWriter.encode(w))
	var vox := VoxAsset.from_asset(TMP)
	assert_true(vox != null, "应能被读回")
	if vox == null:
		return
	assert_true(absf(vox.materials[1].metal - 0.8) < 0.05, "金属度应保持")
	assert_true(absf(vox.materials[1].rough - 0.3) < 0.05, "粗糙度应保持")


## 嵌套组：`.vox` 的 nTRN 是**相对父**的局部变换，写绝对变换会让子层把父的位移/旋转再吃一遍。
## 这一条是 cars.vox 那类"多层嵌套 + 每层都有旋转"的真实结构的回归钉子。
func test_nested_group_transform() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	var outer := w.create_group("outer", null)
	outer.local_transform = Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(4, 0, 0))
	var inner := w.create_group("inner", outer)
	inner.local_transform = Transform3D(Basis(Vector3.FORWARD, PI / 2), Vector3(0, 3, 0))
	var m := w.create_model("box", Vector3i(3, 3, 3), inner)
	m.fill_box(Vector3i(0, 0, 0), Vector3i(1, 1, 1), c)
	m.local_transform = Transform3D(Basis(Vector3.UP, PI / 2), Vector3(1, 0, 2))
	var want := _voxel_world(w, m)
	var bytes := VoxWriter.encode(w)
	assert_true(not bytes.is_empty(), "嵌套组应能编码")
	if bytes.is_empty():
		return
	_save(bytes)
	var back := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	assert_eq(_voxel_world(back, back.all_models()[0]), want, "嵌套组下的体素世界坐标应保持")


## 粗糙度**独立于**金属度存在：真实资产里就有 `_type:"_metal"` 而 `_metal:0`、只调了 rough 的条目
## （`cars.vox` 的 142/152/208）。写端若只按 `metal > 0` 决定要不要写 MATL，这类材质整条丢失，
## 读回静默回落成默认 `rough = 1` —— 表面上看不出来，直到用户发现"材质被重置了"。
func test_rough_without_metal_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color(0, 1, 1))
	w.set_material_scalar(c, &"rough", 0.25)
	var m := w.create_model("m", Vector3i(2, 2, 2))
	m.set_voxel(0, 0, 0, c)
	_save(VoxWriter.encode(w))
	var vox := VoxAsset.from_asset(TMP)
	assert_true(vox != null, "应能被读回")
	if vox == null:
		return
	assert_true(absf(vox.materials[1].rough - 0.25) < 0.05,
			"金属度为 0 时粗糙度也必须落盘（实为 %.3f）" % vox.materials[1].rough)
	assert_true(vox.materials[1].metal < 0.05, "金属度应仍为 0")


## 导出只写**一个**占位图层。
## 【为什么钉这条】`.vox` 的 LAYR 只是"图层可见性开关"，分组在 `nTRN`/`nGRP` 树上、可见性在
## 每个节点的 `_hidden` 上。按顶层节点建图层等于凭空造出第二套并行层级 —— 这是**设计决定**，
## 不是代码细节，所以要有测试盯着，避免哪天被"顺手改回去"。
func test_single_layer_chunk() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	for i in 2:
		var m := w.create_model("m%d" % i, Vector3i(2, 2, 2))
		m.set_voxel(0, 0, 0, c)
	var bytes := VoxWriter.encode(w)
	assert_true(not bytes.is_empty(), "应能编码")
	if bytes.is_empty():
		return
	var layers := 0
	var pos := 20
	while pos < bytes.size() - 11:
		var id := bytes.slice(pos, pos + 4).get_string_from_ascii()
		var size := bytes.decode_u32(pos + 4)
		var child := bytes.decode_u32(pos + 8)
		if id == "LAYR":
			layers += 1
		pos += 12 + size + child
	assert_eq(layers, 1, "两个顶层模型仍只写 1 个图层")


# 边界

func test_reject_oversize() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	var m := w.create_model("big", Vector3i(VoxSpace.MAX_EDGE + 1, 4, 4))
	m.set_voxel(0, 0, 0, c)
	var report := VoxWriter.check(w)
	assert_true(not report["ok"], "超过 256 应拒绝保存")
	assert_true(VoxWriter.encode(w).is_empty(), "拒绝时不应产出字节")


func test_reject_oblique_rotation() -> void:
	var w := _box_world()
	var m := w.all_models()[0]
	m.local_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(30)), Vector3.ZERO)
	assert_true(not VoxWriter.check(w)["ok"], "斜角旋转应拒绝保存")


func test_empty_world_rejected() -> void:
	assert_true(not VoxWriter.check(QVoxelWorld.create_empty())["ok"], "空世界应拒绝")


## 可见性是**节点属性**，导出写 `nTRN._hidden`（不是 LAYR）：子节点的隐藏必须能往返。
func test_hidden_child_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	var g := w.create_group("g", null)
	var m := w.create_model("m", Vector3i(2, 2, 2), g)
	m.set_voxel(0, 0, 0, c)
	m.visible = false
	_save(VoxWriter.encode(w))
	var back := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	var seen := {}
	for n in back.all_nodes():
		seen[n.node_name] = n.visible
	assert_eq(seen.get("m", true), false, "隐藏的子模型应保持隐藏")
	assert_eq(seen.get("g", false), true, "父组应仍可见")


## 空组（子树里没有任何可写节点）整条跳过：写出去只会得到一个读端会丢弃的空 nGRP。
func test_empty_group_dropped() -> void:
	var w := QVoxelWorld.create_empty()
	var c := w.add_material(Color.RED)
	w.create_group("empty", null)
	var m := w.create_model("m", Vector3i(2, 2, 2), null)
	m.set_voxel(0, 0, 0, c)
	_save(VoxWriter.encode(w))
	var back := VoxAssetWorld.to_world(VoxAsset.from_asset(TMP))
	assert_true(back != null, "应能重建世界")
	if back == null:
		return
	var names := []
	for n in back.all_nodes():
		names.append(n.node_name)
	assert_true(not names.has("empty"), "空组不该出现在往返结果里")
	assert_true(names.has("m"), "有内容的模型必须保留")


## 畸形文件不能让解析器原地打转（实测过一次：坏 size 字段能把编辑器主线程卡死）。
## 这条用例的价值在于"它没卡住"本身 —— 保护若失效，整个测试进程会挂住而不是失败。
func test_malformed_chunk_terminates() -> void:
	var bytes := VoxWriter.encode(_box_world())
	assert_true(bytes.size() > 40, "应有可用的样例文件")
	if bytes.size() <= 40:
		return
	# 8 字节文件头 + 12 字节 MAIN 头 = 20，第一个子块从 20 开始，其 size 字段在 24。
	bytes.encode_u32(24, 0x7FFFFFF0)
	_save(bytes)
	var vox := VoxAsset.from_asset(TMP)
	assert_true(vox != null, "应返回（残缺）结果，而不是卡死或崩溃")

func test_deer_vox_unchanged() -> void:
	var vox := VoxAsset.from_asset("res://demo/deer.vox")
	assert_true(vox != null, "应能解析 demo/deer.vox")
	if vox == null:
		return
	assert_eq(vox.models.size(), 4, "四个模型")
	var total := 0
	var ids := {}
	for m in vox.models:
		total += m.voxels.size()
		for p in m.voxels:
			ids[m.voxels[p]] = true
	assert_eq(total, 1415, "体素总数应与抽取前一致")
	assert_eq(ids.size(), 30, "用到的颜色数应与抽取前一致")
	assert_true(not ids.has(0), "colorIndex 0 不该出现（1..255 才是颜色）")


## 材质表已满（256 项）时，合并必须复用"未被体素引用"的槽，而不是直接拒绝。
## 从 `.vox` 读回来的世界正是这种形状：255 个槽都有颜色，实际只用到几十个。
func test_merge_reuses_free_slots() -> void:
	var a := _box_world()
	while a.materials.size() < 256:
		a.materials.append(VoxelMaterial.air_mate())
	var b := _box_world()
	var added: Array[QVoxelModel] = a.merge_from(b)
	assert_eq(added.size(), 1, "表满时仍应能复用未引用的槽")
	assert_eq(a.materials.size(), 256, "复用而不是继续增长")
	if added.is_empty():
		return
	var ids := added[0].used_materials().keys()
	ids.sort()
	assert_eq(ids.size(), 2, "两个材质都该有归属")
	assert_true(int(ids[0]) >= 3, "应落到空闲槽（1、2 已被 a 占用）")
	# src_ids 排序后按顺序分配，于是 b 的 1/2 恰好落到槽 3/4。
	assert_true(_same_color(a.material_color(3), b.material_color(1)), "第一个材质搬到槽 3")
	assert_true(_same_color(a.material_color(4), b.material_color(2)), "第二个材质搬到槽 4")


# 内部

func _box_world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	var a := w.add_material(Color(0.9, 0.2, 0.2))
	var b := w.add_material(Color(0.2, 0.4, 0.9))
	var m := w.create_model("box", Vector3i(4, 4, 4))
	for x in 4:
		for y in 4:
			for z in 4:
				m.set_voxel(x, y, z, a)
	m.set_voxel(0, 0, 0, b)
	return w


func _save(bytes: PackedByteArray) -> Error:
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	if f == null:
		return ERR_CANT_OPEN
	f.store_buffer(bytes)
	f.close()
	return OK


## 模型内每个体素的世界坐标（排序后，便于整体比较）。
func _voxel_world(w: QVoxelWorld, m: QVoxelModel) -> Array:
	var xf := w.world_transform(m)
	var data := m.read_box(Vector3i.ZERO, m.grid_size)
	var gs := m.grid_size
	var out := []
	var i := 0
	for z in gs.z:
		for y in gs.y:
			for x in gs.x:
				if data[i] > 0:
					var p := xf * Vector3(x, y, z)
					out.append(Vector3i(roundi(p.x), roundi(p.y), roundi(p.z)))
				i += 1
	out.sort()
	return out


func _count(m: QVoxelModel) -> int:
	var n := 0
	for v in m.read_box(Vector3i.ZERO, m.grid_size):
		if v > 0:
			n += 1
	return n


## 颜色经 8 位量化往返，容差按 1/255 的几倍取。
func _same_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 \
			and absf(a.b - b.b) < 0.01 and absf(a.a - b.a) < 0.01
