@tool
class_name VoxelMeshLibraryImporter
extends VoxelMeshImporter

## `.vox` / `.qvx` → **MeshLibrary**（按 model / node / frame 分项）。进阶用法，优先级次之。
## 继承网格导入器的全部选项 + 两项专属（见 VoxelImportOptions.mesh_library_specs）。

const MeshMode = VoxelImportOptions.MeshMode
const mesh_mode := VoxelImportOptions.MESH_MODE
const import_meshes := VoxelImportOptions.IMPORT_MESHES


func _get_importer_name():
	return "voxel_mesh_library"


func _get_visible_name():
	return "Voxel MeshLibrary"


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "MeshLibrary"


## 排在 Mesh 之后、Data 之前：网格库是"要自己拼装"的进阶用法。
func _get_priority() -> float:
	return 1.5


func _get_import_options(_path, _preset) -> Array[Dictionary]:
	return VoxelImportOptions.mesh_library_specs()


## 必须重写：静态调用按定义所在脚本解析，基类的 default_options() 看不到追加的两项。
static func default_options() -> Dictionary:
	return VoxelImportOptions.defaults(VoxelImportOptions.mesh_library_specs())


func _from_qvx(qvx, options, source_file) -> Resource:
	return VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, options, source_file)


func _from_vox(vox, options, source_file) -> Resource:
	return VoxelMeshGenerator.generate_mesh_library(vox, options, source_file)
