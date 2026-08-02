class_name VoxelMeshGenerator
## 体素网格生成器
## 会将数据分为6个方向 并多线程计算网格


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


## 运行时网格生成入口
## 直接接受体素字典和材质数组，无需 VoxData 实例
## 供 VoxelRenderer / VoxelDestructible 等运行时节点使用
## options 可包含: scale, unwrap_lightmap_uv2, uv2_texel_size (均可选)
static func generate_mesh_runtime(voxels: Dictionary[Vector3i, int], materials: Array, options: Dictionary = {}) -> ArrayMesh:
	if voxels.is_empty():
		return null
	var gen := VoxelMeshGenerator.new(null, options, "")
	# 统一对齐材质数组：确保"材质数组索引 == 材质ID"，避免内部 mats[id] 越界
	gen.runtime_materials = VoxelMaterial.align_by_id(materials)
	# 运行时不生成纹理材质资源，由调用方提供或使用默认材质
	gen.materials = [options.get("material_solid", null), options.get("material_transparent", null)]
	var time := Time.get_ticks_usec()
	gen.start_generate_mesh(voxels)
	var mesh := gen.wait_finished(options.get(VoxelMeshImporter.unwrap_lightmap_uv2, false), options.get(VoxelMeshImporter.uv2_texel_size, 0.2))
	if not mesh:
		return null
	if options.get(VoxelMeshImporter.unwrap_lightmap_uv2, false):
		mesh.lightmap_unwrap(Transform3D.IDENTITY, options.get(VoxelMeshImporter.uv2_texel_size, 0.2))
	if Engine.is_editor_hint():
		print_verbose("generate_mesh_runtime: ", (Time.get_ticks_usec() - time) / 1000.0, "ms")
	return mesh


## 从材质数组生成运行时纹理材质 (StandardMaterial3D 数组，0=实体 1=透明)
## 与编辑器导入的纹理材质等价，但完全在内存中生成，不涉及文件 IO
## 复用与编辑器导入一致的 UV 采样方案 (纹素中心对齐材质ID)
## 材质→颜色采样公式统一在 VoxelMaterial 中
static func generate_textured_materials_runtime(materials: Array) -> Array:
	var result: Array = [null, null]
	var images := _build_channel_images(materials)
	var solid := StandardMaterial3D.new()
	solid.emission_enabled = true
	solid.emission_energy_multiplier = 20
	solid.metallic = 1
	solid.albedo_texture = ImageTexture.create_from_image(images["albedo"])
	solid.metallic_texture = ImageTexture.create_from_image(images["metal"])
	solid.roughness_texture = ImageTexture.create_from_image(images["rough"])
	solid.emission_texture = ImageTexture.create_from_image(images["emission"])
	solid.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	result[0] = solid
	var trans := solid.duplicate()
	trans.refraction_enabled = true
	trans.refraction_scale = 0.01
	trans.emission_enabled = false
	trans.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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

var pos_min: Vector3i
var pos_max: Vector3i
var slice_voxels: Array[Dictionary]
var scale: float = 1
var tasks: Array
var mesh: ArrayMesh
var voxel: VoxData
var frame_index: int
var materials: Array[Material]
var root_path: String
## 运行时材质数组 (非空时优先于 voxel.materials 使用)
var runtime_materials: Array = []


func _init(voxel: VoxData, options: Dictionary, path: String = "") -> void:
	self.root_path = path
	self.voxel = voxel
	frame_index = options.get(VoxelMeshImporter.frame_index, 0)
	scale = options.get(VoxelMeshImporter.scale, 0.1)
	if scale <= 0:
		scale = 0.01

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
		material.emission_enabled = true
		material.emission_energy_multiplier = 20
		material.metallic = 1
		material.albedo_texture = generate_albedo_textrue(save_path)
		material.metallic_texture = generate_metal_textrue(save_path)
		material.roughness_texture = generate_rough_textrue(save_path)
		material.emission_texture = generate_emission_textrue(save_path)
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
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
		material.refraction_enabled = true
		material.refraction_scale = 0.01
		material.emission_enabled = false
		material.transparency = BaseMaterial3D.Transparency.TRANSPARENCY_ALPHA
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		if save_path:
			material.resource_path = path
			ResourceSaver.save(material)
	else:
		pass
	return material

func _generate_texture(get_pixel: Callable, save_path: String, type: String) -> ImageTexture:
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
	return _generate_texture(func(m: VoxelMaterial): return VoxelMaterial.albedo_color(m), save_path, "albedo")

func generate_metal_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelMaterial): return VoxelMaterial.metal_color(m), save_path, "metal")

func generate_rough_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelMaterial): return VoxelMaterial.rough_color(m), save_path, "rough")

func generate_emission_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelMaterial): return VoxelMaterial.emission_color(m), save_path, "emission")


