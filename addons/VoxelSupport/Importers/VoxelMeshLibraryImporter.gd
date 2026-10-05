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

func _get_priority() -> float:
	# 排在 Mesh 之后、Data 之前：网格库是"要自己拼装"的进阶用法
	return 1.5


## .qvox 没有体素动画帧，split_by_frame 会被当作 split_by_model 处理（导入时给出警告）。
## frame_index 对 .qvox 同样无意义 → 隐藏。
func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	if option_name == frame_index:
		return not QVoxAsset.handles(path)
	return super._get_option_visibility(path, option_name, options)


func _import(source_file, save_path, options, _platforms, gen_files):
	var lib: MeshLibrary
	if QVoxAsset.handles(source_file):
		var qvox := QVoxAsset.from_file(source_file)
		if qvox == null:
			return FAILED
		lib = VoxelMeshGenerator.generate_mesh_library_from_qvox(qvox, options, source_file)
	else:
		var voxel_data := VoxAsset.from_asset(source_file)
		if voxel_data == null:
			return FAILED
		lib = VoxelMeshGenerator.generate_mesh_library(voxel_data, options, source_file)
	if lib == null:
		return FAILED
	return ResourceSaver.save(lib, "%s.%s" % [save_path, _get_save_extension()])
