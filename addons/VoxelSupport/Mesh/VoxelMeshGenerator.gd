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
	var unwrap: bool = options[VoxelImportOptions.UNWRAP_UV2]
	gen.wait_finished(unwrap, options[VoxelImportOptions.UV2_TEXEL_SIZE])
	if not gen.mesh or gen.mesh.get_surface_count() == 0:
		return null
	# 球体路径的 UV2 只在单网格入口展开（wait_finished 刻意跳过），且只展开这一次 ——
	# 此前这里对 cube 又展开一遍，同一张网格白跑两次昂贵的 unwrap。
	if unwrap and gen.shape == VoxelImportOptions.Shape.sphere:
		gen.mesh.lightmap_unwrap(Transform3D.IDENTITY, options[VoxelImportOptions.UV2_TEXEL_SIZE])
	print_verbose("generate_mesh mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms", gen.mesh.get_faces().size() / 6, "face")
	return gen.mesh


# 材质魔术值：编辑器导入与运行时生成共用，避免两处漂移
## 自发光倍率。20 不是随手调亮的 HDR 值 —— 它是把 MagicaVoxel 的自发光观感
## （同一套 ACES + 曝光 1.8）对齐到本管线实测出来的倍率，**不要按直觉下调**：
## 改它等于改所有已有模型的发光语义，动之前先拿 MagicaVoxel 出图重新对一遍。
const MATERIAL_EMISSION_ENERGY := 20.0
const MATERIAL_REFRACTION_SCALE := 0.01


## 统一配置实心材质（编辑器/运行时共用）
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

## `.vox` → MeshLibrary。分项拆解在 `_mesh_library_items`，写入库的骨架在 `_commit_mesh_library`。
## [param gen_files] 引擎的产物登记数组：分项网格落到 res:// 之后必须登记，
## 否则引擎不知道它们是导入产物，项名/分项方式一变就留下没人回收的孤儿文件。
static func generate_mesh_library(voxel: VoxAsset, options: Dictionary, path: String = "",
		gen_files: Array = []) -> MeshLibrary:
	var mode := int(options[VoxelImportOptions.MESH_MODE])
	var frame := int(options.get(VoxelImportOptions.FRAME_INDEX, 0))
	var root_gen := VoxelMeshGenerator.new(voxel, options, path)
	root_gen.generate_materials(options)
	var time := Time.get_ticks_usec()
	var built: Array = []
	for item in _mesh_library_items(voxel, frame, mode):
		var gen := VoxelMeshGenerator.new(voxel, options, path)
		gen.materials = root_gen.materials
		gen.mesh = _get_mesh(item["name"], path, options)
		gen.start_generate_mesh(item["voxels"])
		gen.wait_finished(options[VoxelImportOptions.UNWRAP_UV2], options[VoxelImportOptions.UV2_TEXEL_SIZE])
		built.append({"name": item["name"], "mesh": gen.mesh, "dirty": gen.regenerated})
	print_verbose("generate_mesh_library mesh: ", (Time.get_ticks_usec() - time) / 1000.0, "ms")
	return _commit_mesh_library(built, options, path, gen_files)


## 写库骨架（`.vox` / `.qvx` 共用）：收集旧网格 → 清库 → 逐项写入 → 删掉本次未再生成的旧文件。
## 项名一律取 `built[i]["name"]`，绝不取 `mesh.resource_name` —— built_in 策略下
## `_get_mesh` 返回的是无名 ArrayMesh，按它命名会让所有项名字都是空的。
static func _commit_mesh_library(built: Array, options: Dictionary, path: String,
		gen_files: Array = []) -> MeshLibrary:
	var lib: MeshLibrary = null
	if path != "" and FileAccess.file_exists(path):
		var res: Resource = ResourceLoader.load(path)
		if res is MeshLibrary:
			lib = res
	if lib == null:
		lib = MeshLibrary.new()
	var old_meshes: Array[ArrayMesh] = []
	for i in lib.get_item_list():
		var old := lib.get_item_mesh(i)
		if old:
			old_meshes.append(old)
	lib.clear()
	var writes := bool(options[VoxelImportOptions.IMPORT_MESHES]) and path != ""
	var idx := 0
	# 本次"仍在用"的落盘路径。判删只认它，不按项名反查：项名经过净化（`a/b` → `a_b`）
	# 后与资源名不再一致，按名字反查会误删刚写好的文件。
	var keep := {}
	for item in built:
		var mesh: ArrayMesh = item["mesh"]
		# 空网格不建项：GridMap 里一个"看不见的项"只会让人以为导入失败
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		lib.create_item(idx)
		lib.set_item_mesh(idx, mesh)
		lib.set_item_name(idx, item["name"])
		idx += 1
		if mesh.resource_path == "":
			continue
		keep[mesh.resource_path] = true
		if not writes:
			continue
		# 只落盘本次真的重建过的项：缓存命中的项内容与磁盘上完全一致，
		# 重写一次只会刷掉 mtime、制造 VCS 噪音，还会让引擎丢弃它的资源缓存。
		if bool(item.get("dirty", true)):
			ResourceSaver.save(mesh)
		# 登记给引擎（含复用的项：它们同样是本次导入的产物，不登记就会在
		# 项名/分项方式变化后变成孤儿文件）。
		if not gen_files.has(mesh.resource_path):
			gen_files.append(mesh.resource_path)
	# 只清"上次落盘、这次不再生成"的分项网格文件。resource_path 为空说明它没落过盘
	# （built_in 策略），对空路径 remove_absolute 是无意义且危险的调用。
	# 【为什么引擎登记了还要自己删】引擎对"上次登记过、这次没再生成"的 dest_files
	# 清理并不总能覆盖（项名变化/分项方式切换），这一步是幂等兜底。
	for old_mesh in old_meshes:
		var old_path := old_mesh.resource_path
		if old_path != "" and not keep.has(old_path):
			DirAccess.remove_absolute(old_path)
			print_verbose("delete ", old_path)
	return lib


