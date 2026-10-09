class_name VoxelMeshGenerator
## 体素网格生成器（编辑器导入路径）
## 几何内核统一下沉 C++（NativeLoader → VoxelNative），与运行时管线共用同一套实现：
##   cube   面片网格（分方向可见性 + 贪婪合并）
##   sphere 每体素一颗 icosphere（自动按顶点预算降采样）
## 此处只负责：材质纹理、MeshLibrary 分割编排，以及把原生 arrays 交给引擎 API 组装。


static func generate_mesh(voxel: VoxAsset, options: Dictionary, path: String = "") -> ArrayMesh:
	var gen := VoxelMeshGenerator.new(voxel, options, path)
	gen.generate_materials(options)
	var time := Time.get_ticks_usec()
	gen.start_generate_mesh(voxel.get_voxels(gen.frame_index))
	gen.wait_finished(options[VoxelMeshImporter.unwrap_lightmap_uv2], options[VoxelMeshImporter.uv2_texel_size])
	if not gen.mesh:
		return null
	if options[VoxelMeshImporter.unwrap_lightmap_uv2]:
		gen.mesh.lightmap_unwrap(Transform3D.IDENTITY, options[VoxelMeshImporter.uv2_texel_size])
	print_verbose("generate_mesh mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms", gen.mesh.get_faces().size() / 6, "face")
	return gen.mesh


# 材质魔术值：编辑器导入与运行时生成共用，避免两处漂移
const MATERIAL_EMISSION_ENERGY := 20.0
const MATERIAL_REFRACTION_SCALE := 0.01


## 统一配置实心材质（编辑器/运行时共用）
##
## 【不开 vertex_color_use_as_albedo】本渲染器不提供几何级顶点色 AO（曾实现过，
## 实测观感更差，原因记录在 VoxelChunkGenerator 的"已移除：顶点色 AO"那段）。
## 凹处的层次改为用**材质分档**表达（同色系更暗的一档体素），那才是体素画法。
static func _configure_solid_material(m: StandardMaterial3D) -> void:
	m.emission_enabled = true
	m.emission_energy_multiplier = MATERIAL_EMISSION_ENERGY
	m.metallic = 1.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST


## 统一配置透明材质（在实心材质基础上追加折射/透明，关闭自发光）
static func _configure_trans_material(m: StandardMaterial3D) -> void:
	m.refraction_enabled = true
	m.refraction_scale = MATERIAL_REFRACTION_SCALE
	m.emission_enabled = false
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST


## 从材质数组生成运行时纹理材质 (StandardMaterial3D 数组，0=实体 1=透明)
## 与编辑器导入的纹理材质等价，但完全在内存中生成，不涉及文件 IO
## 复用与编辑器导入一致的 UV 采样方案 (纹素中心对齐材质ID)
## 材质→颜色采样公式统一在 VoxelMaterial 中
static func generate_textured_materials_runtime(materials: Array) -> Array:
	var result: Array = [null, null]
	var images := _build_channel_images(materials)
	var solid := StandardMaterial3D.new()
	_configure_solid_material(solid)
	solid.albedo_texture = ImageTexture.create_from_image(images["albedo"])
	solid.metallic_texture = ImageTexture.create_from_image(images["metal"])
	solid.roughness_texture = ImageTexture.create_from_image(images["rough"])
	solid.emission_texture = ImageTexture.create_from_image(images["emission"])
	result[0] = solid
	var trans := solid.duplicate()
	_configure_trans_material(trans)
	result[1] = trans
	return result


## 从材质数组统一生成 4 张 256x1 材质通道图 (albedo/metal/rough/emission)
## 采样公式统一在 VoxelMaterial 中，编辑器文件纹理与运行时内存纹理共用
## 使用静态方法采样，保证对 placeholder 实例(编辑器导入资源)也可安全调用
static func _build_channel_images(materials: Array) -> Dictionary:
	var albedo_image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	var metal_image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	var rough_image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	var emission_image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in mini(materials.size(), 256):
		var m: VoxelMaterial = materials[i]
		if m == null:
			continue
		albedo_image.set_pixel(i, 0, VoxelMaterial.albedo_color(m))
		metal_image.set_pixel(i, 0, VoxelMaterial.metal_color(m))
		rough_image.set_pixel(i, 0, VoxelMaterial.rough_color(m))
		emission_image.set_pixel(i, 0, VoxelMaterial.emission_color(m))
	return {
		"albedo": albedo_image, "metal": metal_image,
		"rough": rough_image, "emission": emission_image,
	}

