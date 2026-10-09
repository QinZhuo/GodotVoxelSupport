extends Node3D

## QVX ⇄ Mesh 对比验证场 —— 以「.vox 直接导入成 mesh」为正确基准。
##
## 每个模型渲染**两份**，左右紧邻：
##   左：MESH 路径（正确基准）
##        .vox → VoxAccess.voxel → VoxelMeshGenerator.generate_mesh()
##        → ArrayMesh + VoxelMeshGenerator.generate_textured_materials_runtime(materials)
##        这条路径就是 demo.tscn 里 deer.vox 作为 ArrayMesh 使用的路径，
##        用户确认「导入 mesh 显示的 mesh 是正确的」。
##   右：QVX 路径（待验证）
##        .vox → QVoxelSource → .qvx (QVoxelStream.save_chunk) → 回读 → VoxelRenderer
##
## 两侧都用同一套 256×1 材质纹理（VoxelMaterial.albedo_color 采样），
## 因此**颜色差异只能来自 UV 或网格几何**。
##
## 关键已知差异（本场景要暴露的）：
##   MESH 路径 UV: (u, 0.5)          —— GDScript _generate_size_dir_face
##   QVX 路径 UV: (u, 0.0)          —— 原生 generate_dense_impl (voxel_native.cpp:301/316)
##   两者 u 相同、v 不同。若纹理被按 clamp/mipmap/双线性处理，v=0.0 可能采到边界，
##   在 1 像素高的纹理上产生条纹/串色。
##
## 除肉眼对比，本场景还做**逐体素数值比对**（QVX 往返 vs 原始 chunk 缓冲），
## 并在 HUD 打出 PASS / FAIL。
##
## 操作：
##   1..9  : 只显示第 N 组（左 mesh / 右 qvx）
##   0     : 显示全部
##   M     : 单独切换 mesh 侧显示
##   Q     : 单独切换 qvx 侧显示
##   V     : 把 QVX 侧的 UV 从 v=0.0 改成 v=0.5 复测（验证 v 的影响）
##   W     : 线框
##   R     : 自动旋转
##   F     : 强制重新烘焙 .qvx 后再比对
##   左键拖拽 / 滚轮 : 旋转 / 缩放
##   Esc   : 退出

@export var models: Array[String] = [
	"res://demo/deer.vox",
	"res://demo/cars.vox",
	"res://demo/teapot1.vox",
]

@export var pair_gap: float = 2.6
@export var group_gap: float = 6.2
@export var target_extent: float = 2.2
## 烘焙缓存目录。**本场景独占，不与其它 demo 共用**：
## 【踩过的坑】它原先是 `user://qvx_viewer`（与 qvox_model_viewer 同一个目录、同一批文件名），
## 而 viewer 按 world_origin（负坐标）烘、本场景按 bottom_center（重映射到 0 起）烘——
## 谁后跑谁把对方的缓存覆盖掉，表现是**逐体素比对莫名 FAIL**（差异成千上万格，但两侧位置仍对齐）。
## 缓存键必须包含"写入时的语义"，否则缓存会跨语义串味。
@export var bake_dir: String = "user://qvox_vs_mesh"
@export var force_rebake: bool = false
## 覆盖 QVX 侧 UV 的 v 分量（-1 = 不改，保持原生 v=0.0）
## 两侧**显式同取**的原点模式（见 `_build_group` / `_build_reference_mesh`）。
## 抽成常量是为了让"烘焙文件名 + 数据构造 + mesh 选项"三处不可能各写一个值——
## 这三处一旦不一致，表现就是逐体素比对 FAIL 而位置看着还对（最难查的那类 bug）。
const ORIGIN_MODE := QVoxelSource.OriginMode.BOTTOM_CENTER

## 覆盖 QVX 侧 UV 的 v 分量（-1 = 不改，保持原生 v=0.0）
@export var qvox_uv_v_override: float = -1.0

var _camera: Camera3D
var _hud: Label
var _info: Label
var _root: Node3D

var _yaw := 0.0
var _pitch := 0.18
var _dist := 16.0
var _auto_rotate := false
var _wireframe := false
var _dragging := false
var _show_mesh := true
var _show_qvox := true

