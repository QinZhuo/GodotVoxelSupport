@tool
class_name DevProjectSetup

static var _project_dirs: PackedStringArray = [
	"res://Assets/",
	"res://Assets/Def/",
	"res://Assets/Def/Attribute/",
	"res://Assets/Def/Buff/",
	"res://Assets/Def/Signal/",
	"res://Assets/Def/Tag/",
	"res://Assets/Translation/",
	"res://Scenes/",
	"res://Scripts/",
	"res://Scripts/Def/",
	"res://Scripts/Def/Condition/",
	"res://Scripts/Def/Effect/",
	"res://Scripts/Def/Signal/",
	"res://Scripts/Def/Tag/",
	"res://Scripts/Def/Value/",
	"res://Scripts/Entity/",
	"res://Scripts/View/",
]

static func create_structure() -> void:
	var dir = DirAccess.open("res://")
	if not dir:
		printerr("DevProjectSetup: 无法打开 res://")
		return

	var created_count := 0
	var existed_count := 0
	var error_count := 0

	for sub_path in _project_dirs:
		print("新建文件夹", sub_path)
		if dir.dir_exists(sub_path):
			existed_count += 1
			continue

		var ok = dir.make_dir_recursive(sub_path)
		if ok == OK:
			created_count += 1
		else:
			printerr("DevProjectSetup: 创建失败 [%s] (错误码: %d)" % [sub_path, ok])
			error_count += 1

	print("DevProjectSetup: 完成！新建 %d 个文件夹，已存在 %d 个，失败 %d 个。" % [created_count, existed_count, error_count])
