@tool
extends EditorPlugin

## VoxelSupport 编辑器插件：注册 `.vox` / `.qvx` 的导入器。
## 【基础 vs 动态体素】网格导入（静态展示，大多数游戏只需要它）永远注册；**动态体素**
## （QVoxelSource 数据资源，供运行时逐格增删 / 破坏 / 无限地形）由项目设置
## `voxel_support/enable_runtime` 开关控制，**默认关** —— 关掉时插件不产出任何运行时数据资源。
## 【改开关后需重载插件】导入器集合在 `_enter_tree` 读取，改设置后禁用再启用本插件（或重启编辑器）生效。

const SETTING_ENABLE_RUNTIME := "voxel_support/enable_runtime"

## 受开关门控的目录（关 → 写 `.gdignore`，真·不编译）。
## `Model/`（世界/场景/求值）+ `Dynamic/`（运行时数据层）—— 两者都只在"要编辑 / 要动态体素"时才需要；
## 关掉后只剩 `Importer + Format + Mesh`，即"导入为静态网格"的最小集。
const GATED_DIRS := [
	"res://addons/VoxelSupport/Model",
	"res://addons/VoxelSupport/Dynamic",
]

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
	_apply_runtime_gate()

	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelNoopImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshLibraryImporter.gd").new())
	# 动态体素导入器：仅当开关打开时注册（否则连选项都不出现在导入面板）。
	# 用 load 而非 preload：关闭时该脚本可能被 .gdignore 排除，preload 会在解析期直接报错。
	if bool(ProjectSettings.get_setting(SETTING_ENABLE_RUNTIME, false)):
		var script := load("res://addons/VoxelSupport/Dynamic/QVoxelSourceImporter.gd")
		if script != null:
			importers.append(script.new())
	for importer in importers:
		add_import_plugin(importer)


func _exit_tree():
	for importer in importers:
		remove_import_plugin(importer)


## 按开关同步被门控目录的 `.gdignore`：**关 → 写入**（编辑器不扫描该目录 = 不编译、不导入、
## class_name 不进全局类表）；**开 → 删除**。这是"一个项目设置 → 真·物理排除"的桥。
## 改设置后需重载本插件（或重启编辑器）生效。
## 【代价】关闭时 `Model/` 与 `Dynamic/` 里的类全部消失 —— 引用它们的**编辑器（QVoxelier）/
## 测试 / 演示也会编译失败**。故：本仓库在 project.godot 里把该开关置 true；纯静态网格的游戏置 false。
func _apply_runtime_gate() -> void:
	var enabled := bool(ProjectSettings.get_setting(SETTING_ENABLE_RUNTIME, false))
	var changed := false
	for dir in GATED_DIRS:
		var marker: String = dir + "/.gdignore"
		var has := FileAccess.file_exists(marker)
		if has == (not enabled):
			continue  # 已一致（enabled 时不该有 marker；否则该有）
		if enabled:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(marker))
		else:
			var f := FileAccess.open(marker, FileAccess.WRITE)
			if f != null:
				f.close()
		changed = true
	if changed:
		EditorInterface.get_resource_filesystem().scan()