## MeshMode → `[{name, voxels}]`（三种分项的**唯一**拆解处，网格生成只消费结果）。
## 【坐标语义】每项都是独立资产：只去掉该项节点自己的摆放，子树内部的相对摆放必须保留——
## 全丢掉会让多部件对象的所有部件叠到同一个中心（整体糊成一团）。
## 与 `_items_by_node`（.qvx 侧）同构：重名/无名退化为稳定编号，项名不撞。
static func _mesh_library_items(voxel: VoxAsset, frame_index: int, mode: int) -> Array:
	var out: Array = []
	match mode:
		VoxelImportOptions.MeshMode.split_by_node:
			var used := {}
			for node_id in voxel.top_node_ids():
				var node: VoxAsset.VoxelNode = voxel.nodes.get(node_id)
				if node == null:
					continue
				out.append({
					"name": _unique_name(used, node.get_name(voxel, frame_index)),
					"voxels": node.get_voxels(voxel, frame_index, true),
				})
		VoxelImportOptions.MeshMode.split_by_frame:
			# 帧数取资产本身的（`VoxAsset.frame_count`），不是 frame_index —— 后者是"导哪一帧"，
			# 拿它当上限会让 4 帧动画的逐帧导出只得到第 0 帧（静默少 3 项）。
			for i in voxel.frame_count():
				out.append({"name": "frame_%d" % i, "voxels": voxel.get_voxels(i)})
		_:
			for i in voxel.models.size():
				out.append({"name": "model_%d" % i, "voxels": voxel.models[i].get_voxels()})
	return out


## 项名去重：重名或空名一律退化为 `node_N`（N 单调递增）—— 项名是 MeshLibrary 项的身份，
## 空名/撞名会让 `find_item_by_name` 失效，也让"旧网格文件该不该删"的判断失准。
## 判重按**落盘文件名**（净化后）而不是原串：`a/b` 与 `a_b` 名字不同却会写到同一个 .res 上。
static func _unique_name(used: Dictionary, wanted: String) -> String:
	if wanted != "" and not used.has(_safe_file_name(wanted)):
		used[_safe_file_name(wanted)] = true
		return wanted
	var seq := used.size() + 1
	var nm := "node_%d" % seq
	while used.has(_safe_file_name(nm)):
		seq += 1
		nm = "node_%d" % seq
	used[_safe_file_name(nm)] = true
	return nm


## 分项网格的落盘目录。**带上源扩展名**：同目录下 `cars.vox` 与 `cars.qvx` 的 stem 相同，
## 只按 stem 建目录会让两者的分项互相覆盖（`.vox → .qvx` 迁移期这很常见）。
static func _item_dir(path: String) -> String:
	var ext := path.get_extension()
	return path.get_basename() if ext == "" else "%s_%s" % [path.get_basename(), ext]