func start_generate_mesh(voxels: Dictionary[Vector3i, int]) -> void:
	var voxels_hash := voxels.hash()
	if not mesh:
		mesh = ArrayMesh.new()
	else:
		if mesh.has_meta("hash") and voxels_hash == mesh.get_meta("hash"):
			return
		mesh.clear_surfaces()
	mesh.set_meta("hash", voxels_hash)
	pos_min = Vector3i.MAX
	pos_max = Vector3i.MIN

	if voxels.size() == 0:
		return

	slice_voxels = [ {}, {}, {}]
	for pos in voxels:
		pos_min.x = min(pos_min.x, pos.x)
		pos_min.y = min(pos_min.y, pos.y)
		pos_min.z = min(pos_min.z, pos.z)
		pos_max.x = max(pos_max.x, pos.x)
		pos_max.y = max(pos_max.y, pos.y)
		pos_max.z = max(pos_max.z, pos.z)
		for axis in 3:
			var slice_index := pos[axis]
			var slices := slice_voxels[axis]
			if not slices.has(slice_index):
				slices[slice_index] = {}
			slices[slice_index][pos] = voxels[pos]

	tasks.clear()
	for dir in FaceTool.Faces.size():
		var task = {dir = dir}
		tasks.append(task)
		task.id = WorkerThreadPool.add_task(_generate_dir_face.bind(task))

func wait_finished(gen_uv2: bool, uv2_texel_size: float) -> ArrayMesh:
	if tasks.size() > 0:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for task in tasks:
			WorkerThreadPool.wait_for_task_completion(task.id)
		for i in 2:
			for task in tasks:
				if "meshes" in task:
					var child_mesh: ArrayMesh = task.meshes[i]
					if child_mesh.get_surface_count() > 0:
						surface.append_from(child_mesh, 0, Transform3D.IDENTITY)
			surface.set_material(materials[i])
			surface.commit(mesh)
			surface.clear()
		tasks.clear()
		if gen_uv2:
			mesh.lightmap_unwrap(Transform3D.IDENTITY, uv2_texel_size)
	return mesh

func _generate_dir_face(task) -> void:
	var surfaces: Array[SurfaceTool] = [SurfaceTool.new(), SurfaceTool.new()]
	for surface in surfaces:
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var axis := FaceTool.SliceAxis[task.dir]
	var slices := slice_voxels[axis.x]
	for slice_index in range(pos_min[axis.x], pos_max[axis.x] + 1):
		if slices.has(slice_index):
			var slice_voxels_visible = _get_dir_visible_slice_voxels(slices, axis, task.dir, slice_index)
			if slice_voxels_visible.size() > 0:
				# 转换为 2D 网格，使用共享贪婪合并器
				var grid := {}
				for p: Vector3i in slice_voxels_visible:
					grid[Vector2i(p[axis.y], p[axis.z])] = slice_voxels_visible[p]
				var rects: Array[VoxelGreedyMesher.RectInfo] = VoxelGreedyMesher.greedy_merge(grid)
				for rect in rects:
					var pos: Vector3i
					pos[axis.x] = slice_index
					pos[axis.y] = rect.position.x
					pos[axis.z] = rect.position.y
					var size: Vector3 = Vector3.ONE
					size[axis.y] = rect.size.x
					size[axis.z] = rect.size.y
					_generate_size_dir_face(slice_voxels_visible, axis, pos, size, task.dir, surfaces)
	task.meshes = [surfaces[0].commit(), surfaces[1].commit()]


func _get_dir_visible_slice_voxels(slices: Dictionary, axis: Vector3i, dir: int, slice_index: int) -> Dictionary:
	var voxels := {}
	var offset := Vector3i(FaceTool.Normals[dir])
	var slice: Dictionary = slices[slice_index]
	var dir_slice_index := slice_index + offset[axis.x]

	if not slices.has(dir_slice_index):
		return slice.duplicate()

	var dir_slice = slices[dir_slice_index]
	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	for pos: Vector3i in slice:
		var visible := false
		var dir_pos: Vector3i = pos + offset
		if dir_slice.has(dir_pos):
			var mat: VoxelMaterial = mats[slice[pos]]
			var dir_mat: VoxelMaterial = mats[dir_slice[dir_pos]]
			if (mat.trans > 0) != (dir_mat.trans > 0):
				visible = true
			elif mat.trans > 0 and mat != dir_mat:
				visible = true
		else:
			visible = true
		if visible:
			voxels[pos] = slice[pos]
	return voxels

func _generate_size_dir_face(voxels: Dictionary, axis: Vector3i, pos: Vector3i, size: Vector3, dir: int, surfaces: Array[SurfaceTool]):
	var id: int = voxels[pos]

	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	var surface := surfaces[0] if mats[id].trans <= 0 else surfaces[1]

	surface.set_normal(FaceTool.Normals[dir])
	# UV采样纹素中心，避免落在边界上导致取色偏移 (统一公式见 VoxelMaterial.uv_for_id)
	var u := VoxelMaterial.uv_for_id(id)
	var v := 0.5
	for point: Vector3 in FaceTool.Faces[dir]:
		surface.set_uv(Vector2(u, v))
		surface.add_vertex((point * size + Vector3(pos)) * scale)

	var cur_pos := pos
	var y_max := size[axis.y]
	var z_max := size[axis.z]
	for y in y_max:
		cur_pos[axis.z] = pos[axis.z]
		for z in z_max:
			voxels.erase(cur_pos)
			cur_pos[axis.z] += 1
		cur_pos[axis.y] += 1
