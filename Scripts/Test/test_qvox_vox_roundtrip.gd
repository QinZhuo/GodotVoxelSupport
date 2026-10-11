extends TestCase

## `.vox` ⇄ `.qvx` 数据互转实测：各种情况下两种格式能否正确互相转化。
## 判据：把两侧都化成"世界体素坐标集合"的**签名**（非空体素数 + 坐标滚动哈希）再比对，
## 避免为上百万元素建大字典（teapot 样例会超时）。覆盖：
##   ① demo 真实样例：.vox → 世界 → .qvx → 世界；
##   ② demo 真实样例：.vox → 世界 → .vox（结构保留）→ 世界；
##   ③ 合成多模型 / 不同尺寸 / 偏移 / 旋转 / 组 / 隐藏层；
##   ④ 材质颜色往返；
##   ⑤ FRAM 帧动画经 .qvx 往返。

const SAMPLES_DIR := "res://demo"
const TMP_DIR := "user://qvx_vox_rt"
## 超大样例（teapot2 5.6MB / 1.4M 体素）往返会拖爆测试时长，跳过；其几何一致性由
## test_qvox_vox_bridge 的 parity 用例覆盖。
const MAX_BYTES := 2_000_000


func cleanup() -> void:
	_remove_dir(TMP_DIR)


# ① .vox → 世界 → .qvx → 世界

func test_vox_to_qvx_roundtrip_samples() -> void:
	for path in _list_vox(SAMPLES_DIR):
		var name := str(path).get_file()
		var vox := VoxAsset.from_asset(str(path))
		assert_true(vox != null, "应能读入 %s" % name)
		if vox == null:
			continue
		var a := _world_sig(vox.to_world())
		var w := vox.to_world()
		var rep := QVoxelFile.QVoxelReport.new()
		var doc := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true, rep, true)
		assert_true(doc != null, "%s：.qvx 应能解析回去（%s）" % [name, rep.summary()])
		if doc == null:
			continue
		var b := _world_sig(QVoxelWorld.from_document(doc))
		assert_eq(b, a, "%s：.vox→.qvx 世界体素签名一致" % name)


# ② .vox → 世界 → .vox（结构保留）→ 世界

func test_vox_to_vox_roundtrip_samples() -> void:
	_ensure_dir(TMP_DIR)
	for path in _list_vox(SAMPLES_DIR):
		var name := str(path).get_file()
		var vox := VoxAsset.from_asset(str(path))
		if vox == null:
			continue
		var a := _world_sig(vox.to_world())
		var asset := VoxAsset.from_world(vox.to_world())
		var out := TMP_DIR + "/" + name
		assert_eq(VoxAccess.Save(out, asset), OK, "%s：应能写出" % name)
		var back := VoxAsset.from_asset(out)
		assert_true(back != null, "%s：应能读回" % name)
		if back == null:
			continue
		var b := _world_sig(back.to_world())
		assert_eq(b, a, "%s：.vox→.vox 世界体素签名一致" % name)


# ③ 合成：多模型 / 不同尺寸 / 偏移 / 旋转 / 组 / 隐藏层

func test_synthetic_multimodel_roundtrip() -> void:
	_ensure_dir(TMP_DIR)
	var w := QVoxelWorld.create_empty()
	var red := w.add_material(Color.RED)
	var grp := w.create_group("layerA")
	var a := w.create_model("A", Vector3i(8, 6, 4), grp)
	a.set_voxel(1, 1, 1, red)
	a.set_voxel(6, 0, 3, red)
	var b := w.create_model("B", Vector3i(4, 4, 4), grp)
	b.set_voxel(0, 0, 0, red)
	b.set_voxel(3, 3, 3, red)
	b.offset = Vector3i(20, 5, -3)
	var c := w.create_model("C", Vector3i(5, 3, 2))
	c.set_voxel(4, 0, 0, red)
	c.set_voxel(0, 2, 1, red)
	c.local_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(-6, 0, 4))
	var hg := w.create_group("hidden")
	hg.visible = false
	var d := w.create_model("D", Vector3i(3, 3, 3), hg)
	d.set_voxel(1, 1, 1, red)

	var a_sig := _world_sig(w)

	var doc := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true,
			QVoxelFile.QVoxelReport.new(), true)
	assert_true(doc != null, ".qvx 应能解析回去")
	assert_eq(_world_sig(QVoxelWorld.from_document(doc)), a_sig, ".qvx 往返世界体素签名一致")

	var asset := VoxAsset.from_world(w)
	assert_eq(asset.models.size(), 4, "结构保留：每个模型一块")
	var out := TMP_DIR + "/synth.vox"
	assert_eq(VoxAccess.Save(out, asset), OK, "应能写出 .vox")
	var back := VoxAsset.from_asset(out)
	assert_true(back != null, "应能读回 .vox")
	if back == null:
		return
	assert_eq(_world_sig(back.to_world()), a_sig, ".vox 往返世界体素签名一致")


# ④ 材质颜色往返

func test_material_color_roundtrip() -> void:
	_ensure_dir(TMP_DIR)
	var w := QVoxelWorld.create_empty()
	w.add_material(Color(0.87, 0.27, 0.25))
	w.add_material(Color(0.26, 0.64, 0.94))
	var m := w.create_model("m", Vector3i(4, 4, 4))
	m.set_voxel(0, 0, 0, 1)
	m.set_voxel(3, 3, 3, 2)
	var out := TMP_DIR + "/mat.vox"
	assert_eq(VoxAccess.Save(out, VoxAsset.from_world(w)), OK, "应能写出")
	var back := VoxAsset.from_asset(out)
	if back == null:
		return
	var w2 := back.to_world()
	assert_eq(w2.material_color(1), w.material_color(1), "材质 1 颜色往返一致")
	assert_eq(w2.material_color(2), w.material_color(2), "材质 2 颜色往返一致")