var _groups: Array = []
var _focus_group := -1
var _row_min := Vector3.ZERO
var _row_max := Vector3.ZERO


func _ready() -> void:
	_setup_camera()
	_setup_hud()
	_run_vkey_collision_probe()
	_build_all(force_rebake)
	print("[QvxMeshCmp] 初始化完成，组数=%d" % _groups.size())


## 原生哈希键碰撞探针（回归守卫，纯逻辑、无需模型文件）。
##
## 背景：`voxel_native.cpp` 的 `vkey` / `grid_vkey` 把 (x,y,z) 打包成 uint64 做哈希键，
## 曾因位段重叠（x 占 bit42..63、y 占 bit21..52 重叠 11 位）导致**负坐标大面积撞键**，
## 使 chunks / mat_map / chunk_bufs / by_chunk / removed_set 等把不同 chunk 或体素
## 当成同一个 → 网格错乱、材质串味、破坏操作丢体素。
##
## 本探针用原生暴露的 API 间接验证：对一组**互不相同**的体素位置调用
## `collect_chunks`（内部用 chunk_of + vkey 分组去重），若返回的 chunk 数少于
## 实际应有的不同 chunk 数，即说明键发生碰撞。探针在正/负坐标域各跑一遍。
func _run_vkey_collision_probe() -> void:
	if not NativeLoader.is_available():
		print("[QvxMeshCmp][VKeyProbe] 原生库不可用，跳过")
		return
	var bad := 0
	# 取一批落在不同 chunk 的坐标（含负 chunk），每个坐标单点成数组。
	# chunk_of(p) = p >> 5。这里每 32 步取一个点 → 每点独占一个 chunk。
	var positions: Array = []
	var expect := {}
	var coords := [
		Vector3i(-1000 * 32, -3 * 32, -3 * 32),
		Vector3i(-999 * 32, -3 * 32, -3 * 32),
		Vector3i(-1 * 32, -1 * 32, -1 * 32),
		Vector3i(0, 0, 0),
		Vector3i(1 * 32, 1 * 32, 1 * 32),
		Vector3i(1000 * 32, 3 * 32, 3 * 32),
		Vector3i(999 * 32, 3 * 32, 3 * 32),
		Vector3i(-500 * 32, 7 * 32, -9 * 32),
	]
	for p in coords:
		positions.append(p)
		expect[Vector3i(p.x >> 5, p.y >> 5, p.z >> 5)] = true
	var got: Array = VoxelNative.collect_chunks(positions)
	# collect_chunks 返回去重后的 chunk 列表
	var got_set := {}
	for ck in got:
		got_set[ck] = true
	if got_set.size() != expect.size():
		bad += 1
		print("[QvxMeshCmp][VKeyProbe] FAIL: 期望 %d 个不同 chunk，实得 %d（键碰撞!）"
				% [expect.size(), got_set.size()])
		# 打印缺失项便于定位
		for k in expect:
			if not got_set.has(k):
				print("    缺失 chunk: %s" % k)
	else:
		print("[QvxMeshCmp][VKeyProbe] PASS: 负/正坐标 chunk 去重正确（%d/%d）"
				% [got_set.size(), expect.size()])
	if bad == 0:
		print("[QvxMeshCmp][VKeyProbe] 原生哈希键无碰撞")


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.current = true
	_camera.fov = 60.0
	_camera.far = 800.0


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.position = Vector2(12, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(0.08, 0.09, 0.12))
	_hud.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(_hud)

	_info = Label.new()
	_info.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_info.position = Vector2(-540, 10)
	_info.size = Vector2(528, 0)
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_info.add_theme_font_size_override("font_size", 13)
	_info.add_theme_color_override("font_color", Color(0.05, 0.1, 0.2))
	_info.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_info.add_theme_constant_override("outline_size", 5)
	layer.add_child(_info)