## 取该项的网格载体：开 import_meshes 时复用磁盘上的旧网格（逐项缓存的挂载点），
## 否则每次新建（无缓存可命中）。
## 【想强制重建某一项】删掉 `<stem>_<ext>/` 下对应的 `.res` 即可 —— 缺失即重建。
static func _get_mesh(name: String, path: String, options: Dictionary) -> ArrayMesh:
	if not (bool(options[VoxelImportOptions.IMPORT_MESHES]) and path != ""):
		return ArrayMesh.new()
	DirAccess.make_dir_absolute(_item_dir(path))
	# 项名可能来自用户写的节点名（`/`、`:` 等是非法路径字符）：落盘前先净化，否则保存失败。
	var child_path := _item_dir(path) + "/" + _safe_file_name(name) + ".res"
	# 存在性检查必须针对**要加载的那个文件**（child_path）。此前检查的是源资产 path，
	# 于是"缓存的 .res 存在但源资产不在"时会漏加载，反之也会误走加载分支。
	var mesh := ResourceLoader.load(child_path) as ArrayMesh if FileAccess.file_exists(child_path) else null
	if not mesh:
		mesh = ArrayMesh.new()
		mesh.resource_path = child_path
		mesh.resource_name = name
	return mesh


## 资源文件名安全化：只替换文件系统/Godot 资源路径不接受的字符，其余原样保留。
static func _safe_file_name(name: String) -> String:
	var out := ""
	for ch in name:
		out += "_" if ch in "/\\:*?\"<>|" else ch
	return out if out != "" else "item"


## 材质通道图（albedo/metal/rough/emission）——一次导入只构建一次。
## 此前每张纹理都重新构建全部 4 张图（4 材质 × 4 纹理 = 16 次），纯浪费。
func _get_channel_images() -> Dictionary:
	if _channel_images.is_empty():
		_channel_images = _build_channel_images(_materials_src())
	return _channel_images


## .qvx → ArrayMesh（单网格）。选项与 .vox 路径共用，故两者产物形状一致。
static func generate_mesh_from_qvx(qvx: QVoxelAsset, options: Dictionary, path: String = "") -> ArrayMesh:
	var gen := VoxelMeshGenerator.new(null, options, path)
	gen.qvx = qvx
	gen.runtime_materials = qvx.materials
	gen.generate_materials(options)
	gen.start_generate_mesh_from_qvx()
	gen.wait_finished(options[VoxelImportOptions.UNWRAP_UV2], options[VoxelImportOptions.UV2_TEXEL_SIZE])
	if not gen.mesh or gen.mesh.get_surface_count() == 0:
		return null
	return gen.mesh


## .qvx → MeshLibrary。三种分项都是"每项一个网格"：
##   模型分项：每个体素源一项（项名 model_<id>；动画模型取 `frame_index` 那一帧）；
##   节点分项：NODE 里每个 kind="model" 节点一项（项名取节点名）；
##   帧分项：整个资产在每一帧的样子（项名 frame_<k>），与 .vox 的 split_by_frame 同构。
## 【为什么 split_by_frame 对 .qvx 不再降级】FRAM 落地后 .qvx 真的有体素动画帧了（§12.7）。
## 继续按 split_by_model 处理会让"逐帧导出"的用户拿到 N 个模型而不是 N 帧 —— 静默的错产物。
static func generate_mesh_library_from_qvx(qvx: QVoxelAsset, options: Dictionary,
		path: String = "", gen_files: Array = []) -> MeshLibrary:
	var frame := int(options.get(VoxelImportOptions.FRAME_INDEX, 0))
	var items: Array
	match int(options[VoxelImportOptions.MESH_MODE]):
		VoxelImportOptions.MeshMode.split_by_node:
			items = _items_by_node(qvx, frame)
		VoxelImportOptions.MeshMode.split_by_frame:
			items = _items_by_frame(qvx)
		_:
			items = _items_by_model(qvx, frame)
	return _commit_mesh_library(
			_build_qvx_items(qvx, items, options, path), options, path, gen_files)


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
	for p in qvx.placements:
		out.append({
			"name": _unique_name(used, String(p.get("name", ""))),
			"chunks": qvx.frame_blocks(int(p["model_id"]), frame),
		})
	return out


## 逐帧一项：整个资产在第 k 帧长什么样（与 .vox 的 split_by_frame 同构）。
## 帧数取所有动画模型的最大帧数；全静态资产 = 1 帧（即"整资产一项"）。
## 【为什么要按帧各算一次包围盒】原点由包围盒导出，而包围盒随帧变（§12.7 的 origin_offset）。
## 沿用第 0 帧的原点会让"第 3 帧才长出来的部分"整体偏移 —— 逐帧项各自摆正才是对的。
static func _items_by_frame(qvx: QVoxelAsset) -> Array:
	var out: Array = []
	for k in qvx.total_frame_count():
		out.append({"name": "frame_%d" % k, "chunks": qvx.block_buffers(k)})
	return out


