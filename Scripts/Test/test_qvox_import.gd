extends TestCase

## QVox 导入链路测试：`.qvox` → QVoxAsset → VoxelData / 网格 / 材质。
##
## 钉死的是"QVox 的语义不能被中间表示压缩"这件事。此前 `.qvox` 走 VoxAsset
## （MagicaVoxel 场景图形状的适配器）导致三处**静默**失真，本文件逐条覆盖：
##   ① 多模型只导入第一个（VoxelFrame 的合并分支在 index==0 时短路）；
##   ② NODE 场景图完全不参与 → 各模型的位置/旋转丢失；
##   ③ 体素被摊平成逐体素稀疏字典再重映射回块 → 大模型多趟全量字典操作 + 内存峰值。
## 另有两条守门用例：块级与融合结果一致、材质 MATE 互转幂等。

const TEST_DIR := "user://qvox_import_test"
const SAMPLES_DIR := "res://demo/samples"


func cleanup() -> void:
	_remove_dir(TEST_DIR)


# ----------------------------------------------------------------------------
# ① 多模型 + NODE 摆放：一个都不能丢，位置按 NODE 变换融合
# ----------------------------------------------------------------------------

func test_multi_model_with_node_placement() -> void:
	var path := TEST_DIR + "/two.qvox"
	_write_two_model_qvox(path, true)
	var qvox := QVoxAsset.from_file(path)
	assert_true(qvox != null, "应能解析双模型 .qvox")
	if qvox == null:
		return
	assert_eq(qvox.models.size(), 2, "两个 VOX0 都应在")
	assert_eq(qvox.placements.size(), 2, "NODE 里两个 model 节点都应在")
	assert_false(qvox.is_block_importable(), "带位移的摆放必须走融合路径")

	var data := VoxelData.from_qvox(qvox)
	assert_true(data != null, "应能构造 VoxelData")
	if data == null:
		return
	# 模型 0：块 (0,0,0) 内 (1,1,1) → 世界 (1,1,1)
	# 模型 1：块 (5,0,0) 内 (1,1,1) → 世界 (161,1,1)，再叠加 NODE 位移 (0,64,0)
	assert_eq(data.get_voxel_count(), 2, "两模型各 1 个体素（此前只剩第一个模型）")
	assert_eq(data.get_all_chunk_keys().size(), 2, "两个模型应落在两个不同 chunk")
	assert_true(data.has_voxel(Vector3i(1, 1, 1)), "模型 0 的体素应在原处")
	assert_true(data.has_voxel(Vector3i(161, 65, 1)), "模型 1 的体素应叠加 NODE 位移")


# ----------------------------------------------------------------------------
# ② 无 NODE（恒等摆放）= 块级直连：与逐体素融合结果必须一致
# ----------------------------------------------------------------------------

func test_block_import_matches_fused() -> void:
	var path := TEST_DIR + "/plain.qvox"
	_write_two_model_qvox(path, false)
	var qvox := QVoxAsset.from_file(path)
	assert_true(qvox.is_block_importable(), "无 NODE → 应可块级直连（零逐体素展开）")
	if not qvox.is_block_importable():
		return
	var via_blocks := VoxelData.from_qvox(qvox)
	# fused_voxels() 是"有变换时"的参考实现：两条路必须给出同一个世界
	assert_eq(via_blocks.get_voxels_dict_snapshot(), qvox.fused_voxels(),
			"块级直连与逐体素融合必须逐体素一致")
	assert_eq(via_blocks.grid_size, qvox.grid_size(), "grid_size 应来自体素包围盒")
	assert_eq(via_blocks.get_voxel_count(), 2, "体素数应正确（块级安装用原生 count 统计）")


# ----------------------------------------------------------------------------
# ③ 网格：所有模型都要出现在同一个 mesh 里
# ----------------------------------------------------------------------------