# ⑤ FRAM 帧动画经 .qvx 往返

## 体素动画：世界（FRAM，多帧）→ .vox（nSHP 多帧）→ 世界（FRAM），帧数/每帧体素一致。
func test_world_animation_to_vox_roundtrip() -> void:
	_ensure_dir(TMP_DIR)
	var vox := VoxAsset.from_asset("res://demo/deer.vox")
	if vox == null:
		return
	var w := vox.to_world()
	var out := TMP_DIR + "/anim.vox"
	assert_eq(VoxAccess.Save(out, VoxAsset.from_world(w)), OK, "应能写出 .vox")
	var back := VoxAsset.from_asset(out)
	assert_true(back != null, "应能读回")
	if back == null:
		return
	var w2 := back.to_world()
	var anim: QVoxelModel = null
	for m in w2.all_models():
		if m.is_animated():
			anim = m
	assert_true(anim != null, "体素动画应经 .vox 保留")
	if anim == null:
		return
	assert_eq(anim.frame_count(), 4, "4 帧")
	for k in anim.frame_count():
		anim.active_frame = k
		var got := QVoxelEvalEngine.evaluate_world(w2, QVoxelEvalContext.new()).solid_count()
		var want := vox.get_voxels(k).size()
		assert_eq(got, want, "第 %d 帧体素数应与原始 .vox 一致" % k)

func test_vox_voxel_animation_import() -> void:
	var vox := VoxAsset.from_asset("res://demo/deer.vox")
	assert_true(vox != null, "应能读入 deer.vox")
	if vox == null:
		return
	var w := vox.to_world()
	var anim: QVoxelModel = null
	for m in w.all_models():
		if m.is_animated():
			anim = m
	assert_true(anim != null, "deer 的 nSHP 多帧应导入成动画模型（FRAM）")
	if anim == null:
		return
	assert_eq(anim.frame_count(), 4, "deer 应有 4 帧")
	for k in anim.frame_count():
		anim.active_frame = k
		var got := QVoxelEvalEngine.evaluate_world(w, QVoxelEvalContext.new()).solid_count()
		var want := vox.get_voxels(k).size()
		assert_eq(got, want, "deer 第 %d 帧体素数应与 .vox 取景一致" % k)

func test_fram_qvx_roundtrip() -> void:
	var w := QVoxelWorld.create_empty()
	var red := w.add_material(Color.RED)
	var m := w.create_model("anim", Vector3i(4, 4, 4))
	m.make_animated()
	m.set_frame_voxel(0, 0, 0, 0, red)
	var f1 := QVoxelFrame.new()
	m.add_frame(f1, 1)
	m.set_frame_voxel(1, 3, 3, 3, red)
	m.anim_fps = 8
	m.anim_loop = false
	var doc := QVoxelFile.parse(QVoxelFile.serialize(w.to_document()), true,
			QVoxelFile.QVoxelReport.new(), true)
	assert_true(doc != null, ".qvx 应能解析回去")
	var m2 := QVoxelWorld.from_document(doc).all_models()[0]
	assert_true(m2.is_animated(), "动画存活")
	assert_eq(m2.frame_count(), 2, "两帧")
	assert_eq(m2.get_frame_block(1, Vector3i.ZERO)[QVoxelSpec.index_in_block(Vector3i(3, 3, 3), m2.block_size)], red, "第 1 帧体素")
	assert_eq(m2.anim_fps, 8, "帧率")
	assert_false(m2.anim_loop, "循环标志")


# ⑥ 无 NODE 的纯 VXEL `.qvx`（如 demo/samples）也能导入出模型

func test_qvx_without_node_imports_models() -> void:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = {
		"qvox": QVoxelSpec.VERSION,
		"channels": [{"name": QVoxelSpec.DOMINANT_CHANNEL, "bpp": QVoxelSpec.CHANNEL_BPP}],
		"block_size": 32, "up_axis": "y",
	}
	doc.materials = [
		{"rgba": 0, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0},
		{"rgba": 0xFF0000FF, "metal": 0, "rough": 0, "hardness": 0, "mass": 0, "e_r": 0, "e_g": 0, "e_b": 0},
	]
	var buf := PackedInt32Array()
	buf.resize(32 * 32 * 32)
	buf[0] = 1
	doc.models = {0: {Vector3i.ZERO: buf}}
	var w := QVoxelWorld.from_document(doc)
	assert_eq(w.all_models().size(), 1, "无 NODE 的纯 VXEL 文件应导入出模型")
	if w.all_models().size() == 1:
		assert_eq(w.all_models()[0].model_id, 0)
		assert_eq(w.all_models()[0].count_solid(), 1)


# 夹具

## 世界求值的"体素集合签名"：非空体素数 + 坐标滚动哈希（内存恒定，避免上百万元素的字典）。
func _world_sig(world: QVoxelWorld) -> Dictionary:
	var res := QVoxelEvalEngine.evaluate_world(world, QVoxelEvalContext.new())
	var gs := res.grid_size
	var o := res.origin
	var count := 0
	var h := 0
	var i := 0
	for z in gs.z:
		for y in gs.y:
			for x in gs.x:
				if res.volume[i] > 0:
					count += 1
					h = (h * 1099511628211 + hash(Vector3i(o.x + x, o.y + y, o.z + z))) & 0x7FFFFFFFFFFFFFFF
				i += 1
	return {"count": count, "hash": h}


func _list_vox(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".vox"):
			var p := dir_path.path_join(name)
			if _file_size(p) <= MAX_BYTES:
				out.append(p)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


func _ensure_dir(dir_path: String) -> void:
	var abs := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _remove_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path.path_join(name)))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