static func generate_mesh_library(voxel: VoxAsset, options: Dictionary, path: String = "") -> MeshLibrary:
	var root_gen := VoxelMeshGenerator.new(voxel, options, path)
	root_gen.generate_materials(options)
	var time := Time.get_ticks_usec()

	var gens: Array[VoxelMeshGenerator]
	var res: Resource = ResourceLoader.load(path) if FileAccess.file_exists(path) else null
	var voxel_mesh_library: MeshLibrary = res if res is MeshLibrary else null
	if not voxel_mesh_library:
		voxel_mesh_library = MeshLibrary.new()
	match options[VoxelMeshLibraryImporter.mesh_mode]:
		VoxelMeshLibraryImporter.MeshMode.split_by_model:
			for i in voxel.models.size():
				var gen := VoxelMeshGenerator.new(voxel, options, path)
				gen.materials = root_gen.materials
				gen.mesh = _get_mesh("model_" + str(i), path, options)
				gen.start_generate_mesh(voxel.models[i].get_voxels())
				gens.append(gen)

		VoxelMeshLibraryImporter.MeshMode.split_by_node:
			var root_node := voxel.nodes[voxel.nodes[0].child_nodes[0]]
			var gen_nodes: Array[String]
			for node_id in root_node.child_nodes:
				var node := voxel.nodes[node_id]
				if node.name:
					if gen_nodes.has(node.name):
						printerr("Nodes cannot have the same name [", node.name, "] path: ", path)
						continue
					gen_nodes.append(node.name)
				var gen := VoxelMeshGenerator.new(voxel, options, path)
				gen.materials = root_gen.materials
				gen.mesh = _get_mesh(node.get_name(voxel, root_gen.frame_index), path, options)
				gen.start_generate_mesh(node.get_voxels(voxel, root_gen.frame_index, true), )
				gens.append(gen)

		VoxelMeshLibraryImporter.MeshMode.split_by_frame:
			for i in root_gen.frame_index + 1:
				var gen := VoxelMeshGenerator.new(voxel, options, path)
				gen.materials = root_gen.materials
				gen.mesh = _get_mesh("frame_" + str(i), path, options)
				gen.start_generate_mesh(voxel.get_voxels(i))
				gens.append(gen)

	var old_meshes: Array[ArrayMesh]
	for i in voxel_mesh_library.get_item_list():
		var old_mesh := voxel_mesh_library.get_item_mesh(i)
		if old_mesh:
			old_meshes.append(old_mesh)
	voxel_mesh_library.clear()
	for i in gens.size():
		var child_mesh := gens[i].wait_finished(options[VoxelMeshImporter.unwrap_lightmap_uv2], options[VoxelMeshImporter.uv2_texel_size])
		if not child_mesh:
			continue
		voxel_mesh_library.create_item(i)
		voxel_mesh_library.set_item_mesh(i, child_mesh)
		voxel_mesh_library.set_item_name(i, child_mesh.resource_name)
		if options[VoxelMeshLibraryImporter.import_meshes] and path:
			ResourceSaver.save(child_mesh)
	for old_mesh in old_meshes:
		var i := voxel_mesh_library.find_item_by_name(old_mesh.resource_name)
		if i < 0:
			DirAccess.remove_absolute(old_mesh.resource_path)
			print_verbose("delete ", old_mesh.resource_path)
	print_verbose("generate_mesh_library mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms")
	return voxel_mesh_library

static func _get_mesh(name: String, path: String, options: Dictionary) -> ArrayMesh:
	if options[VoxelMeshLibraryImporter.import_meshes] and path:
		DirAccess.make_dir_absolute(path.get_basename())
		var child_path := path.get_basename() + "/" + name + ".res"
		# 存在性检查必须针对**要加载的那个文件**（child_path）。此前检查的是源资产 path，
		# 于是"缓存的 .res 存在但源资产不在"时会漏加载，反之也会误走加载分支。
		var mesh := ResourceLoader.load(child_path) as ArrayMesh if FileAccess.file_exists(child_path) else null
		if not mesh:
			mesh = ArrayMesh.new()
			mesh.resource_path = child_path
			mesh.resource_name = name
		return mesh
	else:
		return ArrayMesh.new()


