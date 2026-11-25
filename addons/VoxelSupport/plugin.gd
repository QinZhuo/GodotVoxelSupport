@tool
extends EditorPlugin

## VoxelSupport 编辑器插件：注册 `.vox` / `.qvx` 的导入器。
## 三类产物各一个导入器：静态网格 / MeshLibrary / 动态体素数据。粒子不单独导入（见 README）。
## 四个导入器全部在 `Importer/`，与"编辑器侧扩展"同类，不散落在各层。

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