func test_mesh_covers_all_models() -> void:
	var path := TEST_DIR + "/mesh_two.qvox"
	_write_two_model_qvox(path, false)
	var qvox := QVoxAsset.from_file(path)
	var opts := {}
	for o in VoxelMeshImporter.new()._get_import_options("", false):
		opts[o["name"]] = o["default_value"]
	var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh_from_qvox(qvox, opts, path)
	assert_true(mesh != null, "应能为 .qvox 生成网格")
	if mesh == null:
		return
	var verts := 0
	for i in mesh.get_surface_count():
		verts += mesh.surface_get_array_len(i)
	# 孤立体素 = 6 个面 × 4 顶点 = 24；两个模型共 48（只导入一个模型会是 24）
	assert_true(verts >= 48, "两个模型的体素都应出现在网格里（实得 %d 顶点）" % verts)


# ----------------------------------------------------------------------------
# ④ 资源载荷：块表往返（单一格式，无旧版兼容路径）
# ----------------------------------------------------------------------------

func test_resource_payload_roundtrip() -> void:
	var d := _make_data()
	d.set_voxel(Vector3i(1, 2, 3), 1, false)
	d.set_voxel(Vector3i(40, 0, 0), 1, false)   # 第二个 chunk：验证多块
	var payload: Variant = d.get("voxel_data_payload")
	assert_true(payload is String and not (payload as String).is_empty(), "应产出载荷字符串")

	var r := VoxelData.new()
	r.set("voxel_data_payload", payload)
	assert_eq(r.get_voxels_dict_snapshot(), d.get_voxels_dict_snapshot(), "载荷往返应逐体素一致")
	assert_eq(r.get_all_chunk_keys().size(), 2, "两个 chunk 都应恢复")
	assert_eq(r.grid_size, d.grid_size, "grid_size 应随载荷恢复")

	# 版本不符 → 明确拒绝（报错 + 空载荷），而不是按当前格式猜着读
	var bad := VoxelData.new()
	bad.set("voxel_data_payload", VoxelPayloadCodec.encode({"v": VoxelPayloadCodec.VERSION + 1, "blocks": {}}))
	assert_eq(bad.get_voxel_count(), 0, "版本不符的载荷应被拒绝")


# ----------------------------------------------------------------------------
# ⑤ 材质：MATE ↔ VoxelMaterial 的唯一转换必须幂等且保住物理量
# ----------------------------------------------------------------------------

func test_material_mate_roundtrip() -> void:
	var entry := {
		"rgba": 0x804020FF, "metal": 255, "rough": 128,
		"hardness": 30, "mass": 233, "e_r": 200, "e_g": 10, "e_b": 5,
	}
	var mat := VoxelMaterial.from_mate(entry, 7)
	assert_eq(mat.id, 7, "id 应来自条目下标")
	assert_eq(mat.hardness, 30.0, "hardness 直存整数")
	assert_eq(mat.mass, 233.0, "mass 直存整数")
	assert_true(absf(mat.metal - 1.0) < 0.01, "metal 0-255 → 0-1")
	assert_true(absf(mat.rough - 128.0 / 255.0) < 0.01, "rough 0-255 → 0-1")
	assert_true(absf(mat.emission - 200.0 / 255.0) < 0.01, "emission 取三通道最大")

	var back := VoxelMaterial.to_mate(mat)
	assert_eq(back["hardness"], 30, "往返 hardness")
	assert_eq(back["mass"], 233, "往返 mass")
	assert_eq(back["metal"], 255, "往返 metal")
	# 颜色经 0-1 浮点量化，允许 ±1/255 的误差
	assert_true(absi(int((back["rgba"] >> 24) & 0xFF) - 0x80) <= 1, "往返 R 通道")
	assert_true(absi(int(back["rgba"] & 0xFF) - 0xFF) <= 1, "往返 alpha")
	# 幂等：已是 MATE 形状的 Dictionary 再转一次必须不变（写盘反复 flush 依赖它）
	assert_eq(VoxelMaterial.to_mate(back), back, "MATE 归一化必须幂等")
	assert_eq(VoxelMaterial.to_mate(null), VoxelMaterial.air_mate(), "null → 空气条目")