## 材质通道图（albedo/metal/rough/emission）——一次导入只构建一次。
## 此前每张纹理都重新构建全部 4 张图（4 材质 × 4 纹理 = 16 次），纯浪费。
func _get_channel_images() -> Dictionary:
	if _channel_images.is_empty():
		var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
		_channel_images = _build_channel_images(mats)
	return _channel_images


# ----------------------------------------------------------------------------
# QVX 路径 —— 块级生成
# ----------------------------------------------------------------------------
# QVX 的 block_size 恒等于 CHUNK_SIZE，块坐标就是 chunk 坐标，因此网格可以直接按块生成：
# build_halo_from_buffers（跨块面可见性）→ generate_chunk_dense。无需把数据摊平成
# Dictionary[Vector3i,int] 再交给 generate_arrays_native 重新分块（那是 .vox 路径的做法）。
#
# 坐标约定：use_local_space=false → 顶点 = (体素坐标 + offset) × scale，即**绝对世界坐标**，
# 于是各块结果可直接拼接；块边界面"负方向本块负责、正方向看邻居"的约定保证每个跨界只生成
# 一次 → 拼接后无重叠面、无 z-fighting。

## 由块缓冲生成网格 arrays（输出形状与 generate_arrays_native 一致）。
##
## 【测试 oracle，非生产路径】生产路径已全量下沉原生
## （NativeLoader.generate_arrays_from_chunks_native，见 P2-5）：本函数保留的唯一用途是
## test_voxel_snapshot_baseline 的逐位对照。原生实现与本 oracle 的产物字节序列必须一致，
## 故两处需同步修改。
static func generate_arrays_from_chunks(chunks: Dictionary, trans_flags: PackedByteArray,
		scale: float, offset: Vector3) -> Dictionary:
	var sv := PackedVector3Array()
	var sn := PackedVector3Array()
	var su := PackedVector2Array()
	var si := PackedInt32Array()
	var tv := PackedVector3Array()
	var tn := PackedVector3Array()
	var tu := PackedVector2Array()
	var ti := PackedInt32Array()
	for key in chunks:
		var ck: Vector3i = key
		var halo := VoxelChunkGenerator.build_halo_from_buffers(chunks, ck)
		if halo.is_empty():
			continue
		var part := NativeLoader.generate_chunk_dense(halo, trans_flags, scale, ck, false, offset)
		# 【为什么写在循环体内而不是抽函数】Packed*Array 是写时复制：把累积数组传进辅助
		# 函数会多一个引用，每次 append 都触发整段复制（O(n²)）。故就地 append 局部变量。
		var pv: PackedVector3Array = part.get("solid_verts", PackedVector3Array())
		if not pv.is_empty():
			var base := sv.size()
			sv.append_array(pv)
			sn.append_array(part["solid_normals"])
			su.append_array(part["solid_uvs"])
			si.append_array(_shift_index_array(part["solid_idxs"], base))
		var pt: PackedVector3Array = part.get("trans_verts", PackedVector3Array())
		if not pt.is_empty():
			var base_t := tv.size()
			tv.append_array(pt)
			tn.append_array(part["trans_normals"])
			tu.append_array(part["trans_uvs"])
			ti.append_array(_shift_index_array(part["trans_idxs"], base_t))
	var out := {
		"solid_verts": sv, "solid_normals": sn, "solid_uvs": su, "solid_idxs": si,
		"trans_verts": tv, "trans_normals": tn, "trans_uvs": tu, "trans_idxs": ti,
	}
	return out


## 索引数组整体加偏移（多块网格合并时把各自的顶点基准抬到全局）。
static func _shift_index_array(idxs: PackedInt32Array, base: int) -> PackedInt32Array:
	if base == 0:
		return idxs
	var out := PackedInt32Array()
	out.resize(idxs.size())
	for i in idxs.size():
		out[i] = idxs[i] + base
	return out


