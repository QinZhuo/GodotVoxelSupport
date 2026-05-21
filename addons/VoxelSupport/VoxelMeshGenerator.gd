class_name VoxelMeshGenerator
## 体素网格生成器
## 会将数据分为6个方向 并多线程计算网格


static func generate_mesh(voxel: VoxelData, options: Dictionary, path: String = "") -> ArrayMesh:
	var gen := VoxelMeshGenerator.new(voxel, options, path)
	gen.generate_materials(options)
	var time := Time.get_ticks_usec()
	gen.start_generate_mesh(voxel.get_voxels(gen.frame_index))
	gen.wait_finished(options[VoxelMeshImporter.unwrap_lightmap_uv2], options[VoxelMeshImporter.uv2_texel_size])
	if not gen.mesh:
		return null
	if options[VoxelMeshImporter.unwrap_lightmap_uv2]:
		gen.mesh.lightmap_unwrap(Transform3D.IDENTITY, options[VoxelMeshImporter.uv2_texel_size])
	prints("generate_mesh mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms", gen.mesh.get_faces().size() / 6, "face")
	return gen.mesh

static func generate_mesh_library(voxel: VoxelData, options: Dictionary, path: String = "") -> MeshLibrary:
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
			printerr("delete ", old_mesh.resource_path)
	prints("generate_mesh_library mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms")
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
var voxel: VoxelData
var frame_index: int
var materials: Array[Material]
var root_path: String


func _init(voxel: VoxelData, options: Dictionary, path: String = "") -> void:
	self.root_path = path
	self.voxel = voxel
	frame_index = options[VoxelMeshImporter.frame_index]
	scale = options[VoxelMeshImporter.scale]
	if scale <= 0:
		scale = 0.01

func change_mesh_scale(scale: float):
	if mesh:
		var mesh_tool = MeshDataTool.new()
		var new_mesh = ArrayMesh.new()
		for si in mesh.get_surface_count():
			mesh_tool.create_from_surface(mesh, si)
			for i in mesh_tool.get_vertex_count():
				mesh_tool.set_vertex(i, mesh_tool.get_vertex(i) * scale)
			mesh_tool.commit_to_surface(new_mesh, si)
		mesh = new_mesh


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
		if save_path:
			material.resource_path = path
			ResourceSaver.save(material)
	else:
		pass
	return material

func _generate_texture(get_pixel: Callable, save_path: String, type: String) -> ImageTexture:
	var image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for x in 256:
		var color: Color = get_pixel.call(voxel.materials[x])
		image.set_pixel(x, 0, color)
	DirAccess.make_dir_absolute(save_path.get_basename())
	var path := save_path.get_basename() + '/tex_' + type + '.tres'
	var texture: ImageTexture = ResourceLoader.load(path) if FileAccess.file_exists(path) else ImageTexture.create_from_image(image)
	texture.set_image(image)
	if save_path:
		texture.resource_path = path
		ResourceSaver.save(texture)
	return texture

func generate_albedo_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelData.VoxelMaterial): return m.color if not m.is_transparent else Color(m.color.r, m.color.g, m.color.b, 1 - m.trans), save_path, "albedo")

func generate_metal_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelData.VoxelMaterial): return Color.from_hsv(0, 0, m.metal), save_path, "metal")

func generate_rough_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelData.VoxelMaterial): return Color.from_hsv(0, 0, m.rough), save_path, "rough")

func generate_emission_textrue(save_path: String = "") -> ImageTexture:
	return _generate_texture(func(m: VoxelData.VoxelMaterial): return m.color * m.emission, save_path, "emission")


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
				var slice = slices[slice_index]
				var pos: Vector3i
				pos[axis.x] = slice_index
				for y in range(pos_min[axis.y], pos_max[axis.y] + 1):
					pos[axis.y] = y
					for z in range(pos_min[axis.z], pos_max[axis.z] + 1):
						pos[axis.z] = z
						if slice_voxels_visible.has(pos):
							_generate_voxel_dir_face(slice_voxels_visible, axis, pos, task.dir, surfaces)
	task.meshes = [surfaces[0].commit(), surfaces[1].commit()]


func _get_dir_visible_slice_voxels(slices: Dictionary, axis: Vector3i, dir: int, slice_index: int) -> Dictionary:
	var voxels := {}
	var offset := Vector3i(FaceTool.Normals[dir])
	var slice: Dictionary = slices[slice_index]
	var dir_slice_index := slice_index + offset[axis.x]

	if not slices.has(dir_slice_index):
		return slice.duplicate()

	var dir_slice = slices[dir_slice_index]
	for pos: Vector3i in slice:
		var visible := false
		var dir_pos: Vector3i = pos + offset
		if dir_slice.has(dir_pos):
			var mat := voxel.materials[slice[pos]]
			var dir_mat := voxel.materials[dir_slice[dir_pos]]
			if mat.is_transparent != dir_mat.is_transparent:
				visible = true
			elif mat.is_transparent and mat != dir_mat:
				visible = true
		else:
			visible = true
		if visible:
			voxels[pos] = slice[pos]
	return voxels

func _generate_voxel_dir_face(voxels: Dictionary, axis: Vector3i, pos: Vector3i, dir: int, surfaces: Array[SurfaceTool]) -> void:
	var length: int = _get_max_length(voxels, pos, axis.y)
	var width: int = _get_max_width(voxels, pos, axis.z, axis.y, length)
	var size: Vector3 = Vector3.ONE
	size[axis.y] = length
	size[axis.z] = width
	_generate_size_dir_face(voxels, axis, pos, size, dir, surfaces)


func _generate_size_dir_face(voxels: Dictionary, axis: Vector3i, pos: Vector3i, size: Vector3, dir: int, surfaces: Array[SurfaceTool]):
	var id: int = voxels[pos]
	var uv := Vector2((id + 0.5) / 256.0, 0.5)

	var surface := surfaces[0] if not voxel.materials[id].is_transparent else surfaces[1]

	surface.set_normal(FaceTool.Normals[dir])
	for point: Vector3 in FaceTool.Faces[dir]:
		surface.set_uv(uv)
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


func _get_max_length(voxels: Dictionary, pos: Vector3i, axis: int, max_length: int = -1) -> int:
	var value: int = voxels[pos]
	var cur_pos: Vector3i = pos
	cur_pos[axis] += 1
	var size := 1

	while voxels.has(cur_pos) and voxels[cur_pos] == value:
		cur_pos[axis] += 1
		size += 1
		if max_length > 0 and size >= max_length:
			break
	return size

func _get_max_width(voxels: Dictionary, pos: Vector3i, width_axis: int, length_axis: int, length: int) -> int:
	var value: int = voxels[pos]
	var cur_pos: Vector3i = pos
	cur_pos[width_axis] += 1
	var size := 1

	while voxels.has(cur_pos) and voxels[cur_pos] == value and _get_max_length(voxels, cur_pos, length_axis, length) >= length:
		cur_pos[width_axis] += 1
		size += 1
	return size