# ----------------------------------------------------------------------------
# ⑥ 仓库样例：所有样例都应能导入出非空体素
# ----------------------------------------------------------------------------

func test_samples_import_without_loss() -> void:
	var files := _list_qvox(SAMPLES_DIR)
	assert_true(not files.is_empty(), "%s 下应至少有一个 .qvox 样例" % SAMPLES_DIR)
	for path in files:
		var qvox := QVoxAsset.from_file(str(path))
		assert_true(qvox != null, "%s 应能解析" % path.get_file())
		if qvox == null:
			continue
		assert_true(not qvox.is_empty(), "%s 应含非空块" % path.get_file())
		var data := VoxelData.from_qvox(qvox)
		assert_true(data.get_voxel_count() > 0, "%s 应导入出体素" % path.get_file())


# ----------------------------------------------------------------------------
# ⑦ NODE 变换：通用四元数（而不是 .vox 的 0–23 朝向索引）
# ----------------------------------------------------------------------------

## 90° 绕 Y 在浮点里恰好落在整数上：体素 (1,1,1) → (1,1,-1)。
## 这条用例钉住旋转的**表示与解码**：若哪天有人把 `.vox` 的 0–23 索引搬回 QVox，
## 这里会立刻变成"体素还在原地"而失败。
func test_node_quaternion_rotation_applied() -> void:
	var path := TEST_DIR + "/rot.qvox"
	var q := Quaternion(Vector3.UP, PI / 2.0)
	_write_single_voxel_qvox(path, {"r": [q.x, q.y, q.z, q.w]})
	var qvox := QVoxAsset.from_file(path)
	assert_true(qvox != null, "应能解析带旋转的 .qvox")
	if qvox == null:
		return
	assert_false(qvox.is_block_importable(), "带旋转的摆放必须走逐体素融合路径")
	var data := VoxelData.from_qvox(qvox)
	assert_eq(data.get_voxel_count(), 1, "旋转后仍应恰好一个体素")
	assert_true(data.has_voxel(Vector3i(1, 1, -1)), "90° 绕 Y：(1,1,1) → (1,1,-1)")
	assert_false(data.has_voxel(Vector3i(1, 1, 1)), "原位置不应残留")


## 缩放与平移同属 `transform`，且三个字段都可缺省（未写的 `r` 即恒等）。
func test_node_scale_and_translation_applied() -> void:
	var path := TEST_DIR + "/scale.qvox"
	_write_single_voxel_qvox(path, {"t": [10, 0, 0], "s": [2, 2, 2]})
	var qvox := QVoxAsset.from_file(path)
	assert_true(qvox != null, "应能解析带缩放的 .qvox")
	if qvox == null:
		return
	var data := VoxelData.from_qvox(qvox)
	assert_true(data.has_voxel(Vector3i(12, 2, 2)), "先缩放 2× 再平移 (10,0,0)：(1,1,1) → (12,2,2)")


# ----------------------------------------------------------------------------
# ⑧ NODE.animations 的帧补丁必须真的被消费（此前只被解析/校验，没有任何读取方）
# ----------------------------------------------------------------------------