func _build_all(rebake: bool) -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_groups.clear()
	_focus_group = -1

	_root = Node3D.new()
	_root.name = "Models"
	add_child(_root)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(bake_dir))

	var n := models.size()
	for i in n:
		var src: String = models[i]
		if not ResourceLoader.exists(src):
			push_warning("[QvxMeshCmp] 找不到模型: %s" % src)
			continue
		var g := _build_group(src, i, n, rebake)
		if g.is_empty():
			continue
		_groups.append(g)

	_layout()
	_auto_frame()
	_apply_visibility()
	_update_hud()


## 构建一组：左 = mesh 路径（正确基准），右 = .qvx 往返
func _build_group(src: String, index: int, total: int, rebake: bool) -> Dictionary:
	var name := src.get_file().get_basename()

	# ---------- A. MESH 路径（正确基准）----------
	var vox := VoxAccess.Open(src)
	if vox == null:
		push_error("[QvxMeshCmp] VoxAccess 打开失败: %s" % src)
		return {}
	var mesh := _build_reference_mesh(vox.voxel)
	if mesh == null:
		push_error("[QvxMeshCmp] generate_mesh 失败: %s" % src)
		return {}
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	_root.add_child(mesh_inst)

	# ---------- B. QVX 路径 ----------
	# 两侧**显式取同一个原点模式**：导入器默认值现在是 world_origin（原样保留文件里的坐标），
	# 而本场景的排布与取景是按"模型贴地"设计的（world_origin 下 teapot1 会悬空 5.8 单位、出画）。
	# 默认值本身的一致性由 test_qvox_import.gd 的 test_mesh_and_data_origin_agree 守着，
	# 不靠本场景。
	var data := QVoxelSource.from_voxel_data(vox.voxel, 0, ORIGIN_MODE)
	if data == null:
		push_error("[QvxMeshCmp] from_voxel_data 失败: %s" % src)
		return {}
	var chunks_vox := _extract_chunks(data)

	# 文件名带回原点模式：缓存键必须包含"写入时的语义"，否则改了模式就会读到上一次的坐标
	# （目录已独占，这层是第二道保险，也让缓存文件自解释）。
	var qpath := bake_dir.path_join("%s_%d.qvx" % [name, ORIGIN_MODE])
	if rebake or not FileAccess.file_exists(qpath):
		_bake_qvox(qpath, data, chunks_vox)

	var reader := QVoxelStream.new()
	reader.file_path = qpath
	reader.clear_cache()
	var chunks_qvox := {}
	for ck in chunks_vox:
		var got := reader.load_chunk(ck, 0)
		if not got.is_empty():
			chunks_qvox[ck] = got

	# ---------- C. 逐体素数值比对 ----------
	var diff_count := 0
	var total_voxels := 0
	var total_cells := 0
	var missing := 0
	var extra := 0
	for ck in chunks_vox:
		if not chunks_qvox.has(ck):
			missing += 1
			continue
		var a: PackedInt32Array = chunks_vox[ck]
		var b: PackedInt32Array = chunks_qvox[ck]
		var m := mini(a.size(), b.size())
		total_cells += m
		for i in m:
			if a[i] != 0:
				total_voxels += 1
			if a[i] != b[i]:
				diff_count += 1
	for ck in chunks_qvox:
		if not chunks_vox.has(ck):
			extra += 1

	# ---------- C2. 原生几何完整性（回归守卫）----------
	# 逐三角形检查：同一三角形的 3 个顶点必须 UV 一致、法线一致。
	# 这是「原生顶点去重键碰撞」这一类 bug 的直接探针：
	# 若去重键（点+面+材质）发生碰撞，一个顶点会被另一材质/另一面的三角形复用，
	# 于是同一三角形上出现不同 UV（u 在两 texel 间插值 → 彩虹条纹）或不同法线。
	var geo_bad_uv := 0
	var geo_bad_normal := 0
	var geo_tris := 0
	# 用最初 data 的原生 chunk 生成器，逐块检查
	var gen := VoxelChunkGenerator.new()
	var aligned: Array = []
	aligned.resize(data.materials.size())
	for i in data.materials.size():
		aligned[i] = data.materials[i]
	for ck in chunks_vox:
		var halo := gen.build_halo_from_buffers(chunks_vox, ck)
		var res := gen.generate_single_chunk_dense(halo, aligned, 0.1, ck, Vector3.ZERO)
		if res.is_empty():
			continue
		var uvs: PackedVector2Array = res.get("solid_uvs", PackedVector2Array())
		var nrms: PackedVector3Array = res.get("solid_normals", PackedVector3Array())
		var idxs: PackedInt32Array = res.get("solid_idxs", PackedInt32Array())
		var nt := idxs.size() / 3
		geo_tris += nt
		for t in nt:
			var a := idxs[t * 3]
			var b := idxs[t * 3 + 1]
			var c := idxs[t * 3 + 2]
			if not (uvs[a] == uvs[b] and uvs[b] == uvs[c]):
				geo_bad_uv += 1
			if not (nrms[a] == nrms[b] and nrms[b] == nrms[c]):
				geo_bad_normal += 1

	# ---------- D. QVX 渲染器 ----------
	var rdata := QVoxelSource.new()
	rdata.stream = reader
	# 【关键】渲染顶点 = (体素坐标 + data.center_offset) * voxel_scale，故这个新 QVoxelSource 必须
	# 继承同一份原点偏移——否则右侧会按"内容角点即原点"渲染，与左侧 mesh 差出一截
	# （这正是本场景此前"基础位置差很多"的第二半原因：脚本新建 rdata 时漏了 center_offset）。
	rdata.center_offset = data.center_offset
	for m in data.materials:
		if m != null:
			rdata.add_material(m)
	var qvox_r := VoxelRenderer.new()
	qvox_r.data = rdata
	qvox_r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	qvox_r.lod_count = 1
	_root.add_child(qvox_r)

	var ok := diff_count == 0 and missing == 0 and extra == 0 \
			and geo_bad_uv == 0 and geo_bad_normal == 0
	print("[QvxMeshCmp] %s: mesh=%d face / qvx %d chunk | 比对单元 %d 差异 %d | 缺块 %d 多块 %d | 几何 %d tri 坏UV %d 坏法线 %d → %s"
			% [name, mesh.get_faces().size() / 3, chunks_qvox.size(), total_cells, diff_count,
			   missing, extra, geo_tris, geo_bad_uv, geo_bad_normal, "PASS" if ok else "FAIL"])

	return {
		"name": name,
		"src": src,
		"mesh_inst": mesh_inst,
		"mesh_aabb": _mesh_aabb(mesh),
		"qvox_r": qvox_r,
		"data": data,
		"chunks_raw": chunks_vox,
		"diff_count": diff_count,
		"total_voxels": total_voxels,
		"total_cells": total_cells,
		"chunks": chunks_vox.size(),
		"missing": missing,
		"extra": extra,
		"geo_tris": geo_tris,
		"geo_bad_uv": geo_bad_uv,
		"geo_bad_normal": geo_bad_normal,
		"ok": ok,
	}


