@tool
extends EditorPlugin

## VoxelSupport 编辑器插件：注册 `.vox` / `.qvx` 的导入器。

var importers: Array[EditorImportPlugin]

func _enter_tree():
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelNoopImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshLibraryImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/QVoxelSourceImporter.gd").new())
	for importer in importers:
		add_import_plugin(importer)

func _exit_tree():
	for importer in importers:
		remove_import_plugin(importer)
