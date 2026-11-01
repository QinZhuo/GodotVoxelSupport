extends TestCase

## 外部模型体素化的契约：三角网格 → 密集体积 → `QVoxelWorld`。
## 用**合成几何**钉住每一步（不依赖任何资产，编辑器进程即可跑）：
##   · 封闭立方体 → 内部填实（全实心，不是空壳）；
##   · 开放平面 → 外部泛洪漏进去 → 自然退化为单层壳（不封闭时的正确降级）；
##   · 比例保持（最长边 = 分辨率，其余轴按比例）；
##   · 开放模型 + 帧序列 → 体素帧动画，且各帧共用同一套栅格与调色板；
##   · OBJ 解析（多边形扇形三角化）。

const TMP_OBJ := "user://mesh_voxelize_tri.obj"


func cleanup() -> void:
	if FileAccess.file_exists(TMP_OBJ):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_OBJ))


# 内核

func test_native_available() -> void:
	assert_true(NativeLoader.is_available(), "原生库应可用（含 voxelize_mesh）")


func test_solid_cube_fills_interior() -> void:
	var scene := _scene([_cube_part()])
	var rast := MeshVoxelizer.frame_grid(scene, 8)
	assert_eq(rast["grid"], Vector3i(8, 8, 8), "1³ 立方体在 8 分辨率下应正好 8³")
	var res := MeshVoxelizer.voxelize_frame(scene, 0, rast)
	assert_true(not res.is_empty(), "应产出体积")
	assert_eq(int(res["count"]), 512, "封闭立方体内部应被填实（8³ 全满）")


func test_open_plane_degrades_to_shell() -> void:
	var scene := _scene([_quad_part()])
	var rast := MeshVoxelizer.frame_grid(scene, 4)
	assert_eq(rast["grid"], Vector3i(4, 4, 1), "平面在 Z 上只有 1 层")
	var res := MeshVoxelizer.voxelize_frame(scene, 0, rast)
	assert_eq(int(res["count"]), 16, "开放平面只应得到表面那一层（4×4）")


func test_grid_keeps_aspect() -> void:
	var scene := _scene([_box_part(Vector3(2, 1, 1))])
	var rast := MeshVoxelizer.frame_grid(scene, 8)
	assert_eq(rast["grid"], Vector3i(8, 4, 4), "最长边 = 分辨率，其余轴按比例")


# 世界侧

func test_world_palette_and_materials() -> void:
	var w: QVoxelWorld = await MeshVoxelWorld.to_world(_scene([_cube_part()]), 4)
	assert_true(w != null, "应能建出世界")
	if w == null:
		return
	assert_eq(w.materials.size(), 2, "一个颜色 + 空气占位")
	assert_eq(int(w.materials[1]["r"]), 255, "材质 1 应是纯红")
	assert_eq(int(w.materials[1]["g"]), 0, "红材质的绿通道为 0")
	var m := w.all_models()[0]
	assert_eq(m.grid_size, Vector3i(4, 4, 4), "模型尺寸即栅格尺寸")
	assert_true(m.source_blocks().size() > 0, "体素应写进块表")


func test_frames_become_voxel_animation() -> void:
	var scene := _scene([_cube_part()])
	var moved := _scene([_cube_part(Vector3(2, 0, 0))])
	(scene["frames"] as Array).append((moved["frames"] as Array)[0])
	var w: QVoxelWorld = await MeshVoxelWorld.to_world(scene, 4)
	assert_true(w != null, "多帧也应能建世界")
	if w == null:
		return
	var m := w.all_models()[0]
	assert_true(m.is_animated(), "多帧应建成体素帧动画")
	assert_eq(m.frame_count(), 2, "两帧就是两帧")
	assert_true(not m.frames[0].is_empty() and not m.frames[1].is_empty(), "两帧都应有内容")


## 追加导入：并进现有世界时材质 ID 整体平移，体素仍指向同一个颜色。
func test_merge_from_shifts_materials() -> void:
	var dst: QVoxelWorld = await MeshVoxelWorld.to_world(_scene([_cube_part()]), 4)
	var src: QVoxelWorld = await MeshVoxelWorld.to_world(_scene([_cube_part()]), 4)
	var base := dst.materials.size()   # src 的材质 1 平移后恰好落在 base
	var added: Array[QVoxelModel] = dst.merge_from(src)
	assert_eq(added.size(), 1, "并入一个模型")
	assert_eq(dst.materials.size(), base + src.materials.size() - 1, "材质按需追加（空气共用）")
	var m := added[0]
	assert_true(m.used_materials().has(base), "体素应指向平移后的材质 ID")
	assert_eq(dst.material_color(base), Color.RED, "平移后仍是同一颜色")
	assert_eq(_filled(m), 64, "并入的模型内容完整（4³ 实心）")


