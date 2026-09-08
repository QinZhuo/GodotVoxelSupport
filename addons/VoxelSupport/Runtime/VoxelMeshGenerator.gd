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
## 导入形状 (VoxelMeshImporter.Shape): cube=面片网格, sphere=每体素一颗小球
var shape: int = VoxelMeshImporter.Shape.cube
## 球体细分级别 (icosphere)，仅 sphere 形状生效；默认 0=20 面，优先保证性能
var sphere_subdivisions: int = 0
## 小球半径相对体素边长的比例，仅 sphere 形状生效
var sphere_scale: float = 1.0
## sphere 模式下待同步生成的球心集合 (start_generate_mesh 填充，wait_finished 消费)
var _sphere_cells: Dictionary[Vector3i, int] = {}
## 实际生效的采样间隔：由顶点预算自动推导，无外部设置项
var _sphere_step_used: int = 1

## 顶点预算：超出则自动放大采样间隔，防止大模型在编辑器内 OOM 崩溃
const SPHERE_VERTEX_BUDGET := 4_000_000


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
	# hash 必须包含所有影响几何的选项：MeshLibrary 模式会复用磁盘上的旧 mesh(带 meta)，
	# 若只含体素数据，单独修改 scale/sphere_* 时会被短路、保留旧网格
	var voxels_hash := hash([voxels.hash(), scale, shape, sphere_subdivisions, sphere_scale])
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

	var solid_voxels: Dictionary[Vector3i, int] = {}
	for pos in voxels:
		# 统一材质契约：材质ID 0 = 空（空气），跳过不参与网格与包围盒
		if voxels[pos] <= 0:
			continue
		solid_voxels[pos] = voxels[pos]
		pos_min.x = min(pos_min.x, pos.x)
		pos_min.y = min(pos_min.y, pos.y)
		pos_min.z = min(pos_min.z, pos.z)
		pos_max.x = max(pos_max.x, pos.x)
		pos_max.y = max(pos_max.y, pos.y)
		pos_max.z = max(pos_max.z, pos.z)

	if solid_voxels.size() == 0:
		return

	if shape == VoxelMeshImporter.Shape.sphere:
		# 球体模式：每颗小球代表一个(可能降采样的)体素格子
		_sphere_cells = _select_sphere_cells(solid_voxels)
		tasks.clear()
		return

	slice_voxels = [ {}, {}, {}]
	for pos in solid_voxels:
		for axis in 3:
			var slice_index := pos[axis]
			var slices := slice_voxels[axis]
			if not slices.has(slice_index):
				slices[slice_index] = {}
			slices[slice_index][pos] = solid_voxels[pos]

	tasks.clear()
	for dir in FaceTool.Faces.size():
		var task = {dir = dir}
		tasks.append(task)
		task.id = WorkerThreadPool.add_task(_generate_dir_face.bind(task))


## 球体模式：按 step 降采样体素为格子，格子材质取第一个非空材质（与 LOD 降采样规则一致）
func _downsample_to_cells(voxels: Dictionary[Vector3i, int], step: int) -> Dictionary[Vector3i, int]:
	if step <= 1:
		return voxels
	var cells: Dictionary[Vector3i, int] = {}
	for pos: Vector3i in voxels:
		var key := Vector3i(_floor_div(pos.x, step), _floor_div(pos.y, step), _floor_div(pos.z, step))
		if not cells.has(key):
			cells[key] = voxels[pos]
	return cells


static func _floor_div(v: int, d: int) -> int:
	var q: int = v / d
	if q * d > v:
		q -= 1
	return q


## 球体模式：只保留至少有一格外露的格子
## 完全被实心邻居包裹的格子不可见，跳过可大幅减少三角形数量
func _collect_surface_cells(cells: Dictionary[Vector3i, int]) -> Dictionary[Vector3i, int]:
	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	var result: Dictionary[Vector3i, int] = {}
	for pos: Vector3i in cells:
		var id: int = cells[pos]
		for dir in FaceTool.Normals.size():
			var n_pos: Vector3i = pos + Vector3i(FaceTool.Normals[dir])
			if not cells.has(n_pos):
				result[pos] = id
				break
			if FaceTool.face_visible(mats[id], mats[cells[n_pos]]):
				result[pos] = id
				break
	return result


## 球体模式：按顶点预算自动推导采样间隔，返回最终球心格子集合
## 大模型(数十万外露体素)若不降采样会直接 OOM 崩溃，故预算优先于精度
## 先用包围盒表面积估算所需 step，避免反复全量扫描；step 不作为外部设置项
func _select_sphere_cells(voxels: Dictionary[Vector3i, int]) -> Dictionary[Vector3i, int]:
	var verts_per_sphere: int = FaceTool.get_icosphere(sphere_subdivisions)["vertices"].size()
	var dims := (pos_max - pos_min) + Vector3i.ONE
	var surface_est := 2 * (dims.x * dims.y + dims.y * dims.z + dims.z * dims.x)
	# cells_at_step ~= surface_est / step^2，要求 cells*verts <= budget
	var step := 1
	var need := int(ceil(sqrt(float(surface_est) * verts_per_sphere / float(SPHERE_VERTEX_BUDGET))))
	while step < need and step < 32:
		step *= 2
	var cells := _collect_surface_cells(_downsample_to_cells(voxels, step))
	# 估算偏低时兜底放大（最多一次全量重扫）
	while cells.size() * verts_per_sphere > SPHERE_VERTEX_BUDGET and step < 32:
		step *= 2
		cells = _collect_surface_cells(_downsample_to_cells(voxels, step))
	_sphere_step_used = step
	if step > 1:
		print("voxel sphere: auto step ", step, " (spheres=", cells.size(),
			", budget=", SPHERE_VERTEX_BUDGET, " verts)")
	return cells