## 用与 VoxelMeshImporter 完全相同的选项构建参考 mesh。
## demo/deer.vox.import 的参数：scale=0.1, shape=1(cube), frame_index=0,
## import_materials_textures=false, material_path=""
func _build_reference_mesh(voxel: VoxAsset) -> ArrayMesh:
	var opts := {
		VoxelMeshImporter.scale: 0.1,
		# 与右侧 data 路径显式取同一个原点模式：本场景要验证的正是"两条路一致"
		VoxelMeshImporter.origin: ORIGIN_MODE,
		VoxelMeshImporter.shape: VoxelMeshImporter.Shape.cube,
		VoxelMeshImporter.sphere_subdivisions: 0,
		VoxelMeshImporter.sphere_scale: 1.0,
		VoxelMeshImporter.frame_index: 0,
		VoxelMeshImporter.unwrap_lightmap_uv2: false,
		VoxelMeshImporter.uv2_texel_size: 0.2,
		VoxelMeshImporter.import_materials_textures: false,
	}
	return VoxelMeshGenerator.generate_mesh(voxel, opts)


func _mesh_aabb(mesh: ArrayMesh) -> AABB:
	return mesh.get_aabb()


func _bake_qvox(qpath: String, data: QVoxelSource, chunks: Dictionary) -> void:
	var stream := QVoxelStream.new()
	stream.file_path = qpath
	var mats: Array = []
	mats.resize(data.materials.size())
	for i in data.materials.size():
		mats[i] = data.materials[i]
	stream.set_materials(mats)
	for ck in chunks:
		stream.save_chunk(ck, chunks[ck], 0)
	stream.flush()