## 按 items（[{name, chunks}]）逐项生成网格（不写库，交给 `_commit_mesh_library`）。
## 每项按 origin_mode 各自摆正（VoxelWorldUtil.origin_offset）—— MeshLibrary 的每一项都是独立资产，
## 本就该各自有原点，否则往场景里放第 N 项时位置会带着别的模型的偏移。
static func _build_qvx_items(qvx: QVoxelAsset, items: Array, options: Dictionary,
		path: String) -> Array:
	var built: Array = []
	for item in items:
		var chunks: Dictionary = item["chunks"]
		if chunks.is_empty():
			continue
		var child := _get_mesh(item["name"], path, options)
		var gen := VoxelMeshGenerator.new(null, options, path)
		gen.mesh = child
		gen.runtime_materials = qvx.materials
		gen.generate_materials(options)
		gen.start_generate_mesh_from_chunks(
				chunks, VoxelWorldUtil.origin_offset(QVoxelAsset.bounds_for_blocks(chunks), gen.origin_mode))
		gen.wait_finished(options[VoxelImportOptions.UNWRAP_UV2], options[VoxelImportOptions.UV2_TEXEL_SIZE])
		built.append({"name": item["name"], "mesh": child, "dirty": gen.regenerated})
	return built


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
## 导入形状 (VoxelImportOptions.Shape): cube=面片网格, sphere=每体素一颗小球
var shape: int = VoxelImportOptions.Shape.cube
## 球体细分级别 (icosphere)，仅 sphere 形状生效；默认 0=20 面，优先保证性能
var sphere_subdivisions: int = 0
## 小球半径相对体素边长的比例，仅 sphere 形状生效
var sphere_scale: float = 1.0
## 资产原点模式（导入选项 mesh/origin，见 VoxelWorldUtil.OriginMode）：决定顶点叠加多少原点偏移。
## 四条链路共用同一套语义，故这里只把选项读进来，再交给 VoxelWorldUtil.origin_offset 算。
## 默认 WORLD_ORIGIN = 不动几何（本插件网格导入一直以来的行为）。
var origin_mode: int = VoxelWorldUtil.OriginMode.WORLD_ORIGIN

## 顶点预算：超出则由原生按采样间隔自动降采样，防止大模型在编辑器内 OOM 崩溃
const SPHERE_VERTEX_BUDGET := 4_000_000
## 原生几何内核返回的 arrays（start_generate_mesh 填充，wait_finished 消费）
var _native_arrays: Dictionary = {}
## 本次调用是否真的重建了几何（缓存命中的项为 false）。
## MeshLibrary 分项落盘只认它：内容与磁盘完全一致的项没必要重写（那会白刷 mtime）。
var regenerated := false


func _init(voxel: VoxAsset, options: Dictionary, path: String = "") -> void:
	self.root_path = path
	self.voxel = voxel
	frame_index = options.get(VoxelImportOptions.FRAME_INDEX, 0)
	scale = options.get(VoxelImportOptions.SCALE, 0.1)
	if scale <= 0:
		scale = 0.01
	shape = options.get(VoxelImportOptions.SHAPE, VoxelImportOptions.Shape.cube)
	sphere_subdivisions = clampi(options.get(VoxelImportOptions.SPHERE_SUBDIVISIONS, 0), 0, 2)
	sphere_scale = clampf(options.get(VoxelImportOptions.SPHERE_SCALE, 1.0), 0.05, 2.0)
	origin_mode = options.get(VoxelImportOptions.ORIGIN, VoxelWorldUtil.OriginMode.WORLD_ORIGIN)


