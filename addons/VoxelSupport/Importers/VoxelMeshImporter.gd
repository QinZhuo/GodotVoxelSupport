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
## frame_index 对 .qvox 无意义（一个 VOX0 就是一个模型，无动画帧概念）→ 隐藏。
func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	if String(option_name).begins_with("mesh/sphere_"):
		return options.get(VoxelMeshImporter.shape, Shape.cube) == Shape.sphere
	if option_name == frame_index:
		return not QVoxAsset.handles(path)
	return true

func _import(source_file, save_path, options, _platforms, gen_files):
	var mesh: ArrayMesh
	if QVoxAsset.handles(source_file):
		var qvox := QVoxAsset.from_file(source_file)
		if qvox == null:
			return FAILED
		mesh = VoxelMeshGenerator.generate_mesh_from_qvox(qvox, options, source_file)
	else:
		mesh = VoxelMeshGenerator.generate_mesh(VoxAsset.from_asset(source_file), options, source_file)
	if not mesh:
		return FAILED
	return ResourceSaver.save(mesh, "%s.%s" % [save_path, _get_save_extension()])
