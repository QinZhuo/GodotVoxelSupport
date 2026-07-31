@tool
class_name VoxelDataImporter
extends EditorImportPlugin

## 导入 .vox 为 VoxelDataResource (.res)
## 保存可序列化的体素数据，供 VoxelRenderer / VoxelDestructible 等运行时节点使用
## 不生成 mesh，仅保存原始体素数据，便于运行时动态修改和破坏

const frame_index := "mesh/frame_index"
const scale := "mesh/scale"


func _get_importer_name():
	return 'voxel_data'


func _get_visible_name():
	return "Voxel Data Resource"


func _get_recognized_extensions():
	return ['vox']


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "Resource"


func _get_priority() -> float:
	return 1.0


func _get_import_options(path, preset) -> Array[Dictionary]:
	return [
		{
			name = frame_index,
			default_value = 0,
		},
		{
			name = scale,
			default_value = 0.1,
		},
	]


func _import(source_file, save_path, options, _platforms, gen_files):
	var vox_access := VoxAccess.Open(source_file)
	if not vox_access:
		return FAILED
	var res := VoxelDataResource.from_voxel_data(vox_access.voxel, options[frame_index])
	res.default_scale = options[scale]
	return ResourceSaver.save(res, "%s.%s" % [save_path, _get_save_extension()])