## `frame_index` 选第几帧，节点摆放就取那一帧的覆盖值。
## 守的是"帧补丁不是死数据"：若哪天有人删掉 QVoxAsset._frame_patches 的调用，
## 这里会立刻变成"两帧位置一样"而失败。
func test_animation_frame_patch_applied() -> void:
	var path := TEST_DIR + "/anim.qvox"
	# 本 helper 只有一个节点 → 帧补丁的键是下标 0。
	# 第 0 帧覆盖 t=(0,0,0)，第 1 帧覆盖 t=(0,64,0)。
	_write_single_voxel_qvox(path, {},
			[{"t": 0, "0": {"t": [0, 0, 0]}}, {"t": 100, "0": {"t": [0, 64, 0]}}])
	var f0 := QVoxAsset.from_file(path, 0)
	var f1 := QVoxAsset.from_file(path, 1)
	assert_true(f0 != null and f1 != null, "应能解析带动画的 .qvox")
	if f0 == null or f1 == null:
		return
	assert_eq(f0.placements.size(), 1, "每帧都应有 1 条摆放")
	assert_eq(f1.placements.size(), 1, "每帧都应有 1 条摆放")
	var d0 := VoxelData.from_qvox(f0)
	var d1 := VoxelData.from_qvox(f1)
	# 体素位于块 (0,0,0) 的局部 (1,1,1)
	assert_true(d0.has_voxel(Vector3i(1, 1, 1)), "第 0 帧：模型应落在原点")
	assert_true(d1.has_voxel(Vector3i(1, 65, 1)), "第 1 帧：帧补丁应把模型抬高 64")
	assert_false(d1.has_voxel(Vector3i(1, 1, 1)), "第 1 帧：原位置不应残留")
	# 越界帧号安全退化：不崩、按"无补丁"处理（等价静态摆放）
	var out := QVoxAsset.from_file(path, 9)
	assert_true(out != null, "越界 frame_index 不应导致失败")
	if out != null:
		assert_true(VoxelData.from_qvox(out).has_voxel(Vector3i(1, 1, 1)),
				"越界 frame_index 应退化为无补丁")


# ----------------------------------------------------------------------------
# ⑨ 原点统一：`.vox → mesh` 与 `.vox → data` 必须摆在同一个位置（同 scale）
# ----------------------------------------------------------------------------

## 守两件事：
##   ① 同一个模型经两条导入路径进场景，必须落在同一位置——mesh 的世界 AABB 与 data 的
##      `(体素AABB + center_offset) × scale` 在**三种原点模式下**都必须重合；
##   ② 导入器默认值必须是 `WORLD_ORIGIN`（不动几何）。它等于本插件网格导入一直以来的行为，
##      改成别的会让已有资产升级后集体挪位。
##
## 形状固定用 cube：sphere 是另一种几何（每体素一颗球，AABB 本就更大），与原点无关。
func test_mesh_and_data_origin_agree() -> void:
	var src := "res://demo/deer.vox"
	if not ResourceLoader.exists(src):
		return   # 纯净检出可能没有素材，不因缺资源判失败
	var vox := VoxAsset.from_asset(src)
	assert_true(vox != null, "应能解析 %s" % src)
	if vox == null:
		return

	# 选项取导入器默认值（scale=0.1、origin=world_origin）
	var opts := {}
	for o in VoxelMeshImporter.new()._get_import_options("", false):
		opts[o["name"]] = o["default_value"]
	opts[VoxelMeshImporter.shape] = VoxelMeshImporter.Shape.cube
	assert_eq(int(opts[VoxelMeshImporter.origin]), VoxelData.OriginMode.WORLD_ORIGIN,
			"导入器默认原点应为 WORLD_ORIGIN（不改动几何），否则已有资产会集体挪位")
	var scale: float = opts[VoxelMeshImporter.scale]

	for mode in [VoxelData.OriginMode.WORLD_ORIGIN, VoxelData.OriginMode.BOTTOM_CENTER,
			VoxelData.OriginMode.CONTENT_CENTER]:
		opts[VoxelMeshImporter.origin] = mode
		var mesh: ArrayMesh = VoxelMeshGenerator.generate_mesh(vox, opts, src)
		assert_true(mesh != null, "应为 deer.vox 生成网格（mode=%d）" % mode)
		if mesh == null:
			return
		var data := VoxelData.from_voxel_data(vox, 0, mode)
		var maabb := mesh.get_aabb()
		var db := data.get_voxels_aabb()
		var dmin := (db.position + data.center_offset) * scale
		var dsize := db.size * scale
		var delta := (maabb.position - dmin).length() + (maabb.size - dsize).length()
		assert_true(delta < 0.01,
				"mode=%d 下 mesh 与 data 的原点/尺寸必须一致（Δ=%.4f；mesh=%s data=%s）"
				% [mode, delta, str(maabb), str(AABB(dmin, dsize))])
		if mode == VoxelData.OriginMode.BOTTOM_CENTER:
			assert_true(absf(maabb.position.y) < 0.01,
					"显式选 bottom_center 时底面应落在 y=0（实得 %.3f）" % maabb.position.y)


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 最小可用 QVox 文档骨架：HEAD（单通道 material）+ 材质表（条目 0 空气 + 1 号实体）。
## 各用例只在其上挂自己的 models / node。
func _new_doc() -> QVoxFile.QVoxDocument:
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": VoxelChunk.CHUNK_SIZE,
		"up_axis": "y",
	}
	doc.materials = [VoxelMaterial.air_mate(),
			VoxelMaterial.to_mate(_solid_material(Color(0.2, 0.6, 0.9)))]
	return doc