## .qvx → ArrayMesh（单网格）。选项与 .vox 路径共用，故两者产物形状一致。
static func generate_mesh_from_qvx(qvx: QVoxelAsset, options: Dictionary, path: String = "") -> ArrayMesh:
	var gen := VoxelMeshGenerator.new(null, options, path)
	gen.qvx = qvx
	gen.runtime_materials = qvx.materials
	gen.generate_materials(options)
	gen.start_generate_mesh_from_qvx()
	gen.wait_finished(options[VoxelMeshImporter.unwrap_lightmap_uv2], options[VoxelMeshImporter.uv2_texel_size])
	if not gen.mesh or gen.mesh.get_surface_count() == 0:
		return null
	return gen.mesh


## .qvx → MeshLibrary。三种分项都是"每项一个网格"：
##   模型分项：每个体素源一项（项名 model_<id>；动画模型取 `frame_index` 那一帧）；
##   节点分项：NODE 里每个 kind="model" 节点一项（项名取节点名）；
##   帧分项：整个资产在每一帧的样子（项名 frame_<k>），与 .vox 的 split_by_frame 同构。
##
## 【为什么 split_by_frame 对 .qvx 不再降级】FRAM 落地后 .qvx 真的有体素动画帧了（§12.7）。
## 继续按 split_by_model 处理会让"逐帧导出"的用户拿到 N 个模型而不是 N 帧 —— 静默的错产物。
static func generate_mesh_library_from_qvx(qvx: QVoxelAsset, options: Dictionary,
		path: String = "") -> MeshLibrary:
	var lib: MeshLibrary = null
	if path != "" and FileAccess.file_exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is MeshLibrary:
			lib = res
	if lib == null:
		lib = MeshLibrary.new()
	var frame := int(options.get(VoxelMeshImporter.frame_index, 0))
	var items: Array
	match int(options[VoxelMeshLibraryImporter.mesh_mode]):
		VoxelMeshLibraryImporter.MeshMode.split_by_node:
			items = _items_by_node(qvx, frame)
		VoxelMeshLibraryImporter.MeshMode.split_by_frame:
			items = _items_by_frame(qvx)
		_:
			items = _items_by_model(qvx, frame)
	_fill_mesh_library(lib, qvx.materials, items, options, path)
	return lib


## 每个体素源一项。**动画模型不能只查 models 字典**（它们不在里面）—— 走 all_model_ids()
## 并取 `frame` 帧的块表，于是"带 FRAM 的文件按模型分项"不再少几项。
static func _items_by_model(qvx: QVoxelAsset, frame: int = 0) -> Array:
	var out: Array = []
	for mid in qvx.all_model_ids():
		out.append({"name": "model_%d" % int(mid), "chunks": qvx.frame_blocks(int(mid), frame)})
	return out


static func _items_by_node(qvx: QVoxelAsset, frame: int = 0) -> Array:
	var out: Array = []
	var used := {}
	var seq := 0
	for p in qvx.placements:
		var nm: String = String(p.get("name", ""))
		# 无名/重名时退化为稳定编号 —— 项名是 MeshLibrary 项的身份，不能撞
		while nm == "" or used.has(nm):
			nm = "node_%d" % seq
			seq += 1
		used[nm] = true
		out.append({"name": nm, "chunks": qvx.frame_blocks(int(p["model_id"]), frame)})
	return out


## 逐帧一项：整个资产在第 k 帧长什么样（与 .vox 的 split_by_frame 同构）。
## 帧数取所有动画模型的最大帧数；全静态资产 = 1 帧（即"整资产一项"）。
##
## 【为什么要按帧各算一次包围盒】原点由包围盒导出，而包围盒随帧变（§12.7 的 origin_offset）。
## 沿用第 0 帧的原点会让"第 3 帧才长出来的部分"整体偏移 —— 逐帧项各自摆正才是对的。
static func _items_by_frame(qvx: QVoxelAsset) -> Array:
	var out: Array = []
	for k in qvx.total_frame_count():
		out.append({"name": "frame_%d" % k, "chunks": qvx.block_buffers(k)})
	return out