func _extract_chunks(data: QVoxelSource) -> Dictionary:
	var out: Dictionary = {}
	var raw: Dictionary = data.get("_chunk_buffers")
	for ck in raw:
		var buf: PackedInt32Array = raw[ck]
		if buf.size() > 0:
			out[ck] = buf
	return out


func _chunk_extent(chunks: Dictionary) -> AABB:
	if chunks.is_empty():
		return AABB()
	var mn := Vector3i.MAX
	var mx := Vector3i.MIN
	var found := false
	for ck: Vector3i in chunks:
		var buf: PackedInt32Array = chunks[ck]
		if buf.size() < VoxelChunk.CHUNK_VOLUME:
			continue
		var origin := VoxelChunk.origin_of(ck)
		for i in VoxelChunk.CHUNK_VOLUME:
			if buf[i] <= 0:
				continue
			var p := origin + _local_from_index(i)
			mn.x = mini(mn.x, p.x)
			mn.y = mini(mn.y, p.y)
			mn.z = mini(mn.z, p.z)
			mx.x = maxi(mx.x, p.x)
			mx.y = maxi(mx.y, p.y)
			mx.z = maxi(mx.z, p.z)
			found = true
	if not found:
		return AABB()
	return AABB(Vector3(mn), Vector3(mx - mn + Vector3i.ONE))


static func _local_from_index(i: int) -> Vector3i:
	var lz := i / VoxelChunk.CHUNK_SLICE
	var rem := i % VoxelChunk.CHUNK_SLICE
	var ly := rem / VoxelChunk.CHUNK_SIZE
	var lx := rem % VoxelChunk.CHUNK_SIZE
	return Vector3i(lx, ly, lz)


## 排布：左侧 mesh（正确基准），右侧 qvx，各自直接摆到槽位，**不做任何位置补偿**。
##
## 【为什么不再需要补偿】两条路径现在共用同一套原点语义（`QVoxelSource.OriginMode`，
## 默认 bottom_center = 内容 X/Z 居中 + Y 贴底）。历史上这里两边的原点不同——mesh 走 .vox 的
## SIZE 盒中心（模型可能悬空/下沉）、data 走内容角点（贴地）——实测差 0.35~0.50（模型边长 2.2），
## 当时靠"各自按 AABB 底面对齐"来掩盖。统一约定之后，那种补偿只会掩盖回归，故改为**校验并报告**。
func _layout() -> void:
	var count := _groups.size()
	if count == 0:
		return
	for i in count:
		var g: Dictionary = _groups[i]

		# mesh 侧 AABB（已经是世界单位）
		var ma: AABB = g["mesh_aabb"]
		var mesh_inst: MeshInstance3D = g["mesh_inst"]
		var qvox_r: VoxelRenderer = g["qvox_r"]

		# qvx 侧体素 AABB
		# 注意：qvox_r.data 是由 reader 支撑的 QVoxelSource（只含 stream，无 _chunk_buffers），
		# 因此必须用最初 from_voxel_data 得到的 data 来算体素范围。
		var va: AABB = _chunk_extent(g["chunks_raw"])
		if va.size.length() < 0.0001 or ma.size.length() < 0.0001:
			print("[QvxMeshCmp] 布局跳过 %s: mesh_ext=%.3f vox_ext=%.3f"
					% [g["name"], ma.size.length(), va.size.length()])
			continue

		# 两条路径都要缩放到 target_extent：mesh 顶点已含 scale=0.1，
		# qvx 通过 voxel_scale 控制。
		var mesh_extent := maxf(maxf(ma.size.x, ma.size.y), ma.size.z)
		var vox_extent := maxf(maxf(va.size.x, va.size.y), va.size.z)
		var mesh_scale := target_extent / mesh_extent
		var vs := target_extent / vox_extent

		mesh_inst.scale = Vector3.ONE * mesh_scale
		qvox_r.voxel_scale = vs

		# 两侧原点已统一（QVoxelSource.OriginMode.BOTTOM_CENTER）：X/Z 在内容中心、Y 在底面，
		# 因此各自直接摆到槽位即可，**不需要任何位置补偿**。
		var group_x := (i - (count - 1) * 0.5) * group_gap
		var left_x := group_x - pair_gap * 0.5
		var right_x := group_x + pair_gap * 0.5
		mesh_inst.position = Vector3(left_x, 0.0, 0.0)
		qvox_r.position = Vector3(right_x, 0.0, 0.0)

		# 【复核】两侧世界包围盒必须重合（同一 scale 下）。若哪天有人改坏了原点统一——比如又漏给
		# rdata 设 center_offset、或 mesh 路径退回"作者摆放"——这里会当场报出来，而不是像以前
		# 那样被一段位置补偿代码悄悄掩盖掉。
		var q_off: Vector3 = qvox_r.data.center_offset if qvox_r.data != null else Vector3.ZERO
		var m_min := ma.position * mesh_scale
		var q_min := (va.position + q_off) * vs
		var origin_delta := (m_min - q_min).length()
		g["origin_delta"] = origin_delta
		if origin_delta >= 0.01:
			push_warning("[QvxMeshCmp] %s 两侧原点不一致：mesh 底面 y=%.3f vs qvx 底面 y=%.3f（Δ=%.3f）"
					% [g["name"], m_min.y, q_min.y, origin_delta])

		g["_w"] = target_extent
		g["_h"] = maxf(ma.size.y * mesh_scale, va.size.y * vs)
		g["_d"] = target_extent
		g["_cx"] = group_x
		print("[QvxMeshCmp] 布局 %s: mesh_ext=%.1f(vox=%dface) vox_ext=%.1f qscale=%.4f"
				% [g["name"], mesh_extent, (mesh_inst.mesh as ArrayMesh).get_faces().size() / 3,
				   vox_extent, vs])