func wait_finished(gen_uv2: bool, uv2_texel_size: float) -> ArrayMesh:
	if shape == VoxelMeshImporter.Shape.sphere:
		if _sphere_cells.size() > 0:
			_build_sphere_mesh(_sphere_cells)
			_sphere_cells = {}
		return mesh
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

## 球体模式：为每颗球心放置一颗 icosphere，按材质透明度分到 0=实体 / 1=透明 两个 surface
## 与 cube 路径共用同一套材质与 UV 采样契约 (VoxelMaterial.uv_for_id)
## 直接构建 ArrayMesh（共享顶点 + 索引缓冲），比 SurfaceTool 逐顶点快一个数量级
func _build_sphere_mesh(cells: Dictionary[Vector3i, int]) -> void:
	var template := FaceTool.get_icosphere(sphere_subdivisions)
	var unit_verts: PackedVector3Array = template["vertices"]
	var unit_indices: PackedInt32Array = template["indices"]
	var nv: int = unit_verts.size()
	var ni: int = unit_indices.size()

	var mats: Array = runtime_materials if not runtime_materials.is_empty() else voxel.materials
	var step_f := float(_sphere_step_used)
	var radius := 0.5 * sphere_scale * step_f * scale
	# 球心落在格子中心：格子 key 覆盖体素 [key*step, key*step+step)，中心 = key*step + step/2
	# step=1 时即体素中心 (pos+0.5)，与 cube 路径的包围盒对齐
	var origin := Vector3(step_f * 0.5, step_f * 0.5, step_f * 0.5)

	# 第一遍：按 实体/透明 分桶（s=0 实体，s=1 透明），并预取球心，避免第二遍重复字典查找
	var bucket_pos: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
	var bucket_id: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
	for pos: Vector3i in cells:
		var id: int = cells[pos]
		var mat: VoxelMaterial = mats[id] if id < mats.size() else null
		var s := 0 if (mat == null or mat.trans <= 0) else 1
		bucket_pos[s].append((origin + Vector3(pos) * step_f) * scale)
		bucket_id[s].append(id)

	for s in 2:
		var n_spheres: int = bucket_pos[s].size()
		if n_spheres == 0:
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var idxs := PackedInt32Array()
		verts.resize(n_spheres * nv)
		normals.resize(n_spheres * nv)
		uvs.resize(n_spheres * nv)
		idxs.resize(n_spheres * ni)
		var vi := 0
		var ii := 0
		for j in n_spheres:
			var center: Vector3 = bucket_pos[s][j]
			var u := VoxelMaterial.uv_for_id(bucket_id[s][j])
			var uv := Vector2(u, 0.5)
			var vbase := vi
			for k in nv:
				var v: Vector3 = unit_verts[k]
				verts[vi] = center + v * radius
				normals[vi] = v
				uvs[vi] = uv
				vi += 1
			for k in ni:
				idxs[ii] = unit_indices[k] + vbase
				ii += 1
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = idxs
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		# 空 surface 已跳过，材质须绑定到实际 surface 序号
		mesh.surface_set_material(mesh.get_surface_count() - 1, materials[s])


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
				# 转换为 2D 密集网格，使用共享贪婪合并器（快速密集版，无字典哈希）
				var slice_cells: Dictionary = slice_voxels_visible
				var min_u := 0x7fffffff
				var max_u := -0x7fffffff
				var min_v := 0x7fffffff
				var max_v := -0x7fffffff
				for p: Vector3i in slice_cells:
					min_u = mini(min_u, p[axis.y])
					max_u = maxi(max_u, p[axis.y])
					min_v = mini(min_v, p[axis.z])
					max_v = maxi(max_v, p[axis.z])
				var grid_w := max_u - min_u + 1
				var grid_h := max_v - min_v + 1
				var grid := PackedInt32Array()
				grid.resize(grid_w * grid_h)
				for p: Vector3i in slice_cells:
					grid[(p[axis.y] - min_u) + (p[axis.z] - min_v) * grid_w] = int(slice_cells[p])
				var merge_result := VoxelGreedyMesher.greedy_merge_dense(grid, grid_w, grid_h)
				var m_pos: PackedInt32Array = merge_result["pos"]
				var m_size: PackedInt32Array = merge_result["size"]
				var n_rects: int = merge_result["val"].size()
				for i in n_rects:
					var pos: Vector3i
					pos[axis.x] = slice_index
					pos[axis.y] = m_pos[i * 2] + min_u
					pos[axis.z] = m_pos[i * 2 + 1] + min_v
					var size: Vector3 = Vector3.ONE
					size[axis.y] = m_size[i * 2]
					size[axis.z] = m_size[i * 2 + 1]
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
			# 面可见性统一规则（见 FaceTool.face_visible）：
			# 透明类型不同 → 可见；皆透明且材质不同 → 可见；实心材质接缝 → 不可见
			visible = FaceTool.face_visible(mats[slice[pos]], mats[dir_slice[dir_pos]])
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
