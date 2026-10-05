class_name VoxelMeshGenerator
## 体素网格生成器（编辑器导入路径）
## 几何内核统一下沉 C++（NativeLoader → VoxelNative），与运行时管线共用同一套实现：
##   cube   面片网格（分方向可见性 + 贪婪合并）
##   sphere 每体素一颗 icosphere（自动按顶点预算降采样）
## 此处只负责：材质纹理、MeshLibrary 分割编排，以及把原生 arrays 交给引擎 API 组装。


static func generate_mesh(voxel: VoxData, options: Dictionary, path: String = "") -> ArrayMesh:
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

static func generate_mesh_library(voxel: VoxData, options: Dictionary, path: String = "") -> MeshLibrary:
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
		var mesh := ResourceLoader.load(child_path) as ArrayMesh if FileAccess.file_exists(path) else null
		if not mesh:
			mesh = ArrayMesh.new()
			mesh.resource_path = child_path
			mesh.resource_name = name
		return mesh
	else:
		return ArrayMesh.new()

var scale: float = 1
var mesh: ArrayMesh
var voxel: VoxData
var frame_index: int
var materials: Array[Material]
var root_path: String
## 运行时材质数组 (非空时优先于 voxel.materials 使用)
var runtime_materials: Array = []
## 导入形状 (VoxelMeshImporter.Shape): cube=面片网格, sphere=每体素一颗小球
var shape: int = VoxelMeshImporter.Shape.cube
## 球体细分级别 (icosphere)，仅 sphere 形状生效；默认 0=20 面，优先保证性能
var sphere_subdivisions: int = 0
## 小球半径相对体素边长的比例，仅 sphere 形状生效
var sphere_scale: float = 1.0

## 顶点预算：超出则由原生按采样间隔自动降采样，防止大模型在编辑器内 OOM 崩溃
const SPHERE_VERTEX_BUDGET := 4_000_000
## 原生几何内核返回的 arrays（start_generate_mesh 填充，wait_finished 消费）
var _native_arrays: Dictionary = {}


func _init(voxel: VoxData, options: Dictionary, path: String = "") -> void:
	self.root_path = path
	self.voxel = voxel
	frame_index = options.get(VoxelMeshImporter.frame_index, 0)
	scale = options.get(VoxelMeshImporter.scale, 0.1)
	if scale <= 0:
		scale = 0.01
	shape = options.get(VoxelMeshImporter.shape, VoxelMeshImporter.Shape.cube)
	sphere_subdivisions = clampi(options.get(VoxelMeshImporter.sphere_subdivisions, 0), 0, 2)
	sphere_scale = clampf(options.get(VoxelMeshImporter.sphere_scale, 1.0), 0.05, 2.0)

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
		material.albedo_texture = generate_albedo_textrue(save_path)
		material.metallic_texture = generate_metal_textrue(save_path)
		material.roughness_texture = generate_rough_textrue(save_path)
		material.emission_texture = generate_emission_textrue(save_path)
		if save_path:
			material.resource_path = path
			ResourceSaver.save(material)
	else:
		generate_albedo_textrue(save_path)
		generate_metal_textrue(save_path)
		generate_rough_textrue(save_path)
		generate_emission_textrue(save_path)
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
	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	var images := _build_channel_images(mats)
	var image: Image = images[type]
	DirAccess.make_dir_absolute(save_path.get_basename())
	var path := save_path.get_basename() + '/tex_' + type + '.tres'
	var texture: ImageTexture = ResourceLoader.load(path) if FileAccess.file_exists(path) else ImageTexture.create_from_image(image)
	texture.set_image(image)
	if save_path:
		texture.resource_path = path
		ResourceSaver.save(texture)
	return texture

func generate_albedo_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "albedo")

func generate_metal_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "metal")

func generate_rough_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "rough")

func generate_emission_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(save_path, "emission")


## 请求生成网格：几何内核统一下沉 C++（NativeLoader）。
## cube = 面片贪婪合并；sphere = 每体素一颗小球（原生内部按顶点预算自动降采样）。
## 结果为原生 arrays，实际组装成 surface 在 wait_finished 完成。
func start_generate_mesh(voxels: Dictionary[Vector3i, int]) -> void:
	# hash 必须包含所有影响几何的选项：MeshLibrary 模式会复用磁盘上的旧 mesh(带 meta)，
	# 若只含体素数据，单独修改 scale/sphere_* 时会被短路、保留旧网格
	var voxels_hash := hash([voxels.hash(), scale, shape, sphere_subdivisions, sphere_scale])
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
	if not NativeLoader.is_available():
		push_error("[VoxelMeshGenerator] 网格生成需要原生库 VoxelNative（未加载）")
		return

	var trans_flags := _build_trans_flags()
	if shape == VoxelMeshImporter.Shape.sphere:
		_native_arrays = NativeLoader.generate_spheres_native(
			voxels, trans_flags, sphere_subdivisions, sphere_scale, scale, SPHERE_VERTEX_BUDGET)
	else:
		_native_arrays = NativeLoader.generate_arrays_native(voxels, trans_flags, scale, Vector3.ZERO)


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


## 材质透明标志表（索引=材质ID，1=透明），供原生几何内核判定面可见性并分桶
func _build_trans_flags() -> PackedByteArray:
	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	var flags := PackedByteArray()
	flags.resize(mats.size())
	for i in mats.size():
		var m: VoxelMaterial = mats[i]
		flags[i] = 1 if (m != null and m.trans > 0) else 0
	return flags