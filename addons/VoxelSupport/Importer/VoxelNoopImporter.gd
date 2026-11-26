@tool
class_name VoxelNoopImporter
extends VoxelImportPluginBase

## 「不导入」导入器：只保留原始 `.vox` / `.qvx` 文件，不生成任何产物。

func _get_importer_name():
	return "voxel_noop"

func _get_visible_name():
	return "Voxel No Import"

func _get_save_extension():
	return "res"

func _get_resource_type():
	return "Resource"

func _get_priority() -> float:
	return 0.0

func _get_import_options(_path, _preset) -> Array[Dictionary]:
	return []

## 不加载源文件（noop 不需要内容），直接落一个空 Resource。
func _import(_source_file, save_path, _options, _platforms, _gen_files):
	return ResourceSaver.save(Resource.new(), "%s.%s" % [save_path, _get_save_extension()])