func _auto_frame() -> void:
	var count := _groups.size()
	if count == 0:
		return
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for i in count:
		var g: Dictionary = _groups[i]
		var cx: float = g.get("_cx", 0.0)
		var w: float = target_extent
		mn.x = minf(mn.x, cx - pair_gap * 0.5 - w * 0.5)
		mx.x = maxf(mx.x, cx + pair_gap * 0.5 + w * 0.5)
		mn.z = minf(mn.z, -w * 0.5)
		mx.z = maxf(mx.z, w * 0.5)
		mx.y = maxf(mx.y, g.get("_h", target_extent))
	mn.y = 0.0
	_row_min = mn
	_row_max = mx
	var row_w := mx.x - mn.x
	var row_h := maxf(mx.y, 0.001)
	var fov_v := deg_to_rad(_camera.fov)
	var aspect := 16.0 / 9.0
	var vp := get_viewport()
	if vp != null and vp.get_visible_rect().size.y > 0.0:
		aspect = vp.get_visible_rect().size.x / vp.get_visible_rect().size.y
	var fov_h := 2.0 * atan(tan(fov_v * 0.5) * aspect)
	var d_w := (row_w * 0.5) / tan(fov_h * 0.5)
	var d_h := (row_h * 0.5) / tan(fov_v * 0.5)
	_dist = clampf(maxf(d_w, d_h) * 1.45, 4.0, 200.0)
	_yaw = 0.0
	_pitch = 0.18
	_focus_group = -1
	print("[QvxMeshCmp] 取景: 排宽=%.2f 高=%.2f dist=%.2f" % [row_w, row_h, _dist])


func _process(delta: float) -> void:
	if _auto_rotate and not _dragging:
		_yaw += delta * 0.4
	var target := (_row_min + _row_max) * 0.5
	var px := target.x + _dist * cos(_pitch) * sin(_yaw)
	var py := target.y + _dist * sin(_pitch)
	var pz := target.z + _dist * cos(_pitch) * cos(_yaw)
	_camera.global_position = Vector3(px, py, pz)
	_camera.look_at(target, Vector3.UP)
	_update_hud()