## 按 items（[{name, chunks}]）逐项生成网格写入 MeshLibrary。
## 每项按 origin_mode 各自摆正（VoxelData.origin_offset）—— MeshLibrary 的每一项都是独立资产，
## 本就该各自有原点，否则往场景里放第 N 项时位置会带着别的模型的偏移。
static func _fill_mesh_library(lib: MeshLibrary, materials: Array, items: Array,
		options: Dictionary, path: String) -> void:
	var old_meshes: Array[ArrayMesh] = []
	for i in lib.get_item_list():
		var old := lib.get_item_mesh(i)
		if old:
			old_meshes.append(old)
	lib.clear()
	var idx := 0
	for item in items:
		var chunks: Dictionary = item["chunks"]
		if chunks.is_empty():
			continue
		var item_name: String = item["name"]
		var child := _get_mesh(item_name, path, options)
		child.clear_surfaces()
		var gen := VoxelMeshGenerator.new(null, options, path)
		gen.mesh = child
		gen.runtime_materials = materials
		gen.generate_materials(options)
		gen.start_generate_mesh_from_chunks(
				chunks, VoxelData.origin_offset(QVoxelAsset.bounds_for_blocks(chunks), gen.origin_mode))
		gen.wait_finished(options[VoxelMeshImporter.unwrap_lightmap_uv2], options[VoxelMeshImporter.uv2_texel_size])
		if child.get_surface_count() == 0:
			continue
		lib.create_item(idx)
		lib.set_item_mesh(idx, child)
		lib.set_item_name(idx, item_name)
		idx += 1
		if options[VoxelMeshLibraryImporter.import_meshes] and path:
			ResourceSaver.save(child)
	# 清掉本次未再生成的旧网格文件（与 .vox 路径同策略：按项名反查，找不到即删）
	for old in old_meshes:
		if old.resource_path != "" and lib.find_item_by_name(old.resource_name) < 0:
			DirAccess.remove_absolute(old.resource_path)


var scale: float = 1
var mesh: ArrayMesh
var voxel: VoxAsset
## .qvx 资产（与 voxel 二选一；见 generate_mesh_from_qvx）
var qvx: QVoxelAsset = null
var frame_index: int
var materials: Array[Material]
var root_path: String
## 运行时材质数组 (非空时优先于 voxel.materials 使用)
var runtime_materials: Array = []
## 材质通道图缓存（一次导入只构建一次；见 _get_channel_images）
var _channel_images: Dictionary = {}
## 导入形状 (VoxelMeshImporter.Shape): cube=面片网格, sphere=每体素一颗小球
var shape: int = VoxelMeshImporter.Shape.cube
## 球体细分级别 (icosphere)，仅 sphere 形状生效；默认 0=20 面，优先保证性能
var sphere_subdivisions: int = 0
## 小球半径相对体素边长的比例，仅 sphere 形状生效
var sphere_scale: float = 1.0
## 资产原点模式（导入选项 mesh/origin，见 VoxelData.OriginMode）：决定顶点叠加多少原点偏移。
## 四条链路共用同一套语义，故这里只把选项读进来，再交给 VoxelData.origin_offset 算。
## 默认 WORLD_ORIGIN = 不动几何（本插件网格导入一直以来的行为）。
var origin_mode: int = VoxelData.OriginMode.WORLD_ORIGIN

## 顶点预算：超出则由原生按采样间隔自动降采样，防止大模型在编辑器内 OOM 崩溃
const SPHERE_VERTEX_BUDGET := 4_000_000
## 原生几何内核返回的 arrays（start_generate_mesh 填充，wait_finished 消费）
var _native_arrays: Dictionary = {}


func _init(voxel: VoxAsset, options: Dictionary, path: String = "") -> void:
	self.root_path = path
	self.voxel = voxel
	frame_index = options.get(VoxelMeshImporter.frame_index, 0)
	scale = options.get(VoxelMeshImporter.scale, 0.1)
	if scale <= 0:
		scale = 0.01
	shape = options.get(VoxelMeshImporter.shape, VoxelMeshImporter.Shape.cube)
	sphere_subdivisions = clampi(options.get(VoxelMeshImporter.sphere_subdivisions, 0), 0, 2)
	sphere_scale = clampf(options.get(VoxelMeshImporter.sphere_scale, 1.0), 0.05, 2.0)
	origin_mode = options.get(VoxelMeshImporter.origin, VoxelData.OriginMode.WORLD_ORIGIN)