func generate_materials(options: Dictionary) -> Array[Material]:
	materials.resize(2)
	var path := root_path if options[VoxelImportOptions.IMPORT_MATERIALS_TEXTURES] else ""
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
	var trans_flags := VoxelMaterial.build_trans_flags(_materials_src())
	# hash 必须包含所有影响几何的**输入**：MeshLibrary 模式会复用磁盘上的旧 mesh(带 meta)，
	# 漏一项就会被短路、保留旧网格。透明标志也算输入 —— 它决定体素进 solid 还是 trans 桶，
	# 只改材质透明度（体素一个没动）同样会换出不同的网格。
	var voxels_hash := hash([voxels.hash(), scale, shape, sphere_subdivisions, sphere_scale,
			origin_mode, trans_flags])
	_native_arrays = {}
	regenerated = true
	if not mesh:
		mesh = ArrayMesh.new()
	else:
		# 缓存命中需 hash 一致，且"有体素就必须已有表面"——
		# 否则会把"空网格 + 正确 hash"（原生库曾不可用导致）当成最新版本，永远不再重建。
		if mesh.has_meta("hash") and voxels_hash == mesh.get_meta("hash") \
				and (voxels.is_empty() or mesh.get_surface_count() > 0):
			regenerated = false
			return
		mesh.clear_surfaces()

	if voxels.size() == 0:
		mesh.set_meta("hash", voxels_hash)
		return

	# 原点偏移（体素单位）：按内容 AABB 算一次交给原生内核（cube 路径原生就支持 offset，
	# 不必事后搬运顶点）。WORLD_ORIGIN 模式跳过求界——那是一次 O(体素数) 的字典扫描。
	var offset := Vector3.ZERO
	if origin_mode != VoxelWorldUtil.OriginMode.WORLD_ORIGIN:
		offset = VoxelWorldUtil.origin_offset(VoxelWorldUtil.voxel_bounds(voxels), origin_mode)
	if shape == VoxelImportOptions.Shape.sphere:
		# offset 为体素单位，原生内部乘 scale（与 cube 路径同一约定）——不必再事后遍历平移顶点。
		_native_arrays = NativeLoader.generate_spheres_native(
			voxels, trans_flags, sphere_subdivisions, sphere_scale, scale, SPHERE_VERTEX_BUDGET, offset)
	else:
		_native_arrays = NativeLoader.generate_arrays_native(voxels, trans_flags, scale, offset)

	# 原生库不可用/版本不匹配时返回 {}：此时**不登记 hash** 并报错，
	# 否则空网格会被当作最新缓存，后续导入全部短路、再也修不回来。
	if _native_arrays.is_empty():
		push_error("[VoxelSupport] 体素网格生成返回空（原生库 VoxelNative 不可用或版本不匹配）: %s" % root_path)
		mesh.remove_meta("hash")
		return
	mesh.set_meta("hash", voxels_hash)


## 由块缓冲生成网格（QVX 路径的实例入口：整资产 / MeshLibrary 分项共用）。
## layout_offset 为体素单位的原点偏移（见 VoxelWorldUtil.origin_offset）。
## 与体素路径同一套逐项缓存：命中就不跑内核 —— `.qvx` 分项此前无条件重建，
## 改一个模型时其余项全量重算，正是"分项缓存只覆盖 .vox"这个缺口的来源。
func start_generate_mesh_from_chunks(chunks: Dictionary, layout_offset: Vector3) -> void:
	var trans_flags := VoxelMaterial.build_trans_flags(_materials_src())
	# 块表 hash 的代价是扫一遍 PackedInt32Array，远小于重跑一次原生内核。
	var chunks_hash := hash([chunks.hash(), scale, shape, sphere_subdivisions, sphere_scale,
			origin_mode, layout_offset, trans_flags])
	_native_arrays = {}
	regenerated = true
	if mesh and mesh.has_meta("hash") and chunks_hash == mesh.get_meta("hash") \
			and (chunks.is_empty() or mesh.get_surface_count() > 0):
		regenerated = false
		return
	_reset_mesh()
	if chunks.is_empty():
		mesh.set_meta("hash", chunks_hash)
		return
	_native_arrays = NativeLoader.generate_arrays_from_chunks_native(
			chunks, trans_flags, scale, layout_offset)
	if _native_arrays.is_empty():
		push_error("[VoxelSupport] 体素网格生成返回空（原生库 VoxelNative 不可用或版本不匹配）: %s" % root_path)
		mesh.remove_meta("hash")
		return
	mesh.set_meta("hash", chunks_hash)


## 材质来源（运行时材质优先；`.qvx` 路径的 `voxel` 为 null，故要兜底）。
func _materials_src() -> Array:
	if not runtime_materials.is_empty():
		return runtime_materials
	return voxel.materials if voxel != null else []


## 生成整个 QVX 资产：恒等摆放走块级（零逐体素展开），有变换时逐体素融合。
func start_generate_mesh_from_qvx() -> void:
	_reset_mesh()
	_native_arrays = {}
	if qvx == null or qvx.is_empty():
		return
	var materials_src: Array = runtime_materials if not runtime_materials.is_empty() else qvx.materials
	var trans_flags := VoxelMaterial.build_trans_flags(materials_src)
	# 原点偏移与 .vox 路径同一套（qvx.origin_offset 内部调 VoxelWorldUtil.origin_offset）。
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
	if shape != VoxelImportOptions.Shape.sphere and gen_uv2:
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