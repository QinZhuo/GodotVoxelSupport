@tool
class_name VoxelMeshImporter
extends EditorImportPlugin

func _get_importer_name():
	return 'voxel_mesh'

func _get_visible_name():
	return "Voxel Mesh"

func _get_recognized_extensions():
	return VoxAsset.SUPPORTED_EXTENSIONS.duplicate()

func _get_save_extension():
	return "mesh"

func _get_resource_type():
	return 'Mesh'

## 体素导入形状：cube = 经典面片网格；sphere = 每个体素一颗小球（风格化渲染）
enum Shape {
	cube,
	sphere,
}

func _get_import_options(path, preset) -> Array[Dictionary]:
	return [
		{
			name = scale,
			default_value = 0.1,
		},
		{
			# 资产原点：默认 world_origin = 原样保留文件里的坐标（等于本插件网格导入一直以来的
			# 行为，已有资产不会因升级挪位）。要"X/Z 居中 + Y 贴底"这种游戏资产惯例，
			# 再显式选 bottom_center。与 VoxelDataImporter 的同一选项共享取值与语义，
			# 详见 VoxelData.OriginMode。
			name = origin,
			default_value = VoxelData.OriginMode.WORLD_ORIGIN,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "world_origin,bottom_center,content_center",
		},
		{
			name = shape,
			default_value = Shape.cube,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "cube,sphere",
			# 修改 shape 时强制刷新全部选项可见性，
			# 否则编辑器不会重新调用 _get_option_visibility (godot#49641)
			usage = PropertyUsageFlags.PROPERTY_USAGE_DEFAULT | PropertyUsageFlags.PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED,
		},
		{
			name = sphere_subdivisions,
			default_value = 0,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "20,80,320",
		},
		{
			name = sphere_scale,
			default_value = 1.0,
			property_hint = PropertyHint.PROPERTY_HINT_RANGE,
			hint_string = "0.05,2.0,0.05",
		},
		{
			name = frame_index,
			default_value = 0,
		},
		{
			name = unwrap_lightmap_uv2,
			default_value = false,
		},
		{
			name = uv2_texel_size,
			default_value = 0.2,
			property_hint = PropertyHint.PROPERTY_HINT_RANGE,
			hint_string = "0.01,100,0.001"
		},
		{
			name = import_materials_textures,
			default_value = false,
		},
		{
			name = material_path,
			default_value = "",
			property_hint = PropertyHint.PROPERTY_HINT_FILE,
			hint_string = "*tres,*res"
		},
		{
			name = material_trans_path,
			default_value = "",
			property_hint = PropertyHint.PROPERTY_HINT_FILE,
			hint_string = "*tres,*res"
		},
	]

## 选项名统一取自 VoxAsset 单一出处（与 VoxelDataImporter 共用，避免同值重复定义）
const frame_index := VoxAsset.OPT_FRAME_INDEX
const scale := VoxAsset.OPT_SCALE
const origin := VoxAsset.OPT_ORIGIN
const shape := "mesh/shape"
## icosphere 细分级别 (0..4)，下拉标签为对应三角形数
const sphere_subdivisions := "mesh/sphere_subdivisions"
const sphere_scale := "mesh/sphere_scale"
const unwrap_lightmap_uv2 := "mesh/unwrap_lightmap_uv2"
const uv2_texel_size := "mesh/uv2_texel_size"
const material_path := "material/material_path"
const material_trans_path := "material/material_trans_path"
const import_materials_textures := "material/import_materials_textures"

func _get_priority() -> float:
	# 网格是绝大多数用户的期望产物，故作为新文件的默认导入器
	# （No Import 降到 0、Data/MeshLibrary 次之，避免"默认导入成空资源"）。
	return 2.0


## sphere_* 选项仅在形状选择 sphere 时显示
## 依赖 shape 选项的 PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED 标志触发刷新 (godot#49641)
## frame_index 对两种源格式都有效（两者都有"帧"的概念）：`.vox` 取动画帧；`.qvox` 取 NODE 里
## 第一段动画的 frames[] 下标——它是"该时刻各节点的局部变换覆盖值"，缺省 0 即起始姿态。
func _get_option_visibility(_path: String, option_name: StringName, options: Dictionary) -> bool:
	if String(option_name).begins_with("mesh/sphere_"):
		return options.get(VoxelMeshImporter.shape, Shape.cube) == Shape.sphere
	return true

func _import(source_file, save_path, options, _platforms, gen_files):
	var mesh: ArrayMesh
	if QVoxAsset.handles(source_file):
		var qvox := QVoxAsset.from_file(source_file, options[frame_index])
		if qvox == null:
			return FAILED
		mesh = VoxelMeshGenerator.generate_mesh_from_qvox(qvox, options, source_file)
	else:
		mesh = VoxelMeshGenerator.generate_mesh(VoxAsset.from_asset(source_file), options, source_file)
	if not mesh:
		return FAILED
	return ResourceSaver.save(mesh, "%s.%s" % [save_path, _get_save_extension()])