func generate_materials(options: Dictionary) -> Array[Material]:
	materials.resize(2)
	var path := root_path if options[VoxelMeshImporter.import_materials_textures] else ""
	materials[0] = generate_material(path)
	materials[1] = generate_material_trans(materials[0], path)
	return materials

func generate_material(save_path: String = "") -> StandardMaterial3D:
	var path := save_path.get_basename() + '/mat.tres'
	if save_path:
		DirAccess.make_dir_absolute(save_path.get_basename())
	var material: Material = ResourceLoader.load(path) if FileAccess.file_exists(path) else StandardMaterial3D.new()
	if material is StandardMaterial3D:
		_configure_solid_material(material)
		material.albedo_texture = generate_albedo_texture(save_path)
		material.metallic_texture = generate_metal_texture(save_path)
		material.roughness_texture = generate_rough_texture(save_path)
		material.emission_texture = generate_emission_texture(save_path)
		if save_path:
			material.resource_path = path
			ResourceSaver.save(material)
	else:
		generate_albedo_texture(save_path)
		generate_metal_texture(save_path)
		generate_rough_texture(save_path)
		generate_emission_texture(save_path)
	return material

func generate_material_trans(base: Material, save_path: String = "") -> StandardMaterial3D:
	var path := save_path.get_basename() + '/mat_trans.tres'
	DirAccess.make_dir_absolute(save_path.get_basename())
	var material: Material = ResourceLoader.load(path) if FileAccess.file_exists(path) else base.duplicate() if base else StandardMaterial3D.new()
	if material is StandardMaterial3D:
		_configure_trans_material(material)
		if save_path:
			material.resource_path = path
			ResourceSaver.save(material)
	else:
		pass
	return material

func _generate_texture(save_path: String, type: String) -> ImageTexture:
	# 复用统一的通道图生成，避免与运行时纹理两套采样逻辑漂移
	var image: Image = _get_channel_images()[type]
	DirAccess.make_dir_absolute(save_path.get_basename())
	var path := save_path.get_basename() + '/tex_' + type + '.tres'
	var texture: ImageTexture = ResourceLoader.load(path) if FileAccess.file_exists(path) else ImageTexture.create_from_image(image)
	texture.set_image(image)
	if save_path:
		texture.resource_path = path
		ResourceSaver.save(texture)
	return texture

func generate_albedo_texture(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "albedo")

func generate_metal_texture(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "metal")

func generate_rough_texture(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "rough")

func generate_emission_texture(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "emission")


## 请求生成网格：几何内核统一下沉 C++（NativeLoader）。
## cube = 面片贪婪合并；sphere = 每体素一颗小球（原生内部按顶点预算自动降采样）。
## 结果为原生 arrays，实际组装成 surface 在 wait_finished 完成。
func start_generate_mesh(voxels: Dictionary[Vector3i, int]) -> void:
	# hash 必须包含所有影响几何的选项：MeshLibrary 模式会复用磁盘上的旧 mesh(带 meta)，
	# 若只含体素数据，单独修改 scale/sphere_* 时会被短路、保留旧网格
	var voxels_hash := hash([voxels.hash(), scale, shape, sphere_subdivisions, sphere_scale, origin_mode])
	_native_arrays = {}
	if not mesh:
		mesh = ArrayMesh.new()
	else:
		if mesh.has_meta("hash") and voxels_hash == mesh.get_meta("hash"):
			return
		mesh.clear_surfaces()
	mesh.set_meta("hash", voxels_hash)

	if voxels.size() == 0:
		return

	var trans_flags := VoxelMaterial.build_trans_flags(
			runtime_materials if not runtime_materials.is_empty() else voxel.materials)
	# 原点偏移（体素单位）：按内容 AABB 算一次交给原生内核（cube 路径原生就支持 offset，
	# 不必事后搬运顶点）。WORLD_ORIGIN 模式跳过求界——那是一次 O(体素数) 的字典扫描。
	var offset := Vector3.ZERO
	if origin_mode != VoxelData.OriginMode.WORLD_ORIGIN:
		offset = VoxelData.origin_offset(VoxelData.voxel_bounds(voxels), origin_mode)
	if shape == VoxelMeshImporter.Shape.sphere:
		# offset 为体素单位，原生内部乘 scale（与 cube 路径同一约定）——不必再事后遍历平移顶点。
		_native_arrays = NativeLoader.generate_spheres_native(
			voxels, trans_flags, sphere_subdivisions, sphere_scale, scale, SPHERE_VERTEX_BUDGET, offset)
	else:
		_native_arrays = NativeLoader.generate_arrays_native(voxels, trans_flags, scale, offset)


