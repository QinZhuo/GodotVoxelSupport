@tool
class_name VoxelMeshImporter
extends EditorImportPlugin

func _get_importer_name():
	return 'voxel_mesh'

func _get_visible_name():
	return "Voxel Mesh"

func _get_recognized_extensions():
	return ['vox']

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

const frame_index := "mesh/frame_index"
const scale := "mesh/scale"
const shape := "mesh/shape"
## icosphere 细分级别 (0..4)，下拉标签为对应三角形数
const sphere_subdivisions := "mesh/sphere_subdivisions"
const sphere_scale := "mesh/sphere_scale"
const unwrap_lightmap_uv2 := "mesh/unwrap_lightmap_uv2"
const uv2_texel_size := "mesh/uv2_texel_size"
const material_path := "material/material_path"
const material_trans_path := "material/material_trans_path"
const import_materials_textures := "material/import_materials_textures"

## sphere_* 选项仅在形状选择 sphere 时显示
func _get_option_visibility(_path: String, option_name: StringName, options: Dictionary) -> bool:
	if String(option_name).begins_with("mesh/sphere_"):
		return options.get(VoxelMeshImporter.shape, Shape.cube) == Shape.sphere
	return true

func _import(source_file, save_path, options, _platforms, gen_files):
	var mesh: ArrayMesh
	mesh = VoxelMeshGenerator.generate_mesh(VoxAccess.Open(source_file).voxel, options, source_file)
	if not mesh:
		return FAILED
	return ResourceSaver.save(mesh, "%s.%s" % [save_path, _get_save_extension()])
