@tool
class_name VoxelNoopImporter
extends EditorImportPlugin

## 「不导入」导入器：只保留原始 .vox / .qvox 文件，不生成任何产物。
## 与另外三个导入器（Mesh / MeshLibrary / Data）并列，作为导入面板里的一个选项。
## （此前唯独它没有 class_name，导致按名引用会 "not declared"；补齐以保持一致。）

func _get_importer_name():
	return 'voxel_noop'

func _get_visible_name():
	return "Voxel No Import"

func _get_recognized_extensions():
	return VoxAsset.SUPPORTED_EXTENSIONS.duplicate()

func _get_save_extension():
	return "res"

func _get_resource_type():
	return 'Resource'

func _get_priority() -> float:
	# 最低优先级：它是"显式选择才生效"的兜底项，不该成为新文件的默认导入器
	# （此前它是最高的 2，导致新加的 .vox/.qvox 默认导入成空 Resource）。
	return 0.0

func _get_import_options(path, preset):
	return []
	
func _import(source_file, save_path, options, _platforms, gen_files):
	return ResourceSaver.save(Resource.new(), "%s.%s" % [save_path, _get_save_extension()])