## 由块缓冲生成网格（QVX 路径的实例入口：整资产 / MeshLibrary 分项共用）。
## layout_offset 为体素单位的原点偏移（见 VoxelData.origin_offset）。
func start_generate_mesh_from_chunks(chunks: Dictionary, layout_offset: Vector3) -> void:
	_reset_mesh()
	_native_arrays = {}
	if chunks.is_empty():
		return
	var materials_src: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	_native_arrays = NativeLoader.generate_arrays_from_chunks_native(
			chunks, VoxelMaterial.build_trans_flags(materials_src), scale, layout_offset)


## 生成整个 QVX 资产：恒等摆放走块级（零逐体素展开），有变换时逐体素融合。
func start_generate_mesh_from_qvx() -> void:
	_reset_mesh()
	_native_arrays = {}
	if qvx == null or qvx.is_empty():
		return
	var materials_src: Array = runtime_materials if not runtime_materials.is_empty() else qvx.materials
	var trans_flags := VoxelMaterial.build_trans_flags(materials_src)
	# 原点偏移与 .vox 路径同一套（qvx.origin_offset 内部调 VoxelData.origin_offset）。
	# 单网格取第 frame_index 帧（静态资产恒等于第 0 帧，§12.7）—— 于是"逐帧导出"只需改这一个选项。
	var offset := qvx.origin_offset(origin_mode, frame_index)
	if qvx.is_block_importable():
		_native_arrays = NativeLoader.generate_arrays_from_chunks_native(
				qvx.block_buffers(frame_index), trans_flags, scale, offset)
	else:
		_native_arrays = NativeLoader.generate_arrays_native(
				qvx.fused_voxels(frame_index), trans_flags, scale, offset)


func _reset_mesh() -> void:
	if mesh == null:
		mesh = ArrayMesh.new()
	else:
		mesh.clear_surfaces()


## 完成生成：把原生 arrays 组装为 surface，并按需展开 lightmap UV2
func wait_finished(gen_uv2: bool, uv2_texel_size: float) -> ArrayMesh:
	_append_native_surfaces()
	# 球体路径与旧行为一致：不在 wait_finished 内展开 UV2
	if shape != VoxelMeshImporter.Shape.sphere and gen_uv2:
		mesh.lightmap_unwrap(Transform3D.IDENTITY, uv2_texel_size)
	return mesh


## 把原生几何内核返回的 arrays 变成 surface（0=实体 / 1=透明），并绑定对应材质
func _append_native_surfaces() -> void:
	if _native_arrays.is_empty():
		return
	for i in 2:
		var prefix := "solid" if i == 0 else "trans"
		var arrays := _surface_arrays(_native_arrays, prefix)
		if arrays.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		# 空桶已跳过，材质须绑定到实际 surface 序号
		mesh.surface_set_material(mesh.get_surface_count() - 1, materials[i])
	_native_arrays = {}


## 从原生 arrays 中提取单个桶(实体/透明)的 surface 数组，无三角形时返回空数组
static func _surface_arrays(native_arrays: Dictionary, prefix: String) -> Array:
	var idxs: PackedInt32Array = native_arrays.get(prefix + "_idxs", PackedInt32Array())
	if idxs.is_empty():
		return []
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = native_arrays[prefix + "_verts"]
	arrays[Mesh.ARRAY_NORMAL] = native_arrays[prefix + "_normals"]
	arrays[Mesh.ARRAY_TEX_UV] = native_arrays[prefix + "_uvs"]
	arrays[Mesh.ARRAY_INDEX] = idxs
	return arrays