## 一个块内只有一个非空体素（局部坐标 (1,1,1)，材质 1）的 32³ 缓冲。
func _one_voxel_block() -> PackedInt32Array:
	var b := PackedInt32Array()
	b.resize(VoxelChunk.CHUNK_VOLUME)
	b[VoxelChunk.buf_index(1, 1, 1)] = 1
	return b


## 造一个"单模型单体素"的 .qvox：块 (0,0,0) 内的 (1,1,1) 有一个体素，
## NODE 里一个 model 节点带给定的 transform（空字典 = 不写 NODE 块，即恒等摆放）。
## frames 非空时写入一段动画（帧补丁以**节点下标**为键；本 helper 只有一个节点 → 下标 0）。
## 变换相关的用例共用它，使"看的是变换，而不是文档构造"。
func _write_single_voxel_qvox(path: String, transform: Dictionary, frames: Array = []) -> void:
	var doc := _new_doc()
	doc.models = {0: {Vector3i(0, 0, 0): _one_voxel_block()}}
	if not transform.is_empty() or not frames.is_empty():
		doc.node = {"nodes": [{"name": "n", "kind": "model", "model_id": 0,
				"transform": transform}]}
		if not frames.is_empty():
			doc.node["animations"] = [{"name": "a", "loop": false, "frames": frames}]
	_write_bytes(path, QVoxFile.serialize(doc))


## 造一个"双模型 + 可选 NODE 摆放"的 .qvox。
## 模型 0：块 (0,0,0) 内 (1,1,1)；模型 1：块 (5,0,0) 内 (1,1,1)。
## with_node 时给出 NODE：模型 1 额外位移 (0,64,0)，用于验证场景图不再被丢弃。
func _write_two_model_qvox(path: String, with_node: bool) -> void:
	var doc := _new_doc()
	doc.models = {
		0: {Vector3i(0, 0, 0): _one_voxel_block()},
		1: {Vector3i(5, 0, 0): _one_voxel_block()},
	}
	if with_node:
		doc.node = {"nodes": [
			{"name": "root", "kind": "group", "children": [1, 2]},
			{"name": "body", "kind": "model", "model_id": 0,
					"transform": {"t": [0, 0, 0], "r": [0, 0, 0, 1], "s": [1, 1, 1]}},
			{"name": "wheel", "kind": "model", "model_id": 1,
					"transform": {"t": [0, 64, 0], "r": [0, 0, 0, 1], "s": [1, 1, 1]}},
		]}
	_write_bytes(path, QVoxFile.serialize(doc))


func _solid_material(color: Color) -> VoxelMaterial:
	var mat := VoxelMaterial.new()
	mat.id = 1
	mat.color = color
	mat.rough = 0.8
	mat.hardness = 6.0
	mat.mass = 2.0
	return mat


func _make_data() -> VoxelData:
	var mats: Array[VoxelMaterial] = []
	mats.resize(2)
	mats[1] = _solid_material(Color(0.3, 0.7, 0.2))
	var d := VoxelData.new()
	d.materials = mats
	return d


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _list_qvox(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".qvox"):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


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
