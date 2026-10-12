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

## 在网格导入器选项之上追加 MeshLibrary 专属项（见基类 option_specs 的静态化说明）。
static func option_specs() -> Array[Dictionary]:
	var options := VoxelMeshImporter.option_specs()
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


func _get_import_options(_path, _preset) -> Array[Dictionary]:
	return option_specs()


## 必须重写：静态调用按定义所在脚本解析，基类的 default_options() 看不到上面追加的两项。
static func default_options() -> Dictionary:
	return _defaults_of(option_specs())

func _get_priority() -> float:
	# 排在 Mesh 之后、Data 之前：网格库是"要自己拼装"的进阶用法
	return 1.5


## `.vox` 与 `.qvx` 的选项集一致（都继承自 VoxelMeshImporter），无额外可见性规则。
## 【为什么这里不再写"split_by_frame 对 .qvx 无作用"】FRAM 落地后 `.qvx` 真的有体素动画帧：
## split_by_frame → 整个资产逐帧一项（frame_<k>）；split_by_model / split_by_node 则取
## `frame_index` 那一帧（静态资产恒为第 0 帧）。见 VoxelMeshGenerator 的分项实现。
func _get_option_visibility(path: String, option_name: StringName, options: Dictionary) -> bool:
	return super._get_option_visibility(path, option_name, options)


func _import(source_file, save_path, options, _platforms, gen_files):
	var lib: MeshLibrary
	if QVoxelAsset.handles(source_file):
		var qvx := QVoxelAsset.from_file(source_file)
		if qvx == null:
			return FAILED
		lib = VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, options, source_file)
	else:
		var voxel_data := VoxAsset.from_asset(source_file)
		if voxel_data == null:
			return FAILED
		lib = VoxelMeshGenerator.generate_mesh_library(voxel_data, options, source_file)
	if lib == null:
		return FAILED
	return ResourceSaver.save(lib, "%s.%s" % [save_path, _get_save_extension()])