func _apply_visibility() -> void:
	for g in _groups:
		var mesh_inst: MeshInstance3D = g["mesh_inst"]
		var qvox_r: VoxelRenderer = g["qvox_r"]
		if is_instance_valid(mesh_inst):
			mesh_inst.visible = _show_mesh
		if is_instance_valid(qvox_r):
			qvox_r.visible = _show_qvox

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(1.0, _dist * 0.9)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(300.0, _dist * 1.1)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.01
		_pitch = clampf(_pitch + mm.relative.y * 0.01, -1.4, 1.4)
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_R:
				_auto_rotate = not _auto_rotate
			KEY_W:
				_wireframe = not _wireframe
			KEY_M:
				_show_mesh = not _show_mesh
				_apply_visibility()
			KEY_Q:
				_show_qvox = not _show_qvox
				_apply_visibility()
			KEY_V:
				_patch_qvox_uv_v()
			KEY_F:
				_build_all(true)
			KEY_ESCAPE:
				get_tree().quit()
			KEY_0:
				_focus_group = -1
				_auto_frame()
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				var idx := (event as InputEventKey).keycode - KEY_1
				if idx < _groups.size():
					_focus_group = idx
					_dist = target_extent * 3.4
					_auto_rotate = false


## 诊断开关：把 qvx 侧已生成 chunk mesh 的 UV.v 从 0.0 改成 0.5，复测颜色是否恢复。
## 这是「mesh 路径用 v=0.5 / 原生 chunk 路径用 v=0.0」这一差异的直接验证。
func _patch_qvox_uv_v() -> void:
	var v := 0.5 if qvox_uv_v_override < 0.0 else qvox_uv_v_override
	qvox_uv_v_override = v
	var patched := 0
	for g in _groups:
		var qvox_r: VoxelRenderer = g["qvox_r"]
		for ch in qvox_r.get_children():
			if not (ch is MeshInstance3D):
				continue
			var mi := ch as MeshInstance3D
			var src_mesh: ArrayMesh = mi.mesh
			if src_mesh == null:
				continue
			for s in src_mesh.get_surface_count():
				var arr := src_mesh.surface_get_arrays(s)
				var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
				for i in uvs.size():
					uvs[i].y = v
				arr[Mesh.ARRAY_TEX_UV] = uvs
				src_mesh.surface_remove(s)
				src_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				patched += 1
	print("[QvxMeshCmp] UV.v 覆写为 %.1f，patch surface 数=%d" % [v, patched])


func _update_hud() -> void:
	var fps := Engine.get_frames_per_second()
	_hud.text = "QVX ⇄ Mesh 对比验证    FPS: %d\n" % fps + \
			"左=MESH 导入(正确基准)   右=.qvx 往返 (QVX UV.v 覆写: %s)\n" % [
				("原生0.0" if qvox_uv_v_override < 0.0 else "%.1f" % qvox_uv_v_override)] + \
			"M:%s Q:%s W线框 R旋转\n" % ["显示mesh" if _show_mesh else "隐藏mesh", "显示qvox" if _show_qvox else "隐藏qvox"] + \
			"1-9:聚焦 0:全部 V:切换QVox UV.v F:重烘焙 Esc:退出"

	var lines: Array = ["QVX ⇄ MESH 逐体素比对", ""]
	for g in _groups:
		var tag := "PASS" if g["ok"] else "FAIL"
		var org: Variant = g.get("origin_delta")
		var org_txt := "" if org == null else ("  原点Δ=%.3f%s"
				% [float(org), "" if float(org) < 0.01 else " ←两侧不一致!"])
		lines.append("%s  [%s]%s" % [g["name"], tag, org_txt])
		if g["ok"]:
			lines.append("  %d chunk / 比对 %d 格，零差异" % [g["chunks"], g["total_cells"]])
			lines.append("  几何 %d tri，坏UV 0 坏法线 0" % g["geo_tris"])
		else:
			lines.append("  差异 %d 格 / 缺块 %d 多块 %d" % [g["diff_count"], g["missing"], g["extra"]])
			lines.append("  几何 %d tri / 坏UV %d 坏法线 %d" % [g["geo_tris"], g["geo_bad_uv"], g["geo_bad_normal"]])
	_info.text = "\n".join(PackedStringArray(lines))
