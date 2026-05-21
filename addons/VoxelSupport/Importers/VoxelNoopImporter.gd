@tool
extends EditorImportPlugin

func _get_importer_name():
	return 'voxel_noop'

func _get_visible_name():
	return "Voxel No Import"

func _get_recognized_extensions():
	return ['vox']

func _get_save_extension():
	return "res"

func _get_resource_type():
	return 'Resource'

func _get_priority() -> float:
	return 2

func _get_import_options(path, preset):
	return []
	
func _import(source_file, save_path, options, _platforms, gen_files):
	return ResourceSaver.save(Resource.new(), "%s.%s" % [save_path, _get_save_extension()])
