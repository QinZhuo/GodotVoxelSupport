@tool
extends EditorPlugin

## VoxelSupport 编辑器插件：注册 `.vox` / `.qvx` 的导入器，并按项目设置门控功能范围。
##
## 【用法】`voxel_support/enable_dynamic_voxel` 是**项目初始化选项**（不是运行时开关）：
##   · false（默认）→ 只留 `Importer + Format + Mesh`，即"导入为静态网格"的最小集；
##     `Model/`（世界/场景/求值）与 `Dynamic/`（运行时数据层）被 `.gdignore` **排除**
##     （不编译、不导入、class_name 不进全局类表）。
##   · true → 全量（QVoxelier 编辑器 + 动态体素）。
##   在「项目设置」里改它会**自动**写/删两个 `.gdignore`、清 `.godot/global_script_class_cache.cfg`
##   （Godot 移除 `.gdignore` 后不会重注册类，必须清缓存），然后**提示重启编辑器**才生效。
##   代价：关掉时引用 `Model/`/`Dynamic/` 的 QVoxelier / 测试 / 演示都会编译失败（它们属"全量"场景）。

const SETTING_ENABLE_DYNAMIC_VOXEL := "voxel_support/enable_dynamic_voxel"

## 受开关门控的目录（关 → 写 `.gdignore`，不编译）。
const GATED_DIRS := [
	"res://addons/VoxelSupport/Model",
	"res://addons/VoxelSupport/Dynamic",
]

## 类缓存：Godot 在移除 `.gdignore` 后不会重注册被排除过的类，必须删它 + 重启才能重建。
const CLASS_CACHE := "res://.godot/global_script_class_cache.cfg"

var importers: Array[EditorImportPlugin]


func _enter_tree():
	# 声明项目设置（默认 false），使它在「项目设置」里可见可改。
	if not ProjectSettings.has_setting(SETTING_ENABLE_DYNAMIC_VOXEL):
		ProjectSettings.set_setting(SETTING_ENABLE_DYNAMIC_VOXEL, false)
	ProjectSettings.add_property_info({
		"name": SETTING_ENABLE_DYNAMIC_VOXEL,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	})
	# 在「项目设置」里改开关时实时响应（免去"改完还得手动重载插件"）。
	ProjectSettings.settings_changed.connect(_on_settings_changed)
	_apply_runtime_gate()

	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelNoopImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshImporter.gd").new())
	importers.append(preload("res://addons/VoxelSupport/Importer/VoxelMeshLibraryImporter.gd").new())
	# 动态体素导入器：仅当开关打开时注册。用 load 而非 preload：关闭时该脚本可能被 `.gdignore` 排除。
	if bool(ProjectSettings.get_setting(SETTING_ENABLE_DYNAMIC_VOXEL, false)):
		var script := load("res://addons/VoxelSupport/Dynamic/QVoxelSourceImporter.gd")
		if script != null:
			importers.append(script.new())
	for importer in importers:
		add_import_plugin(importer)


func _exit_tree():
	ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	for importer in importers:
		remove_import_plugin(importer)


## 项目设置变化 → 重新核对门控（只在真的需要变化时才动作；一致则原样返回）。
func _on_settings_changed() -> void:
	_apply_runtime_gate.call_deferred()


## 按开关同步被门控目录的 `.gdignore`：**关 → 写入**（编辑器不扫描该目录 = 不编译、不导入、
## class_name 不进全局类表）；**开 → 删除**。这是"一个项目设置 → 物理排除"的桥。
## 一旦发生变化：删类缓存 + 重扫 + **提示重启**。插件**不代劳重启** —— Godot 移除 `.gdignore`
## 后不会重注册类，删缓存要到下次启动才重建，故这一步只能由用户重启完成。
func _apply_runtime_gate() -> void:
	var enabled := bool(ProjectSettings.get_setting(SETTING_ENABLE_DYNAMIC_VOXEL, false))
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
	if not changed:
		return
	if FileAccess.file_exists(CLASS_CACHE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CLASS_CACHE))
	EditorInterface.get_resource_filesystem().scan()
	# 非阻塞提示（`OS.alert` 是阻塞模态，会卡死编辑器主线程）。
	var msg := ("VoxelSupport 门控已按 `%s=%s` 更新（已清全局类缓存）；"
			+ "请**重启编辑器**才生效 —— Godot 在移除 .gdignore 后不会自动重新注册被排除过的类。"
			% [SETTING_ENABLE_DYNAMIC_VOXEL, str(enabled)])
	push_warning(msg)
	print_rich("[b][color=orange]VoxelSupport[/color][/b]：%s" % msg)
