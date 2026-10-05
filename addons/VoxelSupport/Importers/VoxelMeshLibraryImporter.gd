@tool
class_name VoxelMeshLibraryImporter
extends VoxelMeshImporter

func _get_importer_name():
	return 'voxel_mesh_library'

func _get_visible_name():
	return "Voxel MeshLibrary"

func _get_recognized_extensions():
	return VoxAsset.SUPPORTED_EXTENSIONS.duplicate()

func _get_save_extension():
	return "res"

func _get_resource_type():
	return 'MeshLibrary'

enum MeshMode {
	split_by_model,
	split_by_node,
	split_by_frame,
}

const mesh_mode := "mesh/mode"
const import_meshes := "mesh/import_meshes"

func _get_import_options(path, preset) -> Array[Dictionary]:
	var options = super._get_import_options(path, preset)
	options.append_array([ {
			name = mesh_mode,
			default_value = MeshMode.split_by_model,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "split_by_model,split_by_node,split_by_frame",
		}, {
			name = import_meshes,
			default_value = false,
		}])
	return options

func _import(source_file, save_path, options, _platforms, gen_files):
	var voxel_data := VoxAsset.from_asset(source_file)
	if voxel_data == null:
		return FAILED
	return ResourceSaver.save(VoxelMeshGenerator.generate_mesh_library(voxel_data, options, source_file), "%s.%s" % [save_path, _get_save_extension()])