## 对话框过滤项由 MeshAccess 生成：格式事实只有一处。
func test_filter_specs_cover_extensions() -> void:
	var specs := MeshAccess.filter_specs()
	assert_eq(specs.size(), MeshAccess.EXTENSIONS.size(), "每个扩展名一条过滤")
	assert_eq(String(specs[0][0]), "*.glb", "首个过滤器匹配 .glb")
	assert_true(MeshAccess.describe().contains("obj"), "提示文案应列出全部格式")


# OBJ

func test_obj_parses_quad() -> void:
	var f := FileAccess.open(TMP_OBJ, FileAccess.WRITE)
	assert_true(f != null, "应能写临时 OBJ")
	if f == null:
		return
	f.store_string("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nf 1/1 2/2 3/3 4/4\n")
	f.close()
	var scene: Dictionary = await MeshAccess.load_scene(TMP_OBJ)
	assert_true(not scene.is_empty(), "应能解析 OBJ")
	if scene.is_empty():
		return
	var parts: Array = (scene["frames"] as Array)[0]["parts"]
	assert_eq(parts.size(), 1, "一个材质一组零件")
	assert_eq((parts[0]["verts"] as PackedVector3Array).size(), 4, "四个顶点")
	assert_eq((parts[0]["indices"] as PackedInt32Array).size(), 6, "四边形扇形三角化 → 6 个索引")


func test_obj_is_voxelizable() -> void:
	var f := FileAccess.open(TMP_OBJ, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
	f.close()
	var scene: Dictionary = await MeshAccess.load_scene(TMP_OBJ)
	var w: QVoxelWorld = await MeshVoxelWorld.to_world(scene, 4)
	assert_true(w != null, "OBJ → 体素世界应走通")
	if w != null:
		assert_eq(w.all_models()[0].grid_size, Vector3i(4, 4, 1), "平面 OBJ 只有一层")


# 合成几何

func _scene(parts: Array) -> Dictionary:
	return {
		"name": "t",
		"frames": [{"parts": parts, "time": 0.0}],
		"slots": [{"tex": PackedByteArray(), "size": Vector2i.ZERO, "color": Color.RED}],
	}


## 单位立方体（8 顶点 / 12 三角 / 红槽）—— 顶点位 = (i&1, (i>>1)&1, (i>>2)&1)。
func _cube_part(offset := Vector3.ZERO) -> Dictionary:
	var v := PackedVector3Array()
	for i in 8:
		v.append(Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) + offset)
	var idx := PackedInt32Array([
		0, 1, 3, 0, 3, 2,   # z=0
		4, 5, 7, 4, 7, 6,   # z=1
		0, 1, 5, 0, 5, 4,   # y=0
		2, 3, 7, 2, 7, 6,   # y=1
		0, 2, 6, 0, 6, 4,   # x=0
		1, 3, 7, 1, 7, 5,   # x=1
	])
	return {"verts": v, "indices": idx, "uvs": PackedVector2Array(),
			"colors": PackedColorArray(), "slot": 0}


## z=0 平面上的一米见方（开放模型）。
func _quad_part() -> Dictionary:
	return {
		"verts": PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0),
				Vector3(1, 1, 0), Vector3(0, 1, 0)]),
		"indices": PackedInt32Array([0, 1, 2, 0, 2, 3]),
		"uvs": PackedVector2Array(),
		"colors": PackedColorArray(),
		"slot": 0,
	}


## 模型里非空体素数（一次 read_box，比逐格 get_voxel 快一个量级）。
func _filled(m: QVoxelModel) -> int:
	var n := 0
	for v in m.read_box(Vector3i.ZERO, m.grid_size):
		if v > 0:
			n += 1
	return n


## 任意尺寸的轴对齐长方体（封闭）。
func _box_part(size: Vector3) -> Dictionary:
	var part := _cube_part()
	var v := PackedVector3Array()
	for p in part["verts"]:
		v.append(Vector3(p.x * size.x, p.y * size.y, p.z * size.z))
	part["verts"] = v
	return part
