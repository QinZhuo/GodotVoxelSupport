@tool
extends EditorPlugin

## VoxelSupport 编辑器插件：注册 `.vox` / `.qvx` 的导入器。
## 【基础 vs 动态体素】网格导入（静态展示，大多数游戏只需要它）永远注册；**动态体素**
## （QVoxelSource 数据资源，供运行时逐格增删 / 破坏 / 无限地形）由项目设置
## `voxel_support/enable_runtime` 开关控制，**默认关** —— 关掉时插件不产出任何运行时数据资源。
## 【改开关后需重载插件】导入器集合在 `_enter_tree` 读取，改设置后禁用再启用本插件（或重启编辑器）生效。

const SETTING_ENABLE_RUNTIME := "voxel_support/enable_runtime"

var importers: Array[EditorImportPlugin]


func _enter_tree():
	# 声明项目设置（默认 false），使它在「项目设置」里可见可改。
	if not ProjectSettings.has_setting(SETTING_ENABLE_RUNTIME):
		ProjectSettings.set_setting(SETTING_ENABLE_RUNTIME, false)
	ProjectSettings.add_property_info({
		"name": SETTING_ENABLE_RUNTIME,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})

	importers.append(preload("res://addons/VoxelSupport/Importers/VoxelNoopImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importers/VoxelMeshImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importers/VoxelMeshLibraryImporter.gd").new())
	# 动态体素导入器：仅当开关打开时注册（否则连选项都不出现在导入面板）。
	if bool(ProjectSettings.get_setting(SETTING_ENABLE_RUNTIME, false)):
		importers.append(preload("res://addons/VoxelSupport/Importers/QVoxelSourceImporter.gd").new())
	for importer in importers:
		add_import_plugin(importer)


func _exit_tree():
	for importer in importers:
		remove_import_plugin(importer)
